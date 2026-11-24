// Drives Core for the driver: plain C++, run on the driver's Default queue.
//
// It owns the Session, the EthernetEmulator and the QmapAggregator, sends the session's QMI
// messages through a UsbPort (UsbIo in the driver, a fake in tests/driver), and logs the session's
// progress. Link changes are only recorded while Core is running; the driver applies them after
// the Core call returns (take_link_change, then data_link_down / data_link_up), so nothing it
// does can re-enter the Session from a delegate callback.
//
// The data path. Downlink: each bulk transfer is split into QMAP frames; a data frame on the
// session's mux becomes an Ethernet frame in a receive packet from the RxSink; a command frame is
// answered on the uplink, and flow disable or enable pauses or resumes the uplink. Uplink: each
// frame the host sends goes through the emulator; a reply (ARP, DHCP, neighbour discovery) goes
// back to the host as a received frame, an IP packet goes into the aggregator, whose buffer is
// sent when it is full or when the driver says the transmit queue is empty (flush_uplink). A
// packet that finds every uplink buffer in flight is not taken (transmit returns false); the
// driver keeps the frame and offers it again once a transfer completes.
// A reply to a QMAP command that finds no uplink buffer free (all in flight, or bulk OUT
// recovering) is kept, up to kKeptReplies in order, and sent when a transfer completes
// successfully (on_bulk_out_done) or the uplink is usable again after a failed transfer or a
// recovery (uplink_usable), in both cases before the driver restarts its drain, or on data_tick.
// Kept replies are discarded, and counted as reply drops, on a link down, at stop and on
// drop_kept_replies.
// A pause that no flow enable lifts within kPauseMaxMs of link-up time (timed by data_tick) makes CoreHost ask the
// driver for a session restart (take_restart_wanted); it never restarts the session itself.
// No per-packet logging: counters carry it. A WDS Get Current Settings reply (the liveness probe's,
// every 30 s) is logged only when its settings differ from the ones last logged for that family.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/ethernet.h"
#include "rmnet/qmap.h"
#include "rmnet/session.h"
#include "usb_port.h"

// Where received frames go: the driver's receive packets.
class RxSink {
 public:
  // The buffer of an empty receive packet and its capacity, or nullptr when none is available.
  // Until rx_commit, the same packet is returned again.
  virtual uint8_t* rx_buffer(size_t* cap) = 0;
  // The buffer last returned now holds a frame of `len` bytes: hand it to the host.
  virtual void rx_commit(size_t len) = 0;

 protected:
  ~RxSink() = default;
};

// Data path counters, published by the driver. Packets and bytes count IP packets (without the
// Ethernet or QMAP header) that crossed between the host and the modem.
struct DataCounters {
  uint64_t rx_packets, rx_bytes;  // modem -> host
  uint64_t tx_packets, tx_bytes;  // host -> modem, counted when their transfer completed
  uint64_t rx_transfers;          // bulk reads that completed
  uint64_t rx_empty_transfers;    // of those, ones with no frame (zero length or all-zero filler)
  uint64_t tx_transfers;          // uplink transfers that completed
  uint64_t replies;               // frames the emulator sent the host (ARP, DHCP, ND, adverts)
  // Downlink drops, by cause.
  uint64_t rx_drop_link_down;  // data frame while the link is down
  uint64_t rx_drop_no_packet;  // no receive packet available
  uint64_t rx_drop_filtered;   // the emulator refused it (not IPv4 or IPv6, or a router advert)
  uint64_t rx_drop_too_big;    // larger than a receive packet
  uint64_t rx_drop_other_mux;  // a data frame on another mux ID
  uint64_t rx_drop_bad_qmap;   // malformed or truncated QMAP: the rest of the transfer
  // Uplink drops, by cause.
  uint64_t tx_drop_link_down;  // frame while the link is down
  uint64_t tx_drop_filtered;   // the emulator dropped it (multicast, broadcast, no address family)
  uint64_t tx_drop_busy;       // all uplink buffers in flight; nothing counts it now (such a frame
                               // waits in the driver: transmit returns false)
  uint64_t tx_drop_recovering; // bulk OUT is recovering from a stall
  uint64_t tx_drop_too_big;    // does not fit an empty uplink buffer
  uint64_t tx_drop_usb;        // its transfer failed or could not be submitted
  uint64_t reply_drop_no_packet;  // an emulator reply, with no receive packet available
  // QMAP commands from the modem.
  uint64_t commands;           // command frames received
  uint64_t flow_disable;
  uint64_t flow_enable;
  uint64_t command_replies;    // replies sent
  uint64_t command_reply_drops;  // replies not sent: none could be kept (store full, or too big
                                 // for a kept slot), the send failed, or a kept one was discarded
  uint64_t uplink_pause_timeouts;  // pauses not lifted within kPauseMaxMs (each asked for a restart)
};

enum : uint32_t {
  kKeptReplies = 4,       // command replies kept while no uplink buffer is free
  kKeptReplyBytes = 64,   // each: a flow control reply is 4 + 16 bytes; larger ones are not kept
};

// The longest the uplink may stay paused by a QMAP flow disable before the session is restarted.
enum : uint32_t { kPauseMaxMs = 30000 };

class CoreHost final : public rmnet::SessionDelegate {
 public:
  // profile: the data profile the session asks the modem for (SessionConfig::profile).
  // flow_control: whether the session asks the modem for in-band flow control
  // (SessionConfig::flow_control).
  // qmi_interface: the number of the USB interface the session runs on, which its requests name
  // (SessionConfig::iface_number; 4 on the RM520N-GL).
  // ipv6_only_preferred: whether the emulator's DHCP server may answer with the IPv6-Only
  // Preferred option (rmnet::EthernetEmulator, core/src/dhcp.cpp); off unless the installer
  // turned it on.
  CoreHost(UsbPort& usb, RxSink& rx, const rmnet::MacPair& macs, uint8_t profile, bool flow_control,
           uint8_t qmi_interface, bool ipv6_only_preferred = false);
  CoreHost(const CoreHost&) = delete;
  CoreHost& operator=(const CoreHost&) = delete;

  void start(uint64_t now_ms);
  void stop();
  void tick(uint64_t now_ms);
  void on_control(const uint8_t* data, size_t len, uint64_t now_ms);  // one QMUX frame
  // Stops the session and starts it again from sync. Safe whatever the session's state: idle (it
  // only starts), starting, up or in backoff. In between, the data path's link state is cleared as
  // a link down clears it (data_link_down): the emulator loses its link, the pause is lifted (so
  // take_uplink_resumed is true afterwards if the uplink was paused, and the driver's drain runs),
  // and the kept command replies are discarded and counted as reply drops. The open uplink buffer
  // is released unsent, its packets counted as tx_drop_link_down. A pending restart wish is
  // cleared. If the link was up, take_link_change then reports a link down (and no up: the new
  // session reports its own link up when the call comes up). Frames the driver keeps (its transmit
  // hold) go through transmit afterwards as usual and are dropped as link down. The caller applies
  // the link change afterwards, as after any Core call; must not be called from a Core callback.
  void restart(uint64_t now_ms);

  // Link changes since the last call, in the order to apply them: down first (the link went
  // down), then up (the link is up with link_config(); also a family added while already up).
  struct LinkChange {
    bool down;
    bool up;
  };
  LinkChange take_link_change();
  const rmnet::LinkConfig& link_config() const { return link_; }

  rmnet::SessionState state() const { return session_.state(); }
  bool flow_control_asked() const { return session_.flow_control_asked(); }
  bool flow_control_refused() const { return session_.flow_control_refused(); }
  // No later Set Data Format request of this session asks for flow control (Session::give_up_flow_control).
  // Sends nothing; the driver calls it before the restart that a pause reaching kPauseMaxMs asks for,
  // and logs the give-up itself, so note_flow_refusal must not log it as the modem's refusal.
  void give_up_flow_control() {
    session_.give_up_flow_control();
    logged_flow_refused_ = true;
  }

  // The data path. None of these calls the Session.
  // Applying a link change: down clears the emulator's link and the uplink pause; up (also again
  // while up) gives the emulator the settings, sizes the bulk transfers from the granted data
  // format, starts the bulk reads, and sends a router advertisement if IPv6 is new.
  void data_link_down();
  void data_link_up(uint64_t now_ms);
  // Sends kept command replies a buffer is free for; times a pause while the data link is up
  // (kPauseMaxMs, then a restart is wanted); then the periodic router advertisement, every kRouterAdvertMs while up with IPv6.
  void data_tick(uint64_t now_ms);
  // True once after data_tick found the uplink paused for kPauseMaxMs: the driver should restart
  // the session (restart), after the Core call has returned. Only data_tick sets it.
  bool take_restart_wanted();
  void on_bulk_in(const uint8_t* data, size_t len);
  void on_bulk_out_done(int slot, bool ok);
  // USB says the uplink is usable again: a failed transfer freed its buffer and started no stall
  // recovery, or a recovery ended (UsbIoListener::on_uplink_usable). Sends the kept command replies
  // the free buffers allow, oldest first, and nothing else; the driver calls it before its drain.
  void uplink_usable();
  // One frame from the host. False only when it needs an uplink buffer and all are in flight:
  // nothing is consumed or counted then, and offering the same frame again later gives the same
  // result as offering it once. True in every other case (forwarded, answered, dropped and
  // counted, link down, bulk OUT recovering).
  bool transmit(const uint8_t* frame, size_t len);
  void flush_uplink();  // the transmit queue is empty, or the driver stopped taking frames from it
  bool uplink_paused() const { return paused_; }
  // True once after the uplink was resumed (flow enable, or link down while paused).
  bool take_uplink_resumed();
  const DataCounters& counters() const { return counters_; }
  uint32_t kept_replies() const { return kept_count_; }  // command replies waiting for a buffer
  // Discards the kept command replies (USB failed: they will never find a buffer).
  void drop_kept_replies();

  // SessionDelegate: called by the session from inside start, stop, on_qmi and tick.
  void send_qmi(const uint8_t* data, size_t len) override;
  void link_up(const rmnet::LinkConfig& cfg) override;
  void link_down() override;

 private:
  void note_state();
  void note_flow_refusal();
  void log_sent(const uint8_t* data, size_t len);
  void log_received(const uint8_t* data, size_t len);
  void forget_logged_settings();
  uint8_t family_of(uint8_t wds_client) const;
  void deliver_ip(const uint8_t* ip, size_t len);
  void deliver_frame(const uint8_t* frame, size_t len);
  void send_router_advert();
  void on_command(const rmnet::QmapFrame& f);
  void keep_reply(const rmnet::QmapFrame& f);
  void send_kept_replies();
  void send_reply(int slot, size_t len);
  bool forward(const uint8_t* ip, size_t len);
  bool open_uplink();
  bool count_no_uplink();
  void send_uplink();
  void drop_open_uplink();
  void set_paused(bool paused);

  UsbPort& usb_;
  RxSink& rx_;
  rmnet::Session session_;
  rmnet::EthernetEmulator eth_;
  rmnet::QmapAggregator agg_;  // over the reserved uplink buffer uplink_slot_
  int uplink_slot_;            // -1 when no buffer is being filled
  uint32_t slot_packets_[kUplinkSlots];  // what each uplink transfer carries, for the counters
  uint64_t slot_bytes_[kUplinkSlots];
  uint32_t ul_size_;       // granted uplink transfer size, at most kMaxUplink
  uint32_t ul_datagrams_;  // granted datagrams per uplink transfer
  bool data_up_;           // the link as last applied
  bool data_v6_;           // ... and whether it had IPv6
  bool paused_;            // the modem sent flow disable
  bool resumed_;
  bool pause_timed_;       // paused_, and pause_start_ms_ is the first data_tick that saw it
  bool pause_expired_;     // this pause already asked for a restart
  uint64_t pause_start_ms_;
  bool restart_wanted_;
  uint64_t last_advert_ms_;
  DataCounters counters_;
  bool logged_first_command_;
  bool logged_reply_kept_;
  // Kept command replies: a ring of kKeptReplies, oldest at kept_head_. Never the read buffer the
  // request sits in, so qmap_build_command_reply's no-overlap rule holds.
  uint8_t kept_reply_[kKeptReplies][kKeptReplyBytes];
  uint32_t kept_reply_len_[kKeptReplies];
  uint32_t kept_head_;
  uint32_t kept_count_;
  uint8_t reply_[2048];  // emulator replies, before they are copied into a receive packet
  rmnet::SessionState logged_state_;
  rmnet::LinkConfig link_;
  LinkChange change_;
  uint32_t syncs_sent_;
  bool logged_flow_refused_;  // the session's flow control refusal (kept for its life) was logged
  // The IP family (4 or 6) each WDS client asked for in Start Network, for the log.
  uint8_t start_client_[2];
  bool start_client_known_[2];
  // The settings last logged for each family (IPv4, IPv6) in this session: a Get Current Settings
  // reply is logged only when its settings differ (the liveness probe repeats it every 30 s).
  // Forgotten at start and restart, so a session's first reply is always logged.
  rmnet::RuntimeSettings logged_settings_[2];
  bool logged_settings_known_[2];
};

const char* SessionStateName(rmnet::SessionState s);

enum : uint32_t { kRouterAdvertMs = 600 * 1000 };
