// CoreHost on the host: a fake UsbPort and RxSink stand in for the driver's USB and receive packets.
// The tests cover the transmit hold (a frame refused while every uplink buffer is in flight), the
// kept QMAP command replies, the pause limit (kPauseMaxMs), the QMI interface number the session
// puts in its requests, and the IPv6-only preferred setting the emulator is given.
#include "minitest.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <memory>
#include <vector>

#include "captures.h"
#include "core_host.h"
#include "frames.h"
#include "rmnet/ethernet.h"
#include "rmnet/qmap.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/session.h"

namespace {

// kUplinkSlots buffers in memory, each free, reserved or in flight as on UsbIo. Each send_uplink
// payload and release_uplink slot is recorded. occupy_all puts every free buffer in flight, as
// transfers the test did not make would hold them; complete frees one buffer at a time.
class FakeUsb final : public UsbPort {
 public:
  struct Sent {
    int slot;
    std::vector<uint8_t> bytes;
  };
  std::vector<Sent> uplinks;                // send_uplink, in the order sent
  std::vector<int> releases;                // release_uplink
  std::vector<std::vector<uint8_t>> qmi;    // send
  std::vector<uint32_t> bulk_starts;        // start_bulk

  // Every free buffer goes in flight: acquire_uplink gives none until a transfer completes.
  void occupy_all() {
    for (State& s : state_) {
      if (s == Free) s = InFlight;
    }
  }
  // The transfer from `slot` completed: that buffer, and only it, is free again. The test then
  // tells CoreHost (on_bulk_out_done), as the driver does (Rig::complete, Rig::fail).
  void complete(int slot) {
    REQUIRE(slot >= 0 && slot < static_cast<int>(kUplinkSlots) && state_[slot] == InFlight);
    state_[slot] = Free;
  }

  bool send(const uint8_t* data, size_t len) override {
    qmi.emplace_back(data, data + len);
    return true;
  }
  void start_bulk(uint32_t read_len) override { bulk_starts.push_back(read_len); }
  int acquire_uplink() override {
    for (int i = 0; i < static_cast<int>(kUplinkSlots); i++) {
      if (state_[i] == Free) {
        state_[i] = Reserved;
        return i;
      }
    }
    return -1;
  }
  uint8_t* uplink_buffer(int slot) const override { return buffers_.get() + static_cast<size_t>(slot) * kMaxUplink; }
  // As on UsbIo, false for a slot that is not reserved; nothing is recorded then.
  bool send_uplink(int slot, uint32_t len) override {
    if (slot < 0 || slot >= static_cast<int>(kUplinkSlots) || state_[slot] != Reserved) return false;
    const uint8_t* b = uplink_buffer(slot);
    uplinks.push_back({slot, std::vector<uint8_t>(b, b + len)});
    state_[slot] = InFlight;
    return true;
  }
  void release_uplink(int slot) override {
    releases.push_back(slot);
    state_[slot] = Free;
  }
  bool uplink_recovering() const override { return false; }
  uint16_t bulk_out_packet_size() const override { return 512; }

 private:
  enum State { Free, Reserved, InFlight };
  State state_[kUplinkSlots] = {};
  std::unique_ptr<uint8_t[]> buffers_{new uint8_t[kUplinkSlots * kMaxUplink]()};
};

// One receive packet, always available; every frame committed is recorded.
class FakeRx final : public RxSink {
 public:
  std::vector<std::vector<uint8_t>> frames;
  uint8_t* rx_buffer(size_t* cap) override {
    *cap = sizeof buf_;
    return buf_;
  }
  void rx_commit(size_t len) override { frames.emplace_back(buf_, buf_ + len); }

 private:
  uint8_t buf_[2048];
};

// The link the recorded IPv4 call came up with: its Get Current Settings reply and the modem's Set
// Data Format answer (QMAP both ways, 16384-byte uplink transfers of up to 32 datagrams).
rmnet::LinkConfig recorded_link() {
  rmnet::LinkConfig cfg{};
  std::vector<uint8_t> settings = hex(kWdsSettings4Resp);
  std::vector<uint8_t> format = hex(kWdaSetFormatResp);
  rmnet::QmiMessage m{};
  bool ok = rmnet::qmi_decode({settings.data(), settings.size()}, &m) &&
            rmnet::parse_wds_current_settings(m, &cfg.settings) &&
            rmnet::qmi_decode({format.data(), format.size()}, &m) && rmnet::parse_wda_data_format(m, &cfg.format);
  if (!ok || !cfg.settings.has_v4 || cfg.settings.has_v6 || !rmnet::data_format_usable(cfg.format)) {
    fprintf(stderr, "recorded_link(): the recorded replies do not give a usable IPv4 link\n");
    abort();
  }
  return cfg;
}

// CoreHost over the fakes, its data link brought up as the driver brings it up: the session's
// link_up, then take_link_change and data_link_up. The session itself is never started.
struct Rig {
  FakeUsb usb;
  FakeRx rx;
  CoreHost core;

  Rig() : core(usb, rx, rmnet::derive_macs("bfeed1a5"), 1, true, 4) {
    core.link_up(recorded_link());
    CoreHost::LinkChange c = core.take_link_change();
    CHECK(c.up);
    CHECK(!c.down);
    core.data_link_up(0);
    CHECK_EQ(usb.bulk_starts.size(), 1u);
  }
  void transmit_ok(const std::vector<uint8_t>& f) { CHECK(core.transmit(f.data(), f.size())); }
  bool transmit(const std::vector<uint8_t>& f) { return core.transmit(f.data(), f.size()); }
  void bulk_in(const std::vector<uint8_t>& t) { core.on_bulk_in(t.data(), t.size()); }
  // The transfer from `slot` completed, as the driver reports it: its buffer is free first.
  void complete(int slot) {
    usb.complete(slot);
    core.on_bulk_out_done(slot, true);
  }
  // The transfer from `slot` failed (a timeout, say): its buffer is free, and CoreHost gives it to
  // no kept reply (on_bulk_out_done sends none after a failure).
  void fail(int slot) {
    usb.complete(slot);
    core.on_bulk_out_done(slot, false);
  }
};

// An Ethernet frame from the host to the router carrying a unicast IPv4 UDP datagram; `tag` is its
// one payload byte.
std::vector<uint8_t> host_frame(uint8_t tag) { return ipv4_udp("10.102.246.230", "8.8.8.8", 40000, 53, {tag}); }

// The IP packet inside a frame host_frame made (no Ethernet padding).
std::vector<uint8_t> ip_of(const std::vector<uint8_t>& frame) { return {frame.begin() + 14, frame.end()}; }

// The IP packets the uplink transfers carried, in the order sent.
std::vector<std::vector<uint8_t>> sent_packets(const FakeUsb& usb) {
  std::vector<std::vector<uint8_t>> out;
  for (const FakeUsb::Sent& t : usb.uplinks) {
    size_t off = 0;
    rmnet::QmapFrame f;
    while (rmnet::qmap_next({t.bytes.data(), t.bytes.size()}, &off, &f) == rmnet::QmapStatus::Ok) {
      if (!f.is_command) out.emplace_back(f.payload.data, f.payload.data + f.payload.len);
    }
  }
  return out;
}

// A QMAP flow control request from the modem on mux 0x81 (as in test_qmap.cpp), `tag` its last byte.
std::vector<uint8_t> flow_request(uint8_t name, uint8_t tag) {
  return {0x80, 0x81, 0x00, 0x08, name, rmnet::kQmapCmdRequest, 0x00, 0x00, 0x00, 0x00, 0x00, tag};
}

}  // namespace

TEST(transmit_is_refused_while_every_uplink_buffer_is_in_flight_and_the_same_frame_goes_through_later) {
  Rig r;
  std::vector<uint8_t> f = host_frame(1);
  r.usb.occupy_all();
  CHECK(!r.transmit(f));
  CHECK(!r.transmit(f));  // offered again while still busy: the same answer
  DataCounters none{};
  CHECK(memcmp(&r.core.counters(), &none, sizeof none) == 0);
  CHECK(r.usb.uplinks.empty());

  r.complete(6);  // one transfer completes: its buffer is the only one free
  r.transmit_ok(f);
  CHECK(r.usb.uplinks.empty());  // in the open buffer until the queue is empty
  r.core.flush_uplink();
  REQUIRE(r.usb.uplinks.size() == 1u);
  CHECK_EQ(r.usb.uplinks[0].slot, 6);
  std::vector<std::vector<uint8_t>> sent = sent_packets(r.usb);
  REQUIRE(sent.size() == 1u);
  CHECK(sent[0] == ip_of(f));

  r.complete(r.usb.uplinks[0].slot);
  CHECK_EQ(r.core.counters().tx_packets, 1u);
  CHECK_EQ(r.core.counters().tx_bytes, ip_of(f).size());
}

TEST(frames_reach_the_modem_in_the_order_offered) {
  Rig r;
  std::vector<uint8_t> first = host_frame(1), second = host_frame(2), third = host_frame(3);
  r.transmit_ok(first);
  r.core.flush_uplink();  // the queue ran empty: the first frame's transfer is in flight
  r.usb.occupy_all();     // and so are the other buffers
  CHECK(!r.transmit(second));  // the driver keeps it ...
  REQUIRE(r.usb.uplinks.size() == 1u);
  r.complete(r.usb.uplinks[0].slot);  // ... until the first frame's transfer completes ...
  r.transmit_ok(second);              // ... and offers it again before the third
  r.transmit_ok(third);
  r.core.flush_uplink();
  std::vector<std::vector<uint8_t>> sent = sent_packets(r.usb);
  REQUIRE(sent.size() == 3u);
  CHECK(sent[0] == ip_of(first));
  CHECK(sent[1] == ip_of(second));
  CHECK(sent[2] == ip_of(third));
}

TEST(a_command_reply_is_kept_while_no_buffer_is_free_and_sent_on_the_next_completion) {
  Rig r;
  r.usb.occupy_all();
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 0x2a));
  CHECK_EQ(r.core.kept_replies(), 1u);
  CHECK(r.usb.uplinks.empty());

  r.complete(3);
  CHECK_EQ(r.core.kept_replies(), 0u);
  REQUIRE(r.usb.uplinks.size() == 1u);
  CHECK_EQ(r.usb.uplinks[0].slot, 3);  // in the buffer that transfer freed
  CHECK_BYTES(r.usb.uplinks[0].bytes, "80 81 00 08 01 01 00 00 00 00 00 2a");  // the ACK
  CHECK_EQ(r.core.counters().command_replies, 1u);
  CHECK_EQ(r.core.counters().command_reply_drops, 0u);
}

TEST(at_most_four_replies_are_kept_and_the_fifth_counts_as_a_reply_drop) {
  Rig r;
  r.usb.occupy_all();
  for (uint8_t tag = 1; tag <= 5; tag++) r.bulk_in(flow_request(rmnet::kQmapFlowDisable, tag));
  CHECK_EQ(r.core.kept_replies(), 4u);
  CHECK_EQ(r.core.counters().commands, 5u);
  CHECK_EQ(r.core.counters().command_reply_drops, 1u);

  // Each completion frees one buffer, which takes the oldest kept reply; the rest stay kept until
  // further completions.
  const int freed[] = {5, 2};
  for (size_t k = 0; k < 2; k++) {
    r.complete(freed[k]);
    CHECK_EQ(r.core.kept_replies(), 3 - k);
    REQUIRE(r.usb.uplinks.size() == k + 1);
    CHECK_EQ(r.usb.uplinks[k].slot, freed[k]);
    CHECK_EQ(r.usb.uplinks[k].bytes.back(), k + 1);
  }
  CHECK_EQ(r.core.counters().command_replies, 2u);

  // A failed transfer's buffer goes to no reply (on_bulk_out_done sends none after a failure), so
  // the next completion finds two buffers free: the last two kept go out together, oldest first.
  r.fail(7);
  CHECK_EQ(r.core.kept_replies(), 2u);
  CHECK_EQ(r.usb.uplinks.size(), 2u);
  r.complete(0);
  CHECK_EQ(r.core.kept_replies(), 0u);
  REQUIRE(r.usb.uplinks.size() == 4u);
  CHECK_EQ(r.usb.uplinks[2].bytes.back(), 3u);
  CHECK_EQ(r.usb.uplinks[3].bytes.back(), 4u);

  // The fifth never goes out: a later completion sends nothing.
  r.complete(r.usb.uplinks[0].slot);
  CHECK_EQ(r.usb.uplinks.size(), 4u);
  CHECK_EQ(r.core.counters().command_replies, 4u);
  CHECK_EQ(r.core.counters().command_reply_drops, 1u);
}

TEST(kept_replies_go_out_oldest_first_on_uplink_usable_after_failed_transfers) {
  Rig r;
  r.usb.occupy_all();
  for (uint8_t tag = 1; tag <= 3; tag++) r.bulk_in(flow_request(rmnet::kQmapFlowDisable, tag));
  REQUIRE(r.core.kept_replies() == 3u);

  // Two transfers fail (timeouts, say): their buffers are free, and on_bulk_out_done gives them to
  // no kept reply, since a failure may start a stall recovery.
  r.fail(4);
  r.fail(1);
  CHECK_EQ(r.core.kept_replies(), 3u);
  CHECK(r.usb.uplinks.empty());

  // USB then says the uplink is usable (no recovery started): the two oldest replies take the two
  // free buffers, in order, and the third stays kept.
  r.core.uplink_usable();
  CHECK_EQ(r.core.kept_replies(), 1u);
  REQUIRE(r.usb.uplinks.size() == 2u);
  CHECK_EQ(r.usb.uplinks[0].slot, 1);
  CHECK_BYTES(r.usb.uplinks[0].bytes, "80 81 00 08 01 01 00 00 00 00 00 01");  // the oldest one's ACK
  CHECK_EQ(r.usb.uplinks[1].slot, 4);
  CHECK_BYTES(r.usb.uplinks[1].bytes, "80 81 00 08 01 01 00 00 00 00 00 02");
  CHECK_EQ(r.core.counters().command_replies, 2u);
  CHECK_EQ(r.core.counters().command_reply_drops, 0u);

  // With no buffer free it sends nothing; the next completion sends the last one.
  r.core.uplink_usable();
  CHECK_EQ(r.usb.uplinks.size(), 2u);
  r.complete(6);
  CHECK_EQ(r.core.kept_replies(), 0u);
  REQUIRE(r.usb.uplinks.size() == 3u);
  CHECK_EQ(r.usb.uplinks[2].bytes.back(), 3u);
}

TEST(kept_replies_are_dropped_and_counted_on_link_down) {
  Rig r;
  r.usb.occupy_all();
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  r.bulk_in(flow_request(rmnet::kQmapFlowEnable, 2));
  CHECK_EQ(r.core.kept_replies(), 2u);

  r.core.link_down();  // the session reports it; the driver applies it after the Core call
  CHECK(r.core.take_link_change().down);
  r.core.data_link_down();
  CHECK_EQ(r.core.kept_replies(), 0u);
  CHECK_EQ(r.core.counters().command_reply_drops, 2u);

  // Every transfer completes, so every buffer is free; neither the completions nor a tick send one.
  for (int slot = 0; slot < static_cast<int>(kUplinkSlots); slot++) r.complete(slot);
  r.core.data_tick(1000);
  CHECK(r.usb.uplinks.empty());
  CHECK_EQ(r.core.counters().command_replies, 0u);
}

TEST(a_pause_past_kPauseMaxMs_asks_for_one_restart) {
  Rig r;
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  REQUIRE(r.core.uplink_paused());
  r.core.data_tick(1000);  // the first tick that sees the pause times it
  r.core.data_tick(1000 + kPauseMaxMs - 1);
  CHECK(!r.core.take_restart_wanted());
  r.core.data_tick(1000 + kPauseMaxMs);
  CHECK(r.core.take_restart_wanted());
  CHECK(!r.core.take_restart_wanted());
  r.core.data_tick(1000 + 2 * kPauseMaxMs);  // the same pause asks only once
  CHECK(!r.core.take_restart_wanted());
  CHECK_EQ(r.core.counters().uplink_pause_timeouts, 1u);
}

TEST(restart_lifts_the_pause_and_drops_the_kept_replies) {
  Rig r;
  r.usb.occupy_all();
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  REQUIRE(r.core.uplink_paused());
  REQUIRE(r.core.kept_replies() == 1u);
  REQUIRE(r.usb.qmi.empty());  // the Rig never starts the session: nothing on the control pipe yet

  r.core.restart(5000);
  CHECK(!r.core.uplink_paused());
  CHECK(r.core.take_uplink_resumed());
  CHECK_EQ(r.core.kept_replies(), 0u);
  CHECK_EQ(r.core.counters().command_reply_drops, 1u);

  // The new session's first message: a CTL Sync request.
  REQUIRE(!r.usb.qmi.empty());
  rmnet::QmiMessage m{};
  REQUIRE(rmnet::qmi_decode({r.usb.qmi[0].data(), r.usb.qmi[0].size()}, &m));
  CHECK(m.hdr.service == rmnet::QmiService::CTL);
  CHECK(m.hdr.kind == rmnet::QmiKind::Request);
  CHECK_EQ(m.hdr.msg_id, rmnet::kCtlSync);
}

namespace {

// What CoreHost's session sends on the control pipe for QMI interface `qmi_interface`, from its
// start to its Set Data Format request: the recorded CTL Sync and WDA client replies are fed back
// as the driver feeds them, so the third message is that request.
std::vector<std::vector<uint8_t>> sent_up_to_set_data_format(uint8_t qmi_interface) {
  FakeUsb usb;
  FakeRx rx;
  CoreHost core(usb, rx, rmnet::derive_macs("bfeed1a5"), 1, true, qmi_interface);
  core.start(0);
  std::vector<uint8_t> sync = hex(kCtlSyncResp);
  std::vector<uint8_t> wda = hex(kCtlGetWdaResp);
  core.on_control(sync.data(), sync.size(), 10);
  core.on_control(wda.data(), wda.size(), 20);
  return usb.qmi;
}

}  // namespace

TEST(the_session_names_the_qmi_interface_core_host_was_given) {
  // The RM520N-GL's interface 4: the recorded requests, byte for byte.
  std::vector<std::vector<uint8_t>> sent4 = sent_up_to_set_data_format(4);
  REQUIRE(sent4.size() == 3u);
  CHECK(sent4[0] == hex(kCtlSyncReq));
  CHECK(sent4[1] == hex(kCtlGetWdaReq));
  CHECK(sent4[2] == hex(kWdaSetFormatReqFlow));

  // Another interface number, 3: the same request but for the interface in the Endpoint Info TLV
  // (0x17: endpoint type 2, HSUSB, then the interface number, both 32-bit little-endian).
  std::vector<uint8_t> want = hex(kWdaSetFormatReqFlow);
  const uint8_t endpoint4[] = {0x17, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00};
  std::vector<uint8_t>::iterator at = std::search(want.begin(), want.end(), endpoint4, endpoint4 + sizeof endpoint4);
  REQUIRE(at != want.end());
  at[7] = 0x03;
  std::vector<std::vector<uint8_t>> sent3 = sent_up_to_set_data_format(3);
  REQUIRE(sent3.size() == 3u);
  CHECK(sent3[2] == want);
}

// CoreHost gives its emulator the IPv6-only preferred setting it was made with: a DISCOVER asking
// for option 108 (RFC 8925) on a link whose IPv4 address is in 192.0.0.0/29 is offered no address
// with the setting on, and the link's address with it off (core/src/dhcp.cpp, top comment).
// Synthetic fixtures only (frames.h): a made-up serial number and documentation addresses.
TEST(core_host_gives_its_emulator_the_ipv6_only_preferred_setting) {
  for (bool on : {true, false}) {
    FakeUsb usb;
    FakeRx rx;
    rmnet::MacPair macs = rmnet::derive_macs(kSyntheticSerial);
    CoreHost core(usb, rx, macs, 1, true, 4, on);
    rmnet::LinkConfig cfg{};
    cfg.settings = synthetic_clat_link();
    core.link_up(cfg);
    REQUIRE(core.take_link_change().up);
    core.data_link_up(0);
    size_t before = rx.frames.size();  // the router advertisement for the link's IPv6
    std::vector<uint8_t> q = dhcp_from(macs.host, dhcp_client(1, on ? 1 : 2, "", "", {55, 2, 3, 108}));
    CHECK(core.transmit(q.data(), q.size()));
    REQUIRE(rx.frames.size() == before + 1);
    DhcpReply d = parse_dhcp_reply(rx.frames.back().data(), rx.frames.back().size());
    CHECK(d.checksums_ok);
    CHECK_EQ(d.type, 2);
    CHECK_EQ(d.yiaddr, on ? "0.0.0.0" : "192.0.0.2");
    CHECK_EQ(d.v6only, on);
  }
}
