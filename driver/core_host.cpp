#include "core_host.h"

#include <os/log.h>
#include <string.h>

#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/util.h"
#include "usb_port.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)

namespace {

constexpr uint8_t kTlvStartFamily = 0x19;  // WDS Start Network "IP Family Preference"
constexpr uint8_t kFamilyV4 = 4;
constexpr uint8_t kFamilyV6 = 6;
constexpr size_t kEthHeaderLen = 14;

const char* ServiceName(rmnet::QmiService s) {
  switch (s) {
    case rmnet::QmiService::CTL:
      return "CTL";
    case rmnet::QmiService::WDS:
      return "WDS";
    case rmnet::QmiService::WDA:
      return "WDA";
  }
  return "?";
}

// Field by field (no memcmp of the struct: its padding is not set).
bool SameSettings(const rmnet::RuntimeSettings& a, const rmnet::RuntimeSettings& b) {
  return a.has_v4 == b.has_v4 && memcmp(a.v4_addr, b.v4_addr, sizeof a.v4_addr) == 0 &&
         memcmp(a.v4_gateway, b.v4_gateway, sizeof a.v4_gateway) == 0 &&
         memcmp(a.v4_mask, b.v4_mask, sizeof a.v4_mask) == 0 && memcmp(a.v4_dns, b.v4_dns, sizeof a.v4_dns) == 0 &&
         a.v4_dns_count == b.v4_dns_count && a.has_v6 == b.has_v6 &&
         memcmp(a.v6_addr, b.v6_addr, sizeof a.v6_addr) == 0 && a.v6_prefix_len == b.v6_prefix_len &&
         memcmp(a.v6_gateway, b.v6_gateway, sizeof a.v6_gateway) == 0 &&
         memcmp(a.v6_dns, b.v6_dns, sizeof a.v6_dns) == 0 && a.v6_dns_count == b.v6_dns_count && a.mtu == b.mtu;
}

rmnet::SessionConfig MakeSessionConfig(uint8_t profile, bool flow_control, uint8_t qmi_interface) {
  rmnet::SessionConfig cfg{};
  cfg.iface_number = qmi_interface;
  cfg.profile = profile;
  cfg.flow_control = flow_control;
  return cfg;
}

}  // namespace

const char* SessionStateName(rmnet::SessionState s) {
  switch (s) {
    case rmnet::SessionState::Idle:
      return "idle";
    case rmnet::SessionState::Syncing:
      return "syncing";
    case rmnet::SessionState::Configuring:
      return "configuring";
    case rmnet::SessionState::Connecting:
      return "connecting";
    case rmnet::SessionState::Up:
      return "up";
    case rmnet::SessionState::Refreshing:
      return "refreshing";
    case rmnet::SessionState::Backoff:
      return "backoff";
  }
  return "?";
}

CoreHost::CoreHost(UsbPort& usb, RxSink& rx, const rmnet::MacPair& macs, uint8_t profile, bool flow_control,
                   uint8_t qmi_interface, bool ipv6_only_preferred)
    : usb_(usb),
      rx_(rx),
      session_(MakeSessionConfig(profile, flow_control, qmi_interface), *this),
      eth_(macs, ipv6_only_preferred),
      agg_(nullptr, 0, 0, 0),
      uplink_slot_(-1),
      slot_packets_(),
      slot_bytes_(),
      ul_size_(0),
      ul_datagrams_(0),
      data_up_(false),
      data_v6_(false),
      paused_(false),
      resumed_(false),
      pause_timed_(false),
      pause_expired_(false),
      pause_start_ms_(0),
      restart_wanted_(false),
      last_advert_ms_(0),
      counters_(),
      logged_first_command_(false),
      logged_reply_kept_(false),
      kept_reply_(),
      kept_reply_len_(),
      kept_head_(0),
      kept_count_(0),
      reply_(),
      logged_state_(rmnet::SessionState::Idle),
      link_(),
      change_{false, false},
      syncs_sent_(0),
      logged_flow_refused_(false),
      start_client_(),
      start_client_known_(),
      logged_settings_(),
      logged_settings_known_() {}

void CoreHost::start(uint64_t now_ms) {
  forget_logged_settings();
  session_.start(now_ms);
  note_state();
}

void CoreHost::stop() {
  session_.stop();
  note_state();
  drop_kept_replies();
}

void CoreHost::restart(uint64_t now_ms) {
  LOG("session restart from %{public}s", SessionStateName(session_.state()));
  session_.stop();  // records a link down if the link was up; queues the releases
  note_state();
  drop_open_uplink();
  data_link_down();
  restart_wanted_ = false;
  forget_logged_settings();
  session_.start(now_ms);
  note_state();
}

void CoreHost::forget_logged_settings() {
  logged_settings_known_[0] = false;
  logged_settings_known_[1] = false;
}

void CoreHost::tick(uint64_t now_ms) {
  session_.tick(now_ms);
  note_flow_refusal();
  note_state();
}

void CoreHost::on_control(const uint8_t* data, size_t len, uint64_t now_ms) {
  log_received(data, len);
  session_.on_qmi(data, len, now_ms);
  note_flow_refusal();
  note_state();
}

// One line when the session finds flow control refused by the modem (an error, an unusable answer
// or a timeout); it has already asked again without it. on_qmi and tick are where the modem's
// refusal shows; give_up_flow_control also sets the refusal, but marks this line as logged, since
// the driver logs the give-up itself.
void CoreHost::note_flow_refusal() {
  if (logged_flow_refused_ || !session_.flow_control_refused()) return;
  logged_flow_refused_ = true;
  LOG("flow control refused: data format asked again without it");
}

CoreHost::LinkChange CoreHost::take_link_change() {
  LinkChange c = change_;
  change_ = {false, false};
  return c;
}

void CoreHost::send_qmi(const uint8_t* data, size_t len) {
  log_sent(data, len);
  if (!usb_.send(data, len)) LOG("qmi message of %zu bytes not sent", len);
}

void CoreHost::link_up(const rmnet::LinkConfig& cfg) {
  link_ = cfg;
  change_.up = true;
}

void CoreHost::link_down() {
  change_.down = true;
  change_.up = false;
}

// One line per state change: this is where backoff and the return to syncing show.
void CoreHost::note_state() {
  rmnet::SessionState s = session_.state();
  if (s == logged_state_) return;
  if (logged_state_ == rmnet::SessionState::Syncing && s == rmnet::SessionState::Configuring) {
    LOG("sync answered after %u sent", syncs_sent_);
  }
  LOG("session %{public}s -> %{public}s", SessionStateName(logged_state_), SessionStateName(s));
  logged_state_ = s;
}

uint8_t CoreHost::family_of(uint8_t wds_client) const {
  for (int i = 0; i < 2; i++) {
    if (start_client_known_[i] && start_client_[i] == wds_client) return i == 0 ? kFamilyV4 : kFamilyV6;
  }
  return 0;
}

// Logs every request the session sends: service, client, message and transaction ID.
void CoreHost::log_sent(const uint8_t* data, size_t len) {
  rmnet::QmiMessage m;
  if (!rmnet::qmi_decode(rmnet::Span{data, len}, &m)) {
    LOG("qmi tx %zu bytes (undecodable)", len);
    return;
  }
  if (m.hdr.service == rmnet::QmiService::CTL && m.hdr.msg_id == rmnet::kCtlSync) {
    // The state is logged after the session call returns, so a first sync finds it not Syncing.
    if (logged_state_ != rmnet::SessionState::Syncing) syncs_sent_ = 0;
    syncs_sent_++;
    LOG("sync sent (%u)", syncs_sent_);
    return;
  }
  if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsStartNetwork) {
    rmnet::Span v;
    uint8_t family = 0;
    if (rmnet::qmi_find_tlv(m.tlvs, kTlvStartFamily, &v) && v.len == 1) family = v.data[0];
    if (family == kFamilyV4 || family == kFamilyV6) {
      int i = family == kFamilyV4 ? 0 : 1;
      start_client_[i] = m.hdr.client;
      start_client_known_[i] = true;
    }
    LOG("call IPv%u: start network (client %u)", family, m.hdr.client);
    return;
  }
  LOG("qmi tx %{public}s client %u msg 0x%04x txid %u", ServiceName(m.hdr.service), m.hdr.client, m.hdr.msg_id,
      m.hdr.txid);
}

// Logs every message from the modem, and the meaning of the ones that mark progress.
void CoreHost::log_received(const uint8_t* data, size_t len) {
  rmnet::QmiMessage m;
  if (!rmnet::qmi_decode(rmnet::Span{data, len}, &m)) {
    LOG("qmi rx %zu bytes (undecodable)", len);
    return;
  }
  rmnet::QmiResult r = rmnet::qmi_result(m);
  const char* kind = m.hdr.kind == rmnet::QmiKind::Indication ? "ind" : "resp";
  LOG("qmi rx %{public}s %{public}s client %u msg 0x%04x txid %u result %{public}s 0x%x", ServiceName(m.hdr.service), kind,
      m.hdr.client, m.hdr.msg_id, m.hdr.txid, !r.present ? "-" : (r.ok ? "ok" : "error"), r.error);
  if (m.hdr.kind != rmnet::QmiKind::Response) return;

  if (m.hdr.service == rmnet::QmiService::WDA && m.hdr.msg_id == rmnet::kWdaSetDataFormat) {
    rmnet::DataFormat f;
    if (rmnet::parse_wda_data_format(m, &f)) {
      // "last request asked": the session's last Set Data Format request, which a late answer to an
      // earlier one is not; logged before the session sees this answer.
      LOG("data format: link layer %u, ul agg %u (%u datagrams, %u bytes), dl agg %u (%u datagrams, %u bytes), "
          "usable %d, flow control: last request asked %u, modem says %u",
          f.link_layer, f.ul_agg, f.ul_max_datagrams, f.ul_max_size, f.dl_agg, f.dl_max_datagrams, f.dl_max_size,
          rmnet::data_format_usable(f), session_.flow_control_asked() ? 1u : 0u,
          static_cast<unsigned>(f.flow_control));
    } else if (!r.present) {
      LOG("data format answer has no result");
    } else if (r.ok) {
      LOG("data format not parsed (result ok)");
    } else {
      LOG("data format refused (error 0x%x)", r.error);
    }
  } else if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsStartNetwork) {
    uint32_t handle = 0;
    rmnet::CallEnd end;
    bool ok = rmnet::parse_wds_start_network(m, &handle, &end);
    unsigned family = family_of(m.hdr.client);
    if (ok) {
      LOG("call IPv%u: connected", family);
    } else {
      LOG("call IPv%u: failed, error 0x%x, end reason %u, verbose %u/%u", family, r.error, end.reason,
          end.verbose_type, end.verbose_reason);
    }
  } else if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsGetCurrentSettings) {
    rmnet::RuntimeSettings s{};
    if (rmnet::parse_wds_current_settings(m, &s)) {
      uint8_t family = family_of(m.hdr.client);
      // Only for a known family: a reply from an unknown client is always logged.
      int f = family == kFamilyV4 ? 0 : (family == kFamilyV6 ? 1 : -1);
      if (f >= 0 && logged_settings_known_[f] && SameSettings(logged_settings_[f], s)) return;
      if (f >= 0) {
        logged_settings_[f] = s;
        logged_settings_known_[f] = true;
      }
      LOG("settings IPv%u: v4 %d (/%u, %u dns), v6 %d (/%u, %u dns), mtu %u", family, s.has_v4,
          s.has_v4 ? rmnet::prefix_length(s.v4_mask) : 0, s.v4_dns_count, s.has_v6, s.v6_prefix_len,
          s.v6_dns_count, s.mtu);
    }
  }
}

// --- Data path ---------------------------------------------------------------------------------

void CoreHost::data_link_down() {
  eth_.set_link(nullptr);
  data_up_ = false;
  data_v6_ = false;
  set_paused(false);
  drop_kept_replies();
}

void CoreHost::data_link_up(uint64_t now_ms) {
  const rmnet::LinkConfig& cfg = link_;
  eth_.set_link(&cfg.settings);
  bool again = data_up_;
  bool v6_new = cfg.settings.has_v6 && !data_v6_;
  data_up_ = true;
  data_v6_ = cfg.settings.has_v6;

  uint32_t ul = cfg.format.ul_max_size;
  ul_size_ = ul == 0 || ul > kMaxUplink ? static_cast<uint32_t>(kMaxUplink) : ul;
  ul_datagrams_ = cfg.format.ul_max_datagrams ? cfg.format.ul_max_datagrams : 1;
  uint32_t dl = cfg.format.dl_max_size;
  if (dl == 0 || dl > kMaxDownlink) dl = kMaxDownlink;
  if (!again) {
    LOG("data path: %u bulk reads of %u bytes; %u uplink buffers of %u bytes, %u datagrams, usb packet %u",
        (unsigned)kBulkReads, dl, (unsigned)kUplinkSlots, ul_size_, ul_datagrams_, usb_.bulk_out_packet_size());
  }
  if (v6_new) {
    send_router_advert();
    last_advert_ms_ = now_ms;
  }
  // Last: a read that cannot be posted is fatal, and the driver then stops the session.
  usb_.start_bulk(dl);
}

void CoreHost::data_tick(uint64_t now_ms) {
  send_kept_replies();  // the backstop: a completion normally sends them first
  // A pause is timed only while the data link is up, from the first tick that sees both (at most
  // one tick late): a flow disable during a sync or a backoff restarts no session.
  if (paused_ && data_up_ && !pause_timed_) {
    pause_timed_ = true;
    pause_start_ms_ = now_ms;
  }
  if (paused_ && data_up_ && pause_timed_ && !pause_expired_ && now_ms - pause_start_ms_ >= kPauseMaxMs) {
    pause_expired_ = true;
    restart_wanted_ = true;
    counters_.uplink_pause_timeouts++;
    LOG("uplink paused for %u ms with no flow enable: session restart wanted", (unsigned)kPauseMaxMs);
  }
  if (!data_up_ || !data_v6_) return;
  if (now_ms - last_advert_ms_ < kRouterAdvertMs) return;
  send_router_advert();
  last_advert_ms_ = now_ms;
}

void CoreHost::send_router_advert() {
  size_t n = eth_.make_router_advert(reply_, sizeof reply_);
  if (n) deliver_frame(reply_, n);
}

// Walks the transfer's QMAP frames. The modem sends each packet in its own transfer followed by a
// 4-byte all-zero transfer; that one has no frame (qmap_next says End) and is counted as empty.
void CoreHost::on_bulk_in(const uint8_t* data, size_t len) {
  counters_.rx_transfers++;
  rmnet::Span buf{data, len};
  size_t off = 0;
  bool any = false;
  rmnet::QmapFrame f;
  for (;;) {
    rmnet::QmapStatus st = rmnet::qmap_next(buf, &off, &f);
    if (st == rmnet::QmapStatus::End) break;
    if (st != rmnet::QmapStatus::Ok) {
      counters_.rx_drop_bad_qmap++;
      if (rmnet::worth(counters_.rx_drop_bad_qmap)) {
        LOG("bad qmap (%{public}s) at %zu of a %zu-byte transfer (%llu so far)",
            st == rmnet::QmapStatus::Truncated ? "truncated" : "malformed", off, len, counters_.rx_drop_bad_qmap);
      }
      break;
    }
    any = true;
    if (f.is_command) {
      on_command(f);
    } else if (f.mux_id != rmnet::SessionConfig{}.mux_id) {
      counters_.rx_drop_other_mux++;
    } else if (!data_up_) {
      counters_.rx_drop_link_down++;
    } else {
      deliver_ip(f.payload.data, f.payload.len);
    }
  }
  if (!any) counters_.rx_empty_transfers++;
}

void CoreHost::deliver_ip(const uint8_t* ip, size_t len) {
  size_t cap = 0;
  uint8_t* out = rx_.rx_buffer(&cap);
  if (!out) {
    counters_.rx_drop_no_packet++;
    return;
  }
  if (cap < kEthHeaderLen || len > cap - kEthHeaderLen) {
    counters_.rx_drop_too_big++;
    return;
  }
  size_t n = eth_.wrap_rx(ip, len, out, cap);
  if (n == 0) {
    counters_.rx_drop_filtered++;
    return;
  }
  rx_.rx_commit(n);
  counters_.rx_packets++;
  counters_.rx_bytes += len;
}

void CoreHost::deliver_frame(const uint8_t* frame, size_t len) {
  size_t cap = 0;
  uint8_t* out = rx_.rx_buffer(&cap);
  if (!out || len > cap) {
    counters_.reply_drop_no_packet++;
    return;
  }
  memcpy(out, frame, len);
  rx_.rx_commit(len);
  counters_.replies++;
}

// A command request is answered on the uplink from its own buffer (the reply is built there, not
// in the read buffer the request sits in). Acks and other non-requests are only counted. With no
// uplink buffer free, or replies already kept (they go first), the reply is kept.
void CoreHost::on_command(const rmnet::QmapFrame& f) {
  counters_.commands++;
  rmnet::QmapCommand cmd;
  bool parsed = rmnet::qmap_parse_command(f.payload, &cmd);
  if (!logged_first_command_) {
    logged_first_command_ = true;
    LOG("first qmap command: mux 0x%02x, %zu bytes, name %u, type %u", f.mux_id, f.payload.len,
        parsed ? cmd.name : 0, parsed ? cmd.type : 0);
  }
  if (!parsed || cmd.type != rmnet::kQmapCmdRequest) return;
  if (cmd.name == rmnet::kQmapFlowDisable) {
    counters_.flow_disable++;
    set_paused(true);
  } else if (cmd.name == rmnet::kQmapFlowEnable) {
    counters_.flow_enable++;
    set_paused(false);
  }
  send_kept_replies();
  int slot = kept_count_ == 0 ? usb_.acquire_uplink() : -1;
  if (slot < 0) {
    keep_reply(f);
    return;
  }
  size_t n = rmnet::qmap_build_command_reply(usb_.uplink_buffer(slot), kMaxUplink, f.mux_id, f.payload);
  if (n == 0) {
    usb_.release_uplink(slot);
    counters_.command_reply_drops++;
    return;
  }
  send_reply(slot, n);
}

// Builds the reply into the next free kept slot. A full store, or a reply larger than a slot,
// drops it (counted).
void CoreHost::keep_reply(const rmnet::QmapFrame& f) {
  if (kept_count_ >= kKeptReplies) {
    counters_.command_reply_drops++;
    return;
  }
  uint32_t i = (kept_head_ + kept_count_) % kKeptReplies;
  size_t n = rmnet::qmap_build_command_reply(kept_reply_[i], kKeptReplyBytes, f.mux_id, f.payload);
  if (n == 0) {
    counters_.command_reply_drops++;
    return;
  }
  kept_reply_len_[i] = static_cast<uint32_t>(n);
  kept_count_++;
  if (!logged_reply_kept_) {
    logged_reply_kept_ = true;
    LOG("first qmap command reply kept: no uplink buffer free%{public}s, %zu bytes",
        usb_.uplink_recovering() ? " (bulk out recovering)" : "", n);
  }
}

// Sends kept replies, oldest first, while uplink buffers can be had (none while bulk OUT recovers).
void CoreHost::send_kept_replies() {
  while (kept_count_ > 0) {
    int slot = usb_.acquire_uplink();
    if (slot < 0) return;
    uint32_t i = kept_head_;
    uint32_t n = kept_reply_len_[i];
    memcpy(usb_.uplink_buffer(slot), kept_reply_[i], n);
    kept_head_ = (kept_head_ + 1) % kKeptReplies;
    kept_count_--;
    send_reply(slot, n);
  }
}

void CoreHost::drop_kept_replies() {
  counters_.command_reply_drops += kept_count_;
  kept_count_ = 0;
  kept_head_ = 0;
}

// Sends a reply from a reserved uplink buffer; the transfer carries no IP packet.
void CoreHost::send_reply(int slot, size_t len) {
  slot_packets_[slot] = 0;
  slot_bytes_[slot] = 0;
  if (usb_.send_uplink(slot, static_cast<uint32_t>(len))) {
    counters_.command_replies++;
  } else {
    counters_.command_reply_drops++;
  }
}

bool CoreHost::take_restart_wanted() {
  bool r = restart_wanted_;
  restart_wanted_ = false;
  return r;
}

void CoreHost::set_paused(bool paused) {
  if (paused == paused_) return;
  paused_ = paused;
  pause_timed_ = false;
  pause_expired_ = false;
  if (!paused) resumed_ = true;
  LOG("uplink %{public}s", paused ? "paused (flow disable)" : "resumed");
}

bool CoreHost::take_uplink_resumed() {
  bool r = resumed_;
  resumed_ = false;
  return r;
}

void CoreHost::on_bulk_out_done(int slot, bool ok) {
  if (slot < 0 || slot >= static_cast<int>(kUplinkSlots)) return;
  if (ok) {
    counters_.tx_transfers++;
    counters_.tx_packets += slot_packets_[slot];
    counters_.tx_bytes += slot_bytes_[slot];
  } else {
    counters_.tx_drop_usb += slot_packets_[slot];
  }
  slot_packets_[slot] = 0;
  slot_bytes_[slot] = 0;
  // The freed buffer goes to a kept command reply first: this runs before the driver restarts its
  // drain (RMNetDriver::OnBulkOutDone). Not after a failure, which may start a stall recovery; once
  // USB has decided it did not, or a recovery has ended, uplink_usable does it instead.
  if (ok) send_kept_replies();
}

void CoreHost::uplink_usable() { send_kept_replies(); }

// handle_tx has no side effect when it answers Forward (core/src/ethernet.cpp: the IPv4 and IPv6
// paths only read the frame and return a span into it; neither the emulator's state nor reply_
// changes), so a frame refused for want of a buffer can be offered again with the same result.
bool CoreHost::transmit(const uint8_t* frame, size_t len) {
  if (!data_up_) {
    counters_.tx_drop_link_down++;
    return true;
  }
  rmnet::TxResult r = eth_.handle_tx(frame, len, reply_, sizeof reply_);
  switch (r.action) {
    case rmnet::TxAction::Drop:
      counters_.tx_drop_filtered++;
      return true;
    case rmnet::TxAction::Reply:
      deliver_frame(reply_, r.reply_len);
      return true;
    case rmnet::TxAction::Forward:
      return forward(r.ip.data, r.ip.len);
  }
  return true;
}

// Into the open uplink buffer; when it is full, it is sent and the packet goes into a new one.
// False, with nothing added or counted, when no buffer can be opened because all are in flight;
// the buffer sent to make room stays in flight, and the packet goes into a new one next time.
bool CoreHost::forward(const uint8_t* ip, size_t len) {
  uint8_t mux = rmnet::SessionConfig{}.mux_id;
  if (uplink_slot_ < 0 && !open_uplink()) return count_no_uplink();
  if (!agg_.add(mux, ip, len)) {
    bool was_empty = agg_.count() == 0;
    send_uplink();
    if (was_empty) {
      counters_.tx_drop_too_big++;
      return true;
    }
    if (!open_uplink()) return count_no_uplink();
    if (!agg_.add(mux, ip, len)) {
      counters_.tx_drop_too_big++;
      return true;
    }
  }
  slot_packets_[uplink_slot_]++;
  slot_bytes_[uplink_slot_] += len;
  return true;
}

// No uplink buffer could be had: what transmit returns then. While bulk OUT recovers, the frame is
// dropped and counted (true: taken). Otherwise every buffer is in flight and the frame waits for
// one (false: not taken, nothing counted).
bool CoreHost::count_no_uplink() {
  if (usb_.uplink_recovering()) {
    counters_.tx_drop_recovering++;
    return true;
  }
  return false;
}

bool CoreHost::open_uplink() {
  int slot = usb_.acquire_uplink();
  if (slot < 0) return false;
  uplink_slot_ = slot;
  slot_packets_[slot] = 0;
  slot_bytes_[slot] = 0;
  agg_ = rmnet::QmapAggregator(usb_.uplink_buffer(slot), ul_size_, ul_datagrams_, usb_.bulk_out_packet_size());
  return true;
}

void CoreHost::send_uplink() {
  int slot = uplink_slot_;
  if (slot < 0) return;
  uplink_slot_ = -1;
  size_t n = agg_.finish();
  if (n == 0) {
    usb_.release_uplink(slot);
    return;
  }
  if (!usb_.send_uplink(slot, static_cast<uint32_t>(n))) {
    counters_.tx_drop_usb += slot_packets_[slot];
    slot_packets_[slot] = 0;
    slot_bytes_[slot] = 0;
  }
}

void CoreHost::flush_uplink() { send_uplink(); }

// The open uplink buffer is given back unsent; its packets count as dropped for link down.
void CoreHost::drop_open_uplink() {
  int slot = uplink_slot_;
  if (slot < 0) return;
  uplink_slot_ = -1;
  counters_.tx_drop_link_down += slot_packets_[slot];
  slot_packets_[slot] = 0;
  slot_bytes_[slot] = 0;
  usb_.release_uplink(slot);
}
