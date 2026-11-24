// A multi-line plain-text field for the message being written: an NSTextView in an NSScrollView with
// every automatic substitution switched off (smart quotes, smart dashes, text replacement, spelling
// correction), so the text sent is exactly what was typed. SwiftUI's TextEditor cannot switch these off
// on macOS, and a curly quote alone would make a message Unicode (70 characters a part instead of 160).
//
// The bound text is always the committed text the view shows. The view is built on TextKit 1 (its own
// text storage, layout manager and container), where every edit, undo and redo included, posts
// textDidChange; TextKit 2 does not post it for undo and redo. Text an input method is still composing
// (marked text: pinyin, dead keys) is not committed: while there is some, the binding keeps the last
// committed text, `composing` is true, and the view is never written to from outside. When the view goes (another
// conversation's field takes its place), text still being composed is committed to its own binding first, and the view
// writes nothing after that: a binding is never written by a field that is gone.
import AppKit
import SwiftUI

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var composing: Bool  // the view has marked text (input not finished)
    var editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, composing: $composing) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = PlainTextEditor.makeViews()
        view.string = text
        view.delegate = context.coordinator
        view.markedTextChanged = { [weak coordinator = context.coordinator] view in coordinator?.sync(view) }
        return scroll
    }

    /// The view goes: what an input method still composes is committed (to this field's binding, the conversation it
    /// was typed in), `composing` ends, and the view is cut from its coordinator, so nothing it does later is written.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? MessageTextView else { return }
        if view.hasMarkedText() { view.unmarkText() }
        coordinator.sync(view)
        if coordinator.composing.wrappedValue { coordinator.composing.wrappedValue = false }
        coordinator.retired = true
        view.delegate = nil
        view.markedTextChanged = nil
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.composing = $composing
        guard let view = scroll.documentView as? MessageTextView else { return }
        PlainTextEditor.show(text, in: view)
        if view.isEditable != editable {
            view.isEditable = editable
            view.textColor = editable ? .textColor : .disabledControlTextColor
        }
    }

    /// The scroll view and the TextKit 1 text view in it, wrapping at the view's width.
    static func makeViews() -> (NSScrollView, MessageTextView) {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = MessageTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]

        view.isRichText = false                     // plain text: pasted fonts and colours are dropped
        view.importsGraphics = false                // no pasted or dropped images
        view.allowsImageEditing = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.allowsUndo = true
        view.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .textColor
        scroll.documentView = view
        return (scroll, view)
    }

    /// Writes `text` into the view when it changed from outside (the field cleared after a send). Never
    /// while an input method is composing, and never when the view already shows it. The selection stays
    /// inside the new text, and the view's undo actions go: they describe text that is no longer there.
    static func show(_ text: String, in view: NSTextView) {
        guard !view.hasMarkedText(), view.string != text else { return }
        let caret = view.selectedRange().location
        view.string = text
        view.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        if let storage = view.textStorage { view.undoManager?.removeAllActions(withTarget: storage) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var composing: Binding<Bool>
        var retired = false   // its view is gone: nothing more is written

        init(text: Binding<String>, composing: Binding<Bool>) {
            self.text = text
            self.composing = composing
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            sync(view)
        }

        /// The binding takes the view's text when no input is being composed; `composing` follows the
        /// marked text.
        func sync(_ view: NSTextView) {
            guard !retired else { return }
            let marked = view.hasMarkedText()
            if composing.wrappedValue != marked { composing.wrappedValue = marked }
            if !marked, text.wrappedValue != view.string { text.wrappedValue = view.string }
        }
    }
}

/// An NSTextView that says when an input method starts, changes, commits or abandons its marked text
/// (NSTextView posts no notification for marked text).
final class MessageTextView: NSTextView {
    var markedTextChanged: ((NSTextView) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged?(self)
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged?(self)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        markedTextChanged?(self)
    }
}
