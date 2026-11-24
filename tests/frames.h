// Builders for the Ethernet frames tests feed to the Ethernet emulator.
// Addresses are given as text: IPv4 dotted ("10.102.246.230"), IPv6 in inet_pton form ("fe80::1"),
// MAC as hex ("02 68 7a 43 12 f6").
#pragma once

#include <arpa/inet.h>
#include <stdint.h>
#include <stddef.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "captures.h"
#include "minitest.h"
#include "rmnet/ip.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"

// The MACs derive_macs("bfeed1a5") gives.
inline const char* kHostMac = "02 68 7a 43 12 f6";
inline const char* kRouterMac = "02 68 7a 43 12 f7";

// Six bytes from hex text. Aborts on anything else.
inline std::vector<uint8_t> mac(const char* text) {
  std::vector<uint8_t> m = hex(text);
  if (m.size() != 6) {
    std::fprintf(stderr, "mac(): \"%s\" is not 6 bytes\n", text);
    std::abort();
  }
  return m;
}

// Four bytes from dotted-decimal text. Aborts on malformed text.
inline std::vector<uint8_t> ipv4(const char* text) {
  unsigned a, b, c, d;
  char rest;
  if (std::sscanf(text, "%u.%u.%u.%u%c", &a, &b, &c, &d, &rest) != 4 || a > 255 || b > 255 || c > 255 || d > 255) {
    std::fprintf(stderr, "ipv4(): malformed address \"%s\"\n", text);
    std::abort();
  }
  return {(uint8_t)a, (uint8_t)b, (uint8_t)c, (uint8_t)d};
}

// Ethernet II frame: destination, source, EtherType, payload.
inline std::vector<uint8_t> eth(const char* dst, const char* src, uint16_t ethertype,
                                const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> f = mac(dst);
  std::vector<uint8_t> s = mac(src);
  f.insert(f.end(), s.begin(), s.end());
  f.push_back((uint8_t)(ethertype >> 8));
  f.push_back((uint8_t)ethertype);
  f.insert(f.end(), payload.begin(), payload.end());
  return f;
}

// Broadcast ARP request (Ethernet/IPv4) from sender_mac asking for target_ip; target MAC zero.
inline std::vector<uint8_t> arp_request(const char* sender_mac, const char* sender_ip, const char* target_ip) {
  std::vector<uint8_t> p = hex("00 01 08 00 06 04 00 01");
  std::vector<uint8_t> sm = mac(sender_mac), si = ipv4(sender_ip), ti = ipv4(target_ip);
  p.insert(p.end(), sm.begin(), sm.end());
  p.insert(p.end(), si.begin(), si.end());
  p.insert(p.end(), 6, 0);
  p.insert(p.end(), ti.begin(), ti.end());
  return eth("ff ff ff ff ff ff", sender_mac, 0x0806, p);
}

// Ethernet frame from the host MAC to the router MAC carrying an IPv4 UDP datagram.
// The IPv4 header checksum is valid; the UDP checksum is 0 (not computed).
inline std::vector<uint8_t> ipv4_udp(const char* src, const char* dst, uint16_t sport, uint16_t dport,
                                     const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> s = ipv4(src), d = ipv4(dst);
  size_t udp_len = 8 + payload.size();
  std::vector<uint8_t> pkt(20);
  if (rmnet::build_ipv4_header(pkt.data(), pkt.size(), 17, s.data(), d.data(), udp_len, 64) != 20) {
    std::fprintf(stderr, "ipv4_udp(): payload too large\n");
    std::abort();
  }
  uint8_t udp[8] = {(uint8_t)(sport >> 8), (uint8_t)sport, (uint8_t)(dport >> 8), (uint8_t)dport,
                    (uint8_t)(udp_len >> 8), (uint8_t)udp_len, 0, 0};
  pkt.insert(pkt.end(), udp, udp + 8);
  pkt.insert(pkt.end(), payload.begin(), payload.end());
  return eth(kRouterMac, kHostMac, 0x0800, pkt);
}

// A service (non-CTL) QMI frame with TLV `type` removed and both length fields adjusted. Fails the
// running test if the frame has no such TLV.
// Layout: 01, u16 QMUX length, flags, service, client, flags, u16 txid, u16 msg, u16 TLV length.
inline std::vector<uint8_t> without_tlv(std::vector<uint8_t> f, uint8_t type) {
  for (size_t i = 13; i + 3 <= f.size();) {
    size_t n = 3 + (size_t)(f[i + 1] | f[i + 2] << 8);
    if (f[i] == type) {
      f.erase(f.begin() + (long)i, f.begin() + (long)(i + n));
      size_t qmux = f.size() - 1, tlvs = f.size() - 13;
      f[1] = (uint8_t)qmux; f[2] = (uint8_t)(qmux >> 8);
      f[11] = (uint8_t)tlvs; f[12] = (uint8_t)(tlvs >> 8);
      return f;
    }
    i += n;
  }
  ::minitest::fail(__FILE__, __LINE__, "without_tlv(): TLV not in frame");
  return f;
}

// The link settings the modem reported in the recorded Get Current Settings replies (IPv4 and IPv6).
inline rmnet::RuntimeSettings link_settings() {
  rmnet::RuntimeSettings s{};
  for (const char* text : {kWdsSettings4Resp, kWdsSettings6Resp}) {
    std::vector<uint8_t> f = hex(text);
    rmnet::QmiMessage m{};
    if (!rmnet::qmi_decode({f.data(), f.size()}, &m) || !rmnet::parse_wds_current_settings(m, &s)) {
      std::fprintf(stderr, "link_settings(): recorded settings do not parse\n");
      std::abort();
    }
  }
  return s;
}

// Broadcast DHCP client message (BOOTP op 1) from the host MAC: IPv4 from ciaddr (or 0.0.0.0)
// to 255.255.255.255, UDP 68 to 67 with a valid checksum. Options: 53 `type`, then 50 with
// `requested_ip` unless it is empty, then the bytes of `extra_options` as given, then 255. An
// empty `ciaddr` leaves ciaddr zero.
inline std::vector<uint8_t> dhcp_client(uint8_t type, uint32_t xid, const char* requested_ip, const char* ciaddr,
                                        const std::vector<uint8_t>& extra_options = {}) {
  std::vector<uint8_t> ci = *ciaddr ? ipv4(ciaddr) : std::vector<uint8_t>(4, 0);
  std::vector<uint8_t> b(236, 0);
  b[0] = 1;  // op BOOTREQUEST
  b[1] = 1;  // htype Ethernet
  b[2] = 6;  // hlen
  b[4] = (uint8_t)(xid >> 24); b[5] = (uint8_t)(xid >> 16); b[6] = (uint8_t)(xid >> 8); b[7] = (uint8_t)xid;
  for (int i = 0; i < 4; ++i) b[12 + i] = ci[i];
  std::vector<uint8_t> hm = mac(kHostMac);
  for (int i = 0; i < 6; ++i) b[28 + i] = hm[i];
  std::vector<uint8_t> opts = {0x63, 0x82, 0x53, 0x63, 53, 1, type};
  if (*requested_ip) {
    std::vector<uint8_t> r = ipv4(requested_ip);
    opts.push_back(50); opts.push_back(4); opts.insert(opts.end(), r.begin(), r.end());
  }
  opts.insert(opts.end(), extra_options.begin(), extra_options.end());
  opts.push_back(255);
  b.insert(b.end(), opts.begin(), opts.end());

  std::vector<uint8_t> src = ci, dst = ipv4("255.255.255.255");
  size_t udp_len = 8 + b.size();
  std::vector<uint8_t> pkt(20);
  rmnet::build_ipv4_header(pkt.data(), pkt.size(), 17, src.data(), dst.data(), udp_len, 64);
  uint8_t udp[8] = {0, 68, 0, 67, (uint8_t)(udp_len >> 8), (uint8_t)udp_len, 0, 0};
  pkt.insert(pkt.end(), udp, udp + 8);
  pkt.insert(pkt.end(), b.begin(), b.end());
  uint16_t c = rmnet::udp4_checksum(src.data(), dst.data(), pkt.data() + 20, udp_len);
  if (c == 0) c = 0xffff;
  pkt[26] = (uint8_t)(c >> 8); pkt[27] = (uint8_t)c;
  return eth("ff ff ff ff ff ff", kHostMac, 0x0800, pkt);
}

// What a test needs to see of a DHCP reply frame. Addresses are dotted text, "" when absent;
// numbers are 0 when absent.
struct DhcpReply {
  int op = 0;
  uint32_t xid = 0;
  std::string yiaddr;
  uint8_t chaddr[16] = {};
  int type = 0;  // option 53
  std::string server_id;
  uint32_t lease = 0;
  std::string mask, router;
  std::vector<std::string> dns;
  int mtu = 0;
  bool v6only = false;      // option 108 present with length 4 (RFC 8925)
  uint32_t v6only_wait = 0;
  int auto_configure = -1;  // option 116's byte (RFC 2563), -1 when absent
  std::string ip_src, ip_dst;
  bool checksums_ok = false;  // IPv4 header and UDP (pseudo-header included); a zero UDP checksum fails
};

inline std::string dotted(const uint8_t* a) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "%u.%u.%u.%u", a[0], a[1], a[2], a[3]);
  return buf;
}

// Parses an Ethernet frame carrying IPv4/UDP/DHCP. Stops at the first thing out of bounds,
// leaving the remaining fields at their defaults.
inline DhcpReply parse_dhcp_reply(const uint8_t* bytes, size_t len) {
  DhcpReply d;
  if (len < 14 + 20) return d;
  const uint8_t* ip = bytes + 14;
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  size_t total = (size_t)(ip[2] << 8 | ip[3]);
  if (ihl < 20 || total < ihl + 8 || 14 + total > len || ip[9] != 17) return d;
  d.ip_src = dotted(ip + 12);
  d.ip_dst = dotted(ip + 16);
  const uint8_t* udp = ip + ihl;
  size_t udp_len = (size_t)(udp[4] << 8 | udp[5]);
  if (udp_len < 8 || ihl + udp_len > total) return d;
  bool ip_ok = rmnet::fold_checksum(rmnet::sum16(ip, ihl)) == 0;
  bool udp_ok = (udp[6] | udp[7]) != 0 && rmnet::udp4_checksum(ip + 12, ip + 16, udp, udp_len) == 0;
  d.checksums_ok = ip_ok && udp_ok;
  const uint8_t* b = udp + 8;
  size_t blen = udp_len - 8;
  if (blen < 240) return d;
  d.op = b[0];
  d.xid = (uint32_t)b[4] << 24 | (uint32_t)b[5] << 16 | (uint32_t)b[6] << 8 | b[7];
  d.yiaddr = dotted(b + 16);
  for (int i = 0; i < 16; ++i) d.chaddr[i] = b[28 + i];
  for (size_t i = 240; i < blen;) {
    uint8_t code = b[i];
    if (code == 0) { ++i; continue; }
    if (code == 255 || i + 1 >= blen) break;
    size_t n = b[i + 1];
    const uint8_t* v = b + i + 2;
    if (i + 2 + n > blen) break;
    switch (code) {
      case 53: if (n == 1) d.type = v[0]; break;
      case 54: if (n == 4) d.server_id = dotted(v); break;
      case 51: if (n == 4) d.lease = (uint32_t)v[0] << 24 | (uint32_t)v[1] << 16 | (uint32_t)v[2] << 8 | v[3]; break;
      case 1: if (n == 4) d.mask = dotted(v); break;
      case 3: if (n >= 4) d.router = dotted(v); break;
      case 6: for (size_t k = 0; k + 4 <= n; k += 4) d.dns.push_back(dotted(v + k)); break;
      case 26: if (n == 2) d.mtu = v[0] << 8 | v[1]; break;
      case 108:
        if (n == 4) {
          d.v6only = true;
          d.v6only_wait = (uint32_t)v[0] << 24 | (uint32_t)v[1] << 16 | (uint32_t)v[2] << 8 | v[3];
        }
        break;
      case 116: if (n == 1) d.auto_configure = v[0]; break;
      default: break;
    }
    i += 2 + n;
  }
  return d;
}

// Sixteen bytes from IPv6 text. Aborts on malformed text.
inline std::vector<uint8_t> ipv6(const char* text) {
  std::vector<uint8_t> a(16);
  if (inet_pton(AF_INET6, text, a.data()) != 1) {
    std::fprintf(stderr, "ipv6(): malformed address \"%s\"\n", text);
    std::abort();
  }
  return a;
}

// IPv6 text in inet_ntop form ("fe80::1").
inline std::string ipv6_text(const uint8_t* a) {
  char buf[INET6_ADDRSTRLEN];
  return inet_ntop(AF_INET6, a, buf, sizeof buf) ? buf : "";
}

// Ethernet frame from the host MAC carrying an IPv6 ICMPv6 message, hop limit 255, valid checksum.
// `body` is everything after type, code (0) and checksum. The Ethernet destination is 33:33 plus
// the last four address bytes for a multicast destination, the router MAC otherwise.
inline std::vector<uint8_t> icmp6(const char* src, const char* dst, uint8_t type, const std::vector<uint8_t>& body) {
  std::vector<uint8_t> s = ipv6(src), d = ipv6(dst);
  std::vector<uint8_t> msg = {type, 0, 0, 0};
  msg.insert(msg.end(), body.begin(), body.end());
  uint16_t c = rmnet::icmp6_checksum(s.data(), d.data(), msg.data(), msg.size());
  msg[2] = (uint8_t)(c >> 8); msg[3] = (uint8_t)c;
  std::vector<uint8_t> pkt(40);
  if (rmnet::build_ipv6_header(pkt.data(), pkt.size(), 58, s.data(), d.data(), msg.size(), 255) != 40) {
    std::fprintf(stderr, "icmp6(): body too large\n");
    std::abort();
  }
  pkt.insert(pkt.end(), msg.begin(), msg.end());
  char dst_mac[18];
  if (d[0] == 0xff) {
    std::snprintf(dst_mac, sizeof dst_mac, "33 33 %02x %02x %02x %02x", d[12], d[13], d[14], d[15]);
  } else {
    std::snprintf(dst_mac, sizeof dst_mac, "%s", kRouterMac);
  }
  return eth(dst_mac, kHostMac, 0x86DD, pkt);
}

// Source link-layer address option with the host MAC; none when the source is "::" (RFC 4861).
inline std::vector<uint8_t> host_lla_option(const char* src_ip) {
  if (ipv6(src_ip) == std::vector<uint8_t>(16, 0)) return {};
  std::vector<uint8_t> o = {1, 1};
  std::vector<uint8_t> m = mac(kHostMac);
  o.insert(o.end(), m.begin(), m.end());
  return o;
}

// Router solicitation from `src_ip` to ff02::2.
inline std::vector<uint8_t> router_solicit(const char* src_ip) {
  std::vector<uint8_t> body(4, 0), o = host_lla_option(src_ip);
  body.insert(body.end(), o.begin(), o.end());
  return icmp6(src_ip, "ff02::2", 133, body);
}

// Neighbour solicitation from `src_ip` for `target_ip`, to the target's solicited-node address.
inline std::vector<uint8_t> neighbour_solicit(const char* src_ip, const char* target_ip) {
  std::vector<uint8_t> t = ipv6(target_ip);
  char dst[INET6_ADDRSTRLEN];
  std::snprintf(dst, sizeof dst, "ff02::1:ff%02x:%02x%02x", t[13], t[14], t[15]);
  std::vector<uint8_t> body(4, 0), o = host_lla_option(src_ip);
  body.insert(body.end(), t.begin(), t.end());
  body.insert(body.end(), o.begin(), o.end());
  return icmp6(src_ip, dst, 135, body);
}

// What a test needs to see of a router (134) or neighbour (136) advertisement frame. Addresses are
// inet_ntop text, "" when absent; numbers are 0 when absent.
struct NdReply {
  uint8_t eth_dst[6] = {};
  std::string ip_src, ip_dst;
  int hop_limit = 0;
  int type = 0;
  bool checksum_ok = false;  // ICMPv6 checksum, pseudo-header included
  // Router advertisement
  int cur_hop_limit = 0, flags = 0, router_lifetime = 0;
  uint8_t source_lla[6] = {};
  uint32_t mtu = 0;
  std::string prefix;
  int prefix_len = 0, prefix_flags = 0;
  uint32_t valid_lifetime = 0, preferred_lifetime = 0;
  std::vector<std::string> rdnss;
  uint32_t rdnss_lifetime = 0;
  // Neighbour advertisement
  std::string target;
  int na_flags = 0;
  uint8_t target_lla[6] = {};
};

inline uint32_t get32_be(const uint8_t* p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// Parses an Ethernet frame carrying IPv6/ICMPv6 directly. Stops at the first thing out of bounds,
// leaving the remaining fields at their defaults.
inline NdReply parse_nd_reply(const uint8_t* bytes, size_t len) {
  NdReply d;
  if (len < 14 + 40) return d;
  for (int i = 0; i < 6; ++i) d.eth_dst[i] = bytes[i];
  const uint8_t* ip = bytes + 14;
  size_t plen = (size_t)(ip[4] << 8 | ip[5]);
  if (14 + 40 + plen > len || ip[6] != 58 || plen < 4) return d;
  d.hop_limit = ip[7];
  d.ip_src = ipv6_text(ip + 8);
  d.ip_dst = ipv6_text(ip + 24);
  const uint8_t* m = ip + 40;
  d.type = m[0];
  d.checksum_ok = rmnet::icmp6_checksum(ip + 8, ip + 24, m, plen) == 0;
  size_t opts;
  if (d.type == 134) {
    if (plen < 16) return d;
    d.cur_hop_limit = m[4];
    d.flags = m[5];
    d.router_lifetime = m[6] << 8 | m[7];
    opts = 16;
  } else if (d.type == 136) {
    if (plen < 24) return d;
    d.na_flags = m[4];
    d.target = ipv6_text(m + 8);
    opts = 24;
  } else {
    return d;
  }
  for (size_t i = opts; i + 2 <= plen;) {
    size_t n = (size_t)m[i + 1] * 8;
    if (n == 0 || i + n > plen) break;
    const uint8_t* o = m + i;
    switch (o[0]) {
      case 1: if (n == 8) for (int k = 0; k < 6; ++k) d.source_lla[k] = o[2 + k]; break;
      case 2: if (n == 8) for (int k = 0; k < 6; ++k) d.target_lla[k] = o[2 + k]; break;
      case 5: if (n == 8) d.mtu = get32_be(o + 4); break;
      case 3:
        if (n == 32) {
          d.prefix_len = o[2];
          d.prefix_flags = o[3];
          d.valid_lifetime = get32_be(o + 4);
          d.preferred_lifetime = get32_be(o + 8);
          d.prefix = ipv6_text(o + 16);
        }
        break;
      case 25:
        if (n >= 8) {
          d.rdnss_lifetime = get32_be(o + 4);
          for (size_t k = 8; k + 16 <= n; k += 16) d.rdnss.push_back(ipv6_text(o + k));
        }
        break;
      default: break;
    }
    i += n;
  }
  return d;
}

// Synthetic fixtures, recorded from no modem: a made-up USB serial number, and documentation
// addresses (IPv4 from RFC 5737's TEST-NET blocks, IPv6 from RFC 3849's 2001:db8::/32). 192.0.0.0/29
// is a protocol prefix (RFC 7335), not any network's address.

// The USB serial number the synthetic tests derive their MACs from.
inline const char* kSyntheticSerial = "SYNTHETIC-SERIAL-0001";

// Copies the bytes of `v` to `dst`.
inline void put_bytes(uint8_t* dst, const std::vector<uint8_t>& v) {
  for (size_t i = 0; i < v.size(); ++i) dst[i] = v[i];
}

// A dual-stack link: IPv4 198.51.100.10/30 behind 198.51.100.9, DNS 192.0.2.53 and 192.0.2.54;
// IPv6 2001:db8:0:1::10/64 behind 2001:db8:0:1::1, DNS 2001:db8::53 and 2001:db8::54; MTU 1500.
inline rmnet::RuntimeSettings synthetic_link() {
  rmnet::RuntimeSettings s{};
  s.has_v4 = true;
  put_bytes(s.v4_addr, ipv4("198.51.100.10"));
  put_bytes(s.v4_gateway, ipv4("198.51.100.9"));
  put_bytes(s.v4_mask, ipv4("255.255.255.252"));
  put_bytes(s.v4_dns[0], ipv4("192.0.2.53"));
  put_bytes(s.v4_dns[1], ipv4("192.0.2.54"));
  s.v4_dns_count = 2;
  s.has_v6 = true;
  put_bytes(s.v6_addr, ipv6("2001:db8:0:1::10"));
  s.v6_prefix_len = 64;
  put_bytes(s.v6_gateway, ipv6("2001:db8:0:1::1"));
  put_bytes(s.v6_dns[0], ipv6("2001:db8::53"));
  put_bytes(s.v6_dns[1], ipv6("2001:db8::54"));
  s.v6_dns_count = 2;
  s.mtu = 1500;
  return s;
}

// synthetic_link() as a modem running its own 464XLAT translator reports it: IPv4 192.0.0.2/27
// behind 192.0.0.1 (RFC 7335's prefix). A DS-Lite host uses the same two addresses (RFC 6333
// section 5.7), so the link alone does not show whether the network has NAT64.
inline rmnet::RuntimeSettings synthetic_clat_link() {
  rmnet::RuntimeSettings s = synthetic_link();
  put_bytes(s.v4_addr, ipv4("192.0.0.2"));
  put_bytes(s.v4_gateway, ipv4("192.0.0.1"));
  put_bytes(s.v4_mask, ipv4("255.255.255.224"));
  return s;
}

// A frame dhcp_client() made, sent from `host` instead of kHostMac: the Ethernet source and chaddr
// rewritten, and the UDP checksum computed again.
inline std::vector<uint8_t> dhcp_from(const uint8_t host[6], std::vector<uint8_t> f) {
  uint8_t* ip = f.data() + 14;
  uint8_t* udp = ip + 20;
  for (int i = 0; i < 6; ++i) f[6 + i] = udp[8 + 28 + i] = host[i];
  size_t udp_len = (size_t)(udp[4] << 8 | udp[5]);
  udp[6] = udp[7] = 0;
  uint16_t c = rmnet::udp4_checksum(ip + 12, ip + 16, udp, udp_len);
  if (c == 0) c = 0xffff;
  udp[6] = (uint8_t)(c >> 8); udp[7] = (uint8_t)c;
  return f;
}
