// Tests for app/SmsConversations.swift: which conversation a number belongs to, the conversations (one a number, the
// latest first, unread counts), the order within one (a sent message by the time RMNet sent it, else after the messages
// stored before it), the previews, the sent status words, the heading and the delete question. Built with swiftc by
// `make app-test` from app/SmsModel.swift, app/SmsConversations.swift and this file. Every number and text is made up.
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

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func received(_ index: Int, _ from: String, at seconds: TimeInterval, _ text: String = "Made-up", unread: Bool = false) -> SmsMessage {
    SmsMessage(indices: [index], unread: unread, sender: from, timestamp: t0.addingTimeInterval(seconds), text: text,
               missingParts: 0, readable: true)
}

func sent(_ indices: [Int], to: String, _ text: String = "Made-up reply", box: SmsBox = .sent) -> SmsMessage {
    SmsMessage(indices: indices, unread: false, sender: to, timestamp: nil, text: text, missingParts: 0, readable: true,
               box: box, unsentIndices: box == .unsent ? indices : [])
}

@main
struct SmsConversationsTests {
    static func main() {
        keys()
        grouping()
        settling()
        order()
        words()
        print("conversations: \(checks) checks passed")
    }

    static func keys() {
        equal(conversationKey("+12025550100"), "+12025550100", "key: an international number, whole")
        equal(conversationKey("+1 (202) 555-0100"), "+12025550100", "key: spaces and punctuation")
        equal(conversationKey("2025550100"), "2025550100", "key: a national number, region not known: itself")
        equal(conversationKey("2025550100", home: "1"), "+12025550100", "key: a national number of a US SIM")
        equal(conversationKey("12025550100", home: "1"), "+12025550100", "key: with the trunk prefix 1")
        // Two international numbers that end in the same ten digits are two conversations.
        check(conversationKey("+442025550100", home: "1") != conversationKey("+12025550100", home: "1"),
              "key: +44 and +1 with the same last ten digits differ")
        equal(conversationKey("+442025550100"), "+442025550100", "key: another country's number, whole")
        // Not a North American national number: left as it is.
        equal(conversationKey("0201550100", home: "1"), "0201550100", "key: a leading 0, not merged")
        equal(conversationKey("12345", home: "1"), "12345", "key: a short code")
        equal(conversationKey("55555"), "55555", "key: a short number")
        equal(conversationKey("T-Mobile"), "t-mobile", "key: a name, lower case")
        equal(conversationKey("12a34"), "12a34", "key: digits and letters is a name")
        equal(conversationKey(""), "", "key: none")

        equal(homeCallingCode(imsi: "310150123456789"), "1", "home: a US SIM (MCC 310)")
        equal(homeCallingCode(imsi: "302720123456789"), "1", "home: a Canadian SIM (MCC 302)")
        check(homeCallingCode(imsi: "234150123456789") == nil, "home: elsewhere, not known")
        check(homeCallingCode(imsi: nil) == nil, "home: no SIM, not known")
    }

    // One conversation a number (an international and a national form together where the region is known), the
    // latest first, unread counted; another country's number with the same last digits apart.
    static func grouping() {
        let a1 = received(0, "+12025550100", at: 0, unread: true)
        let a2 = sent([1], to: "2025550100")
        let b1 = received(2, "T-Mobile", at: 500)
        let a3 = received(3, "+12025550100", at: 1000, unread: true)
        let unread: Set<SmsMessageKey> = [a1.key, a3.key]
        let list = conversations([a3, b1, a2, a1], unread: unread, sentAt: [:], home: "1")
        equal(list.map { $0.id }, ["+12025550100", "t-mobile"], "grouping: two conversations, the latest first")
        equal(list[0].messages, [a1, a2, a3], "grouping: received and sent together, in order")
        equal(list[0].unread, 2, "grouping: unread counted")
        equal(list[0].number, "+12025550100", "grouping: the latest message's number")
        equal(list[0].storedParts, 3, "grouping: stored parts")
        equal(list[1].unread, 0, "grouping: none unread")

        // Without the region: the national form is a conversation of its own.
        equal(conversations([a3, a2, a1], unread: [], sentAt: [:]).map { $0.id }, ["+12025550100", "2025550100"],
              "grouping: region not known, the national form apart")
        // The number shown (and replied to): the international form, also when the latest message has the national one.
        let a4 = sent([4], to: "2025550100")
        equal(conversations([a4, a3], unread: [], sentAt: [4: t0.addingTimeInterval(2000)], home: "1").first?.number,
              "+12025550100", "grouping: the international form is the number")
        // Another country, the same last ten digits: its own conversation, its own number.
        let abroad = received(5, "+442025550100", at: 1500)
        let split = conversations([abroad, a3, a1], unread: [], sentAt: [:], home: "1")
        equal(split.map { $0.id }, ["+442025550100", "+12025550100"], "grouping: +44 and +1 apart")
        equal(split.map { $0.number }, ["+442025550100", "+12025550100"], "grouping: each its own number")
        equal(split[1].messages, [a1, a3], "grouping: the +1 conversation has only its own")

        // A conversation of sent messages only, with no time: by its index among the rest.
        let lone = sent([9], to: "+12025550199")
        let withLone = conversations([a3, b1, lone, a1], unread: [], sentAt: [:])
        equal(withLone.map { $0.id }, ["+12025550100", "t-mobile", "+12025550199"], "grouping: no time at all goes last")
        let timed = conversations([a3, b1, lone, a1], unread: [], sentAt: [9: t0.addingTimeInterval(2000)])
        equal(timed.first?.id, "+12025550199", "grouping: sent just now goes first")
        equal(conversations([], unread: [], sentAt: [:]), [], "grouping: none")
    }

    // What RMNet knows of its own sends: a part confirmed sent though still listed unsent is not offered for Retry.
    static func settling() {
        let m = sent([10, 11], to: "+12025550100", "Long", box: .unsent)
        let parts = [StoredPdu(index: 10, status: .unsent, hex: "00AA"), StoredPdu(index: 11, status: .unsent, hex: "00BB")]
        equal(settled([m], parts: parts, confirmed: []), [m], "settled: nothing known, as listed")
        let one = settled([m], parts: parts, confirmed: [StoredPart(index: 10, hex: "00AA")])
        check(one.first?.box == .unsent && one.first?.unsentIndices == [11], "settled: one part sent, the other offered")
        let both = settled([m], parts: parts, confirmed: [StoredPart(index: 10, hex: "00AA"), StoredPart(index: 11, hex: "00BB")])
        check(both.first?.box == .sent && both.first?.unsentIndices == [], "settled: every part sent, shown sent")
        let other = settled([m], parts: parts, confirmed: [StoredPart(index: 10, hex: "00CC")])
        equal(other, [m], "settled: another message at that index, as listed")
    }

    // Within one: by time; a sent message without one after the messages stored before it; by RMNet's time when known.
    static func order() {
        let r1 = received(2, "+12025550100", at: 100)
        let s1 = sent([3], to: "+12025550100", "First reply")
        let r2 = received(5, "+12025550100", at: 200)
        let s2 = sent([6], to: "+12025550100", "Second reply")
        let ordered = conversationOrder([s2, r2, s1, r1], sentAt: [:]).map { $0.message }
        equal(ordered, [r1, s1, r2, s2], "order: each reply after the message stored before it")

        // An index reused after a deletion: a reply stored at a low index, sent now, by RMNet's time.
        let early = sent([0], to: "+12025550100", "Sent now")
        let byTime = conversationOrder([r1, r2, early], sentAt: [0: t0.addingTimeInterval(300)]).map { $0.message }
        equal(byTime, [r1, r2, early], "order: the time RMNet sent it, not the index")
        let byIndex = conversationOrder([r1, r2, early], sentAt: [:]).map { $0.message }
        equal(byIndex, [early, r1, r2], "order: without a time, by the index (a known limit)")
        equal(messageTime(early, sentAt: [0: t0]), t0, "time: sent, known")
        check(messageTime(early, sentAt: [:]) == nil, "time: sent, not known")
        equal(messageTime(r1, sentAt: [2: t0.addingTimeInterval(9999)]), r1.timestamp, "time: received, its own")
    }

    static func words() {
        let c = SmsConversation(id: "x", number: "+12025550100",
                                messages: [received(0, "+12025550100", at: 0, "Line one\nLine two"), sent([1], to: "+12025550100", "Okay\nmore")],
                                unread: 0)
        equal(conversationPreview(c), "You: Okay", "preview: sent, first line")
        let r = SmsConversation(id: "x", number: "+12025550100", messages: [received(0, "+12025550100", at: 0, "Hi\nthere")],
                                unread: 1)
        equal(conversationPreview(r), "Hi", "preview: received")
        let empty = SmsConversation(id: "x", number: "", messages: [SmsMessage(indices: [0], unread: false, sender: "",
                                    timestamp: nil, text: "", missingParts: 0, readable: false)], unread: 0)
        equal(conversationPreview(empty), "Not readable", "preview: not readable")

        let fmt: (Date) -> String = { _ in "14:05" }
        check(sentStatusWords(received(0, "x", at: 0), sentAt: [:], time: fmt) == nil, "status: received, none")
        equal(sentStatusWords(sent([1], to: "x"), sentAt: [:], time: fmt), "Sent", "status: sent, no time")
        equal(sentStatusWords(sent([1], to: "x"), sentAt: [1: t0], time: fmt), "Sent 14:05", "status: sent, with the time")
        equal(sentStatusWords(sent([1], to: "x", box: .unsent), sentAt: [1: t0], time: fmt), "Not sent", "status: not sent")
        equal(sentStatusWords(sent([1], to: "x", box: .unsent), sentAt: [:], unconfirmed: [1], time: fmt), "Not confirmed",
              "status: no answer when it was sent, not confirmed")

        equal(conversationCountLine(count: 0, unread: 0), "", "heading: none")
        equal(conversationCountLine(count: 1, unread: 0), "1 conversation", "heading: one")
        equal(conversationCountLine(count: 3, unread: 2), "3 conversations · 2 unread", "heading: unread")

        let q = deleteConversationQuestion(c)
        equal(q.title, "Delete the conversation with +12025550100?", "delete: title")
        equal(q.message, "2 messages (2 stored parts) will be deleted from the modem. This cannot be undone.", "delete: message")
    }
}
