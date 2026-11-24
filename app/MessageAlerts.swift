// New text messages while RMNet runs: when to count them, what counts as new, and what a notification says. Listing or
// reading an unread message makes it read on the modem (Quectel's AT manual for the RM520N series, 8.6 AT+CMGL and
// 8.7 AT+CMGR: neither has a mode that leaves it unread), so the background never lists or reads one: the app's
// background turn (ModemPulse.swift) reads the message store's count (AT+CPMS?) every 30 s, and when it changed (or
// every tenth turn while it stays the same) the unread entries are counted without being read (SmsService.countUnread:
// the store's entries less the read, unsent and sent ones). More unread or more received entries than at the last
// count is a notification that new messages came in (MessageNotifier.swift), with no sender and no text; the first count
// after the app starts (or after notifications were turned on) is the baseline: what is unread then is one summary.
// Opening Messages lists them (and makes them read on the modem). Counts are of stored parts: a long message is
// several. Foundation only (tests/app/MessageAlertsTests.swift); nothing here logs or stores message text or numbers.
import Foundation

/// What a count gives to announce: the unread parts already there at the baseline (one summary), or that more came in.
enum MessageAlert: Equatable {
    case summary(unread: Int)
    case arrived(Int)          // how many more stored parts are unread (or received) than at the last count
}

struct NewMessageWatch: Equatable {
    /// The store's count read this many times unchanged is counted anyway (about every 5 minutes): a message deleted
    /// elsewhere and one received between two reads leave the count the same.
    static let recountEvery = 10

    private(set) var started = false            // a count (the baseline) has been taken
    private(set) var used: Int? = nil           // the store's count at the last count, or the window's last listing
    private(set) var unread = 0                 // unread parts then
    private(set) var received = 0               // received parts then (unread and read)
    private(set) var reads = 0                  // the store's count read since then

    /// After AT+CPMS?: whether to count the unread parts now: before the first count, when the store's count is not the
    /// one at the last count, and every `recountEvery`th read. nil (not read): nothing.
    mutating func storeCount(_ now: Int?) -> Bool {
        guard let now else { return false }
        reads += 1
        guard started, let used else { return true }
        return now != used || reads >= NewMessageWatch.recountEvery
    }

    /// After a count: the first gives the summary of the unread parts (none when none is unread); a later one that
    /// more came in, when more parts are unread, or more received while some are unread (some were read elsewhere, by
    /// `RMNet sms list`, since): the larger of the two increases. Sent and unsent parts (RMNet's own sends, also from
    /// `RMNet sms send`) are neither, so they are never announced.
    mutating func counted(_ count: SmsStoreCount) -> MessageAlert? {
        defer {
            used = count.used
            unread = count.unread
            received = count.received
            reads = 0
            started = true
        }
        guard started else { return count.unread > 0 ? .summary(unread: count.unread) : nil }
        let more = max(count.unread - unread, count.received - received)
        return count.unread > 0 && more > 0 ? .arrived(min(more, count.unread)) : nil
    }

    /// The Messages screen listed every message, showing the unread ones and making them read on the modem: none is
    /// unread from then on, `received` parts are received, and there is nothing to summarise.
    mutating func listedByWindow(used now: Int?, received parts: Int) {
        used = now
        unread = 0
        received = parts
        reads = 0
        started = true
    }
}

/// A notification's words: `RMNet`, and that the modem has unread messages (the summary) or new ones; never a sender or
/// text (they are not read, so that they stay unread). One part says "message"; more may be one long message, so say
/// "messages" without a number.
func alertContent(_ alert: MessageAlert) -> (title: String, body: String) {
    switch alert {
    case .summary(let n):
        return ("RMNet", n == 1 ? "1 unread message on the modem." : "Unread messages on the modem.")
    case .arrived(let n):
        return ("RMNet", n == 1 ? "New message on the modem." : "New messages on the modem.")
    }
}

/// The menu bar panel's line: "1 unread message", "3 unread messages" (the window's marks); with unread parts on the
/// modem that the window has not listed, "1 unread message" for one and nothing marked, else "Unread messages" with
/// "+" after the marks when there are some ("3+ unread messages"); "" with none.
func unreadLine(_ marks: Int, onModem parts: Int = 0) -> String {
    if parts <= 0 { return marks > 0 ? "\(marks) unread \(marks == 1 ? "message" : "messages")" : "" }
    if marks <= 0 { return parts == 1 ? "1 unread message" : "Unread messages" }
    return "\(marks)+ unread messages"
}

/// Posting notifications with the system's permission: asked the first time one is posted, the ones posted meanwhile
/// wait for the answer; refused, they are dropped, and the next one asks the system again (without a prompt: it may
/// have been allowed in System Settings since). The system's calls are given (MessageNotifier.swift), each answering on
/// the main thread, so this is tested without them.
final class NotificationGate<Request> {
    enum Permission: Equatable { case notAsked, asking, allowed, refused }

    private(set) var permission = Permission.notAsked
    private(set) var dropped = 0
    private var waiting: [Request] = []
    private let ask: (@escaping (Bool) -> Void) -> Void      // the first time: the prompt
    private let check: (@escaping (Bool) -> Void) -> Void    // after a refusal: allowed now?
    private let add: (Request) -> Void

    init(ask: @escaping (@escaping (Bool) -> Void) -> Void, check: @escaping (@escaping (Bool) -> Void) -> Void,
         add: @escaping (Request) -> Void) {
        self.ask = ask
        self.check = check
        self.add = add
    }

    func post(_ request: Request) {
        switch permission {
        case .allowed:
            add(request)
        case .asking:
            waiting.append(request)
        case .notAsked:
            permission = .asking
            waiting.append(request)
            ask { [weak self] allowed in self?.answered(allowed) }
        case .refused:
            permission = .asking
            waiting.append(request)
            check { [weak self] allowed in self?.answered(allowed) }
        }
    }

    private func answered(_ allowed: Bool) {
        permission = allowed ? .allowed : .refused
        let posted = waiting
        waiting = []
        if allowed { posted.forEach(add) } else { dropped += posted.count }
    }
}
