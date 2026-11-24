// Tests for app/SmsController.swift: the controller driven by a fake SmsServing whose calls block until
// the test releases them, with the main run loop pumped so that results come back as in the app. Built
// with swiftc by `make app-test` from app/SmsModel.swift, app/SmsController.swift and this file; needs no
// AppKit, no window and no modem.
// Stops at the first failure, prints which check failed and exits 1.
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

// MARK: - The fake service

enum Call: Equatable {
    case list
    case delete([Int])
    case send(String, String)
    case resend([Int])
    case unblockSlice(start: Bool, finish: Bool)
    case healCnmi
}

/// Records each call, then blocks it (on the controller's queue) until the test releases it with a result.
final class FakeService: SmsServing {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var log: [Call] = []
    private var listResults: [Result<SmsListing, SmsFailure>] = []
    private var deleteResults: [Result<Int, SmsFailure>] = []
    private var sendResults: [Result<SmsSent, SmsFailure>] = []
    private var unblockResults: [Result<SmsUnblockSlice, SmsFailure>] = []
    private var countResults: [Result<SmsStoreCount, SmsFailure>] = []
    private var inside = 0   // calls entered and not yet returned
    private var mostInside = 0

    var calls: [Call] { locked { log } }
    var blocked: Int { locked { inside } }
    var mostAtOnce: Int { locked { mostInside } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func enter(_ call: Call) {
        locked {
            log.append(call)
            inside += 1
            mostInside = max(mostInside, inside)
        }
        gate.wait()
        locked { inside -= 1 }
    }

    func list() -> Result<SmsListing, SmsFailure> {
        enter(.list)
        return locked { listResults.removeFirst() }
    }

    func delete(indices: [Int]) -> Result<Int, SmsFailure> {
        enter(.delete(indices))
        return locked { deleteResults.removeFirst() }
    }

    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        enter(.send(number, text))
        return locked { sendResults.removeFirst() }
    }

    // The window's delete and Retry (checked against the modem by the real service): the indices of the parts.
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure> {
        enter(.delete(parts.map { $0.index }))
        return locked { deleteResults.removeFirst() }
    }

    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure> {
        enter(.resend(parts.map { $0.index }))
        return locked { sendResults.removeFirst() }
    }

    func unblockSlice(start: Bool, finish: Bool) -> Result<SmsUnblockSlice, SmsFailure> {
        enter(.unblockSlice(start: start, finish: finish))
        return locked { unblockResults.removeFirst() }
    }

    func healCnmi() -> Result<SmsUnblockSlice, SmsFailure> {
        enter(.healCnmi)
        return locked { unblockResults.removeFirst() }
    }

    func countUnread() -> Result<SmsStoreCount, SmsFailure> {
        locked { countResults.removeFirst() }
    }

    func releaseList(_ result: Result<SmsListing, SmsFailure>) { locked { listResults.append(result) }; gate.signal() }
    func releaseDelete(_ result: Result<Int, SmsFailure>) { locked { deleteResults.append(result) }; gate.signal() }
    /// The parts sent (stored at no index known to the test), or the failure.
    func releaseSend(_ result: Result<Int, SmsFailure>) {
        locked { sendResults.append(result.map { SmsSent(parts: $0) }) }
        gate.signal()
    }
    func releaseSent(_ result: Result<SmsSent, SmsFailure>) { locked { sendResults.append(result) }; gate.signal() }
    func releaseUnblock(_ result: Result<SmsUnblockSlice, SmsFailure>) {
        locked { unblockResults.append(result) }
        gate.signal()
    }
    func queueCount(_ result: Result<SmsStoreCount, SmsFailure>) { locked { countResults.append(result) } }
}

// MARK: - Helpers

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

/// A controller with a fake service, and what it answered to quits and how often it asked for attention.
final class Rig {
    let fake = FakeService()
    var replies: [Bool] = []
    var attention = 0
    lazy var controller = SmsController(service: fake,
                                        replyToQuit: { [unowned self] in self.replies.append($0) },
                                        requestAttention: { [unowned self] in self.attention += 1 })

    /// The controller ready to send: a valid number and a text.
    func ready(_ text: String = "hello") {
        controller.to = "+27831234567"
        controller.text = text
    }

    /// Starts a send and waits until the fake has it.
    func startSend() {
        let before = fake.calls.count
        controller.send()
        pump(until: { fake.calls.count == before + 1 && fake.blocked == 1 }, "the send reaches the service")
    }

    /// Lists once (the given result) and waits for it to come back.
    func list(_ result: Result<SmsListing, SmsFailure>) {
        let before = fake.calls.count
        controller.refresh()
        pump(until: { fake.calls.count == before + 1 && fake.blocked == 1 }, "the listing reaches the service")
        fake.releaseList(result)
        pump(until: { controller.running == nil }, "the listing comes back")
    }
}

func message(_ indices: [Int], sender: String = "+27838890001", text: String = "hi") -> SmsMessage {
    SmsMessage(indices: indices, unread: false, sender: sender, timestamp: Date(timeIntervalSince1970: 1794657609),
               text: text, missingParts: 0, readable: true)
}

/// A listing of `messages`, each stored part listed too (as the service lists them: a delete takes them from there).
func listing(_ messages: [SmsMessage], used: Int? = nil, total: Int? = nil) -> Result<SmsListing, SmsFailure> {
    let parts = messages.flatMap { m in m.indices.map { StoredPdu(index: $0, status: .read, hex: String(format: "00%04X", $0)) } }
    return .success(SmsListing(messages: messages, used: used, total: total, parts: parts))
}

let notKnown = SmsFailure(message: "The message failed. The modem did not answer in time. It is not known whether it was "
                          + "sent. It may have been delivered; sending it again may deliver it twice.")
let refused = SmsFailure(message: "The message was refused. The modem refused the command (+CMS ERROR: 350). Nothing was sent.")
let listFailed = SmsFailure(message: "Another program is using the modem's spare AT port.")
let deleteFailed = SmsFailure(message: "Stored part 3 could not be deleted. The modem refused the command (ERROR). "
                              + "0 of 2 stored part(s) were deleted before it.")

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

/// Timers that run when the test moves the time on (the result banner's).
final class FakeClock {
    private(set) var now: TimeInterval = 0
    private var timers: [(due: TimeInterval, body: () -> Void)] = []

    func after(_ delay: TimeInterval, _ body: @escaping () -> Void) { timers.append((now + delay, body)) }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.enumerated().filter({ $0.element.due <= end }).min(by: { $0.element.due < $1.element.due }) {
            timers.remove(at: next.offset)
            now = next.element.due
            next.element.body()
        }
        now = end
    }
}

// MARK: - The checks

@main
struct SmsControllerTests {
    static func main() {
        oneCallAtATime()
        twoLines()
        deleting()
        quitting()
        resuming()
        composingAndStore()
        banner()
        unblocking()
        print("smsui-test: \(checks) checks passed")
    }

    // A second send while one runs does nothing; a tick or a refresh during a send does nothing.
    static func oneCallAtATime() {
        let rig = Rig()
        let c = rig.controller
        rig.ready()
        check(c.sendEnabled, "send: enabled with a number and a text")
        rig.startSend()
        check(c.running == .sending, "send: running is .sending")
        check(!c.sendEnabled && !c.refreshEnabled && !c.changeEnabled, "send: nothing else is enabled while it runs")
        c.send()
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls == [.send("+27831234567", "hello")], "send: a second send, a tick and a refresh while a send runs do nothing",
              "\(rig.fake.calls)")
        rig.fake.releaseSend(.success(1))
        pump(until: { c.running == nil }, "the send comes back")
        check(rig.fake.mostAtOnce == 1, "send: never two calls in the service at once")
        check(c.result == "Sent to +27831234567 in 1 part(s)." && !c.resultIsFailure, "send: success sentence", c.result)
        check(c.text == "", "send: the text is cleared after a success")

        // A tick while a listing runs also does nothing.
        let rig2 = Rig()
        rig2.controller.refresh()
        pump(until: { rig2.fake.blocked == 1 }, "a listing starts")
        rig2.controller.tick()
        rig2.controller.refresh()
        settle()
        check(rig2.fake.calls == [.list], "list: a tick and a refresh during a listing do nothing", "\(rig2.fake.calls)")
        rig2.fake.releaseList(listing([]))
        pump(until: { rig2.controller.running == nil }, "the listing comes back")
    }

    // The result line (a send's or delete's) and the list line are kept apart: a listing that fails after a
    // send or delete leaves the result line alone. Typing clears a success's line, not a failure's.
    static func twoLines() {
        // 1. A send that succeeds, then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(true)  // active: the tab lists after a send
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([]))
            pump(until: { c.running == nil }, "the first listing comes back")
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.success(1))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the send starts")
            check(rig.fake.calls.last == .list, "lines: a send that succeeds is followed by a listing")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == "Sent to +27831234567 in 1 part(s)." && !c.resultIsFailure,
                  "lines: a failed listing after a successful send keeps the send's sentence", c.result)
            check(c.listFailure == listFailed.message && c.listText.hasPrefix(listFailed.message),
                  "lines: the listing's failure is on the list line", c.listText)
            c.setTabShown(false)
        }
        // 2. A send that fails (not known), then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(true)
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([]))
            pump(until: { c.running == nil }, "the first listing comes back")
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.failure(notKnown))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the send starts")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == notKnown.message && c.resultIsFailure,
                  "lines: a failed listing after a failed send keeps the send's failure", c.result)
            check(c.text == "hello", "lines: the text is kept after a failed send")
            c.setTabShown(false)
        }
        // 3. A delete that succeeds, then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            let m = message([3, 4])
            c.setTabShown(true)
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([m]))
            pump(until: { c.running == nil }, "the first listing comes back")
            c.delete(m)
            pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
            rig.fake.releaseDelete(.success(2))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the delete starts")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == "Deleted 2 stored part(s)." && !c.resultIsFailure,
                  "lines: a failed listing after a delete keeps the delete's sentence", c.result)
            c.setTabShown(false)
        }
        // Typing after a success clears the result line; after a failure it does not.
        do {
            let rig = Rig()
            let c = rig.controller
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.success(1))
            pump(until: { c.running == nil }, "the send comes back")
            c.text = "n"
            check(c.result == "", "lines: typing after a successful send clears the result line", c.result)
        }
        do {
            let rig = Rig()
            let c = rig.controller
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.failure(refused))
            pump(until: { c.running == nil }, "the send comes back")
            c.text = "hello again"
            check(c.result == refused.message && c.resultIsFailure,
                  "lines: typing after a failed send keeps the failure on the result line", c.result)
        }
    }

    // Delete passes the message's whole indices, and refuses a message that is no longer listed.
    static func deleting() {
        let rig = Rig()
        let c = rig.controller
        let m = message([3, 4, 7])
        rig.list(listing([m]))
        c.delete(m)
        pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
        check(rig.fake.calls.last == .delete([3, 4, 7]), "delete: the message's whole indices are passed", "\(rig.fake.calls)")
        check(c.result == "Deleting 3 stored part(s)…", "delete: the running sentence", c.result)
        rig.fake.releaseDelete(.success(3))
        pump(until: { c.running == nil }, "the delete comes back")
        check(c.result == "Deleted 3 stored part(s).", "delete: the success sentence", c.result)

        let gone = message([9], sender: "+27830000000")
        let before = rig.fake.calls
        c.delete(gone)
        settle()
        check(rig.fake.calls == before, "delete: a message no longer listed is not deleted", "\(rig.fake.calls)")
        check(c.result == "That message is no longer listed. Nothing was deleted." && c.resultIsFailure,
              "delete: the refusal sentence", c.result)

        // A delete while another call runs is refused (a refresh began just before the confirmation).
        c.refresh()
        pump(until: { rig.fake.blocked == 1 }, "a listing starts")
        c.delete(m)
        check(c.result == "The modem was busy with another request. Nothing was deleted; press Delete again.",
              "delete: refused while a listing runs", c.result)
        rig.fake.releaseList(listing([m]))
        pump(until: { c.running == nil }, "the listing comes back")
        check(rig.fake.calls.filter({ if case .delete = $0 { return true } else { return false } }).count == 1,
              "delete: the refused delete did not reach the service", "\(rig.fake.calls)")
    }

    // Quitting: at once with nothing running; after a running call, true exactly once when it was a
    // listing or a send or delete that succeeded, false exactly once (and attention) when a send or delete
    // did not succeed. No listing starts after a quit began.
    static func quitting() {
        // Nothing running.
        do {
            let rig = Rig()
            check(rig.controller.quitWhenFinished() == false, "quit: nothing running answers at once (terminate now)")
            settle()
            check(rig.replies.isEmpty && rig.attention == 0, "quit: nothing running needs no later reply", "\(rig.replies)")
        }

        // Each kind of call, and how it ends.
        enum Ending { case list, sendOK, sendFailed, sendNotKnown, deleteOK, deleteFailed }
        let cases: [(Ending, Bool, String)] = [
            (.list, true, "RMNet quits when the current request to the modem has finished."),
            (.sendOK, true, "RMNet quits when the message being sent has finished."),
            (.deleteOK, true, "RMNet quits when the message being deleted has finished."),
            (.sendFailed, false, "RMNet quits when the message being sent has finished."),
            (.sendNotKnown, false, "RMNet quits when the message being sent has finished."),
            (.deleteFailed, false, "RMNet quits when the message being deleted has finished."),
        ]
        for (ending, goesAhead, notice) in cases {
            let name = "quit during \(ending)"
            let rig = Rig()
            let c = rig.controller
            let m = message([3, 4])
            c.setTabShown(true)  // active: without the quit, a listing would follow a send or delete
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            if ending != .list {
                rig.fake.releaseList(listing([m]))
                pump(until: { c.running == nil }, "the first listing comes back")
                switch ending {
                case .deleteOK, .deleteFailed:
                    c.delete(m)
                    pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
                default:
                    rig.ready()
                    rig.startSend()
                }
            }
            let callsBefore = rig.fake.calls.count
            check(c.quitWhenFinished() == true, "\(name): the quit waits (terminate later)")
            check(c.quitNotice.line == notice, "\(name): the window's quit line", c.quitNotice.line)
            check(rig.replies.isEmpty, "\(name): no reply while the call runs", "\(rig.replies)")
            c.tick()
            c.refresh()
            switch ending {
            case .list: rig.fake.releaseList(listing([m]))
            case .sendOK: rig.fake.releaseSend(.success(1))
            case .sendFailed: rig.fake.releaseSend(.failure(refused))
            case .sendNotKnown: rig.fake.releaseSend(.failure(notKnown))
            case .deleteOK: rig.fake.releaseDelete(.success(2))
            case .deleteFailed: rig.fake.releaseDelete(.failure(deleteFailed))
            }
            pump(until: { !rig.replies.isEmpty }, "\(name): the reply")
            settle()
            check(rig.replies == [goesAhead], "\(name): replies \(goesAhead) exactly once", "\(rig.replies)")
            check(c.quitNotice.line == "", "\(name): the quit line goes when the call has finished", c.quitNotice.line)
            if goesAhead {
                check(rig.attention == 0, "\(name): no request for attention")
                check(rig.fake.calls.count == callsBefore, "\(name): no listing starts after the quit began",
                      "\(rig.fake.calls)")
                c.tick()
                c.refresh()
                settle()
                check(rig.fake.calls.count == callsBefore && !c.refreshEnabled && !c.sendEnabled,
                      "\(name): nothing starts while the app ends", "\(rig.fake.calls)")
            } else {
                check(rig.attention == 1, "\(name): asks for attention once", "\(rig.attention)")
                let want: String
                switch ending {
                case .sendFailed: want = refused.message
                case .sendNotKnown: want = notKnown.message
                default: want = deleteFailed.message
                }
                check(c.result == want && c.resultIsFailure, "\(name): the result line keeps the sentence", c.result)
                // The quit is cancelled: the app goes on, and the shown tab lists again.
                pump(until: { rig.fake.calls.count == callsBefore + 1 && rig.fake.blocked == 1 }, "\(name): the tab lists again")
                rig.fake.releaseList(listing([m]))
                pump(until: { c.running == nil }, "\(name): that listing comes back")
                check(c.result == want, "\(name): the listing after the cancelled quit leaves the result line", c.result)
                check(c.refreshEnabled, "\(name): the controller works again after the cancelled quit")
                settle()
                check(rig.replies == [false] && rig.attention == 1, "\(name): still exactly one reply", "\(rig.replies)")
            }
            c.setTabShown(false)
        }
    }

    // resumeAfterCancelledQuit (the modem tabs' controller cancelled the quit, ruling R18): working again,
    // listing at once with the timer back if the tab is shown; a quit still waiting is cancelled too, its
    // line goes at once, and it is never answered (the running call is not cut short).
    static func resuming() {
        let rig = Rig()
        let c = rig.controller
        func timer() -> Timer? {
            Mirror(reflecting: c).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
        }
        c.setTabShown(true)
        pump(until: { rig.fake.calls.count == 1 && rig.fake.blocked == 1 }, "resume: the first listing")
        rig.fake.releaseList(listing([]))
        pump(until: { c.running == nil }, "resume: the first listing comes back")
        rig.ready()
        check(c.quitWhenFinished() == false, "resume: the quit answered at once")
        check(timer() == nil && !c.refreshEnabled && !c.sendEnabled, "resume: stopped while the app ends")
        c.resumeAfterCancelledQuit()
        pump(until: { rig.fake.calls.count == 2 && rig.fake.blocked == 1 }, "resume: the shown tab lists at once")
        rig.fake.releaseList(listing([]))
        pump(until: { c.running == nil }, "resume: that listing comes back")
        check(timer()?.isValid == true && c.refreshEnabled && c.sendEnabled && c.quitNotice.line == "",
              "resume: the timer runs again and the controller works")

        // A quit that waits for a send, cancelled elsewhere: the line goes at once; the send runs to its end
        // and its result stays, with no answer to the quit and no request for attention.
        rig.startSend()
        check(c.quitWhenFinished() == true, "resume: a quit waits for the send")
        check(c.quitNotice.line == "RMNet quits when the message being sent has finished.", "resume: the quit line",
              c.quitNotice.line)
        c.resumeAfterCancelledQuit()
        check(c.quitNotice.line == "", "resume: the quit line goes at once", c.quitNotice.line)
        check(c.running == .sending && rig.fake.calls.count == 3, "resume: the send is not cut short and nothing else starts",
              "\(rig.fake.calls)")
        rig.fake.releaseSend(.failure(notKnown))
        pump(until: { rig.fake.calls.count == 4 && rig.fake.blocked == 1 }, "resume: the tab lists after the send")
        check(c.result == notKnown.message && c.resultIsFailure, "resume: the send's sentence stays", c.result)
        rig.fake.releaseList(listing([]))
        pump(until: { c.running == nil }, "resume: that listing comes back")
        settle()
        check(rig.replies.isEmpty && rig.attention == 0, "resume: a cancelled quit that was waiting is never answered",
              "\(rig.replies) \(rig.attention)")

        // With the tab not shown: working again, but nothing is listed and no timer runs.
        c.setTabShown(false)
        _ = c.quitWhenFinished()
        c.resumeAfterCancelledQuit()
        settle()
        check(rig.fake.calls.count == 4 && timer() == nil && c.refreshEnabled,
              "resume: with the tab not shown, nothing is listed and no timer runs", "\(rig.fake.calls)")
    }

    // Send waits while an input method composes; the store's warning reaches the list line.
    static func composingAndStore() {
        let rig = Rig()
        let c = rig.controller
        rig.ready()
        check(c.sendEnabled, "composing: send enabled before")
        c.composing = true
        check(!c.sendEnabled, "composing: sendEnabled is false while composing")
        check(c.composeText == "Finish the input being composed (the underlined text) before sending.",
              "composing: the line under the text says so", c.composeText)
        c.send()
        settle()
        check(rig.fake.calls.isEmpty, "composing: send() does nothing while composing", "\(rig.fake.calls)")
        c.composing = false
        check(c.sendEnabled && c.composeText == "1 part, GSM alphabet", "composing: enabled again when finished", c.composeText)

        rig.list(listing([message([1])], used: 22, total: 255))
        check(c.listText.hasSuffix(" 22 of 255 stored parts."), "store: the use reaches the list line", c.listText)
        rig.list(listing([message([1])], used: 230, total: 255))
        check(c.listText.hasSuffix(" 230 of 255 stored parts. The modem's message store is nearly full (230 of 255). "
                                   + "Delete old messages, or new ones will not arrive."),
              "store: the warning reaches the list line", c.listText)
        rig.list(listing([message([1])], used: nil, total: nil))
        check(!c.listText.contains("stored parts"), "store: unknown use is not shown", c.listText)
    }

    // The result banner: dismissed, the line is cleared in the controller, so showing another screen and this one
    // again (or a new window, which reads the same controller) does not bring it back; a success goes after 8 s; a
    // failure stays; a new result replaces the old one.
    static func banner() {
        let fake = FakeService()
        let clock = FakeClock()
        let c = SmsController(service: fake, replyToQuit: { _ in }, requestAttention: {}, resultTimer: clock.after)
        func send(_ outcome: Result<Int, SmsFailure>) {
            c.to = "+12025550100"
            c.text = "Made-up text"
            c.send()
            pump(until: { fake.blocked == 1 }, "banner: the send reaches the service")
            check(c.resultKind == .progress, "banner: the send's words while it runs", "\(c.resultKind)")
            clock.advance(30)
            check(!c.result.isEmpty, "banner: a request's words do not go by themselves")
            fake.releaseSend(outcome)
            pump(until: { c.running == nil }, "banner: the send comes back")
        }

        // Dismissed: cleared, and another screen and back (with its listing) does not bring it back.
        send(.success(1))
        equal(c.result, "Sent to +12025550100 in 1 part(s).", "banner: the success")
        check(c.resultKind == .success, "banner: a success")
        c.dismissResult()
        equal(c.result, "", "banner: dismissed, the line is cleared")
        c.setTabShown(false)
        c.setTabShown(true)
        pump(until: { fake.blocked == 1 }, "banner: the screen lists again")
        fake.releaseList(listing([]))
        pump(until: { c.running == nil }, "banner: the listing comes back")
        c.setTabShown(false)
        equal(c.result, "", "banner: dismissed, it does not come back on another screen and back")

        // A success goes after 8 s, not before.
        send(.success(1))
        clock.advance(7.5)
        equal(c.result, "Sent to +12025550100 in 1 part(s).", "banner: a success still there at 7.5 s")
        clock.advance(0.5)
        equal(c.result, "", "banner: a success gone at 8 s")
        // Not while the pointer is on it.
        send(.success(1))
        c.hoverResult(true)
        clock.advance(20)
        check(!c.result.isEmpty, "banner: under the pointer, it stays")
        c.hoverResult(false)
        clock.advance(ResultExpiry.afterHover)
        equal(c.result, "", "banner: gone after the pointer left")

        // A failure stays until dismissed or replaced.
        send(.failure(refused))
        clock.advance(3600)
        equal(c.result, refused.message, "banner: a failure stays")
        check(c.resultKind == .failure && c.resultIsFailure, "banner: a failure")
        // A new result replaces it (and a success's time starts with it).
        send(.success(2))
        equal(c.result, "Sent to +12025550100 in 2 part(s).", "banner: the next result replaces the failure")
        clock.advance(8)
        equal(c.result, "", "banner: and goes as a success")

        // A success with something to read (not stored on the modem) is a warning: it stays.
        c.to = "+12025550100"
        c.text = "Made-up text"
        c.send()
        pump(until: { fake.blocked == 1 }, "banner: a send")
        fake.releaseSent(.success(SmsSent(parts: 1, indices: [], stored: false)))
        pump(until: { c.running == nil }, "banner: it comes back")
        check(c.resultKind == .warning, "banner: not stored, a warning", "\(c.resultKind)")
        clock.advance(60)
        check(c.result.hasPrefix("Sent to +12025550100 in 1 part(s). It is not stored"), "banner: a warning stays", c.result)
    }

    // Manual Unblock, automatic unblocking when +CMTI without storage is seen, notice when the setting is off,
    // healing AT+CNMI=2,2 on pulse, and quitting between or during slices.
    static func unblocking() {
        let mmsHex = "07912120550501F04404C9320000046211220292942B2C0605040B8423F0010601BE8C82987478008D9089178031323032353535303134342F545950453D504C4D4E00"
        let smsHex = "07912120550501F0040B912120550561F400006211220293002B05C8329BFD06"
        let mmsPart = StoredPdu(index: 10, status: .unread, hex: mmsHex)
        let smsPart = StoredPdu(index: 11, status: .unread, hex: smsHex)

        let fake = FakeService()
        var autoOn = false
        var notifyOn = true
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        var alerts: [MessageAlert] = []
        var replies: [Bool] = []
        let c = SmsController(service: fake,
                              replyToQuit: { replies.append($0) },
                              requestAttention: {},
                              notifyEnabled: { notifyOn },
                              autoUnblockEnabled: { autoOn },
                              unblockWindow: 10,
                              slicePause: 0.01,
                              now: { clock },
                              alert: { alerts.append($0) })

        // Setting off: blockedSmsSeen marks incomingBlocked without calling the service; turning it on starts unblocking.
        c.blockedSmsSeen()
        check(c.incomingBlocked && fake.calls.isEmpty, "unblock: setting off shows notice without opening port")
        autoOn = true
        c.autoUnblockSettingChanged(true)
        pump(until: { fake.calls == [.unblockSlice(start: true, finish: false)] && fake.blocked == 1 },
             "unblock: turning setting on starts slice 1")
        check(!c.incomingBlocked && c.running == .unblocking, "unblock: incomingBlocked cleared while running")
        // Slice 1 receives MMS + SMS; slice 2 is quiet -> finalization slice restores 2,1 and counts unread in the background.
        fake.queueCount(.success(SmsStoreCount(used: 2, received: 2, unread: 2)))
        fake.releaseUnblock(.success(SmsUnblockSlice(parts: [mmsPart, smsPart])))
        pump(until: { fake.calls.count == 2 && fake.blocked == 1 }, "unblock: follow-up slice 2 starts")
        fake.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { fake.calls.count == 3 && fake.blocked == 1 }, "unblock: finalization slice restores CNMI=2,1")
        fake.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { c.running == nil && alerts.count == 1 }, "unblock: finishes and posts alert")
        check(c.result == "Unblocked incoming messages: stored 2 part(s) (1 MMS notification)." && !c.resultIsFailure,
              "unblock: result banner sentence", c.result)
        check(alerts == [.summary(unread: 2)], "unblock: unread count updated after automatic unblock", "\(alerts)")

        // Pulse commands include AT+CNMI? when autoUnblock is on, or once on attach when off; CNMI=2,2 heals even when off.
        notifyOn = false
        check(c.pulseCommands(turn: 1) == ["AT+CNMI?"], "unblock: pulse reads AT+CNMI? with autoUnblock on")
        autoOn = false
        check(c.pulseCommands(turn: 1) == [], "unblock: pulse reads nothing with both off")
        c.modemPresent(true)
        check(c.pulseCommands(turn: 1) == ["AT+CNMI?"], "unblock: modem attach checks AT+CNMI? once")
        c.pulseAnswers(.success(["AT+CNMI?": .lines(["+CNMI: 2,2,0,0,0"])]))
        pump(until: { fake.calls.last == .healCnmi && fake.blocked == 1 }, "unblock: crashed CNMI=2,2 triggers healCnmi")
        fake.releaseUnblock(.success(SmsUnblockSlice(restoredCnmi: true)))
        pump(until: { c.running == nil }, "unblock: healCnmi finishes")
        check(c.result == "Restored incoming message storage (AT+CNMI=2,1,0,0,0); no queued messages arrived.",
              "unblock: healed CNMI reported", c.result)

        // Quitting between two slices runs one finalization pass to restore AT+CNMI=2,1,0,0,0 before quitting.
        let fake2 = FakeService()
        var replies2: [Bool] = []
        let c2 = SmsController(service: fake2, replyToQuit: { replies2.append($0) }, requestAttention: {},
                               unblockWindow: 60, slicePause: 5.0, now: { clock })
        c2.unblock()
        pump(until: { fake2.blocked == 1 }, "unblock quit: slice 1 starts")
        fake2.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { fake2.blocked == 0 && c2.running == .unblocking }, "unblock quit: waiting between slices")
        check(c2.quitWhenFinished() == true, "unblock quit: between slices restores CNMI=2,1 before quitting")
        pump(until: { fake2.calls.last == .unblockSlice(start: false, finish: true) && fake2.blocked == 1 },
             "unblock quit: finalization slice starts")
        fake2.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { replies2 == [true] && c2.running == nil }, "unblock quit: replies true after CNMI=2,1 restored")

        // Quitting during an in-flight slice finishes that slice, restores CNMI=2,1, and quits.
        let fake3 = FakeService()
        var replies3: [Bool] = []
        let c3 = SmsController(service: fake3, replyToQuit: { replies3.append($0) }, requestAttention: {},
                               unblockWindow: 60, slicePause: 0.01, now: { clock })
        c3.unblock()
        pump(until: { fake3.blocked == 1 }, "unblock quit in-flight: slice 1 starts")
        check(c3.quitWhenFinished() == true, "unblock quit in-flight: waits for active slice")
        fake3.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { fake3.calls.last == .unblockSlice(start: false, finish: true) && fake3.blocked == 1 },
             "unblock quit in-flight: finalization slice restores CNMI=2,1")
        fake3.releaseUnblock(.success(SmsUnblockSlice()))
        pump(until: { replies3 == [true] }, "unblock quit in-flight: replies true after CNMI=2,1 restored")
        check(fake3.calls == [.unblockSlice(start: true, finish: false), .unblockSlice(start: false, finish: true)],
              "unblock quit in-flight: no listening slice started after quit")
    }
}
