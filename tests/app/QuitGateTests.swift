// Tests for app/QuitGate.swift: the one answer to the app's quit question from the modem tabs' controller
// and the Messages tab's (ruling R18). First the gate's rules, with members the test answers for by hand;
// then the quit lines the window and the menu bar's panel show (quitNoticeLines); then the whole-branch
// review's case and its neighbours with the real controllers (app/ModemController.swift and
// app/SmsController.swift) on one serial queue, as in the app, each with a fake service whose calls block
// until the test releases them, wired to the gate as the app delegate (app/StatusView.swift) wires them; and
// the SIM slot watcher (app/SimSlotWatch.swift) switching through the modem controller while the app quits.
// Built with swiftc by `make app-test` together with app/SmsModel.swift, app/SmsController.swift,
// app/ModemNetwork.swift, app/ModemSettings.swift, app/ModemController.swift and app/SimSlotWatch.swift; needs no
// AppKit, no window and no modem. Stops at the first failure, prints which check failed and exits 1.
import Foundation

var checks = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        print("FAIL: \(name)")
        let d = detail()
        if !d.isEmpty { print("  \(d)") }
        exit(1)
    }
}

// MARK: - The gate's rules

/// A member the test answers for: what its quitWhenFinished() returns, and how often it was asked and resumed.
final class Member {
    var waits: Bool
    private(set) var asked = 0
    private(set) var resumed = 0

    init(waits: Bool) { self.waits = waits }

    var asMember: QuitGate.Member {
        QuitGate.Member(quitWhenFinished: { [unowned self] in
                            self.asked += 1
                            return self.waits
                        },
                        resume: { [unowned self] in self.resumed += 1 })
    }
}

/// A gate over one member for each of `waits`, and the answers it gave.
final class GateRig {
    let members: [Member]
    var replies: [Bool] = []
    lazy var gate = QuitGate(members.map { $0.asMember }, reply: { [unowned self] in self.replies.append($0) })

    init(_ waits: [Bool]) { members = waits.map { Member(waits: $0) } }

    var asked: [Int] { members.map { $0.asked } }
    var resumed: [Int] { members.map { $0.resumed } }
}

// MARK: - The real controllers on one queue

/// The calls of both fake services, in order. Each call blocks (on the shared queue) until the test releases
/// it; its result is set before the release.
final class Calls {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var names: [String] = []
    private var inside = 0
    private var mostInside = 0

    var log: [String] { locked { names } }
    var blocked: Int { locked { inside } }
    var mostAtOnce: Int { locked { mostInside } }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func enter(_ name: String) {
        locked {
            names.append(name)
            inside += 1
            mostInside = max(mostInside, inside)
        }
        gate.wait()
        locked { inside -= 1 }
    }

    func release() { gate.signal() }
}

final class FakeSms: SmsServing {
    let calls: Calls
    private var sendOutcome: Result<Int, SmsFailure> = .success(1)

    init(_ calls: Calls) { self.calls = calls }

    func list() -> Result<SmsListing, SmsFailure> {
        calls.enter("list")
        return .success(SmsListing(messages: [], used: nil, total: nil))
    }

    func delete(indices: [Int]) -> Result<Int, SmsFailure> {
        calls.enter("delete")
        return .success(indices.count)
    }

    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        calls.enter("send")
        return calls.locked { sendOutcome.map { SmsSent(parts: $0) } }
    }

    func resend(indices: [Int]) -> Result<SmsSent, SmsFailure> { .failure(SmsFailure(message: "not used")) }

    func releaseSend(_ outcome: Result<Int, SmsFailure>) {
        calls.locked { sendOutcome = outcome }
        calls.release()
    }
}

final class FakeModem: ModemServing {
    let calls: Calls
    private var infoOutcome: Result<NetworkInfo, ModemFailure> = .success(NetworkInfo())
    private var radioOutcome: Result<RadioChange, ModemFailure> = .failure(ModemFailure(message: "not set"))
    private var slotOutcome: Result<SimSlotChange, ModemFailure> = .failure(ModemFailure(message: "not set"))

    init(_ calls: Calls) { self.calls = calls }

    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        calls.enter("networkInfo")
        return calls.locked { infoOutcome }
    }

    func antennas() -> Result<[AntennaSignalSet], ModemFailure> { .success([]) }

    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        calls.enter("setRadio")
        return calls.locked { radioOutcome }
    }

    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func profiles() -> Result<[DataProfile], ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    func sim() -> Result<SimInfo, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    func usbMode() -> Result<UsbModeInfo, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    func bands() -> Result<[BandSet], ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    func cellLock() -> Result<CellLockState, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure> { .failure(failureOr("not used")) }
    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure> { .failure(failureOr("not used")) }
    func imei() -> Result<String, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite {
        ImeiWrite(outcome: .failure(ModemFailure(message: "not used")))
    }
    func simSlot() -> Result<Int, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure> {
        calls.enter("setSimSlot \(slot)")
        return calls.locked { slotOutcome }
    }

    func releaseSlot(_ outcome: Result<SimSlotChange, ModemFailure>) {
        calls.locked { slotOutcome = outcome }
        calls.release()
    }
    private func failureOr(_ s: String) -> ModemFailure { ModemFailure(message: s) }

    func releaseInfo(_ outcome: Result<NetworkInfo, ModemFailure>) {
        calls.locked { infoOutcome = outcome }
        calls.release()
    }

    func releaseRadio(_ outcome: Result<RadioChange, ModemFailure>) {
        calls.locked { radioOutcome = outcome }
        calls.release()
    }
}

/// Both controllers on one serial queue, wired to a gate as the app delegate wires them: the modem tabs'
/// controller is member 0, the Messages tab's member 1.
final class App {
    let calls = Calls()
    lazy var smsFake: FakeSms = FakeSms(calls)
    lazy var modemFake: FakeModem = FakeModem(calls)
    let queue = DispatchQueue(label: "io.rmnetdriver.RMNet.modem.quit-test")
    var replies: [Bool] = []
    var attention = 0

    lazy var messages: SmsController = SmsController(service: smsFake, queue: queue,
                                      replyToQuit: { [unowned self] in self.quitGate.replied(1, $0) },
                                      requestAttention: { [unowned self] in self.attention += 1 })
    lazy var modem: ModemController = ModemController(service: modemFake, queue: queue, driverProfile: { 1 },
                                     replyToQuit: { [unowned self] in self.quitGate.replied(0, $0) },
                                     requestAttention: { [unowned self] in self.attention += 1 })
    lazy var quitGate: QuitGate = QuitGate(
        [QuitGate.Member(quitWhenFinished: { [unowned self] in self.modem.quitWhenFinished() },
                         resume: { [unowned self] in self.modem.resumeAfterCancelledQuit() }),
         QuitGate.Member(quitWhenFinished: { [unowned self] in self.messages.quitWhenFinished() },
                         resume: { [unowned self] in self.messages.resumeAfterCancelledQuit() })],
        reply: { [unowned self] in self.replies.append($0) })

    /// The SIM slot watcher, wired to the modem controller as the app delegate wires it, on the test's clock.
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    lazy var watcher: SimSlotWatcher = SimSlotWatcher(
        enabled: { true }, module: { "c0ffee01" },
        switchSlot: { [unowned self] slot, expect, done in
            self.modem.changeSimSlot(slot, automatic: true, expect: expect, completion: done)
        }, now: { [unowned self] in self.clock })

    /// Two background turns 25 s apart that read no SIM in slot 1: the watcher tries slot 2.
    func emptySlotFor25s() {
        let empty: Result<[String: PulseAnswer], ModemFailure> = .success(
            ["AT+CPIN?": .refused("+CME ERROR: 10"), "AT+CFUN?": .lines(["+CFUN: 1"]),
             "AT+QUIMSLOT?": .lines(["+QUIMSLOT: 1"])])
        watcher.pulseAnswers(empty)
        clock += 25
        watcher.pulseAnswers(empty)
    }

    /// applicationShouldTerminate: true is "terminate later".
    func quit() -> Bool { quitGate.ask() }

    /// Starts a send and waits until it blocks in the fake.
    func startSend() {
        messages.to = "+27831234567"
        messages.text = "hello"
        messages.send()
        pump(until: { calls.log.last == "send" && calls.blocked == 1 }, "the send reaches the service")
    }
}

/// The modem controller's repeating timer (its private `timer`), found by reflection; its first turn is moved
/// to the distant future, so it never fires by itself during a test.
func holdTimer(_ c: ModemController) {
    let t = Mirror(reflecting: c).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
    if let t, t.isValid { t.fireDate = .distantFuture }
}

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started or answered would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

let notKnown = SmsFailure(message: "The message failed. The modem did not answer in time. It is not known whether it was "
                          + "sent. It may have been delivered; sending it again may deliver it twice.")
let notAnswered = ModemFailure(message: "The modem did not answer in time.")

// MARK: - The checks

@main
struct QuitGateTests {
    static func main() {
        rules()
        lines()
        reviewCase()
        modemFailsFirst()
        bothSucceed()
        quitWaitsForSwitchBack()
        cancelledQuitFreesWatcher()
        print("quit gate: \(checks) checks passed")
    }

    static func rules() {
        do {
            // No member waits: terminate now, and nothing answers later.
            let rig = GateRig([false, false])
            check(rig.gate.ask() == false, "gate: none waits: terminate now")
            check(rig.asked == [1, 1], "gate: every member is asked, once", "\(rig.asked)")
            rig.gate.replied(0, false)
            rig.gate.replied(1, true)
            check(rig.replies.isEmpty && rig.resumed == [0, 0], "gate: none waits: a stray reply is ignored",
                  "\(rig.replies) \(rig.resumed)")
        }
        do {
            // Every member is asked at once, also when the first waits.
            let rig = GateRig([true, true])
            check(rig.gate.ask() == true, "gate: both wait: terminate later")
            check(rig.asked == [1, 1], "gate: both are asked at once", "\(rig.asked)")
            rig.gate.replied(0, true)
            check(rig.replies.isEmpty, "gate: one of two said true: no answer yet", "\(rig.replies)")
            rig.gate.replied(0, true)
            check(rig.replies.isEmpty, "gate: the same member twice does not count twice", "\(rig.replies)")
            rig.gate.replied(1, true)
            check(rig.replies == [true] && rig.resumed == [0, 0], "gate: both said true: true, once", "\(rig.replies)")
            rig.gate.replied(1, false)
            rig.gate.replied(0, true)
            check(rig.replies == [true] && rig.resumed == [0, 0], "gate: replies after the answer are ignored", "\(rig.replies)")
        }
        do {
            // The first false: false at once, and every other member resumed.
            let rig = GateRig([true, true])
            _ = rig.gate.ask()
            rig.gate.replied(1, false)
            check(rig.replies == [false], "gate: the first false answers false at once", "\(rig.replies)")
            check(rig.resumed == [1, 0], "gate: the other member (still waiting) is resumed; the one that said false is not",
                  "\(rig.resumed)")
            rig.gate.replied(0, true)
            rig.gate.replied(0, false)
            check(rig.replies == [false] && rig.resumed == [1, 0], "gate: after false, later replies are ignored",
                  "\(rig.replies) \(rig.resumed)")

            // A new question after a cancelled one starts afresh.
            check(rig.gate.ask() == true && rig.asked == [2, 2], "gate: a new quit asks both again", "\(rig.asked)")
            rig.gate.replied(1, true)
            check(rig.replies == [false], "gate: the new quit waits for both again", "\(rig.replies)")
            rig.gate.replied(0, true)
            check(rig.replies == [false, true] && rig.resumed == [1, 0], "gate: the new quit answers true once both did",
                  "\(rig.replies) \(rig.resumed)")
        }
        do {
            // A member that already said true is resumed too when another says false: it was stopped as well.
            let rig = GateRig([true, true])
            _ = rig.gate.ask()
            rig.gate.replied(0, true)
            rig.gate.replied(1, false)
            check(rig.replies == [false] && rig.resumed == [1, 0], "gate: true then false: false, and the first is resumed",
                  "\(rig.replies) \(rig.resumed)")
        }
        do {
            // A member that did not wait is resumed when the one that waited says false.
            let rig = GateRig([false, true])
            check(rig.gate.ask() == true, "gate: one waits: terminate later")
            rig.gate.replied(0, true)
            check(rig.replies.isEmpty, "gate: a reply from a member that did not wait is ignored", "\(rig.replies)")
            rig.gate.replied(1, false)
            check(rig.replies == [false] && rig.resumed == [1, 0], "gate: the member that did not wait is resumed",
                  "\(rig.replies) \(rig.resumed)")
            // Afresh: now none waits.
            rig.members[1].waits = false
            check(rig.gate.ask() == false, "gate: after a cancelled quit, a quit with none waiting terminates now")
            rig.gate.replied(1, true)
            check(rig.replies == [false], "gate: a late reply after that is ignored", "\(rig.replies)")
        }
        do {
            let rig = GateRig([true, false])
            _ = rig.gate.ask()
            rig.gate.replied(0, true)
            check(rig.replies == [true] && rig.resumed == [0, 0], "gate: the only waiting member says true: true at once",
                  "\(rig.replies)")
        }
        do {
            let rig = GateRig([true, false])
            _ = rig.gate.ask()
            rig.gate.replied(0, false)
            check(rig.replies == [false] && rig.resumed == [0, 1], "gate: the only waiting member says false: the other resumed",
                  "\(rig.replies) \(rig.resumed)")
        }
    }

    // The lines the window and the menu bar's panel show while a quit waits (quitNoticeLines): the Messages
    // controller's, then the modem tabs', only those set, and a line both give once; with the real controllers,
    // a listing and the Network tab's read both waiting give the read's line once.
    static func lines() {
        let send = "RMNet quits when the message being sent has finished."
        let reading = "RMNet quits when the current request to the modem has finished."
        let bands = "RMNet quits when the bands have been changed."
        check(quitNoticeLines(messages: "", modem: "") == [], "lines: none while no quit waits")
        check(quitNoticeLines(messages: send, modem: "") == [send], "lines: the Messages tab's alone")
        check(quitNoticeLines(messages: "", modem: bands) == [bands], "lines: the modem tabs' alone")
        check(quitNoticeLines(messages: send, modem: bands) == [send, bands], "lines: both, the Messages tab's first")
        check(quitNoticeLines(messages: reading, modem: reading) == [reading], "lines: the same line once")

        let app = App()
        app.messages.setTabShown(true)
        pump(until: { app.calls.log == ["list"] && app.calls.blocked == 1 }, "lines: the listing runs")
        app.modem.setTabShown(.network)
        holdTimer(app.modem)
        check(app.quit() == true, "lines: the quit waits")
        check(quitNoticeLines(messages: app.messages.quitNotice.line, modem: app.modem.quitNotice.line) == [reading],
              "lines: a listing and a read waiting: the read's line once",
              "\(app.messages.quitNotice.line) | \(app.modem.quitNotice.line)")
        app.calls.release()
        pump(until: { app.calls.log == ["list", "networkInfo"] && app.calls.blocked == 1 }, "lines: the modem's read runs")
        app.calls.release()
        pump(until: { !app.replies.isEmpty }, "lines: the answer")
        check(app.replies == [true], "lines: the quit goes ahead", "\(app.replies)")
        check(quitNoticeLines(messages: app.messages.quitNotice.line, modem: app.modem.quitNotice.line) == [],
              "lines: none once the quit has its answer")
        app.modem.setTabShown(nil)
        app.messages.setTabShown(false)
    }

    // The whole-branch review's case: a send runs, the Network tab's read waits behind it on the shared
    // queue, Cmd-Q, the send fails. The failed send cancels the quit (its sentence stays on screen), and the
    // modem read that succeeds afterwards does not end the app.
    static func reviewCase() {
        let app = App()
        app.startSend()
        app.modem.setTabShown(.network)
        holdTimer(app.modem)
        check(app.modem.running == .reading && app.calls.log == ["send"], "review case: the modem's read waits behind the send",
              "\(app.calls.log)")
        check(app.quit() == true, "review case: the quit waits")
        check(app.messages.quitNotice.line == "RMNet quits when the message being sent has finished."
              && app.modem.quitNotice.line == "RMNet quits when the current request to the modem has finished.",
              "review case: both quit lines show", "\(app.messages.quitNotice.line) | \(app.modem.quitNotice.line)")
        check(quitNoticeLines(messages: app.messages.quitNotice.line, modem: app.modem.quitNotice.line)
              == [app.messages.quitNotice.line, app.modem.quitNotice.line],
              "review case: the window and the panel show both lines, the Messages tab's first")
        app.smsFake.releaseSend(.failure(notKnown))
        pump(until: { !app.replies.isEmpty }, "review case: the answer")
        check(app.replies == [false], "review case: the failed send cancels the quit", "\(app.replies)")
        check(app.messages.result == notKnown.message && app.messages.resultIsFailure,
              "review case: the send's sentence stays on screen", app.messages.result)
        check(app.attention == 1, "review case: the app asks for attention once", "\(app.attention)")
        check(app.modem.quitNotice.line == "" && app.messages.quitNotice.line == "", "review case: both quit lines go")
        pump(until: { app.calls.log == ["send", "networkInfo"] && app.calls.blocked == 1 }, "review case: the modem's read runs")
        app.modemFake.releaseInfo(.success(NetworkInfo(radio: .on, mode: "AUTO")))
        pump(until: { app.modem.running == nil }, "review case: the modem's read comes back")
        settle()
        check(app.replies == [false], "review case: the modem's read that succeeds does not answer the quit again",
              "\(app.replies)")
        check(app.modem.info?.mode == "AUTO" && app.modem.refreshEnabled && app.messages.refreshEnabled,
              "review case: both controllers work again")
        check(app.calls.mostAtOnce == 1, "review case: one call at a time on the shared queue")
        app.modem.setTabShown(nil)
    }

    // The other order: a radio switch fails while a send waits behind it. The quit is cancelled at once, and
    // the send that then succeeds does not end the app; the Messages controller works again.
    static func modemFailsFirst() {
        let app = App()
        app.modem.setRadio(on: false)
        pump(until: { app.calls.log == ["setRadio"] && app.calls.blocked == 1 }, "modem first: the switch runs")
        app.messages.to = "+27831234567"
        app.messages.text = "hello"
        app.messages.send()
        check(app.messages.running == .sending, "modem first: the send waits behind the switch")
        check(app.quit() == true, "modem first: the quit waits")
        app.modemFake.releaseRadio(.failure(notAnswered))
        pump(until: { !app.replies.isEmpty }, "modem first: the answer")
        check(app.replies == [false] && app.modem.result == notAnswered.message, "modem first: the failed switch cancels the quit",
              "\(app.replies) \(app.modem.result)")
        check(app.messages.quitNotice.line == "", "modem first: the Messages quit line goes at once")
        pump(until: { app.calls.log == ["setRadio", "send"] && app.calls.blocked == 1 }, "modem first: the send runs")
        app.smsFake.releaseSend(.success(1))
        pump(until: { app.messages.running == nil }, "modem first: the send comes back")
        settle()
        check(app.replies == [false] && app.attention == 1, "modem first: the send that succeeds does not answer the quit again",
              "\(app.replies) \(app.attention)")
        check(app.messages.result == "Sent to +27831234567 in 1 part(s)." && app.messages.sendEnabled == false
              && app.messages.refreshEnabled, "modem first: the Messages controller works again", app.messages.result)
    }

    // The SIM slot watcher's try and its switch back are one unit for the quit: asked while the try runs, the quit waits
    // for the switch back too (the modem is never left on the empty slot it tried), and the app ends after both, with
    // the watcher's line saying what came of them.
    static func quitWaitsForSwitchBack() {
        let app = App()
        app.watcher.modemPresent(true)
        app.emptySlotFor25s()
        pump(until: { app.calls.log == ["setSimSlot 2"] && app.calls.blocked == 1 }, "switch back: the try runs")
        check(app.quit() == true, "switch back: the quit waits for the try")
        equal(app.modem.quitNotice.line, "RMNet quits when the SIM slot has been switched.", "switch back: the quit line")
        app.modemFake.releaseSlot(.success(SimSlotChange(before: 1, after: 2, sim: .notInserted)))
        pump(until: { app.calls.log == ["setSimSlot 2", "setSimSlot 1"] && app.calls.blocked == 1 },
             "switch back: runs while the app quits")
        settle()
        check(app.replies.isEmpty, "switch back: the quit still waits", "\(app.replies)")
        equal(app.modem.quitNotice.line, "RMNet quits when the SIM slot has been switched.", "switch back: the line stays")
        app.modemFake.releaseSlot(.success(SimSlotChange(before: 2, after: 1, sim: .notInserted)))
        pump(until: { !app.replies.isEmpty }, "switch back: the answer")
        equal(app.replies, [true], "switch back: the app ends after both")
        equal(app.watcher.line, "No SIM in either slot.", "switch back: the watcher heard of both")
        check(!app.watcher.switchRunning && app.attention == 0, "switch back: nothing left running, no attention")
        check(app.calls.mostAtOnce == 1, "switch back: one call at a time on the shared queue")
    }

    // A watcher's try that waits behind a read when the quit is asked is dropped, and the watcher hears it was
    // cancelled; when the quit is then cancelled (the Messages send failed), the watcher is free and tries again after
    // its patience, instead of waiting for a switch that will never run.
    static func cancelledQuitFreesWatcher() {
        let app = App()
        app.startSend()
        app.modem.setTabShown(.network)
        holdTimer(app.modem)
        check(app.modem.running == .reading, "cancelled: the modem's read waits behind the send")
        app.watcher.modemPresent(true)
        app.emptySlotFor25s()
        check(app.watcher.switchRunning, "cancelled: the watcher's try waits behind the read")
        check(app.quit() == true, "cancelled: the quit waits")
        check(!app.watcher.switchRunning, "cancelled: the dropped try reported cancelled")
        equal(app.modem.result, "", "cancelled: no result line for the dropped automatic switch")
        app.smsFake.releaseSend(.failure(notKnown))
        pump(until: { !app.replies.isEmpty }, "cancelled: the answer")
        equal(app.replies, [false], "cancelled: the failed send cancels the quit")
        pump(until: { app.calls.log == ["send", "networkInfo"] && app.calls.blocked == 1 }, "cancelled: the read runs")
        app.modemFake.releaseInfo(.success(NetworkInfo(radio: .on, mode: "AUTO")))
        pump(until: { app.modem.running == nil }, "cancelled: the read comes back")
        app.modem.setTabShown(nil)
        equal(app.watcher.pulseCommands(), SimSlotWatcher.commands, "cancelled: the watcher reads again")
        app.clock += 15
        app.emptySlotFor25s()
        pump(until: { app.calls.log.last == "setSimSlot 2" && app.calls.blocked == 1 }, "cancelled: the try again")
        app.modemFake.releaseSlot(.success(SimSlotChange(before: 1, after: 2, sim: .ready)))
        pump(until: { !app.watcher.switchRunning }, "cancelled: the try finishes")
        equal(app.watcher.line, "Switched to SIM 2: no SIM in slot 1.", "cancelled: its line")
    }

    // Both calls succeed: the app ends once both have finished, not before.
    static func bothSucceed() {
        let app = App()
        app.startSend()
        app.modem.setTabShown(.network)
        holdTimer(app.modem)
        check(app.quit() == true, "both succeed: the quit waits")
        app.smsFake.releaseSend(.success(1))
        pump(until: { app.calls.log == ["send", "networkInfo"] && app.calls.blocked == 1 }, "both succeed: the modem's read runs")
        settle()
        check(app.replies.isEmpty, "both succeed: no answer while the modem's read runs", "\(app.replies)")
        app.modemFake.releaseInfo(.success(NetworkInfo()))
        pump(until: { !app.replies.isEmpty }, "both succeed: the answer")
        settle()
        check(app.replies == [true] && app.attention == 0, "both succeed: true, once", "\(app.replies)")
        app.modem.setTabShown(nil)
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}
