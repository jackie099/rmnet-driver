// The driver: opens the modem's QMI interface, runs Core's QMI session over its control channel,
// and presents an Ethernet port whose link follows the session. Frames from the stack go through
// CoreHost to the bulk OUT pipe; bulk IN transfers come back through CoreHost as received frames.
#include <os/log.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/USBDriverKit.h>  // umbrella: also declares IOUSBHostFreeDescriptor
#include <NetworkingDriverKit/NetworkingDriverKit.h>

#include "rmnet/ethernet.h"
#include "rmnet/qmi_interface.h"
#include "rmnet/util.h"

#include "RMNetDriver.h"
#include "core_host.h"
#include "usb_io.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)
// Logs only the first time this point is reached, so the log shows which callbacks macOS uses.
#define LOG_FIRST(flag, fmt, ...)                        \
  do {                                                   \
    if (FirstCall(flag)) LOG(fmt, ##__VA_ARGS__);        \
  } while (0)

namespace {

// The RM520N-GL's QMI interface, used when the personality names none (ReadQmiInterface).
constexpr uint8_t kDefaultQmiInterface = 4;
constexpr uint32_t kPacketCount = 512;
constexpr uint32_t kPacketBufSize = 2048;  // one Ethernet frame per packet
constexpr uint32_t kQueueCapacity = 256;  // the TX completion and both RX queues
// The TX submission queue only. During an upload the uplink hold keeps it full; what does not fit
// waits in macOS's own interface queue, which schedules flows fairly, rather than in order here.
constexpr uint32_t kTxQueueCapacity = 64;
constexpr uint32_t kMtu = 1500;
constexpr uint32_t kMinMtu = 576;
constexpr uint8_t kDefaultProfile = 1;
constexpr const char* kProfileKey = "RMNetProfile";
constexpr const char* kFlowControlKey = "RMNetFlowControl";
constexpr const char* kIpv6OnlyPreferredKey = "RMNetIPv6OnlyPreferred";
constexpr const char* kInterfaceKey = "bInterfaceNumber";
constexpr uint32_t kTxBatch = 32;
constexpr uint32_t kTxHold = 256;  // sent packets the completion queue has not taken yet
constexpr uint32_t kRxHold = 256;  // filled packets the completion queue has not taken yet
constexpr uint32_t kRxBatch = 64;  // filled packets that trigger a hand-up (a hand-up after a
                                   // refusal passes all of rxOut, up to kRxHold)
constexpr uint32_t kRxStock = 32;  // empty receive packets taken from the RX submission queue at once
constexpr uint8_t kLinkHeaderLen = 14;  // Ethernet
constexpr uint32_t kCounterTicks = 10;  // counters are published once a second
constexpr uint64_t kTickNs = 100 * 1000000ull;
constexpr uint64_t kTickLeewayNs = 10 * 1000000ull;
constexpr uint64_t kStopDrainMs = 1000;  // the control ring may take this long to send at Stop
constexpr uint64_t kStopAbortMs = 1000;  // and the aborted requests this long to come back
// A wake whose USB posts are refused (the bus not ready yet) is tried again from every tick until
// this long after the wake call; the attempt made then is the last.
enum : uint32_t { kResumeRetryMs = 5000 };

// One bit per override and handler, set the first time it runs.
enum : uint32_t {
  kLogInit = 1u << 0,
  kLogFree = 1u << 1,
  kLogStart = 1u << 2,
  kLogStop = 1u << 3,
  kLogSetInterfaceEnable = 1u << 5,
  kLogSetPromiscuous = 1u << 6,
  kLogSetAllMulticast = 1u << 7,
  kLogSelectMediaType = 1u << 8,
  kLogGetSupportedMedia = 1u << 9,
  kLogSetMulticastAddresses = 1u << 10,
  kLogSetInterfaceEnableLower = 1u << 11,
  kLogSetPromiscuousLower = 1u << 12,
  kLogSetAllMulticastLower = 1u << 13,
  kLogHandleChosenMedia = 1u << 14,
  kLogGetMaxTransferUnit = 1u << 15,
  kLogSetPowerStateLower = 1u << 16,
  kLogTxAvailable = 1u << 17,
  kLogRxAvailable = 1u << 18,
  kLogTxCompleteFull = 1u << 19,
  kLogInterruptComplete = 1u << 20,
  kLogControlOutComplete = 1u << 21,
  kLogControlInComplete = 1u << 22,
  kLogTimerFired = 1u << 23,
  kLogBulkIn = 1u << 24,
  kLogBulkOut = 1u << 25,
  kLogTxPacket = 1u << 26,
  kLogRxPacket = 1u << 27,
  kLogRxCompleteFull = 1u << 28,
  kLogPoolCount = 1u << 29,
  kLogTxHold = 1u << 30,
  kLogUplinkUsable = 1u << 31,
};

// The number of the modem's QMI interface, from the service's bInterfaceNumber property: the
// personality in Info.plist that matched the provider names it (4 for every listed model). An
// integer from 0 to 255; anything else, or no such property, gives 4, with a log line. The session
// names it in its requests, and CheckQmiInterface compares the provider's number with it.
uint8_t ReadQmiInterface(IOService* service) {
  OSDictionary* props = nullptr;
  kern_return_t ret = service->CopyProperties(&props);
  uint8_t number = kDefaultQmiInterface;
  if (ret != kIOReturnSuccess || !props) {
    LOG("bInterfaceNumber: properties not readable (0x%x); using interface %u", ret, number);
  } else {
    OSObject* obj = props->getObject(kInterfaceKey);
    OSNumber* num = OSDynamicCast(OSNumber, obj);
    if (!obj) {
      LOG("bInterfaceNumber: no such property; using interface %u", number);
    } else if (!num) {
      LOG("bInterfaceNumber: not an integer; using interface %u", number);
    } else if (num->unsigned64BitValue() > 255) {
      LOG("bInterfaceNumber: %llu is not from 0 to 255; using interface %u", num->unsigned64BitValue(), number);
    } else {
      number = static_cast<uint8_t>(num->unsigned64BitValue());
    }
  }
  OSSafeReleaseNULL(props);
  return number;
}

// Whether the provider can be the modem's QMI interface; logs why when it cannot. IOKit matched it
// by the personality's idProduct and bInterfaceNumber, and in the modem's QMI USB configuration
// (AT+QCFG="usbnet",0) that number is the QMI function's. In another configuration the same number
// can belong to another function (an MBIM, ECM, DIAG or serial interface), so the checks that guard
// are the interface's own: class, subclass and protocol 0xff and the QMI function's three endpoints,
// one interrupt IN, one bulk IN and one bulk OUT (rmnet::qmi_interface_fault, the rule of the
// kernel's qmi_wwan). The number is compared with the personality's only as a consistency check.
bool CheckQmiInterface(IOService* provider, uint8_t number) {
  IOUSBHostInterface* intf = OSDynamicCast(IOUSBHostInterface, provider);
  const IOUSBConfigurationDescriptor* cfg = intf ? intf->CopyConfigurationDescriptor() : nullptr;
  const IOUSBInterfaceDescriptor* id = cfg ? intf->GetInterfaceDescriptor(cfg) : nullptr;
  if (!id) {
    LOG("not the QMI interface: no interface descriptor");
    if (cfg) IOUSBHostFreeDescriptor(cfg);
    return false;
  }
  rmnet::QmiEndpoints eps{id->bNumEndpoints, 0, 0, 0};
  const IOUSBEndpointDescriptor* ep = nullptr;
  while ((ep = IOUSBGetNextEndpointDescriptor(cfg, id, reinterpret_cast<const IOUSBDescriptorHeader*>(ep)))) {
    uint8_t type = IOUSBGetEndpointType(ep);
    bool in = IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn;
    if (type == kIOUSBEndpointTypeInterrupt && in) {
      eps.interrupt_in++;
    } else if (type == kIOUSBEndpointTypeBulk && in) {
      eps.bulk_in++;
    } else if (type == kIOUSBEndpointTypeBulk) {
      eps.bulk_out++;
    }
  }
  uint8_t iface = id->bInterfaceNumber;
  uint8_t cls = id->bInterfaceClass;
  uint8_t sub = id->bInterfaceSubClass;
  uint8_t proto = id->bInterfaceProtocol;
  IOUSBHostFreeDescriptor(cfg);
  if (iface != number) {
    LOG("not the QMI interface: interface %u, but the personality names %u", iface, number);
    return false;
  }
  switch (rmnet::qmi_interface_fault(cls, sub, proto, eps)) {
    case rmnet::QmiInterfaceFault::None:
      return true;
    case rmnet::QmiInterfaceFault::Class:
      LOG("not the QMI interface: interface %u has class %02x subclass %02x protocol %02x, not ff ff ff", iface, cls,
          sub, proto);
      return false;
    case rmnet::QmiInterfaceFault::Endpoints:
      LOG("not the QMI interface: interface %u has %u endpoints (%u interrupt in, %u bulk in, %u bulk out), not "
          "3 (one of each)",
          iface, eps.total, eps.interrupt_in, eps.bulk_in, eps.bulk_out);
      return false;
  }
  return false;
}

// The data profile from the service's RMNetProfile property (the personality in Info.plist sets it):
// an integer from 1 to 255. Anything else, or no such property, gives 1, with a log line.
uint8_t ReadProfile(IOService* service) {
  OSDictionary* props = nullptr;
  kern_return_t ret = service->CopyProperties(&props);
  uint8_t profile = kDefaultProfile;
  if (ret != kIOReturnSuccess || !props) {
    LOG("RMNetProfile: properties not readable (0x%x); using profile %u", ret, profile);
  } else {
    OSObject* obj = props->getObject(kProfileKey);
    OSNumber* num = OSDynamicCast(OSNumber, obj);
    if (!obj) {
      LOG("RMNetProfile: no such property; using profile %u", profile);
    } else if (!num) {
      LOG("RMNetProfile: not an integer; using profile %u", profile);
    } else if (num->unsigned64BitValue() < 1 || num->unsigned64BitValue() > 255) {
      LOG("RMNetProfile: %llu is not from 1 to 255; using profile %u", num->unsigned64BitValue(), profile);
    } else {
      profile = static_cast<uint8_t>(num->unsigned64BitValue());
    }
  }
  OSSafeReleaseNULL(props);
  return profile;
}

// Whether the session asks the modem for in-band flow control, from the service's RMNetFlowControl
// property (the personality in Info.plist sets it): the integer 1 asks. 0, any other value, or no
// such property does not ask; anything but 0 or 1 is logged.
bool ReadFlowControl(IOService* service) {
  OSDictionary* props = nullptr;
  kern_return_t ret = service->CopyProperties(&props);
  bool flowControl = false;
  if (ret != kIOReturnSuccess || !props) {
    LOG("RMNetFlowControl: properties not readable (0x%x); not asking for flow control", ret);
  } else {
    OSObject* obj = props->getObject(kFlowControlKey);
    OSNumber* num = OSDynamicCast(OSNumber, obj);
    if (!obj) {
      LOG("RMNetFlowControl: no such property; not asking for flow control");
    } else if (!num) {
      LOG("RMNetFlowControl: not an integer; not asking for flow control");
    } else if (num->unsigned64BitValue() > 1) {
      LOG("RMNetFlowControl: %llu is not 0 or 1; not asking for flow control", num->unsigned64BitValue());
    } else {
      flowControl = num->unsigned64BitValue() == 1;
    }
  }
  OSSafeReleaseNULL(props);
  return flowControl;
}

// Whether the emulator's DHCP server may answer a client that asks for it with the IPv6-Only
// Preferred option (RFC 8925, option 108) on a link whose IPv4 address is in 192.0.0.0/29
// (core/src/dhcp.cpp, top comment), from the service's RMNetIPv6OnlyPreferred property (the
// personality in Info.plist sets it: 0 there, 1 in a build made with RMNET_IPV6_ONLY_PREFERRED=1):
// the integer 1 turns it on. 0, any other value, or no such property leaves it off; anything but 0
// or 1 is logged. Off is the safe side: with it on where the network has no NAT64 (DS-Lite, say), a
// client would give up IPv4.
bool ReadIpv6OnlyPreferred(IOService* service) {
  OSDictionary* props = nullptr;
  kern_return_t ret = service->CopyProperties(&props);
  bool on = false;
  if (ret != kIOReturnSuccess || !props) {
    LOG("RMNetIPv6OnlyPreferred: properties not readable (0x%x); IPv6-only preferred off", ret);
  } else {
    OSObject* obj = props->getObject(kIpv6OnlyPreferredKey);
    OSNumber* num = OSDynamicCast(OSNumber, obj);
    if (!obj) {
      LOG("RMNetIPv6OnlyPreferred: no such property; IPv6-only preferred off");
    } else if (!num) {
      LOG("RMNetIPv6OnlyPreferred: not an integer; IPv6-only preferred off");
    } else if (num->unsigned64BitValue() > 1) {
      LOG("RMNetIPv6OnlyPreferred: %llu is not 0 or 1; IPv6-only preferred off", num->unsigned64BitValue());
    } else {
      on = num->unsigned64BitValue() == 1;
    }
  }
  OSSafeReleaseNULL(props);
  return on;
}

uint64_t NowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
uint64_t NowMs() { return NowNs() / 1000000ull; }

}  // namespace

// Forwards UsbIo's reports to the driver.
struct UsbBridge final : UsbIoListener {
  explicit UsbBridge(RMNetDriver* d) : driver(d) {}
  void on_control(const uint8_t* data, size_t len) override { driver->OnControl(data, len); }
  void on_fatal(const char* what) override { driver->OnUsbFatal(what); }
  void on_bulk_in(const uint8_t* data, size_t len) override { driver->OnBulkIn(data, len); }
  void on_bulk_out_done(int slot, bool ok) override { driver->OnBulkOutDone(slot, ok); }
  void on_uplink_stuck() override { driver->OnUplinkStuck(); }
  void on_uplink_usable() override { driver->OnUplinkUsable(); }
  RMNetDriver* driver;
};

// Gives CoreHost the driver's receive packets.
struct RxBridge final : RxSink {
  explicit RxBridge(RMNetDriver* d) : driver(d) {}
  uint8_t* rx_buffer(size_t* cap) override { return driver->RxBuffer(cap); }
  void rx_commit(size_t len) override { driver->RxCommit(len); }
  RMNetDriver* driver;
};

// What PublishCounters last published, in its order.
enum : uint32_t { kCounterCount = 61 };

struct RMNetDriver_IVars {
  IODispatchQueue* queue;  // the service's Default queue; everything runs on it
  IOUserNetworkPacketBufferPool* pool;
  IOUserNetworkTxSubmissionQueue* txSubmit;
  IOUserNetworkTxCompletionQueue* txComplete;
  IOUserNetworkRxSubmissionQueue* rxSubmit;
  IOUserNetworkRxCompletionQueue* rxComplete;
  OSAction* txAvailAction;
  OSAction* rxAvailAction;
  IOTimerDispatchSource* timer;
  OSAction* timerAction;
  bool timerArmFailed;         // the last WakeAtTime failed: no tick is due (EnsureTimer retries)
  uint64_t timerArmFailures;   // WakeAtTime failures since Start
  UsbBridge* bridge;
  RxBridge* rxBridge;
  UsbIo* usb;       // released objects only once its aborted completions have arrived
  CoreHost* core;
  bool stopping;
  // The stop sequence (TearDown, AdvanceStop): Draining sends what the session queued, Aborting
  // waits for the aborted requests, Done has passed Stop to the superclass.
  enum StopPhase : uint8_t { kStopNone, kStopDraining, kStopAborting, kStopDone } stopPhase;
  IOService* stopProvider;  // retained from TearDown until Stop is passed to the superclass
  uint64_t stopStartMs;
  uint64_t abortStartMs;
  bool usbFailed;
  bool usbDetached;  // usbFailed, and UsbIo had seen the device gone (not attached / no device)
  bool uplinkStuck;  // UsbIo asked for a session restart; acted on once its call has returned
  bool coreStopped;  // session.stop() was called; the Session is not called again
  bool linkActive;  // the link status last reported to the stack
  uint32_t mtu;     // what getMaxTransferUnit answers
  char published[256];  // the status last published, "state|ipv4|ipv6"; empty before the first
  // kLog* bits already logged. Nearly full: every bit is a kLog* flag except 1u << 4 (freed when
  // its line was removed); a line beyond that needs a wider field, kLog* enum and FirstCall.
  uint32_t logged;
  // The data path's packets. Empty packets taken from the RX submission queue in one call wait in
  // rxStock (the last one, rxStock[rxStockCount - 1], is the buffer CoreHost is filling) until they
  // are filled; filled ones wait in rxOut, and sent ones in txDone, until their completion queue
  // takes them (leftovers go first next time, so the pool does not shrink). rxOutCounted and
  // txDoneCounted: how many of those leftovers, the oldest at the front, are already counted as
  // refused (rxCompleteRefused, txCompleteRefused), so a packet refused again is not counted again.
  IOUserNetworkPacket* rxStock[kRxStock];
  uint32_t rxStockCount;
  IOUserNetworkPacket* rxOut[kRxHold];
  uint32_t rxOutCount;
  uint32_t rxOutCounted;
  IOUserNetworkPacket* txDone[kTxHold];
  uint32_t txDoneCount;
  uint32_t txDoneCounted;
  uint64_t rxCompleteRefused;  // filled receive packets the RX completion queue refused, each once
  uint64_t txCompleteRefused;  // sent packets the TX completion queue refused, each once
  bool txHeld;  // frames may wait in the TX submission queue (paused, or no room in txDone)
  // Frames of a batch taken from the TX submission queue that are not yet placed: txPending[txPendingNext]
  // up to txPendingCount, offered first, in order, before a new batch is taken. txWaitUplink: the
  // drain stopped because every uplink buffer was in flight; a transfer that frees one (a success,
  // or a failure UsbIo reports as uplink usable), the end of a recovery whose ClearStall succeeded,
  // a link down or the tick restarts it.
  IOUserNetworkPacket* txPending[kTxBatch];
  uint32_t txPendingCount;
  uint32_t txPendingNext;
  bool txWaitUplink;
  uint64_t txHolds;  // hold episodes: times txWaitUplink went from false to true
  uint64_t uplinkUsable;   // on_uplink_usable callbacks received
  // Timer ticks that drained because txHeld, txWaitUplink or txDoneCount > 0; and ticks that found
  // filled receive packets waiting in rxOut before their first FlushRx.
  uint64_t tickTxDrains;
  uint64_t tickRxFlushes;
  uint32_t ticks;
  uint64_t rxLagMaxUs;  // the longest a successful bulk read waited between completing and its handler
  // The longest and the summed time of the handler of a successful bulk read (BulkInComplete_Impl
  // up to the return of UsbIo::bulk_in_complete, the re-post included), while not stopping. Not
  // counted until the receive path's first-call log lines are behind it: rxReadSeen (a successful
  // read was handled, so "BulkInComplete" and UsbIo's "first bulk read" are logged) and the
  // "first rx packet" line.
  uint64_t rxHandlerMaxNs;
  uint64_t rxHandlerTotalNs;
  bool rxReadSeen;
  // Sleep (SetPowerState): asleep from a power-off call to the next power-on call. While asleep
  // UsbIo is held and nothing calls Core: no tick, no drain. resumePending: the wake's first
  // resume found the bus not ready; until a later attempt (one per tick) resumes UsbIo, or the
  // deadline, a fatal error, a power-off or Stop ends it, the driver behaves as while asleep (every
  // check of asleep also checks it). wakeUpPending: the wake restarted the session and its link up
  // has not come yet; lastWakeUpMs is the time from that wake call to the link up (0 until then).
  // wakeRetries: resume attempts after the first of their wake, since start; wakeRetriesNow: the
  // same for the current wake only (reset by its first attempt).
  bool asleep;
  bool resumePending;
  bool wakeUpPending;
  uint64_t sleeps;
  uint64_t wakes;
  uint64_t wakeStartMs;
  uint64_t lastWakeUpMs;
  uint64_t wakeRetries;
  uint64_t wakeRetriesNow;
  uint32_t lastPowerFlags;
  uint32_t txQueueCapacity;  // the TX submission queue's capacity once made (0 until then)
  bool countersPublished;
  uint64_t counters[kCounterCount];
};

namespace {

// Creates the TX submission queue with `capacity` into ivars->txSubmit, which is set only on success
// (and txQueueCapacity with it). Whatever a failed Create may have handed back is released here.
kern_return_t CreateTxSubmitQueue(RMNetDriver_IVars* ivars, IOService* owner, uint32_t capacity) {
  IOUserNetworkTxSubmissionQueue* q = nullptr;
  kern_return_t ret = IOUserNetworkTxSubmissionQueue::Create(ivars->pool, owner, capacity, 0, ivars->queue, &q);
  if (ret != kIOReturnSuccess) {
    OSSafeReleaseNULL(q);
    return ret;
  }
  ivars->txSubmit = q;
  ivars->txQueueCapacity = capacity;
  return kIOReturnSuccess;
}

}  // namespace

bool RMNetDriver::FirstCall(uint32_t flag) {
  if (!ivars || (ivars->logged & flag)) return false;
  ivars->logged |= flag;
  return true;
}

bool RMNetDriver::init() {
  if (!super::init()) return false;
  ivars = IONewZero(RMNetDriver_IVars, 1);
  if (!ivars) return false;
  ivars->mtu = kMtu;
  LOG_FIRST(kLogInit, "init");
  return true;
}

// Objects are released here rather than in Stop, so nothing still queued on the Default queue can
// reach a released object. UsbIo has normally released its USB objects already (after the last
// aborted completion); deleting it releases whatever is left.
void RMNetDriver::free() {
  LOG_FIRST(kLogFree, "free");
  if (ivars) {
    delete ivars->core;
    ivars->core = nullptr;
    delete ivars->usb;
    ivars->usb = nullptr;
    delete ivars->bridge;
    ivars->bridge = nullptr;
    delete ivars->rxBridge;
    ivars->rxBridge = nullptr;
    OSSafeReleaseNULL(ivars->timer);
    OSSafeReleaseNULL(ivars->timerAction);
    OSSafeReleaseNULL(ivars->txAvailAction);
    OSSafeReleaseNULL(ivars->rxAvailAction);
    OSSafeReleaseNULL(ivars->txSubmit);
    OSSafeReleaseNULL(ivars->txComplete);
    OSSafeReleaseNULL(ivars->rxSubmit);
    OSSafeReleaseNULL(ivars->rxComplete);
    OSSafeReleaseNULL(ivars->pool);
    OSSafeReleaseNULL(ivars->queue);
  }
  IOSafeDeleteNULL(ivars, RMNetDriver_IVars, 1);
  super::free();
}

// Order (docs/driverkit-notes.md 3.9): check the provider (CheckQmiInterface: IOKit matched its
// number, so what guards is its class, subclass and protocol 0xff and the QMI endpoints; nothing is
// opened before the check), open USB and read the serial number, create Core, the interface with
// the MAC derived from the serial, the timer, then DTR and the interrupt read, then the session. A
// failure tears down what was made and fails Start. Failures to report the link status or publish
// properties do not fail Start (see ReportLink and PublishStatus).
kern_return_t RMNetDriver::Start_Impl(IOService* provider) {
  LOG_FIRST(kLogStart, "Start");
  kern_return_t ret = Start(provider, SUPERDISPATCH);
  if (ret != kIOReturnSuccess) {
    LOG("super Start failed 0x%x", ret);
    return ret;
  }
  uint8_t qmiInterface = ReadQmiInterface(this);
  if (!CheckQmiInterface(provider, qmiInterface)) ret = kIOReturnUnsupported;
  if (ret == kIOReturnSuccess) ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  if (ret == kIOReturnSuccess) ret = OpenUsb(provider);

  rmnet::MacPair macs{};
  if (ret == kIOReturnSuccess) {
    char serial[64];
    ivars->usb->read_serial(serial, sizeof serial);
    if (serial[0] == '\0') {
      LOG("no USB serial number; MACs derived from \"unknown\"");
      macs = rmnet::derive_macs("unknown");
    } else {
      macs = rmnet::derive_macs(serial);
    }
    LOG("serial number of %zu characters, host MAC %02x:%02x:%02x:%02x:%02x:%02x", strlen(serial), macs.host[0],
        macs.host[1], macs.host[2], macs.host[3], macs.host[4], macs.host[5]);
    uint8_t profile = ReadProfile(this);
    LOG("profile %u", profile);
    PublishProfile(profile);
    bool flowControl = ReadFlowControl(this);
    LOG("flow control %u", flowControl ? 1u : 0u);
    bool v6OnlyPreferred = ReadIpv6OnlyPreferred(this);
    LOG("IPv6-only preferred %u", v6OnlyPreferred ? 1u : 0u);
    PublishIpv6OnlyPreferred(v6OnlyPreferred);
    ivars->rxBridge = new RxBridge(this);
    if (ivars->rxBridge) {
      ivars->core =
          new CoreHost(*ivars->usb, *ivars->rxBridge, macs, profile, flowControl, qmiInterface, v6OnlyPreferred);
    }
    if (!ivars->core) ret = kIOReturnNoMemory;
  }
  if (ret == kIOReturnSuccess) ret = CreateInterface(macs.host);
  if (ret == kIOReturnSuccess) ret = StartTimer();
  if (ret == kIOReturnSuccess) ret = ivars->usb->start();
  if (ret == kIOReturnSuccess) {
    ivars->core->start(NowMs());
    ApplyCore();
    PublishStatus();
    ret = RegisterService();
  }
  if (ret != kIOReturnSuccess) {
    LOG("Start failed 0x%x", ret);
    TearDown(provider);  // passes Stop to the superclass, at once or once USB has quiesced
    return ret;
  }
  LOG("started; TX submission queue capacity %u", ivars->txQueueCapacity);
  return kIOReturnSuccess;
}

// UsbIo opens the interface with completion actions made here; it holds its own references.
kern_return_t RMNetDriver::OpenUsb(IOService* provider) {
  IOUSBHostInterface* intf = OSDynamicCast(IOUSBHostInterface, provider);
  if (!intf) return kIOReturnUnsupported;
  ivars->bridge = new UsbBridge(this);
  if (!ivars->bridge) return kIOReturnNoMemory;
  ivars->usb = new UsbIo(*ivars->bridge);
  if (!ivars->usb) return kIOReturnNoMemory;

  UsbIoActions actions{};
  kern_return_t ret = CreateActionInterruptComplete(0, &actions.interrupt);
  if (ret == kIOReturnSuccess) ret = CreateActionControlOutComplete(0, &actions.control_out);
  if (ret == kIOReturnSuccess) ret = CreateActionControlInComplete(0, &actions.control_in);
  for (uint32_t i = 0; i < kBulkReads && ret == kIOReturnSuccess; i++) {
    ret = CreateActionBulkInComplete(sizeof(uint32_t), &actions.bulk_in[i]);
  }
  for (uint32_t i = 0; i < kUplinkSlots && ret == kIOReturnSuccess; i++) {
    ret = CreateActionBulkOutComplete(sizeof(uint32_t), &actions.bulk_out[i]);
  }
  if (ret == kIOReturnSuccess) ret = ivars->usb->open(this, intf, actions);
  OSSafeReleaseNULL(actions.interrupt);
  OSSafeReleaseNULL(actions.control_out);
  OSSafeReleaseNULL(actions.control_in);
  for (uint32_t i = 0; i < kBulkReads; i++) OSSafeReleaseNULL(actions.bulk_in[i]);
  for (uint32_t i = 0; i < kUplinkSlots; i++) OSSafeReleaseNULL(actions.bulk_out[i]);
  if (ret != kIOReturnSuccess) LOG("USB open failed 0x%x", ret);
  return ret;
}

// The pool, the four packet queues and their handlers, then the Ethernet interface itself, with
// the link reported inactive.
kern_return_t RMNetDriver::CreateInterface(const uint8_t* hostMac) {
  IOUserNetworkPacketBufferPoolOptions opts{};
  opts.packetCount = kPacketCount;
  opts.bufferCount = kPacketCount;
  opts.bufferSize = kPacketBufSize;
  opts.maxBuffersPerPacket = 1;
  opts.poolFlags = PoolFlagMapToDext;
  kern_return_t ret = IOUserNetworkPacketBufferPool::CreateWithOptions(this, "RMNetPool", &opts, &ivars->pool);
  if (ret != kIOReturnSuccess) return ret;

  ret = CreateTxSubmitQueue(ivars, this, kTxQueueCapacity);
  if (ret != kIOReturnSuccess) {
    // Nothing documents which capacities Create accepts; kQueueCapacity has worked on every load.
    LOG("TX submission queue of %u refused 0x%x; trying %u", kTxQueueCapacity, ret, kQueueCapacity);
    ret = CreateTxSubmitQueue(ivars, this, kQueueCapacity);
  }
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkTxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->txComplete);
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkRxSubmissionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->rxSubmit);
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkRxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->rxComplete);
  if (ret != kIOReturnSuccess) return ret;

  IODataQueueDispatchSource* dq = nullptr;
  ret = CreateActionTxPacketsAvailable(0, &ivars->txAvailAction);
  if (ret != kIOReturnSuccess) return ret;
  ret = ivars->txSubmit->CopyDataQueue(&dq);
  if (ret != kIOReturnSuccess) return ret;
  ret = dq->SetDataAvailableHandler(ivars->txAvailAction);
  OSSafeReleaseNULL(dq);
  if (ret != kIOReturnSuccess) return ret;

  ret = CreateActionRxPacketsAvailable(0, &ivars->rxAvailAction);
  if (ret != kIOReturnSuccess) return ret;
  ret = ivars->rxSubmit->CopyDataQueue(&dq);
  if (ret != kIOReturnSuccess) return ret;
  ret = dq->SetDataAvailableHandler(ivars->rxAvailAction);
  OSSafeReleaseNULL(dq);
  if (ret != kIOReturnSuccess) return ret;

  ether_addr_t mac;
  memcpy(mac.octet, hostMac, sizeof(mac.octet));
  IOUserNetworkPacketQueue* queues[] = {ivars->txSubmit, ivars->txComplete, ivars->rxSubmit, ivars->rxComplete};
  ret = RegisterEthernetInterface(mac, ivars->pool, queues, 4);
  if (ret != kIOReturnSuccess) return ret;

  // setMaxTransferUnit here fails with kIOReturnUnsupported (first load); getMaxTransferUnit
  // gives the stack the MTU instead. A link status reported here is lost (configd ran DHCP on the
  // port), so it is reported again once the stack enables the interface. Neither fails Start.
  ReportLink();
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::StartTimer() {
  kern_return_t ret = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
  if (ret == kIOReturnSuccess) ret = CreateActionTimerFired(0, &ivars->timerAction);
  if (ret == kIOReturnSuccess) ret = ivars->timer->SetHandler(ivars->timerAction);
  if (ret == kIOReturnSuccess) ArmTimer();
  return ret;
}

// The timer is one-shot: re-armed after every tick. A failure is remembered (timerArmFailed) and
// EnsureTimer tries again from every other entry into the driver; until one succeeds no tick is due.
// Both lines are logged only when the failure count is a power of two, so a timer that keeps failing
// and recovering cannot flood the log.
void RMNetDriver::ArmTimer() {
  kern_return_t ret = ivars->timer->WakeAtTime(kIOTimerClockUptimeRaw, NowNs() + kTickNs, kTickLeewayNs);
  uint64_t n = ivars->timerArmFailures;
  bool worth = (n & (n - 1)) == 0;
  if (ret == kIOReturnSuccess) {
    if (ivars->timerArmFailed && worth) LOG("timer armed again after %llu failures", n);
    ivars->timerArmFailed = false;
    return;
  }
  ivars->timerArmFailed = true;
  n = ++ivars->timerArmFailures;
  if ((n & (n - 1)) == 0) LOG("timer not armed: 0x%x (%llu failures)", ret, n);
}

// Called from every completion handler, TxPacketsAvailable and RxPacketsAvailable: if the last arm
// failed, the timer is armed again, so the tick (Core's tick, the counters, the stall-recovery
// deadline, the held drain, and while stopping the two deadlines of AdvanceStop) resumes. Never
// once the stop sequence is done (FinishStop sets kStopDone before it cancels the timer), so a
// cancelled timer is never armed.
void RMNetDriver::EnsureTimer() {
  if (!ivars || !ivars->timerArmFailed || !ivars->timer) return;
  if (ivars->stopPhase == RMNetDriver_IVars::kStopDone) return;
  ArmTimer();
}

// The stop sequence, shared by Stop and a failed Start (docs/driverkit-notes.md 3.9):
// 1. stopping; the session stops and queues its releases; the link is reported inactive and the
//    queues are disabled. Core is not called again.
// 2. Draining: the control ring keeps sending, until it is empty, a request fails, or
//    kStopDrainMs after the start.
// 3. Aborting: the pipes and control requests are aborted; wait until none is outstanding, or
//    kStopAbortMs.
// 4. Close the interface, release the USB objects, pass Stop to the superclass.
// Nothing blocks: AdvanceStop runs after every USB completion and on every timer tick (the timer
// is kept running until step 4 and is the clock for both deadlines). Stop always finishes: past
// the second deadline it is passed on with requests still outstanding, and that is logged.
void RMNetDriver::TearDown(IOService* provider) {
  if (ivars->stopping) return;
  ivars->stopping = true;
  ivars->stopProvider = provider;
  provider->retain();
  ivars->stopStartMs = NowMs();
  ivars->wakeUpPending = false;  // no link up can follow now: none is measured from an old wake
  ivars->resumePending = false;  // nothing is retried once stopping: finish_sending ends the hold
  // Not again if OnUsbFatal already stopped the session: Core is not called after stop().
  if (ivars->core && !ivars->coreStopped) {
    ivars->coreStopped = true;
    ivars->core->stop();
    ivars->core->take_link_change();
  }
  if (ivars->usb) LOG("stop: %u control messages queued", ivars->usb->queued());
  ivars->linkActive = false;
  if (ivars->txSubmit) ReportLink();
  if (ivars->txSubmit) ivars->txSubmit->setEnable(false);
  if (ivars->txComplete) ivars->txComplete->setEnable(false);
  if (ivars->rxSubmit) ivars->rxSubmit->setEnable(false);
  if (ivars->rxComplete) ivars->rxComplete->setEnable(false);
  ivars->stopPhase = RMNetDriver_IVars::kStopDraining;
  if (ivars->usb) ivars->usb->finish_sending();
  AdvanceStop();
}

void RMNetDriver::AdvanceStop() {
  uint64_t now = NowMs();
  UsbIo* usb = ivars->usb;
  if (ivars->stopPhase == RMNetDriver_IVars::kStopDraining) {
    bool late = now - ivars->stopStartMs >= kStopDrainMs;
    // Without the timer there is no clock for the deadline; nothing was ever posted then.
    // A failed arm counts as no timer: no tick may come to end the wait.
    if (usb && !usb->sending_done() && !late && ivars->timer && !ivars->timerArmFailed) return;
    if (usb) {
      usb->abort();
      LOG("stop: control messages sent %u, dropped %u%{public}s; aborted with %u requests outstanding",
          usb->sent_at_stop(), usb->dropped_at_stop(), late ? " (drain deadline)" : "", usb->outstanding());
    }
    ivars->stopPhase = RMNetDriver_IVars::kStopAborting;
    ivars->abortStartMs = now;
  }
  if (ivars->stopPhase == RMNetDriver_IVars::kStopAborting) {
    if (usb && usb->outstanding() > 0) {
      if (now - ivars->abortStartMs < kStopAbortMs && ivars->timer && !ivars->timerArmFailed) return;
      // Close also aborts; the objects are left to free(), which may run before they return.
      LOG("stop: %u aborted requests still outstanding after %llu ms; passing Stop on anyway",
          usb->outstanding(), now - ivars->abortStartMs);
      usb->close();
    } else if (usb) {
      usb->close_and_release();
      LOG("stop: usb objects released");
    }
    FinishStop();
  }
}

void RMNetDriver::FinishStop() {
  ivars->stopPhase = RMNetDriver_IVars::kStopDone;
  ivars->timerArmFailed = false;  // the timer is cancelled: nothing arms it again (EnsureTimer)
  if (ivars->timer) ivars->timer->Cancel(^{});
  IOService* provider = ivars->stopProvider;
  ivars->stopProvider = nullptr;
  LOG("stop: passing Stop to the superclass");
  kern_return_t ret = Stop(provider, SUPERDISPATCH);
  if (ret != kIOReturnSuccess) LOG("super Stop 0x%x", ret);
  OSSafeReleaseNULL(provider);
}

// Starts the stop sequence and returns; the superclass gets Stop when USB has quiesced.
kern_return_t RMNetDriver::Stop_Impl(IOService* provider) {
  LOG_FIRST(kLogStop, "Stop");
  TearDown(provider);
  return kIOReturnSuccess;
}

// Sleep and wake (docs/driverkit-notes.md 3.8). Called by the system on the Default queue, as a
// call of its own: never from inside a Core call or a UsbIo listener call, so RestartSession may be
// called here. Every call is logged and always passed to the superclass.
// - Power off (the system is going to sleep): nothing is sent and Core is not called (the bus is
//   about to suspend, and transfers failing around the suspend must not count toward UsbIo's
//   failure limits). The driver marks itself asleep and holds UsbIo.
// - Power on after a sleep: UsbIo resumes (its failure memory cleared, its reads posted again)
//   and the session restarts from sync, taking the link down first, so the port ends up with the
//   new call's addresses or down, never up with the old ones. If USB failed or the device went
//   during the sleep, nothing more: a new instance follows the re-enumeration. If the bus refuses a
//   post and has not gone, the resume is pending: tried again from every tick (ResumeUsb), the
//   driver behaving as while asleep meanwhile, until it succeeds or kResumeRetryMs after the wake
//   call, when a refusal is fatal as before.
// - A power off while the resume is pending ends it; the next power on is a fresh wake.
// - Anything else (power on while not asleep, pending or not, a second power off, low power):
//   nothing.
kern_return_t RMNetDriver::SetPowerState_Impl(uint32_t powerFlags) {
  LOG("SetPowerState 0x%x%{public}s", powerFlags,
      !ivars ? ""
             : (ivars->asleep ? " (asleep)"
                              : (ivars->resumePending ? " (resume pending)" : (ivars->stopping ? " (stopping)" : ""))));
  if (ivars) {
    ivars->lastPowerFlags = powerFlags;
    if (powerFlags == kIOServicePowerCapabilityOff) {
      PowerOff();
    } else if (powerFlags & kIOServicePowerCapabilityOn) {
      PowerOn(powerFlags);
    }
    if (!ivars->stopping && ivars->core && ivars->usb) PublishCounters();
  }
  // Like every other entry into the driver, retries a failed arm. At a wake this is what restarts
  // everything periodic: the liveness probe, the sync resends.
  EnsureTimer();
  return SetPowerState(powerFlags, SUPERDISPATCH);  // must reach the superclass to acknowledge
}

void RMNetDriver::PowerOff() {
  if (ivars->asleep) {
    LOG("power off: already asleep, nothing new");
    return;
  }
  bool wasPending = ivars->resumePending;
  ivars->resumePending = false;  // the next power on starts a fresh wake, with a fresh deadline
  ivars->asleep = true;
  ivars->sleeps++;
  LOG("power off: asleep (sleep %llu); the session is left as it is until the wake%{public}s", ivars->sleeps,
      wasPending ? " (the last wake's resume was still pending)" : "");
  if (ivars->usb && !ivars->stopping) ivars->usb->hold();  // still held if pending: only resets its attempts
}

void RMNetDriver::PowerOn(uint32_t powerFlags) {
  if (!ivars->asleep) {
    LOG("power on 0x%x: not asleep, nothing to do", powerFlags);
    return;
  }
  ivars->asleep = false;
  ivars->wakes++;
  ivars->wakeStartMs = NowMs();
  ivars->lastWakeUpMs = 0;
  ivars->wakeUpPending = false;
  if (ivars->stopping || !ivars->usb || !ivars->core) {
    LOG("wake %llu: stopping, nothing to do", ivars->wakes);
    return;
  }
  if (ivars->usbFailed) {
    LOG("wake %llu: usb had failed; nothing more (a new instance follows re-enumeration)", ivars->wakes);
    return;
  }
  if (ivars->usb->device_gone()) {
    // The link may still be reported up with the old call's addresses, and Stop may not have come
    // yet: take it down now, with the state "detached".
    LOG("wake %llu: the device went during the sleep; nothing more (a new instance follows re-enumeration)",
        ivars->wakes);
    OnUsbFatal("device gone during the sleep");
    return;
  }
  LOG("wake %llu: resuming usb and restarting the session", ivars->wakes);
  ResumeUsb();  // SetPowerState_Impl then retries a failed timer arm (EnsureTimer)
}

// One attempt to resume UsbIo for the current wake: PowerOn makes the first; while it leaves the
// resume pending, every timer tick makes one more (TimerFired_Impl), the last once kResumeRetryMs
// have passed since the wake call. Resumed: the session restarts from sync, as after any wake. Not
// yet: pending, the driver behaving as while asleep. Failed: UsbIo reported it (on_fatal), or USB
// had failed already; nothing more. Never once stopping, after a fatal error or after a new power
// off: each of those clears resumePending, and only TimerFired_Impl calls this while it is set.
void RMNetDriver::ResumeUsb() {
  bool first = !ivars->resumePending;
  ivars->resumePending = false;
  if (first) {
    ivars->wakeRetriesNow = 0;
  } else {
    if (ivars->usb->device_gone()) {
      // As at the wake call: take the link down, with the state "detached".
      LOG("wake %llu: the device went while its resume was pending; nothing more", ivars->wakes);
      OnUsbFatal("device gone before usb resumed");
      return;
    }
    ivars->wakeRetries++;
    ivars->wakeRetriesNow++;
  }
  bool lastTry = NowMs() - ivars->wakeStartMs >= kResumeRetryMs;
  UsbIo::Resume r = ivars->usb->resume(lastTry);
  if (r == UsbIo::Resume::NotYet) {
    ivars->resumePending = true;
    if (first) {
      LOG("wake %llu: usb not ready; tried again every tick for up to %u ms", ivars->wakes,
          (unsigned)kResumeRetryMs);
    }
    return;
  }
  if (r == UsbIo::Resume::Failed) return;  // already reported as usb failed
  if (!first) {
    LOG("wake %llu: usb resumed on retry %llu (%llu retries since start)", ivars->wakes, ivars->wakeRetriesNow,
        ivars->wakeRetries);
  }
  ivars->wakeUpPending = true;
  RestartSession("wake");
}

// Reports the link status last decided (ivars->linkActive). A failure is logged and does not
// fail the caller: the status is reported again whenever the stack enables the interface.
IOReturn RMNetDriver::ReportLink() {
  LinkStatus status = ivars->linkActive ? kIOUserNetworkLinkStatusActive : kIOUserNetworkLinkStatusInactive;
  IOReturn ret = reportLinkStatus(status, kIOUserNetworkMediaEthernetAuto);
  if (ret != kIOReturnSuccess) LOG("reportLinkStatus %d: 0x%x", ivars->linkActive, ret);
  return ret;
}

// --- Session ------------------------------------------------------------------------------------

// One QMUX frame from the modem (UsbIo, from a response read's completion).
void RMNetDriver::OnControl(const uint8_t* data, size_t len) {
  if (ivars->stopping || !ivars->core || ivars->coreStopped) return;
  ivars->core->on_control(data, len, NowMs());
  ApplyCore();
}

// USB stopped for good (the interrupt read keeps failing, a bulk pipe cannot be recovered, the
// uplink keeps timing out, the device has gone). The session cannot continue: stop it and report
// the link down. It is not restarted; a re-enumeration starts afresh. RMNetState says "detached"
// rather than "usb failed" when UsbIo had seen a not-attached or no-device status by then: the
// device went away. A modem reboot does not show that: its interrupt read ends aborted
// (kIOReturnAborted, 0xe00002eb) and the re-post is refused with not-ready (kIOReturnNotReady,
// 0xe00002d8); neither counts as gone (a device still attached can return not-ready around a wake),
// so the old instance shows "usb failed" for a few milliseconds before Stop.
void RMNetDriver::OnUsbFatal(const char* what) {
  bool gone = ivars->usb && ivars->usb->device_gone();
  LOG("usb failed: %{public}s%{public}s", what, gone ? " (device gone)" : "");
  ivars->usbFailed = true;
  ivars->usbDetached = gone;
  ivars->wakeUpPending = false;  // the session is not restarted, so the wake's link up never comes
  ivars->resumePending = false;  // nor is a pending resume tried again
  if (ivars->stopping || !ivars->core) return;
  ivars->core->drop_kept_replies();  // they will never find an uplink buffer (not the Session)
  if (ivars->coreStopped) return;
  ivars->coreStopped = true;
  ivars->core->stop();
  ApplyCore();
}

// Stops the session and starts it again from sync (CoreHost::restart), then applies the link down
// it recorded, so the port reports link down, and link up again when the new call comes up. The one
// case where the Session is called after a stop. Never while stopping, after a fatal USB error, or
// once the session was stopped for good (coreStopped, which only those two set): the wish is then
// dropped, with a log line. Called only after a Core call has returned, never from a Core callback.
void RMNetDriver::RestartSession(const char* why) {
  if (!ivars->core || ivars->stopping || ivars->usbFailed || ivars->coreStopped) {
    LOG("session restart (%{public}s) not made: %{public}s", why,
        ivars->stopping ? "stopping" : (ivars->usbFailed ? "usb failed" : "session stopped"));
    return;
  }
  LOG("session restart: %{public}s", why);
  ivars->core->restart(NowMs());
  ApplyCore();
}

// Applies what the last Core call decided, now that it has returned: link down, then link up
// (both, in that order, for a bounce). A second link up while the link is up means a family was
// added: the emulator, the MTU and the properties are updated, a router advertisement goes out if
// IPv6 is new, and the link stays active. The data path is updated last, after the link is
// reported, because starting the bulk reads can fail and stop the session (OnUsbFatal, which
// applies its own link down). After a link down a drain held for want of an uplink buffer runs at
// once, unless lifting a pause has already drained: with the link down its kept frames need no
// buffer, and go through CoreHost::transmit to be dropped as link down (CoreHost::restart says the
// same); after a bounce (down, then up) they are only offered again.
void RMNetDriver::ApplyCore() {
  CoreHost::LinkChange c = ivars->core->take_link_change();
  if (c.down) {
    ivars->core->data_link_down();
    ivars->mtu = kMtu;
    if (ivars->linkActive) {
      ivars->linkActive = false;
      ReportLink();
    }
    LOG("link down");
  }
  if (c.up) {
    const rmnet::RuntimeSettings& s = ivars->core->link_config().settings;
    uint32_t mtu = s.mtu;
    if (mtu == 0 || mtu > kMtu) mtu = kMtu;
    if (mtu < kMinMtu) mtu = kMinMtu;
    ivars->mtu = mtu;
    IOReturn mret = setMaxTransferUnit(mtu);
    bool again = ivars->linkActive;
    if (!again) {
      ivars->linkActive = true;
      ReportLink();
    }
    LOG("link up%{public}s: ipv4 %d ipv6 %d, carrier mtu %u; setMaxTransferUnit(%u) 0x%x%{public}s",
        again ? " (family added)" : "", s.has_v4, s.has_v6, s.mtu, mtu, mret,
        mret == kIOReturnSuccess ? "" : ", so the interface keeps the mtu it registered with");
    if (!again && ivars->wakeUpPending) {
      ivars->wakeUpPending = false;
      uint64_t ms = NowMs() - ivars->wakeStartMs;
      ivars->lastWakeUpMs = ms > 0 ? ms : 1;
      LOG("link up %llu ms after the wake", ms);
    }
    ivars->core->data_link_up(NowMs());
  }
  PublishStatus();
  FlushRx();  // a router advertisement
  if (ivars->core->take_uplink_resumed()) DrainTx();
  if (c.down && ivars->txWaitUplink) DrainTx();  // still held: no pause was lifted
}

// Publishes the profile in use as RMNetProfile, over the personality's value, so the registry shows
// what the session asks for. A failure is logged and does not fail Start.
void RMNetDriver::PublishProfile(uint8_t profile) {
  OSDictionary* props = OSDictionary::withCapacity(1);
  OSNumber* n = OSNumber::withNumber(static_cast<uint64_t>(profile), 32);
  if (props && n) {
    props->setObject(kProfileKey, n);
    kern_return_t ret = SetProperties(props);
    if (ret != kIOReturnSuccess) LOG("SetProperties (profile) 0x%x", ret);
  }
  OSSafeReleaseNULL(n);
  OSSafeReleaseNULL(props);
}

// Publishes whether IPv6-only preferred is on as RMNetIPv6OnlyPreferred (0 or 1), over the
// personality's value, so the registry shows what the DHCP server does, whatever the personality
// held. A failure is logged and does not fail Start.
void RMNetDriver::PublishIpv6OnlyPreferred(bool on) {
  OSDictionary* props = OSDictionary::withCapacity(1);
  OSNumber* n = OSNumber::withNumber(static_cast<uint64_t>(on ? 1 : 0), 32);
  if (props && n) {
    props->setObject(kIpv6OnlyPreferredKey, n);
    kern_return_t ret = SetProperties(props);
    if (ret != kIOReturnSuccess) LOG("SetProperties (IPv6-only preferred) 0x%x", ret);
  }
  OSSafeReleaseNULL(n);
  OSSafeReleaseNULL(props);
}

// Status for the host app: properties on this service in the I/O registry. Republished only when
// something changed. A failure is logged and does not fail the caller: the status is for the
// app, and the driver works without it.
void RMNetDriver::PublishStatus() {
  char state[24];
  char v4[64] = "none";
  char v6[80] = "none";
  const char* name = SessionStateName(ivars->core->state());
  if (ivars->usbFailed) name = ivars->usbDetached ? "detached" : "usb failed";
  // While asleep (or its resume pending) a gone device is not fatal (UsbIo is held), but the state
  // says so.
  else if ((ivars->asleep || ivars->resumePending) && ivars->usb && ivars->usb->device_gone()) name = "detached";
  snprintf(state, sizeof state, "%s", name);
  if (ivars->linkActive) {
    const rmnet::RuntimeSettings& s = ivars->core->link_config().settings;
    if (s.has_v4) rmnet::format_ipv4(s, v4, sizeof v4);
    if (s.has_v6) rmnet::format_ipv6(s, v6, sizeof v6);
  }
  char key[sizeof ivars->published];
  snprintf(key, sizeof key, "%s|%s|%s", state, v4, v6);
  if (strcmp(key, ivars->published) == 0) return;

  OSDictionary* props = OSDictionary::withCapacity(3);
  OSString* st = OSString::withCString(state);
  OSString* a4 = OSString::withCString(v4);
  OSString* a6 = OSString::withCString(v6);
  if (props && st && a4 && a6) {
    props->setObject("RMNetState", st);
    props->setObject("RMNetIPv4", a4);
    props->setObject("RMNetIPv6", a6);
    kern_return_t ret = SetProperties(props);
    if (ret != kIOReturnSuccess) {
      LOG("SetProperties 0x%x", ret);
    } else {
      strlcpy(ivars->published, key, sizeof ivars->published);
    }
  }
  OSSafeReleaseNULL(st);
  OSSafeReleaseNULL(a4);
  OSSafeReleaseNULL(a6);
  OSSafeReleaseNULL(props);
}

// --- Network stack callbacks ---------------------------------------------------------------------

// Reached through the base class's setInterfaceEnable, which the stack calls first.
kern_return_t RMNetDriver::SetInterfaceEnable_Impl(bool isEnable) {
  LOG_FIRST(kLogSetInterfaceEnable, "SetInterfaceEnable %d", isEnable);
  ivars->txSubmit->setEnable(isEnable);
  ivars->txComplete->setEnable(isEnable);
  ivars->rxSubmit->setEnable(isEnable);
  ivars->rxComplete->setEnable(isEnable);
  if (isEnable) ReportLink();
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::SetPromiscuousModeEnable_Impl(bool enable) {
  LOG_FIRST(kLogSetPromiscuous, "SetPromiscuousModeEnable %d", enable);
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::SetAllMulticastModeEnable_Impl(bool enable) {
  LOG_FIRST(kLogSetAllMulticast, "SetAllMulticastModeEnable %d", enable);
  return kIOReturnSuccess;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
kern_return_t RMNetDriver::SelectMediaType_Impl(IOUserNetworkMediaType mediaType) {
  LOG_FIRST(kLogSelectMediaType, "SelectMediaType 0x%x", mediaType);
  return kIOReturnSuccess;
}
#pragma clang diagnostic pop

// Replaces the deprecated ReportAvailableMediaTypes: the framework asks for the media list. A call
// without an array, or with no room, is answered with the count alone.
IOReturn RMNetDriver::getSupportedMediaArray(MediaWord* mediaArray, uint32_t* mediaCount) {
  LOG_FIRST(kLogGetSupportedMedia, "getSupportedMediaArray array %d count %u", mediaArray != nullptr,
            mediaCount ? *mediaCount : 0);
  if (!mediaCount) return kIOReturnBadArgument;
  if (mediaArray && *mediaCount >= 1) mediaArray[0] = kIOUserNetworkMediaEthernetAuto;
  *mediaCount = 1;
  return kIOReturnSuccess;
}

IOReturn RMNetDriver::setMulticastAddresses(const ether_addr_t*, uint32_t count) {
  LOG_FIRST(kLogSetMulticastAddresses, "setMulticastAddresses %u", count);
  return kIOReturnSuccess;
}

IOReturn RMNetDriver::setInterfaceEnable(bool enable) {
  LOG_FIRST(kLogSetInterfaceEnableLower, "setInterfaceEnable %d", enable);
  return super::setInterfaceEnable(enable);
}

IOReturn RMNetDriver::setPromiscuousModeEnable(bool enable) {
  LOG_FIRST(kLogSetPromiscuousLower, "setPromiscuousModeEnable %d", enable);
  return super::setPromiscuousModeEnable(enable);
}

IOReturn RMNetDriver::setAllMulticastModeEnable(bool enable) {
  LOG_FIRST(kLogSetAllMulticastLower, "setAllMulticastModeEnable %d", enable);
  return super::setAllMulticastModeEnable(enable);
}

IOReturn RMNetDriver::handleChosenMedia(MediaWord chosenMedia) {
  LOG_FIRST(kLogHandleChosenMedia, "handleChosenMedia 0x%x", chosenMedia);
  return super::handleChosenMedia(chosenMedia);
}

uint32_t RMNetDriver::getMaxTransferUnit() {
  LOG_FIRST(kLogGetMaxTransferUnit, "getMaxTransferUnit, superclass says %u", super::getMaxTransferUnit());
  return ivars->mtu;
}

IOReturn RMNetDriver::setPowerState(unsigned long powerState, IOService* whatDevice) {
  LOG_FIRST(kLogSetPowerStateLower, "setPowerState %lu", powerState);
  return super::setPowerState(powerState, whatDevice);
}

// --- Packet queues -------------------------------------------------------------------------------

// During a hold (txWaitUplink) a drain would only be refused again: the frame it waits with is
// first in txPending. Only sent packets are completed then; the next successful uplink completion
// (OnBulkOutDone), the uplink becoming usable again (OnUplinkUsable), a link down (ApplyCore) or
// the timer tick restarts the drain.
void RMNetDriver::TxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogTxAvailable, "TxPacketsAvailable");
  EnsureTimer();
  if (ivars->txWaitUplink) {
    FlushTxDone();
    return;
  }
  DrainTx();
}

// Empty receive packets arrived; also a chance to hand up filled ones the queue refused before.
void RMNetDriver::RxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogRxAvailable, "RxPacketsAvailable");
  EnsureTimer();
  if (ivars->stopping) return;
  FlushRx();
}

// Takes frames from the TX submission queue until it is empty, passes each to CoreHost and
// completes it whatever happened to it (CoreHost copies what it keeps), then sends the open
// uplink buffer: the queue is empty. Not while the modem has paused the uplink: frames stay
// queued until it resumes. If the completion queue refuses packets, they are kept and returned
// first next time; with no room to keep a whole batch, the rest waits for the next timer tick.
// When every uplink buffer is in flight, the frame CoreHost did not take and the rest of its batch
// stay in txPending and the drain stops (txWaitUplink); the next successful uplink transfer
// (OnBulkOutDone), a failed one that started no recovery or the end of a recovery whose ClearStall
// succeeded (OnUplinkUsable), a link down (ApplyCore), or the timer tick, restarts it, and those
// frames are offered first, in order, before a new batch is taken. The frames behind them stay in
// the TX submission queue, which is the backpressure.
// A taken batch always fits txDone: it is taken only with kTxBatch free there, and nothing else
// adds to txDone until all of it is placed.
void RMNetDriver::DrainTx() {
  FlushTxDone();
  if (ivars->stopping || !ivars->core || !ivars->txSubmit) return;
  // Core is not called while asleep or while the wake's resume is pending; the first tick after the
  // resume drains.
  if (ivars->asleep || ivars->resumePending) {
    ivars->txHeld = true;
    return;
  }
  if (ivars->core->uplink_paused()) {
    ivars->txHeld = true;
    return;
  }
  ivars->txHeld = false;
  bool wasWaiting = ivars->txWaitUplink;  // a hold episode lasts until a drain ends without a hold
  ivars->txWaitUplink = false;
  for (;;) {
    if (ivars->txPendingNext == ivars->txPendingCount) {
      ivars->txPendingNext = 0;
      ivars->txPendingCount = 0;
      if (kTxHold - ivars->txDoneCount < kTxBatch) {
        ivars->txHeld = true;
        break;
      }
      ivars->txPendingCount = ivars->txSubmit->DequeuePackets(ivars->txPending, kTxBatch);
      if (ivars->txPendingCount > kTxBatch) ivars->txPendingCount = kTxBatch;
      if (ivars->txPendingCount == 0) break;
    }
    while (ivars->txPendingNext < ivars->txPendingCount) {
      IOUserNetworkPacket* p = ivars->txPending[ivars->txPendingNext];
      size_t off = p->getDataOff();
      uint32_t len = p->getDataLength();
      LOG_FIRST(kLogTxPacket, "first tx packet: data offset %zu, length %u", off, len);
      const uint8_t* data = reinterpret_cast<const uint8_t*>(p->getDataVirtualAddress()) + off;
      if (!ivars->core->transmit(data, len)) {
        ivars->txWaitUplink = true;
        if (!wasWaiting) ivars->txHolds++;
        LOG_FIRST(kLogTxHold, "first uplink hold: every uplink buffer in flight, %u frames kept",
                  ivars->txPendingCount - ivars->txPendingNext);
        break;
      }
      ivars->txDone[ivars->txDoneCount++] = p;
      ivars->txPendingNext++;
    }
    FlushTxDone();
    if (ivars->txWaitUplink) break;
  }
  ivars->core->flush_uplink();
  FlushRx();  // emulator replies
}

// Completes sent packets in one call; what the completion queue refuses is kept, in order, and
// offered first next time. RMNetTxCompleteRefused counts each packet the first time it is refused,
// by keeping a count of the kept packets already counted (txDoneCounted): the queue takes from the
// front, so the refused ones are the newest n - done, and of them the kept ones already counted
// are the oldest, txDoneCounted - done of them if positive; only the rest are new refusals.
void RMNetDriver::FlushTxDone() {
  uint32_t n = ivars->txDoneCount;
  if (n == 0 || !ivars->txComplete) return;
  uint32_t done = ivars->txComplete->EnqueuePackets(ivars->txDone, n);
  if (done > n) done = n;
  if (done < n) {
    LOG_FIRST(kLogTxCompleteFull, "tx completion queue took %u of %u packets; the rest are kept", done, n);
    memmove(&ivars->txDone[0], &ivars->txDone[done], (n - done) * sizeof(ivars->txDone[0]));
  }
  uint32_t stillCounted = ivars->txDoneCounted > done ? ivars->txDoneCounted - done : 0;
  ivars->txCompleteRefused += (n - done) - stillCounted;
  ivars->txDoneCounted = n - done;
  ivars->txDoneCount = n - done;
}

// CoreHost's receive buffers: the last packet of the stock, which stays the one offered until
// RxCommit takes it, so a frame rejected after its buffer was offered costs no packet. An empty
// stock is refilled with one DequeuePackets call of up to kRxStock packets. None when the RX
// submission queue has none, or when kRxHold filled packets are still waiting for the completion
// queue. The stock is kept across a link down; at Stop it is abandoned with the disabled queues.
uint8_t* RMNetDriver::RxBuffer(size_t* cap) {
  if (ivars->rxOutCount >= kRxHold || !ivars->rxSubmit) return nullptr;
  if (ivars->rxStockCount == 0) {
    uint32_t n = ivars->rxSubmit->DequeuePackets(ivars->rxStock, kRxStock);
    ivars->rxStockCount = n > kRxStock ? kRxStock : n;
    if (ivars->rxStockCount == 0) return nullptr;
  }
  *cap = kPacketBufSize;
  return reinterpret_cast<uint8_t*>(ivars->rxStock[ivars->rxStockCount - 1]->getDataVirtualAddress());
}

void RMNetDriver::RxCommit(size_t len) {
  if (ivars->rxStockCount == 0) return;
  IOUserNetworkPacket* p = ivars->rxStock[--ivars->rxStockCount];
  IOReturn ret = p->setDataOffAndLen(0, len);
  LOG_FIRST(kLogRxPacket, "first rx packet: length %zu, setDataOffAndLen 0x%x", len, ret);
  p->setLinkHeaderLength(kLinkHeaderLen);
  ivars->rxOut[ivars->rxOutCount++] = p;
  if (ivars->rxOutCount >= kRxBatch) FlushRx();
}

// Hands filled packets up in one call; what the completion queue refuses is kept, in order.
// RMNetRxCompleteRefused counts each packet the first time it is refused, as FlushTxDone does, by
// keeping a count of the kept packets already counted (rxOutCounted): of the n - done refused now
// (the newest), the rxOutCounted - done at the front, if positive, were counted already.
void RMNetDriver::FlushRx() {
  uint32_t n = ivars->rxOutCount;
  if (n == 0 || !ivars->rxComplete) return;
  uint32_t done = ivars->rxComplete->EnqueuePackets(ivars->rxOut, n);
  if (done > n) done = n;
  if (done < n) {
    LOG_FIRST(kLogRxCompleteFull, "rx completion queue took %u of %u packets; the rest are kept", done, n);
    memmove(&ivars->rxOut[0], &ivars->rxOut[done], (n - done) * sizeof(ivars->rxOut[0]));
  }
  uint32_t stillCounted = ivars->rxOutCounted > done ? ivars->rxOutCounted - done : 0;
  ivars->rxCompleteRefused += (n - done) - stillCounted;
  ivars->rxOutCounted = n - done;
  ivars->rxOutCount = n - done;
}

// How long a completed read waited for its handler, which is how long the modem had one read fewer
// posted. The completion timestamp is in absolute-time units: nanoseconds, or the 24 MHz ticks of
// Apple silicon (timebase 125/3), told apart by size against the uptime in nanoseconds; the first
// completion's log line shows both values.
void RMNetDriver::NoteRxLag(uint64_t timestamp, uint64_t nowNs) {
  if (timestamp == 0) return;
  uint64_t tsNs = timestamp >= nowNs / 2 ? timestamp : timestamp / 3 * 125 + timestamp % 3 * 125 / 3;
  if (tsNs > nowNs) return;
  uint64_t lagUs = (nowNs - tsNs) / 1000;
  if (lagUs > ivars->rxLagMaxUs) ivars->rxLagMaxUs = lagUs;
}

// One completed bulk read: frames go up in one batch, and a resumed uplink is drained.
void RMNetDriver::OnBulkIn(const uint8_t* data, size_t len) {
  if (ivars->stopping || !ivars->core) return;
  ivars->core->on_bulk_in(data, len);
  FlushRx();
  if (ivars->core->take_uplink_resumed()) DrainTx();
}

// UsbIo found the uplink stuck for the first time since a successful transfer. Called from inside
// UsbIo::bulk_out_complete: only recorded here; BulkOutComplete_Impl restarts the session once
// that call has returned.
void RMNetDriver::OnUplinkStuck() {
  ivars->uplinkStuck = true;
}

// A completed uplink transfer frees its buffer: a drain that stopped for want of one restarts.
// CoreHost runs first, so a QMAP command reply it kept takes the freed buffer before the drain.
// Only after a success: UsbIo reports a failed transfer before it starts a stall recovery, so a
// drain then could submit to a halted pipe; once UsbIo has decided on the recovery, its
// on_uplink_usable (OnUplinkUsable) restarts it instead (the tick does after a failed ClearStall,
// and the session restart after a stuck uplink).
void RMNetDriver::OnBulkOutDone(int slot, bool ok) {
  if (ivars->stopping || !ivars->core) return;
  ivars->core->on_bulk_out_done(slot, ok);
  if (ok && ivars->txWaitUplink) DrainTx();
}

// UsbIo says a held uplink may go on (UsbIoListener::on_uplink_usable): a failed transfer freed its
// buffer and started no recovery, or a bulk OUT recovery ended with a successful ClearStall. Raised
// only from inside UsbIo::bulk_out_complete (never from UsbIo::resume), while UsbIo runs, is not
// held, has not failed and is not recovering, so the drain cannot submit to a halted pipe.
// Nothing happens when the same completion found the uplink stuck (uplinkStuck): the session
// restart that follows it (BulkOutComplete_Impl) takes the link down, and ApplyCore's drain then
// drops the kept frames as link down, where a drain now would put another transfer on the stuck
// endpoint, which would count as a stall of the restarted session. Otherwise, as OnBulkOutDone
// does, CoreHost first gives the free buffers to kept QMAP command replies, then a drain held for
// want of a buffer (txWaitUplink) or for another reason (txHeld) restarts at once instead of on
// the next tick; DrainTx itself still holds while asleep, while the wake's resume is pending and
// while the modem pauses the uplink.
void RMNetDriver::OnUplinkUsable() {
  ivars->uplinkUsable++;
  LOG_FIRST(kLogUplinkUsable, "first uplink usable callback: drain %{public}s",
            ivars->txWaitUplink ? "waiting for a buffer" : (ivars->txHeld ? "held" : "not held"));
  if (ivars->stopping || !ivars->core) return;
  if (ivars->uplinkStuck) return;
  ivars->core->uplink_usable();
  if (ivars->txWaitUplink || ivars->txHeld) DrainTx();
}

// The data path counters, as properties next to RMNetState, once a second when they changed.
// RMNetPacketsHeld is what the driver holds of the pool beyond its stock of empty receive packets
// (unhanded receive packets, uncompleted transmit packets and transmit frames kept for an uplink
// buffer); idle, it is 0. RMNetRxStock is the stock, from 0 to kRxStock. RMNetTxPending is the kept
// frames alone; RMNetTxHolds counts the hold episodes, from the drain stopping for want of an
// uplink buffer to a drain that ends without stopping so. RMNetRxHandlerMaxUs and
// RMNetRxHandlerTotalUs are the longest and the summed bulk read handler time; divided by
// RMNetRxTransfers, the total gives the mean (the transfers handled before the receive path's
// first log lines are not timed). RMNetQmapCommandRepliesKept is the command replies CoreHost
// keeps now for want of an uplink buffer, from 0 to kKeptReplies. RMNetTimerArmFailures counts failed
// WakeAtTime calls; RMNetUsbBulkOutTimeouts uplink transfers that timed out or were aborted by no
// one in the driver; RMNetUplinkStuckRestarts the session restarts asked for by a stuck uplink;
// RMNetUplinkPauseTimeouts QMAP pauses that lasted kPauseMaxMs and asked for a session restart.
// Sleep: RMNetSleeps and RMNetWakes count power-off calls and power-on calls after one;
// RMNetLastWakeUpMs is the time from the last wake call to the next link up (0 until then);
// RMNetWakeRetries counts resume attempts after the first of their wake (the bus not ready);
// RMNetSleepCompletions counts USB completions that arrived while UsbIo was held, and
// RMNetSleepLastStatus is the last status among them other than success; RMNetLastPowerFlags is the
// flags of the last SetPowerState call. RMNetTxQueueCapacity is the TX submission queue's capacity,
// kTxQueueCapacity or, if the system refused that, kQueueCapacity (not a counter; it never changes).
// In-band flow control (not counters either): RMNetFlowControlAsked is 1 if the last Set Data Format
// request asked for it, RMNetFlowControlRefused 1 once the modem refused it (no later request asks),
// and RMNetFlowControlOn the modem's answer in the data format in use now: 0 whenever the session is
// not up. RMNetFlowControlRefused also becomes 1 when the driver gives flow control up after a pause
// that reached kPauseMaxMs.
// The waits for the timer: RMNetUplinkUsable counts UsbIo's uplink-usable callbacks (a failed
// transfer that started no recovery, or the end of a recovery whose ClearStall succeeded; also
// those ignored because the uplink was found stuck); RMNetTxCompleteRefused and
// RMNetRxCompleteRefused the packets the TX and RX completion queues refused, each packet once
// however often it is offered again; RMNetTickTxDrains the ticks that drained because the drain
// was held (txHeld, which a QMAP pause also sets), waited for an uplink buffer, or had sent packets
// left to complete; RMNetTickRxFlushes the ticks that found refused receive packets still waiting.
void RMNetDriver::PublishCounters() {
  const DataCounters& c = ivars->core->counters();
  uint32_t txPending = ivars->txPendingCount - ivars->txPendingNext;
  const UsbIoStats& u = ivars->usb->stats();
  uint32_t poolCount = 0;
  kern_return_t pret = ivars->pool ? ivars->pool->GetPacketCount(&poolCount) : kIOReturnNotReady;
  LOG_FIRST(kLogPoolCount, "pool GetPacketCount: %u (0x%x)", poolCount, pret);
  bool flowControlOn =
      ivars->core->state() == rmnet::SessionState::Up && ivars->core->link_config().format.flow_control != 0;
  struct Entry {
    const char* key;
    uint64_t value;
  };
  const Entry entries[kCounterCount] = {
      {"RMNetRxPackets", c.rx_packets},
      {"RMNetRxBytes", c.rx_bytes},
      {"RMNetTxPackets", c.tx_packets},
      {"RMNetTxBytes", c.tx_bytes},
      {"RMNetRxTransfers", c.rx_transfers},
      {"RMNetRxEmptyTransfers", c.rx_empty_transfers},
      {"RMNetTxTransfers", c.tx_transfers},
      {"RMNetReplies", c.replies},
      {"RMNetRxDropLinkDown", c.rx_drop_link_down},
      {"RMNetRxDropNoPacket", c.rx_drop_no_packet},
      {"RMNetRxDropFiltered", c.rx_drop_filtered},
      {"RMNetRxDropTooBig", c.rx_drop_too_big},
      {"RMNetRxDropOtherMux", c.rx_drop_other_mux},
      {"RMNetRxDropBadQmap", c.rx_drop_bad_qmap},
      {"RMNetTxDropLinkDown", c.tx_drop_link_down},
      {"RMNetTxDropFiltered", c.tx_drop_filtered},
      {"RMNetTxDropBusy", c.tx_drop_busy},
      {"RMNetTxDropRecovering", c.tx_drop_recovering},
      {"RMNetTxDropTooBig", c.tx_drop_too_big},
      {"RMNetTxDropUsb", c.tx_drop_usb},
      {"RMNetReplyDropNoPacket", c.reply_drop_no_packet},
      {"RMNetQmapCommands", c.commands},
      {"RMNetQmapFlowDisable", c.flow_disable},
      {"RMNetQmapFlowEnable", c.flow_enable},
      {"RMNetQmapCommandReplies", c.command_replies},
      {"RMNetQmapCommandReplyDrops", c.command_reply_drops},
      {"RMNetUsbBulkInErrors", u.bulk_in_errors},
      {"RMNetUsbBulkOutErrors", u.bulk_out_errors},
      {"RMNetUsbRecoveries", u.recoveries},
      {"RMNetUsbStallClears", u.stall_clears},
      {"RMNetRxLagMaxUs", ivars->rxLagMaxUs},
      {"RMNetRxFullTransfers", u.full_reads},
      {"RMNetPacketsHeld", uint64_t{ivars->rxOutCount} + ivars->txDoneCount + txPending},
      {"RMNetPoolPacketCount", poolCount},
      {"RMNetUplinkPaused", ivars->core->uplink_paused() ? 1u : 0u},
      {"RMNetTxHolds", ivars->txHolds},
      {"RMNetTxPending", txPending},
      {"RMNetRxStock", ivars->rxStockCount},
      {"RMNetRxHandlerMaxUs", ivars->rxHandlerMaxNs / 1000},
      {"RMNetRxHandlerTotalUs", ivars->rxHandlerTotalNs / 1000},
      {"RMNetQmapCommandRepliesKept", ivars->core->kept_replies()},
      {"RMNetTimerArmFailures", ivars->timerArmFailures},
      {"RMNetUsbBulkOutTimeouts", u.bulk_out_timeouts},
      {"RMNetUplinkPauseTimeouts", c.uplink_pause_timeouts},
      {"RMNetUplinkStuckRestarts", u.uplink_stuck_restarts},
      {"RMNetSleeps", ivars->sleeps},
      {"RMNetWakes", ivars->wakes},
      {"RMNetLastWakeUpMs", ivars->lastWakeUpMs},
      {"RMNetWakeRetries", ivars->wakeRetries},
      {"RMNetSleepCompletions", u.sleep_completions},
      {"RMNetSleepLastStatus", u.sleep_last_status},
      {"RMNetLastPowerFlags", ivars->lastPowerFlags},
      {"RMNetTxQueueCapacity", ivars->txQueueCapacity},
      {"RMNetFlowControlAsked", ivars->core->flow_control_asked() ? 1u : 0u},
      {"RMNetFlowControlRefused", ivars->core->flow_control_refused() ? 1u : 0u},
      {"RMNetFlowControlOn", flowControlOn ? 1u : 0u},
      {"RMNetUplinkUsable", ivars->uplinkUsable},
      {"RMNetTxCompleteRefused", ivars->txCompleteRefused},
      {"RMNetRxCompleteRefused", ivars->rxCompleteRefused},
      {"RMNetTickTxDrains", ivars->tickTxDrains},
      {"RMNetTickRxFlushes", ivars->tickRxFlushes},
  };
  bool changed = !ivars->countersPublished;
  for (uint32_t i = 0; i < kCounterCount; i++) {
    if (entries[i].value != ivars->counters[i]) changed = true;
  }
  if (!changed) return;

  OSDictionary* props = OSDictionary::withCapacity(kCounterCount);
  if (!props) return;
  bool ok = true;
  for (uint32_t i = 0; i < kCounterCount && ok; i++) {
    OSNumber* n = OSNumber::withNumber(entries[i].value, 64);
    ok = n && props->setObject(entries[i].key, n);
    OSSafeReleaseNULL(n);
  }
  if (ok) {
    kern_return_t ret = SetProperties(props);
    if (ret == kIOReturnSuccess) {
      for (uint32_t i = 0; i < kCounterCount; i++) ivars->counters[i] = entries[i].value;
      ivars->countersPublished = true;
    } else {
      LOG("SetProperties (counters) 0x%x", ret);
    }
  }
  OSSafeReleaseNULL(props);
}

// --- USB and timer -------------------------------------------------------------------------------

// Completions go to UsbIo even while stopping: it counts the aborted ones before releasing.
// A successful read while not stopping is timed from after the first-call log line to the return
// of bulk_in_complete (parsing, handing packets up, re-posting the read); not until the receive
// path's first-call lines are logged (rxReadSeen and "first rx packet"), so no log line is timed.
// The lag uses the clock read taken on entry.
void RMNetDriver::BulkInComplete_Impl(OSAction* action, IOReturn status, uint32_t actualByteCount,
                                     uint64_t completionTimestamp) {
  uint64_t now = NowNs();
  LOG_FIRST(kLogBulkIn, "BulkInComplete 0x%x, %u bytes, completion timestamp %llu, uptime %llu ns", status,
            actualByteCount, completionTimestamp, now);
  if (!ivars || !ivars->usb) return;
  bool handled = status == kIOReturnSuccess && !ivars->stopping;
  if (handled) NoteRxLag(completionTimestamp, now);
  bool timed = handled && ivars->rxReadSeen && (ivars->logged & kLogRxPacket);
  uint64_t start = timed ? NowNs() : 0;
  uint32_t slot = *static_cast<uint32_t*>(action->GetReference());
  ivars->usb->bulk_in_complete(slot, status, actualByteCount);
  if (timed) {
    uint64_t ns = NowNs() - start;
    if (ns > ivars->rxHandlerMaxNs) ivars->rxHandlerMaxNs = ns;
    ivars->rxHandlerTotalNs += ns;
  }
  if (handled) ivars->rxReadSeen = true;
  if (ivars->stopping) AdvanceStop();
  EnsureTimer();
}

void RMNetDriver::BulkOutComplete_Impl(OSAction* action, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogBulkOut, "BulkOutComplete 0x%x, %u bytes", status, actualByteCount);
  if (!ivars || !ivars->usb) return;
  uint32_t slot = *static_cast<uint32_t*>(action->GetReference());
  ivars->usb->bulk_out_complete(slot, status, actualByteCount);
  if (ivars->uplinkStuck) {
    ivars->uplinkStuck = false;
    RestartSession("uplink stuck");  // refused while stopping or after a fatal USB error
  }
  if (ivars->stopping) AdvanceStop();
  EnsureTimer();
}

void RMNetDriver::InterruptComplete_Impl(OSAction*, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogInterruptComplete, "InterruptComplete 0x%x, %u bytes", status, actualByteCount);
  if (ivars && ivars->usb) ivars->usb->interrupt_complete(status, actualByteCount);
  if (ivars && ivars->stopping) AdvanceStop();
  EnsureTimer();
}

void RMNetDriver::ControlOutComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlOutComplete, "ControlOutComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_out_complete(status, bytesTransferred);
  if (ivars && ivars->stopping) AdvanceStop();
  EnsureTimer();
}

void RMNetDriver::ControlInComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlInComplete, "ControlInComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_in_complete(status, bytesTransferred);
  if (ivars && ivars->stopping) AdvanceStop();
  EnsureTimer();
}

void RMNetDriver::TimerFired_Impl(OSAction*, uint64_t) {
  LOG_FIRST(kLogTimerFired, "TimerFired");
  if (!ivars) return;
  if (ivars->stopping) {
    // The timer is the clock of the stop sequence until it passes Stop on.
    AdvanceStop();
    if (ivars->stopPhase != RMNetDriver_IVars::kStopDone) {
      ArmTimer();
      // No tick will come: finish now rather than wait for a completion that may never arrive.
      if (ivars->timerArmFailed) AdvanceStop();
    }
    return;
  }
  if (!ivars->core) return;
  if (ivars->asleep || ivars->resumePending) {
    // Neither Core nor USB is called while asleep (no probe, no sync resend, no recovery deadline);
    // only the status and the counters are published. While the wake's resume is pending, the same,
    // and one more attempt (which may resume and restart the session; the next tick is a full one).
    if (ivars->resumePending) ResumeUsb();
    PublishStatus();
    if (++ivars->ticks % kCounterTicks == 0) PublishCounters();
    ArmTimer();
    return;
  }
  // Filled receive packets waiting here were refused by the RX completion queue (every path that
  // fills rxOut ends with a FlushRx), and wait for this tick unless an RxPacketsAvailable or a
  // completion flushes first. Counted before the tick's first FlushRx (ApplyCore's, then the one
  // below), so a tick whose ApplyCore hands them up counts too.
  if (ivars->rxOutCount > 0) ivars->tickRxFlushes++;
  uint64_t now = NowMs();
  if (ivars->usb) ivars->usb->tick();  // bounds a bulk pipe recovery; may report on_fatal
  if (!ivars->coreStopped) {
    ivars->core->tick(now);
    ApplyCore();
  }
  ivars->core->data_tick(now);
  if (ivars->core->take_restart_wanted()) {
    // A pause that never ends must not repeat after every restart: the restarted session does not
    // ask for flow control again.
    if (ivars->core->flow_control_asked()) {
      ivars->core->give_up_flow_control();
      LOG("flow control given up: the uplink stayed paused for %u s with no flow enable",
          (unsigned)(kPauseMaxMs / 1000));
    }
    RestartSession("uplink paused with no flow enable");
  }
  FlushRx();
  if (ivars->txHeld || ivars->txWaitUplink || ivars->txDoneCount > 0) {
    ivars->tickTxDrains++;
    DrainTx();
  }
  if (++ivars->ticks % kCounterTicks == 0) PublishCounters();
  ArmTimer();
}
