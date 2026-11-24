// The Messages screen's conversations: the modem's messages (SmsModel.swift: received, and those RMNet stored and sent)
// grouped by the other party's number, each conversation in the order it happened, the one with the latest message
// first. The modem gives a sent message no time (an SMS-SUBMIT has none), so a sent message takes the time RMNet sent
// it, when this run of RMNet sent it (kept in memory only); otherwise it goes after the messages stored before it (a
// lower index; the modem fills the lowest free index, so without deletions the order of the indices is the order of
// storing). A number is one conversation with itself only: an international number never joins another that ends in
// the same digits; a national number joins its international form only where the SIM's region says what that is
// (homeCallingCode). Foundation only (tests/app/SmsConversationsTests.swift); nothing here logs or stores text or
// numbers.
import Foundation

/// The messages with one number, oldest first, and how many of them are unread (the window's marks).
struct SmsConversation: Equatable, Identifiable {
    let id: String               // conversationKey of the number
    let number: String           // as the latest message gives it, in its international form when one gives that
    let messages: [SmsMessage]   // oldest first
    let unread: Int

    var latest: SmsMessage? { messages.last }
    var storedParts: Int { messages.reduce(0) { $0 + $1.indices.count } }
}

/// The country calling code for a SIM's national numbers, from its IMSI's mobile country code: "1" for a North
/// American one (MCC 302, 310-316: one numbering plan, 10-digit national numbers); nil for any other or none, where a
/// national number's international form is not certain (trunk prefixes and number lengths differ), so it is not
/// merged with one.
func homeCallingCode(imsi: String?) -> String? {
    guard let imsi, imsi.count >= 5, let mcc = Int(imsi.prefix(3)) else { return nil }
    return [302, 310, 311, 312, 313, 314, 315, 316].contains(mcc) ? "1" : nil
}

/// Which conversation a number belongs to: an international number (`+` first) is `+` and all its digits; with `home`
/// "1" a national North American number (10 digits not starting with 0 or 1, or 11 starting with 1) is its
/// international form, so `+1 555 555 0100` and `5555550100` are one conversation; any other number is its digits. A
/// name (an alphanumeric sender such as a carrier's) is lower case; "" for none.
func conversationKey(_ number: String, home: String? = nil) -> String {
    let trimmed = number.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.unicodeScalars.filter { ("0"..."9").contains($0) }
    let rest = trimmed.unicodeScalars.filter { !("0"..."9").contains($0) && !" +-().".unicodeScalars.contains($0) }
    guard !digits.isEmpty, rest.isEmpty else { return trimmed.lowercased() }
    let all = String(String.UnicodeScalarView(digits))
    if trimmed.hasPrefix("+") { return "+" + all }
    if home == "1" {
        if all.count == 10, let first = all.first, !"01".contains(first) { return "+1" + all }
        if all.count == 11, all.hasPrefix("1"), !"01".contains(all[all.index(after: all.startIndex)]) { return "+" + all }
    }
    return all
}

/// When a message happened, as far as known: a received one's time; a sent one's when this run of RMNet sent it.
func messageTime(_ m: SmsMessage, sentAt: [Int: Date]) -> Date? {
    if !m.outgoing { return m.timestamp }
    return m.indices.compactMap { sentAt[$0] }.max()
}

/// The messages as conversations, the latest first (by the latest message's time, else its index). `home`: as
/// conversationKey takes it.
func conversations(_ messages: [SmsMessage], unread: Set<SmsMessageKey>, sentAt: [Int: Date],
                   home: String? = nil) -> [SmsConversation] {
    var groups: [String: [SmsMessage]] = [:]
    var order: [String] = []
    for m in messages {
        let key = conversationKey(m.sender, home: home)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(m)
    }
    let built = order.map { key -> (SmsConversation, Date?, Int) in
        let ordered = conversationOrder(groups[key] ?? [], sentAt: sentAt)
        let latest = ordered.last
        let international = ordered.last { $0.message.sender.hasPrefix("+") }
        let c = SmsConversation(id: key, number: (international ?? latest)?.message.sender ?? "",
                                messages: ordered.map { $0.message },
                                unread: ordered.filter { unread.contains($0.message.key) }.count)
        return (c, latest?.time, ordered.map { $0.message.indices.max() ?? 0 }.max() ?? 0)
    }
    return built.sorted { a, b in
        switch (a.1, b.1) {
        case let (ta?, tb?) where ta != tb: return ta > tb
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.2 > b.2
        }
    }.map { $0.0 }
}

/// One conversation's messages oldest first, each with the time it sorts by: its own (messageTime), or, without one,
/// that of the latest message stored before it (a lower index) that has one; by index where those are equal.
func conversationOrder(_ messages: [SmsMessage], sentAt: [Int: Date]) -> [(message: SmsMessage, time: Date?)] {
    let byIndex = messages.sorted { ($0.indices.first ?? 0) < ($1.indices.first ?? 0) }
    var latestBefore: Date? = nil
    var placed: [(message: SmsMessage, time: Date?, index: Int)] = []
    for m in byIndex {
        let own = messageTime(m, sentAt: sentAt)
        let time = own ?? latestBefore
        if let own { latestBefore = max(latestBefore ?? own, own) }
        placed.append((m, time, m.indices.first ?? 0))
    }
    return placed.sorted { a, b in
        switch (a.time, b.time) {
        case let (ta?, tb?) where ta != tb: return ta < tb
        case (.none, .some): return true
        case (.some, .none): return false
        default: return a.index < b.index
        }
    }.map { ($0.message, $0.time) }
}

/// A conversation row's preview: the latest message's first line, `You: ` before one RMNet sent; `No text` for one
/// without text.
func conversationPreview(_ c: SmsConversation) -> String {
    guard let m = c.latest else { return "" }
    let line = m.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let text = line.isEmpty ? (m.readable ? "No text" : "Not readable") : line
    return m.outgoing ? "You: \(text)" : text
}

/// What a sent message's bubble says under it: `Sent` (with the time when RMNet sent it in this run), `Not sent`, or
/// `Not confirmed` when a part's send got no answer in this run (`unconfirmed`: such stored indices; it may have gone);
/// nil for a received message.
func sentStatusWords(_ m: SmsMessage, sentAt: [Int: Date], unconfirmed: Set<Int> = [], time: (Date) -> String) -> String? {
    switch m.box {
    case .received: return nil
    case .unsent: return m.unsentIndices.contains(where: unconfirmed.contains) ? "Not confirmed" : "Not sent"
    case .sent: return messageTime(m, sentAt: sentAt).map { "Sent \(time($0))" } ?? "Sent"
    }
}

/// The list's heading: "3 conversations · 1 unread", "1 conversation"; "" with none.
func conversationCountLine(count: Int, unread: Int) -> String {
    guard count > 0 else { return "" }
    return "\(count) \(count == 1 ? "conversation" : "conversations")" + (unread > 0 ? " · \(unread) unread" : "")
}

/// The confirmation before a conversation is deleted: with whom, and how many messages and stored parts go.
func deleteConversationQuestion(_ c: SmsConversation) -> (title: String, message: String) {
    let who = c.number.isEmpty ? "an unknown sender" : c.number
    let n = c.messages.count, parts = c.storedParts
    return ("Delete the conversation with \(who)?",
            "\(n) \(n == 1 ? "message" : "messages") (\(parts) stored \(parts == 1 ? "part" : "parts")) will be deleted "
                + "from the modem. This cannot be undone.")
}

/// The messages as the window shows them: a part whose send the modem confirmed in this run but still lists as unsent
/// (SmsSendRecord.stillUnsent, kept in memory as `confirmed`) is not offered for Retry, and a message with no other
/// unsent part is sent. `parts`: the listing's stored entries, to tell that the part at an index is that one.
func settled(_ messages: [SmsMessage], parts: [StoredPdu], confirmed: Set<StoredPart>) -> [SmsMessage] {
    guard !confirmed.isEmpty else { return messages }
    let indices = Set(parts.filter { confirmed.contains(StoredPart($0)) }.map { $0.index })
    return settled(messages, confirmedIndices: indices)
}

/// `conversations` under another name, for SmsController, whose property has that name.
enum RMNetConversations {
    static func build(_ messages: [SmsMessage], unread: Set<SmsMessageKey>, sentAt: [Int: Date],
                      home: String?) -> [SmsConversation] {
        conversations(messages, unread: unread, sentAt: sentAt, home: home)
    }
}
