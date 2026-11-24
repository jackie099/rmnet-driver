// Text messages on the modem: lists, deletes and sends them over the spare AT port, with the model in
// SmsModel.swift doing all the reading and writing of PDUs. Each call opens the port, works and closes
// it, also on failure; a port is never used again after a failure other than the modem's own refusal (AtPort closes
// itself on a timeout). Calls are synchronous and must not be made on the main thread. Nothing here logs or stores
// message text or numbers on the Mac: they go only to the caller, and to the modem's own store.
//
// A message is sent from the modem's store (3GPP TS 27.005; Quectel's AT manual for the RM520N series, 8.10 and
// 8.11): each part is written with AT+CMGW (stored "unsent"), then sent with AT+CMSS, after which the modem keeps it
// as "sent". So a sent message is listed with the received ones (AT+CMGL), by the window and by `RMNet sms list`, and
// a part whose AT+CMSS failed stays stored as "unsent", for Retry (resend) or Delete. The modem gives a stored
// SMS-SUBMIT no time. When the modem lists one storage and writes to another (AT+CPMS: <mem1> differs from <mem2>), a
// stored message would never be listed, so the message is sent directly with AT+CMGS, as before, and not stored.
//
// The window deletes and sends again what it listed, by stored index; another program (`RMNet sms delete`, say) may
// have changed the store since, and the modem fills the lowest free index, so an index can hold another message by
// then. So a delete or a Retry from the window first checks, in the same session, that the module (its USB serial
// number: one that gives none is never taken for the same), the SIM (its IMSI, needed to send and for a store on the
// SIM) and the storages are those of the listing, and that every part is still there as listed, its raw PDU unchanged
// (AT+CMGL=1, 2 and 3, which change no status: only an unread entry that is listed is made read, 8.6); if not, it does
// nothing and the window lists again.
//
// What became of each part sent from the store is kept across runs in the record of sent messages
// (SmsSendLedger.swift), shared with `RMNet sms send`: written, confirmed sent (+CMSS), or not known. A listing marks a
// part the record confirms as sent (never offered for Retry, also when the modem still lists it as unsent), and Retry
// refuses one. A send reports apart what reached the network and what is kept on the modem (a copy as sent that could
// not be written, a part still listed as unsent) and in the record.
//
// AT+CMGL and AT+CMGR have no mode that leaves an unread message unread in the RM520N's manual (8.6, 8.7: listing or
// reading a "REC UNREAD" entry makes it "REC READ"), so the background check for new messages never lists or reads one:
// countUnread counts the entries that are not unread (AT+CMGL=1, 2, 3) and takes them from the store's count.
import Foundation

/// The port the service talks to: AtPort, or a scripted port in the tests.
protocol SmsPort: AnyObject {
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError>
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError>
    func listen(duration: TimeInterval, extendOnDelivery: TimeInterval, maxDuration: TimeInterval) -> Result<Void, AtError>
    func takeDeliveries() -> [AtDeliveredPdu]
    func close()
    /// The module the port is open on (AtPort.deviceSerial).
    var deviceSerial: String? { get }
}

extension SmsPort {
    func listen(duration: TimeInterval, extendOnDelivery: TimeInterval, maxDuration: TimeInterval) -> Result<Void, AtError> {
        .success(())
    }
    func takeDeliveries() -> [AtDeliveredPdu] { [] }
}

extension AtPort: SmsPort {}

/// One open port and the failure that ended its use: after anything but the modem's own refusal nothing more is sent
/// on it (AtPort has closed itself after a timeout, and after an I/O error the port is not trusted); a later command
/// fails at once with that failure.
private final class SmsSession {
    let port: SmsPort
    private(set) var broken: AtError?

    init(_ port: SmsPort) { self.port = port }

    var usable: Bool { broken == nil }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        note(broken.map { .failure($0) } ?? port.command(line, timeout: timeout))
    }

    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        note(broken.map { .failure($0) } ?? port.send(line, afterPrompt: payload, timeout: timeout))
    }

    private func note(_ result: Result<[String], AtError>) -> Result<[String], AtError> {
        if case .failure(let error) = result, broken == nil, !isModemRefusal(error) { broken = error }
        return result
    }
}

private func isModemRefusal(_ error: AtError) -> Bool {
    if case .modem = error { return true }
    return false
}

final class SmsService: SmsServing {
    private static let readTimeout: TimeInterval = 3
    private static let listTimeout: TimeInterval = 15    // up to 255 stored entries
    private static let deleteTimeout: TimeInterval = 10
    private static let writeTimeout: TimeInterval = 10   // AT+CMGW: the manual says 300 ms
    private static let sendTimeout: TimeInterval = 120   // per part: AT+CMGS and AT+CMSS, "120 s, determined by network"
    private static let sliceFirstDuration: TimeInterval = 0.55
    private static let sliceDuration: TimeInterval = 0.70 // keeps every port open under 1 s (< AtPort.busyLimit 2 s)
    private static let sliceExtend: TimeInterval = 0.5
    private static let sliceMaxDuration: TimeInterval = 1.4
    private static let slicePause: TimeInterval = 0.35

    private let openPort: () -> Result<SmsPort, AtError>
    private let ledger: SmsSendLedgerKeeping?
    private let healCnmiOnOpen: Bool
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date

    /// `waitForPort` false: a port another program holds fails as busy at once (AtPort.openWithoutWaiting), for the
    /// app's background count of new messages, which then tries again on a later turn.
    convenience init(waitForPort: Bool = true) {
        self.init(open: waitForPort ? { AtPort.open().map { $0 as SmsPort } }
                                    : { AtPort.openWithoutWaiting().map { $0 as SmsPort } },
                  ledger: SmsSendLedgerFile.standard, healCnmiOnOpen: true)
    }

    /// `ledger`: the record of sent messages (nil: none is kept or read).
    init(open: @escaping () -> Result<SmsPort, AtError>, ledger: SmsSendLedgerKeeping? = nil, healCnmiOnOpen: Bool = false,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> Date = { Date() }) {
        openPort = open
        self.ledger = ledger
        self.healCnmiOnOpen = healCnmiOnOpen
        self.sleep = sleep
        self.now = now
    }

    // The listing, then the store's use and storages (AT+CPMS?) and the SIM (AT+CIMI) in the same session; if those
    // cannot be read the listing still succeeds, without them (its place is then not complete: nothing listed can be
    // deleted or sent again from the window until a listing has them).
    func list() -> Result<SmsListing, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) { return .failure(failure) }
        if healCnmiOnOpen { healCnmiIfNeeded(on: session) }
        switch session.command("AT+CMGL=4", timeout: SmsService.listTimeout) {
        case .success(let lines):
            let parts = parseListing(lines)
            let messages = assemble(parts.map(decodePart))
            var store: (used: Int, total: Int)? = nil
            var place = SmsPlace(device: port.deviceSerial)
            switch readPlace(session) {
            case .success(let read):
                store = read.store
                place = read.place
            case .failure:
                place.complete = false
            }
            var listing = SmsListing(messages: messages, used: store?.used, total: store?.total, parts: parts,
                                     place: place)
            noteRecord(on: &listing)
            return .success(listing)
        case .failure(let error):
            return .failure(SmsFailure(message: "The messages could not be listed. \(describe(error))"))
        }
    }

    // Each index once, the first of each kept; the count is of the deletes the modem answered "OK".
    func delete(indices given: [Int]) -> Result<Int, SmsFailure> {
        var seen = Set<Int>()
        let indices = given.filter { seen.insert($0).inserted }
        guard !indices.isEmpty else { return .success(0) }
        guard indices.allSatisfy({ $0 >= 0 }) else {
            return .failure(SmsFailure(message: "A stored index is negative. Nothing was deleted."))
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was deleted."))
        }
        defer { port.close() }
        return deleteEach(indices, on: SmsSession(port))
    }

    /// The window's delete: every part checked first (checkListed), then deleted as `delete(indices:)` does.
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure> {
        var seen = Set<Int>()
        let targets = parts.filter { seen.insert($0.index).inserted }
        guard !targets.isEmpty else { return .success(0) }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was deleted."))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) ?? checkListed(targets, listedFrom: place, sending: false, on: session) {
            return .failure(failure.adding(" Nothing was deleted."))
        }
        return deleteEach(targets.map { $0.index }, on: session)
    }

    private func deleteEach(_ indices: [Int], on session: SmsSession) -> Result<Int, SmsFailure> {
        var deleted = 0
        for index in indices {
            if case .failure(let error) = session.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) {
                let before = "\(deleted) of \(indices.count) stored part(s) were deleted before it."
                // Only the modem's own refusal says the entry is still there; after no answer in time or an
                // I/O error the modem may have deleted it.
                if case .modem = error {
                    return .failure(SmsFailure(message: "Stored part \(index) could not be deleted. \(describe(error)) \(before)"))
                }
                return .failure(SmsFailure(message: "Deleting stored part \(index) failed. \(describe(error)) "
                                           + "It is not known whether it was deleted; \(before)"))
            }
            deleted += 1
        }
        return .success(deleted)
    }

    /// Writes every part to the store (AT+CMGW=<length>,2), then sends each from there (AT+CMSS=<index>). A part that
    /// could not be written leaves nothing sent: the parts written before it are deleted again while the port still
    /// works. A part whose send failed stays stored as unsent, with the parts after it (Retry, Delete). With <mem1> and
    /// <mem2> different, or AT+CPMS? refused or without names, the parts are sent with AT+CMGS and not stored. When
    /// AT+CPMS? got no answer the port is not used again: nothing has been sent, so a new port is opened once for it.
    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        // The model checks the number and the length first, so a bad request never opens the port.
        let parts: [SubmitPdu]
        switch encodeSubmit(to: number, text: text, reference: UInt8.random(in: 0...255)) {
        case .success(let p): parts = p
        case .failure(let failure): return .failure(failure)
        }
        // Where the modem would store the parts: AT+CPMS? on a port in PDU mode. With no answer that port is not used
        // again; nothing has been sent, so one new port is opened for it.
        var port: SmsPort? = nil
        defer { port?.close() }
        var opened: SmsSession? = nil
        var stores: Bool? = nil
        var storage: String? = nil
        var unanswered: AtError = .timeout
        for _ in 0..<2 {
            port?.close()
            switch openPort() {
            case .success(let p): port = p
            case .failure(let error):
                port = nil
                return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
            }
            let s = SmsSession(port!)
            opened = s
            if let failure = usePduMode(s) {
                return .failure(SmsFailure(message: "\(failure.message) Nothing was sent."))
            }
            switch s.command("AT+CPMS?", timeout: SmsService.readTimeout) {
            case .success(let lines):
                let names = parseStorageNames(lines)
                stores = names.map { $0.read == $0.write } ?? false
                storage = names?.write
            case .failure(let error): if isModemRefusal(error) { stores = false } else { unanswered = error }
            }
            if stores != nil { break }
        }
        guard let stores, let session = opened else {
            return .failure(SmsFailure(message: "Where the modem stores messages could not be read. "
                                       + "\(describe(unanswered)) Nothing was sent."))
        }
        guard stores else { return sendDirectly(parts, on: session) }
        // Who sends, for the record of sent messages: the module, the SIM (AT+CIMI) and the storage written to.
        var imsi: String? = nil
        if case .success(let lines) = session.command("AT+CIMI", timeout: SmsService.readTimeout) { imsi = parseImsi(lines) }
        let sender = Sender(module: session.port.deviceSerial, imsi: imsi, storage: storage)

        var written: [(index: Int, hex: String)] = []
        var unrecorded: String? = nil
        for (n, part) in parts.enumerated() {
            let reason: String
            switch session.send("AT+CMGW=\(part.tpduLength),2", afterPrompt: part.hex, timeout: SmsService.writeTimeout) {
            case .success(let lines):
                if let index = parseStoreIndex(lines) {
                    written.append((index, part.hex))
                    unrecorded = unrecorded ?? recordParts([(index, part.hex)], .written, by: sender)
                    continue
                }
                reason = "The modem did not say where it stored it (no +CMGW line)."
            case .failure(let error):
                reason = describe(error)
            }
            // Nothing was sent: the parts written so far go again, while the port works.
            var left = written.count
            if session.usable {
                for w in written {
                    if case .success = session.command("AT+CMGD=\(w.index)", timeout: SmsService.deleteTimeout) { left -= 1 }
                }
            }
            let which = parts.count == 1 ? "The message" : "Part \(n + 1) of \(parts.count)"
            var message = "\(which) could not be stored on the modem. \(reason) Nothing was sent."
            if left > 0 { message += " Parts already stored are listed as Not sent." }
            return .failure(SmsFailure(message: message, record: SmsSendRecord(unrecorded: unrecorded),
                                       reachedModem: left > 0))
        }
        return sendStored(written, on: session, by: sender, unrecorded: unrecorded)
    }

    /// Who sends a stored part: the module, the SIM's IMSI and the storage written to (the record of sent messages'
    /// key, SmsPartKey).
    private struct Sender {
        let module: String?
        let imsi: String?
        let storage: String?
    }

    /// Records parts in the record of sent messages; nil when recorded (or none is kept), else why not.
    private func recordParts(_ parts: [(index: Int, hex: String)], _ state: SmsPartState, by sender: Sender) -> String? {
        guard let ledger, !parts.isEmpty else { return nil }
        let keys = parts.compactMap { SmsPartKey(module: sender.module, imsi: sender.imsi, storage: sender.storage,
                                                 index: $0.index, hex: $0.hex) }
        guard keys.count == parts.count else {
            return "the modem gives no USB serial number, or its SIM could not be identified."
        }
        let at = now()
        return ledger.record(keys.map { SmsLedgerEvent(time: at, key: $0, state: state) })
    }

    /// A listing's unsent parts as the record of sent messages knows them (confirmed sent, or not known).
    private func noteRecord(on listing: inout SmsListing) {
        guard let ledger, listing.place.complete, listing.parts.contains(where: { $0.status == .unsent }) else { return }
        switch ledger.states() {
        case .failure(let why):
            listing.ledgerProblem = why.message
        case .success(let states):
            for p in listing.parts where p.status == .unsent {
                guard let key = SmsPartKey(module: listing.place.device, imsi: listing.place.sim,
                                           storage: listing.place.listsFrom, index: p.index, hex: p.hex) else { continue }
                switch states[key] {
                case .confirmed?: listing.sentConfirmed.insert(p.index)
                case .unknown?: listing.sendUnknown.insert(p.index)
                default: break
                }
            }
        }
    }

    /// The window's Retry: the listed unsent parts checked first (checkListed: still unsent, as listed, where listed),
    /// then sent again from the store (AT+CMSS).
    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure> {
        var seen = Set<Int>()
        let targets = parts.filter { seen.insert($0.index).inserted }
        guard !targets.isEmpty, targets.allSatisfy({ $0.index >= 0 && $0.status == .unsent }) else {
            return .failure(SmsFailure(message: "There is nothing stored to send. Nothing was sent."))
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) ?? checkListed(targets, listedFrom: place, sending: true, on: session) {
            return .failure(failure.adding(" Nothing was sent."))
        }
        // A part RMNet confirmed sent is never sent again, also when the modem still lists it as unsent.
        let sender = Sender(module: place.device, imsi: place.sim, storage: place.writesTo)
        if let ledger {
            switch ledger.states() {
            case .failure(let why):
                return .failure(SmsFailure(message: "RMNet cannot tell whether these parts were sent already: "
                                           + "\(why.message) Nothing was sent."))
            case .success(let states):
                for part in targets {
                    if let key = SmsPartKey(module: sender.module, imsi: sender.imsi, storage: sender.storage,
                                            index: part.index, hex: part.hex), states[key] == .confirmed {
                        return .failure(SmsFailure(message: "Stored part \(part.index) was sent already (the modem "
                                                   + "confirmed it); it is not sent again. Nothing was sent.",
                                                   listingChanged: true))
                    }
                }
            }
        }
        return sendStored(targets.map { ($0.index, $0.hex) }, on: session, by: sender, unrecorded: nil)
    }

    /// AT+CMSS for each stored part in turn; after each that went, its stored status is made "sent" (markSent). A part
    /// the modem refused was not sent; after any other failure it is not known (sendFailure). Either way it and the
    /// parts after it stay stored as unsent. What became of each part is in the result's record, and in the record of
    /// sent messages as soon as it is known (confirmed, or not known).
    private func sendStored(_ stored: [(index: Int, hex: String)], on session: SmsSession, by sender: Sender,
                            unrecorded firstProblem: String?) -> Result<SmsSent, SmsFailure> {
        var record = SmsSendRecord(unrecorded: firstProblem)
        func note(_ parts: [(index: Int, hex: String)], _ state: SmsPartState) {
            if let problem = recordParts(parts, state, by: sender), record.unrecorded == nil { record.unrecorded = problem }
        }
        for (n, part) in stored.enumerated() {
            let reason: String
            let known: Bool
            switch session.command("AT+CMSS=\(part.index)", timeout: SmsService.sendTimeout) {
            case .success(let lines):
                if parseStoredSendReference(lines) != nil {
                    let marked = markSent(part.index, written: part.hex, on: session)
                    var confirmed = [(part.index, marked.hex)]
                    if let copy = marked.sentAt, copy != part.index { confirmed.append((copy, marked.hex)) }
                    note(confirmed, .confirmed)
                    if let at = marked.sentAt { record.sent.append(StoredPart(index: at, hex: marked.hex)) }
                    else { record.unarchived += 1 }
                    if marked.stillUnsent { record.stillUnsent.append(StoredPart(index: part.index, hex: marked.hex)) }
                    continue
                }
                reason = "The modem did not confirm it with a +CMSS line."
                known = false
            case .failure(let error):
                reason = describe(error)
                known = isModemRefusal(error)
            }
            if !known {
                record.unknown.append(StoredPart(index: part.index, hex: part.hex))
                note([part], .unknown)
            }
            return .failure(SmsFailure(message: sendFailure(part: n, of: stored.count, reason: reason, known: known)
                                       + " It is kept on the modem as Not sent: Retry sends it, Delete removes it.",
                                       record: record, reachedModem: true))
        }
        return .success(SmsSent(parts: stored.count, indices: record.sent.map { $0.index }, record: record))
    }

    /// The modem should list a part it sent from its store as "sent". One that still says "unsent" (AT+CMGR) is deleted
    /// and written again as sent (AT+CMGD, then AT+CMGW=<length>,3: the delete frees the place the copy needs), so it is
    /// not offered for Retry. `sentAt`: where the part is stored as sent now (nil: its copy could not be written, so it
    /// is no longer stored); `stillUnsent`: the part is still stored as unsent at its index, or that is not known (its
    /// status could not be read, or the delete failed), though it was sent; `hex`: its raw PDU as stored.
    private func markSent(_ index: Int, written: String, on session: SmsSession) -> (sentAt: Int?, stillUnsent: Bool, hex: String) {
        guard case .success(let lines) = session.command("AT+CMGR=\(index)", timeout: SmsService.readTimeout),
              let entry = parseReadEntry(lines) else {
            return (index, true, written)
        }
        guard entry.status == .unsent, let length = submitLength(entry.hex) else { return (index, false, entry.hex) }
        guard case .success = session.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) else {
            return (index, true, entry.hex)
        }
        guard case .success(let answer) = session.send("AT+CMGW=\(length),3", afterPrompt: entry.hex,
                                                       timeout: SmsService.writeTimeout),
              let copy = parseStoreIndex(answer) else { return (nil, false, entry.hex) }
        return (copy, false, entry.hex)
    }

    /// AT+CMGS for each part, as before stored sending: when the modem would store where it does not list.
    private func sendDirectly(_ parts: [SubmitPdu], on session: SmsSession) -> Result<SmsSent, SmsFailure> {
        for (n, part) in parts.enumerated() {
            let result = session.send("AT+CMGS=\(part.tpduLength)", afterPrompt: part.hex, timeout: SmsService.sendTimeout)
            // A refusal from the modem means this part did not go; any other failure (no answer in time, an
            // I/O error, an "OK" without "+CMGS:") may come after the modem took the part, so it is not known.
            let reason: String
            let known: Bool
            switch result {
            case .success(let lines):
                if parseSendReference(lines) != nil { continue }
                reason = "The modem did not confirm it with a +CMGS line."
                known = false
            case .failure(let error):
                reason = describe(error)
                known = isModemRefusal(error)
            }
            return .failure(SmsFailure(message: sendFailure(part: n, of: parts.count, reason: reason, known: known),
                                       reachedModem: n > 0 || !known))
        }
        return .success(SmsSent(parts: parts.count, indices: [], stored: false))
    }

    /// The background count: the store's entries (AT+CPMS?) less those that are read, unsent or sent (AT+CMGL=1, 2, 3)
    /// are the unread ones, none of which is listed or read (so none is made read). The store's count read again after
    /// the lists must be the same (a message that came in meanwhile is counted on a later turn).
    func countUnread() -> Result<SmsStoreCount, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) { return .failure(failure) }
        if healCnmiOnOpen { healCnmiIfNeeded(on: session) }
        func used() -> Result<Int, SmsFailure> {
            switch session.command("AT+CPMS?", timeout: SmsService.readTimeout) {
            case .success(let lines):
                guard let store = parseStorage(lines) else {
                    return .failure(SmsFailure(message: "The modem did not say how full its message store is."))
                }
                return .success(store.used)
            case .failure(let error):
                return .failure(SmsFailure(message: "The message store could not be read. \(describe(error))"))
            }
        }
        let before: Int
        switch used() {
        case .success(let n): before = n
        case .failure(let f): return .failure(f)
        }
        var counts: [Int] = []
        for stat in 1...3 {
            switch session.command("AT+CMGL=\(stat)", timeout: SmsService.listTimeout) {
            case .success(let lines): counts.append(listedCount(lines))
            case .failure(let error):
                return .failure(SmsFailure(message: "The messages could not be counted. \(describe(error))"))
            }
        }
        guard case .success(let after) = used(), after == before else {
            return .failure(SmsFailure(message: "The message store changed while it was counted."))
        }
        let unread = before - counts.reduce(0, +)
        guard unread >= 0 else { return .failure(SmsFailure(message: "The message store's count does not add up.")) }
        return .success(SmsStoreCount(used: before, received: unread + counts[0], unread: unread))
    }

    // MARK: Checking what was listed

    /// The store's use and storages (AT+CPMS?) and the SIM's IMSI (AT+CIMI: refused, as with no SIM, is none); a
    /// failure when either got no answer or AT+CPMS? was refused. Without storage names the place is not complete.
    private func readPlace(_ session: SmsSession) -> Result<(place: SmsPlace, store: (used: Int, total: Int)?), AtError> {
        let storage: [String]
        switch session.command("AT+CPMS?", timeout: SmsService.readTimeout) {
        case .success(let lines): storage = lines
        case .failure(let error): return .failure(error)
        }
        var sim: String? = nil
        switch session.command("AT+CIMI", timeout: SmsService.readTimeout) {
        case .success(let lines): sim = parseImsi(lines)
        case .failure(let error): if !isModemRefusal(error) { return .failure(error) }
        }
        let names = parseStorageNames(storage)
        var place = SmsPlace(device: session.port.deviceSerial, sim: sim, listsFrom: names?.read, writesTo: names?.write)
        place.complete = names != nil
        return .success((place, parseStorage(storage)))
    }

    /// Whether the listed `parts` are still where and what they were: the same module, SIM and storages (and, to send
    /// again, <mem2> the same as <mem1>: AT+CMSS sends from <mem2>), and each part at its index with the same status
    /// (a received one is read by now: the listing made it read) and the same PDU. nil when so; else why not, with
    /// listingChanged set when the listing is out of date.
    private func checkListed(_ parts: [StoredPdu], listedFrom listed: SmsPlace, sending: Bool,
                             on session: SmsSession) -> SmsFailure? {
        let changed = "The messages on the modem changed since they were listed:"
        guard listed.complete else {
            return SmsFailure(message: "Where the messages are stored was not known when they were listed. List them again.",
                              listingChanged: true)
        }
        // The module: known on both sides and the same (two modules that give no serial number are not the same one).
        guard let device = listed.device, let here = session.port.deviceSerial else {
            return SmsFailure(message: "RMNet cannot tell which modem this is (it gives no USB serial number), so it "
                              + "changes nothing listed.")
        }
        guard here == device else {
            return SmsFailure(message: "\(changed) another modem is attached.", listingChanged: true)
        }
        let now: SmsPlace
        switch readPlace(session) {
        case .success(let read): now = read.place
        case .failure(let error):
            return SmsFailure(message: "The modem could not be checked before the change. \(describe(error))")
        }
        guard now.complete, now.listsFrom == listed.listsFrom, now.writesTo == listed.writesTo else {
            return SmsFailure(message: "\(changed) it stores them in another place now.", listingChanged: true)
        }
        // The SIM: known and the same to send, or when the messages are stored on the SIM; else only the same.
        if sending || listed.listsFrom == "SM" {
            guard listed.sim != nil, now.sim != nil else {
                return SmsFailure(message: "RMNet cannot tell which SIM is in use (AT+CIMI gave no IMSI), so it changes "
                                  + "nothing listed.")
            }
        }
        guard now.sim == listed.sim else {
            return SmsFailure(message: "\(changed) another SIM is in use.", listingChanged: true)
        }
        if sending, now.listsFrom != now.writesTo {
            return SmsFailure(message: "The modem sends from another storage than the one it lists, so a listed part "
                              + "cannot be sent again.")
        }
        // Where each part may be now: a received one read (1); an unsent one unsent (2), or, for a delete, sent (3)
        // (its send was confirmed late); a sent one sent.
        func allowed(_ status: SmsStatus) -> [SmsStatus] {
            switch status {
            case .unread, .read: return [.read]
            case .unsent: return sending ? [.unsent] : [.unsent, .sent]
            case .sent: return [.sent]
            }
        }
        let wanted = Set(parts.flatMap { allowed($0.status) })
        var found: [Int: StoredPdu] = [:]
        for status in [SmsStatus.read, .unsent, .sent] where wanted.contains(status) {
            switch session.command("AT+CMGL=\(status.rawValue)", timeout: SmsService.listTimeout) {
            case .success(let lines):
                for entry in parseListing(lines) where entry.status == status { found[entry.index] = entry }
            case .failure(let error):
                return SmsFailure(message: "The stored messages could not be checked. \(describe(error))")
            }
        }
        for part in parts {
            guard let now = found[part.index], allowed(part.status).contains(now.status),
                  now.hex.uppercased() == part.hex.uppercased() else {
                return SmsFailure(message: "\(changed) stored part \(part.index) is not the one listed.",
                                  listingChanged: true)
            }
        }
        return nil
    }

    // Reads the message format and switches to PDU mode (0) if it is text mode (1); the setting is not
    // saved. Any other answer is a failure.
    private func usePduMode(_ session: SmsSession) -> SmsFailure? {
        let lines: [String]
        switch session.command("AT+CMGF?", timeout: SmsService.readTimeout) {
        case .success(let l): lines = l
        case .failure(let error):
            return SmsFailure(message: "The message format could not be read. \(describe(error))")
        }
        let mode = lines.lazy
            .filter { $0.hasPrefix("+CMGF:") }
            .compactMap { Int($0.dropFirst("+CMGF:".count).trimmingCharacters(in: .whitespaces)) }
            .first
        switch mode {
        case 0:
            return nil
        case 1:
            if case .failure(let error) = session.command("AT+CMGF=0", timeout: SmsService.readTimeout) {
                return SmsFailure(message: "The modem could not be put in PDU mode. \(describe(error))")
            }
            return nil
        default:
            return SmsFailure(message: "The modem did not say which message format it uses.")
        }
    }

    // MARK: Unblocking incoming messages and healing AT+CNMI

    /// Streams queued incoming messages across short port opens: the first checks `AT+CPMS?` and sets `AT+CNMI=2,2,0,0,0`
    /// (left on across the 0.35 s pauses so the carrier's retry never meets `2,1`, while any `+CMT` read during a pause is
    /// buffered by the modem or written to the store on close by `AtPort`), middle opens listen for 0.70 s (~0.85 s port
    /// hold, well under `AtPort.busyLimit`), and the final open puts `AT+CNMI=2,1,0,0,0` back. Stops early once a pass has
    /// received messages and the following pass is quiet.
    func unblock(seconds: Int, shouldStop: () -> Bool) -> Result<SmsUnblocked, SmsFailure> {
        let totalSeconds = max(1, seconds)
        if totalSeconds == 1 {
            return runUnblockSlice(listenDuration: SmsService.sliceFirstDuration, start: true, finish: true)
                .map { assembleUnblocked($0.parts, restoredCnmi: $0.restoredCnmi) }
        }
        let deadline = now().addingTimeInterval(TimeInterval(totalSeconds))
        var written: [StoredPdu] = []
        var restored = false
        var lastHadParts = false

        switch runUnblockSlice(listenDuration: SmsService.sliceFirstDuration, start: true, finish: false) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let first):
            lastHadParts = !first.parts.isEmpty
            written.append(contentsOf: first.parts)
            if first.restoredCnmi { restored = true }
        }

        loop: while !shouldStop() {
            if now() >= deadline && !lastHadParts { break loop }
            sleep(SmsService.slicePause)
            if shouldStop() { break loop }
            let left = deadline.timeIntervalSince(now())
            let duration = min(SmsService.sliceDuration, max(0.2, left))
            switch runUnblockSlice(listenDuration: duration, start: false, finish: false) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let slice):
                lastHadParts = !slice.parts.isEmpty
                written.append(contentsOf: slice.parts)
                // Once queued messages have arrived and a follow-up window sees no more, the queue has flushed.
                if !written.isEmpty && !lastHadParts { break loop }
            }
        }

        switch runUnblockSlice(listenDuration: 0, start: false, finish: true) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let tail):
            written.append(contentsOf: tail.parts)
            return .success(assembleUnblocked(written, restoredCnmi: restored))
        }
    }

    func unblockSlice(start: Bool, finish: Bool) -> Result<SmsUnblockSlice, SmsFailure> {
        let duration: TimeInterval = (finish && !start)
            ? 0
            : (start ? SmsService.sliceFirstDuration : SmsService.sliceDuration)
        return runUnblockSlice(listenDuration: duration, start: start, finish: finish)
    }

    /// Checks `AT+CNMI?` without enabling `2,2`, restoring `2,1,0,0,0` if an earlier crashed process left it otherwise
    /// and storing any rescued `+CMT` PDUs as unread.
    func healCnmi() -> Result<SmsUnblockSlice, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        let session = SmsSession(port)
        let rescued = AtPort.takeRescuedDeliveries() + port.takeDeliveries()
        if let failure = usePduMode(session) {
            AtPort.keepRescuedDeliveries(rescued)
            return .failure(failure)
        }
        var wasNot21 = false
        switch session.command("AT+CNMI?", timeout: SmsService.readTimeout) {
        case .success(let lines):
            if let cnmi = parseCnmi(lines), cnmi != (2, 1) { wasNot21 = true }
        case .failure(let error):
            AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
            return .failure(SmsFailure(message: "The incoming message setting could not be read. \(describe(error))"))
        }
        var restoreError: AtError? = nil
        if wasNot21 {
            if case .failure(let error) = session.command("AT+CNMI=2,1,0,0,0", timeout: SmsService.readTimeout) {
                restoreError = error
            }
        }
        let all = rescued + port.takeDeliveries()
        var written: [StoredPdu] = []
        if !all.isEmpty {
            switch storeDeliveries(all, on: session, checkRoom: true) {
            case .success(let stored): written = stored
            case .failure(let failure): return .failure(failure)
            }
        }
        if let restoreError {
            return .failure(SmsFailure(message: "Incoming message storage (AT+CNMI=2,1,0,0,0) could not be restored. "
                                       + describe(restoreError)))
        }
        return .success(SmsUnblockSlice(parts: written, restoredCnmi: wasNot21))
    }

    /// Best-effort check used on regular `list` and `countUnread` opens: restores `AT+CNMI=2,1,0,0,0` if an earlier
    /// crashed run left it otherwise, and stores any rescued `+CMT` PDUs while the store has room.
    private func healCnmiIfNeeded(on session: SmsSession) {
        let rescued = AtPort.takeRescuedDeliveries() + session.port.takeDeliveries()
        var wasNot21 = false
        if case .success(let lines) = session.command("AT+CNMI?", timeout: SmsService.readTimeout),
           let cnmi = parseCnmi(lines), cnmi != (2, 1) {
            wasNot21 = true
            _ = session.command("AT+CNMI=2,1,0,0,0", timeout: SmsService.readTimeout)
        }
        let all = rescued + session.port.takeDeliveries()
        guard !all.isEmpty else { return }
        if case .failure = storeDeliveries(all, on: session, checkRoom: true) {
            // Unwritten items were already put back into AtPort.keepRescuedDeliveries by storeDeliveries.
        }
        _ = wasNot21
    }

    private func runUnblockSlice(listenDuration: TimeInterval, start: Bool, finish: Bool) -> Result<SmsUnblockSlice, SmsFailure> {
        var port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error):
            return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        var session = SmsSession(port)
        let rescued = AtPort.takeRescuedDeliveries() + port.takeDeliveries()
        var pduReady = false

        func ensurePduMode() -> SmsFailure? {
            if pduReady { return nil }
            if let failure = usePduMode(session) { return failure }
            pduReady = true
            return nil
        }

        func restoreCnmi() -> AtError? {
            if session.usable {
                switch session.command("AT+CNMI=2,1,0,0,0", timeout: SmsService.readTimeout) {
                case .success: return nil
                case .failure(let error) where isModemRefusal(error): return error
                case .failure: break
                }
            }
            // The port closed on a timeout or broke on I/O: open one new port to put AT+CNMI=2,1,0,0,0 back.
            let mid = port.takeDeliveries()
            port.close()
            switch openPort() {
            case .failure(let error):
                AtPort.keepRescuedDeliveries(mid)
                return error
            case .success(let fresh):
                port = fresh
                session = SmsSession(fresh)
                pduReady = false
                AtPort.keepRescuedDeliveries(mid)
                _ = ensurePduMode()
                if case .failure(let error) = session.command("AT+CNMI=2,1,0,0,0", timeout: SmsService.readTimeout) {
                    return error
                }
                return nil
            }
        }

        var wasNot21 = false
        var streamingActive = !start

        if start {
            if let failure = ensurePduMode() {
                AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                return .failure(failure)
            }
            switch session.command("AT+CNMI?", timeout: SmsService.readTimeout) {
            case .success(let lines):
                if let cnmi = parseCnmi(lines), cnmi != (2, 1) { wasNot21 = true }
            case .failure(let error) where !isModemRefusal(error):
                AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                return .failure(SmsFailure(message: "The incoming message setting could not be read. \(describe(error))"))
            case .failure:
                break
            }

            // Check that the store lists what it writes and has room before acknowledging anything from the network.
            switch session.command("AT+CPMS?", timeout: SmsService.readTimeout) {
            case .success(let lines):
                guard let names = parseStorageNames(lines), names.read == names.write else {
                    if wasNot21 { _ = restoreCnmi() }
                    AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                    return .failure(SmsFailure(message: "Incoming messages cannot be unblocked while the modem lists one "
                                               + "storage and writes to another (AT+CPMS)."))
                }
                guard let store = parseStorage(lines) else {
                    if wasNot21 { _ = restoreCnmi() }
                    AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                    return .failure(SmsFailure(message: "The modem did not say how full its message store is."))
                }
                if store.used + rescued.count >= store.total && rescued.isEmpty {
                    if wasNot21 { _ = restoreCnmi() }
                    return .failure(SmsFailure(message: "The modem's message store is full (\(store.used) of \(store.total)). "
                                               + "Delete old messages before unblocking incoming ones."))
                }
            case .failure(let error):
                if wasNot21 { _ = restoreCnmi() }
                AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                return .failure(SmsFailure(message: "The message store could not be read. \(describe(error))"))
            }

            if case .failure(let error) = session.command("AT+CNMI=2,2,0,0,0", timeout: SmsService.readTimeout) {
                if wasNot21 { _ = restoreCnmi() }
                AtPort.keepRescuedDeliveries(rescued + port.takeDeliveries())
                return .failure(SmsFailure(message: "Incoming message streaming could not be enabled. \(describe(error))"))
            }
            streamingActive = true
        }

        var listenOutcome: Result<Void, AtError> = .success(())
        if listenDuration > 0 {
            listenOutcome = port.listen(duration: listenDuration, extendOnDelivery: SmsService.sliceExtend,
                                        maxDuration: SmsService.sliceMaxDuration)
        }
        var preRestore: [AtDeliveredPdu] = []
        if case .failure = listenOutcome {
            preRestore = port.takeDeliveries()
            session = SmsSession(BrokenSmsPort())
            pduReady = false
        }

        let mustRestore: Bool
        if case .failure = listenOutcome {
            mustRestore = streamingActive || wasNot21
        } else {
            mustRestore = finish
        }
        var restoreError: AtError? = nil
        if mustRestore {
            if session.usable { _ = ensurePduMode() }
            restoreError = restoreCnmi()
            if restoreError == nil { streamingActive = false }
        }

        let all = AtPort.takeRescuedDeliveries() + rescued + preRestore + port.takeDeliveries()
        var written: [StoredPdu] = []
        if !all.isEmpty {
            if let failure = ensurePduMode() {
                AtPort.keepRescuedDeliveries(all)
                if streamingActive { _ = restoreCnmi() }
                return .failure(failure)
            }
            switch storeDeliveries(all, on: session, checkRoom: false) {
            case .success(let stored):
                written = stored
            case .failure(let failure):
                if streamingActive { _ = restoreCnmi() }
                return .failure(failure)
            }
        }
        if let restoreError {
            return .failure(SmsFailure(message: "Incoming message storage (AT+CNMI=2,1,0,0,0) could not be restored. "
                                       + describe(restoreError)))
        }
        if case .failure(let error) = listenOutcome, written.isEmpty {
            return .failure(SmsFailure(message: "Listening for incoming messages failed. \(describe(error))"))
        }
        return .success(SmsUnblockSlice(parts: written, restoredCnmi: wasNot21))
    }

    /// Writes each `+CMT` PDU to the modem's store as unread (`AT+CMGW=<length>,0`). Any PDUs not confirmed written are
    /// kept in `AtPort.keepRescuedDeliveries` (in memory only) so a later pass can still store them.
    private func storeDeliveries(_ deliveries: [AtDeliveredPdu], on session: SmsSession,
                                 checkRoom: Bool) -> Result<[StoredPdu], SmsFailure> {
        if checkRoom {
            guard case .success(let lines) = session.command("AT+CPMS?", timeout: SmsService.readTimeout),
                  let names = parseStorageNames(lines), names.read == names.write,
                  let store = parseStorage(lines), store.used < store.total else {
                AtPort.keepRescuedDeliveries(deliveries)
                return .failure(SmsFailure(message: "Received message(s) could not be stored on the modem."))
            }
        }
        var written: [StoredPdu] = []
        for (i, item) in deliveries.enumerated() {
            let length = submitLength(item.hex) ?? item.tpduLength
            let reason: String
            switch session.send("AT+CMGW=\(length),0", afterPrompt: item.hex, timeout: SmsService.writeTimeout) {
            case .success(let lines):
                if let index = parseStoreIndex(lines) {
                    written.append(StoredPdu(index: index, status: .unread, hex: item.hex))
                    continue
                }
                reason = "The modem did not say where it stored it (no +CMGW line)."
            case .failure(let error):
                reason = describe(error)
            }
            AtPort.keepRescuedDeliveries(Array(deliveries[i...]))
            let before = written.isEmpty ? "" : " \(written.count) of \(deliveries.count) part(s) were stored before it."
            return .failure(SmsFailure(message: "A received message could not be stored on the modem. \(reason)\(before)"))
        }
        return .success(written)
    }
}

private final class BrokenSmsPort: SmsPort {
    let deviceSerial: String? = nil
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> { .failure(.io(kIOReturnNotOpen)) }
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        .failure(.io(kIOReturnNotOpen))
    }
    func close() {}
}

private extension SmsFailure {
    func adding(_ tail: String) -> SmsFailure {
        SmsFailure(message: message + tail, listingChanged: listingChanged, record: record)
    }
}


/// The TPDU length of a stored PDU (its octets after the service centre field), as AT+CMGW takes it.
private func submitLength(_ hex: String) -> Int? {
    guard hex.count % 2 == 0, hex.count >= 2, let sc = Int(hex.prefix(2), radix: 16) else { return nil }
    let tpdu = hex.count / 2 - 1 - sc
    return tpdu > 0 ? tpdu : nil
}

// `part` counts from 0. Parts before it were confirmed by the modem. When it is not known whether the
// part went, the sentence warns that sending again may deliver it twice: the text is kept and Send works
// again, and each send costs the owner a fee.
private func sendFailure(part: Int, of total: Int, reason: String, known: Bool) -> String {
    let which = total == 1 ? "The message" : "Part \(part + 1) of \(total)"
    let state: String
    if known {
        state = part == 0 ? "Nothing was sent."
            : "\(part) of \(total) parts were sent; the message is incomplete at the receiver."
    } else if total == 1 {
        state = "It is not known whether it was sent."
    } else if part == 0 {
        state = "It is not known whether that part was sent; no other part was sent."
    } else {
        state = "It is not known whether that part was sent; \(part) of \(total) parts were sent before it, "
            + "so the message is incomplete at the receiver."
    }
    if known { return "\(which) was refused. \(reason) \(state)" }
    return "\(which) failed. \(reason) \(state) It may have been delivered; sending it again may deliver it twice."
}

// One sentence for each way the AT port can fail.
func describe(_ error: AtError) -> String {
    switch error {
    case .modemNotAttached:
        return "The RM520N-GL (USB 2c7c:0801) is not attached."
    case .noAtInterface:
        return "The modem has no spare AT port."
    case .busy:
        return "Another program is using the modem's spare AT port."
    case .timeout:
        return "The modem did not answer in time."
    case .modem(let line):
        return "The modem refused the command (\(line))."
    case .io(let status):
        return "An I/O error occurred on the modem's spare AT port (code \(String(format: "0x%08x", UInt32(bitPattern: status))))."
    }
}
