// Ethernet emulation over the modem's raw-IP link. macOS sees an Ethernet
// interface; the emulator adds and removes Ethernet headers and plays the
// router on the other end of the link, answering ARP, DHCP and IPv6 neighbour
// discovery itself.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/bytes.h"
#include "rmnet/qmi_msgs.h"

namespace rmnet {

// Locally administered unicast MACs for the host interface and the emulated router.
struct MacPair {
  uint8_t host[6];
  uint8_t router[6];
};

// Stable for a given USB serial number; host and router differ only in the last bit.
MacPair derive_macs(const char* usb_serial);

enum class TxAction : uint8_t { Forward, Reply, Drop };

// Forward: ip is the packet inside the frame (points into the frame).
// Reply: reply_len bytes were written to the reply buffer.
struct TxResult {
  TxAction action;
  Span ip;
  size_t reply_len;
};

class EthernetEmulator {
 public:
  // ipv6_only_preferred: whether DHCP may answer a client that asks for it with the IPv6-Only
  // Preferred option (RFC 8925, option 108) on a link that looks like a 464XLAT one (dhcp.cpp,
  // top comment). Off unless the installer turned it on for a network known to provide NAT64.
  explicit EthernetEmulator(const MacPair& macs, bool ipv6_only_preferred = false);

  // Copies *settings; nullptr means the link is down.
  void set_link(const RuntimeSettings* settings);

  // Wraps a packet from the modem in an Ethernet header, router to host.
  // Returns the frame length, or 0 if the packet is to be dropped.
  size_t wrap_rx(const uint8_t* ip, size_t len, uint8_t* out, size_t cap);

  // Decides what to do with a frame the host sent.
  TxResult handle_tx(const uint8_t* frame, size_t len, uint8_t* reply, size_t reply_cap);

  // Unsolicited IPv6 router advertisement frame to all nodes (ff02::1). Returns
  // its length, or 0 when the link is down, has no IPv6, or `cap` is too small.
  //
  // The caller must send the result to the host when the link comes up and then
  // at least every 600 seconds while the link stays up. The advertisement gives
  // the router and its RDNSS servers a lifetime of 1800 seconds; without a fresh
  // one inside that time macOS drops the IPv6 default route and DNS servers.
  // Answers to the host's router solicitations (handle_tx) do not replace this:
  // the host solicits only when it chooses to, not before the lifetime ends.
  size_t make_router_advert(uint8_t* out, size_t cap);

 private:
  // One handler per EtherType; each receives the payload after the Ethernet header.
  TxResult tx_ipv4(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);
  TxResult tx_ipv6(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);
  TxResult tx_arp(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);

  // DHCP (dhcp.cpp). `ip` is an IPv4 packet trimmed to its total length.
  // is_dhcp_client says whether it is UDP from port 68 to port 67; such packets
  // go to tx_dhcp and never upstream, whatever their destination.
  static bool is_dhcp_client(const uint8_t* ip, size_t len);
  TxResult tx_dhcp(const uint8_t* frame, const uint8_t* ip, size_t len, uint8_t* reply, size_t cap);

  // Neighbour discovery (ndp.cpp). `ip` is an IPv6 packet trimmed to its payload
  // length. is_nd_solicit says whether it carries ICMPv6 directly (next header
  // 58) of type router or neighbour solicitation; such packets go to tx_nd.
  static bool is_nd_solicit(const uint8_t* ip, size_t len);
  TxResult tx_nd(const uint8_t* ip, size_t len, uint8_t* reply, size_t cap);
  // Router advertisement frame to eth_dst / ip_dst; 0 if `cap` is too small.
  size_t write_router_advert(uint8_t* out, size_t cap, const uint8_t eth_dst[6], const uint8_t ip_dst[16]) const;
  // Whether `ip` (len bytes from the modem) is a router advertisement.
  static bool is_router_advert(const uint8_t* ip, size_t len);

  // Writes an Ethernet header from the router to `dst`; returns 14.
  size_t write_header(uint8_t* out, const uint8_t dst[6], uint16_t ethertype) const;

  MacPair macs_;
  RuntimeSettings link_;
  bool link_up_;
  bool ipv6_only_preferred_;
};

}  // namespace rmnet
