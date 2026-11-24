// A screen's result line, the banner at its bottom (DesignKit's resultBanner): what kind of line it is, and how long it
// stays. The line is the controller's (Messages: SmsController; Network and SIM & Data: ModemController; Driver:
// StatusController), so dismissing it clears it there: it does not come back when another screen is shown or the window
// is closed and opened again. A success goes by itself 8 s after it is shown, but not while the pointer is on its
// banner (then 3 s after the pointer leaves it); a request's words while it runs, a warning (a success with something
// to read) and a failure stay until they are dismissed or the next result replaces them. Foundation only
// (tests/app/ResultLineTests.swift, and the controllers' tests).
import Foundation

/// What a result line tells: a request that runs, one that succeeded, one that succeeded with something to read, or
/// one that failed.
enum ResultKind: Equatable {
    case progress
    case success
    case warning
    case failure
}

/// When a controller's result line goes by itself. The controller tells it each line it shows (`shown`, "" for none)
/// and where the pointer is (`hover`); it calls `clear` when a success has had its time. Its timers come from `after`:
/// the main run loop's (mainRunLoopAfter), or a fake clock in the tests.
final class ResultExpiry {
    static let successLifetime: TimeInterval = 8   // a success, from when it is shown
    static let afterHover: TimeInterval = 3        // a success whose time ran out under the pointer, after it leaves

    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let clear: () -> Void
    private var generation = 0      // the line shown; a timer of an earlier one does nothing
    private var hovering = false
    private var due = false         // the success's time ran out while the pointer was on it

    init(after: @escaping (TimeInterval, @escaping () -> Void) -> Void, clear: @escaping () -> Void) {
        self.after = after
        self.clear = clear
    }

    /// A new line: whatever an earlier line waited for no longer counts; a success starts its own time.
    func shown(_ text: String, _ kind: ResultKind) {
        generation += 1
        due = false
        guard !text.isEmpty, kind == .success else { return }
        arm(ResultExpiry.successLifetime)
    }

    /// The pointer came onto the banner (true) or left it (false).
    func hover(_ on: Bool) {
        hovering = on
        if !on, due {
            due = false
            arm(ResultExpiry.afterHover)
        }
    }

    private func arm(_ delay: TimeInterval) {
        let line = generation
        after(delay) { [weak self] in
            guard let self, self.generation == line else { return }
            if self.hovering {
                self.due = true
                return
            }
            self.clear()
        }
    }
}

/// A timer on the main run loop, for ResultExpiry.
func mainRunLoopAfter(_ delay: TimeInterval, _ body: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
}
