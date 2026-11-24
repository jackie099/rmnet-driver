// The window's Messages screen, as conversations: the modem's messages, received and sent (SmsService.swift stores what
// RMNet sends on the modem, AT+CMGW then AT+CMSS), grouped by the other party's number (SmsConversations.swift). The
// list (how many conversations and how many unread above it; each row the number, the latest message's first line, how
// long ago, the unread count) beside the conversation shown: received messages on the left, sent ones on the right with
// Sent or Not sent (Retry, Delete), Copy Code for a one-time code, and a reply field at the bottom. The store's use is in
// the list's footer; Refresh, Delete Conversation… and New Message (a sheet, to a new number) are in the toolbar.
// SmsController (SmsController.swift) holds the state and runs the service; every decision that is a pure function of
// values lives in SmsModel.swift and SmsConversations.swift. Nothing here logs or stores message text or numbers.
import AppKit
import SwiftUI

extension SmsMessage: Identifiable {
    var id: SmsMessageKey { key }
}

struct SmsView: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: SmsController
    @State private var confirmingMessage: SmsMessage? = nil              // the message the delete confirmation is about
    @State private var confirmingConversation: SmsConversation? = nil    // the conversation it is about
    // What the open confirmation deletes, frozen when it opened (SmsController.target): never what a listing that
    // comes while it is open has at the same indices. nil: no longer listed when it opened.
    @State private var confirmingTarget: SmsTarget? = nil
    @State private var writing = false                                   // the New Message sheet is open

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { controller.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh")
                        .disabled(!controller.refreshEnabled)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { controller.unblock() } label: { Label("Unblock", systemImage: "tray.and.arrow.down") }
                        .help("Receive queued incoming messages held up by an MMS notification")
                        .disabled(!controller.changeEnabled)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { askDelete(controller.shownConversation) } label: {
                        Label("Delete Conversation…", systemImage: "trash")
                    }
                    .help("Delete Conversation…")
                    .disabled(!controller.changeEnabled || controller.shownConversation == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { Label("New Message", systemImage: "square.and.pencil") }
                        .help("New Message")
                }
            }
            // The last send's, retry's, delete's or unblock's result, until the next one, its X, or (a success) 8 s.
            .resultBanner(controller.result, kind: controller.resultKind, dismiss: controller.dismissResult,
                          hover: controller.hoverResult)
            .sheet(isPresented: $writing) { ComposeSheet(controller: controller) }
            .onChange(of: confirmingMessage != nil || confirmingConversation != nil) { _, open in
                controller.setConfirmingDelete(open)
            }
            .confirmationDialog(confirmingMessage.map { deleteQuestion($0).title } ?? "",
                                isPresented: Binding(get: { confirmingMessage != nil },
                                                     set: { if !$0 { confirmingMessage = nil } }),
                                titleVisibility: .visible, presenting: confirmingMessage) { m in
                Button("Delete", role: .destructive) { controller.delete(confirmingTarget) }
                Button("Cancel", role: .cancel) {}
            } message: { m in
                Text(verbatim: deleteQuestion(m).message)
            }
            .confirmationDialog(confirmingConversation.map { deleteConversationQuestion($0).title } ?? "",
                                isPresented: Binding(get: { confirmingConversation != nil },
                                                     set: { if !$0 { confirmingConversation = nil } }),
                                titleVisibility: .visible, presenting: confirmingConversation) { c in
                Button("Delete Conversation", role: .destructive) {
                    controller.deleteConversation(c, target: .some(confirmingTarget))
                }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(verbatim: deleteConversationQuestion(c).message)
            }
    }

    /// Opens the delete confirmation for `m`, with what it will delete frozen now.
    private func askDelete(_ m: SmsMessage) {
        confirmingTarget = controller.target(for: [m])
        confirmingMessage = m
    }

    private func askDelete(_ c: SmsConversation?) {
        guard let c else { return }
        confirmingTarget = controller.target(for: c)
        confirmingConversation = c
    }

    @ViewBuilder private var content: some View {
        if controller.messages.isEmpty {
            VStack(spacing: 0) {
                if controller.incomingBlocked {
                    BlockedIncomingNotice(enabled: controller.changeEnabled) { controller.unblock() }
                }
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let list = controller.conversations
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if controller.incomingBlocked {
                        BlockedIncomingNotice(enabled: controller.changeEnabled) { controller.unblock() }
                    }
                    if let failure = controller.listFailure {
                        StaleListNotice(text: listLine(updated: controller.listedAt, failure: failure))
                    }
                    ListHeading(text: conversationCountLine(count: list.count, unread: list.reduce(0) { $0 + $1.unread }),
                                unread: list.contains { $0.unread > 0 })
                    // Ages are counted from a clock that turns every 15 s, so they stay right between listings.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        List(list, selection: $controller.selectedConversation) { c in
                            ConversationRow(conversation: c, sentAt: controller.sentAt, now: context.date)
                                .tag(c.id)
                        }
                        .listStyle(.inset)
                    }
                    ListFooter(controller: controller)
                }
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 330)
                Divider()
                ConversationPane(controller: controller, conversation: controller.shownConversation,
                                 deleteMessage: { askDelete($0) },
                                 deleteConversation: { askDelete($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// No messages: the modem is not attached, the listing failed, there are none, or the first listing runs.
    @ViewBuilder private var emptyState: some View {
        if let failure = controller.listFailure {
            if failure == describe(.modemNotAttached) {
                EmptyState(symbol: "cable.connector.slash", title: "Modem not attached", message: failure)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "The messages could not be read", message: failure)
            }
        } else if controller.listed {
            EmptyState(symbol: "tray", title: "No messages",
                       message: listLine(updated: controller.listedAt, failure: nil),
                       action: (title: "New Message", perform: { writing = true }))
        } else {
            EmptyState(symbol: "message", title: "Reading the messages…")
        }
    }
}

// MARK: - The list

/// The sender as a title: the number or name the modem gave, "Unknown sender" when it gave none.
private func senderTitle(_ number: String) -> String {
    number.isEmpty ? "Unknown sender" : number
}

/// The first letter of a model line in upper case, so it reads as a sentence on its own ("1 part missing").
private func sentence(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}

/// How long ago, against `now` ("Now", "5 min. ago", "Yesterday", "4 days ago"); a time after `now` (the service
/// centre's clock ahead of the Mac's) counts as now; "" with no time.
private func age(_ time: Date?, now: Date) -> String {
    guard let time else { return "" }
    return sentence(ageFormatter.localizedString(for: min(time, now), relativeTo: now))
}

private let ageFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.unitsStyle = .short
    f.dateTimeStyle = .named
    return f
}()

/// A time in full ("Monday 16 November 2026 at 14:05").
private let fullTime: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
    return f
}()

/// A bubble's time: "14:05" today, "Mon 14:05" this week, "16 Nov 14:05" before.
private func bubbleTime(_ date: Date, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        f.dateFormat = "HH:mm"
    } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
        f.dateFormat = "EEE HH:mm"
    } else {
        f.dateFormat = "d MMM HH:mm"
    }
    return f.string(from: date)
}

/// Above the list: how many conversations, and how many messages are unread (blue when some are).
private struct ListHeading: View {
    let text: String
    let unread: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(verbatim: text)
                .foregroundStyle(unread ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.xs)
    }
}

/// A conversation in the list: its number, the latest message's first line (`You:` before a sent one, a red mark
/// before one not sent), how long ago, and the unread count.
private struct ConversationRow: View {
    let conversation: SmsConversation
    let sentAt: [Int: Date]
    let now: Date

    var body: some View {
        let latest = conversation.latest
        let time = latest.flatMap { messageTime($0, sentAt: sentAt) }
        HStack(alignment: .top, spacing: Spacing.s) {
            Avatar(number: conversation.number, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(verbatim: senderTitle(conversation.number))
                        .font(.body.weight(conversation.unread > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    Text(verbatim: age(time, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(time.map { fullTime.string(from: $0) } ?? "")
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    if latest?.box == .unsent {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Not sent"))
                    }
                    Text(verbatim: conversationPreview(conversation))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    if conversation.unread > 0 {
                        Text(verbatim: "\(conversation.unread)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue))
                            .accessibilityLabel(Text(verbatim: "\(conversation.unread) unread"))
                    }
                }
                .font(.callout)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A round mark for a number: a person, or the first letter of a name (a carrier's).
private struct Avatar: View {
    let number: String
    let size: CGFloat

    var body: some View {
        let isName = !number.isEmpty && number.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        ZStack {
            Circle().fill(.quaternary)
            if isName, let first = number.first {
                Text(verbatim: String(first).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Above the list when automatic unblocking is off and the modem reported an unstored incoming message (`+CMTI: ,3`).
private struct BlockedIncomingNotice: View {
    let enabled: Bool
    let unblock: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Incoming messages appear blocked by an MMS notification.")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Unblock", action: unblock)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .padding(Spacing.m)
        .background(Color.orange.opacity(0.12), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Above the list when the last listing failed and the list shown is an older one.
private struct StaleListNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .background(Color.orange.opacity(0.12), ignoresSafeAreaEdges: [])  // not up under the toolbar
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The list's footer: the store's use as a gauge (not shown when it is not known), the warning when it is nearly full,
/// and when the list was read.
private struct ListFooter: View {
    @ObservedObject var controller: SmsController

    var body: some View {
        let warning = storeWarning(used: controller.storeUsed, total: controller.storeTotal)
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let used = controller.storeUsed, let total = controller.storeTotal, total > 0 {
                CapacityGauge(used: used, total: total, label: "Message store")
                    .font(.caption)
            }
            if !warning.isEmpty {
                Text(verbatim: warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if controller.listFailure == nil && controller.listed {
                Text(verbatim: listLine(updated: controller.listedAt, failure: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}


// MARK: - The conversation

/// The conversation shown: its number with Delete Conversation…, its messages oldest first as bubbles (received on the
/// left, sent on the right), and the reply field; with none shown, what to do.
private struct ConversationPane: View {
    @ObservedObject var controller: SmsController
    let conversation: SmsConversation?
    let deleteMessage: (SmsMessage) -> Void
    let deleteConversation: (SmsConversation) -> Void

    var body: some View {
        if let c = conversation {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    Avatar(number: c.number, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: senderTitle(c.number))
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(verbatim: "\(c.messages.count) \(c.messages.count == 1 ? "message" : "messages")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Spacing.s)
                    Button(role: .destructive) { deleteConversation(c) } label: {
                        Label("Delete Conversation…", systemImage: "trash")
                    }
                    .disabled(!controller.changeEnabled)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: Spacing.m) {
                            ForEach(c.messages) { m in
                                Bubble(message: m, sentAt: controller.sentAt, unconfirmed: controller.unconfirmed,
                                       changeEnabled: controller.changeEnabled,
                                       retry: { controller.retry(m) }, delete: { deleteMessage(m) })
                                    .id(m.key)
                            }
                        }
                        .padding(Spacing.l)
                    }
                    .onAppear { reader.scrollTo(c.messages.last?.key, anchor: .bottom) }
                    .onChange(of: c.messages.last?.key) { _, last in
                        withAnimation { reader.scrollTo(last, anchor: .bottom) }
                    }
                }
                Divider()
                // Its own field for each conversation (and its own binding): text an input method commits after
                // another conversation was chosen goes to this one, never to the next.
                ReplyField(controller: controller, conversation: c.id, number: c.number)
                    .id(c.id)
            }
        } else {
            EmptyState(symbol: "bubble.left.and.bubble.right", title: "No conversation selected",
                       message: "Select a conversation in the list to read it, or start one with New Message.")
        }
    }
}

/// One message: received on the left in gray, sent on the right in blue (dimmed while not sent); under it its time,
/// or Sent, and Not sent or Not confirmed (a send that got no answer: it may have gone) with Retry and Delete; Copy
/// Code for a one-time code; a note for a part missing or a message that cannot be read. Its context menu copies the
/// text or the code, and deletes it.
private struct Bubble: View {
    let message: SmsMessage
    let sentAt: [Int: Date]
    let unconfirmed: Set<Int>
    let changeEnabled: Bool
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        let mine = message.outgoing
        let note = rowNote(message)
        let code = mine ? nil : verificationCode(in: message.text)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(verbatim: message.text.isEmpty ? (message.readable ? "No text" : "Not readable") : message.text)
                    .italic(message.text.isEmpty)
                    .foregroundStyle(mine ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(shape.fill(mine ? AnyShapeStyle(Color.accentColor.opacity(message.box == .unsent ? 0.55 : 1))
                                                : AnyShapeStyle(.fill.secondary)))
                    .overlay {
                        if message.box == .unsent { shape.strokeBorder(Color.red.opacity(0.7), lineWidth: 1) }
                    }
                    .contextMenu {
                        Button("Copy Text") { copy(message.text) }
                        if let code { Button("Copy Code \(code)") { copy(code) } }
                        Divider()
                        Button("Delete…", role: .destructive, action: delete)
                            .disabled(!changeEnabled)
                    }
                if !note.isEmpty {
                    Label(sentence(note), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: Spacing.s) {
                    if let code {
                        Button { copy(code) } label: { Label("Copy Code \(code)", systemImage: "number") }
                            .controlSize(.small)
                            .monospacedDigit()
                    }
                    meta
                }
            }
            if !mine { Spacer(minLength: 80) }
        }
    }

    /// The time of a received message; Sent (with the time when known) or Not sent, with Retry and Delete, for a sent one.
    @ViewBuilder private var meta: some View {
        if message.box == .unsent {
            let words = sentStatusWords(message, sentAt: sentAt, unconfirmed: unconfirmed, time: { bubbleTime($0) })
            let maybeSent = words == "Not confirmed"
            Label(words ?? "Not sent", systemImage: maybeSent ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(maybeSent ? .orange : .red)
                .help(maybeSent ? "The modem did not answer when it was sent: it may have been delivered." : "")
            Button("Retry", action: retry)
                .controlSize(.small)
                .disabled(!changeEnabled)
                .help(maybeSent ? "Send the stored part(s) again. It may have been delivered already; sending it again "
                                  + "may deliver it twice." : "Send the stored part(s) again")
            Button("Delete", role: .destructive, action: delete)
                .controlSize(.small)
                .disabled(!changeEnabled)
        } else if let words = sentStatusWords(message, sentAt: sentAt, time: { bubbleTime($0) }) {
            Text(verbatim: words)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let time = message.timestamp {
            Text(verbatim: bubbleTime(time))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(fullTime.string(from: time))
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// The reply: the text (plain, as in the New Message sheet), its part count, and Send (Return sends; Option-Return is a
/// new line). A number that cannot take a reply (a name, such as a carrier's) says so instead.
private struct ReplyField: View {
    @ObservedObject var controller: SmsController
    let conversation: String
    let number: String

    var body: some View {
        if validNumber(number) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .bottom, spacing: Spacing.s) {
                    let edge = RoundedRectangle(cornerRadius: 8, style: .continuous)
                    let key = conversation
                    PlainTextEditor(text: Binding(get: { controller.replyDraft(for: key) },
                                                  set: { controller.setReplyDraft($0, for: key) }),
                                    composing: $controller.replyComposing,
                                    editable: controller.running != .sending)
                        .frame(height: 54)
                        .clipShape(edge)
                        .overlay(edge.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                        .accessibilityLabel(Text("Reply"))
                    Button {
                        controller.sendReply()
                    } label: {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(controller.replyEnabled ? .defaultAction : nil)
                    .disabled(!controller.replyEnabled)
                }
                Text(verbatim: controller.replyText.isEmpty ? "Each message sent costs a carrier fee." : controller.replyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.m)
        } else {
            Text(verbatim: "\(senderTitle(number)) cannot take a reply.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
        }
    }
}

// MARK: - The New Message sheet

/// To, the text (plain, with no automatic substitutions: PlainTextEditor.swift) and its part counter, Cancel and Send.
/// The number and the text live in the controller, so closing the sheet keeps them. While a send runs nothing can be
/// changed or closed and the sheet shows what runs; after a failure the sheet stays open with the failure in it; after
/// a success it closes, and the screen's banner shows the result. Send is the default button (Return) only while the
/// controller allows sending and the To field is not being edited, so Return in To never sends; in the text, Return is
/// a new line. While an input method composes, Send waits (the controller's sendEnabled and composeText).
struct ComposeSheet: View {
    @ObservedObject var controller: SmsController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingNumber: Bool
    @State private var sentHere = false  // a send was started from this sheet: its failure is shown here

    var body: some View {
        let sending = controller.running == .sending
        VStack(alignment: .leading, spacing: Spacing.m) {
            SheetHeader(symbol: "square.and.pencil", title: "New Message",
                        subtitle: "Sent from the modem's SIM; each message sent costs a carrier fee.")
                .padding(.bottom, Spacing.xs)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("To")
                    .foregroundStyle(.secondary)
                TextField("To", text: $controller.to, prompt: Text("Number, with + and the country code"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($editingNumber)
                    .disabled(sending)
            }
            let badNumber = numberNote(controller.to)
            if !badNumber.isEmpty {
                ProblemNote(text: badNumber)
            }
            // It scrolls inside its frame, so a long text is never clipped. Its square bezel is drawn over with the
            // rounded edge of the To field.
            let edge = RoundedRectangle(cornerRadius: 6, style: .continuous)
            PlainTextEditor(text: $controller.text, composing: $controller.composing, editable: !sending)
                .frame(minHeight: 100, idealHeight: 140, maxHeight: 240)
                .clipShape(edge)
                .overlay(edge.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .accessibilityLabel(Text("Message"))
            Text(verbatim: controller.composeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if sending {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(verbatim: controller.result)
                        .font(.callout)
                }
            } else if sentHere && controller.resultIsFailure && !controller.result.isEmpty {
                ProblemNote(text: controller.result)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send") {
                    sentHere = true
                    controller.send()
                }
                .keyboardShortcut(controller.sendEnabled && !editingNumber ? .defaultAction : nil)
                .disabled(!controller.sendEnabled)
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.xl - 4)
        .frame(width: 460)
        .interactiveDismissDisabled(sending)
        .onChange(of: controller.running) { was, now in
            // A send started here has finished: on success the sheet closes (the banner shows the result). The
            // controller lists again as the send finishes, so what follows it may be a listing rather than nothing.
            if was == .sending, now != .sending, sentHere, !controller.resultIsFailure { dismiss() }
        }
    }
}
