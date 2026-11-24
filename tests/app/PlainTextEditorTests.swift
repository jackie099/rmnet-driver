// Tests for app/PlainTextEditor.swift, off screen with AppKit: the reply field of one conversation while an input method
// still composes (marked text, as pinyin before a candidate is chosen) when another conversation is chosen. The field
// that goes commits what it composes to its own conversation's draft and writes nothing after that; the next
// conversation's field and draft are never written by it. Built with swiftc by `make app-test`; no window is shown.
// Stops at the first failure, prints which check failed and exits 1.
import AppKit
import SwiftUI

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

/// The conversations' drafts and the shared `composing`, as SmsController keeps them.
final class Drafts {
    var text: [String: String] = [:]
    var composing = false

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.text[key] ?? "" }, set: { self.text[key] = $0.isEmpty ? nil : $0 })
    }

    var composingBinding: Binding<Bool> { Binding(get: { self.composing }, set: { self.composing = $0 }) }
}

/// A field as PlainTextEditor makes it, for the conversation `key`.
func field(_ key: String, _ drafts: Drafts) -> (scroll: NSScrollView, view: MessageTextView, coordinator: PlainTextEditor.Coordinator) {
    let coordinator = PlainTextEditor.Coordinator(text: drafts.binding(key), composing: drafts.composingBinding)
    let (scroll, view) = PlainTextEditor.makeViews()
    view.string = drafts.text[key] ?? ""
    view.delegate = coordinator
    view.markedTextChanged = { [weak coordinator] v in coordinator?.sync(v) }
    return (scroll, view, coordinator)
}

let nowhere = NSRange(location: NSNotFound, length: 0)

@main
struct PlainTextEditorTests {
    static func main() {
        _ = NSApplication.shared
        let drafts = Drafts()
        drafts.text["B"] = "Made-up draft of B"

        // Typing in A's field: A's draft.
        let a = field("A", drafts)
        a.view.insertText("Made-up ", replacementRange: nowhere)
        equal(drafts.text["A"], "Made-up ", "typed: A's draft")
        // An input method composes (marked text): not committed yet.
        a.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: nowhere)
        check(a.view.hasMarkedText(), "composing: the view has marked text")
        check(drafts.composing, "composing: said")
        equal(drafts.text["A"], "Made-up ", "composing: A's draft keeps the committed text")

        // Another conversation is chosen: A's field goes (SwiftUI dismantles it), B's comes.
        PlainTextEditor.dismantleNSView(a.scroll, coordinator: a.coordinator)
        equal(drafts.text["A"], "Made-up ni", "switch: what was composed is committed to A")
        check(!drafts.composing, "switch: no longer composing")
        let b = field("B", drafts)
        equal(b.view.string, "Made-up draft of B", "switch: B's field shows B's draft")
        equal(drafts.text["B"], "Made-up draft of B", "switch: B's draft untouched")

        // The input method commits late, into the field that went: nothing is written, to A or to B.
        a.view.insertText("hao", replacementRange: nowhere)
        equal(drafts.text["A"], "Made-up ni", "late: A's draft as committed at the switch")
        equal(drafts.text["B"], "Made-up draft of B", "late: never B's")

        // Typing in B's field: B's draft only.
        b.view.insertText(" more", replacementRange: nowhere)
        equal(drafts.text["B"], "Made-up draft of B more", "B: typed")
        equal(drafts.text["A"], "Made-up ni", "B: A untouched")

        // A field that goes with nothing composed: its text as it was, nothing else.
        PlainTextEditor.dismantleNSView(b.scroll, coordinator: b.coordinator)
        equal(drafts.text["B"], "Made-up draft of B more", "B goes: as typed")
        print("reply editor: \(checks) checks passed")
    }
}
