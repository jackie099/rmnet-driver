// Switching SIM slots by itself. The RM520N-GL uses one of its two SIM slots at a time (AT+QUIMSLOT, ModemSettings.swift),
// and nothing on this board tells it that a SIM was moved to the other slot: its SIM detection is off. So when a modem
// attaches and the slot in use has no usable SIM, RMNet switches to the other slot; if that one has none either, it
// switches back. At most one try for each attach, so it never switches back and forth.
//
// What counts as "no usable SIM": AT+CPIN? answering `+CME ERROR: 10` (SIM not inserted) or `+CME ERROR: 13` (SIM
// failure), as 3GPP TS 27.007 numbers them (simUnusable), for 25 s without a break, and only while AT+CFUN? says the
// radio is on (1): in minimum functionality (0) the modem powers the SIM down and answers so for a SIM that is there,
// and right after an attach a SIM can answer `+CME ERROR: 14` (busy) or 10 for a few seconds while it starts. A SIM
// that answers READY or asks for its PIN or PUK is there: nothing is done. A break is any read that does not say
// "unusable" with the radio on: a part not read (the port busy, a command that timed out), another answer, or no read
// for longer than two background turns (the Mac slept, a turn was skipped); the 25 s then start again.
//
// The switch itself checks again, on the port that writes AT+QUIMSLOT=, before it writes (SimSlotExpectation): the same
// module (its USB serial number, read when it attached, or read again when it was not known then; a module whose serial
// number is still not known is never switched), still on the slot that was read, the radio on and the SIM still
// unusable; otherwise nothing is written and the watcher starts again or stops (SimSlotSkip). The switch back checks
// the same on the slot it tried, so a SIM that has become ready there meanwhile is kept. When the SIM of the slot tried
// could not be told after the switch (not read, busy), nothing is concluded: the watcher reads it on later turns
// (`verifying`) until it is told. A switch back that is not made because something is not known yet (the radio, the SIM,
// the module) is tried again on the next turn. The switch back is part of the same change as the try
// (ModemController.changeSimSlot), so a quit waits for both and never leaves the modem on the empty slot it tried.
//
// SimSlotWatch is the decision, a value tested by tests/app/SimSlotWatchTests.swift; SimSlotWatcher runs it in the app:
// it reads the SIM in the app's background turn (ModemPulse.swift) while it watches, and switches with the modem
// screens' controller (ModemController.changeSimSlot), on the queue they share. Only the app does this; neither the
// command line nor the driver switches by itself.
import Combine
import Foundation

struct SimSlotWatch: Equatable {
    enum Phase: Equatable {
        case idle                                                // no modem, or this attach is settled
        case watching                                            // a modem attached; no verdict yet
        case unusable(since: Date, slot: Int, state: SimState)   // the slot in use has had no usable SIM since then
        case switching(from: Int, to: Int, reason: SimState)     // trying the other slot
        case verifying(from: Int, to: Int, reason: SimState)     // switched; the SIM of the slot tried not told yet
        case switchingBack(original: Int, tried: Int, reason: SimState, triedState: SimState?)
    }

    enum Action: Equatable { case none, switchSlot(Int), say(String) }

    /// How long the slot in use must have no usable SIM before the other slot is tried.
    static let patience: TimeInterval = 25
    /// The longest time between two reads that still counts as "without a break": two background turns (15 s each,
    /// ModemPulse) and their tolerance.
    static let longestGap: TimeInterval = 40

    private(set) var phase: Phase = .idle
    private var lastRead: Date? = nil   // the last read that said "unusable", while `phase` is .unusable

    /// The watcher wants the SIM read: a modem attached and no verdict yet.
    var wantsReads: Bool {
        switch phase {
        case .watching, .unusable, .verifying: return true
        default: return false
        }
    }

    /// A modem came onto USB (or was there when the app started): watch it afresh.
    mutating func attached() { phase = .watching }

    /// The modem left USB, or the slot was switched in the window: nothing more for this attach.
    mutating func stop() { phase = .idle }

    /// A read of the SIM (AT+CPIN?), the radio (AT+CFUN?) and the slot (AT+QUIMSLOT?) at `at`; a part nil was not read.
    /// With `enabled` off (Settings) it keeps watching but never switches.
    mutating func read(sim: SimState?, radio: RadioState?, slot: Int?, at: Date, enabled: Bool) -> Action {
        guard wantsReads else { return .none }
        if case .verifying(let from, let to, let reason) = phase {
            // The slot tried, until its SIM is told with the radio on: usable, the switch stands; unusable, back.
            guard let sim, let slot, radio == .on else { return .none }
            guard slot == to else {
                phase = .idle                                       // switched elsewhere meanwhile
                return .none
            }
            switch simConclusive(sim) {
            case true?:
                phase = .idle
                return .say(switchedLine(to: to, reason: reason, from: from))
            case false?:
                phase = .switchingBack(original: from, tried: to, reason: reason, triedState: sim)
                return .switchSlot(from)
            case nil:
                return .none
            }
        }
        guard let sim, let slot, let radio else {                   // a part not read: a break, start again
            missed()
            return .none
        }
        guard radio == .on else {
            missed()                                                // the SIM may be powered down: start again
            return .none
        }
        if simUnusable(sim) {
            if case .unusable(let since, let s, _) = phase, s == slot,
               let last = lastRead, at.timeIntervalSince(last) <= SimSlotWatch.longestGap, at >= last {
                lastRead = at
                guard enabled, at.timeIntervalSince(since) >= SimSlotWatch.patience else { return .none }
                let other = otherSimSlot(slot)
                phase = .switching(from: slot, to: other, reason: sim)
                lastRead = nil
                return .switchSlot(other)
            }
            phase = .unusable(since: at, slot: slot, state: sim)    // the first, or after a break: the 25 s start now
            lastRead = at
            return .none
        }
        switch sim {
        case .ready, .pin, .puk, .pin2, .puk2:
            phase = .idle                                           // a SIM is there
            lastRead = nil
        case .busy, .notInserted, .failure, .other:
            missed()                                                // still starting, or another answer: start again
        }
        return .none
    }

    /// A turn without a read (the port busy or not opened, a part not read, the radio not on): a break in "no usable
    /// SIM", which starts the patience again. Nothing while it does not watch.
    mutating func missed() {
        guard wantsReads else { return }
        if case .verifying = phase { return }                       // still not told: keep reading the slot tried
        phase = .watching
        lastRead = nil
    }

    /// The switch asked for did not start (another change ran), or was dropped before it ran (the app began to quit,
    /// and the quit was cancelled): try the other slot again after the patience (the try did not happen), or,
    /// switching back, switch back on the next turn (retryAction).
    mutating func notStarted() {
        if case .switching = phase { phase = .watching }
    }

    /// The expectation of the switch back (retryAction): the module, on the slot tried, still without a usable SIM.
    func retryExpectation(module: String?) -> SimSlotExpectation? {
        if case .switchingBack(_, let tried, _, _) = phase {
            return SimSlotExpectation(module: module, slot: tried, unusableSim: true)
        }
        return nil
    }

    /// The switch back that did not start, asked again.
    var retryAction: Action {
        if case .switchingBack(let original, _, _, _) = phase { return .switchSlot(original) }
        return .none
    }

    /// What came of a switch: the action that follows (the switch back), and the line to show, if any. Something not
    /// known yet (the module, the radio, the SIM) concludes nothing: the try is watched for again, the slot tried read
    /// again (`verifying`), or the switch back tried again on the next turn.
    mutating func switched(_ outcome: Result<SimSlotChange, ModemFailure>) -> (action: Action, line: String?) {
        switch phase {
        case .switching(let from, let to, let reason):
            switch outcome {
            case .failure:
                phase = .idle
                return (.none, "\(reasonWords(reason, slot: from)); could not switch to SIM \(to).")
            case .success(let c) where c.skipped == .otherModule || c.skipped == .otherSlot:
                phase = .idle                                       // another module, or switched elsewhere meanwhile
                return (.none, nil)
            case .success(let c) where c.skipped != nil:
                phase = .watching                                   // not so (or not known) on the port that writes
                return (.none, nil)
            case .success(let c) where !c.changed:
                phase = .idle                                       // on that slot already
                return (.none, nil)
            case .success(let c):
                switch c.sim.flatMap(simConclusive) {
                case false?:
                    phase = .switchingBack(original: from, tried: to, reason: reason, triedState: c.sim)
                    return (.switchSlot(from), nil)
                case true?:
                    phase = .idle
                    return (.none, switchedLine(to: to, reason: reason, from: from))
                case nil:
                    phase = .verifying(from: from, to: to, reason: reason)
                    return (.none, nil)
                }
            }
        case .switchingBack(let original, let tried, let reason, let triedState):
            switch outcome {
            case .failure:
                phase = .idle
                return (.none, "\(reasonWords(triedState ?? .notInserted, slot: tried)) either; could not switch back to SIM \(original).")
            case .success(let c) where c.skipped == .simUsable:
                phase = .idle                                       // the slot tried has a usable SIM by now: kept
                return (.none, switchedLine(to: tried, reason: reason, from: original))
            case .success(let c) where c.skipped == .radioNotOn || c.skipped == .simUnknown || c.skipped == .moduleUnknown:
                return (.none, nil)                                 // not known yet: tried again on the next turn
            case .success(let c) where c.skipped != nil || !c.changed:
                phase = .idle                                       // another slot or module by then: left as it is
                return (.none, nil)
            case .success:
                phase = .idle
                let neither = reason == .notInserted && (triedState ?? .notInserted) == .notInserted
                return (.none, neither ? "No SIM in either slot." : "No usable SIM in either slot.")
            }
        default:
            return (.none, nil)
        }
    }
}

/// "Switched to SIM 2: no SIM in slot 1."
private func switchedLine(to: Int, reason: SimState, from: Int) -> String {
    "Switched to SIM \(to): \(reasonWords(reason, slot: from).lowercasedFirst)."
}

/// "No SIM in slot 1", "SIM failure in slot 1".
private func reasonWords(_ state: SimState, slot: Int) -> String {
    state == .failure ? "SIM failure in slot \(slot)" : "No SIM in slot \(slot)"
}

private extension String {
    /// "No SIM in slot 1" → "no SIM in slot 1"; "SIM failure…" stays.
    var lowercasedFirst: String {
        hasPrefix("SIM") ? self : prefix(1).lowercased() + dropFirst()
    }
}

/// Runs SimSlotWatch in the app: told when a modem comes onto USB or leaves it (the menu bar item's registry polls),
/// it asks for the SIM in the background turn while it watches, and switches with `switchSlot` (the modem screens'
/// controller: one change at a time, the quit waits for it and for its switch back). Its line says what it last did,
/// for the SIM card.
final class SimSlotWatcher: ObservableObject {
    @Published private(set) var line: String? = nil
    @Published private(set) var lineAt: Date? = nil
    @Published private(set) var phase: SimSlotWatch.Phase = .idle

    static let commands = ["AT+CPIN?", "AT+CFUN?", "AT+QUIMSLOT?"]

    private var watch = SimSlotWatch() {
        didSet { if phase != watch.phase { phase = watch.phase } }
    }
    private var present = false
    private(set) var switchRunning = false
    private var attachedModule: String? = nil   // the module's USB serial number when it attached
    private let enabled: () -> Bool
    private let module: () -> String?
    private let switchSlot: (Int, SimSlotExpectation, @escaping (SimSlotOutcome) -> Int?) -> Bool
    private let now: () -> Date

    /// `enabled`: Settings' Switch SIM slots automatically. `module`: the attached module's USB serial number (read
    /// when it attaches; the switch writes only on that one). `switchSlot`: starts a switch with its expectation (false:
    /// it did not start) and calls back on the main thread with its outcome, before a quit that waits is answered; the
    /// slot handed back is switched to at once, as part of the same change (the switch back).
    init(enabled: @escaping () -> Bool,
         module: @escaping () -> String? = { nil },
         switchSlot: @escaping (Int, SimSlotExpectation, @escaping (SimSlotOutcome) -> Int?) -> Bool,
         now: @escaping () -> Date = { Date() }) {
        self.enabled = enabled
        self.module = module
        self.switchSlot = switchSlot
        self.now = now
    }

    /// The slot it is about to try: the slot in use has no usable SIM, and switching by itself is on.
    var aboutToTry: (empty: Int, other: Int)? {
        guard case .unusable(_, let slot, _) = phase, enabled() else { return nil }
        return (slot, otherSimSlot(slot))
    }

    /// The modem is on USB (true) or not: a modem that appears is watched afresh, one that goes is forgotten.
    func modemPresent(_ isPresent: Bool) {
        if isPresent && !present {
            attachedModule = module()
            watch.attached()
        }
        if !isPresent && present { watch.stop() }
        present = isPresent
    }

    /// The slot was switched in the window: nothing more is done for this attach.
    func switchedByHand() {
        if !switchRunning { watch.stop() }
    }

    /// The commands for this background turn: the SIM, the radio and the slot while it watches; none otherwise. A switch
    /// back that could not start is asked again first.
    func pulseCommands() -> [String] {
        if !switchRunning, case .switchSlot(let slot) = watch.retryAction,
           let expect = watch.retryExpectation(module: attachedModule) {
            start(slot, expect: expect)
        }
        return watch.wantsReads && !switchRunning ? SimSlotWatcher.commands : []
    }

    /// The turn's answers (keyed by command; a command missing was not read), or why the port could not be used: the
    /// turn is a break (SimSlotWatch.missed).
    func pulseAnswers(_ answers: Result<[String: PulseAnswer], ModemFailure>) {
        guard case .success(let a) = answers else {
            watch.missed()
            return
        }
        let sim = a["AT+CPIN?"].flatMap(simState)
        let radio = a["AT+CFUN?"].flatMap { parseRadio($0.lines) }
        let slot = a["AT+QUIMSLOT?"].flatMap { parseSimSlot($0.lines) }
        switch watch.read(sim: sim, radio: radio, slot: slot, at: now(), enabled: enabled()) {
        case .switchSlot(let target):
            if case .switching(let from, _, _) = watch.phase {
                start(target, expect: SimSlotExpectation(module: attachedModule, slot: from))
            } else if let expect = watch.retryExpectation(module: attachedModule) {
                start(target, expect: expect)                       // back, from the slot tried (`verifying`)
            }
        case .say(let words):
            line = words
            lineAt = now()
        case .none:
            break
        }
    }

    /// A module whose serial number was not known when it attached is read again first; one still not known is not
    /// switched (the port finds `moduleUnknown`, and the watcher checks again later).
    private func start(_ slot: Int, expect given: SimSlotExpectation) {
        var expect = given
        if expect.module == nil, let read = module() {
            attachedModule = read
            expect = SimSlotExpectation(module: read, slot: given.slot, unusableSim: given.unusableSim)
        }
        switchRunning = true
        let started = switchSlot(slot, expect) { [weak self] outcome in
            guard let self else { return nil }
            switch outcome {
            case .cancelled:
                self.switchRunning = false
                self.watch.notStarted()
                return nil
            case .finished(let result):
                let next = self.watch.switched(result)
                if let line = next.line {
                    self.line = line
                    self.lineAt = self.now()
                }
                // The switch back runs at once, as part of the same change: still running.
                if case .switchSlot(let back) = next.action { return back }
                self.switchRunning = false
                return nil
            }
        }
        if !started {
            switchRunning = false
            watch.notStarted()
        }
    }
}
