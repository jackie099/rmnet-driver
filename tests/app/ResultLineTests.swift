// Tests for app/ResultLine.swift on a fake clock: a success goes 8 s after it is shown, not while the pointer is on its
// banner (then 3 s after it leaves); a request's words, a warning and a failure never go by themselves; a new line
// replaces the old one, and the old one's time no longer counts. Built with swiftc by `make app-test`; no AppKit.
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

/// Timers that run when the test moves the time on.
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

/// A controller's line, as the controllers keep it.
final class Line {
    let clock = FakeClock()
    var text = ""
    lazy var expiry = ResultExpiry(after: clock.after, clear: { [unowned self] in self.show("", .success) })

    func show(_ t: String, _ kind: ResultKind) {
        text = t
        expiry.shown(t, kind)
    }
}

@main
struct ResultLineTests {
    static func main() {
        equal(ResultExpiry.successLifetime, 8, "a success's time: 8 s")

        // A success goes after 8 s.
        let s = Line()
        s.show("Sent to +12025550100 in 1 part(s).", .success)
        s.clock.advance(7.9)
        equal(s.text, "Sent to +12025550100 in 1 part(s).", "success: still there at 7.9 s")
        s.clock.advance(0.1)
        equal(s.text, "", "success: gone at 8 s")

        // A failure, a warning and a request's words stay.
        for kind in [ResultKind.failure, .warning, .progress] {
            let l = Line()
            l.show("Made-up line", kind)
            l.clock.advance(3600)
            equal(l.text, "Made-up line", "\(kind): stays")
        }

        // A new line replaces the old one; the old one's time does not cut the new one short.
        let r = Line()
        r.show("First", .success)
        r.clock.advance(5)
        r.show("Second", .success)
        r.clock.advance(4)
        equal(r.text, "Second", "replaced: the first one's time does not count")
        r.clock.advance(4)
        equal(r.text, "", "replaced: the second goes 8 s after it was shown")
        // A success replaced by a failure: the failure stays.
        r.show("Done", .success)
        r.clock.advance(2)
        r.show("Refused", .failure)
        r.clock.advance(60)
        equal(r.text, "Refused", "replaced by a failure: it stays")
        // A request's words, then its success: 8 s from the success.
        r.show("Sending…", .progress)
        r.clock.advance(30)
        r.show("Sent.", .success)
        r.clock.advance(7)
        equal(r.text, "Sent.", "after progress: the success's own 8 s")
        r.clock.advance(1)
        equal(r.text, "", "after progress: gone")

        // Under the pointer: it stays; 3 s after the pointer leaves, it goes.
        let h = Line()
        h.show("Done", .success)
        h.clock.advance(2)
        h.expiry.hover(true)
        h.clock.advance(20)
        equal(h.text, "Done", "hover: stays while the pointer is on it")
        h.expiry.hover(false)
        h.clock.advance(2.9)
        equal(h.text, "Done", "hover: not at once when the pointer leaves")
        h.clock.advance(0.1)
        equal(h.text, "", "hover: gone 3 s after the pointer left")
        // The pointer on and off before the 8 s: the 8 s still count.
        let q = Line()
        q.show("Done", .success)
        q.expiry.hover(true)
        q.clock.advance(1)
        q.expiry.hover(false)
        q.clock.advance(7)
        equal(q.text, "", "hover: on and off early, gone at 8 s")
        // A new line while the pointer is on the old one: it starts its own 8 s.
        let n = Line()
        n.show("Done", .success)
        n.expiry.hover(true)
        n.clock.advance(10)
        n.show("Done again", .success)
        n.expiry.hover(false)
        n.clock.advance(7)
        equal(n.text, "Done again", "hover: a new line has its own 8 s")
        n.clock.advance(1)
        equal(n.text, "", "hover: then goes")

        // Nothing to clear: an empty line starts nothing.
        let e = Line()
        e.show("", .success)
        e.clock.advance(100)
        equal(e.text, "", "empty: nothing")
        print("result line: \(checks) checks passed")
    }
}
