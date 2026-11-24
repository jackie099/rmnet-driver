// Tests for app/SmsModel.swift: decoding SMS-DELIVER PDUs, the GSM 7-bit and UCS-2 alphabets,
// assembling multi-part messages, encoding SMS-SUBMIT, and reading the modem's AT answers.
// Built with swiftc by `make app-test`; needs no Xcode project and no hardware.
// Stops at the first failure, prints which check failed and exits 1.
//
// Hand-built vectors carry their derivation field by field (TS 23.040 / TS 23.038). Semi-octets are
// written swapped: the digits "86" are the octet 0x68. Time stamps are year, month, day, hour,
// minute, second, zone, each swapped; the zone is in quarter hours and bit 3 of the octet is the sign.
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

/// A UTC instant, so no check depends on this Mac's time zone.
func utc(_ secondsSince1970: TimeInterval) -> Date { Date(timeIntervalSince1970: secondsSince1970) }

func decode(_ hex: String, index: Int = 1, status: SmsStatus = .read) -> SmsPart {
    decodePart(StoredPdu(index: index, status: status, hex: hex))
}

func expectPart(_ hex: String, _ name: String, sender: String, text: String, time: Date?,
                concat: SmsConcat? = nil) {
    let p = decode(hex)
    check(p.readable, "\(name): readable", "\(p)")
    check(p.sender == sender, "\(name): sender", "want \"\(sender)\", got \"\(p.sender)\"")
    check(p.text == text, "\(name): text", "want \"\(text)\", got \"\(p.text)\"")
    check(p.timestamp == time, "\(name): time", "want \(String(describing: time)), got \(String(describing: p.timestamp))")
    check(p.concat == concat, "\(name): concatenation", "want \(String(describing: concat)), got \(String(describing: p.concat))")
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

func expectUnreadable(_ hex: String, _ name: String) {
    let p = decode(hex, index: 4, status: .unread)
    check(!p.readable && p.sender == "" && p.text == "" && p.timestamp == nil && p.concat == nil
            && p.index == 4 && p.status == .unread, "unreadable: \(name)", "\(p)")
}

// --- DELIVER vectors -------------------------------------------------------------------------------

// The classic vector (given in the plan, checked by hand by the controller).
let classic = "07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC37"

// UCS-2 Chinese, zone +8 hours.
//   08               SMSC length: 8 octets follow (type + 7)
//   91 683108200105F0  SMSC +8613800210500: international; "86 13 80 02 10 50 0F" swapped
//   04               first octet: TP-MTI 00 (DELIVER), TP-MMS 1, no UDHI
//   0D 91 683119325476F8  sender: 13 digits, international, "86 13 91 23 45 67 8F" swapped
//   00               TP-PID
//   08               TP-DCS: group 00xx, alphabet bits 10 = UCS-2
//   62 11 41 01 03 00 23  2026-11-14 10:30:00, zone 0x23: tens 3 (sign bit 0), units 2 = +32 quarters = +8 h
//   08               TP-UDL: 8 octets
//   4F60 597D 4E16 754C  你 好 世 界 in UTF-16 big-endian
// 10:30:00 at +8 is 02:30:00 UTC = 1794623400.
let chinese = "0891683108200105F0" + "04" + "0D91683119325476F8" + "00" + "08" + "62114101030023" + "08"
    + "4F60597D4E16754C"

// Alphanumeric sender "Alerts", no SMSC stored, zone -5 hours, GSM 7-bit text "Code 1234".
//   00               SMSC length 0
//   04               first octet: DELIVER, MMS
//   0B               sender length: 11 useful semi-octets (6 septets x 7 = 42 bits -> 11 nibbles)
//   D0               type: ext 1, type of number 101 (alphanumeric), plan 0000
//   4176594E9F03     "Alerts" packed: septets A=1000001 l=1101100 e=1100101 r=1110010 t=1110100 s=1110011
//                    o0 = A | (l&1)<<7 = 0x41;   o1 = l>>1 | (e&3)<<6 = 0x36|0x40 = 0x76
//                    o2 = e>>2 | (r&7)<<5 = 0x19|0x40 = 0x59;  o3 = r>>3 | (t&0xF)<<4 = 0x0E|0x40 = 0x4E
//                    o4 = t>>4 | (s&0x1F)<<3 = 0x07|0x98 = 0x9F;  o5 = s>>5 = 0x03
//   00 00            TP-PID, TP-DCS 00 (GSM 7-bit)
//   62 10 50 80 00 00 0A  2026-01-05 08:00:00; zone 0x0A: low nibble 1010 = sign 1, tens 2; units 0
//                    -> -20 quarters = -5 h
//   09               TP-UDL: 9 septets
//   C337B90C8AC96634 "Code 1234" packed into 8 octets (63 bits)
// 08:00:00 at -5 is 13:00:00 UTC = 1767618000.
let alphanumeric = "00" + "04" + "0BD0" + "4176594E9F03" + "00" + "00" + "6210508000000A" + "09"
    + "C337B90C8AC96634"

// National-number sender 10086.
//   08 91 683108100005F0  SMSC +8613800100500
//   04               DELIVER, MMS
//   05 A1 0180F6     sender: 5 digits, type 0xA1 (type of number 010 national, plan 0001); "10 08 6F" swapped
//   00 00            PID, DCS GSM 7-bit
//   62 11 41 81 50 90 23  2026-11-14 18:05:09 +8 h
//   0D               13 septets
//   C2303BEC1E97413199AB0603  "Balance 12.50" packed (91 bits -> 12 octets)
// 18:05:09 at +8 is 10:05:09 UTC = 1794650709.
let national = "0891683108100005F0" + "04" + "05A10180F6" + "00" + "00" + "62114181509023" + "0D"
    + "C2303BEC1E97413199AB0603"

// GSM 7-bit with a user data header (8-bit concatenation, part 1 of 2) and one fill bit.
//   07 91 7283010010F5  SMSC +27381000015
//   44               first octet: DELIVER, MMS, TP-UDHI (bit 6)
//   0B 91 7238880900F1  sender +27838890001
//   00 00            PID, DCS GSM 7-bit
//   62 11 41 21 00 00 00  2026-11-14 12:00:00 +0
//   12               TP-UDL 18 septets: the header is 6 octets = 48 bits, padded with 1 fill bit to
//                    49 bits = 7 septets, then "Hello world" = 11 septets
//   05 00 03 42 02 01  UDHL 5; element 00 (concatenation, 8-bit reference), length 3, ref 0x42, total 2, seq 1
//   906536FB0DBABFE56C32  the 11 septets packed from bit 49 on (bit 48 is the fill bit, 0)
// 12:00:00 UTC = 1794657600.
let withHeader = "07917283010010F5" + "44" + "0B917238880900F1" + "00" + "00" + "62114121000000" + "12"
    + "050003420201" + "906536FB0DBABFE56C32"

// GSM 7-bit extension characters "€[]{}\~^|": each is escape 0x1B then the extension code
// (€ 65, [ 3C, ] 3E, { 28, } 29, \ 2F, ~ 3D, ^ 14, | 40), so 9 characters are 18 septets.
//   07 91 7283010010F5  SMSC; 04 DELIVER; 0B 91 7238880900F1 sender +27838890001; 00 00 PID, DCS
//   99 30 92 51 61 95 80  1999-03-29 15:16:59 +2 h (the classic vector's time)
//   12               18 septets
//   9BF286B7F16D509BD4E6B5E96D281B20  septets 1B 65 1B 3C 1B 3E 1B 28 1B 29 1B 2F 1B 3D 1B 14 1B 40
//                    packed (126 bits -> 16 octets); o0 = 1B | (65&1)<<7 = 0x9B
let extensionText = "07917283010010F5" + "04" + "0B917238880900F1" + "00" + "00" + "99309251619580" + "12"
    + "9BF286B7F16D509BD4E6B5E96D281B20"

// UCS-2 with an emoji (a surrogate pair): "Hi 😀".
//   00 SMSC; 04 DELIVER; 0B 91 7238880900F1 sender; 00 PID; 08 DCS UCS-2; 99309251619580 time
//   0A               10 octets
//   0048 0069 0020 D83D DE00  H i space, then U+1F600 as the pair D83D DE00
let emoji = "00" + "04" + "0B917238880900F1" + "00" + "08" + "99309251619580" + "0A" + "004800690020D83DDE00"

// UCS-2 with a 16-bit concatenation element after an element that must be skipped.
//   00 SMSC; 44 DELIVER with UDHI; 0B 91 7238880900F1 sender; 00 PID; 08 UCS-2; 99309251619580 time
//   0D               13 octets: header 11 (UDHL octet + 10) and text 2
//   0A               UDHL 10
//   01 02 00 00      element 01 (special message indication), length 2: skipped
//   08 04 12 34 03 02  element 08 (concatenation, 16-bit reference), length 4: ref 0x1234 = 4660, total 3, seq 2
//   597D             好
let concat16 = "00" + "44" + "0B917238880900F1" + "00" + "08" + "99309251619580" + "0D" + "0A01020000080412340302"
    + "597D"

// 8-bit data shown as Latin-1: DCS 04 (group 00xx, alphabet 01); UDL 4; 63 61 66 E9 = "café".
let latin1 = "00" + "04" + "0B917238880900F1" + "00" + "04" + "99309251619580" + "04" + "636166E9"

// The classic vector with DCS F0 (group 1111: class 0, bit 2 = 0 -> GSM 7-bit).
let classGroup = "07917283010010F5040BC87238880900F100F0993092516195800AE8329BFD4697D9EC37"

// The whole basic table: the 127 septets 0x00...0x7F without the escape 0x1B, in order.
//   07 91 7283010010F5  SMSC; 04 DELIVER; 0B C8 7238880900F1 sender 27838890001; 00 PID; 00 DCS GSM 7-bit
//   99 30 92 51 61 95 80  the classic vector's time
//   7F               TP-UDL 127 septets = 889 bits -> 112 octets
//   then the 127 septets packed (septet n at bits 7n...7n+6). o0 = 00 | (01&1)<<7 = 0x80;
//   o1 = 01>>1 | (02&3)<<6 = 0x80; o2 = 02>>2 | (03&7)<<5 = 0x60; ... The 112 octets were computed by an
//   independent packer (a big little-endian integer in Python) and equal the reviewer's own packing.
let wholeTable = "07917283010010F5" + "04" + "0BC87238880900F1" + "00" + "00" + "99309251619580" + "7F"
    + "8080604028180E888462C168381E90886442A9582E988C86D3F17C4021D18854329D5029D58AD572BD6031D98C56B3DD"
    + "7039DD8ED7F3FD8041E19058341E9149E592D9743EA151E9945AB55EB159ED96DBF57EC161F1985C369FD169F59ADD76BFE1"
    + "71F99C5EB7DFF179FD9EDFF7FF01"

// The same 127 characters written out from TS 23.038 §6.2.1, row by row, not taken from the model's table.
let wholeTableText =
    "@\u{00A3}$\u{00A5}\u{00E8}\u{00E9}\u{00F9}\u{00EC}\u{00F2}\u{00C7}\n\u{00D8}\u{00F8}\r\u{00C5}\u{00E5}"  // 0x00-0x0F
    + "\u{0394}_\u{03A6}\u{0393}\u{039B}\u{03A9}\u{03A0}\u{03A8}\u{03A3}\u{0398}\u{039E}"            // 0x10-0x1A
    + "\u{00C6}\u{00E6}\u{00DF}\u{00C9}"                                                             // 0x1C-0x1F
    + " !\"#\u{00A4}%&'()*+,-./"                                                                     // 0x20-0x2F
    + "0123456789:;<=>?"                                                                             // 0x30-0x3F
    + "\u{00A1}ABCDEFGHIJKLMNO"                                                                      // 0x40-0x4F
    + "PQRSTUVWXYZ\u{00C4}\u{00D6}\u{00D1}\u{00DC}\u{00A7}"                                          // 0x50-0x5F
    + "\u{00BF}abcdefghijklmno"                                                                      // 0x60-0x6F
    + "pqrstuvwxyz\u{00E4}\u{00F6}\u{00F1}\u{00FC}\u{00E0}"                                          // 0x70-0x7F

// Alphanumeric sender "AlertsP" (7 septets = 49 bits in 7 octets: 4176594E9F4301; the first six octets
// as in `alphanumeric` except o5 = s>>5 | (P&0x3F)<<2 = 0x03|0x40 = 0x43, o6 = P>>6 = 0x01).
// The length 0D (13 useful semi-octets) is right; 0E (14, twice the octets) leaves 56 bits = 8 septets
// whose last is the zero padding, which must not read as a trailing "@".
func alphaSender(_ length: String) -> String {
    "00" + "04" + length + "D0" + "4176594E9F4301" + "00" + "00" + "99309251619580" + "0A" + "E8329BFD4697D9EC37"
}

let classicTime = utc(922713419) // 1999-03-29 13:16:59 UTC

let deliverVectors = [classic, chinese, alphanumeric, national, withHeader, extensionText, emoji, concat16,
                      latin1, classGroup, wholeTable]

// --- assembly helpers ------------------------------------------------------------------------------

func part(_ index: Int, _ sender: String = "+111", _ time: Date? = nil, _ text: String,
          _ concat: (Int, Int, Int)? = nil, status: SmsStatus = .read) -> SmsPart {
    SmsPart(index: index, status: status, sender: sender, timestamp: time, text: text,
            concat: concat.map { SmsConcat(reference: $0.0, total: $0.1, sequence: $0.2) }, readable: true)
}

/// A fixed-seed generator (SplitMix64), so the round trip sees the same texts every run.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Reads every PDU back and joins the texts; nil when one does not read back or its concatenation
/// element is wrong.
func readBack(_ pdus: [SubmitPdu], reference: Int, number: String) -> String? {
    var text = ""
    for (n, pdu) in pdus.enumerated() {
        guard pdu.tpduLength == pdu.hex.utf8.count / 2 - 1, pdu.hex.hasPrefix("00"),
              let r = readSubmit(pdu.hex), r.number == number else { return nil }
        let want = pdus.count == 1 ? nil : SmsConcat(reference: reference, total: pdus.count, sequence: n + 1)
        guard r.concat == want else { return nil }
        text += r.text
    }
    return text
}

// --- the window's helpers (composeNote, canSend, numberNote, rowTitle, rowNote, deleteQuestion, unreadMarks,
// listLine, the store's use and warning, listHeadline, listPlaceholder)

func message(_ indices: [Int], unread: Bool = false, sender: String = "+27838890001", time: Date? = nil,
             text: String = "hi", missing: Int = 0, readable: Bool = true) -> SmsMessage {
    SmsMessage(indices: indices, unread: unread, sender: sender, timestamp: time, text: text,
               missingParts: missing, readable: readable)
}

func windowHelperChecks() {
    // composeNote: parts and alphabet, from the same splitting the sender uses.
    let notes: [(String, String)] = [
        ("", ""),
        ("hello", "1 part, GSM alphabet"),
        (String(repeating: "a", count: 160), "1 part, GSM alphabet"),
        (String(repeating: "a", count: 161), "2 parts, GSM alphabet"),
        ("你好", "1 part, Unicode"),
        (String(repeating: "好", count: 140), "3 parts, Unicode"),
        (String(repeating: "a", count: 1530), "10 parts, GSM alphabet"),
        (String(repeating: "a", count: 1531), "too long: 11 parts, at most 10"),
        (String(repeating: "a", count: 153 * 11 + 1), "too long: 12 parts, at most 10"),
        (String(repeating: "好", count: 70), "1 part, Unicode"),
        (String(repeating: "好", count: 71), "2 parts, Unicode"),
        (String(repeating: "好", count: 670), "10 parts, Unicode"),
        (String(repeating: "好", count: 671), "too long: 11 parts, at most 10"),
    ]
    for (text, want) in notes {
        let got = composeNote(text)
        check(got == want, "composeNote: \(text.count) characters", "want \"\(want)\", got \"\(got)\"")
    }

    // canSend: a valid number and a text of 1 to 10 parts that is not only blanks.
    let good = "+27838890001"
    check(canSend(number: good, text: "hi"), "canSend: valid number and text")
    check(canSend(number: "10086", text: "你好"), "canSend: national number, Unicode text")
    check(!canSend(number: "12", text: "hi"), "canSend: number too short")
    check(!canSend(number: "+27 83", text: "hi"), "canSend: number with a space")
    check(!canSend(number: "", text: "hi"), "canSend: no number")
    check(!canSend(number: good, text: ""), "canSend: empty text")
    check(!canSend(number: good, text: " \n\t "), "canSend: only blanks")
    check(canSend(number: good, text: String(repeating: "a", count: 1530)), "canSend: 10 parts")
    check(!canSend(number: good, text: String(repeating: "a", count: 1531)), "canSend: 11 parts")

    // numberNote: says nothing until there is a number, and nothing for a valid one.
    let rule = "The number is 3 to 20 digits, with an optional + in front."
    check(numberNote("") == "", "numberNote: empty")
    check(numberNote(good) == "", "numberNote: valid")
    check(numberNote("12") == rule, "numberNote: too short", numberNote("12"))
    check(numberNote("+27 83") == rule, "numberNote: with a space", numberNote("+27 83"))

    // rowTitle: today's messages as HH:mm, older ones with the date, in the zone given.
    let now = utc(1794657600) // 2026-11-14 12:00 UTC (20:00 in Shanghai)
    let utcZone = TimeZone(identifier: "UTC")!
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let titles: [(SmsMessage, TimeZone, String)] = [
        (message([1], time: utc(1794616200)), utcZone, "+27838890001, 00:30"),            // 14th 00:30 UTC
        (message([1], time: utc(1794611400)), utcZone, "+27838890001, 2026-11-13 23:10"), // 13th 23:10 UTC
        (message([1], time: utc(1794611400)), shanghai, "+27838890001, 07:10"),          // 14th 07:10 there
        (message([1], time: utc(1794700200)), utcZone, "+27838890001, 23:50"),            // later today
        (message([1], time: utc(1794700200)), shanghai, "+27838890001, 2026-11-15 07:50"), // tomorrow there
        (message([1], time: utc(1735787040)), utcZone, "+27838890001, 2025-01-02 03:04"),
        (message([1], sender: "Alerts", time: nil), utcZone, "Alerts, no time"),
        (message([5], sender: "", time: nil, text: "", readable: false), utcZone, "unknown sender, no time"),
    ]
    for (m, zone, want) in titles {
        let got = rowTitle(m, now: now, timeZone: zone)
        check(got == want, "rowTitle: \(want) in \(zone.identifier)", "got \"\(got)\"")
    }

    // rowNote: what the row says besides the text.
    check(rowNote(message([1])) == "", "rowNote: complete")
    check(rowNote(message([1, 2], missing: 1)) == "1 part missing", "rowNote: one part missing")
    check(rowNote(message([1], missing: 2)) == "2 parts missing", "rowNote: two parts missing")
    check(rowNote(message([7], sender: "", text: "", readable: false)) == "not readable", "rowNote: not readable")

    // deleteQuestion: names the sender and counts every stored part.
    let two = deleteQuestion(message([3, 4], sender: "+111"))
    check(two.title == "Delete the message from +111?", "deleteQuestion: title", two.title)
    check(two.message == "2 stored parts will be deleted from the modem. This cannot be undone.",
          "deleteQuestion: two parts", two.message)
    let one = deleteQuestion(message([9], sender: ""))
    check(one.title == "Delete the message from an unknown sender?", "deleteQuestion: no sender", one.title)
    check(one.message == "1 stored part will be deleted from the modem. This cannot be undone.",
          "deleteQuestion: one part", one.message)

    // The key: indices, sender and time together.
    let a = message([1], unread: true, time: utc(1794616200))
    let b = message([2, 3], time: utc(1794611400))
    let c = message([4], time: nil)
    check(a.key == message([1], unread: false, time: utc(1794616200), text: "other").key,
          "key: the unread flag and the text are not part of it")
    check(a.key != message([1], sender: "+1", time: utc(1794616200)).key, "key: another sender")
    check(a.key != message([1], time: utc(1794611400)).key, "key: another time")
    check(b.key != message([2], time: utc(1794611400)).key, "key: other indices")

    // unreadMarks: unread now, or still marked from before and still listed.
    let gone = message([8], time: nil).key
    let marks = unreadMarks(listed: [a, b, c], kept: [b.key, gone])
    check(marks == [a.key, b.key], "unreadMarks: new unread plus kept, gone dropped", "\(marks)")
    check(unreadMarks(listed: [], kept: [a.key]).isEmpty, "unreadMarks: nothing listed")
    check(unreadMarks(listed: [b, c], kept: []).isEmpty, "unreadMarks: nothing unread")

    // listLine: the state of the list, never a send's or a delete's result.
    let updated = utc(1794657609) // 12:00:09 UTC, 20:00:09 in Shanghai
    let busy = "The modem's AT port is busy."
    let lines: [(Date?, String?, TimeZone, String)] = [
        (nil, nil, utcZone, ""),
        (updated, nil, utcZone, "Updated 12:00:09."),
        (updated, nil, shanghai, "Updated 20:00:09."),
        (updated, busy, utcZone, "The modem's AT port is busy. The list below may be out of date; it was updated 12:00:09."),
        (nil, busy, utcZone, "The modem's AT port is busy."),
    ]
    for (at, failure, zone, want) in lines {
        let got = listLine(updated: at, failure: failure, timeZone: zone)
        check(got == want, "listLine: \(want.isEmpty ? "nothing" : want)", "got \"\(got)\"")
    }

    // listLine with the store's use: after the update time; the warning from 90 %.
    let full = "The modem's message store is nearly full (230 of 255). Delete old messages, or new ones will not arrive."
    let storeLines: [(String?, Int?, Int?, String)] = [
        (nil, 22, 255, "Updated 12:00:09. 22 of 255 stored parts."),
        (nil, 229, 255, "Updated 12:00:09. 229 of 255 stored parts."),
        (nil, 230, 255, "Updated 12:00:09. 230 of 255 stored parts. " + full),
        (nil, nil, nil, "Updated 12:00:09."),
        (busy, 230, 255, "The modem's AT port is busy. The list below may be out of date; it was updated 12:00:09. "
                         + "230 of 255 stored parts. " + full),
    ]
    for (failure, used, total, want) in storeLines {
        let got = listLine(updated: updated, failure: failure, used: used, total: total, timeZone: utcZone)
        check(got == want, "listLine with the store: \(want)", "got \"\(got)\"")
    }
    check(listLine(updated: nil, failure: busy, used: 230, total: 255, timeZone: utcZone) == busy,
          "listLine: never listed, the store's use is not shown")

    // The store: its use, when it is nearly full (90 %), the warning, and the verb's first line.
    let stores: [(Int?, Int?, String, Bool, String)] = [
        (0, 255, "0 of 255 stored parts", false, "sms: 3 message(s), 0 of 255 stored parts used"),
        (229, 255, "229 of 255 stored parts", false, "sms: 3 message(s), 229 of 255 stored parts used"),
        (230, 255, "230 of 255 stored parts", true, "sms: 3 message(s), 230 of 255 stored parts used"),
        (255, 255, "255 of 255 stored parts", true, "sms: 3 message(s), 255 of 255 stored parts used"),
        (nil, nil, "", false, "sms: 3 message(s)"),
        (0, 0, "0 of 0 stored parts", false, "sms: 3 message(s), 0 of 0 stored parts used"),
    ]
    for (used, total, use, nearlyFull, headline) in stores {
        let name = "store \(used.map(String.init) ?? "unknown") of \(total.map(String.init) ?? "unknown")"
        check(storeUse(used: used, total: total) == use, "storeUse: \(name)", storeUse(used: used, total: total))
        check(storeNearlyFull(used: used, total: total) == nearlyFull, "storeNearlyFull: \(name)")
        let warning = storeWarning(used: used, total: total)
        let wantWarning = nearlyFull
            ? "The modem's message store is nearly full (\(used!) of \(total!)). Delete old messages, or new ones will not arrive."
            : ""
        check(warning == wantWarning, "storeWarning: \(name)", warning)
        check(listHeadline(count: 3, used: used, total: total) == headline, "listHeadline: \(name)",
              listHeadline(count: 3, used: used, total: total))
    }
    check(listHeadline(count: 0, used: 0, total: 255) == "sms: no messages, 0 of 255 stored parts used",
          "listHeadline: no messages, store known")
    check(listHeadline(count: 0, used: nil, total: nil) == "sms: no messages", "listHeadline: no messages, store unknown")

    // composeNote while an input method composes: Send waits for the input to be finished.
    check(composeNote("hello", composing: true) == "Finish the input being composed (the underlined text) before sending.",
          "composeNote: composing")
    check(composeNote("hello", composing: false) == "1 part, GSM alphabet", "composeNote: not composing")

    // listPlaceholder: what an empty list area says, from the list's state only.
    check(listPlaceholder(listed: false, failed: false) == "Reading the messages…", "listPlaceholder: first listing")
    check(listPlaceholder(listed: false, failed: true) == "The messages could not be read.", "listPlaceholder: failed")
    check(listPlaceholder(listed: true, failed: false) == "No messages on the modem.", "listPlaceholder: empty")
    check(listPlaceholder(listed: true, failed: true) == "No messages on the modem.", "listPlaceholder: empty, then failed")
}

@main
struct SmsModelTests {
    static func main() {
        // --- the classic vector ------------------------------------------------------------------
        expectPart(classic, "classic", sender: "27838890001", text: "hellohello", time: classicTime)

        // --- hand-built vectors ------------------------------------------------------------------
        expectPart(chinese, "UCS-2 Chinese, +8 h", sender: "+8613912345678", text: "你好世界", time: utc(1794623400))
        expectPart(alphanumeric, "alphanumeric sender, -5 h", sender: "Alerts", text: "Code 1234",
                   time: utc(1767618000))
        expectPart(national, "national sender", sender: "10086", text: "Balance 12.50", time: utc(1794650709))
        expectPart(withHeader, "7-bit with header and fill bit", sender: "+27838890001", text: "Hello world",
                   time: utc(1794657600), concat: SmsConcat(reference: 0x42, total: 2, sequence: 1))
        expectPart(extensionText, "extension characters", sender: "+27838890001", text: "€[]{}\\~^|",
                   time: classicTime)
        expectPart(emoji, "UCS-2 surrogate pair", sender: "+27838890001", text: "Hi 😀", time: classicTime)
        check(decode(emoji).text.unicodeScalars.last == "\u{1F600}", "surrogate pair joins into U+1F600")
        expectPart(concat16, "16-bit concatenation after a skipped element", sender: "+27838890001", text: "好",
                   time: classicTime, concat: SmsConcat(reference: 0x1234, total: 3, sequence: 2))
        expectPart(latin1, "8-bit as Latin-1", sender: "+27838890001", text: "café", time: classicTime)
        expectPart(classGroup, "class group 1111, 7-bit", sender: "27838890001", text: "hellohello",
                   time: classicTime)
        let kept = decode(classic, index: 17, status: .unread)
        check(kept.index == 17 && kept.status == .unread, "decodePart keeps index and status")

        // --- text from the modem is display-safe ---------------------------------------------------
        let r = "\u{FFFD}"
        // UCS-2: SMSC 00; first 04; sender 0B 91 7238880900F1; PID 00; DCS 08; classic time; UDL 28 (40
        // octets, 20 units): A ESC [ 2 J BEL BS U+009B U+202E U+2066 b TAB c CR LF d CR e DEL NUL.
        let hostileUcs2 = decode("00040B917238880900F1000899309251619580" + "28"
            + "0041001B005B0032004A00070008009B202E2066006200090063000D000A0064000D0065007F0000")
        check(hostileUcs2.readable && hostileUcs2.text == "A\(r)[2J\(r)\(r)\(r)\(r)\(r)b\tc\nd\ne\(r)\(r)",
              "UCS-2: ESC, BEL, BS, U+009B, bidi controls, DEL, NUL replaced; CR LF and CR to LF; tab kept",
              hostileUcs2.text.debugDescription)
        // 8-bit (DCS 04): UDL 23 (35 octets): "x", the 32 C1 bytes 80-9F, "y", E9 (é).
        let hostileLatin1 = decode("00040B917238880900F1000499309251619580" + "23" + "78"
            + "808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F" + "79E9")
        check(hostileLatin1.readable && hostileLatin1.text == "x" + String(repeating: r, count: 32) + "y\u{E9}",
              "8-bit: bytes 80-9F replaced, é kept", hostileLatin1.text.debugDescription)
        // Alphanumeric sender, 14 semi-octets = 8 septets: a CR b LF c ESC-0A (form feed) d, packed
        // 61 0D 62 0A 63 1B 0A 64 -> E1865831DE28C8 (packed by hand: septet n at bits 7n..7n+6).
        let hostileSender = decode("00040ED0E1865831DE28C80000993092516195800AE8329BFD4697D9EC37")
        check(hostileSender.readable && hostileSender.sender == "a\(r)b\(r)c\(r)d" && hostileSender.text == "hellohello",
              "alphanumeric sender: CR, LF and FF replaced", hostileSender.sender.debugDescription)
        // The function itself.
        check(displaySafe("a\r\nb\rc\nd", keepLineEnds: true) == "a\nb\nc\nd", "displaySafe: CR LF and CR to LF")
        check(displaySafe("a\tb", keepLineEnds: true) == "a\tb", "displaySafe: tab kept in a text")
        check(displaySafe("a\tb\r\nc", keepLineEnds: false) == "a\(r)b\(r)\(r)c", "displaySafe: a sender keeps no control")
        check(displaySafe("\u{1B}]0;title\u{07}", keepLineEnds: true) == "\(r)]0;title\(r)", "displaySafe: OSC replaced")
        check(displaySafe("\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}", keepLineEnds: true)
                == String(repeating: r, count: 9), "displaySafe: every bidi embedding, override and isolate replaced")
        check(displaySafe("\u{1F}\u{20}\u{7E}\u{7F}\u{9F}\u{A0}", keepLineEnds: true) == "\(r) ~\(r)\(r)\u{A0}",
              "displaySafe: the edges of the ranges")
        let ordinary = "你好世界 😀👍🏽 café Ñandú Ærø ﷺ ٱلسلام"
        check(displaySafe(ordinary, keepLineEnds: true) == ordinary && displaySafe(ordinary, keepLineEnds: false) == ordinary,
              "displaySafe: Chinese, emoji, accented and Arabic text untouched")

        // An invalid time stamp leaves the message readable without a time.
        // Month octet 31 = month 13.
        let month13 = decode("07917283010010F5040BC87238880900F10000993192516195800AE8329BFD4697D9EC37")
        check(month13.readable && month13.timestamp == nil && month13.text == "hellohello",
              "month 13: readable, no time", "\(month13)")
        // 99 20 03 = 1999-02-30, a day February does not have.
        let february30 = decode("07917283010010F5040BC87238880900F10000992003516195800AE8329BFD4697D9EC37")
        check(february30.readable && february30.timestamp == nil, "30 February: readable, no time", "\(february30)")

        // --- the alphabet table, position by position ---------------------------------------------
        // decodePart shows the lone CR (septet 0x0D) as LF; everything else is as the table has it.
        let table = decode(wholeTable)
        let shownTableText = wholeTableText.replacingOccurrences(of: "\r", with: "\n")
        check(table.readable && Array(table.text.unicodeScalars) == Array(shownTableText.unicodeScalars),
              "the 127 basic septets decode to TS 23.038's characters in order",
              "\(Array(table.text.unicodeScalars).count) scalars: \(table.text.debugDescription)")
        // "@£$_¤¡¿ÄΔ" by hand from TS 23.038: @ 00, £ 01, $ 02, _ 11, ¤ 24, ¡ 40, ¿ 60, Ä 5B, Δ 10.
        // 9 septets = 63 bits -> 8 octets 808020420282B710 (independent packer).
        // TPDU: 01 00 0B 91 7238880900F1 00 00 09 + 8 octets = 4 + 6 + 3 + 8 = 21.
        check(encodeSubmit(to: "+27838890001", text: "@\u{00A3}$_\u{00A4}\u{00A1}\u{00BF}\u{00C4}\u{0394}", reference: 0)
                == .success([SubmitPdu(hex: "0001000B917238880900F1000009" + "808020420282B710", tpduLength: 21)]),
              "encodeSubmit: non-ASCII GSM characters to their exact septets")

        // --- more data coding groups (TS 23.038 §4) ------------------------------------------------
        // The classic vector with DCS 40: group 01xx (automatic deletion), alphabet bits 00 = GSM 7-bit.
        expectPart("07917283010010F5040BC87238880900F10040993092516195800AE8329BFD4697D9EC37",
                   "DCS 40, group 01xx", sender: "27838890001", text: "hellohello", time: classicTime)
        // DCS C0: group 1100 (message waiting, discard), GSM 7-bit.
        expectPart("07917283010010F5040BC87238880900F100C0993092516195800AE8329BFD4697D9EC37",
                   "DCS C0, group 1100", sender: "27838890001", text: "hellohello", time: classicTime)
        // DCS D0: group 1101 (message waiting, store), GSM 7-bit.
        expectPart("07917283010010F5040BC87238880900F100D0993092516195800AE8329BFD4697D9EC37",
                   "DCS D0, group 1101", sender: "27838890001", text: "hellohello", time: classicTime)
        // The emoji vector with DCS E0: group 1110 (message waiting, store), UCS-2.
        expectPart("00" + "04" + "0B917238880900F1" + "00" + "E0" + "99309251619580" + "0A" + "004800690020D83DDE00",
                   "DCS E0, group 1110", sender: "+27838890001", text: "Hi 😀", time: classicTime)
        // DCS 80: group 1000 is reserved.
        expectUnreadable("07917283010010F5040BC87238880900F10080993092516195800AE8329BFD4697D9EC37",
                         "DCS 80, reserved group 1000")

        // --- an odd UCS-2 body: the emoji vector with UDL 0B and one extra octet 41 -----------------
        expectPart("00" + "04" + "0B917238880900F1" + "00" + "08" + "99309251619580" + "0B" + "004800690020D83DDE0041",
                   "odd UCS-2 body read without its last octet", sender: "+27838890001", text: "Hi 😀",
                   time: classicTime)

        // --- an alphanumeric sender padded to whole octets ------------------------------------------
        expectPart(alphaSender("0E"), "alphanumeric length 14: no phantom @", sender: "AlertsP", text: "hellohello",
                   time: classicTime)
        expectPart(alphaSender("0D"), "alphanumeric length 13", sender: "AlertsP", text: "hellohello",
                   time: classicTime)

        // --- not readable, no crash ----------------------------------------------------------------
        expectUnreadable("", "empty hex")
        expectUnreadable("0", "one hex digit")
        expectUnreadable(String(classic.dropLast()), "odd number of hex digits")
        expectUnreadable("07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC3G", "not hex")
        // Status report: 00 SMSC; 06 = TP-MTI 10 (SMS-STATUS-REPORT); 05 message reference;
        // 0B 91 7238880900F1 recipient; two time stamps; 00 status.
        expectUnreadable("00" + "06" + "05" + "0B917238880900F1" + "99309251619580" + "99309251619580" + "00",
                         "status report (TP-MTI 2)")
        // SMS-SUBMIT stored to send (TP-MTI 1, AT+CMGW): its recipient and text, no time. 00 SMSC; 01 SUBMIT; 00 TP-MR;
        // 0B 91 2120550521F3 recipient +12025550123 (made up); 00 PID; 00 DCS; 0A septets "hellohello".
        let stored = decode("0001000B912120550521F300000AE8329BFD4697D9EC37", index: 4, status: .sent)
        check(stored.readable && stored.sender == "+12025550123" && stored.text == "hellohello" && stored.timestamp == nil
                && stored.outgoing && stored.status == .sent, "SMS-SUBMIT stored: recipient and text", "\(stored)")
        check(!decode(classic, index: 1, status: .read).outgoing, "a received part is not outgoing")
        // The classic vector with DCS 0C: group 00xx, alphabet bits 11 = reserved.
        expectUnreadable("07917283010010F5040BC87238880900F1000C993092516195800AE8329BFD4697D9EC37",
                         "reserved alphabet")
        // DCS 20: group 00xx with the compressed bit.
        expectUnreadable("07917283010010F5040BC87238880900F10020993092516195800AE8329BFD4697D9EC37",
                         "compressed text")
        // The header vector with element length 04 where only 3 octets remain in the 5-octet header.
        expectUnreadable("07917283010010F5" + "44" + "0B917238880900F1" + "00" + "00" + "62114121000000" + "12"
                         + "050004420201" + "906536FB0DBABFE56C32", "header element past the header")
        // UDL 0xA1 = 161 septets, more than an SMS holds.
        expectUnreadable("07917283010010F5040BC87238880900F1000099309251619580A1" + String(repeating: "00", count: 141),
                         "user data length over 160")
        // An SMSC length that runs past the end.
        expectUnreadable("FF00", "SMSC length past the end")
        for (n, vector) in deliverVectors.enumerated() {
            var failedAt: Int? = nil
            for k in 0..<vector.utf8.count where decode(String(vector.prefix(k))).readable {
                failedAt = k
                break
            }
            check(failedAt == nil, "every prefix of DELIVER vector \(n) is unreadable",
                  "the prefix of \(failedAt ?? -1) hex digits read as a message")
        }

        // --- parseListing --------------------------------------------------------------------------
        let listing = parseListing(["AT+CMGL=4", "", "+CMGL: 3,0,,29", classic, "", "+CMGL: 7,1,,24",
                                    extensionText, "stray line", "+CMGL: 5,1,,24", "+CMGL: 6,0,,24", emoji,
                                    "+CMGL: x,0,,24", latin1, "+CMGL: 8,9,,24", latin1,
                                    "+CMGL: 9,1,,24", "OK"])
        check(listing.map { $0.index } == [3, 7, 6], "parseListing: indices", "\(listing)")
        check(listing.first == StoredPdu(index: 3, status: .unread, hex: classic), "parseListing: 3 is unread, its hex")
        check(listing.count > 1 && listing[1] == StoredPdu(index: 7, status: .read, hex: extensionText),
              "parseListing: 7 is read, its hex")
        check(parseListing(["+CMGL: 2,1,,29"]).isEmpty, "parseListing: no hex line after +CMGL, dropped")
        check(parseListing(["+CMGL: 2,1,,29", "OK"]).isEmpty, "parseListing: OK is not a hex line")
        check(parseListing(["+CMGL: 2,1,,29\r", "\(classic)\r"]) == [StoredPdu(index: 2, status: .read, hex: classic)],
              "parseListing: carriage returns trimmed")
        check(parseListing(["OK"]).isEmpty && parseListing([]).isEmpty, "parseListing: empty store")
        check(parseListing(["+CMGL: 3,0,,29", "+CMTI: \"ME\",4", classic])
                == [StoredPdu(index: 3, status: .unread, hex: classic)],
              "parseListing: an unsolicited line between header and hex is skipped")
        check(parseListing(["+CMGL: 3,0,,29", "+CMTI: \"ME\",4", "", "^RSSI: 5", classic, "+CMGL: 4,1,,24",
                            "+CDS: 6", emoji, "OK"])
                == [StoredPdu(index: 3, status: .unread, hex: classic), StoredPdu(index: 4, status: .read, hex: emoji)],
              "parseListing: several unsolicited lines, two entries")
        check(parseListing(["+CMGL: 3,0,,29", "+CMTI: \"ME\",4", "+CMGL: 4,1,,24", emoji])
                == [StoredPdu(index: 4, status: .read, hex: emoji)],
              "parseListing: a header without hex never takes the next header's hex")
        check(parseListing(["+CMGL: 99999999999999999999999,1,,29", classic]).isEmpty,
              "parseListing: an index past Int is dropped, no trap")

        // --- assemble ------------------------------------------------------------------------------
        let t0 = utc(1_699_999_000), t1 = utc(1_700_000_000), t2 = utc(1_700_000_100), t3 = utc(1_700_000_200)
        let ordered = assemble([part(10, "+111", t1, "C", (5, 3, 3)), part(11, "+111", t1, "A", (5, 3, 1)),
                                part(12, "+111", t1, "B", (5, 3, 2))])
        check(ordered.count == 1 && ordered.first?.text == "ABC" && ordered.first?.indices == [10, 11, 12]
                && ordered.first?.missingParts == 0 && ordered.first?.readable == true,
              "assemble: parts 3, 1, 2 give ABC", "\(ordered)")
        let duplicate = assemble([part(20, "+111", t1, "A", (6, 2, 1)), part(5, "+111", t1, "A", (6, 2, 1)),
                                  part(21, "+111", t1, "B", (6, 2, 2))])
        check(duplicate.count == 1 && duplicate.first?.text == "AB" && duplicate.first?.indices == [5, 20, 21]
                && duplicate.first?.missingParts == 0,
              "assemble: an identical duplicate is one message listing both indices", "\(duplicate)")
        // The same sequence with a different text is another message, even inside the time window.
        let clash = assemble([part(20, "+111", t1, "X", (6, 2, 1)), part(5, "+111", t1, "A", (6, 2, 1)),
                              part(21, "+111", t1, "B", (6, 2, 2))])
        check(clash.map { $0.text }.sorted() == ["AB", "X[...]"]
                && clash.first { $0.text == "AB" }?.indices == [5, 21]
                && clash.first { $0.text == "X[...]" }?.indices == [20],
              "assemble: a repeated sequence with a different text starts another message", "\(clash)")
        // The same sender, reference and total a day apart: two messages, each with its own indices and unread.
        let day = utc(1_700_086_400)
        let reused = assemble([part(1, "+111", t1, "A1", (9, 2, 1)), part(2, "+111", t1, "A2", (9, 2, 2)),
                               part(3, "+111", day, "B1", (9, 2, 1), status: .unread),
                               part(4, "+111", day, "B2", (9, 2, 2), status: .unread)])
        check(reused.count == 2 && reused[0] == SmsMessage(indices: [3, 4], unread: true, sender: "+111", timestamp: day,
                                                           text: "B1B2", missingParts: 0, readable: true)
                && reused[1] == SmsMessage(indices: [1, 2], unread: false, sender: "+111", timestamp: t1, text: "A1A2",
                                           missingParts: 0, readable: true),
              "assemble: a reference reused a day later is another message", "\(reused)")
        let minute = assemble([part(1, "+111", utc(1_700_000_060), "C", (3, 3, 3)),
                               part(2, "+111", utc(1_700_000_030), "B", (3, 3, 2)), part(3, "+111", t1, "A", (3, 3, 1))])
        check(minute.count == 1 && minute.first?.text == "ABC" && minute.first?.timestamp == t1,
              "assemble: three parts within a minute are one message", "\(minute)")
        let window = assemble([part(1, "+111", t1, "A", (3, 2, 1)), part(2, "+111", utc(1_700_000_900), "B", (3, 2, 2)),
                               part(3, "+111", t1, "C", (4, 2, 1)), part(4, "+111", utc(1_700_000_901), "D", (4, 2, 2))])
        check(window.map { $0.text }.sorted() == ["AB", "C[...]", "[...]D"],
              "assemble: 15 minutes joins, 15 minutes and 1 second does not", "\(window.map { $0.text })")
        let untimed = assemble([part(6, "+111", t1, "A", (8, 2, 1)), part(7, "+111", nil, "B", (8, 2, 2))])
        check(untimed.count == 1 && untimed.first?.text == "AB" && untimed.first?.indices == [6, 7],
              "assemble: a part without a time joins by sender, reference and total", "\(untimed)")
        // Every order of the same six parts gives the same messages.
        let six = [part(1, "+111", t1, "A", (9, 2, 1)), part(2, "+111", utc(1_700_000_010), "B", (9, 2, 2)),
                   part(3, "+111", day, "C", (9, 2, 1)), part(4, "+111", utc(1_700_086_405), "D", (9, 2, 2)),
                   part(5, "+111", utc(1_700_000_020), "A", (9, 2, 1)), part(6, "+111", utc(1_700_000_015), "X", (9, 2, 1))]
        let wantSix = assemble(six)
        check(wantSix.map { $0.text } == ["CD", "X[...]", "AB"] && wantSix.map { $0.indices } == [[3, 4], [6], [1, 2, 5]],
              "assemble: six colliding parts", "\(wantSix.map { "\($0.text) \($0.indices)" })")
        func permutations(_ items: [SmsPart]) -> [[SmsPart]] {
            guard let head = items.first else { return [[]] }
            return permutations(Array(items.dropFirst())).flatMap { rest in
                (0...rest.count).map { i -> [SmsPart] in var r = rest; r.insert(head, at: i); return r }
            }
        }
        let orders = permutations(six)
        check(orders.count == 720 && orders.allSatisfy { assemble($0) == wantSix },
              "assemble: the same result for all 720 orders of the input")
        let gap = assemble([part(1, "+111", t1, "A", (7, 3, 1)), part(3, "+111", t1, "C", (7, 3, 3))])
        check(gap.count == 1 && gap.first?.text == "A[...]C" && gap.first?.missingParts == 1 && gap.first?.indices == [1, 3],
              "assemble: a missing middle part", "\(gap)")
        let run = assemble([part(1, "+111", t1, "A", (7, 5, 1)), part(5, "+111", t1, "E", (7, 5, 5))])
        check(run.first?.text == "A[...]E" && run.first?.missingParts == 3,
              "assemble: a run of missing parts is one [...], each counted", "\(run)")
        let hostile = assemble([part(1, "+111", t1, "A", (7, 255, 1))])
        check(hostile.first?.text == "A[...]" && hostile.first?.missingParts == 254,
              "assemble: a total of 255 with one part", "\(hostile)")
        let senders = assemble([part(1, "+111", t1, "A", (9, 2, 1)), part(2, "+222", t2, "B", (9, 2, 1))])
        check(senders.count == 2 && senders.allSatisfy { $0.missingParts == 1 },
              "assemble: two senders with the same reference and total kept apart", "\(senders)")
        let totals = assemble([part(1, "+111", t1, "A", (9, 2, 1)), part(2, "+111", t1, "B", (9, 3, 2))])
        check(totals.count == 2, "assemble: same reference, different totals kept apart", "\(totals)")
        let unreadPart = assemble([part(1, "+111", t1, "A", (4, 2, 1)),
                                   part(2, "+111", t1, "B", (4, 2, 2), status: .unread)])
        check(unreadPart.first?.unread == true, "assemble: unread when any part is unread")
        let unreadable = SmsPart(index: 2, status: .unread, sender: "", timestamp: nil, text: "", concat: nil,
                                 readable: false)
        let mixed = assemble([part(4, "+111", t0, "old"), unreadable, part(9, "+333", nil, "no time"),
                              part(6, "+222", t3, "new"), part(7, "+111", t2, "Z", (1, 2, 2)),
                              part(3, "+111", t1, "Y", (1, 2, 1))])
        check(mixed.map { $0.text } == ["new", "YZ", "old", "", "no time"],
              "assemble: newest first, entries without a time last by index", "\(mixed.map { $0.text })")
        check(mixed.count == 5 && mixed[1].timestamp == t1 && mixed[1].indices == [3, 7],
              "assemble: a multi-part message takes its earliest part's time", "\(mixed)")
        check(mixed.count == 5 && mixed[3] == SmsMessage(indices: [2], unread: true, sender: "", timestamp: nil, text: "",
                                                        missingParts: 0, readable: false),
              "assemble: an unreadable entry is a message by itself", "\(mixed)")
        check(mixed.first?.unread == false && mixed.first?.sender == "+222", "assemble: a single part keeps its sender")
        check(assemble([]).isEmpty, "assemble: nothing")
        let fromPdus = assemble(parseListing(["+CMGL: 1,1,,24", withHeader, "+CMGL: 2,0,,29", classic]).map(decodePart))
        check(fromPdus.map { $0.text } == ["Hello world[...]", "hellohello"] && fromPdus.first?.missingParts == 1,
              "assemble: from the listing through decodePart", "\(fromPdus)")

        // --- chooseEncoding and partCount ----------------------------------------------------------
        check(chooseEncoding("hello") == .gsm7, "chooseEncoding: ASCII letters are GSM")
        check(chooseEncoding("€[]{}\\~^|\u{000C}") == .gsm7, "chooseEncoding: the extension table is GSM")
        check(chooseEncoding("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ!\"#¤%&'()*+,-./:;<=>?¡ÄÖÑÜ§¿äöñüà") == .gsm7,
              "chooseEncoding: the whole basic table is GSM")
        check(chooseEncoding("你好") == .ucs2, "chooseEncoding: Chinese is UCS-2")
        check(chooseEncoding("ç") == .ucs2, "chooseEncoding: lower-case c cedilla is not in the GSM table")
        check(chooseEncoding("`") == .ucs2, "chooseEncoding: backtick is not in the GSM table")
        check(partCount("") == 0, "partCount: empty text is 0")
        let a = { (n: Int) in String(repeating: "a", count: n) }
        let zh = { (n: Int) in String(repeating: "中", count: n) }
        check(partCount(a(160)) == 1, "partCount: 160 GSM characters, 1 part")
        check(partCount(a(161)) == 2, "partCount: 161 GSM characters, 2 parts")
        check(partCount(a(158) + "€") == 1, "partCount: 158 + € is 160 septets, 1 part")
        check(partCount(a(159) + "€") == 2, "partCount: 160 characters with a € are 161 septets, 2 parts")
        check(partCount(a(306)) == 2 && partCount(a(307)) == 3, "partCount: 153 septets per part")
        check(partCount(zh(70)) == 1, "partCount: 70 Chinese characters, 1 part")
        check(partCount(zh(71)) == 2, "partCount: 71 Chinese characters, 2 parts")
        check(partCount(zh(134)) == 2 && partCount(zh(135)) == 3, "partCount: 67 units per part")
        check(partCount(String(repeating: "😀", count: 35)) == 1 && partCount(String(repeating: "😀", count: 36)) == 2,
              "partCount: an emoji is two units")

        // An escape pair at the boundary: 152 a then € (2 septets) would be 154 > 153, so € moves whole.
        let euroEdge = encodeSubmit(to: "+27838890001", text: a(152) + "€" + a(10), reference: 1)
        if case .success(let pdus) = euroEdge, pdus.count == 2,
           let first = readSubmit(pdus[0].hex), let second = readSubmit(pdus[1].hex) {
            check(first.text == a(152) && second.text == "€" + a(10), "escape pair at a part boundary moves whole",
                  "\(first.text.count), \(second.text)")
        } else {
            check(false, "escape pair at a part boundary: two parts", "\(euroEdge)")
        }
        // A surrogate pair at the boundary: 66 中 then 😀 (2 units) would be 68 > 67, so 😀 moves whole.
        let pairEdge = encodeSubmit(to: "+27838890001", text: zh(66) + "😀" + zh(10), reference: 1)
        if case .success(let pdus) = pairEdge, pdus.count == 2,
           let first = readSubmit(pdus[0].hex), let second = readSubmit(pdus[1].hex) {
            check(first.text == zh(66) && second.text == "😀" + zh(10), "surrogate pair at a part boundary moves whole",
                  "\(first.text), \(second.text)")
        } else {
            check(false, "surrogate pair at a part boundary: two parts", "\(pairEdge)")
        }

        // --- encodeSubmit --------------------------------------------------------------------------
        // The plan's vector: 00 SMSC; 01 SUBMIT; 00 MR; 0B 91 7238880900F1; 00 PID; 00 DCS; 0A UDL; text.
        check(encodeSubmit(to: "+27838890001", text: "hellohello", reference: 0)
                == .success([SubmitPdu(hex: "0001000B917238880900F100000AE8329BFD4697D9EC37", tpduLength: 22)]),
              "encodeSubmit: hellohello to +27838890001", "\(encodeSubmit(to: "+27838890001", text: "hellohello", reference: 0))")
        // No "+": 0A digits, type 81, "08 38 89 00 01" swapped = 80 83 98 00 10; "hello" = E8329BFD06 (35 bits).
        // TPDU: 01 00 0A 81 8083980010 00 00 05 E8329BFD06 = 4 + 5 + 3 + 5 = 17 octets.
        check(encodeSubmit(to: "0838890001", text: "hello", reference: 0)
                == .success([SubmitPdu(hex: "0001000A81" + "8083980010" + "0000" + "05" + "E8329BFD06", tpduLength: 17)]),
              "encodeSubmit: a number without + uses type 81",
              "\(encodeSubmit(to: "0838890001", text: "hello", reference: 0))")
        // UCS-2: 01 00 0B 91 7238880900F1 00 08 04 4F60 597D = 4 + 6 + 3 + 4 = 17 octets.
        check(encodeSubmit(to: "+27838890001", text: "你好", reference: 0)
                == .success([SubmitPdu(hex: "0001000B917238880900F10008044F60597D", tpduLength: 17)]),
              "encodeSubmit: UCS-2 single part", "\(encodeSubmit(to: "+27838890001", text: "你好", reference: 0))")
        // Multi-part GSM: first octet 41 (SUBMIT + UDHI); part 1 UDL A0 = 160 = 7 header septets + 153;
        // header 05 00 03 2A 02 01; part 2 UDL 0F = 7 + 8.
        if case .success(let pdus) = encodeSubmit(to: "+27838890001", text: a(161), reference: 0x2A), pdus.count == 2 {
            check(pdus[0].hex.hasPrefix("0041000B917238880900F10000A00500032A0201"), "encodeSubmit: part 1 header", pdus[0].hex)
            check(pdus[1].hex.hasPrefix("0041000B917238880900F100000F0500032A0202"), "encodeSubmit: part 2 header", pdus[1].hex)
            check(pdus[0].tpduLength == 13 + 140, "encodeSubmit: a full 7-bit part is 140 octets of user data",
                  "\(pdus[0].tpduLength)")
        } else {
            check(false, "encodeSubmit: 161 characters are 2 parts")
        }
        check(encodeSubmit(to: "+27838890001", text: a(153 * 10), reference: 0).map { $0.count } == .success(10),
              "encodeSubmit: 10 parts are allowed")
        if case .failure(let f) = encodeSubmit(to: "+27838890001", text: a(153 * 10 + 1), reference: 0) {
            check(f.message.contains("too long"), "encodeSubmit: 11 parts, the failure says too long", f.message)
        } else {
            check(false, "encodeSubmit: 11 parts are a failure")
        }
        check(encodeSubmit(to: "+27838890001", text: zh(67 * 11), reference: 0).map { $0.count }
                == .failure(SmsFailure(message: "The message is too long: it needs 11 parts and at most 10 can be sent.")),
              "encodeSubmit: 11 UCS-2 parts are a failure")
        for bad in ["", "12", "+12", "+12a45", "+1 234 567", "++123", "1234567890123456789012"] {
            if case .failure = encodeSubmit(to: bad, text: "hi", reference: 0) {
                check(true, "encodeSubmit: invalid number \"\(bad)\"")
            } else {
                check(false, "encodeSubmit: invalid number \"\(bad)\" is a failure")
            }
        }
        if case .failure = encodeSubmit(to: "+27838890001", text: "", reference: 0) {
            check(true, "encodeSubmit: empty text is a failure")
        } else {
            check(false, "encodeSubmit: empty text is a failure")
        }

        // Round trip over generated texts with a fixed seed: GSM only, GSM with the extension
        // table, and mixed with characters that force UCS-2 (including surrogate pairs).
        let basicPool = Array("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà".unicodeScalars)
        let extensionPool = Array("\u{000C}^{}\\[~]|€".unicodeScalars)
        let widePool = Array("你好世界中文短信çÿЖ😀🎉👍".unicodeScalars)
        var random = SplitMix(state: 20261114)
        var roundTrips = 0, tooLong = 0
        for n in 0..<300 {
            let kind = n % 3
            let length = 1 + random.below(kind == 0 ? 1530 : kind == 1 ? 900 : 650)
            var scalars = String.UnicodeScalarView()
            for _ in 0..<length {
                let pick = random.below(10)
                if kind >= 1 && pick == 0 {
                    scalars.append(extensionPool[random.below(extensionPool.count)])
                } else if kind == 2 && pick <= 3 {
                    scalars.append(widePool[random.below(widePool.count)])
                } else {
                    scalars.append(basicPool[random.below(basicPool.count)])
                }
            }
            let text = String(scalars)
            let reference = UInt8(truncatingIfNeeded: n)
            let parts = partCount(text)
            switch encodeSubmit(to: "+27838890001", text: text, reference: reference) {
            case .success(let pdus):
                let back = readBack(pdus, reference: Int(reference), number: "+27838890001")
                guard pdus.count == parts, parts <= 10, let b = back,
                      Array(b.unicodeScalars) == Array(text.unicodeScalars) else {
                    check(false, "round trip text \(n)", "kind \(kind), length \(length), parts \(parts)/\(pdus.count)")
                    continue
                }
                roundTrips += 1
            case .failure(let f):
                guard parts > 10, f.message.contains("too long") else {
                    check(false, "round trip text \(n): unexpected failure", f.message)
                    continue
                }
                tooLong += 1
            }
        }
        check(roundTrips >= 200, "round trip: at least 200 texts read back the same", "\(roundTrips) of 300")
        check(roundTrips + tooLong == 300, "round trip: every text either reads back or is too long",
              "\(roundTrips) + \(tooLong)")

        // --- validNumber ---------------------------------------------------------------------------
        for good in ["+27838890001", "10086", "123", "+123", String(repeating: "9", count: 20),
                     "+" + String(repeating: "9", count: 20)] {
            check(validNumber(good), "validNumber: \"\(good)\" is valid")
        }
        for bad in ["", "+", "12", "+12", String(repeating: "9", count: 21), "+1 234", "12-34", "123+",
                    "１２３", "+٣٤٥"] {
            check(!validNumber(bad), "validNumber: \"\(bad)\" is not valid")
        }

        // --- parseSendReference --------------------------------------------------------------------
        check(parseSendReference(["AT+CMGS=22", "> ", "+CMGS: 12", "", "OK"]) == 12, "parseSendReference: 12")
        check(parseSendReference(["+CMGS: 0,\"99/03/29,15:16:59+08\""]) == 0, "parseSendReference: with a time after it")
        check(parseSendReference(["+CMGS: 256"]) == nil, "parseSendReference: 256 is out of range")
        check(parseSendReference(["+CMGS: x"]) == nil, "parseSendReference: not a number")
        check(parseSendReference(["+CMS ERROR: 500"]) == nil && parseSendReference([]) == nil,
              "parseSendReference: an error")

        // --- parseStorage --------------------------------------------------------------------------
        let storage = parseStorage(["AT+CPMS?", "+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255", "OK"])
        check(storage?.used == 0 && storage?.total == 255, "parseStorage: ME 0 of 255", "\(String(describing: storage))")
        let unnamed = parseStorage(["+CPMS: 3,255,3,255,3,255"])
        check(unnamed?.used == 3 && unnamed?.total == 255, "parseStorage: without names", "\(String(describing: unnamed))")
        check(parseStorage(["+CPMS: \"ME\",x,255"]) == nil, "parseStorage: not a number")
        check(parseStorage(["+CPMS: \"ME\",300,255"]) == nil, "parseStorage: more used than there is")
        check(parseStorage(["+CPMS: \"ME\""]) == nil, "parseStorage: no numbers")
        check(parseStorage(["OK"]) == nil && parseStorage([]) == nil, "parseStorage: no +CPMS line")

        windowHelperChecks()
        readingPaneHelpers()
        storedSending()
        mmsNotificationsAndUnblock()

        print("sms-test: \(checks) checks passed")
    }

    /// The list's heading and the reading pane's Copy Code.
    static func readingPaneHelpers() {
        check(messageCountLine(count: 0, unread: 0) == "", "count line: none")
        check(messageCountLine(count: 1, unread: 0) == "1 message", "count line: one")
        check(messageCountLine(count: 3, unread: 1) == "3 messages · 1 unread", "count line: with unread")

        let found: [(String, String)] = [
            ("Your verification code is 482913. It expires in 10 minutes.", "482913"),
            ("Code 1234", "1234"),
            ("\u{9A8C}\u{8BC1}\u{7801}\u{FF1A}384920\u{FF0C}5\u{5206}\u{949F}\u{5185}\u{6709}\u{6548}\u{3002}", "384920"),  // a Chinese code message, as escapes
            ("Your OTP: 00112233", "00112233"),
            ("G-482913 is your Google verification code.", "482913"),
        ]
        for (text, code) in found {
            check(verificationCode(in: text) == code, "code: \(text)", "got \(String(describing: verificationCode(in: text)))")
        }
        let none = [
            "T-Mobile: You have used 75% of your high-speed data for this bill cycle.",   // no code word
            "Running late, see you at the station around six.",
            "Your code is 1234, reference 5678.",                                           // two groups
            "Call +12025550123 about your code.",                                           // a phone number
            "Pay $1500 with code word",                                                     // an amount
            "Your balance 1234.56; PIN unchanged",                                          // a decimal
            "Your code is 123.",                                                            // too short
            "Order #123456 code",                                                           // an order number
            "Call 555-1234 for a new PIN",                                                  // a phone number
        ]
        for text in none {
            check(verificationCode(in: text) == nil, "no code: \(text)", "got \(String(describing: verificationCode(in: text)))")
        }
    }

    /// Messages RMNet stored to send: the listing with every status, their box, multi-part sent messages with an unsent
    /// part, and the answers of AT+CMGW, AT+CMSS, AT+CMGR and AT+CPMS's storage names.
    static func storedSending() {
        // A sent and an unsent message among received ones; the same text sent to the same number as two parts.
        guard case .success(let pdus) = encodeSubmit(to: "+12025550100", text: String(repeating: "made-up ", count: 25),
                                                     reference: 7), pdus.count == 2,
              case .success(let one) = encodeSubmit(to: "+12025550199", text: "Made-up reply", reference: 1) else {
            check(false, "stored: the PDUs encode")
            return
        }
        // A received one: 00 SMSC; 04 DELIVER; 0B 91 2120550521F0 sender +12025550120 (made up); 00 PID; 00 DCS;
        // 62112201000000 2026-11-22 10:00:00 +00; 0A septets "hellohello".
        let delivered = "0004" + "0B912120550521F0" + "0000" + "62112201000000" + "0AE8329BFD4697D9EC37"
        let lines = ["+CMGL: 0,1,,\(delivered.count / 2 - 1)", delivered,
                     "+CMGL: 1,3,,\(one[0].tpduLength)", one[0].hex,
                     "+CMGL: 2,3,,\(pdus[0].tpduLength)", pdus[0].hex,
                     "+CMGL: 3,2,,\(pdus[1].tpduLength)", pdus[1].hex,
                     "+CMGL: 4,2,,\(one[0].tpduLength)", one[0].hex]
        let parsed = parseListing(lines)
        equal(parsed.map { $0.status }, [.read, .sent, .sent, .unsent, .unsent], "stored: the statuses listed")
        let messages = assemble(parsed.map(decodePart))
        equal(messages.count, 4, "stored: received, sent, a two-part message, and an unsent one")
        let received = messages.first { $0.indices == [0] }
        check(received?.box == .received && received?.outgoing == false && received?.sender == "+12025550120",
              "stored: received")
        let sent = messages.first { $0.indices == [1] }
        check(sent?.box == .sent && sent?.sender == "+12025550199" && sent?.text == "Made-up reply" && sent?.unread == false
                && sent?.timestamp == nil && sent?.unsentIndices == [], "stored: sent", "\(String(describing: sent))")
        let twoParts = messages.first { $0.indices == [2, 3] }
        check(twoParts?.box == .unsent && twoParts?.unsentIndices == [3] && twoParts?.missingParts == 0
                && twoParts?.text == String(repeating: "made-up ", count: 25), "stored: two parts, one unsent",
              "\(String(describing: twoParts))")
        let unsent = messages.first { $0.indices == [4] }
        check(unsent?.box == .unsent && unsent?.unsentIndices == [4] && unsent?.unread == false, "stored: unsent")
        // A sent part and a received part with the same key never merge.
        check(messages.allSatisfy { m in m.box == .received || m.sender != "+12025550120" }, "stored: directions kept apart")

        check(parseStoreIndex(["+CMGW: 5"]) == 5 && parseStoreIndex(["OK"]) == nil && parseStoreIndex(["+CMGW: x"]) == nil,
              "parse: +CMGW")
        check(parseStoredSendReference(["+CMSS: 12"]) == 12 && parseStoredSendReference(["+CMSS: 12,\"0011\""]) == 12
                && parseStoredSendReference(["+CMSS: 300"]) == nil && parseStoredSendReference([]) == nil, "parse: +CMSS")
        let read = parseReadEntry(["+CMGR: 2,,23", one[0].hex])
        check(read?.status == .unsent && read?.hex == one[0].hex, "parse: +CMGR status and PDU")
        check(parseReadEntry(["+CMGR: 3,,23"]) == nil, "parse: +CMGR without its PDU")
        let names = parseStorageNames(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"])
        check(names?.read == "ME" && names?.write == "ME", "parse: CPMS names")
        let mixed = parseStorageNames(["+CPMS: \"SM\",0,50,\"ME\",3,255,\"ME\",3,255"])
        check(mixed?.read == "SM" && mixed?.write == "ME", "parse: CPMS names that differ")
        check(parseStorageNames(["+CPMS: 3,255,3,255,3,255"]) == nil, "parse: CPMS without names")

        // `sms list`: sent and unsent messages listed with their recipient; JSON's added status, the other keys kept.
        let listing = SmsListing(messages: messages, used: 5, total: 255)
        let printed = smsListLines(listing, time: { _ in "2026-11-22 10:00:00" })
        check(printed.contains("[1] sent to +12025550199 no time") && printed.contains("[2,3] unsent to +12025550100 no time")
                && printed.contains("[4] unsent to +12025550199 no time")
                && printed.contains("[0] read +12025550120 2026-11-22 10:00:00"),
              "sms list: the lines", printed.joined(separator: " | "))
        let json = smsListJSON(messages, time: { _ in "t" })
        check(JSONSerialization.isValidJSONObject(json), "sms list --json: valid")
        let sentJSON = json.first { ($0["indices"] as? [Int]) == [1] }
        equal(sentJSON?["status"] as? String, "sent", "sms list --json: status sent")
        check(sentJSON?["time"] is NSNull && sentJSON?["sender"] as? String == "+12025550199", "sms list --json: no time, the recipient")
        equal(json.first { ($0["indices"] as? [Int]) == [0] }?["status"] as? String, "received", "sms list --json: status received")
        equal(Set(sentJSON?.keys.map { $0 } ?? []),
              ["indices", "unread", "sender", "time", "text", "missingParts", "readable", "status", "notConfirmed"],
              "sms list --json: the keys (notConfirmed added)")
    }

    /// WAP Push MMS notifications (single-part and multi-part) and `sms unblock` parsing and output.
    static func mmsNotificationsAndUnblock() {
        func hexBytes(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        func deliverWapPush(outerSenderHex: String = "04813200", udh: [UInt8], payload: [UInt8],
                            timeHex: String = "62112201510000") -> String {
            let ud = udh + payload
            return "0044" + outerSenderHex + "0004" + timeHex + String(format: "%02X", ud.count) + hexBytes(ud)
        }

        let portUdh: [UInt8] = [0x06, 0x05, 0x04, 0x0B, 0x84, 0x23, 0xF0]
        let wspHead: [UInt8] = [0x01, 0x06, 0x03, 0xBE, 0xAF, 0x84]

        // 1. Single-part MMS notification with address-present token (0x80) and PLMN suffix.
        let fromPlmn = [UInt8(0x80)] + Array("12025550144/TYPE=PLMN".utf8) + [0x00]
        let mmsBody1: [UInt8] = [0x8C, 0x82, 0x98] + Array("tx1".utf8) + [0x00, 0x8D, 0x90,
                                 0x89, UInt8(fromPlmn.count)] + fromPlmn
            + [0x83] + Array("http://mmsc.example.invalid/m1".utf8) + [0x00]
        let singleHex = deliverWapPush(udh: portUdh, payload: wspHead + mmsBody1)
        let singleMsg = assemble([decodePart(StoredPdu(index: 7, status: .unread, hex: singleHex))])
        equal(singleMsg.count, 1, "mms single: one message")
        check(singleMsg.first?.readable == true && singleMsg.first?.unread == true
                && singleMsg.first?.sender == "12025550144"
                && singleMsg.first?.text == mmsNotificationText && singleMsg.first?.timestamp != nil,
              "mms single: decoded sender, text and time", "\(String(describing: singleMsg.first))")

        // 2. MMS From encoded with Value-length + Well-known-charset UTF-8 (0xEA).
        let utf8Addr = [UInt8(0xEA)] + Array("+12025550177/TYPE=PLMN".utf8) + [0x00]
        let fromCharset = [UInt8(0x80), UInt8(utf8Addr.count)] + utf8Addr
        let mmsBody2: [UInt8] = [0x8C, 0x82, 0x8D, 0x90, 0x89, UInt8(fromCharset.count)] + fromCharset
        let charsetHex = deliverWapPush(udh: portUdh, payload: wspHead + mmsBody2)
        let charsetMsg = assemble([decodePart(StoredPdu(index: 8, status: .unread, hex: charsetHex))])
        equal(charsetMsg.first?.sender, "+12025550177", "mms charset From: sender")

        // 3. Insert-address-token (0x81) in From falls back to the outer TP-OA ("2300").
        let mmsBodyAnon: [UInt8] = [0x8C, 0x82, 0x8D, 0x90, 0x89, 0x01, 0x81]
        let anonHex = deliverWapPush(udh: portUdh, payload: wspHead + mmsBodyAnon)
        let anonMsg = assemble([decodePart(StoredPdu(index: 9, status: .unread, hex: anonHex))])
        check(anonMsg.first?.sender == "2300" && anonMsg.first?.text == mmsNotificationText,
              "mms anonymous From: outer sender kept", "\(String(describing: anonMsg.first))")

        // 4. Non-MMS WAP Push on port 2948 (for example text/vnd.wap.si, 0xB5) stays unreadable.
        let nonMmsHex = deliverWapPush(udh: portUdh, payload: [0x01, 0x06, 0x01, 0xB5, 0x02, 0x05, 0x6A, 0x00])
        let nonMmsMsg = assemble([decodePart(StoredPdu(index: 12, status: .unread, hex: nonMmsHex))])
        check(nonMmsMsg.first?.readable == false, "non-MMS WAP Push: not readable")

        // 5. Two-part concatenated WAP Push MMS notification reassembles across parts 1 and 2.
        let fullPush = wspHead + mmsBody2
        let splitAt = fullPush.count / 2
        let concatUdh1: [UInt8] = [0x0B, 0x00, 0x03, 0x42, 0x02, 0x01, 0x05, 0x04, 0x0B, 0x84, 0x23, 0xF0]
        let concatUdh2: [UInt8] = [0x0B, 0x00, 0x03, 0x42, 0x02, 0x02, 0x05, 0x04, 0x0B, 0x84, 0x23, 0xF0]
        let part1 = StoredPdu(index: 10, status: .unread,
                              hex: deliverWapPush(udh: concatUdh1, payload: Array(fullPush[..<splitAt])))
        let part2 = StoredPdu(index: 11, status: .unread,
                              hex: deliverWapPush(udh: concatUdh2, payload: Array(fullPush[splitAt...])))
        let joined = assemble([decodePart(part2), decodePart(part1)])
        equal(joined.count, 1, "mms two-part: assembled into one message")
        check(joined.first?.indices == [10, 11] && joined.first?.missingParts == 0
                && joined.first?.sender == "+12025550177" && joined.first?.text == mmsNotificationText,
              "mms two-part: indices, sender and text", "\(String(describing: joined.first))")

        // 6. parseCnmi, parseSms("unblock"), assembleUnblocked, sentences and JSON.
        check(parseCnmi(["+CNMI: 2,1,0,0,0", "OK"])?.mode == 2 && parseCnmi(["+CNMI: 2,1,0,0,0"])?.mt == 1,
              "parseCnmi: 2,1")
        check(parseCnmi(["+CNMI: 2,2,0,0,0"])?.mt == 2 && parseCnmi(["OK"]) == nil && parseCnmi(["+CNMI: x,1"]) == nil,
              "parseCnmi: 2,2 and invalid")

        equal(parseSms(["unblock"]), .unblock(seconds: 95, json: false), "parseSms: unblock default")
        equal(parseSms(["unblock", "--json"]), .unblock(seconds: 95, json: true), "parseSms: unblock --json")
        equal(parseSms(["unblock", "30", "--json"]), .unblock(seconds: 30, json: true), "parseSms: unblock 30 --json")
        equal(parseSms(["unblock", "--json", "180"]), .unblock(seconds: 180, json: true), "parseSms: unblock --json 180")
        check(parseSms(["unblock", "0"]) == nil && parseSms(["unblock", "181"]) == nil
                && parseSms(["unblock", "--json", "--json"]) == nil && parseSms(["unblock", "10", "20"]) == nil,
              "parseSms: unblock wrong usage")

        let ordinaryHex = "0004" + "0B912120550561F1" + "0000" + "62112201610000" + "02C834"
        let unblocked = assembleUnblocked([StoredPdu(index: 7, status: .unread, hex: singleHex),
                                           StoredPdu(index: 8, status: .unread, hex: ordinaryHex)], restoredCnmi: false)
        check(unblocked.stored == 2 && unblocked.mmsNotifications == 1 && unblocked.indices == [7, 8]
                && unblocked.messages.allSatisfy { $0.unread }, "assembleUnblocked: counts and unread")
        equal(smsUnblockSentence(unblocked), "Unblocked incoming messages: stored 2 part(s) (1 MMS notification).",
              "smsUnblockSentence: stored with MMS")
        let quietHealed = assembleUnblocked([], restoredCnmi: true)
        equal(smsUnblockSentence(quietHealed),
              "Restored incoming message storage (AT+CNMI=2,1,0,0,0); no queued messages arrived.",
              "smsUnblockSentence: healed CNMI")
        let cliLines = smsUnblockLines(unblocked, seconds: 75, time: { _ in "2026-11-22 10:15:00" })
        check(cliLines.first == "sms: unblocked: stored 2 part(s), 2 message(s) (1 MMS notification)"
                && cliLines.contains("  \(mmsNotificationText)"), "smsUnblockLines: summary and MMS text",
              cliLines.joined(separator: " | "))
        let ujson = smsUnblockJSON(unblocked, time: { _ in "2026-11-22T10:15:00Z" })
        check(JSONSerialization.isValidJSONObject(ujson) && ujson["storedParts"] as? Int == 2
                && ujson["mmsNotifications"] as? Int == 1 && ujson["indices"] as? [Int] == [7, 8]
                && ujson["restoredCnmi"] as? Bool == false, "smsUnblockJSON: valid and keys")
    }
}
