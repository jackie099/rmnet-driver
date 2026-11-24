// The modem's spare AT port: USB interface 3 of 2c7c:0801, opened from user space with IOUSBHost.
// Sends one command at a time and collects the answer. Knows nothing about what the commands mean.
// Nothing that goes over the port is logged: it will carry message text and phone numbers.
import Foundation
import IOKit
import IOUSBHost
import notify

enum AtError: Error, Equatable {
    case modemNotAttached      // no RM520N-GL (2c7c:0801) on USB: the AT port is used on that model only
    case noAtInterface         // the modem is there but has no interface 3 with two bulk endpoints
    case busy                  // another program holds the interface
    case io(Int32)             // an IOKit status from a transfer or the open
    case timeout               // no final result (or no prompt) in time
    case modem(String)         // the modem's own error line: "ERROR", "+CME ERROR: 10", "+CMS ERROR: 500", or
                               // another V.250 final result: "NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE"
}

// The answer to one line sent to the modem, assembled from the bytes as they arrive. Pure: no I/O.
//
// Input is split on CR and LF; control characters (an echoed Ctrl-Z) and surrounding spaces are
// removed from each line and empty lines are dropped. When the port echoes (`echo` is the line that
// was sent), the echo is the gate: every line before it is stale (the late answer of an earlier
// command) or unsolicited, and is discarded. After the echo, a line that is exactly "OK" ends the
// answer with the lines before it; "ERROR", "+CME ERROR:…" or "+CMS ERROR:…" ends it as an error, and
// so do V.250's other final results, each exactly that line: "NO CARRIER" (ATA with no call, say),
// "BUSY", "NO ANSWER" and "NO DIALTONE"; otherwise such an answer would wait for an OK until its timeout.
// With `prompt`, the answer is instead the "> " prompt (no line end after it), recognised only after
// the echo; an error line before it still ends the answer. When the port does not echo (`echo` nil),
// there is no gate.
//
// The result after a payload (`afterPayload:`) has no gate: by then the prompt has passed the gate,
// so every earlier command has finished. Whether and how the modem echoes the payload is not known,
// so the echo is not required; a line that is the payload or a piece of it (the echo broken by a line
// end) is skipped if it comes.
struct AtAnswerCollector {
    enum Outcome: Equatable {
        case waiting
        case prompt
        case answer([String])
        case modemError(String)
    }

    private let echo: String?
    private let payload: String?
    private let wantsPrompt: Bool
    private var echoSeen = false
    private var buffer: [UInt8] = []  // bytes of the line not yet ended
    private var lines: [String] = []
    private(set) var outcome: Outcome = .waiting

    init(echo: String?, prompt: Bool = false) {
        self.echo = echo
        self.payload = nil
        self.wantsPrompt = prompt
    }

    init(afterPayload payload: String) {
        self.echo = nil
        self.payload = payload
        self.wantsPrompt = false
    }

    // Feeds bytes that arrived; once the outcome is no longer `.waiting`, further bytes are ignored.
    @discardableResult
    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> Outcome where Bytes.Element == UInt8 {
        guard outcome == .waiting else { return outcome }
        buffer.append(contentsOf: bytes)
        while outcome == .waiting, let end = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let text = AtAnswerCollector.clean(buffer[..<end])
            buffer.removeSubrange(...end)
            if !text.isEmpty { take(text) }
        }
        if outcome == .waiting, wantsPrompt, echo == nil || echoSeen, AtAnswerCollector.clean(buffer[...]) == ">" {
            outcome = .prompt
        }
        return outcome
    }

    private mutating func take(_ line: String) {
        if let echo, !echoSeen, AtAnswerCollector.withoutPrompt(line) == echo { echoSeen = true; return }
        if echo != nil && !echoSeen { return }  // the gate: nothing before the echo belongs to this answer
        if AtAnswerCollector.isErrorResult(line) {
            outcome = .modemError(line)
        } else if wantsPrompt {
            return  // before the prompt only an error line counts
        } else if line == "OK" {
            outcome = .answer(lines)
        } else if let payload, isPieceOf(payload, line) {
            return  // the payload's echo, whole or in pieces
        } else {
            lines.append(line)
        }
    }

    // A bare ">" (a leftover prompt) also counts.
    private func isPieceOf(_ payload: String, _ line: String) -> Bool {
        let text = AtAnswerCollector.withoutPrompt(line)
        return text.isEmpty || payload.range(of: text) != nil
    }

    // V.250's other final results, in their verbose form (CONNECT, which starts data mode, is left out).
    private static let otherFinalResults: Set<String> = ["NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE"]

    static func isErrorResult(_ line: String) -> Bool {
        line == "ERROR" || line.hasPrefix("+CME ERROR:") || line.hasPrefix("+CMS ERROR:") || otherFinalResults.contains(line)
    }

    fileprivate static func clean(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.filter { $0 >= 0x20 || $0 == 0x09 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    // A payload's echo may follow the prompt on the same line.
    private static func withoutPrompt(_ line: String) -> String {
        guard line.hasPrefix(">") else { return line }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

/// One unsolicited PDU delivery (`+CMT: [<alpha>],<length>` followed by its hex line) read from the port while
/// `AT+CNMI` is `2,2`. Kept in memory only until `SmsService` writes it to the modem's message store.
struct AtDeliveredPdu: Equatable {
    let tpduLength: Int
    let hex: String
}

/// Watches the bytes read from the port for unsolicited SMS lines that would otherwise be discarded before a command's
/// echo or during a drain:
/// - `+CMTI:` with no storage name (`+CMTI: ,3`) or a negative index (`+CMTI: ,-1`), which the RM520N-GL sends when an
///   incoming WAP Push (such as an MMS notification) cannot be stored under `AT+CNMI=2,1`;
/// - `+CMT: [<alpha>],<length>` followed by its hex PDU line (`(1 + scOctets + length) * 2 == hex.count`), sent while
///   `AT+CNMI` is `2,2` (during `sms unblock`, or if an earlier process died before restoring `2,1`).
/// Pure: no I/O, nothing logged.
struct AtUnsolicitedReader {
    private var buffer: [UInt8] = []
    private var pendingLength: Int? = nil
    private(set) var sawBlockedCmti = false
    private(set) var deliveries: [AtDeliveredPdu] = []

    var waitingForHex: Bool { pendingLength != nil }

    mutating func feed<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        while let end = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let text = AtAnswerCollector.clean(buffer[..<end])
            buffer.removeSubrange(...end)
            if !text.isEmpty { take(text) }
        }
    }

    mutating func takeDeliveries() -> [AtDeliveredPdu] {
        let taken = deliveries
        deliveries = []
        return taken
    }

    mutating func takeBlockedFlag() -> Bool {
        let flag = sawBlockedCmti
        sawBlockedCmti = false
        return flag
    }

    private mutating func take(_ line: String) {
        if let length = pendingLength {
            if AtUnsolicitedReader.matchesCmtHex(line, tpduLength: length) {
                deliveries.append(AtDeliveredPdu(tpduLength: length, hex: line))
                pendingLength = nil
                return
            }
            if line == "OK" || AtAnswerCollector.isErrorResult(line) {
                pendingLength = nil
            }
        }
        if let length = AtUnsolicitedReader.cmtLength(line) {
            pendingLength = length
            return
        }
        if AtUnsolicitedReader.isBlockedCmti(line) {
            sawBlockedCmti = true
        }
    }

    static func isBlockedCmti(_ line: String) -> Bool {
        guard line.hasPrefix("+CMTI:") else { return false }
        let rest = line.dropFirst("+CMTI:".count)
        guard let comma = rest.lastIndex(of: ",") else { return false }
        let mem = rest[..<comma].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        let indexText = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard let index = Int(indexText) else { return false }
        return mem.isEmpty || index < 0
    }

    static func cmtLength(_ line: String) -> Int? {
        guard line.hasPrefix("+CMT:") else { return nil }
        let rest = line.dropFirst("+CMT:".count)
        guard let comma = rest.lastIndex(of: ",") else { return nil }
        let lengthText = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard let length = Int(lengthText), length > 0 else { return nil }
        return length
    }

    static func matchesCmtHex(_ line: String, tpduLength: Int) -> Bool {
        guard tpduLength > 0, line.utf8.count >= 4, line.utf8.count % 2 == 0,
              line.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }),
              let sc = Int(line.prefix(2), radix: 16) else { return false }
        return (1 + sc + tpduLength) * 2 == line.utf8.count
    }
}

// Whether the port echoes, from successive answers to "AT" collected without a gate. An answer counts
// only if it is empty (no echo) or exactly the line "AT" (echo); anything else (a late answer of an
// earlier command, an error line) means: read away what is pending and probe again. The verdict is
// settled when two counted answers in a row agree. Pure: no I/O.
struct AtEchoProbe {
    enum Step: Equatable {
        case probeAgain
        case settled(echoes: Bool)
    }

    private var last: Bool?

    mutating func record(_ outcome: AtAnswerCollector.Outcome) -> Step {
        guard let verdict = AtEchoProbe.verdict(outcome) else {
            last = nil
            return .probeAgain
        }
        if last == verdict { return .settled(echoes: verdict) }
        last = verdict
        return .probeAgain
    }

    private static func verdict(_ outcome: AtAnswerCollector.Outcome) -> Bool? {
        switch outcome {
        case .answer([]): return false
        case .answer(["AT"]): return true
        default: return nil
        }
    }
}

// The port. Each public method holds a lock, so calls from two threads cannot interleave; calls are
// synchronous and must not be made on the main thread. The class starts no threads of its own.
//
// Timeouts. `timeout` is the time allowed for the answer after the line has been written. Before each
// command the port reads away what the modem sent unasked, for at most 0.5 s in all; each write may
// take up to 2 s. Worst cases:
// - `open()`: while another program holds the interface, retries every 0.1 s for up to 2 s (then
//   `.busy`); registry lookups; then the ESC and the echo probes (drains, "AT" writes, answers) within
//   3 s, plus one 2 s write begun just before those 3 s ran out: 7 s.
// - `command`: 0.5 s + 2 s + `timeout`.
// - `send`: 0.5 s drain + 2 s line write + min(10 s, `timeout`) for the prompt + 2 s payload write,
//   then either `timeout` for the result or a 2 s ESC write: 4.5 s + min(10 s, `timeout`) +
//   max(`timeout`, 2 s). (A failed line write goes straight to the ESC write: 0.5 s + 2 s + 2 s = 4.5 s.)
// After `.timeout` the port has closed itself: a later call returns `.io(kIOReturnNotOpen)` and the
// caller opens a new port. So does any failure that may leave the modem at the "> " prompt.
final class AtPort {
    private static let vendor = 0x2C7C
    private static let product = 0x0801
    private static let interfaceNumber = 3
    private static let pollInterval: TimeInterval = 0.1
    private static let drainInterval: TimeInterval = 0.05
    private static let drainLimit: TimeInterval = 0.5
    private static let writeTimeout: TimeInterval = 2
    private static let openTimeout: TimeInterval = 3
    private static let promptLimit: TimeInterval = 10
    private static let busyLimit: TimeInterval = 2
    private static let busyRetryInterval: TimeInterval = 0.1
    private static let ctrlZ: UInt8 = 0x1A
    private static let escape: UInt8 = 0x1B

    /// Posted (with no payload) when a command-line RMNet verb sees a storage-less `+CMTI:` or rescues a `+CMT` PDU on
    /// the port, so a running RMNet app on this Mac hears of a blocked incoming queue even when another program (including
    /// a privileged helper) opened the port first.
    static let blockedSmsNotifyKey = "io.rmnetdriver.RMNet.smsBlocked"
    static let blockedSmsNotification = Notification.Name(blockedSmsNotifyKey)
    private static let noticeLock = NSLock()
    private static var blockedHandler: (() -> Void)?
    private static var rescued: [AtDeliveredPdu] = []

    /// Sets the running app's callback for a blocked incoming SMS notice or an unsolicited `+CMT` delivery read outside
    /// `SmsService`. Without one (a command-line verb), `blockedSmsNotifyKey` and `blockedSmsNotification` are posted.
    static func setBlockedSmsHandler(_ handler: (() -> Void)?) {
        noticeLock.lock()
        blockedHandler = handler
        noticeLock.unlock()
    }

    /// Any `+CMT` PDUs read on ports that closed without storing them, kept in memory so `SmsService` can write them.
    static func takeRescuedDeliveries() -> [AtDeliveredPdu] {
        noticeLock.lock()
        defer { noticeLock.unlock() }
        let taken = rescued
        rescued = []
        return taken
    }

    static func keepRescuedDeliveries(_ items: [AtDeliveredPdu]) {
        guard !items.isEmpty else { return }
        noticeLock.lock()
        rescued = items + rescued
        noticeLock.unlock()
    }

    static var hasRescuedDeliveries: Bool {
        noticeLock.lock()
        defer { noticeLock.unlock() }
        return !rescued.isEmpty
    }

    private static func notifyBlockedSms() {
        noticeLock.lock()
        let handler = blockedHandler
        noticeLock.unlock()
        if let handler {
            handler()
        } else {
            notify_post(blockedSmsNotifyKey)
            DistributedNotificationCenter.default().postNotificationName(
                blockedSmsNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    private let lock = NSLock()
    private var interface: IOUSBHostInterface?
    private var input: IOUSBHostPipe?
    private var output: IOUSBHostPipe?
    // Each IN transfer is one packet long, so every packet the modem sends completes a transfer and a
    // transfer that ends by its timeout cannot have received anything that would be lost.
    private let readSize: Int
    private var echoes = false  // learned at open()
    private var unsolicited = AtUnsolicitedReader()
    /// The USB serial number of the device this port was opened on (read from that device's own registry entry when the
    /// port opened, so it is the module the commands go to, not another one attached since); nil when it gives none.
    let deviceSerial: String?

    private init(interface: IOUSBHostInterface, input: IOUSBHostPipe, output: IOUSBHostPipe, readSize: Int,
                 deviceSerial: String?) {
        self.interface = interface
        self.input = input
        self.output = output
        self.readSize = readSize
        self.deviceSerial = deviceSerial
    }

    deinit { close() }

    // MARK: Opening and closing

    // Another program (an `sms` verb in a terminal while the window lists, or the other way round) may
    // hold the interface for a moment: a busy open is tried again every 0.1 s for up to 2 s. Nothing has
    // been written to the modem before an open succeeds, so trying again is safe.
    static func open() -> Result<AtPort, AtError> {
        let deadline = Date().addingTimeInterval(busyLimit)
        while true {
            let result = openOnce()
            guard case .failure(.busy) = result, deadline.timeIntervalSinceNow > busyRetryInterval else { return result }
            Thread.sleep(forTimeInterval: busyRetryInterval)
        }
    }

    /// One try, no waiting: busy at once while another program holds the interface. For reads that are only worth
    /// making when the port is free (the menu bar's signal bars), so that they never hold up the program that has it.
    static func openWithoutWaiting() -> Result<AtPort, AtError> { openOnce() }

    private static func openOnce() -> Result<AtPort, AtError> {
        let device = matchingService("IOUSBHostDevice", ["idVendor": vendor, "idProduct": product])
        guard device != IO_OBJECT_NULL else { return .failure(.modemNotAttached) }
        defer { IOObjectRelease(device) }

        let service = childInterface(of: device, number: interfaceNumber)
        guard service != IO_OBJECT_NULL else { return .failure(.noAtInterface) }
        defer { IOObjectRelease(service) }

        let iface: IOUSBHostInterface
        do {
            iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            // The open fails with a generic status when another program holds the interface; the
            // registry says whether one does.
            let status = ioStatus(error)
            let held = status == kIOReturnExclusiveAccess || hasExclusiveOwner(service)
            return .failure(held ? .busy : .io(status))
        }

        guard let endpoints = bulkEndpoints(of: iface) else {
            iface.destroy()
            return .failure(.noAtInterface)
        }
        let port: AtPort
        do {
            let input = try iface.copyPipe(withAddress: Int(endpoints.input))
            let output = try iface.copyPipe(withAddress: Int(endpoints.output))
            port = AtPort(interface: iface, input: input, output: output, readSize: endpoints.inputPacketSize,
                          deviceSerial: usbSerial(of: device))
        } catch {
            iface.destroy()
            return .failure(.io(ioStatus(error)))
        }
        if let failure = port.learnEcho() {
            port.close()
            return .failure(failure)
        }
        return .success(port)
    }

    func close() {
        let shouldNotify: Bool
        lock.lock()
        shouldNotify = closeLocked(rescueToModem: true)
        lock.unlock()
        if shouldNotify { AtPort.notifyBlockedSms() }
    }

    @discardableResult
    private func closeLocked(rescueToModem: Bool) -> Bool {
        let blocked = unsolicited.takeBlockedFlag()
        var leftover = unsolicited.takeDeliveries()
        let hadDeliveries = !leftover.isEmpty
        if rescueToModem, !leftover.isEmpty, output != nil {
            leftover = storeRescuedOnModemLocked(leftover)
        }
        if !leftover.isEmpty { AtPort.keepRescuedDeliveries(leftover) }
        input = nil
        output = nil
        interface?.destroy()
        interface = nil
        return blocked || hadDeliveries
    }

    /// When a non-SMS command (such as `RMNet network` run by another process during an unblock pause) reads an
    /// unsolicited `+CMT` delivery on this port, write it to the modem's store as unread (`AT+CMGW=<length>,0`) before
    /// closing the interface so a short-lived CLI process never loses a message.
    private func storeRescuedOnModemLocked(_ items: [AtDeliveredPdu]) -> [AtDeliveredPdu] {
        guard case .success = commandLocked("AT+CMGF=0", timeout: 2),
              case .success(let cpms) = commandLocked("AT+CPMS?", timeout: 2),
              var room = AtPort.writableStoreRoom(cpms), room > 0 else {
            return items
        }
        for (i, item) in items.enumerated() {
            guard room > 0 else { return Array(items[i...]) }
            let sc = Int(item.hex.prefix(2), radix: 16) ?? -1
            let computed = sc >= 0 ? (item.hex.utf8.count / 2 - 1 - sc) : 0
            let length = computed > 0 ? computed : item.tpduLength
            guard case .success(let lines) = sendLocked("AT+CMGW=\(length),0", afterPrompt: item.hex, timeout: 5),
                  lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("+CMGW:") }) else {
                return Array(items[i...])
            }
            room -= 1
        }
        return []
    }

    private static func writableStoreRoom(_ lines: [String]) -> Int? {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("+CPMS:") else { continue }
            let fields = line.dropFirst("+CPMS:".count).split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6, fields[0].hasPrefix("\""), fields[0] == fields[3],
                  let used = Int(fields[1]), let total = Int(fields[2]), used >= 0, total >= used else { return nil }
            return total - used
        }
        return nil
    }

    // Probes with "AT" until two answers in a row agree on whether the port echoes (AtEchoProbe),
    // within `openTimeout` in all; otherwise `.timeout`. First one ESC: a process that died between
    // AT+CMGS and its payload leaves the modem at the "> " prompt, where "AT" would become message text;
    // ESC cancels that half-entered message (and is ignored otherwise). An echoed ESC is a control
    // character, which the collector removes from its line, and whatever the modem answers to it is read
    // away by the first drain or makes the probe try again.
    private func learnEcho() -> AtError? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(AtPort.openTimeout)
        if let failure = write([AtPort.escape]) { return failure }
        var probe = AtEchoProbe()
        while deadline.timeIntervalSinceNow > 0 {
            discardUnsolicited(until: deadline)
            if let failure = write(Array("AT\r".utf8)) { return failure }
            var collector = AtAnswerCollector(echo: nil)
            switch wait(&collector, until: deadline) {
            case .success(let outcome):
                if case .settled(let verdict) = probe.record(outcome) {
                    echoes = verdict
                    return nil
                }
            case .failure(let failure):
                return failure
            }
        }
        return .timeout
    }

    // MARK: Commands

    // Sends the line and returns the lines before the final "OK", without the echo and without empty lines.
    func command(_ line: String, timeout: TimeInterval = 3) -> Result<[String], AtError> {
        lock.lock()
        defer { lock.unlock() }
        return commandLocked(line, timeout: timeout)
    }

    private func commandLocked(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        guard output != nil else { return .failure(.io(kIOReturnNotOpen)) }
        discardUnsolicited()
        if let failure = write(Array(line.utf8) + [UInt8(ascii: "\r")]) { return closingOnTimeout(.failure(failure)) }
        var collector = AtAnswerCollector(echo: echoes ? line : nil)
        return closingOnTimeout(answer(wait(&collector, until: Date().addingTimeInterval(timeout))))
    }

    // For AT+CMGS / AT+CMGW: sends `line`, waits for the "> " prompt, sends `payload` followed by Ctrl-Z (0x1A),
    // then returns the lines before the final "OK". If the prompt does not come, sends ESC (0x1B) and
    // fails with .timeout.
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        lock.lock()
        defer { lock.unlock() }
        return sendLocked(line, afterPrompt: payload, timeout: timeout)
    }

    private func sendLocked(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        guard output != nil else { return .failure(.io(kIOReturnNotOpen)) }
        discardUnsolicited()
        // If the line reached the modem despite the failure, the modem may be at the prompt.
        if let failure = write(Array(line.utf8) + [UInt8(ascii: "\r")]) { return leavePrompt(after: failure) }

        var promptCollector = AtAnswerCollector(echo: echoes ? line : nil, prompt: true)
        switch wait(&promptCollector, until: Date().addingTimeInterval(min(timeout, AtPort.promptLimit))) {
        case .success(.prompt):
            break
        case .success(.modemError(let text)):
            return .failure(.modem(text))
        case .success:
            return leavePrompt(after: .timeout)  // not reached: a prompt collector ends only with a prompt or an error
        case .failure(let failure):
            return leavePrompt(after: failure)
        }

        if let failure = write(Array(payload.utf8) + [AtPort.ctrlZ]) { return leavePrompt(after: failure) }
        var collector = AtAnswerCollector(afterPayload: payload)
        return closingOnTimeout(answer(wait(&collector, until: Date().addingTimeInterval(timeout))))
    }

    /// Reads unsolicited output for `duration` (extended by `extendOnDelivery`, up to `maxDuration` in all, while a
    /// `+CMT` delivery arrives so a multi-part burst is not cut short). For `SmsService` while `AT+CNMI` is `2,2`.
    func listen(duration: TimeInterval, extendOnDelivery: TimeInterval = 0.5,
                maxDuration: TimeInterval = 1.4) -> Result<Void, AtError> {
        var shouldNotify = false
        defer { if shouldNotify { AtPort.notifyBlockedSms() } }
        lock.lock()
        defer { lock.unlock() }
        guard input != nil else { return .failure(.io(kIOReturnNotOpen)) }
        let start = Date()
        let hardLimit = start.addingTimeInterval(max(duration, maxDuration))
        var deadline = min(start.addingTimeInterval(max(0, duration)), hardLimit)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return .success(()) }
            let before = unsolicited.deliveries.count
            let waitingBefore = unsolicited.waitingForHex
            switch readOnce(timeout: min(left, AtPort.pollInterval)) {
            case .success(let bytes):
                if !bytes.isEmpty, unsolicited.deliveries.count > before || unsolicited.waitingForHex || waitingBefore {
                    deadline = min(Date().addingTimeInterval(extendOnDelivery), hardLimit)
                }
            case .failure(.timeout):
                continue
            case .failure(let failure):
                shouldNotify = closeLocked(rescueToModem: false)
                return .failure(failure)
            }
        }
    }

    /// Takes the `+CMT` deliveries read on this port so far (including any read during `open()` or before a command).
    func takeDeliveries() -> [AtDeliveredPdu] {
        lock.lock()
        defer { lock.unlock() }
        _ = unsolicited.takeBlockedFlag()
        return unsolicited.takeDeliveries()
    }

    // The modem may be at the "> " prompt: ESC cancels the half-entered command, and the port closes.
    // A failed ESC write is reported instead of `failure`.
    private func leavePrompt(after failure: AtError) -> Result<[String], AtError> {
        let escapeFailure = write([AtPort.escape])
        if closeLocked(rescueToModem: false) { DispatchQueue.global(qos: .utility).async { AtPort.notifyBlockedSms() } }
        switch escapeFailure {
        case nil: return .failure(failure)
        case .io(let status): return .failure(.io(status))
        default: return .failure(.io(kIOReturnTimeout))  // the ESC write timed out
        }
    }

    private func closingOnTimeout(_ result: Result<[String], AtError>) -> Result<[String], AtError> {
        if case .failure(.timeout) = result, closeLocked(rescueToModem: false) {
            DispatchQueue.global(qos: .utility).async { AtPort.notifyBlockedSms() }
        }
        return result
    }

    private func answer(_ waited: Result<AtAnswerCollector.Outcome, AtError>) -> Result<[String], AtError> {
        switch waited {
        case .success(.answer(let lines)): return .success(lines)
        case .success(.modemError(let line)): return .failure(.modem(line))
        case .success: return .failure(.timeout)  // not reached: a collector without prompt never stops at one
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: Reading

    // Feeds what arrives to `collector` until it has an outcome or the deadline passes (`.timeout`).
    private func wait(_ collector: inout AtAnswerCollector, until deadline: Date) -> Result<AtAnswerCollector.Outcome, AtError> {
        while collector.outcome == .waiting {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return .failure(.timeout) }
            switch readOnce(timeout: min(left, AtPort.pollInterval)) {
            case .success(let bytes): collector.feed(bytes)
            case .failure(.timeout): continue
            case .failure(let failure): return .failure(failure)
            }
        }
        return .success(collector.outcome)
    }

    // Reads what the modem sent unasked (or late, after an earlier timeout) and throws it away: until
    // a quiet interval, for at most `drainLimit` in all (and not past `limit`). A read error is left for
    // the command to meet.
    private func discardUnsolicited(until limit: Date = .distantFuture) {
        let deadline = min(Date().addingTimeInterval(AtPort.drainLimit), limit)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return }
            guard case .success(let bytes) = readOnce(timeout: min(left, AtPort.drainInterval)), !bytes.isEmpty else { return }
        }
    }

    // One bulk IN transfer of one packet. A transfer that ends by its timeout is `.timeout`.
    private func readOnce(timeout: TimeInterval) -> Result<[UInt8], AtError> {
        guard let input else { return .failure(.io(kIOReturnNotOpen)) }
        let buffer = NSMutableData(length: readSize)!
        var count = 0
        do {
            // A timeout of 0 would mean "never"; the shortest wait is 1 ms.
            try input.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: max(timeout, 0.001))
        } catch {
            let status = AtPort.ioStatus(error)
            return .failure(status == kIOReturnTimeout ? .timeout : .io(status))
        }
        let bytes = Array(UnsafeRawBufferPointer(start: buffer.bytes, count: count))
        if !bytes.isEmpty { unsolicited.feed(bytes) }
        return .success(bytes)
    }

    private func write(_ bytes: [UInt8]) -> AtError? {
        guard let output else { return .io(kIOReturnNotOpen) }
        let buffer = NSMutableData(bytes: bytes, length: bytes.count)
        var count = 0
        do {
            try output.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: AtPort.writeTimeout)
        } catch {
            let status = AtPort.ioStatus(error)
            return status == kIOReturnTimeout ? .timeout : .io(status)
        }
        return count == bytes.count ? nil : .io(kIOReturnUnderrun)
    }

    // MARK: Finding the interface

    // The IOKit status in an error thrown by IOUSBHost (its code is the IOReturn).
    private static func ioStatus(_ error: Error) -> Int32 {
        Int32(truncatingIfNeeded: (error as NSError).code)
    }

    // Whether the registry names a program holding the interface ("UsbExclusiveOwner").
    private static func hasExclusiveOwner(_ service: io_service_t) -> Bool {
        IORegistryEntryCreateCFProperty(service, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() != nil
    }

    // The device's "USB Serial Number" (as `ioreg` shows it), printable ASCII, at most 64 characters; nil without one.
    private static func usbSerial(of device: io_service_t) -> String? {
        for key in ["USB Serial Number", "kUSBSerialNumberString"] {
            guard let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            let serial = String(value.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.prefix(64))
            if !serial.isEmpty { return serial }
        }
        return nil
    }

    private static func matchingService(_ className: String, _ properties: [String: Any]) -> io_service_t {
        let matching = IOServiceMatching(className) as NSMutableDictionary
        matching[kIOPropertyMatchKey] = properties
        return IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)  // consumes `matching`
    }

    // The device's IOUSBHostInterface child with the given bInterfaceNumber, retained, or IO_OBJECT_NULL.
    private static func childInterface(of device: io_service_t, number: Int) -> io_service_t {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != IO_OBJECT_NULL {
            let value = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               (value?.takeRetainedValue() as? NSNumber)?.intValue == number {
                return child
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        return IO_OBJECT_NULL
    }

    // The interface's bulk IN and bulk OUT endpoints, from its descriptors, with the IN packet size.
    private static func bulkEndpoints(of iface: IOUSBHostInterface) -> (input: UInt8, output: UInt8, inputPacketSize: Int)? {
        let config = iface.configurationDescriptor
        let ifdesc = iface.interfaceDescriptor
        var bulkIn: (UInt8, Int)?
        var bulkOut: UInt8?
        var current = UnsafeRawPointer(ifdesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, ifdesc, current) {
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            let address = endpoint.pointee.bEndpointAddress
            guard endpoint.pointee.bmAttributes & 0x03 == 2 else { continue }  // bulk only
            if address & 0x80 != 0 {
                let packetSize = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x7FF)
                if bulkIn == nil, packetSize > 0 { bulkIn = (address, packetSize) }
            } else if bulkOut == nil {
                bulkOut = address
            }
        }
        guard let bulkIn, let bulkOut else { return nil }
        return (bulkIn.0, bulkOut, bulkIn.1)
    }
}
