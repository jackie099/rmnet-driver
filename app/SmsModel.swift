// The pure SMS message model: reading the AT text the modem answers in PDU mode, decoding the
// SMS-DELIVER PDUs it received and the SMS-SUBMIT PDUs stored to send (AT+CMGW, AT+CMSS), assembling
// multi-part messages, and encoding SMS-SUBMIT PDUs.
// Formats: 3GPP TS 23.040 (PDUs, addresses, user data header, time stamp), TS 23.038 (the GSM 7-bit
// default alphabet and its extension table, septet packing, the data coding scheme), TS 27.005
// (+CMGL, +CMGS, +CPMS). No I/O here; every function is total and never traps on any input.
import Foundation

enum SmsStatus: Int { case unread = 0, read = 1, unsent = 2, sent = 3 }

/// Which way a message went: received (stored REC UNREAD or REC READ), or written by RMNet and sent (STO SENT) or not
/// sent (STO UNSENT: written, and its AT+CMSS failed or did not run).
enum SmsBox: String, Equatable { case received, sent, unsent }

struct StoredPdu: Equatable { let index: Int; let status: SmsStatus; let hex: String }

struct SmsConcat: Equatable { let reference: Int; let total: Int; let sequence: Int }

/// The text shown for a stored MMS notification (WAP Push to port 2948, OMA MMS m-notification-ind).
let mmsNotificationText = "MMS notification (not supported)"

/// One stored entry, decoded or not.
struct SmsPart: Equatable {
    let index: Int
    let status: SmsStatus
    let sender: String     // the other party: who sent it, or for a stored SMS-SUBMIT whom it is for; "" when not readable
    let timestamp: Date?   // the service centre's time, nil when absent or invalid
    let text: String       // "" when not readable
    let concat: SmsConcat?
    let readable: Bool     // false: neither an SMS-DELIVER nor an SMS-SUBMIT, or malformed
    var wapPush: [UInt8]? = nil  // octets of a multi-part WAP Push to port 2948, joined in assemble()

    /// Stored to send (STO SENT or STO UNSENT), not received.
    var outgoing: Bool { status == .sent || status == .unsent }
}

struct SmsMessage: Equatable {
    let indices: [Int]     // every stored index of the message, ascending
    let unread: Bool       // any part was unread when listed (received messages only)
    let sender: String     // the other party: the sender of a received message, the recipient of a sent one
    let timestamp: Date?   // the service centre's time of a received message; nil for a sent one (SMS-SUBMIT has none)
    let text: String
    let missingParts: Int  // 0 when complete
    let readable: Bool
    var box: SmsBox = .received
    var unsentIndices: [Int] = []   // the stored parts still STO UNSENT, ascending (Retry sends them)

    var outgoing: Bool { box != .received }
}

enum SmsEncoding { case gsm7, ucs2 }

/// tpduLength: octets after the SMSC field (what AT+CMGS takes).
struct SubmitPdu: Equatable { let hex: String; let tpduLength: Int }

/// A sentence for the owner. `listingChanged`: what the window listed is no longer what the modem has (another module or
/// SIM, another storage, or a stored part that changed), so nothing was done and the window lists again. `record`: what
/// became of the parts of a send that failed part way (SmsSendRecord). `reachedModem`: a part of the message went, or
/// may have, or is stored on the modem for Retry: the whole text must not be sent again (the window clears it).
struct SmsFailure: Error, Equatable {
    let message: String
    var listingChanged = false
    var record = SmsSendRecord()
    var reachedModem = false
}

/// Listed parts as they were when a delete was confirmed or a Retry pressed, and where they were listed from: the
/// change is made only on that module and SIM, in that storage, on parts that are still exactly those (their raw PDUs),
/// never on what a later listing has at the same indices.
struct SmsTarget: Equatable {
    let parts: [StoredPdu]
    let place: SmsPlace
}

/// Where a listing came from: the module (the USB serial number of the device the port was opened on), the SIM (its
/// IMSI, AT+CIMI; nil when none could be read) and the storages (AT+CPMS?: <mem1>, listed and deleted from; <mem2>,
/// written to and sent from; nil when not read). A delete or a Retry of listed parts goes ahead only where all of it is
/// still the same (SmsService). Kept in memory only, never shown, logged or stored.
struct SmsPlace: Equatable {
    var device: String? = nil
    var sim: String? = nil
    var listsFrom: String? = nil
    var writesTo: String? = nil
    var complete = true     // false: the storages or the SIM could not be read
}

/// A listing: the messages, and how many of the store's entries are used (nil when the modem's answer to
/// AT+CPMS? could not be read); every stored entry as listed, and where they were listed from.
struct SmsListing: Equatable {
    let messages: [SmsMessage]
    let used: Int?
    let total: Int?
    var parts: [StoredPdu] = []
    var place = SmsPlace()
    /// From the record of sent messages (SmsSendLedger.swift): stored indices listed as unsent that RMNet confirmed
    /// sent (never sent again), and those whose send got no answer (Not confirmed); why the record could not be read.
    var sentConfirmed: Set<Int> = []
    var sendUnknown: Set<Int> = []
    var ledgerProblem: String? = nil
}

/// A stored part as the modem keeps it: its index and what it holds (pduSignature: the PDU without its service centre
/// field and, for an SMS-SUBMIT, without the message reference the modem sets when it sends it). Two listings agree on
/// a part when both are the same.
struct StoredPart: Hashable {
    let index: Int
    let signature: String

    init(index: Int, hex: String) {
        self.index = index
        signature = pduSignature(hex)
    }

    init(_ stored: StoredPdu) { self.init(index: stored.index, hex: stored.hex) }
}

/// What became of a send's stored parts, for the window (in memory; across runs the record of sent messages keeps the
/// same, SmsSendLedger.swift): `sent`, each part the modem confirmed (+CMSS), where it is stored now; `stillUnsent`,
/// those of them the modem still lists as unsent (they were sent: never offered for Retry); `unknown`, a part whose send
/// got no answer (it may have gone: marked Not confirmed); `unarchived`, how many sent parts are no longer stored (their
/// copy as sent could not be written); `unrecorded`, why the record of sent messages could not be written.
struct SmsSendRecord: Equatable {
    var sent: [StoredPart] = []
    var stillUnsent: [StoredPart] = []
    var unknown: [StoredPart] = []
    var unarchived = 0
    var unrecorded: String? = nil
}

/// A send that went: how many parts, and where they are stored as sent (none when the modem could not store them and
/// they were sent directly: `stored` false). `archived`: every part is kept on the modem as sent.
struct SmsSent: Equatable {
    let parts: Int
    var indices: [Int] = []
    var stored = true
    var record = SmsSendRecord()

    var archived: Bool { stored && record.unarchived == 0 && record.stillUnsent.isEmpty }
}

/// What a send's sentence adds about where its parts are kept and recorded (empty when all is well): parts sent but no
/// longer stored, parts sent but still listed as unsent, a record of sent messages that could not be written.
func smsArchiveNotes(_ record: SmsSendRecord) -> [String] {
    var notes: [String] = []
    if record.unarchived > 0 {
        let n = record.unarchived
        notes.append("\(n) sent \(n == 1 ? "part" : "parts") could not be kept on the modem as sent, so "
                     + "\(n == 1 ? "it is" : "they are") no longer listed.")
    }
    if !record.stillUnsent.isEmpty {
        let n = record.stillUnsent.count
        notes.append("\(n) sent \(n == 1 ? "part is" : "parts are") still stored as unsent on the modem; RMNet does not "
                     + "send \(n == 1 ? "it" : "them") again.")
    }
    if let why = record.unrecorded { notes.append("The send was not recorded: \(why)") }
    return notes
}

/// The messages as RMNet knows them: a message whose unsent parts RMNet confirmed sent (`confirmed`, stored indices)
/// keeps only the others for Retry, and is sent when none is left.
func settled(_ messages: [SmsMessage], confirmedIndices confirmed: Set<Int>) -> [SmsMessage] {
    guard !confirmed.isEmpty else { return messages }
    return messages.map { m in
        guard m.box == .unsent else { return m }
        var copy = m
        copy.unsentIndices = m.unsentIndices.filter { !confirmed.contains($0) }
        if copy.unsentIndices.isEmpty { copy.box = .sent }
        return copy
    }
}

/// The background count (SmsServing.countUnread): the store's entries, how many are received, and how many of those are
/// unread, found without reading an unread one (AT+CMGL=0 or 4 and AT+CMGR make it read): the entries less the read,
/// unsent and sent ones (AT+CMGL=1, 2 and 3 change no status).
struct SmsStoreCount: Equatable {
    let used: Int
    let received: Int
    let unread: Int
}

/// One short pass of unblocking incoming messages (`AT+CNMI=2,2,0,0,0` for about a second, then `2,1,0,0,0` again):
/// the stored parts written to the modem as unread (`AT+CMGW=<length>,0`), and whether `AT+CNMI` was already not `2,1`.
struct SmsUnblockSlice: Equatable {
    var parts: [StoredPdu] = []
    var restoredCnmi = false
}

/// What `sms unblock` (or the window's Unblock) recovered: how many stored parts were written as unread, how many of
/// the assembled messages are MMS notifications, the stored indices ascending, the assembled messages newest first, and
/// whether `AT+CNMI` was already not `2,1` when the run began.
struct SmsUnblocked: Equatable {
    let stored: Int
    let mmsNotifications: Int
    var indices: [Int] = []
    var messages: [SmsMessage] = []
    var restoredCnmi = false
}

protocol SmsServing {
    func list() -> Result<SmsListing, SmsFailure>
    func delete(indices: [Int]) -> Result<Int, SmsFailure>                   // stored entries deleted (`sms delete`)
    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure>
    /// Deletes listed parts, after checking in the same session that the modem still has them where they were listed.
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure>
    /// Sends listed unsent parts again (Retry), after the same check.
    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure>
    func countUnread() -> Result<SmsStoreCount, SmsFailure>
    /// Streams queued incoming messages across short port opens (`AT+CNMI=2,2,0,0,0` during the run, `2,1,0,0,0` put
    /// back at the end or on any failure) and writes each back to the modem's store as unread (`AT+CMGW=<length>,0`).
    func unblock(seconds: Int, shouldStop: () -> Bool) -> Result<SmsUnblocked, SmsFailure>
    /// One short port open of `unblock` (`start`: check store and set `2,2`; `finish`: restore `2,1`), so the app's
    /// shared queue and the spare AT port stay free between passes.
    func unblockSlice(start: Bool, finish: Bool) -> Result<SmsUnblockSlice, SmsFailure>
    /// Restores `AT+CNMI=2,1,0,0,0` when a previous run left it otherwise, storing any rescued `+CMT` PDUs as unread.
    func healCnmi() -> Result<SmsUnblockSlice, SmsFailure>
}

// For fakes that need only some of it (the tests'): nothing is done.
extension SmsServing {
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure> {
        .failure(SmsFailure(message: "Not available. Nothing was deleted."))
    }
    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure> {
        .failure(SmsFailure(message: "Not available. Nothing was sent."))
    }
    func countUnread() -> Result<SmsStoreCount, SmsFailure> { .failure(SmsFailure(message: "Not available.")) }
    func unblock(seconds: Int, shouldStop: () -> Bool) -> Result<SmsUnblocked, SmsFailure> {
        .failure(SmsFailure(message: "Not available."))
    }
    func unblockSlice(start: Bool, finish: Bool) -> Result<SmsUnblockSlice, SmsFailure> {
        .failure(SmsFailure(message: "Not available."))
    }
    func healCnmi() -> Result<SmsUnblockSlice, SmsFailure> { .success(SmsUnblockSlice()) }
}

// MARK: - The GSM 7-bit default alphabet (TS 23.038 §6.2.1) and its extension table (§6.2.1.1)

/// The basic table, indexed by septet value 0x00...0x7F. 0x1B is the escape to the extension table;
/// it is never produced from text and is handled before this table is consulted.
private let gsmBasicTable: [Unicode.Scalar] = [
    // 0x00 - 0x0F
    "@", "\u{00A3}", "$", "\u{00A5}", "\u{00E8}", "\u{00E9}", "\u{00F9}", "\u{00EC}",
    "\u{00F2}", "\u{00C7}", "\n", "\u{00D8}", "\u{00F8}", "\r", "\u{00C5}", "\u{00E5}",
    // 0x10 - 0x1F
    "\u{0394}", "_", "\u{03A6}", "\u{0393}", "\u{039B}", "\u{03A9}", "\u{03A0}", "\u{03A8}",
    "\u{03A3}", "\u{0398}", "\u{039E}", "\u{001B}", "\u{00C6}", "\u{00E6}", "\u{00DF}", "\u{00C9}",
    // 0x20 - 0x2F
    " ", "!", "\"", "#", "\u{00A4}", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
    // 0x30 - 0x3F
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
    // 0x40 - 0x4F
    "\u{00A1}", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    // 0x50 - 0x5F
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "\u{00C4}", "\u{00D6}", "\u{00D1}", "\u{00DC}", "\u{00A7}",
    // 0x60 - 0x6F
    "\u{00BF}", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    // 0x70 - 0x7F
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "\u{00E4}", "\u{00F6}", "\u{00F1}", "\u{00FC}", "\u{00E0}",
]

private let gsmEscape: UInt8 = 0x1B

/// The extension table: the septet that follows 0x1B.
private let gsmExtensionTable: [UInt8: Unicode.Scalar] = [
    0x0A: "\u{000C}", // form feed
    0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\", 0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|",
    0x65: "\u{20AC}", // euro sign
]

/// Text to septets: one septet for the basic table, the escape and one septet for the extension.
private let gsmEncodeTable: [Unicode.Scalar: [UInt8]] = {
    var table: [Unicode.Scalar: [UInt8]] = [:]
    for (code, scalar) in gsmBasicTable.enumerated() where code != Int(gsmEscape) {
        table[scalar] = [UInt8(truncatingIfNeeded: code)]
    }
    for (code, scalar) in gsmExtensionTable {
        table[scalar] = [gsmEscape, code]
    }
    return table
}()

private func gsmBasic(_ septet: UInt8) -> Unicode.Scalar {
    let i = Int(septet & 0x7F)
    return i < gsmBasicTable.count ? gsmBasicTable[i] : " "
}

/// Septets to text. An escape followed by a code the extension table lacks shows the basic
/// character (TS 23.038 §6.2.1.1); escape-escape shows a space; a lone escape at the end is dropped.
private func gsmDecode(_ septets: [UInt8]) -> String {
    var scalars = String.UnicodeScalarView()
    var i = 0
    while i < septets.count {
        let c = septets[i]
        if c == gsmEscape {
            if i + 1 < septets.count {
                let next = septets[i + 1]
                if next == gsmEscape {
                    scalars.append(" ")
                } else if let e = gsmExtensionTable[next] {
                    scalars.append(e)
                } else {
                    scalars.append(gsmBasic(next))
                }
            }
            i += 2
        } else {
            scalars.append(gsmBasic(c))
            i += 1
        }
    }
    return String(scalars)
}

// MARK: - Septet packing (TS 23.038 §6.1.2.1.1): septet n occupies bits 7n...7n+6, least significant first

/// Reads `count` septets starting at septet position `first` of `octets`; nil when the octets end too soon.
private func unpackSeptets(_ octets: [UInt8], from first: Int, count: Int) -> [UInt8]? {
    guard first >= 0, count >= 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(count)
    var n = 0
    while n < count {
        let bit = (first + n) * 7
        let at = bit / 8, shift = bit % 8
        guard at < octets.count else { return nil }
        var value = Int(octets[at]) >> shift
        if shift > 1 {
            guard at + 1 < octets.count else { return nil }
            value |= Int(octets[at + 1]) << (8 - shift)
        }
        out.append(UInt8(truncatingIfNeeded: value & 0x7F))
        n += 1
    }
    return out
}

/// Packs `septets` after `header` octets, the first septet at the next septet boundary
/// (the fill bits between the header and the text stay 0).
private func packSeptets(_ septets: [UInt8], after header: [UInt8]) -> (octets: [UInt8], septetLength: Int) {
    let first = (header.count * 8 + 6) / 7
    let total = first + septets.count
    var out = header + [UInt8](repeating: 0, count: max(0, (total * 7 + 7) / 8 - header.count))
    for (n, s) in septets.enumerated() {
        let bit = (first + n) * 7
        let at = bit / 8, shift = bit % 8
        let value = Int(s & 0x7F)
        if at < out.count { out[at] |= UInt8(truncatingIfNeeded: value << shift) }
        if shift > 1, at + 1 < out.count { out[at + 1] |= UInt8(truncatingIfNeeded: value >> (8 - shift)) }
    }
    return (out, total)
}

// MARK: - Hex and a bounds-checked reader

private func hexNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

private func octets(fromHex hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i + 1 < chars.count {
        guard let high = hexNibble(chars[i]), let low = hexNibble(chars[i + 1]) else { return nil }
        out.append(high << 4 | low)
        i += 2
    }
    return out
}

private func hexString(_ octets: [UInt8]) -> String {
    let digits = Array("0123456789ABCDEF")
    var s = ""
    for o in octets {
        s.append(digits[Int(o >> 4)])
        s.append(digits[Int(o & 0x0F)])
    }
    return s
}

private struct OctetReader {
    let octets: [UInt8]
    var position = 0

    init(_ octets: [UInt8]) { self.octets = octets }

    mutating func next() -> UInt8? {
        guard position < octets.count else { return nil }
        defer { position += 1 }
        return octets[position]
    }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, n <= octets.count - position else { return nil }
        defer { position += n }
        return Array(octets[position..<(position + n)])
    }

    mutating func rest() -> [UInt8] {
        let r = position < octets.count ? Array(octets[position...]) : []
        position = octets.count
        return r
    }
}

// MARK: - Addresses (TS 23.040 §9.1.2.5)

/// Semi-octet values to characters (TS 23.040 §9.1.2.3): 0-9, then *, #, a, b, c; 0xF is filler.
private func semiOctetCharacter(_ v: UInt8) -> Character? {
    switch v {
    case 0...9: return Character(Unicode.Scalar(0x30 + v))
    case 0xA: return "*"
    case 0xB: return "#"
    case 0xC: return "a"
    case 0xD: return "b"
    case 0xE: return "c"
    default: return nil
    }
}

/// Address-Length (useful semi-octets), Type-of-Address, then the value. International numbers get a
/// leading "+", other numbers are digits, alphanumeric (type of number 101) is packed GSM 7-bit.
private func readAddress(_ r: inout OctetReader) -> String? {
    guard let length = r.next(), let type = r.next() else { return nil }
    let semiOctets = Int(length)
    guard semiOctets <= 20, let value = r.take((semiOctets + 1) / 2) else { return nil }
    let typeOfNumber = (type >> 4) & 0x07
    if typeOfNumber == 5 {
        guard var septets = unpackSeptets(value, from: 0, count: semiOctets * 4 / 7) else { return nil }
        // A length given as twice the octets (not the useful semi-octets) can fill whole septets with the
        // zero padding; drop that last septet so it does not read as a trailing "@".
        if (semiOctets * 4) % 7 == 0, septets.last == 0x00 { septets.removeLast() }
        return gsmDecode(septets)
    }
    var s = typeOfNumber == 1 ? "+" : ""
    for n in 0..<semiOctets {
        let o = value[n / 2]
        let v = n % 2 == 0 ? o & 0x0F : o >> 4
        if v == 0x0F { continue }
        guard let c = semiOctetCharacter(v) else { return nil }
        s.append(c)
    }
    return s
}

private func encodeAddress(_ number: String) -> [UInt8] {
    let international = number.hasPrefix("+")
    let digits = Array((international ? String(number.dropFirst()) : number).utf8).map { $0 &- 0x30 }
    var out: [UInt8] = [UInt8(truncatingIfNeeded: digits.count), international ? 0x91 : 0x81]
    var i = 0
    while i < digits.count {
        let low = digits[i] & 0x0F
        let high: UInt8 = i + 1 < digits.count ? digits[i + 1] & 0x0F : 0x0F
        out.append(high << 4 | low)
        i += 2
    }
    return out
}

// MARK: - The service centre time stamp (TS 23.040 §9.2.3.11)

/// Seven swapped-BCD octets: year, month, day, hour, minute, second, zone in quarter hours whose
/// bit 3 is the sign (1: behind UTC). Two-digit years 90-99 are 1990s, 00-89 are 2000s.
private func serviceCentreTime(_ o: [UInt8]) -> Date? {
    guard o.count == 7 else { return nil }
    var fields: [Int] = []
    for b in o.prefix(6) {
        let tens = Int(b & 0x0F), units = Int(b >> 4)
        guard tens <= 9, units <= 9 else { return nil }
        fields.append(tens * 10 + units)
    }
    let zone = o[6]
    let zoneTens = Int(zone & 0x07), zoneUnits = Int(zone >> 4)
    guard zoneUnits <= 9, fields.count == 6 else { return nil }
    let quarters = zoneTens * 10 + zoneUnits
    let seconds = (zone & 0x08 != 0 ? -1 : 1) * quarters * 15 * 60
    guard let timeZone = TimeZone(secondsFromGMT: seconds) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let year = fields[0] >= 90 ? 1900 + fields[0] : 2000 + fields[0]
    let (month, day, hour, minute, second) = (fields[1], fields[2], fields[3], fields[4], fields[5])
    guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
    let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let date = calendar.date(from: wanted) else { return nil }
    // A day the month does not have (31 April) would roll over; refuse it instead.
    let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    guard back.year == year, back.month == month, back.day == day,
          back.hour == hour, back.minute == minute, back.second == second else { return nil }
    return date
}

// MARK: - Data coding scheme (TS 23.038 §4) and user data (TS 23.040 §9.2.3.24)

private enum Alphabet { case gsm7, latin1, ucs2 }

/// General data coding groups 00xx and 01xx (automatic deletion), not compressed; the message waiting
/// groups 1100 and 1101 (7-bit) and 1110 (UCS-2); the message class group 1111. 1000-1011 are reserved.
private func alphabet(fromCodingScheme dcs: UInt8) -> Alphabet? {
    switch dcs >> 4 {
    case 0xC, 0xD:
        return .gsm7
    case 0xE:
        return .ucs2
    case 0x0...0x7:
        if dcs & 0x20 != 0 { return nil } // compressed
        switch (dcs >> 2) & 0x03 {
        case 0: return .gsm7
        case 1: return .latin1
        case 2: return .ucs2
        default: return nil // reserved
        }
    case 0xF:
        return dcs & 0x04 == 0 ? .gsm7 : .latin1
    default:
        return nil
    }
}

/// The information elements of a user data header: the concatenation elements 0x00 (8-bit reference)
/// and 0x08 (16-bit reference), and the application port elements 0x04 (8-bit) and 0x05 (16-bit);
/// others are skipped. nil when an element runs past the header.
private let wapPushDestinationPort = 0x0B84  // 2948: WAP connectionless push (MMS notifications)

private struct HeaderElements {
    let concat: SmsConcat?
    let destinationPort: Int?
}

private func readHeader(_ h: [UInt8]) -> HeaderElements? {
    var concat: SmsConcat? = nil
    var destinationPort: Int? = nil
    var i = 0
    while i < h.count {
        guard i + 1 < h.count else { return nil }
        let id = h[i], length = Int(h[i + 1])
        guard length <= h.count - i - 2 else { return nil }
        let data = Array(h[(i + 2)..<(i + 2 + length)])
        if concat == nil {
            var found: SmsConcat? = nil
            if id == 0x00, data.count == 3 {
                found = SmsConcat(reference: Int(data[0]), total: Int(data[1]), sequence: Int(data[2]))
            } else if id == 0x08, data.count == 4 {
                found = SmsConcat(reference: Int(data[0]) << 8 | Int(data[1]), total: Int(data[2]), sequence: Int(data[3]))
            }
            // A sequence of 0 or past the total makes the element meaningless (TS 23.040 §9.2.3.24.1).
            if let f = found, f.total >= 1, f.sequence >= 1, f.sequence <= f.total { concat = f }
        }
        if destinationPort == nil {
            if id == 0x05, data.count == 4 {
                destinationPort = Int(data[0]) << 8 | Int(data[1])
            } else if id == 0x04, data.count == 2 {
                destinationPort = Int(data[0])
            }
        }
        i += 2 + length
    }
    return HeaderElements(concat: concat, destinationPort: destinationPort)
}

/// WSP's variable-length unsigned integer (WAP-230-WSP §8.1.2): 7 bits per octet, bit 7 set until the last.
private func readUintvar(_ bytes: [UInt8], from start: Int) -> (value: Int, next: Int)? {
    var value = 0
    var i = start
    for _ in 0..<5 {
        guard i < bytes.count else { return nil }
        let b = bytes[i]
        i += 1
        value = (value << 7) | Int(b & 0x7F)
        if b & 0x80 == 0 { return (value, i) }
    }
    return nil
}

/// Extracts the sender from an OMA MMS `From` field value (OMA-TS-MMS-ENC §7.3.21): `0x80` (Address-present-token)
/// followed by an Encoded-string-value, usually `<number>/TYPE=PLMN\0`; `0x81` (Insert-address-token) has no sender.
private func parseMmsFrom(_ value: [UInt8]) -> String? {
    guard let token = value.first, token == 0x80 else { return nil }
    var rest = Array(value.dropFirst())
    guard let first = rest.first else { return nil }
    var utf16 = false
    if first <= 0x1F {
        let parsed: (value: Int, next: Int)? = first <= 0x1E ? (Int(first), 1) : readUintvar(rest, from: 1)
        guard let (len, afterLen) = parsed, afterLen <= rest.count else { return nil }
        let inner = Array(rest[afterLen..<min(rest.count, afterLen + len)])
        guard let charset = inner.first else { return nil }
        if charset >= 0x80 {
            rest = Array(inner.dropFirst())
        } else if charset <= 0x1E {
            let n = Int(charset)
            guard 1 + n <= inner.count else { return nil }
            var mib = 0
            for o in inner[1..<(1 + n)] { mib = (mib << 8) | Int(o) }
            utf16 = (mib == 1013 || mib == 1015)
            rest = Array(inner.dropFirst(1 + n))
        } else if let nul = inner.firstIndex(of: 0x00), nul + 1 < inner.count {
            rest = Array(inner[(nul + 1)...])
        } else {
            return nil
        }
    }
    let text: String
    if utf16 {
        var units: [UInt16] = []
        var j = 0
        while j + 1 < rest.count {
            let u = UInt16(rest[j]) << 8 | UInt16(rest[j + 1])
            if u == 0 { break }
            units.append(u)
            j += 2
        }
        text = String(decoding: units, as: UTF16.self)
    } else {
        if rest.first == 0x7F { rest.removeFirst() }
        let slice = rest.prefix { $0 != 0x00 }
        text = String(decoding: slice, as: UTF8.self)
    }
    let raw = text.trimmingCharacters(in: .whitespaces)
    if let range = raw.range(of: "/type=", options: [.caseInsensitive]) {
        let addr = raw[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return addr.isEmpty ? nil : addr
    }
    return raw.isEmpty ? nil : raw
}

/// Decodes a WSP connectionless push payload sent to port 2948 (WAP-230-WSP §8.2.4.1, OMA-TS-MMS-ENC §6.2):
/// whether it is an MMS PDU (`application/vnd.wap.mms-message`, code 0x3E -> 0xBE, or `X-Mms-Message-Type` 0x8C 0x82),
/// and the sender in its `From` header (0x89) when present.
private func decodeMmsNotification(_ bytes: [UInt8]) -> (isMms: Bool, sender: String?) {
    guard bytes.count >= 3, bytes[1] == 0x06 || bytes[1] == 0x07,
          let (headersLen, afterLen) = readUintvar(bytes, from: 2),
          headersLen >= 1, headersLen <= bytes.count - afterLen else {
        return (false, nil)
    }
    let headersEnd = afterLen + headersLen
    let mmsMedia = "application/vnd.wap.mms-message"
    var contentTypeIsMms = false
    let ctFirst = bytes[afterLen]
    if ctFirst == 0xBE {
        contentTypeIsMms = true
    } else if ctFirst <= 0x1F {
        let parsed: (value: Int, next: Int)? = ctFirst <= 0x1E
            ? (Int(ctFirst), afterLen + 1)
            : readUintvar(bytes, from: afterLen + 1)
        if let (len, start) = parsed, len >= 1, start < headersEnd {
            if bytes[start] == 0xBE {
                contentTypeIsMms = true
            } else {
                let media = String(decoding: bytes[start..<min(headersEnd, start + len)].prefix { $0 != 0x00 }, as: UTF8.self)
                contentTypeIsMms = media.lowercased() == mmsMedia
            }
        }
    } else if ctFirst < 0x80 {
        let media = String(decoding: bytes[afterLen..<headersEnd].prefix { $0 != 0x00 }, as: UTF8.self)
        contentTypeIsMms = media.lowercased() == mmsMedia
    }

    let body = Array(bytes[headersEnd...])
    let hasMmsType = body.count >= 2 && body[0] == 0x8C && (0x80...0x97).contains(body[1])
    guard contentTypeIsMms || (body.count >= 2 && body[0] == 0x8C && body[1] == 0x82) else {
        return (false, nil)
    }
    guard hasMmsType else { return (contentTypeIsMms, nil) }

    // Walk WSP/MMS header fields (WAP-230-WSP §8.4.1.2) to read From (0x89).
    var i = 0
    while i < body.count {
        let field = body[i]
        guard field >= 0x80, i + 1 < body.count else { break }
        i += 1
        let first = body[i]
        let value: [UInt8]
        if first <= 0x1E {
            let len = Int(first)
            i += 1
            guard len <= body.count - i else { break }
            value = Array(body[i..<(i + len)])
            i += len
        } else if first == 0x1F {
            guard let (len, next) = readUintvar(body, from: i + 1), len <= body.count - next else { break }
            value = Array(body[next..<(next + len)])
            i = next + len
        } else if first < 0x80 {
            guard let end = body[i...].firstIndex(of: 0x00) else { break }
            value = Array(body[i..<end])
            i = end + 1
        } else {
            value = [first]
            i += 1
        }
        if field == 0x89, let from = parseMmsFrom(value) {
            return (true, from)
        }
    }
    return (true, nil)
}

/// Decodes user data of `length` (septets for 7-bit, octets otherwise), with or without a header.
private struct DecodedUserData {
    let text: String
    let concat: SmsConcat?
    var destinationPort: Int? = nil
    var rawPayload: [UInt8]? = nil
}

private func readUserData(_ ud: [UInt8], length: Int, alphabet: Alphabet,
                          hasHeader: Bool) -> DecodedUserData? {
    let maximum = alphabet == .gsm7 ? 160 : 140
    let needed = alphabet == .gsm7 ? (length * 7 + 7) / 8 : length
    guard length >= 0, length <= maximum, ud.count >= needed else { return nil }
    var headerOctets = 0
    var concat: SmsConcat? = nil
    var destinationPort: Int? = nil
    if hasHeader {
        guard let headerLength = ud.first else { return nil }
        headerOctets = 1 + Int(headerLength)
        guard headerOctets <= needed, let elements = readHeader(Array(ud[1..<headerOctets])) else { return nil }
        concat = elements.concat
        destinationPort = elements.destinationPort
    }
    if destinationPort == wapPushDestinationPort, alphabet != .gsm7 {
        return DecodedUserData(text: "", concat: concat, destinationPort: destinationPort,
                               rawPayload: Array(ud[headerOctets..<needed]))
    }
    switch alphabet {
    case .gsm7:
        let first = (headerOctets * 8 + 6) / 7
        guard length >= first, let septets = unpackSeptets(ud, from: first, count: length - first) else { return nil }
        return DecodedUserData(text: gsmDecode(septets), concat: concat, destinationPort: destinationPort)
    case .latin1:
        var scalars = String.UnicodeScalarView()
        for o in ud[headerOctets..<length] { scalars.append(Unicode.Scalar(o)) }
        return DecodedUserData(text: String(scalars), concat: concat, destinationPort: destinationPort)
    case .ucs2:
        // An odd octet count is read without its last octet.
        let body = Array(ud[headerOctets..<length])
        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var i = 0
        while i + 1 < body.count {
            units.append(UInt16(body[i]) << 8 | UInt16(body[i + 1]))
            i += 2
        }
        // UTF-16 big-endian: surrogate pairs join; a lone surrogate becomes U+FFFD.
        return DecodedUserData(text: String(decoding: units, as: UTF16.self), concat: concat,
                               destinationPort: destinationPort)
    }
}

// MARK: - Reading the modem's answers (TS 27.005)

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func isHexLine(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.allSatisfy { hexNibble($0) != nil }
}

/// The lines AT+CMGL=4 answers: "+CMGL: <index>,<stat>,[<alpha>],<length>" then a hex line.
/// An entry without its hex line is dropped; any other line is ignored. Between a header and its hex line,
/// lines that are neither hex nor a header (blank lines, unsolicited results such as +CMTI) are skipped;
/// the next header ends the search, so a header never takes another header's hex.
func parseListing(_ lines: [String]) -> [StoredPdu] {
    var out: [StoredPdu] = []
    var i = 0
    while i < lines.count {
        let line = trimmed(lines[i])
        i += 1
        guard line.hasPrefix("+CMGL:") else { continue }
        let fields = line.dropFirst("+CMGL:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        guard fields.count >= 2, let index = Int(fields[0]), index >= 0,
              let stat = Int(fields[1]), let status = SmsStatus(rawValue: stat) else { continue }
        var j = i
        while j < lines.count {
            let candidate = trimmed(lines[j])
            if candidate.hasPrefix("+CMGL:") { break }
            if isHexLine(candidate) {
                out.append(StoredPdu(index: index, status: status, hex: candidate))
                i = j + 1
                break
            }
            j += 1
        }
    }
    return out
}

/// "+CMGW: <index>" after a message was written to the store (AT+CMGW).
func parseStoreIndex(_ lines: [String]) -> Int? {
    firstNumber(lines, "+CMGW:")
}

/// "+CMSS: <mr>[,<ackpdu>]" (mr 0-255) after a stored message was sent (AT+CMSS).
func parseStoredSendReference(_ lines: [String]) -> Int? {
    firstNumber(lines, "+CMSS:").flatMap { (0...255).contains($0) ? $0 : nil }
}

/// The status of "+CMGR: <stat>,[<alpha>],<length>" (AT+CMGR in PDU mode), and the PDU line after it.
func parseReadEntry(_ lines: [String]) -> (status: SmsStatus, hex: String)? {
    guard let i = lines.firstIndex(where: { trimmed($0).hasPrefix("+CMGR:") }),
          let stat = firstNumber([lines[i]], "+CMGR:"), let status = SmsStatus(rawValue: stat),
          let hex = lines[(i + 1)...].map(trimmed).first(where: isHexLine) else { return nil }
    return (status, hex)
}

/// The storages of "+CPMS: "ME",u,t,"ME",u,t,"ME",u,t": <mem1> (listed and deleted) and <mem2> (written and sent
/// from); nil without names.
func parseStorageNames(_ lines: [String]) -> (read: String, write: String)? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CPMS:") else { continue }
        let fields = line.dropFirst("+CPMS:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        guard fields.count >= 6, fields[0].hasPrefix("\""), fields[3].hasPrefix("\"") else { return nil }
        return (fields[0].replacingOccurrences(of: "\"", with: ""), fields[3].replacingOccurrences(of: "\"", with: ""))
    }
    return nil
}

/// The IMSI AT+CIMI answers (a line of 6 to 15 digits), nil without one.
func parseImsi(_ lines: [String]) -> String? {
    lines.map(trimmed).first { (6...15).contains($0.count) && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
}

/// How many entries an AT+CMGL answer lists (its "+CMGL: <index>,…" lines).
func listedCount(_ lines: [String]) -> Int {
    lines.map(trimmed).filter { $0.hasPrefix("+CMGL:") && firstNumber([$0], "+CMGL:") != nil }.count
}

/// What a stored PDU holds, for telling stored parts apart across listings: its octets after the service centre field
/// (which the modem may fill in), with an SMS-SUBMIT's message reference (TP-MR, set by the modem when it sends) as 00;
/// upper-case hex. A PDU that cannot be read is its own upper-case hex.
func pduSignature(_ hex: String) -> String {
    guard let all = octets(fromHex: hex), let sc = all.first, all.count > Int(sc) + 1 else { return hex.uppercased() }
    var tpdu = Array(all[(Int(sc) + 1)...])
    if tpdu[0] & 0x03 == 1, tpdu.count > 1 { tpdu[1] = 0 }  // TP-MTI 1: SMS-SUBMIT; the next octet is TP-MR
    return hexString(tpdu)
}

/// The first field of the first line starting `prefix`, as a non-negative number.
private func firstNumber(_ lines: [String], _ prefix: String) -> Int? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix(prefix) else { continue }
        let first = line.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false).first
        guard let f = first, let n = Int(trimmed(String(f))), n >= 0 else { return nil }
        return n
    }
    return nil
}

/// "+CMGS: <mr>" (0-255) after a message was sent.
func parseSendReference(_ lines: [String]) -> Int? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CMGS:") else { continue }
        let first = line.dropFirst("+CMGS:".count).split(separator: ",", omittingEmptySubsequences: false).first
        guard let f = first, let mr = Int(trimmed(String(f))), (0...255).contains(mr) else { return nil }
        return mr
    }
    return nil
}

/// The first used/total pair of "+CPMS: "ME",0,255,..." (or "+CPMS: 0,255,..." without names).
func parseStorage(_ lines: [String]) -> (used: Int, total: Int)? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CPMS:") else { continue }
        let fields = line.dropFirst("+CPMS:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        let start = fields.first?.hasPrefix("\"") == true ? 1 : 0
        guard fields.count >= start + 2, let used = Int(fields[start]), let total = Int(fields[start + 1]),
              used >= 0, total >= 0, used <= total else { return nil }
        return (used, total)
    }
    return nil
}

/// `<mode>` and `<mt>` of "+CNMI: 2,1,0,0,0" (AT+CNMI?); nil without them.
func parseCnmi(_ lines: [String]) -> (mode: Int, mt: Int)? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CNMI:") else { continue }
        let fields = line.dropFirst("+CNMI:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        guard fields.count >= 2, let mode = Int(fields[0]), let mt = Int(fields[1]), mode >= 0, mt >= 0 else {
            return nil
        }
        return (mode, mt)
    }
    return nil
}

// MARK: - Decoding SMS-DELIVER (TS 23.040 §9.2.2.1)

private struct Deliver {
    let sender: String
    let timestamp: Date?
    let text: String
    let concat: SmsConcat?
    var wapPush: [UInt8]? = nil
}

private func decodeDeliver(_ hex: String) -> Deliver? {
    guard let all = octets(fromHex: hex) else { return nil }
    var r = OctetReader(all)
    guard let serviceCentreLength = r.next(), r.take(Int(serviceCentreLength)) != nil else { return nil }
    guard let first = r.next(), first & 0x03 == 0 else { return nil } // TP-MTI 0: SMS-DELIVER
    guard let sender = readAddress(&r) else { return nil }
    guard r.next() != nil, let dcs = r.next(), let alpha = alphabet(fromCodingScheme: dcs) else { return nil }
    guard let time = r.take(7), let length = r.next() else { return nil }
    guard let body = readUserData(r.rest(), length: Int(length), alphabet: alpha,
                                  hasHeader: first & 0x40 != 0) else { return nil }
    if let push = body.rawPayload {
        if body.concat != nil {
            return Deliver(sender: sender, timestamp: serviceCentreTime(time), text: "", concat: body.concat,
                           wapPush: push)
        }
        let mms = decodeMmsNotification(push)
        guard mms.isMms else { return nil }
        return Deliver(sender: mms.sender ?? sender, timestamp: serviceCentreTime(time),
                       text: mmsNotificationText, concat: nil)
    }
    return Deliver(sender: sender, timestamp: serviceCentreTime(time), text: body.text, concat: body.concat)
}

// MARK: - Text from the modem, safe to show

/// Characters a sender could use to move the cursor, erase or forge lines, or reorder what is shown:
/// the C0 controls, DEL, the C1 controls and the bidirectional embeddings, overrides and isolates.
private func isUnsafeForDisplay(_ v: UInt32) -> Bool {
    v <= 0x1F || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
}

/// Text received from the network, made safe for every place it is shown (a terminal, JSON, the window).
/// Each unsafe character becomes U+FFFD. With `keepLineEnds` (a message's text), CR LF and a lone CR
/// become LF, LF stays, and tab stays; without it (a sender) every control character is replaced.
func displaySafe(_ s: String, keepLineEnds: Bool) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        i += 1
        if keepLineEnds {
            if c == "\r" {
                if i < scalars.count, scalars[i] == "\n" { i += 1 }
                out.append("\n")
                continue
            }
            if c == "\n" || c == "\t" {
                out.append(c)
                continue
            }
        }
        out.append(isUnsafeForDisplay(c.value) ? "\u{FFFD}" : c)
    }
    return String(out)
}

/// The sender and the text of a readable part are display-safe (`displaySafe`). An SMS-SUBMIT stored to send (STO SENT or
/// STO UNSENT) reads as its recipient and text, with no time.
func decodePart(_ stored: StoredPdu) -> SmsPart {
    guard let d = decodeDeliver(stored.hex) else {
        if let submit = readSubmit(stored.hex) {
            return SmsPart(index: stored.index, status: stored.status, sender: displaySafe(submit.number, keepLineEnds: false),
                           timestamp: nil, text: displaySafe(submit.text, keepLineEnds: true), concat: submit.concat,
                           readable: true)
        }
        return SmsPart(index: stored.index, status: stored.status, sender: "", timestamp: nil, text: "",
                       concat: nil, readable: false)
    }
    return SmsPart(index: stored.index, status: stored.status, sender: displaySafe(d.sender, keepLineEnds: false),
                   timestamp: d.timestamp, text: displaySafe(d.text, keepLineEnds: true), concat: d.concat,
                   readable: true, wapPush: d.wapPush)
}

/// Reads back an SMS-SUBMIT (TS 23.040 §9.2.2.2) with the same address and user data routines the
/// decoder uses. The checks use it to prove that what encodeSubmit writes reads back as the same text.
func readSubmit(_ hex: String) -> (number: String, text: String, concat: SmsConcat?)? {
    guard let all = octets(fromHex: hex) else { return nil }
    var r = OctetReader(all)
    guard let serviceCentreLength = r.next(), r.take(Int(serviceCentreLength)) != nil else { return nil }
    guard let first = r.next(), first & 0x03 == 1 else { return nil } // TP-MTI 1: SMS-SUBMIT
    guard r.next() != nil, let number = readAddress(&r) else { return nil } // message reference, then address
    guard r.next() != nil, let dcs = r.next(), let alpha = alphabet(fromCodingScheme: dcs) else { return nil }
    let validityOctets = [0, 7, 1, 7][Int((first >> 3) & 0x03)]
    guard r.take(validityOctets) != nil, let length = r.next() else { return nil }
    guard let body = readUserData(r.rest(), length: Int(length), alphabet: alpha,
                                  hasHeader: first & 0x40 != 0) else { return nil }
    return (number, body.text, body.concat)
}

// MARK: - Assembling multi-part messages

/// A message's box from its parts: received; or sent, unless a part is still unsent.
private func box(of parts: [SmsPart]) -> SmsBox {
    guard parts.contains(where: { $0.outgoing }) else { return .received }
    return parts.contains(where: { $0.status == .unsent }) ? .unsent : .sent
}

private struct GroupKey: Hashable { let sender: String; let reference: Int; let total: Int; let outgoing: Bool }

/// Parts further than this from a group's earliest part start another message.
private let groupWindow: TimeInterval = 15 * 60

private struct PartGroup { let key: GroupKey; var earliest: Date?; var members: [SmsPart] }

/// Parts belong to one message when they have the same sender, reference and total, each part's time is
/// within 15 minutes of the group's earliest part (a part without a time joins by the key alone), and the
/// group does not already hold that sequence number with a different text. A repeated sequence with the
/// same text is a duplicate: the lower index gives the text and both indices are listed. Parts are taken
/// in order of time, then index, so the result does not depend on the order of the listing.
/// Messages come newest first; entries without a time last, by index.
/// A known limit: two different multi-part messages from one sender that reuse a reference and total
/// within 15 minutes, with parts that interleave in time or with a part missing, can exchange parts and
/// show as complete. No simple rule tells them apart; it needs a sender that reuses a reference that soon.
func assemble(_ parts: [SmsPart]) -> [SmsMessage] {
    var messages: [SmsMessage] = []
    var candidates: [SmsPart] = []
    for p in parts {
        if p.readable, p.concat != nil {
            candidates.append(p)
        } else {
            messages.append(SmsMessage(indices: [p.index], unread: p.status == .unread, sender: p.sender,
                                       timestamp: p.timestamp, text: p.text, missingParts: 0,
                                       readable: p.readable, box: box(of: [p]),
                                       unsentIndices: p.status == .unsent ? [p.index] : []))
        }
    }
    // Time first (parts without a time after the others), then index; the rest only breaks exact ties.
    candidates.sort { a, b in
        switch (a.timestamp, b.timestamp) {
        case let (ta?, tb?) where ta != tb: return ta < tb
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            if a.index != b.index { return a.index < b.index }
            let sa = a.concat?.sequence ?? 0, sb = b.concat?.sequence ?? 0
            if sa != sb { return sa < sb }
            if a.sender != b.sender { return a.sender < b.sender }
            return a.text < b.text
        }
    }
    var groups: [PartGroup] = []
    for p in candidates {
        guard let c = p.concat else { continue }
        let key = GroupKey(sender: p.sender, reference: c.reference, total: c.total, outgoing: p.outgoing)
        let home = groups.firstIndex { g in
            guard g.key == key else { return false }
            if let t = p.timestamp, let e = g.earliest, abs(t.timeIntervalSince(e)) > groupWindow { return false }
            return !g.members.contains {
                $0.concat?.sequence == c.sequence && ($0.text != p.text || $0.wapPush != p.wapPush)
            }
        }
        if let h = home {
            groups[h].members.append(p)
            if groups[h].earliest == nil { groups[h].earliest = p.timestamp }
        } else {
            groups.append(PartGroup(key: key, earliest: p.timestamp, members: [p]))
        }
    }
    for g in groups {
        let timestamp = g.members.compactMap { $0.timestamp }.min()
        if g.members.contains(where: { $0.wapPush != nil }) {
            var payload: [UInt8] = []
            var missing = 0
            for sequence in 1...max(1, g.key.total) {
                let same = g.members.filter { $0.concat?.sequence == sequence }
                if let chosen = same.min(by: { $0.index < $1.index }) {
                    payload.append(contentsOf: chosen.wapPush ?? [])
                } else {
                    missing += 1
                }
            }
            let mms = decodeMmsNotification(payload)
            let who = mms.sender.map { displaySafe($0, keepLineEnds: false) } ?? g.key.sender
            messages.append(SmsMessage(indices: g.members.map { $0.index }.sorted(),
                                       unread: g.members.contains { $0.status == .unread },
                                       sender: mms.isMms ? who : "",
                                       timestamp: mms.isMms ? timestamp : nil,
                                       text: mms.isMms ? mmsNotificationText : "",
                                       missingParts: mms.isMms ? missing : 0,
                                       readable: mms.isMms, box: box(of: g.members),
                                       unsentIndices: g.members.filter { $0.status == .unsent }.map { $0.index }.sorted()))
            continue
        }
        var text = ""
        var missing = 0
        var inGap = false
        for sequence in 1...max(1, g.key.total) {
            // A duplicate sequence keeps the lower index for the text.
            let same = g.members.filter { $0.concat?.sequence == sequence }
            if let chosen = same.min(by: { $0.index < $1.index }) {
                text += chosen.text
                inGap = false
            } else {
                // A run of missing parts shows as one mark; each one is counted.
                if !inGap { text += "[...]" }
                inGap = true
                missing += 1
            }
        }
        messages.append(SmsMessage(indices: g.members.map { $0.index }.sorted(),
                                   unread: g.members.contains { $0.status == .unread }, sender: g.key.sender,
                                   timestamp: timestamp, text: text, missingParts: missing, readable: true,
                                   box: box(of: g.members),
                                   unsentIndices: g.members.filter { $0.status == .unsent }.map { $0.index }.sorted()))
    }
    return messages.sorted { a, b in
        let ia = a.indices.first ?? 0, ib = b.indices.first ?? 0
        switch (a.timestamp, b.timestamp) {
        case let (ta?, tb?): return ta != tb ? ta > tb : ia > ib
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return ia < ib
        }
    }
}

// MARK: - Encoding SMS-SUBMIT (TS 23.040 §9.2.2.2)

func chooseEncoding(_ text: String) -> SmsEncoding {
    text.unicodeScalars.allSatisfy { gsmEncodeTable[$0] != nil } ? .gsm7 : .ucs2
}

private let maximumParts = 10

/// Splits text into parts of whole characters: an escape pair or a surrogate pair is never cut.
/// GSM 7-bit: one part up to 160 septets, else parts of 153; UCS-2: one up to 70 units, else 67.
private func splitText(_ text: String) -> (encoding: SmsEncoding, parts: [[Unicode.Scalar]]) {
    let encoding = chooseEncoding(text)
    func cost(_ s: Unicode.Scalar) -> Int {
        encoding == .gsm7 ? (gsmEncodeTable[s]?.count ?? 1) : UTF16.width(s)
    }
    let scalars = Array(text.unicodeScalars)
    let total = scalars.reduce(0) { $0 + cost($1) }
    let single = encoding == .gsm7 ? 160 : 70
    let multi = encoding == .gsm7 ? 153 : 67
    if total == 0 { return (encoding, []) }
    if total <= single { return (encoding, [scalars]) }
    var parts: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    var used = 0
    for s in scalars {
        let c = cost(s)
        if used + c > multi {
            parts.append(current)
            current = []
            used = 0
        }
        current.append(s)
        used += c
    }
    if !current.isEmpty { parts.append(current) }
    return (encoding, parts)
}

/// Parts the text needs; 0 for empty text.
func partCount(_ text: String) -> Int { splitText(text).parts.count }

/// An optional leading "+", then 3 to 20 digits.
func validNumber(_ number: String) -> Bool {
    let digits = Array((number.hasPrefix("+") ? String(number.dropFirst()) : number).unicodeScalars)
    return (3...20).contains(digits.count) && digits.allSatisfy { ("0"..."9").contains($0) }
}

/// SMS-SUBMIT PDUs with the stored service centre (00), no validity period, no status report and
/// message reference 00. Multi-part messages carry the 8-bit concatenation element with `reference`.
func encodeSubmit(to number: String, text: String, reference: UInt8) -> Result<[SubmitPdu], SmsFailure> {
    guard validNumber(number) else {
        return .failure(SmsFailure(message: "The number is not valid: use 3 to 20 digits, with an optional + in front."))
    }
    let (encoding, parts) = splitText(text)
    guard !parts.isEmpty else { return .failure(SmsFailure(message: "The message is empty.")) }
    guard parts.count <= maximumParts else {
        return .failure(SmsFailure(message: "The message is too long: it needs \(parts.count) parts and at most \(maximumParts) can be sent."))
    }
    let multipart = parts.count > 1
    let address = encodeAddress(number)
    var out: [SubmitPdu] = []
    for (n, part) in parts.enumerated() {
        // First octet: TP-MTI 01 (SUBMIT), TP-VPF 00 (no validity), TP-SRR 0, TP-UDHI when multi-part.
        var tpdu: [UInt8] = [multipart ? 0x41 : 0x01, 0x00] + address + [0x00, encoding == .gsm7 ? 0x00 : 0x08]
        let header: [UInt8] = multipart
            ? [0x05, 0x00, 0x03, reference, UInt8(truncatingIfNeeded: parts.count), UInt8(truncatingIfNeeded: n + 1)]
            : []
        switch encoding {
        case .gsm7:
            let septets = part.flatMap { gsmEncodeTable[$0] ?? [] }
            let packed = packSeptets(septets, after: header)
            tpdu.append(UInt8(truncatingIfNeeded: packed.septetLength)) // at most 160
            tpdu += packed.octets
        case .ucs2:
            var ud = header
            for unit in String(String.UnicodeScalarView(part)).utf16 {
                ud.append(UInt8(truncatingIfNeeded: unit >> 8))
                ud.append(UInt8(truncatingIfNeeded: unit))
            }
            tpdu.append(UInt8(truncatingIfNeeded: ud.count)) // at most 140
            tpdu += ud
        }
        out.append(SubmitPdu(hex: "00" + hexString(tpdu), tpduLength: tpdu.count))
    }
    return .success(out)
}

// MARK: - What the window shows (pure decisions for app/SmsView.swift and app/SmsController.swift)

/// The line under the text being written: how many parts it needs and in which alphabet; "" for no text.
/// While an input method is composing, that the input must be finished first (Send is disabled).
func composeNote(_ text: String, composing: Bool = false) -> String {
    if composing { return "Finish the input being composed (the underlined text) before sending." }
    let parts = partCount(text)
    if parts == 0 { return "" }
    if parts > maximumParts { return "too long: \(parts) parts, at most \(maximumParts)" }
    let alphabet = chooseEncoding(text) == .gsm7 ? "GSM alphabet" : "Unicode"
    return "\(parts) \(parts == 1 ? "part" : "parts"), \(alphabet)"
}

/// A valid number and a text of 1 to 10 parts that is not only blanks.
func canSend(number: String, text: String) -> Bool {
    guard validNumber(number), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return (1...maximumParts).contains(partCount(text))
}

/// The line under the number: "" while it is empty or valid, else the rule.
func numberNote(_ number: String) -> String {
    number.isEmpty || validNumber(number) ? "" : "The number is 3 to 20 digits, with an optional + in front."
}

/// Formatters for the window's times, one set per time zone, made once (rows are drawn often).
private final class TimeFormats {
    struct Formats { let calendar: Calendar; let time: DateFormatter; let dayAndTime: DateFormatter; let seconds: DateFormatter }
    private static var made: [TimeZone: Formats] = [:]
    private static let lock = NSLock()

    static func formats(_ timeZone: TimeZone) -> Formats {
        lock.lock()
        defer { lock.unlock() }
        if let found = made[timeZone] { return found }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func formatter(_ pattern: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f
        }
        let set = Formats(calendar: calendar, time: formatter("HH:mm"), dayAndTime: formatter("yyyy-MM-dd HH:mm"),
                      seconds: formatter("HH:mm:ss"))
        made[timeZone] = set
        return set
    }
}

/// "<sender>, <time>": a time on the same day as `now` (in `timeZone`) as HH:mm, others as
/// yyyy-MM-dd HH:mm. The window passes the time of the last listing as `now`.
func rowTitle(_ m: SmsMessage, now: Date, timeZone: TimeZone = .current) -> String {
    let sender = m.sender.isEmpty ? "unknown sender" : m.sender
    guard let time = m.timestamp else { return "\(sender), no time" }
    let f = TimeFormats.formats(timeZone)
    let text = f.calendar.isDate(time, inSameDayAs: now) ? f.time.string(from: time) : f.dayAndTime.string(from: time)
    return "\(sender), \(text)"
}

/// The line about the list itself: when it was last listed and how full the store was then (with the
/// warning from 90 %), or why the last listing failed. A send's or a delete's result never goes here.
func listLine(updated: Date?, failure: String?, used: Int? = nil, total: Int? = nil,
              timeZone: TimeZone = .current) -> String {
    let at = updated.map { TimeFormats.formats(timeZone).seconds.string(from: $0) }
    let line: String
    switch (failure, at) {
    case (nil, nil): return ""
    case (nil, let t?): line = "Updated \(t)."
    case (let f?, nil): return f
    case (let f?, let t?): line = "\(f) The list below may be out of date; it was updated \(t)."
    }
    let use = storeUse(used: used, total: total)
    let warning = storeWarning(used: used, total: total)
    return [line, use.isEmpty ? "" : "\(use).", warning].filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - The modem's message store (AT+CPMS?)

/// "N of M stored parts"; "" when not known.
func storeUse(used: Int?, total: Int?) -> String {
    guard let used, let total else { return "" }
    return "\(used) of \(total) stored parts"
}

/// From 90 % of the store used. When the store is full the network holds new messages, and they can
/// expire without the owner knowing.
func storeNearlyFull(used: Int?, total: Int?) -> Bool {
    guard let used, let total, total > 0 else { return false }
    return used * 10 >= total * 9
}

/// The warning shown (window and verb) when the store is nearly full; "" otherwise.
func storeWarning(used: Int?, total: Int?) -> String {
    guard storeNearlyFull(used: used, total: total), let used, let total else { return "" }
    return "The modem's message store is nearly full (\(used) of \(total)). "
        + "Delete old messages, or new ones will not arrive."
}

/// The first line of `sms list`.
func listHeadline(count: Int, used: Int?, total: Int?) -> String {
    let head = count == 0 ? "sms: no messages" : "sms: \(count) message(s)"
    let use = storeUse(used: used, total: total)
    return use.isEmpty ? head : "\(head), \(use) used"
}

/// What the list area says while there are no rows.
func listPlaceholder(listed: Bool, failed: Bool) -> String {
    if listed { return "No messages on the modem." }
    return failed ? "The messages could not be read." : "Reading the messages…"
}

/// What a row says besides its title and text: "not readable", "<n> part(s) missing" or "".
func rowNote(_ m: SmsMessage) -> String {
    if !m.readable { return "not readable" }
    if m.missingParts > 0 { return "\(m.missingParts) \(m.missingParts == 1 ? "part" : "parts") missing" }
    return ""
}

/// The list's heading: "3 messages · 1 unread", "1 message"; "" with none.
func messageCountLine(count: Int, unread: Int) -> String {
    guard count > 0 else { return "" }
    return "\(count) \(count == 1 ? "message" : "messages")" + (unread > 0 ? " · \(unread) unread" : "")
}

/// Words that name a one-time code, in the languages such texts come in (lower case). The CJK ones are written as
/// escapes so the source stays ASCII: "verification code" in simplified and traditional Chinese, Japanese and Korean.
private let codeWords = ["code", "otp", "pin", "passcode", "password", "verification", "verify",
                         "\u{9A8C}\u{8BC1}\u{7801}", "\u{6821}\u{9A8C}\u{7801}", "\u{52A8}\u{6001}\u{7801}", "\u{9A57}\u{8B49}\u{78BC}",
                         "\u{8A8D}\u{8B49}\u{78BC}", "\u{8A8D}\u{8A3C}", "\u{C778}\u{C99D}"]

/// The one-time code in a message, for the reading pane's Copy Code: the one group of 4 to 8 ASCII digits standing
/// alone (not part of a longer number, after `+`, a currency sign, `#` or a digit and `-`, or before a decimal point), in a text
/// that names a code (codeWords); nil when there is no such word, no such group, or more than one group.
func verificationCode(in text: String) -> String? {
    let lower = text.lowercased()
    guard codeWords.contains(where: { lower.contains($0) }) else { return nil }
    let scalars = Array(text.unicodeScalars)
    func isDigit(_ i: Int) -> Bool { i >= 0 && i < scalars.count && (0x30...0x39).contains(scalars[i].value) }
    var groups: [String] = []
    var i = 0
    while i < scalars.count {
        guard isDigit(i) else { i += 1; continue }
        var end = i
        while isDigit(end) { end += 1 }
        let before: Unicode.Scalar? = i > 0 ? scalars[i - 1] : nil
        let after: Unicode.Scalar? = end < scalars.count ? scalars[end] : nil
        // "+1555…", "$1500", "#123456" and "555-1234" are not codes; "G-482913" is.
        let joinedBefore = (before.map { "+$€£¥#".unicodeScalars.contains($0) } ?? false)
            || (before == "-" && isDigit(i - 2))
        let decimalAfter = after.map { $0 == "." || $0 == "," } == true && isDigit(end + 1)
        let length = end - i
        if (4...8).contains(length) && !joinedBefore && !decimalAfter {
            groups.append(String(String.UnicodeScalarView(scalars[i..<end])))
        }
        i = end
    }
    return groups.count == 1 ? groups[0] : nil
}

// MARK: - What `RMNet sms list` prints

/// The headline, the store's warning, then each message: `[indices] unread|read <sender> <time>` for a received one,
/// `[indices] sent to|unsent to <recipient> no time` for one RMNet stored to send (`unsent (not confirmed) to` when a
/// part's send got no answer: it may have gone), and its text indented below. The messages as the record of sent
/// messages settles them (a part RMNet confirmed sent is sent).
func smsListLines(_ listing: SmsListing, time: (Date) -> String) -> [String] {
    var lines = [listHeadline(count: listing.messages.count, used: listing.used, total: listing.total)]
    let warning = storeWarning(used: listing.used, total: listing.total)
    if !warning.isEmpty { lines.append("sms: \(warning)") }
    for m in settled(listing.messages, confirmedIndices: listing.sentConfirmed) {
        let indices = "[" + m.indices.map(String.init).joined(separator: ",") + "]"
        guard m.readable else {
            lines.append("\(indices) not readable")
            continue
        }
        let state: String
        switch m.box {
        case .received: state = m.unread ? "unread" : "read"
        case .sent: state = "sent to"
        case .unsent:
            state = m.unsentIndices.contains(where: listing.sendUnknown.contains) ? "unsent (not confirmed) to" : "unsent to"
        }
        var head = "\(indices) \(state) \(m.sender) \(m.timestamp.map(time) ?? "no time")"
        if m.missingParts > 0 { head += " (\(m.missingParts) part(s) missing)" }
        lines.append(head)
        if m.text.isEmpty { continue }
        for line in m.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines.append("  \(line)")
        }
    }
    return lines
}

/// `sms list --json`: one object a message, the keys it always had and `status` (added): "received", "sent" or
/// "unsent"; for the last two `sender` is the recipient and `time` is null. `notConfirmed` (added): an unsent part's
/// send got no answer (it may have gone). With `listing`, the messages as the record of sent messages settles them.
func smsListJSON(_ messages: [SmsMessage], time: (Date) -> String, notConfirmed: Set<Int> = []) -> [[String: Any]] {
    messages.map { m in
        ["indices": m.indices, "unread": m.unread, "sender": m.sender,
         "time": m.timestamp.map(time) ?? NSNull(), "text": m.text,
         "missingParts": m.missingParts, "readable": m.readable, "status": m.box.rawValue,
         "notConfirmed": m.box == .unsent && m.unsentIndices.contains(where: notConfirmed.contains)]
    }
}

func smsListJSON(_ listing: SmsListing, time: (Date) -> String) -> [[String: Any]] {
    smsListJSON(settled(listing.messages, confirmedIndices: listing.sentConfirmed), time: time,
                notConfirmed: listing.sendUnknown)
}

/// The confirmation before a delete: the sender, and how many stored parts go.
func deleteQuestion(_ m: SmsMessage) -> (title: String, message: String) {
    let sender = m.sender.isEmpty ? "an unknown sender" : m.sender
    let n = m.indices.count
    return ("Delete the message from \(sender)?",
            "\(n) stored \(n == 1 ? "part" : "parts") will be deleted from the modem. This cannot be undone.")
}

/// A message across listings: its stored indices, its sender and its time.
struct SmsMessageKey: Hashable {
    let indices: [Int]
    let sender: String
    let timestamp: Date?
}

extension SmsMessage {
    var key: SmsMessageKey { SmsMessageKey(indices: indices, sender: sender, timestamp: timestamp) }
}

/// Listing marks messages as read on the modem, so the window keeps its own marks: a listed message is
/// marked when the modem says unread or when it was marked before (`kept`); marks of messages no longer
/// listed are dropped.
func unreadMarks(listed: [SmsMessage], kept: Set<SmsMessageKey>) -> Set<SmsMessageKey> {
    Set(listed.filter { $0.unread || kept.contains($0.key) }.map { $0.key })
}

// MARK: - Unblocking incoming messages (`RMNet sms unblock` and the window's Unblock)

let smsUnblockDefaultSeconds = 95
let smsUnblockSecondsRange = 1...180

enum SmsCommand: Equatable {
    case list(json: Bool)
    case send(number: String, text: String)
    case delete(indices: [Int])
    case unblock(seconds: Int, json: Bool)
}

/// The words after "sms"; nil for wrong usage.
func parseSms(_ words: [String]) -> SmsCommand? {
    guard let verb = words.first else { return nil }
    let rest = Array(words.dropFirst())
    switch verb {
    case "list":
        if rest.isEmpty { return .list(json: false) }
        return rest == ["--json"] ? .list(json: true) : nil
    case "send":
        guard rest.count >= 2 else { return nil }
        return .send(number: rest[0], text: rest.dropFirst().joined(separator: " "))
    case "delete":
        let indices = rest.compactMap { Int($0) }.filter { $0 >= 0 }
        guard !rest.isEmpty, indices.count == rest.count else { return nil }
        var seen = Set<Int>()
        return .delete(indices: indices.filter { seen.insert($0).inserted })  // each once, first kept
    case "unblock":
        var json = false
        var seconds: Int? = nil
        for word in rest {
            if word == "--json" {
                guard !json else { return nil }
                json = true
            } else if seconds == nil, !word.isEmpty, word.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
                      let n = Int(word), smsUnblockSecondsRange.contains(n) {
                seconds = n
            } else {
                return nil
            }
        }
        return .unblock(seconds: seconds ?? smsUnblockDefaultSeconds, json: json)
    default:
        return nil
    }
}

/// Assembles the stored parts written by `unblock` without reading them back from the modem (so they stay REC UNREAD).
func assembleUnblocked(_ parts: [StoredPdu], restoredCnmi: Bool) -> SmsUnblocked {
    let messages = assemble(parts.map(decodePart))
    let mms = messages.filter { $0.text == mmsNotificationText }.count
    return SmsUnblocked(stored: parts.count, mmsNotifications: mms, indices: parts.map { $0.index }.sorted(),
                        messages: messages, restoredCnmi: restoredCnmi)
}

/// The window's banner sentence after `Unblock`.
func smsUnblockSentence(_ result: SmsUnblocked) -> String {
    guard result.stored > 0 else {
        return result.restoredCnmi
            ? "Restored incoming message storage (AT+CNMI=2,1,0,0,0); no queued messages arrived."
            : "No queued messages arrived."
    }
    let mms = result.mmsNotifications > 0
        ? " (\(result.mmsNotifications) MMS \(result.mmsNotifications == 1 ? "notification" : "notifications"))"
        : ""
    return "Unblocked incoming messages: stored \(result.stored) part(s)\(mms)."
}

/// What `RMNet sms unblock` prints.
func smsUnblockLines(_ result: SmsUnblocked, seconds: Int, time: (Date) -> String) -> [String] {
    guard result.stored > 0 else {
        if result.restoredCnmi {
            return ["sms: restored incoming message storage (AT+CNMI=2,1,0,0,0); no queued messages arrived in \(seconds) s"]
        }
        return ["sms: no queued messages arrived in \(seconds) s"]
    }
    let mms = result.mmsNotifications > 0
        ? " (\(result.mmsNotifications) MMS \(result.mmsNotifications == 1 ? "notification" : "notifications"))"
        : ""
    var lines = ["sms: unblocked: stored \(result.stored) part(s), \(result.messages.count) message(s)\(mms)"]
    for m in result.messages {
        let indices = "[" + m.indices.map(String.init).joined(separator: ",") + "]"
        guard m.readable else {
            lines.append("\(indices) not readable")
            continue
        }
        var head = "\(indices) \(m.unread ? "unread" : "read") \(m.sender) \(m.timestamp.map(time) ?? "no time")"
        if m.missingParts > 0 { head += " (\(m.missingParts) part(s) missing)" }
        lines.append(head)
        if m.text.isEmpty { continue }
        for line in m.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines.append("  \(line)")
        }
    }
    return lines
}

/// `sms unblock --json`: the summary counts, the stored indices, and `messages` in `sms list --json`'s form.
func smsUnblockJSON(_ result: SmsUnblocked, time: (Date) -> String) -> [String: Any] {
    ["indices": result.indices, "messages": smsListJSON(result.messages, time: time),
     "mmsNotifications": result.mmsNotifications, "restoredCnmi": result.restoredCnmi, "storedParts": result.stored]
}
