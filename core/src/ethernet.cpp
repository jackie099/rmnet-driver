#include "rmnet/ethernet.h"

#include <string.h>

#include "ethernet_internal.h"

namespace rmnet {

using namespace eth_internal;

namespace {

constexpr size_t kArpLen = 28;  // Ethernet/IPv4 ARP body

constexpr uint16_t kArpHwEthernet = 1;
constexpr uint16_t kArpOpRequest = 1;
constexpr uint16_t kArpOpReply = 2;

constexpr uint64_t kFnvOffset = 0xcbf29ce484222325ull;
constexpr uint64_t kFnvPrime = 0x100000001b3ull;

}  // namespace

MacPair derive_macs(const char* usb_serial) {
  uint64_t h = kFnvOffset;
  for (const char* p = usb_serial; p && *p; ++p) {
    h ^= (uint8_t)*p;
    h *= kFnvPrime;
  }
  MacPair m;
  m.host[0] = 0x02;
  m.host[1] = (uint8_t)(h >> 32);
  m.host[2] = (uint8_t)(h >> 24);
  m.host[3] = (uint8_t)(h >> 16);
  m.host[4] = (uint8_t)(h >> 8);
  m.host[5] = (uint8_t)(h & 0xfe);
  memcpy(m.router, m.host, 6);
  m.router[5] |= 0x01;
  return m;
}

EthernetEmulator::EthernetEmulator(const MacPair& macs, bool ipv6_only_preferred)
    : macs_(macs), link_(), link_up_(false), ipv6_only_preferred_(ipv6_only_preferred) {}

void EthernetEmulator::set_link(const RuntimeSettings* settings) {
  if (settings) {
    link_ = *settings;
    link_up_ = true;
  } else {
    link_ = RuntimeSettings();
    link_up_ = false;
  }
}

size_t EthernetEmulator::write_header(uint8_t* out, const uint8_t dst[6], uint16_t ethertype) const {
  memcpy(out, dst, 6);
  memcpy(out + 6, macs_.router, 6);
  put16(out + 12, ethertype);
  return kEthHeaderLen;
}

size_t EthernetEmulator::wrap_rx(const uint8_t* ip, size_t len, uint8_t* out, size_t cap) {
  if (len == 0 || cap < kEthHeaderLen || len > cap - kEthHeaderLen) return 0;
  uint16_t ethertype;
  switch (ip[0] >> 4) {
    case 4: ethertype = kEtherTypeIpv4; break;
    case 6: ethertype = kEtherTypeIpv6; break;
    default: return 0;
  }
  if (is_router_advert(ip, len)) return 0;  // the host must see only the emulated router
  write_header(out, macs_.host, ethertype);
  memcpy(out + kEthHeaderLen, ip, len);
  return kEthHeaderLen + len;
}

TxResult EthernetEmulator::handle_tx(const uint8_t* frame, size_t len, uint8_t* reply, size_t reply_cap) {
  if (!link_up_ || len < kEthHeaderLen) return drop();
  const uint8_t* payload = frame + kEthHeaderLen;
  size_t n = len - kEthHeaderLen;
  switch (get16(frame + 12)) {
    case kEtherTypeIpv4: return tx_ipv4(frame, payload, n, reply, reply_cap);
    case kEtherTypeIpv6: return tx_ipv6(frame, payload, n, reply, reply_cap);
    case kEtherTypeArp: return tx_arp(frame, payload, n, reply, reply_cap);
    default: return drop();
  }
}

// Answers DHCP itself and forwards unicast IPv4, trimmed to the header's total
// length (Ethernet may pad). Drops everything when the link has no IPv4.
TxResult EthernetEmulator::tx_ipv4(const uint8_t* frame, const uint8_t* p, size_t len, uint8_t* reply,
                                   size_t cap) {
  if (!link_.has_v4 || len < kIpv4HeaderLen || (p[0] >> 4) != 4) return drop();
  size_t total = get16(p + 2);
  if (total < kIpv4HeaderLen || total > len) return drop();
  if (is_dhcp_client(p, total)) return tx_dhcp(frame, p, total, reply, cap);
  const uint8_t* dst = p + 16;
  bool broadcast = dst[0] == 255 && dst[1] == 255 && dst[2] == 255 && dst[3] == 255;
  bool multicast = (dst[0] & 0xf0) == 0xe0;  // 224.0.0.0/4
  if (broadcast || multicast) return drop();
  return forward(p, total);
}

// Answers router and neighbour solicitations itself, drops other multicast, and
// forwards unicast IPv6, trimmed to the header's payload length (Ethernet may pad).
TxResult EthernetEmulator::tx_ipv6(const uint8_t*, const uint8_t* p, size_t len, uint8_t* reply, size_t cap) {
  if (!link_.has_v6 || len < kIpv6HeaderLen || (p[0] >> 4) != 6) return drop();
  size_t total = kIpv6HeaderLen + get16(p + 4);
  if (total > len) return drop();
  if (is_nd_solicit(p, total)) return tx_nd(p, total, reply, cap);
  if (p[24] == 0xff) return drop();  // destination in ff00::/8
  return forward(p, total);
}

// Answers every Ethernet/IPv4 ARP request with the router's MAC, so all
// traffic goes to the emulated router. Probes, announcements and requests for
// the host's own address get no answer (answering those would look like an
// address conflict to the host).
TxResult EthernetEmulator::tx_arp(const uint8_t*, const uint8_t* p, size_t len, uint8_t* reply, size_t cap) {
  if (!link_.has_v4 || len < kArpLen) return drop();
  if (get16(p) != kArpHwEthernet || get16(p + 2) != kEtherTypeIpv4 || p[4] != 6 || p[5] != 4 ||
      get16(p + 6) != kArpOpRequest) {
    return drop();
  }
  const uint8_t* sender_mac = p + 8;
  const uint8_t* sender_ip = p + 14;
  const uint8_t* target_ip = p + 24;
  static const uint8_t kZeroIp[4] = {0, 0, 0, 0};
  if (memcmp(sender_ip, kZeroIp, 4) == 0 || memcmp(sender_ip, target_ip, 4) == 0) return drop();
  if (memcmp(target_ip, link_.v4_addr, 4) == 0) return drop();
  if (cap < kEthHeaderLen + kArpLen) return drop();

  // Copied first so the reply is correct even if the caller passes the frame's own buffer as reply.
  uint8_t mac[6], sip[4], tip[4];
  memcpy(mac, sender_mac, 6);
  memcpy(sip, sender_ip, 4);
  memcpy(tip, target_ip, 4);

  write_header(reply, mac, kEtherTypeArp);
  uint8_t* a = reply + kEthHeaderLen;
  put16(a, kArpHwEthernet);
  put16(a + 2, kEtherTypeIpv4);
  a[4] = 6;
  a[5] = 4;
  put16(a + 6, kArpOpReply);
  memcpy(a + 8, macs_.router, 6);
  memcpy(a + 14, tip, 4);
  memcpy(a + 18, mac, 6);
  memcpy(a + 24, sip, 4);
  return replied(kEthHeaderLen + kArpLen);
}

}  // namespace rmnet
