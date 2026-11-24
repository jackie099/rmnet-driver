#include <cstring>

#include "minitest.h"

#include "frames.h"
#include "rmnet/ethernet.h"

TEST(discover_gets_offer_with_modem_settings) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 0x12345678, "", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
  CHECK_BYTES(r, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 00");
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_src, "10.102.246.229"); CHECK_EQ(d.ip_dst, "255.255.255.255");
  CHECK_EQ(d.op, 2); CHECK_EQ(d.xid, 0x12345678u); CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "10.102.246.230");
  CHECK_BYTES(d.chaddr, 6, "02 68 7a 43 12 f6");
  CHECK_EQ(d.server_id, "10.102.246.229"); CHECK_EQ(d.lease, 3600u); CHECK_EQ(d.mask, "255.255.255.252");
  CHECK_EQ(d.router, "10.102.246.229"); CHECK_EQ(d.mtu, 1500);
  REQUIRE(d.dns.size() == 2); CHECK_EQ(d.dns[0], "203.0.113.193");
}
TEST(request_for_our_address_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 7, "10.102.246.230", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "10.102.246.230"); CHECK_EQ(d.lease, 3600u);
}
TEST(renewal_with_ciaddr_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 8, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK_EQ(parse_dhcp_reply(r, t.reply_len).type, 5);
}
TEST(request_for_other_address_gets_nak) {          // macOS re-asking for its old ECM lease
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 9, "192.168.225.141", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 6); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.server_id, "10.102.246.229");
}
TEST(inform_gets_ack_without_lease) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(8, 10, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.dns.size(), 2u);
}
TEST(dhcp_while_link_down_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto s = link_settings(); s.has_v4 = false; e.set_link(&s);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
// A dhcp_client() frame cut to `bootp_len` BOOTP bytes, with the IPv4 total length, IPv4 header
// checksum, UDP length and UDP checksum rewritten to match, so it passes the IPv4 and UDP checks.
static std::vector<uint8_t> refit(std::vector<uint8_t> frame, size_t bootp_len) {
  frame.resize(14 + 20 + 8 + bootp_len);
  uint8_t* ip = frame.data() + 14;
  uint8_t* udp = ip + 20;
  size_t total = 20 + 8 + bootp_len, udp_len = 8 + bootp_len;
  ip[2] = (uint8_t)(total >> 8); ip[3] = (uint8_t)total;
  ip[10] = ip[11] = 0;
  uint16_t c = rmnet::fold_checksum(rmnet::sum16(ip, 20)); ip[10] = (uint8_t)(c >> 8); ip[11] = (uint8_t)c;
  udp[4] = (uint8_t)(udp_len >> 8); udp[5] = (uint8_t)udp_len;
  udp[6] = udp[7] = 0;
  c = rmnet::udp4_checksum(ip + 12, ip + 16, udp, udp_len); if (c == 0) c = 0xffff;
  udp[6] = (uint8_t)(c >> 8); udp[7] = (uint8_t)c;
  return frame;
}
TEST(malformed_dhcp_with_matching_lengths_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 1, "10.102.246.230", "");               // options: cookie, 53 1 3, 50 4 <address>, 255
  size_t bootp = q.size() - 14 - 20 - 8;
  auto whole = refit(q, bootp);                                    // unchanged length: still answered
  CHECK(e.handle_tx(whole.data(), whole.size(), r, sizeof r).action == rmnet::TxAction::Reply);
  auto cut = refit(q, 100);                                        // cut inside BOOTP, before the cookie
  CHECK(e.handle_tx(cut.data(), cut.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto overrun = refit(q, 240 + 3 + 2 + 2);                        // option 50 says 4 bytes, 2 remain
  CHECK(e.handle_tx(overrun.data(), overrun.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto untyped = q; for (size_t i = 0; i < 3; ++i) untyped[14 + 20 + 8 + 240 + i] = 0;  // option 53 becomes padding
  untyped = refit(untyped, bootp);
  CHECK(e.handle_tx(untyped.data(), untyped.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(malformed_dhcp_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  auto no_cookie = q; no_cookie[14 + 20 + 8 + 236] ^= 0xff;
  CHECK(e.handle_tx(no_cookie.data(), no_cookie.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(q.data(), 14 + 20 + 8 + 100, r, sizeof r).action == rmnet::TxAction::Drop);      // cut inside BOOTP
  auto release = dhcp_client(7, 1, "", "10.102.246.230");
  CHECK(e.handle_tx(release.data(), release.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  uint8_t small[100]; CHECK(e.handle_tx(q.data(), q.size(), small, sizeof small).action == rmnet::TxAction::Drop);  // reply buffer too small
}

// Pinned behaviour (the deferred list of 2026-11-13).

TEST(udp_checksum_computing_to_zero_is_sent_as_ffff) {
  // Two DISCOVERs' replies differ only in the xid they echo. With xid 0 the UDP checksum is c; the
  // xid 0000:c adds c to the ones'-complement sum, which then folds to 0xffff, so the checksum
  // computes to 0 and goes out as 0xffff (0 on the wire would mean "no checksum").
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto first = dhcp_client(1, 0, "", "");
  auto t = e.handle_tx(first.data(), first.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  uint16_t c = static_cast<uint16_t>(r[40] << 8 | r[41]);                    // the UDP checksum: 14 + 20 + 6
  CHECK(c != 0xffff);                                                         // an ordinary one
  auto q = dhcp_client(1, c, "", "");
  t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  CHECK_BYTES(r + 40, 2, "ff ff");
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.xid, c); CHECK(d.checksums_ok);                                  // 0xffff checks as 0 would
}

// IPv6-only links (RFC 8925 option 108; core/src/dhcp.cpp, top comment), RFC 2131's server
// identifier and reply destinations. These tests use only the synthetic fixtures (frames.h): a
// made-up serial number and documentation addresses.

static rmnet::MacPair synthetic_macs() { return rmnet::derive_macs(kSyntheticSerial); }
// A DHCP client message (dhcp_client) from the synthetic host's MAC.
static std::vector<uint8_t> client(uint8_t type, uint32_t xid, const char* requested_ip, const char* ciaddr,
                                   const std::vector<uint8_t>& options = {}) {
  return dhcp_from(synthetic_macs().host, dhcp_client(type, xid, requested_ip, ciaddr, options));
}
// Whether a reply frame goes to the synthetic host's MAC and names it in chaddr.
static bool to_synthetic_host(const uint8_t* frame, const DhcpReply& d) {
  rmnet::MacPair m = synthetic_macs();
  return std::memcmp(frame, m.host, 6) == 0 && std::memcmp(d.chaddr, m.host, 6) == 0;
}
static const std::vector<uint8_t> kPrlV6only = {55, 4, 1, 3, 6, 108};  // parameter request list asking for 108
static const std::vector<uint8_t> kPrlPlain = {55, 3, 1, 3, 6};
static const std::vector<uint8_t> kAutoConfigureOn = {116, 1, 1};      // RFC 2563 "auto-configure"
// The options of a and then of b.
static std::vector<uint8_t> both(std::vector<uint8_t> a, const std::vector<uint8_t>& b) {
  a.insert(a.end(), b.begin(), b.end());
  return a;
}

// With option 108 turned on (EthernetEmulator's ipv6_only_preferred).

TEST(v6only_client_on_clat_link_gets_offer_of_no_address) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); REQUIRE(s.has_v6); e.set_link(&s);
  uint8_t r[600];
  auto q = client(1, 0x0badcafe, "", "", both(kPrlV6only, kAutoConfigureOn));
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK(to_synthetic_host(r, d)); CHECK_EQ(d.ip_src, "192.0.0.1"); CHECK_EQ(d.ip_dst, "255.255.255.255");
  CHECK_EQ(d.type, 2); CHECK_EQ(d.xid, 0x0badcafeu); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.server_id, "192.0.0.1");
  CHECK(d.v6only); CHECK_EQ(d.v6only_wait, 1800u); CHECK_EQ(d.auto_configure, 0);
  CHECK_EQ(d.lease, 0u); CHECK_EQ(d.mask, ""); CHECK_EQ(d.router, ""); CHECK_EQ(d.dns.size(), 0u); CHECK_EQ(d.mtu, 0);
}
TEST(v6only_offer_carries_116_only_when_the_client_sent_it) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(1, 2, "", "", kPrlV6only);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK(d.v6only); CHECK_EQ(d.auto_configure, -1);
}
TEST(client_not_asking_for_108_on_clat_link_gets_the_address) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(1, 3, "", "", both(kPrlPlain, kAutoConfigureOn));
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.lease, 3600u); CHECK_EQ(d.mask, "255.255.255.224");
  CHECK_EQ(d.router, "192.0.0.1"); CHECK(!d.v6only); CHECK_EQ(d.auto_configure, -1);
}
TEST(v6only_client_on_native_ipv4_link_gets_the_address) {  // turned on, but the address is not in 192.0.0.0/29
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_link(); REQUIRE(s.has_v6); e.set_link(&s);
  uint8_t r[600];
  auto q = client(1, 4, "", "", both(kPrlV6only, kAutoConfigureOn));
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "198.51.100.10"); CHECK_EQ(d.lease, 3600u); CHECK_EQ(d.router, "198.51.100.9");
  CHECK(!d.v6only); CHECK_EQ(d.auto_configure, -1);
}
TEST(v6only_client_on_clat_link_without_ipv6_gets_the_address) {  // no IPv6: the host has no translator to use
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); s.has_v6 = false; e.set_link(&s);
  uint8_t r[600];
  auto q = client(1, 5, "", "", kPrlV6only);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK(!d.v6only);
}
TEST(v6only_init_reboot_for_the_address_on_clat_link_gets_ack_with_108) {  // RFC 8925 3.3: processed per RFC 2131
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 6, "192.0.0.2", "", kPrlV6only);  // INIT-REBOOT: a lease from an earlier link
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK(to_synthetic_host(r, d)); CHECK_EQ(d.ip_dst, "255.255.255.255");  // no ciaddr
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.lease, 3600u);
  CHECK_EQ(d.server_id, "192.0.0.1"); CHECK_EQ(d.router, "192.0.0.1");
  CHECK(d.v6only); CHECK_EQ(d.v6only_wait, 1800u); CHECK_EQ(d.auto_configure, -1);  // 116 is for offers only
}
TEST(v6only_request_for_another_address_on_clat_link_gets_nak) {  // RFC 2131: not this link's address
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 11, "192.0.0.4", "", kPrlV6only);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 6); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.server_id, "192.0.0.1");
  CHECK(!d.v6only); CHECK_EQ(d.router, "");
}
TEST(v6only_renewal_on_clat_link_gets_ack_with_108) {  // an address in use is not taken away
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 7, "", "192.0.0.2", kPrlV6only);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_dst, "192.0.0.2");  // to ciaddr (RFC 2131 4.1)
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.lease, 3600u);
  CHECK_EQ(d.router, "192.0.0.1"); CHECK(d.v6only); CHECK_EQ(d.v6only_wait, 1800u); CHECK_EQ(d.auto_configure, -1);
}
TEST(plain_request_on_clat_link_still_gets_ack) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 8, "192.0.0.2", "", kPrlPlain);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK(!d.v6only);
}
TEST(inform_on_clat_link_never_carries_108) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(8, 9, "", "192.0.0.2", kPrlV6only);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK(!d.v6only); CHECK_EQ(d.router, "192.0.0.1");
}
TEST(clat_prefix_is_192_0_0_0_slash_29) {
  rmnet::EthernetEmulator e(synthetic_macs(), true); uint8_t r[600];
  auto q = client(1, 10, "", "", kPrlV6only);
  auto s = synthetic_clat_link(); s.v4_addr[3] = 7; e.set_link(&s);  // 192.0.0.7: the last address inside
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.v6only); CHECK_EQ(d.yiaddr, "0.0.0.0");
  s.v4_addr[3] = 8; e.set_link(&s);                                 // 192.0.0.8: the first one outside
  t = e.handle_tx(q.data(), q.size(), r, sizeof r); d = parse_dhcp_reply(r, t.reply_len);
  CHECK(!d.v6only); CHECK_EQ(d.yiaddr, "192.0.0.8");
}

// With option 108 off, as it is unless the installer turns it on. A DS-Lite network reports the
// same link (RFC 6333 section 5.7) and has no NAT64: its host must be leased 192.0.0.2.

TEST(option_108_is_off_by_default) {
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_clat_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(1, 12, "", "", both(kPrlV6only, kAutoConfigureOn));
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.lease, 3600u); CHECK(!d.v6only);
  CHECK_EQ(d.auto_configure, -1);
}
TEST(option_108_off_leases_the_clat_prefix_address_to_a_client_asking_for_108) {
  rmnet::EthernetEmulator e(synthetic_macs(), false); auto s = synthetic_clat_link(); REQUIRE(s.has_v6); e.set_link(&s);
  uint8_t r[600];
  auto discover = client(1, 13, "", "", both(kPrlV6only, kAutoConfigureOn));
  auto t = e.handle_tx(discover.data(), discover.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK(to_synthetic_host(r, d)); CHECK_EQ(d.ip_dst, "255.255.255.255");
  CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.server_id, "192.0.0.1"); CHECK_EQ(d.lease, 3600u);
  CHECK_EQ(d.mask, "255.255.255.224"); CHECK_EQ(d.router, "192.0.0.1"); CHECK_EQ(d.mtu, 1500);
  REQUIRE(d.dns.size() == 2u); CHECK_EQ(d.dns[0], "192.0.2.53"); CHECK_EQ(d.dns[1], "192.0.2.54");
  CHECK(!d.v6only); CHECK_EQ(d.auto_configure, -1);

  std::vector<uint8_t> ours = {54, 4, 192, 0, 0, 1};  // SELECTING: the offer taken names this server
  auto select = client(3, 13, "192.0.0.2", "", both(kPrlV6only, ours));
  t = e.handle_tx(select.data(), select.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "192.0.0.2"); CHECK_EQ(d.lease, 3600u);
  CHECK_EQ(d.router, "192.0.0.1"); CHECK(!d.v6only);

  auto renew = client(3, 14, "", "192.0.0.2", kPrlV6only);
  t = e.handle_tx(renew.data(), renew.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_dst, "192.0.0.2"); CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "192.0.0.2");
  CHECK(!d.v6only);
}

// RFC 2131: a REQUEST for another server (section 3.1, step 4), and where replies go (section 4.1).

TEST(request_naming_another_server_is_ignored) {
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_link(); e.set_link(&s); uint8_t r[600];
  auto other = client(3, 15, "198.51.100.10", "", {54, 4, 198, 51, 100, 200});
  CHECK(e.handle_tx(other.data(), other.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto bad_length = client(3, 15, "198.51.100.10", "", {54, 3, 198, 51, 100});
  CHECK(e.handle_tx(bad_length.data(), bad_length.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto ours = client(3, 15, "198.51.100.10", "", {54, 4, 198, 51, 100, 9});
  auto t = e.handle_tx(ours.data(), ours.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  CHECK_EQ(parse_dhcp_reply(r, t.reply_len).type, 5);
}
TEST(renewal_ack_goes_to_ciaddr) {
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 16, "", "198.51.100.10");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK(to_synthetic_host(r, d)); CHECK_EQ(d.ip_src, "198.51.100.9");
  CHECK_EQ(d.ip_dst, "198.51.100.10"); CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "198.51.100.10");
}
TEST(inform_ack_goes_to_ciaddr) {  // RFC 2131 4.3.5
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(8, 17, "", "198.51.100.10");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_dst, "198.51.100.10"); CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "0.0.0.0");
}
TEST(nak_is_broadcast_even_to_a_client_with_ciaddr) {
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_link(); e.set_link(&s); uint8_t r[600];
  auto q = client(3, 18, "", "203.0.113.77");  // renewing an address this link does not have
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.type, 6); CHECK_EQ(d.ip_dst, "255.255.255.255");
}
TEST(replies_to_a_client_without_ciaddr_are_broadcast) {  // whatever its broadcast bit says (dhcp.cpp)
  rmnet::EthernetEmulator e(synthetic_macs()); auto s = synthetic_link(); e.set_link(&s); uint8_t r[600];
  for (auto q : {client(1, 19, "", ""), client(3, 19, "198.51.100.10", "")}) {  // broadcast bit clear in both
    auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
    auto d = parse_dhcp_reply(r, t.reply_len);
    CHECK(d.checksums_ok); CHECK(to_synthetic_host(r, d)); CHECK_EQ(d.ip_dst, "255.255.255.255");
    CHECK_EQ(d.yiaddr, "198.51.100.10");
  }
}
