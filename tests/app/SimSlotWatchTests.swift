// Tests for app/SimSlotWatch.swift and app/AppSettings.swift: when the other SIM slot is tried (no usable SIM in the slot
// in use for 25 s without a break, the radio on), when not (a SIM there, busy, the radio off, the setting off, no modem,
// a read missing or too late: the wait starts again), what follows a switch (staying, switching back once, or nothing
// when the port that writes found otherwise), the lines it leaves, never switching back and forth within one attach, a
// switch that did not start or was cancelled, and the watcher's commands, answers, attaches and expectations; then the
// settings' defaults and keeping.
// Built with swiftc by `make app-test` from app/ModemNetwork.swift, app/ModemSettings.swift, app/SimSlotWatch.swift,
// app/AppSettings.swift and this file; no AppKit, no modem.
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

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

/// A switch to `to` that read `sim` in the new slot.
func switched(_ from: Int, _ to: Int, _ sim: SimState?) -> Result<SimSlotChange, ModemFailure> {
    .success(SimSlotChange(before: from, after: to, sim: sim))
}

@main
struct SimSlotWatchTests {
    static func main() {
        waiting()
        notWhen()
        afterTheSwitch()
        backAndForth()
        notStarted()
        breaks()
        skipped()
        watcher()
        watcherBreaksAndCancels()
        notKnownYet()
        watcherNotKnownYet()
        settings()
        print("SIM slot watch: \(checks) checks passed")
    }

    // No usable SIM for 25 s with the radio on: the other slot.
    static func waiting() {
        var w = SimSlotWatch()
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true), .none, "idle: no modem, nothing")
        check(!w.wantsReads, "idle: no reads wanted")
        w.attached()
        check(w.wantsReads, "attached: reads wanted")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true), .none, "first empty read")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(15), enabled: true), .none, "15 s: not yet")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(24.9), enabled: true), .none, "24.9 s: not yet")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true), .switchSlot(2), "25 s: slot 2")
        equal(w.phase, .switching(from: 1, to: 2, reason: .notInserted), "switching")
        check(!w.wantsReads, "switching: no reads")

        // SIM failure (CME 13) counts too, from slot 2 to slot 1.
        var f = SimSlotWatch()
        f.attached()
        _ = f.read(sim: .failure, radio: .on, slot: 2, at: at(0), enabled: true)
        equal(f.read(sim: .failure, radio: .on, slot: 2, at: at(30), enabled: true), .switchSlot(1), "SIM failure: slot 1")
    }

    // A SIM there, busy, the radio off, a part not read, the setting off: no switch (or the wait starts again).
    static func notWhen() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .busy, radio: .on, slot: 1, at: at(10), enabled: true)
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(26), enabled: true), .none, "busy started the wait again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(51), enabled: true), .switchSlot(2), "25 s after busy")

        var r = SimSlotWatch()
        r.attached()
        _ = r.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = r.read(sim: .failure, radio: .minimum, slot: 1, at: at(20), enabled: true)
        equal(r.read(sim: .notInserted, radio: .on, slot: 1, at: at(30), enabled: true), .none,
              "minimum functionality (the SIM powered down) started the wait again")
        _ = r.read(sim: .notInserted, radio: .airplane, slot: 1, at: at(60), enabled: true)
        equal(r.phase, .watching, "airplane mode: no verdict")

        var ready = SimSlotWatch()
        ready.attached()
        _ = ready.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = ready.read(sim: .ready, radio: .on, slot: 1, at: at(5), enabled: true)
        equal(ready.phase, .idle, "ready: settled")
        equal(ready.read(sim: .notInserted, radio: .on, slot: 1, at: at(60), enabled: true), .none, "settled: nothing more")
        var pin = SimSlotWatch()
        pin.attached()
        _ = pin.read(sim: .pin, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(pin.phase, .idle, "asking for its PIN: a SIM is there")

        // Each part not read, and another answer, is a break: the wait starts again at the next "unusable".
        for (name, sim, radio, slot) in [("radio not read", SimState.notInserted, RadioState?.none, Int?.some(1)),
                                         ("slot not read", .notInserted, .on, nil),
                                         ("SIM not read", nil, .on, 1),
                                         ("another answer", .other("+CME ERROR: 3"), .on, 1)] as [(String, SimState?, RadioState?, Int?)] {
            var unread = SimSlotWatch()
            unread.attached()
            _ = unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
            _ = unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(15), enabled: true)
            equal(unread.read(sim: sim, radio: radio, slot: slot, at: at(30), enabled: true), .none, "\(name): no verdict")
            equal(unread.phase, .watching, "\(name): watching again")
            equal(unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(34), enabled: true), .none,
                  "\(name): the wait starts again")
            equal(unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(45), enabled: true), .none, "\(name): 11 s")
            equal(unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(59), enabled: true), .switchSlot(2),
                  "\(name): 25 s after the break")
        }

        var off = SimSlotWatch()
        off.attached()
        for t in stride(from: 0.0, through: 60, by: 15) {
            equal(off.read(sim: .notInserted, radio: .on, slot: 1, at: at(t), enabled: false), .none, "setting off: no switch")
        }
        equal(off.read(sim: .notInserted, radio: .on, slot: 1, at: at(61), enabled: true), .switchSlot(2),
              "setting turned on: switches at the next read")

        // Another slot reported (switched elsewhere) starts the wait again.
        var moved = SimSlotWatch()
        moved.attached()
        _ = moved.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(moved.read(sim: .notInserted, radio: .on, slot: 2, at: at(30), enabled: true), .none, "slot changed: wait again")
    }

    // The new slot has a SIM: stay, with a line. Neither has: switch back once, with a line.
    static func afterTheSwitch() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let ok = w.switched(switched(1, 2, .ready))
        equal(ok.action, .none, "ready in slot 2: stays")
        equal(ok.line, "Switched to SIM 2: no SIM in slot 1.", "ready in slot 2: the line")
        equal(w.phase, .idle, "ready in slot 2: settled")

        var p = SimSlotWatch()
        p.attached()
        _ = p.read(sim: .failure, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = p.read(sim: .failure, radio: .on, slot: 1, at: at(25), enabled: true)
        equal(p.switched(switched(1, 2, .pin)).line, "Switched to SIM 2: SIM failure in slot 1.", "a PIN in slot 2: stays")

        var n = SimSlotWatch()
        n.attached()
        _ = n.read(sim: .notInserted, radio: .on, slot: 2, at: at(0), enabled: true)
        _ = n.read(sim: .notInserted, radio: .on, slot: 2, at: at(25), enabled: true)
        let back = n.switched(switched(2, 1, .notInserted))
        equal(back.action, .switchSlot(2), "nothing in slot 1 either: back to slot 2")
        equal(back.line, nil, "no line before the switch back")
        let done = n.switched(switched(1, 2, .notInserted))
        equal(done.action, .none, "back: no more switches")
        equal(done.line, "No SIM in either slot.", "back: the line")
        equal(n.phase, .idle, "back: settled")

        var u = SimSlotWatch()
        u.attached()
        _ = u.read(sim: .failure, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = u.read(sim: .failure, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = u.switched(switched(1, 2, .notInserted))
        equal(u.switched(switched(2, 1, .failure)).line, "No usable SIM in either slot.", "a failure and none: the line")

        var e = SimSlotWatch()
        e.attached()
        _ = e.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = e.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let failed = e.switched(.failure(ModemFailure(message: "The SIM slot was not changed. ERROR")))
        equal(failed.line, "No SIM in slot 1; could not switch to SIM 2.", "the switch failed: the line")
        equal(e.phase, .idle, "the switch failed: no second try")

        var b = SimSlotWatch()
        b.attached()
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = b.switched(switched(1, 2, .notInserted))
        equal(b.switched(.failure(ModemFailure(message: "busy"))).line,
              "No SIM in slot 2 either; could not switch back to SIM 1.", "the switch back failed: the line")

        var s = SimSlotWatch()
        s.attached()
        _ = s.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = s.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let same = s.switched(.success(SimSlotChange(before: 2, after: 2)))
        check(same.action == .none && same.line == nil && s.phase == .idle, "switched elsewhere meanwhile: nothing")
    }

    // Within one attach: one try, one switch back, then nothing, whatever the reads say; a new attach watches again.
    static func backAndForth() {
        var w = SimSlotWatch()
        w.attached()
        var switches = 0
        var slot = 1
        var time: TimeInterval = 0
        for _ in 0..<40 {
            if case .switchSlot(let to) = w.read(sim: .notInserted, radio: .on, slot: slot, at: at(time), enabled: true) {
                switches += 1
                var next = w.switched(switched(slot, to, .notInserted))
                slot = to
                while case .switchSlot(let back) = next.action {
                    switches += 1
                    next = w.switched(switched(slot, back, .notInserted))
                    slot = back
                }
            }
            time += 15
        }
        equal(switches, 2, "ten minutes of empty slots: one try and one switch back")
        equal(slot, 1, "back on the slot it started on")
        w.attached()
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(1000), enabled: true), .none, "a new attach: wait again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(1025), enabled: true), .switchSlot(2),
              "a new attach: one try again")
    }

    // A switch that did not start: the try did not happen (watch again); a switch back is asked again.
    static func notStarted() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        w.notStarted()
        equal(w.phase, .watching, "the try did not start: watching again")
        equal(w.retryAction, .none, "no retry of a try")

        var b = SimSlotWatch()
        b.attached()
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = b.switched(switched(1, 2, .notInserted))
        b.notStarted()
        equal(b.retryAction, .switchSlot(1), "the switch back did not start: asked again")
        b.stop()
        equal(b.retryAction, .none, "stopped: nothing")
    }

    // Breaks in "no usable SIM": a turn without a read, or one too long after the last (the Mac slept, turns skipped).
    static func breaks() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(15), enabled: true)
        w.missed()
        equal(w.phase, .watching, "missed: watching again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(30), enabled: true), .none, "missed: the wait starts again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(45), enabled: true), .none, "missed: 15 s")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(55), enabled: true), .switchSlot(2), "missed: 25 s after")

        var gap = SimSlotWatch()
        gap.attached()
        _ = gap.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(gap.read(sim: .notInserted, radio: .on, slot: 1, at: at(41), enabled: true), .none,
              "gap: 41 s without a read is a break")
        equal(gap.phase, .unusable(since: at(41), slot: 1, state: .notInserted), "gap: the wait starts at the late read")
        equal(gap.read(sim: .notInserted, radio: .on, slot: 1, at: at(66), enabled: true), .switchSlot(2), "gap: 25 s later")

        var exact = SimSlotWatch()
        exact.attached()
        _ = exact.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(exact.read(sim: .notInserted, radio: .on, slot: 1, at: at(40), enabled: true), .switchSlot(2),
              "gap: 40 s is still two turns")

        var back = SimSlotWatch()
        back.attached()
        _ = back.read(sim: .notInserted, radio: .on, slot: 1, at: at(100), enabled: true)
        equal(back.read(sim: .notInserted, radio: .on, slot: 1, at: at(130), enabled: true), .switchSlot(2), "clock: forward")
        var setBack = SimSlotWatch()
        setBack.attached()
        _ = setBack.read(sim: .notInserted, radio: .on, slot: 1, at: at(100), enabled: true)
        equal(setBack.read(sim: .notInserted, radio: .on, slot: 1, at: at(70), enabled: true), .none,
              "clock: set back is a break")

        var idle = SimSlotWatch()
        idle.missed()
        equal(idle.phase, .idle, "missed: nothing while it does not watch")
    }

    // The port that writes found otherwise (SimSlotSkip): the radio off or a SIM there by then: watch again; another
    // module or slot: nothing more. A switch back not made: no line.
    static func skipped() {
        func trying() -> SimSlotWatch {
            var w = SimSlotWatch()
            w.attached()
            _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
            _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
            return w
        }
        for (skip, phase) in [(SimSlotSkip.radioNotOn, SimSlotWatch.Phase.watching), (.simUsable, .watching),
                              (.simUnknown, .watching), (.moduleUnknown, .watching),
                              (.otherModule, .idle), (.otherSlot, .idle)] {
            var w = trying()
            let next = w.switched(.success(SimSlotChange(before: 1, after: 1, skipped: skip)))
            check(next.action == .none && next.line == nil, "skipped \(skip): no switch, no line")
            equal(w.phase, phase, "skipped \(skip): phase")
        }
        var b = trying()
        _ = b.switched(switched(1, 2, .notInserted))
        let notBack = b.switched(.success(SimSlotChange(before: 1, after: 1, skipped: .otherSlot)))
        check(notBack.action == .none && notBack.line == nil, "switch back not made: no line")
        equal(b.phase, .idle, "switch back not made: settled")
        var e = trying()
        _ = e.switched(switched(1, 2, .notInserted))
        equal(e.retryExpectation(module: "c0ffee01"), SimSlotExpectation(module: "c0ffee01", slot: 2, unusableSim: true),
              "the switch back's expectation: the module, on the slot tried")
        var none = SimSlotWatch()
        check(none.retryExpectation(module: nil) == nil, "no switch back: no expectation")
        none.attached()
    }

    // The watcher: its commands while it watches, the answers turned into a switch, the attaches, a switch by hand.
    static func watcher() {
        var clock = at(0)
        var enabled = true
        var asked: [Int] = []
        var expectations: [SimSlotExpectation] = []
        var pending: [(SimSlotOutcome) -> Int?] = []
        var accept = true
        let w = SimSlotWatcher(enabled: { enabled }, module: { "c0ffee01" }, switchSlot: { slot, expect, done in
            guard accept else { return false }
            asked.append(slot)
            expectations.append(expect)
            pending.append(done)
            return true
        }, now: { clock })
        // The controller's part: the outcome to the watcher; a slot it hands back is switched to at once, as part of the
        // same change (asked, and answered later through the same completion).
        func finish(_ outcome: Result<SimSlotChange, ModemFailure>) {
            let done = pending.removeFirst()
            if let back = done(.finished(outcome)) {
                asked.append(back)
                pending.insert(done, at: 0)
            }
        }
        func answers(_ cpin: PulseAnswer, cfun: String = "+CFUN: 1", slot: Int = 1) -> Result<[String: PulseAnswer], ModemFailure> {
            .success(["AT+CPIN?": cpin, "AT+CFUN?": .lines([cfun]), "AT+QUIMSLOT?": .lines(["+QUIMSLOT: \(slot)"])])
        }
        let empty = PulseAnswer.refused("+CME ERROR: 10")

        equal(w.pulseCommands(), [], "watcher: no modem, no commands")
        w.modemPresent(true)
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: attached, the three reads")
        w.pulseAnswers(answers(empty))
        clock = at(15)
        w.pulseAnswers(.failure(ModemFailure(message: "The modem's AT port is busy.")))
        check(asked.isEmpty, "watcher: a busy turn decides nothing")
        w.pulseAnswers(answers(empty))
        clock = at(30)
        w.pulseAnswers(answers(empty))
        check(asked.isEmpty, "watcher: a busy turn was a break: 15 s since")
        clock = at(40)
        w.pulseAnswers(answers(empty))
        equal(asked, [2], "watcher: switches to slot 2, 25 s after the break")
        equal(expectations, [SimSlotExpectation(module: "c0ffee01", slot: 1)],
              "watcher: expects the module that attached, on slot 1, the radio on and the SIM unusable")
        equal(w.pulseCommands(), [], "watcher: no reads while it switches")
        check(w.switchRunning, "watcher: a switch runs")
        finish(switched(1, 2, .ready))
        equal(w.line, "Switched to SIM 2: no SIM in slot 1.", "watcher: the line")
        equal(w.lineAt, at(40), "watcher: when")
        check(!w.switchRunning, "watcher: the switch has finished")
        equal(w.pulseCommands(), [], "watcher: settled, no reads")

        // Still present: no new watch. Gone and back: a new one.
        w.modemPresent(true)
        equal(w.pulseCommands(), [], "watcher: still present, nothing new")
        w.modemPresent(false)
        w.modemPresent(true)
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: attached again, reads again")

        // Neither slot: the switch back follows by itself.
        asked = []
        clock = at(100)
        w.pulseAnswers(answers(empty))
        clock = at(130)
        w.pulseAnswers(answers(empty))
        equal(asked, [2], "watcher: tries slot 2")
        finish(switched(1, 2, .notInserted))
        equal(asked, [2, 1], "watcher: and back to slot 1, as part of the same change")
        check(w.switchRunning && w.line == "Switched to SIM 2: no SIM in slot 1.",
              "watcher: still running, no new line yet")
        finish(switched(2, 1, .notInserted))
        equal(w.line, "No SIM in either slot.", "watcher: neither slot")
        check(!w.switchRunning, "watcher: both finished")

        // A switch back that was cancelled (dropped before it ran) is asked again on the next turn, with its expectation.
        w.modemPresent(false)
        w.modemPresent(true)
        asked = []
        expectations = []
        clock = at(200)
        w.pulseAnswers(answers(empty))
        clock = at(230)
        w.pulseAnswers(answers(empty))
        finish(switched(1, 2, .notInserted))
        equal(asked, [2, 1], "watcher: the switch back handed to the controller")
        _ = pending.removeFirst()(.cancelled)
        check(!w.switchRunning, "watcher: a cancelled switch back frees the watcher")
        _ = w.pulseCommands()
        equal(asked, [2, 1, 1], "watcher: the switch back asked again on the next turn")
        equal(expectations.last, SimSlotExpectation(module: "c0ffee01", slot: 2, unusableSim: true),
              "watcher: asked again with the module, on the slot tried")
        finish(switched(2, 1, .notInserted))

        // A switch by hand stops the watch; the setting off never switches.
        w.modemPresent(false)
        w.modemPresent(true)
        w.switchedByHand()
        equal(w.pulseCommands(), [], "watcher: switched by hand, nothing more")
        w.modemPresent(false)
        w.modemPresent(true)
        enabled = false
        asked = []
        clock = at(300)
        w.pulseAnswers(answers(empty))
        clock = at(330)
        w.pulseAnswers(answers(empty))
        check(asked.isEmpty, "watcher: the setting off, no switch")
        accept = false
        enabled = true
        clock = at(340)
        w.pulseAnswers(answers(empty))
        check(asked.isEmpty && !w.switchRunning, "watcher: a switch that did not start leaves it free")
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: and watching again")
    }

    // The watcher and breaks: a turn with a command missing (not read in time) starts the wait again; a try that was
    // cancelled (dropped when the app began to quit, the quit then cancelled) frees it, and it watches again.
    static func watcherBreaksAndCancels() {
        var clock = at(0)
        var asked: [Int] = []
        var pending: [(SimSlotOutcome) -> Int?] = []
        let w = SimSlotWatcher(enabled: { true }, switchSlot: { slot, _, done in
            asked.append(slot)
            pending.append(done)
            return true
        }, now: { clock })
        let empty = PulseAnswer.refused("+CME ERROR: 10")
        let full: [String: PulseAnswer] = ["AT+CPIN?": empty, "AT+CFUN?": .lines(["+CFUN: 1"]),
                                           "AT+QUIMSLOT?": .lines(["+QUIMSLOT: 1"])]
        w.modemPresent(true)
        w.pulseAnswers(.success(full))
        clock = at(15)
        var partial = full
        partial["AT+QUIMSLOT?"] = nil      // the turn's last read timed out: not in the answers
        w.pulseAnswers(.success(partial))
        clock = at(30)
        w.pulseAnswers(.success(full))
        check(asked.isEmpty, "watcher: a command missing is a break")
        clock = at(55)
        w.pulseAnswers(.success(full))
        equal(asked, [2], "watcher: 25 s after the break")

        _ = pending.removeFirst()(.cancelled)
        check(!w.switchRunning, "watcher: a cancelled try frees it")
        equal(w.phase, .watching, "watcher: and it watches again")
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: reads again")
        clock = at(70)
        w.pulseAnswers(.success(full))
        clock = at(95)
        w.pulseAnswers(.success(full))
        equal(asked, [2, 2], "watcher: tries again after the patience")
    }

    // Nothing concluded from what is not known: the SIM of the slot tried not told after the switch (not read, busy)
    // is read on later turns; a switch back whose slot tried has a usable SIM by then is not made; one not made because
    // the radio, the SIM or the module was not known is tried again.
    static func notKnownYet() {
        func trying(_ slot: Int = 1) -> SimSlotWatch {
            var w = SimSlotWatch()
            w.attached()
            _ = w.read(sim: .notInserted, radio: .on, slot: slot, at: at(0), enabled: true)
            _ = w.read(sim: .notInserted, radio: .on, slot: slot, at: at(25), enabled: true)
            return w
        }
        for (sim, name) in [(SimState?.none, "not read"), (.busy, "busy"), (.other("+CME ERROR: 3"), "another answer")] {
            var w = trying()
            let next = w.switched(switched(1, 2, sim))
            check(next.action == .none && next.line == nil, "tried, SIM \(name): nothing concluded, no line")
            equal(w.phase, .verifying(from: 1, to: 2, reason: .notInserted), "tried, SIM \(name): read again")
            check(w.wantsReads, "tried, SIM \(name): reads wanted")
        }
        // Verifying: not read, the radio off, busy, a turn missed: still verifying; then ready: the switch stands.
        var v = trying()
        _ = v.switched(switched(1, 2, nil))
        equal(v.read(sim: nil, radio: .on, slot: 2, at: at(40), enabled: true), .none, "verifying: SIM not read")
        equal(v.read(sim: .notInserted, radio: .airplane, slot: 2, at: at(55), enabled: true), .none,
              "verifying: the radio not on")
        equal(v.read(sim: .busy, radio: .on, slot: 2, at: at(70), enabled: true), .none, "verifying: busy")
        v.missed()
        equal(v.phase, .verifying(from: 1, to: 2, reason: .notInserted), "verifying: a missed turn concludes nothing")
        equal(v.read(sim: .ready, radio: .on, slot: 2, at: at(85), enabled: true),
              .say("Switched to SIM 2: no SIM in slot 1."), "verifying: ready, the switch stands")
        equal(v.phase, .idle, "verifying: settled")
        // Verifying, then no SIM there either: back, with the slot tried's expectation.
        var n = trying()
        _ = n.switched(switched(1, 2, .busy))
        equal(n.read(sim: .notInserted, radio: .on, slot: 2, at: at(40), enabled: true), .switchSlot(1),
              "verifying: no SIM there either, back")
        equal(n.phase, .switchingBack(original: 1, tried: 2, reason: .notInserted, triedState: .notInserted),
              "verifying: switching back")
        equal(n.retryExpectation(module: "TESTMODULE1"), SimSlotExpectation(module: "TESTMODULE1", slot: 2),
              "verifying: the switch back checks the slot tried")
        // Verifying, switched elsewhere meanwhile: nothing more.
        var e = trying()
        _ = e.switched(switched(1, 2, nil))
        equal(e.read(sim: .ready, radio: .on, slot: 1, at: at(40), enabled: true), .none, "verifying: another slot")
        equal(e.phase, .idle, "verifying: another slot, settled")

        // The switch back: the slot tried has a usable SIM by then (it was slow): kept, and said.
        var r = trying()
        _ = r.switched(switched(1, 2, .notInserted))
        let kept = r.switched(.success(SimSlotChange(before: 2, after: 2, skipped: .simUsable)))
        check(kept.action == .none && kept.line == "Switched to SIM 2: no SIM in slot 1.", "back: SIM ready there, kept",
              "\(kept)")
        equal(r.phase, .idle, "back: kept, settled")
        // Not known yet (the radio, the SIM, the module): tried again on the next turn.
        for skip in [SimSlotSkip.radioNotOn, .simUnknown, .moduleUnknown] {
            var p = trying()
            _ = p.switched(switched(1, 2, .notInserted))
            let next = p.switched(.success(SimSlotChange(before: 2, after: 2, skipped: skip)))
            check(next.action == .none && next.line == nil, "back, \(skip): nothing concluded")
            equal(p.retryAction, .switchSlot(1), "back, \(skip): tried again")
            equal(p.retryExpectation(module: "TESTMODULE1"), SimSlotExpectation(module: "TESTMODULE1", slot: 2),
                  "back, \(skip): with the same checks")
        }
    }

    // The watcher: a module not known when it attached is read again before a switch, and one still not known is
    // passed as not known (the port then refuses it); a slot tried whose SIM was not told is read until it is; a switch
    // back whose radio was not on is tried again on the next turn.
    static func watcherNotKnownYet() {
        var clock = at(0)
        var serial: String? = nil
        var expectations: [SimSlotExpectation] = []
        var pending: [(SimSlotOutcome) -> Int?] = []
        let w = SimSlotWatcher(enabled: { true }, module: { serial }, switchSlot: { slot, expect, done in
            expectations.append(expect)
            pending.append(done)
            return true
        }, now: { clock })
        func answers(_ cpin: PulseAnswer, slot: Int) -> Result<[String: PulseAnswer], ModemFailure> {
            .success(["AT+CPIN?": cpin, "AT+CFUN?": .lines(["+CFUN: 1"]), "AT+QUIMSLOT?": .lines(["+QUIMSLOT: \(slot)"])])
        }
        let empty = PulseAnswer.refused("+CME ERROR: 10")
        w.modemPresent(true)                       // no serial number known yet
        w.pulseAnswers(answers(empty, slot: 1))
        clock = at(25)
        w.pulseAnswers(answers(empty, slot: 1))
        equal(expectations.last, SimSlotExpectation(module: nil, slot: 1), "watcher: module still not known, passed so")
        _ = pending.removeFirst()(.finished(.success(SimSlotChange(before: 1, after: 1, skipped: .moduleUnknown))))
        check(!w.switchRunning && w.phase == .watching, "watcher: not known, watching again")
        serial = "TESTMODULE1"                     // known by now
        clock = at(40)
        w.pulseAnswers(answers(empty, slot: 1))
        clock = at(65)
        w.pulseAnswers(answers(empty, slot: 1))
        equal(expectations.last, SimSlotExpectation(module: "TESTMODULE1", slot: 1), "watcher: the module read again")

        // Switched; the SIM of slot 2 not told: read on later turns, then none there either: back, checked on slot 2.
        _ = pending.removeFirst()(.finished(.success(SimSlotChange(before: 1, after: 2, sim: .busy))))
        check(!w.switchRunning, "watcher: verifying, nothing running")
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: verifying, reads the slot tried")
        clock = at(80)
        w.pulseAnswers(answers(.refused("+CME ERROR: 14"), slot: 2))
        equal(expectations.count, 2, "watcher: busy, nothing yet")
        clock = at(95)
        w.pulseAnswers(answers(empty, slot: 2))
        equal(expectations.last, SimSlotExpectation(module: "TESTMODULE1", slot: 2), "watcher: back, checked on slot 2")
        // The radio was not on when the switch back checked: tried again on the next turn.
        _ = pending.removeFirst()(.finished(.success(SimSlotChange(before: 2, after: 2, skipped: .radioNotOn))))
        check(!w.switchRunning, "watcher: the switch back not made yet")
        _ = w.pulseCommands()
        equal(expectations.count, 4, "watcher: the switch back asked again on the next turn")
        _ = pending.removeFirst()(.finished(.success(SimSlotChange(before: 2, after: 1, sim: .notInserted))))
        equal(w.line, "No SIM in either slot.", "watcher: then made")
        equal(w.phase, .idle, "watcher: settled")
    }

    // The settings: on by default, kept, read back.
    static func settings() {
        let suite = "io.rmnetdriver.RMNet.tests.settings.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        check(s.simAutoSwitch && s.notifyMessages && s.smsAutoUnblock, "settings: on by default")
        s.simAutoSwitch = false
        s.notifyMessages = false
        s.smsAutoUnblock = false
        equal(defaults.object(forKey: "simAutoSwitch") as? Bool, false, "settings: kept under simAutoSwitch")
        equal(defaults.object(forKey: "notifyNewMessages") as? Bool, false, "settings: kept under notifyNewMessages")
        equal(defaults.object(forKey: "smsAutoUnblock") as? Bool, false, "settings: kept under smsAutoUnblock")
        let again = AppSettings(defaults: defaults)
        check(!again.simAutoSwitch && !again.notifyMessages && !again.smsAutoUnblock, "settings: read back")
        defaults.set("yes", forKey: "notifyNewMessages")
        defaults.set("yes", forKey: "smsAutoUnblock")
        check(AppSettings(defaults: defaults).notifyMessages && AppSettings(defaults: defaults).smsAutoUnblock,
              "settings: a value not a Bool is on")
    }
}
