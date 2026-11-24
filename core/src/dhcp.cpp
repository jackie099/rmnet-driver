// The emulated router's DHCP server (RFC 2131, options RFC 2132). It hands the
// host the address settings the modem returned, so DHCP never reaches the modem.
//
// IPv6-only networks (off unless the installer turns it on). On an IPv6-only
// network with 464XLAT some modems run the customer-side translator (CLAT)
// themselves and report an IPv4 address from 192.0.0.0/29 (RFC 7335), usually
// 192.0.0.2 behind 192.0.0.1. macOS starts its own translator (CLAT46) on such a
// network too, and it uses 192.0.0.2 as well: when DHCP then sets the same
// address, configd releases its CLAT address and the interface is left with no
// IPv4 address at all. The IPv6-Only Preferred option (RFC 8925, option 108)
// avoids that: a client that asks for it is offered no address, and its own
// translator carries its IPv4.
//
// That is right only on a network that provides NAT64: RFC 8925 section 4 expects
// the option to be configured, in a typical deployment, only where the network
// provides NAT64, and a client told to prefer IPv6 only leaves DHCPv4 alone for
// kV6OnlyWaitSeconds. The address does not show which network this is, and the
// driver reads no translation state from the modem: RFC 7335 section 4 shares
// 192.0.0.0/29 between 464XLAT and DS-Lite, and a DS-Lite host uses the same
// 192.0.0.2 behind 192.0.0.1 (RFC 6333 section 5.7 and appendix B.2) with no
// NAT64 anywhere, so told to prefer IPv6 only it would lose IPv4. Option 108 is
// therefore sent only when the installer has turned it on (EthernetEmulator's
// ipv6_only_preferred; in the driver the personality's RMNetIPv6OnlyPreferred,
// which a build with RMNET_IPV6_ONLY_PREFERRED=1 sets) for a network known to
// provide NAT64, such as an IPv6-only one with 464XLAT; and even then only to a
// client that asks for it, on a link that has IPv6 and whose IPv4 address is in
// 192.0.0.0/29. Every other client and link is leased the modem's address as
// usual, a link whose address is in 192.0.0.0/29 included.
#include <string.h>

#include "rmnet/ethernet.h"
#include "rmnet/ip.h"

#include "ethernet_internal.h"

namespace rmnet {

using namespace eth_internal;

namespace {

constexpr size_t kUdpHeaderLen = 8;
constexpr uint8_t kProtoUdp = 17;
constexpr uint16_t kPortServer = 67;
constexpr uint16_t kPortClient = 68;
constexpr uint8_t kTtl = 64;

// BOOTP fixed part: op htype hlen hops xid secs flags ciaddr yiaddr siaddr giaddr chaddr sname file.
constexpr size_t kBootpFixedLen = 236;
constexpr size_t kOffXid = 4;
constexpr size_t kOffFlags = 10;
constexpr size_t kOffCiaddr = 12;
constexpr size_t kOffYiaddr = 16;
constexpr size_t kOffChaddr = 28;
constexpr size_t kChaddrLen = 16;
constexpr size_t kOptionsStart = kBootpFixedLen + 4;  // after the magic cookie
constexpr size_t kMinBootpLen = 300;                  // what clients expect at least (RFC 1542)
constexpr uint8_t kMagicCookie[4] = {0x63, 0x82, 0x53, 0x63};

constexpr uint8_t kOpRequest = 1;
constexpr uint8_t kOpReply = 2;
constexpr uint8_t kHtypeEthernet = 1;
constexpr uint8_t kHlenEthernet = 6;

constexpr uint8_t kOptPad = 0;
constexpr uint8_t kOptMask = 1;
constexpr uint8_t kOptRouter = 3;
constexpr uint8_t kOptDns = 6;
constexpr uint8_t kOptMtu = 26;
constexpr uint8_t kOptRequestedIp = 50;
constexpr uint8_t kOptLease = 51;
constexpr uint8_t kOptMessageType = 53;
constexpr uint8_t kOptServerId = 54;
constexpr uint8_t kOptParamRequestList = 55;
constexpr uint8_t kOptIpv6OnlyPreferred = 108;  // RFC 8925
constexpr uint8_t kOptAutoConfigure = 116;      // RFC 2563
constexpr uint8_t kOptEnd = 255;

constexpr uint8_t kDiscover = 1;
constexpr uint8_t kOffer = 2;
constexpr uint8_t kRequest = 3;
constexpr uint8_t kAck = 5;
constexpr uint8_t kNak = 6;
constexpr uint8_t kInform = 8;

constexpr uint32_t kLeaseSeconds = 3600;
constexpr uint32_t kMinMtu = 68;  // RFC 2132 option 26 minimum
// How long a client told to prefer IPv6 only leaves DHCPv4 alone, unless its link goes down and up
// first: RFC 8925's suggested default (its minimum is 300).
constexpr uint32_t kV6OnlyWaitSeconds = 1800;
constexpr uint8_t kDoNotAutoConfigure = 0;  // RFC 2563: no IPv4 link-local address either

// Option bytes of the largest reply: 53, 54, 51, 1, 3, 6 (two servers), 26, 108, 255 (an ACK of a
// renewal on an IPv6-only link). The IPv6-only offer (53, 54, 108, 116, 255) is smaller.
constexpr size_t kMaxOptionsLen = 3 + 6 + 6 + 6 + 6 + 10 + 4 + 6 + 1;
constexpr size_t kReplyBootpLen =
    kOptionsStart + kMaxOptionsLen > kMinBootpLen ? kOptionsStart + kMaxOptionsLen : kMinBootpLen;
constexpr size_t kReplyFrameLen = kEthHeaderLen + kIpv4HeaderLen + kUdpHeaderLen + kReplyBootpLen;

const uint8_t kBroadcastIp[4] = {255, 255, 255, 255};

// The fields of a client message the reply needs, copied out so the reply
// may be written over the request.
struct ClientMessage {
  uint8_t type;
  uint8_t xid[4];
  uint8_t flags[2];
  uint8_t ciaddr[4];
  uint8_t chaddr[kChaddrLen];
  bool has_requested_ip;
  uint8_t requested_ip[4];
  bool has_server_id;        // option 54: the server whose offer a REQUEST takes
  uint8_t server_id[4];
  bool wants_v6only;         // option 108 in its parameter request list (option 55)
  bool sent_auto_configure;  // it sent option 116 (RFC 2563), so a reply may carry one too
};

// Whether a is in 192.0.0.0/29, the prefix RFC 7335 sets aside for IPv4 continuity: 464XLAT's
// translator (CLAT), and DS-Lite's B4 element too, so it alone does not show a network with NAT64.
bool in_clat_prefix(const uint8_t a[4]) { return a[0] == 192 && a[1] == 0 && a[2] == 0 && (a[3] & 0xf8) == 0; }

bool is_zero(const uint8_t a[4]) { return (a[0] | a[1] | a[2] | a[3]) == 0; }

// Parses a BOOTP request with the magic cookie and option 53. False if malformed.
bool parse_client_message(const uint8_t* b, size_t len, ClientMessage* m) {
  if (len < kOptionsStart || b[0] != kOpRequest || memcmp(b + kBootpFixedLen, kMagicCookie, 4) != 0) {
    return false;
  }
  bool has_type = false;
  m->has_requested_ip = false;
  m->has_server_id = false;
  m->wants_v6only = false;
  m->sent_auto_configure = false;
  for (size_t i = kOptionsStart; i < len;) {
    uint8_t code = b[i];
    if (code == kOptPad) {
      ++i;
      continue;
    }
    if (code == kOptEnd) break;
    if (len - i < 2 || len - i - 2 < b[i + 1]) return false;  // option runs past the message
    uint8_t n = b[i + 1];
    const uint8_t* v = b + i + 2;
    if (code == kOptMessageType) {
      if (n != 1) return false;
      m->type = v[0];
      has_type = true;
    } else if (code == kOptRequestedIp) {
      if (n != 4) return false;
      memcpy(m->requested_ip, v, 4);
      m->has_requested_ip = true;
    } else if (code == kOptServerId) {
      if (n != 4) return false;
      memcpy(m->server_id, v, 4);
      m->has_server_id = true;
    } else if (code == kOptParamRequestList) {
      for (uint8_t k = 0; k < n; ++k) {
        if (v[k] == kOptIpv6OnlyPreferred) m->wants_v6only = true;
      }
    } else if (code == kOptAutoConfigure) {
      if (n == 1) m->sent_auto_configure = true;  // any other length: not the option RFC 2563 defines
    }
    i += 2 + (size_t)n;
  }
  if (!has_type) return false;
  memcpy(m->xid, b + kOffXid, 4);
  memcpy(m->flags, b + kOffFlags, 2);
  memcpy(m->ciaddr, b + kOffCiaddr, 4);
  memcpy(m->chaddr, b + kOffChaddr, kChaddrLen);
  return true;
}

uint8_t* put_option(uint8_t* o, uint8_t code, const uint8_t* value, uint8_t n) {
  o[0] = code;
  o[1] = n;
  memcpy(o + 2, value, n);
  return o + 2 + n;
}

}  // namespace

bool EthernetEmulator::is_dhcp_client(const uint8_t* ip, size_t len) {
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  bool first_fragment = (get16(ip + 6) & 0x1fff) == 0;
  return ip[9] == kProtoUdp && first_fragment && ihl >= kIpv4HeaderLen && len >= ihl + kUdpHeaderLen &&
         get16(ip + ihl) == kPortClient && get16(ip + ihl + 2) == kPortServer;
}

// Answers DISCOVER with OFFER, REQUEST with ACK for the link's address (the
// requested IP address, else ciaddr) and NAK for any other, and INFORM with ACK,
// all from the gateway address. Anything else is dropped, and so is a REQUEST
// whose server identifier (option 54) is not ours: the client took another
// server's offer (RFC 2131 section 3.1, step 4).
//
// The reply's IP destination is chosen as RFC 2131 section 4.1 says for a client
// on this link (giaddr is not looked at: the host is the only client of the
// emulated router, and no relay agent sits between them): a NAK is broadcast; an
// OFFER or ACK goes to ciaddr when the client gave one (renewing, rebinding,
// INFORM), and is broadcast when it did not. Section 4.1 would send that last one
// to yiaddr when the client's broadcast bit is clear; it is broadcast whatever the
// bit says. The Ethernet destination is always the host's MAC.
//
// IPv6-only (see the top of this file), when the installer turned it on, the
// client asked for option 108, the link has IPv6 and the modem's IPv4 address is
// in 192.0.0.0/29:
// - DISCOVER gets an OFFER of 0.0.0.0 with option 108 and nothing else but the
//   server ID (and option 116 set to "do not auto-configure" if the client sent
//   116), as RFC 8925 sections 3.3 and 3.3.1 recommend;
// - a REQUEST gets ACK or NAK as above, which RFC 8925 section 3.3 requires, and
//   the ACK carries 108: a client in INIT-REBOOT (a lease from an earlier link)
//   then stops DHCPv4 and leaves the address alone, and a renewing one keeps the
//   address it already uses (RFC 8925 section 3.2).
TxResult EthernetEmulator::tx_dhcp(const uint8_t*, const uint8_t* ip, size_t len, uint8_t* reply, size_t cap) {
  if (!link_.has_v4) return drop();
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  const uint8_t* udp = ip + ihl;
  size_t udp_len = get16(udp + 4);
  if (udp_len < kUdpHeaderLen || udp_len > len - ihl) return drop();
  ClientMessage m;
  if (!parse_client_message(udp + kUdpHeaderLen, udp_len - kUdpHeaderLen, &m)) return drop();

  bool v6only = ipv6_only_preferred_ && m.wants_v6only && link_.has_v6 && in_clat_prefix(link_.v4_addr);
  uint8_t type;
  bool give_address = true;   // yiaddr and lease
  bool give_settings = true;  // mask, router, DNS and MTU
  switch (m.type) {
    case kDiscover:
      type = kOffer;
      if (v6only) give_address = give_settings = false;
      break;
    case kRequest: {
      if (m.has_server_id && memcmp(m.server_id, link_.v4_gateway, 4) != 0) return drop();
      const uint8_t* asked = m.has_requested_ip ? m.requested_ip : m.ciaddr;
      type = memcmp(asked, link_.v4_addr, 4) == 0 ? kAck : kNak;
      break;
    }
    case kInform: type = kAck; give_address = false; v6only = false; break;
    default: return drop();
  }
  if (cap < kReplyFrameLen) return drop();

  memset(reply, 0, kReplyFrameLen);
  uint8_t* out_ip = reply + kEthHeaderLen;
  uint8_t* out_udp = out_ip + kIpv4HeaderLen;
  uint8_t* b = out_udp + kUdpHeaderLen;

  b[0] = kOpReply;
  b[1] = kHtypeEthernet;
  b[2] = kHlenEthernet;
  memcpy(b + kOffXid, m.xid, 4);
  memcpy(b + kOffFlags, m.flags, 2);
  if (give_address && type != kNak) memcpy(b + kOffYiaddr, link_.v4_addr, 4);
  memcpy(b + kOffChaddr, m.chaddr, kChaddrLen);
  memcpy(b + kBootpFixedLen, kMagicCookie, 4);

  uint8_t* o = b + kOptionsStart;
  o = put_option(o, kOptMessageType, &type, 1);
  o = put_option(o, kOptServerId, link_.v4_gateway, 4);
  if (type != kNak) {
    if (give_address) {
      uint8_t lease[4];
      put32(lease, kLeaseSeconds);
      o = put_option(o, kOptLease, lease, 4);
    }
    if (give_settings) {
      o = put_option(o, kOptMask, link_.v4_mask, 4);
      o = put_option(o, kOptRouter, link_.v4_gateway, 4);
      uint8_t dns_count = link_.v4_dns_count < 2 ? link_.v4_dns_count : 2;
      if (dns_count > 0) {
        *o++ = kOptDns;
        *o++ = (uint8_t)(4 * dns_count);
        for (uint8_t i = 0; i < dns_count; ++i, o += 4) memcpy(o, link_.v4_dns[i], 4);
      }
      if (link_.mtu >= kMinMtu && link_.mtu <= 0xffff) {
        uint8_t mtu[2];
        put16(mtu, (uint16_t)link_.mtu);
        o = put_option(o, kOptMtu, mtu, 2);
      }
    }
    if (v6only) {
      uint8_t wait[4];
      put32(wait, kV6OnlyWaitSeconds);
      o = put_option(o, kOptIpv6OnlyPreferred, wait, 4);
      if (type == kOffer && m.sent_auto_configure) o = put_option(o, kOptAutoConfigure, &kDoNotAutoConfigure, 1);
    }
  }
  *o = kOptEnd;

  const uint8_t* dst = type != kNak && !is_zero(m.ciaddr) ? m.ciaddr : kBroadcastIp;
  size_t out_udp_len = kUdpHeaderLen + kReplyBootpLen;
  put16(out_udp, kPortServer);
  put16(out_udp + 2, kPortClient);
  put16(out_udp + 4, (uint16_t)out_udp_len);
  uint16_t sum = udp4_checksum(link_.v4_gateway, dst, out_udp, out_udp_len);
  put16(out_udp + 6, sum == 0 ? 0xffff : sum);  // 0 on the wire would mean "no checksum"

  build_ipv4_header(out_ip, kIpv4HeaderLen, kProtoUdp, link_.v4_gateway, dst, out_udp_len, kTtl);
  write_header(reply, macs_.host, kEtherTypeIpv4);
  return replied(kReplyFrameLen);
}

}  // namespace rmnet
