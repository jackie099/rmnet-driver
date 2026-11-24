// The modem's settings and the changes RMNet makes to them: the radio, the network mode, the USB network
// mode, the bands LTE and 5G may use, the data profiles (APN, user name, password, authentication) and the
// SIM's PIN. Here are the
// reading of their AT answers, the checks of what the owner types (also the one AT command `RMNet at`
// sends), the AT lines that change the modem, the questions asked before a change and the sentences said
// after it, and `ModemServing`, the interface of the service that does the I/O. Foundation only: pure
// functions over the answer lines (AtPort's lines between the echo and OK), so `make app-test` builds this
// file with ModemNetwork.swift alone. A missing field, `-` in place of a number, or a short line reads as
// "not known"; nothing here crashes on an odd answer.
//
// A profile's password is kept in memory only. No string conversion of any value here shows it (only
// whether one is set); the one text that holds it is `profileCommand`, the line sent to the modem.
import Foundation

// MARK: - Values

/// A sentence for the owner. A profile change that failed after its line may have reached the modem also
/// carries the profile's settings before it (ruling R19), so that the way back can be shown; nil otherwise.
/// A command sent by `at` that ended without OK carries how it ended, when `RMNet at` prints that its own
/// way (`atKind`); nil otherwise. Its string conversions show no password: ProfileSettings shows only
/// whether one is set.
struct ModemFailure: Error, Equatable {
    let message: String
    var profileBefore: ProfileSettings? = nil
    var atKind: AtFailureKind? = nil
}

/// How a command sent by `at` ended without OK: the modem's own error line (`ERROR`, `+CME ERROR: …`,
/// `+CMS ERROR: …`; the failure's message is that line), or no answer in the time given. Any other failure
/// of `at` (the port not opened, an I/O error) has none.
enum AtFailureKind: Equatable { case modemError, timeout }

/// So `error.localizedDescription` is the owner's sentence, not "The operation couldn't be completed".
extension ModemFailure: LocalizedError { var errorDescription: String? { message } }

/// AT+QICSGP <context_type>.
enum PdpType: Int, CaseIterable { case ipv4 = 1, ipv6 = 2, ipv4v6 = 3 }

/// AT+QICSGP <authentication>.
enum AuthMethod: Int, CaseIterable { case none = 0, pap = 1, chap = 2, papOrChap = 3 }

/// A profile's settings as AT+QICSGP reads and writes them. Interpolation, String(describing:),
/// String(reflecting:) and dump show `profileWords` and a mirror with `passwordSet` in place of the
/// password.
struct ProfileSettings: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var type: PdpType
    var apn: String
    var user: String
    var password: String            // in memory only: never printed, logged or stored
    var auth: AuthMethod

    var description: String { profileWords(self) }
    var debugDescription: String { profileWords(self) }
    var customMirror: Mirror {
        Mirror(self, children: ["type": type, "apn": apn, "user": user, "passwordSet": !password.isEmpty, "auth": auth],
               displayStyle: .struct)
    }
}

/// A profile as AT+CGDCONT? lists it (PDP type and APN display-safe), with its AT+QICSGP=<id> settings:
/// nil above 16 (AT+QICSGP takes profiles 1 to 16) or when they could not be read.
struct DataProfile: Equatable { let id: Int; let pdpType: String; let apn: String; let settings: ProfileSettings? }

/// AT+CPIN? READY, SIM PIN, SIM PUK, SIM PIN2, SIM PUK2; or its error line: +CME ERROR 10 (no SIM),
/// 13 (SIM failure), 14 (SIM busy); `other` holds any other answer, display-safe.
enum SimState: Equatable { case ready, pin, puk, pin2, puk2, notInserted, failure, busy, other(String) }

/// The SIM: its state, the PIN lock (AT+CLCK="SC",2) and the attempts left (AT+QPINC? "SC"); nil where
/// not read.
struct SimInfo: Equatable {
    let state: SimState; let pinLock: Bool?; let pinAttempts: Int?; let pukAttempts: Int?
    var activeSlot: Int? = nil      // AT+QUIMSLOT?: the slot in use (1 or 2); nil when not read
}

/// After AT+CFUN=1 or =4. Switched on: the registration last read, and the whole seconds until it was
/// registered (nil when it was not, within the wait). Switched off: both nil.
struct RadioChange: Equatable { let on: Bool; let registration: Registration?; let secondsToRegister: Int? }

/// mode_pref before and after a change, as the modem gave them.
struct ModeChange: Equatable { let before: String; let after: String }

/// What happened to the radio around a profile change: no redial asked; the radio was off, so it was left
/// off; switched off and on again; or left off after the change because it could not be switched on (why).
enum RedialResult: Equatable { case notAsked, radioWasOff, done(RadioChange), radioLeftOff(String) }

struct ProfileChange: Equatable { let id: Int; let before: ProfileSettings; let after: ProfileSettings; let redial: RedialResult }

/// Whether the SIM took the PIN, the SIM read again after it (nil when that read failed), and, when it was
/// not taken, the modem's error line (`+CME ERROR: 16` is a wrong PIN; another, such as 14, SIM busy, is not).
struct PinOutcome: Equatable {
    let accepted: Bool
    let sim: SimInfo?
    var refusal: String? = nil
}

/// AT+QCFG="usbnet" <net>: what the modem offers on USB for the network, in effect after a restart. 0 is
/// RMNET (QMI), the one mode this driver works in; 1 ECM, 2 MBIM, 3 RNDIS.
enum UsbNetMode: Int, CaseIterable {
    case qmi = 0, ecm = 1, mbim = 2, rndis = 3

    /// As `RMNet usbmode` prints and takes it.
    var name: String {
        switch self {
        case .qmi: return "qmi"
        case .ecm: return "ecm"
        case .mbim: return "mbim"
        case .rndis: return "rndis"
        }
    }
}

/// AT+QCFG="usbnet" as read: the number the modem gave, kept also when RMNet does not know it (`mode` nil).
struct UsbModeInfo: Equatable {
    let value: Int
    var mode: UsbNetMode? { UsbNetMode(rawValue: value) }
}

/// After a USB mode change: it was already that mode (nothing sent but the read); set and the modem told to
/// restart (it goes away from USB for about 30 s); or set, in effect at the next restart.
enum UsbModeChange: Equatable { case unchanged, rebooting, setTakesEffectAfterRestart }

/// The radio access technologies whose bands `RMNet bands` shows and locks, in the order it shows them:
/// LTE, 5G non-standalone (EN-DC) and 5G standalone.
enum BandRat: String, CaseIterable {
    case lte, nsa, sa

    /// Its AT+QNWPREFCFG setting, the bands it may use; also its line in AT+QNWPREFCFG="rf_band", the bands
    /// the modem's hardware supports (which a lock does not change).
    var key: String {
        switch self {
        case .lte: return "lte_band"
        case .nsa: return "nsa_nr5g_band"
        case .sa: return "nr5g_band"
        }
    }

    /// As `RMNet bands` prints it.
    var name: String {
        switch self {
        case .lte: return "LTE"
        case .nsa: return "5G NSA"
        case .sa: return "5G SA"
        }
    }
}

/// One RAT's bands: those it may use and those the modem supports, each sorted, each band once.
struct BandSet: Equatable { let rat: BandRat; let allowed: [Int]; let supported: [Int] }

/// A RAT's allowed bands before and after a change, each sorted, each band once; the same when nothing was
/// written (they were already the ones asked).
struct BandChange: Equatable { let before: [Int]; let after: [Int] }

/// One LTE cell in `AT+QNWLOCK="common/4g"`.
struct LteLockedCell: Equatable {
    let earfcn: Int
    let pci: Int
}

/// 5G SA cell lock parameters in `AT+QNWLOCK="common/5g"`.
struct NrCellLock: Equatable {
    let pci: Int
    let arfcn: Int
    let scsKHz: Int
    let band: Int
}

/// Parsed answer of `AT+QNWLOCK="common/5g"`.
enum ParsedNrCellLock: Equatable {
    case unlocked
    case locked(NrCellLock)
}

/// Complete cell-lock and reboot-persistence state (`AT+QNWLOCK`) plus optional neighbour cells.
struct CellLockState: Equatable {
    let lte: [LteLockedCell]
    let nr: NrCellLock?
    let persistLte: Bool
    let persistNr: Bool
    var neighbours: [NeighbourCell] = []

    var isLocked: Bool { !lte.isEmpty || nr != nil }
    var persistsAcrossReboot: Bool { persistLte || persistNr }
}

/// A cell the modem uses now, locked to only while it still does: the serving cell and the carriers are read again in
/// the same port session as the lock is written (ModemService.lockCellInUse), so a cell that has changed since the
/// caller looked is never locked to. `serving`: whatever serves now (`RMNet cell lock current`): its 5G SA leg, else
/// its LTE leg; `scsKHz` is the subcarrier spacing for a 5G SA cell the modem gives none for (never guessed: without
/// it the lock is refused). `nr`, `lte`: that cell (the window's Lock of a cell in use).
enum CellInUse: Equatable {
    case serving(scsKHz: Int?)
    case nr(NrCellLock)
    case lte(LteLockedCell)
}

/// What a cell in use is locked with, or why it is not (cellInUseLock).
enum CellInUseCheck: Equatable {
    case nr(NrCellLock)
    case lte(LteLockedCell)
    case refused(String)
}

/// Outcome of writing a cell lock or persistence setting.
enum CellLockChange: Equatable {
    case unchanged(CellLockState)
    case changed(before: CellLockState, after: CellLockState)
}

/// Outcome of writing a new IMEI via `AT+EGMR=1,7,"<imei>"`.
enum ImeiChange: Equatable {
    case unchanged(String)
    case rebooting(before: String, after: String)
    case setTakesEffectAfterRestart(before: String, after: String)
    /// Written and read back, but the restart asked for was refused or got no answer: `sentence` says which, and that
    /// the new IMEI takes effect at the next restart.
    case restartFailed(before: String, after: String, sentence: String)
}

/// What a change of the IMEI was confirmed for (the window's question, `imei set`'s): the module (its USB serial number)
/// and the IMEI it had then. The port that writes checks both first (ModemService.setImei) and writes nothing on another
/// module or over another IMEI.
struct ImeiExpectation: Equatable {
    let module: String
    let before: String
}

/// The IMEI and the module it was read on (the port's USB serial number; nil when the module gives none).
struct ImeiReading: Equatable {
    let imei: String
    let module: String?
}

/// An IMEI change as its own port session saw it (ModemService.setImei): the outcome, the module the port was opened on
/// (its USB serial number, AtPort.deviceSerial) and the IMEI read on that port before the write; each nil when not known
/// (the port did not open, the module gives no serial number, the read failed). The IMEI history records these, not
/// what was read on another port before or after.
struct ImeiWrite: Equatable {
    var outcome: Result<ImeiChange, ModemFailure>
    var module: String? = nil
    var before: String? = nil
}

/// The modem over its spare AT port. Each call blocks until done; callers keep it off the main thread.
protocol ModemServing {
    func networkInfo() -> Result<NetworkInfo, ModemFailure>
    func antennas() -> Result<[AntennaSignalSet], ModemFailure>
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure>
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure>          // one canonicalMode accepts (R8)
    func profiles() -> Result<[DataProfile], ModemFailure>
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure>
    func sim() -> Result<SimInfo, ModemFailure>
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure>
    func usbMode() -> Result<UsbModeInfo, ModemFailure>
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure>
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure>   // one atCommandProblem accepts
    func bands() -> Result<[BandSet], ModemFailure>                                  // in BandRat.allCases order
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> // refuses what bandsProblem does
    func cellLock() -> Result<CellLockState, ModemFailure>
    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure>
    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure>
    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure>
    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure>    // refuses what cellInUseProblem does
    func imei() -> Result<String, ModemFailure>
    /// The IMEI and the module of the port it was read on, in one port open (what a change is confirmed for).
    func imeiReading() -> Result<ImeiReading, ModemFailure>
    /// `expect`: write only on that module over that IMEI, checked on the port that writes (the window's Change… and
    /// Change Back…, `imei set`); nil: on any.
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite
    func simSlot() -> Result<Int, ModemFailure>                                       // AT+QUIMSLOT?
    /// `expect`: an automatic switch's expectation, checked on the port that writes (SimSlotExpectation); nil: none.
    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure>
}

extension ModemServing {
    /// On any module; the outcome only.
    func setImei(_ imei: String, reboot: Bool) -> Result<ImeiChange, ModemFailure> {
        setImei(imei, reboot: reboot, expect: nil).outcome
    }

    /// For services that cannot tell the module (the tests' fakes): the IMEI, on a module not known.
    func imeiReading() -> Result<ImeiReading, ModemFailure> {
        imei().map { ImeiReading(imei: $0, module: nil) }
    }

    /// Asked by the owner: no expectation.
    func setSimSlot(_ slot: Int, wait: SimSlotWait) -> Result<SimSlotChange, ModemFailure> {
        setSimSlot(slot, wait: wait, expect: nil)
    }
}

// MARK: - Answer lines

private func answerField(_ f: [String], _ i: Int) -> String? {
    i >= 0 && i < f.count ? f[i] : nil
}

/// A whole number; nil when the field is missing, empty, `-` or not a number.
private func answerInt(_ f: [String], _ i: Int) -> Int? {
    answerField(f, i).flatMap { Int($0) }
}

/// A count (attempts left): a whole number of at least 0.
private func answerCount(_ f: [String], _ i: Int) -> Int? {
    answerInt(f, i).flatMap { $0 >= 0 ? $0 : nil }
}

/// The fields of the first line with the prefix; nil when no line has it.
private func firstAnswer(_ lines: [String], _ prefix: String) -> [String]? {
    for line in lines {
        if let f = atFields(line, prefix: prefix) { return f }
    }
    return nil
}

// MARK: - Network mode

/// What the window offers, in this order. canonicalMode is in ModemNetwork.swift, with modeWords.
let networkModeChoices = ["AUTO", "LTE:NR5G", "NR5G", "LTE"]

/// AT+QNWPREFCFG="mode_pref",<mode>: written to the modem's NVM, in effect at once.
func modeCommand(_ mode: String) -> String {
    "AT+QNWPREFCFG=\"mode_pref\",\(mode)"
}

// MARK: - USB network mode

/// AT+QCFG="usbnet": `+QCFG: "usbnet",<net>`. nil without that line, or with no number in it.
func parseUsbMode(_ lines: [String]) -> UsbModeInfo? {
    for line in lines {
        if let f = atFields(line, prefix: "+QCFG"), answerField(f, 0) == "usbnet" {
            return answerInt(f, 1).map { UsbModeInfo(value: $0) }
        }
    }
    return nil
}

/// AT+QCFG="usbnet",<net>: kept by the modem, in effect at its next restart.
func usbModeCommand(_ mode: UsbNetMode) -> String {
    "AT+QCFG=\"usbnet\",\(mode.rawValue)"
}

/// `qmi`, `ecm`, `mbim`, `rndis`; `unknown (<n>)` for another number.
func usbModeName(_ value: Int) -> String {
    UsbNetMode(rawValue: value)?.name ?? "unknown (\(value))"
}

/// `RMNet usbmode --json`: `{"mode":"qmi","value":0,"driverWorks":true}`.
func usbModeJSON(_ info: UsbModeInfo) -> [String: Any] {
    ["mode": usbModeName(info.value), "value": info.value, "driverWorks": info.mode == .qmi]
}

// MARK: - Bands

/// Sorted, each band once.
func bandSorted(_ bands: [Int]) -> [Int] {
    Array(Set(bands)).sorted()
}

/// A band number as written: ASCII digits only (no sign, no space), at least 1; nil otherwise.
func parseBandNumber(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
          let n = Int(text), n >= 1 else { return nil }
    return n
}

/// The first line `+QNWPREFCFG: "<key>",<list>`, the list band numbers joined by `:` (`0` alone: none), in
/// quotes or not (rf_band quotes it, a RAT's own setting does not): the bands sorted, each once. nil without a
/// line for the key, or when its list is not such a list (an empty number, a letter or sign, a `0` among other
/// numbers, or a field after it).
func parseBandList(_ lines: [String], key: String) -> [Int]? {
    for line in lines {
        guard let f = atFields(line, prefix: "+QNWPREFCFG"), answerField(f, 0) == key else { continue }
        guard f.count == 2 else { return nil }
        if f[1] == "0" { return [] }
        var bands: [Int] = []
        for number in f[1].split(separator: ":", omittingEmptySubsequences: false) {
            guard let band = parseBandNumber(number) else { return nil }
            bands.append(band)
        }
        return bandSorted(bands)
    }
    return nil
}

/// AT+QNWPREFCFG="<key>",<b1>:<b2>:…, the bands sorted, each once: kept by the modem, in effect at once. Check
/// `bandsProblem` first (never an empty list, which would read as no list).
func bandsCommand(_ rat: BandRat, _ bands: [Int]) -> String {
    "AT+QNWPREFCFG=\"\(rat.key)\"," + bandSorted(bands).map { String($0) }.joined(separator: ":")
}

/// `3, 41`: ascending, each band once; `none` for no band.
func bandListWords(_ bands: [Int]) -> String {
    bands.isEmpty ? "none" : bandSorted(bands).map { String($0) }.joined(separator: ", ")
}

/// nil when `bands` may be written as `rat`'s bands; else why not: an empty list (the RAT would have no band
/// left), or bands the modem does not support, named, with the ones it does.
func bandsProblem(_ rat: BandRat, _ bands: [Int], supported: [Int]) -> String? {
    if bands.isEmpty { return "At least one \(rat.name) band is needed." }
    let unsupported = bandSorted(bands.filter { !supported.contains($0) })
    guard !unsupported.isEmpty else { return nil }
    return "The modem does not support \(rat.name) \(unsupported.count == 1 ? "band" : "bands") "
        + "\(bandListWords(unsupported)) (supported: \(bandListWords(supported)))."
}

/// The end of a sentence for a failure before `rat`'s write: `The 5G NSA bands were not changed.` (In `bands
/// reset` of all three an earlier RAT may have been set, so not "Nothing was changed.")
func bandsNotChanged(_ rat: BandRat) -> String {
    "The \(rat.name) bands were not changed."
}

/// `RMNet bands --json`, one RAT: `{"rat":"lte","allowed":[3,41],"supported":[1,2,…]}`.
func bandsJSON(_ set: BandSet) -> [String: Any] {
    ["rat": set.rat.rawValue, "allowed": set.allowed, "supported": set.supported]
}

// MARK: - One AT command as typed (`RMNet at`)

/// The longest command `RMNet at` sends, in characters.
let atCommandLimit = 512

/// The commands that answer with a "> " prompt and wait for a second stage (a message body, an SMS command
/// PDU) that one line cannot give, each with what `RMNet at` says about it. The modem may ignore spaces in a
/// command line and runs commands joined with `;`, so these are looked for anywhere in the line, spaces
/// removed (also inside a quoted string, which is refused too).
private let atPromptCommands: [(name: String, reason: String)] = [
    ("+CMGS", "AT+CMGS needs a message body; use RMNet sms send"),
    ("+CMGW", "AT+CMGW needs a message body; use RMNet sms send"),
    ("+CMGC", "AT+CMGC needs a second stage after a > prompt; RMNet at sends one line only"),
    ("+QCMGS", "AT+QCMGS needs a second stage after a > prompt; RMNet at sends one line only"),
]

/// The first basic command after AT that would take the AT port to data mode (D dials, O goes online) or
/// change whether and how the modem answers (V: words or numbers; Q: result codes on or off).
private let atLockoutFirstCommands: [Character] = ["D", "O", "V", "Q"]

/// Anywhere in the line: the line-end characters the modem expects and answers with (S3, S4), &W, which
/// would keep such settings across a restart, and +CGDATA, which enters data state.
private let atLockoutAnywhere = ["S3=", "S4=", "&W", "+CGDATA"]

private func atLockout(_ what: String) -> String {
    "RMNet at does not send \(what) (it would switch the AT port to data mode or change how the modem answers, "
        + "and RMNet's own AT features would stop working)"
}

/// The values written to the modem's USB setting `key` (`USBNET`, `USBCFG`) anywhere in `compact` (the line
/// upper-cased, spaces removed): for each `+QCFG=<key>,` (the key in quotes or not), the text after the comma up
/// to the next `;` or the line's end. A read (`+QCFG="usbnet"`, no comma) has none.
private func usbSettingWrites(_ compact: String, key: String) -> [Substring] {
    var values: [Substring] = []
    for quoted in ["\"\(key)\",", "\(key),"] {
        let pattern = "+QCFG=" + quoted
        var rest = compact[...]
        while let found = rest.range(of: pattern) {
            let after = rest[found.upperBound...]
            values.append(after.prefix { $0 != ";" })
            rest = after
        }
    }
    return values
}

/// nil when `line` may be sent as one AT command; else why not, as `RMNet at` says it after `at: ` (never
/// quoting the line). Refused: an empty line; a character outside printable ASCII (0x20–0x7E), so no CR or LF
/// (which would end the line early and send a second command) and no Ctrl-Z (which ends a message body); more
/// than 512 characters; a line that does not start with AT (any case). Then, on the line upper-cased with its
/// spaces removed: a prompt command anywhere (`atPromptCommands`); ATD, ATO, ATV or ATQ as the first basic
/// command; S3=, S4=, &W or +CGDATA anywhere; a write of the USB network mode (AT+QCFG="usbnet",<n>) other than
/// 0, QMI (`RMNet usbmode set` warns and checks first), and any write of the USB configuration
/// (AT+QCFG="usbcfg",…), after which the modem may no longer be found on USB 2c7c:0801; the reads of both are
/// sent. Those would leave the port waiting for a second stage, or unusable for RMNet's own AT features (AtPort
/// expects verbose answers ending in OK, in command mode), or take the modem away from RMNet.
func atCommandProblem(_ line: String) -> String? {
    let scalars = line.unicodeScalars
    if scalars.isEmpty { return "no command given; usage: RMNet at [--timeout <seconds>] <command>" }
    guard scalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
        return "a command is printable ASCII only (no line end, tab or Ctrl-Z)"
    }
    if scalars.count > atCommandLimit { return "a command is at most \(atCommandLimit) characters" }
    let upper = line.uppercased()              // ASCII only by now
    guard upper.hasPrefix("AT") else { return "a command starts with AT" }
    let compact = upper.replacingOccurrences(of: " ", with: "")
    for command in atPromptCommands where compact.contains(command.name) { return command.reason }
    if let first = compact.dropFirst(2).first, atLockoutFirstCommands.contains(first) { return atLockout("AT\(first)") }
    for part in atLockoutAnywhere where compact.contains(part) { return atLockout("AT\(part)") }
    if usbSettingWrites(compact, key: "USBNET").contains(where: { $0 != "0" }) {
        return "use RMNet usbmode set to change the USB mode; it warns and checks first"
    }
    if !usbSettingWrites(compact, key: "USBCFG").isEmpty {
        return "RMNet at does not change the USB configuration (usbcfg): the modem could disappear from RMNet"
    }
    return nil
}

// MARK: - Data profiles

/// AT+CGDCONT?: `+CGDCONT: <cid>,<PDP_type>,<APN>,…`. A line without a profile number of at least 1, a
/// type and an APN is skipped; a number listed twice keeps its first line. Type and APN display-safe.
func parseProfiles(_ lines: [String]) -> [(id: Int, pdpType: String, apn: String)] {
    var profiles: [(id: Int, pdpType: String, apn: String)] = []
    for line in lines {
        guard let f = atFields(line, prefix: "+CGDCONT"), let id = answerInt(f, 0), id >= 1,
              let pdpType = answerField(f, 1), let apn = answerField(f, 2),
              !profiles.contains(where: { $0.id == id }) else { continue }
        profiles.append((id: id, pdpType: modemTextSafe(pdpType), apn: modemTextSafe(apn)))
    }
    return profiles
}

/// AT+QICSGP=<id>: `+QICSGP: <type>,"<APN>","<user>","<password>",<auth>`, the values exactly as given
/// (a quoted comma stays in its field). nil without such a line, or with a type or auth out of range.
func parseProfileSettings(_ lines: [String]) -> ProfileSettings? {
    guard let f = firstAnswer(lines, "+QICSGP"),
          let type = answerInt(f, 0).flatMap({ PdpType(rawValue: $0) }),
          let apn = answerField(f, 1), let user = answerField(f, 2), let password = answerField(f, 3),
          let auth = answerInt(f, 4).flatMap({ AuthMethod(rawValue: $0) }) else { return nil }
    return ProfileSettings(type: type, apn: apn, user: user, password: password, auth: auth)
}

/// AT+QICSGP=<id>,<type>,"<apn>","<user>","<password>",<auth>. It holds the password: send it, never
/// show or log it. Check `profileProblem` first (no value may hold a `"` or a `\`).
func profileCommand(_ id: Int, _ s: ProfileSettings) -> String {
    "AT+QICSGP=\(id),\(s.type.rawValue),\"\(s.apn)\",\"\(s.user)\",\"\(s.password)\",\(s.auth.rawValue)"
}

private let apnRule = "An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores; it does not "
    + "start or end with a dot or a hyphen, has no two dots in a row, and has no hyphen next to a dot."
private let userRule = "A user name is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let passwordRule = "A password is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let noAuthenticationRule = "With no authentication the user name and password must be empty; "
    + "choose PAP, CHAP or PAP or CHAP to use them."

/// Up to 100 of ASCII letters, digits, `.`, `-`, `_`, in labels joined by dots, none empty and none starting
/// or ending with `-` (3GPP TS 23.003's DNS rules, ruling R21: so `apn set --apn --no-redial` is refused);
/// empty is allowed (the network chooses). Checked by Unicode scalar, so a combining mark is a character of
/// its own.
private func apnAllowed(_ apn: String) -> Bool {
    let scalars = apn.unicodeScalars
    guard scalars.count <= 100 else { return false }
    guard !scalars.isEmpty else { return true }
    let labels = scalars.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" }) else { return false }
    return scalars.allSatisfy { c in
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return c == "." || c == "-" || c == "_"
        }
    }
}

/// Up to 127 of printable ASCII (0x20–0x7E) without `"`, which would end the quoted value, and without
/// `\`, since a V.250 / 27.007 string constant may read `\hh` as an escape (`a\41` stored as `aA`).
private func credentialAllowed(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    return scalars.count <= 127 && scalars.allSatisfy { (0x20...0x7E).contains($0.value) && $0 != "\"" && $0 != "\\" }
}

/// nil for a profile RMNet can change (1 to 16); else the sentence.
func profileNumberProblem(_ id: Int) -> String? {
    (1...16).contains(id) ? nil : "Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."
}

/// nil when the settings can be sent to profile `id`; else the sentence saying which rule they break
/// (the profile number first, then the APN, the user name, the password, then that with no authentication
/// both are empty; never quoting the password). With authentication 0 the modem turns a profile that has a
/// password into CHAP by itself (seen on 2026-11-15, ruling R15), so RMNet does not send such a profile.
func profileProblem(_ id: Int, _ s: ProfileSettings) -> String? {
    if let problem = profileNumberProblem(id) { return problem }
    if !apnAllowed(s.apn) { return apnRule }
    if !credentialAllowed(s.user) { return userRule }
    if !credentialAllowed(s.password) { return passwordRule }
    if s.auth == AuthMethod.none && !(s.user.isEmpty && s.password.isEmpty) { return noAuthenticationRule }
    return nil
}

private func typeWords(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "IPV4"
    case .ipv6: return "IPV6"
    case .ipv4v6: return "IPV4V6"
    }
}

private func authWords(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "no authentication"
    case .pap: return "PAP"
    case .chap: return "CHAP"
    case .papOrChap: return "PAP or CHAP"
    }
}

/// The `--type` and `--auth` values of `RMNet apn set`, also the JSON's auth.
private func typeOption(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "ipv4"
    case .ipv6: return "ipv6"
    case .ipv4v6: return "ipv4v6"
    }
}

private func authOption(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "none"
    case .pap: return "pap"
    case .chap: return "chap"
    case .papOrChap: return "pap-or-chap"
    }
}

/// The settings in words without the password's part: `IPV4V6, APN "cmnet", PAP, user "u"`.
private func settingsWords(_ s: ProfileSettings) -> String {
    var parts = [typeWords(s.type), "APN \"\(modemTextSafe(s.apn))\"" + (s.apn.isEmpty ? " (the network chooses)" : ""),
                 authWords(s.auth)]
    if !s.user.isEmpty { parts.append("user \"\(modemTextSafe(s.user))\"") }
    return parts.joined(separator: ", ")
}

/// `IPV4V6, APN "cmnet", PAP, user "u", password set`: an empty APN reads `APN "" (the network
/// chooses)`; an empty user name and an empty password are left out. Never the password itself.
func profileWords(_ s: ProfileSettings) -> String {
    settingsWords(s) + (s.password.isEmpty ? "" : ", password set")
}

/// The value in single quotes for the shell, each `'` inside as `'\''` (found by Unicode scalar, so a
/// quote that a combining mark joins into one Character is escaped too).
private func shellQuoted(_ value: String) -> String {
    var out = String.UnicodeScalarView()
    out.append("'")
    for c in value.unicodeScalars {
        if c == "'" { out.append(contentsOf: "'\\''".unicodeScalars) } else { out.append(c) }
    }
    out.append("'")
    return String(out)
}

/// The `RMNet apn set` options that put `s` back: `--apn '' --type ipv4v6 --user '' --auth none
/// --no-password`. The last option always says what becomes of the password (ruling R6): `--no-password`
/// when `s` had none, so a password the change added is cleared; `--password` when `s` had one (the
/// owner types the old one at the prompt; it is never printed).
func profileRestoreArguments(_ s: ProfileSettings) -> String {
    let words = ["--apn", shellQuoted(modemTextSafe(s.apn)), "--type", typeOption(s.type),
                 "--user", shellQuoted(modemTextSafe(s.user)), "--auth", authOption(s.auth),
                 s.password.isEmpty ? "--no-password" : "--password"]
    return words.joined(separator: " ")
}

/// The command that puts a profile back to `s`, as `apn set` and the window show it: `RMNet apn set
/// <profileRestoreArguments(s)>` (never the password: `--password` asks for it).
func profileRestoreCommand(_ s: ProfileSettings) -> String {
    "RMNet apn set " + profileRestoreArguments(s)
}

/// The command that puts the network mode back to `before`, as the modem gave it, lower-cased (ruling R8:
/// `NR5G:LTE` is put back as `nr5g:lte`); nil for a value RMNet cannot set.
func modeRestoreCommand(_ before: String) -> String? {
    canonicalMode(before) == nil ? nil : "RMNet mode \(before.lowercased())"
}

/// The `RMNet at` line that sets the network mode to `before` as it is: `RMNet at '<modeCommand(before)>'`.
/// nil unless `before` is printable ASCII without quotes, so that it goes into the shell's single quotes and
/// the AT line unchanged, and `RMNet at` would send that line as it is: not empty, no space at its end (the
/// verb drops it), and a line `atCommandProblem` accepts.
func modeAtRestoreCommand(_ before: String) -> String? {
    let command = modeCommand(before)
    guard !before.isEmpty, !before.hasSuffix(" "),
          before.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) && $0 != "\"" && $0 != "'" }),
          atCommandProblem(command) == nil else { return nil }
    return "RMNet at '\(command)'"
}

/// The way back from a mode change for an earlier value RMNet's `mode` cannot set (modeRestoreCommand is nil,
/// ruling R8), to follow a phrase naming that value: `cannot be set with RMNet mode; to put it back: <its
/// RMNet at line>`, or, without such a line, `cannot be set with RMNet mode; set it again with RMNet at
/// 'AT+QNWPREFCFG="mode_pref",<value>'`, `<value>` as written. No period after it: one would join the
/// pasted command's last word.
func modeAtWayBack(_ before: String) -> String {
    if let line = modeAtRestoreCommand(before) { return "cannot be set with RMNet mode; to put it back: \(line)" }
    return "cannot be set with RMNet mode; set it again with RMNet at '\(modeCommand("<value>"))'"
}

private func orNull<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

/// `RMNet apn show --json`: the driver's profile number and each profile; `auth`, `user` and
/// `passwordSet` are null when the profile's settings were not read. Never the password.
func profilesJSON(_ profiles: [DataProfile], driverProfile: Int) -> [String: Any] {
    let rows: [[String: Any]] = profiles.map { p in
        ["id": p.id, "pdpType": p.pdpType, "apn": p.apn,
         "auth": orNull(p.settings.map { authOption($0.auth) }),
         "user": orNull(p.settings.map { modemTextSafe($0.user) }),
         "passwordSet": orNull(p.settings.map { !$0.password.isEmpty }),
         "driver": p.id == driverProfile]
    }
    return ["driverProfile": driverProfile, "profiles": rows]
}

// MARK: - SIM

/// AT+CPIN?: `+CPIN: <code>`. nil without a +CPIN line, or with an empty code.
func parseSimState(_ lines: [String]) -> SimState? {
    guard let code = firstAnswer(lines, "+CPIN").flatMap({ answerField($0, 0) }), !code.isEmpty else { return nil }
    switch code {
    case "READY": return .ready
    case "SIM PIN": return .pin
    case "SIM PUK": return .puk
    case "SIM PIN2": return .pin2
    case "SIM PUK2": return .puk2
    default: return .other(modemTextSafe(code))
    }
}

/// The state that AT+CPIN?'s error line gives: `+CME ERROR: 10` no SIM, `13` SIM failure, `14` SIM busy;
/// any other line is `.other(line)`, display-safe.
func simState(fromError line: String) -> SimState {
    switch atFields(line, prefix: "+CME ERROR").flatMap({ answerInt($0, 0) }) {
    case 10: return .notInserted
    case 13: return .failure
    case 14: return .busy
    default: return .other(modemTextSafe(line))
    }
}

/// AT+QPINC?: the `"SC"` line, `+QPINC: "SC",<PIN attempts left>,<PUK attempts left>`.
func parsePinAttempts(_ lines: [String]) -> (pin: Int?, puk: Int?) {
    for line in lines {
        if let f = atFields(line, prefix: "+QPINC"), answerField(f, 0) == "SC" { return (answerCount(f, 1), answerCount(f, 2)) }
    }
    return (nil, nil)
}

/// AT+CLCK="SC",2: `+CLCK: <status>`, 1 locked (the SIM asks for its PIN at start), 0 not.
func parsePinLock(_ lines: [String]) -> Bool? {
    switch firstAnswer(lines, "+CLCK").flatMap({ answerInt($0, 0) }) {
    case 0: return false
    case 1: return true
    default: return nil
    }
}

/// AT+CPIN="<pin>". It holds the PIN: send it, never show or log it. Check `pinProblem` first.
func pinCommand(_ pin: String) -> String {
    "AT+CPIN=\"\(pin)\""
}

/// nil for 4 to 8 ASCII digits; else the rule (never quoting what was typed).
func pinProblem(_ pin: String) -> String? {
    let scalars = pin.unicodeScalars
    let digits = (4...8).contains(scalars.count) && scalars.allSatisfy { (0x30...0x39).contains($0.value) }
    return digits ? nil : "A PIN is 4 to 8 digits."
}

/// The SIM's state in words, as the SIM row reads it.
func simStateWords(_ state: SimState) -> String {
    switch state {
    case .ready: return "ready"
    case .pin: return "asks for its PIN"
    case .puk: return "blocked: needs its PUK from the carrier"
    case .pin2: return "asks for PIN2"
    case .puk2: return "asks for PUK2"
    case .notInserted: return "not inserted"
    case .failure: return "SIM failure"
    case .busy: return "busy"
    case .other(let text): return text
    }
}

private func simStateKey(_ state: SimState) -> String {
    switch state {
    case .ready: return "ready"
    case .pin: return "pin"
    case .puk: return "puk"
    case .pin2: return "pin2"
    case .puk2: return "puk2"
    case .notInserted: return "not inserted"
    case .failure: return "failure"
    case .busy: return "busy"
    case .other(let text): return text
    }
}

/// The window's rows and the CLI's lines: SIM, PIN lock, Attempts left; a row whose value was not read
/// is left out.
func simRows(_ sim: SimInfo) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = [(label: "SIM", value: simStateWords(sim.state))]
    if let lock = sim.pinLock { rows.append((label: "PIN lock", value: lock ? "on" : "off")) }
    let attempts = [sim.pinAttempts.map { "PIN \($0)" }, sim.pukAttempts.map { "PUK \($0)" }].compactMap { $0 }
    if !attempts.isEmpty { rows.append((label: "Attempts left", value: attempts.joined(separator: ", "))) }
    if let slot = sim.activeSlot { rows.append((label: "Slot", value: String(slot))) }
    return rows
}

/// `RMNet sim --json`: every key is always there; a value not read is null.
func simJSON(_ sim: SimInfo) -> [String: Any] {
    ["state": simStateKey(sim.state), "pinLock": orNull(sim.pinLock), "pinAttempts": orNull(sim.pinAttempts),
     "pukAttempts": orNull(sim.pukAttempts), "activeSlot": orNull(sim.activeSlot)]
}

// MARK: - The SIM slot (AT+QUIMSLOT)
//
// The RM520N-GL has two SIM slots and uses one at a time (dual SIM, single standby): AT+QUIMSLOT? gives
// `+QUIMSLOT: <1|2>` and AT+QUIMSLOT=<1|2> switches. The modem reads the other SIM and registers again within
// seconds, with no restart, and keeps the slot across restarts.

let simSlots = [1, 2]

/// One command's answer in a short read (ModemService.shortReads): its lines, or the modem's error line.
enum PulseAnswer: Equatable {
    case lines([String])
    case refused(String)

    /// The lines, none for a refusal (as a read whose refusal only leaves its part unknown).
    var lines: [String] {
        if case .lines(let l) = self { return l }
        return []
    }
}

/// AT+CPIN? as a short read gave it: a state (the error line is one too: simState(fromError:)); nil when it said
/// neither.
func simState(_ answer: PulseAnswer) -> SimState? {
    switch answer {
    case .lines(let lines): return parseSimState(lines)
    case .refused(let line): return simState(fromError: line)
    }
}

/// AT+QUIMSLOT?: `+QUIMSLOT: 1` → 1; nil without such a line or for another value.
func parseSimSlot(_ lines: [String]) -> Int? {
    guard let slot = firstAnswer(lines, "+QUIMSLOT").flatMap({ answerInt($0, 0) }), simSlots.contains(slot) else {
        return nil
    }
    return slot
}

func simSlotCommand(_ slot: Int) -> String { "AT+QUIMSLOT=\(slot)" }

/// The slot that is not `slot`.
func otherSimSlot(_ slot: Int) -> Int { slot == 1 ? 2 : 1 }

/// A SIM state no SIM in the slot can be used in: none there (`+CME ERROR: 10`, SIM not inserted) or one the
/// modem cannot use (`+CME ERROR: 13`, SIM failure), as 3GPP TS 27.007 (9.2.1) numbers them. Not `busy`
/// (`+CME ERROR: 14`): the SIM is there and still starting.
func simUnusable(_ state: SimState) -> Bool {
    state == .notInserted || state == .failure
}

/// How long a slot change waits: for the new slot's SIM only (`sim`), or also for the registration (`registration`).
enum SimSlotWait: Equatable { case sim, registration }

/// What a slot change did: the slots before and after (the same: nothing was changed), the new slot's SIM state as
/// read until it settled (nil: not read), after how many whole seconds it was ready, and the registration with its
/// seconds (only when waited for, and the SIM was ready).
struct SimSlotChange: Equatable {
    let before: Int
    let after: Int
    var sim: SimState? = nil
    var secondsToSim: Int? = nil
    var registration: Registration? = nil
    var secondsToRegister: Int? = nil
    var skipped: SimSlotSkip? = nil   // an automatic switch not made: what its expectation found otherwise

    var changed: Bool { before != after }
}

/// What an automatic switch (SimSlotWatch.swift) expects to find on the port that would write AT+QUIMSLOT=, checked
/// there first, in the same port open (ModemService.setSimSlot): the module it watched (its USB serial number: one not
/// known, here or on the port, is never taken for the same), still on `slot`; and with `unusableSim`, the radio still on
/// (AT+CFUN? 1) and the SIM still without a usable SIM (AT+CPIN?, simUnusable). Anything else, or a part that cannot be
/// read: nothing is written, and the change says why (`skipped`). The try and the switch back both check all of it.
struct SimSlotExpectation: Equatable {
    let module: String?
    let slot: Int
    var unusableSim = true
}

/// What came of a SIM slot change for its asker (ModemController.changeSimSlot's completion): its outcome, or `cancelled` when it was
/// dropped before it ran (it waited behind a read when the app began to quit).
enum SimSlotOutcome: Equatable {
    case finished(Result<SimSlotChange, ModemFailure>)
    case cancelled
}

/// Why an automatic switch was not made: the module not known (no serial number here or on the port), another module
/// on the port, another slot in use, the radio not on (or not read), a SIM that is usable now, or a SIM whose state
/// could not be told (not read, busy, another answer). The first, the radio and the SIM not told are "not known yet":
/// the watcher checks again later.
enum SimSlotSkip: Equatable { case moduleUnknown, otherModule, otherSlot, radioNotOn, simUsable, simUnknown }

/// A SIM state that says what the slot has: a usable SIM (true), none usable (false), or not yet told (nil: busy while it
/// starts, or another answer).
func simConclusive(_ state: SimState) -> Bool? {
    switch state {
    case .ready, .pin, .puk, .pin2, .puk2: return true
    case .notInserted, .failure: return false
    case .busy, .other: return nil
    }
}

/// The result line of a slot change.
func simSlotSentence(_ c: SimSlotChange) -> String {
    guard c.changed else { return "Already on SIM \(c.after); nothing changed." }
    guard let sim = c.sim else { return "Switched to SIM \(c.after); its SIM state could not be read." }
    if simUnusable(sim) {
        return "Switched to SIM \(c.after), but it has no usable SIM (\(simStateWords(sim)))."
    }
    guard sim == .ready else { return "Switched to SIM \(c.after). SIM: \(simStateWords(sim))." }
    var line = "Switched to SIM \(c.after). SIM ready"
    if let seconds = c.secondsToRegister, let r = c.registration {
        line += "; \(registrationWords(r)) after \(seconds) s"
    } else if let r = c.registration {
        line += "; \(registrationWords(r)) (not registered yet)"
    }
    return line + "."
}

/// The question before a slot change (the window's confirmation; `RMNet sim slot set` asks the same on the terminal).
func simSlotQuestion(from: Int?, to: Int) -> (title: String, message: String) {
    (title: "Switch to SIM \(to)?",
     message: (from.map { "The modem uses SIM \($0) now. " } ?? "")
        + "The connection drops while the modem reads the SIM in slot \(to) and registers again, usually for a few "
        + "seconds; with no SIM in slot \(to) there is no service until it is switched back. The modem keeps the slot "
        + "after a restart.")
}

/// "1 attempt left", "3 attempts left".
private func attemptsLeft(_ n: Int) -> String {
    n == 1 ? "1 attempt left" : "\(n) attempts left"
}

// MARK: - Before a change: the questions

func radioOffQuestion() -> (title: String, message: String) {
    (title: "Switch the radio off?",
     message: "The modem leaves the network (airplane mode), and the driver's connection is down until the radio is "
        + "switched on again: use the Radio switch on the Network screen, or run `RMNet radio on`.")
}

/// The way back from a mode change: for any mode `canonicalMode` accepts, which the service sends in the
/// modem's own order (ruling R8: `NR5G:LTE` is put back as `NR5G:LTE`); for another value, its `RMNet at`
/// line (modeAtWayBack).
private func modeWayBack(_ from: String?) -> String {
    guard let from else { return "After the change, RMNet says how to put the earlier mode back." }
    guard canonicalMode(from) != nil else {
        return "The current mode \(modemTextSafe(from)) \(modeAtWayBack(from))"
    }
    return "To put it back, press Put Back in the window or run `RMNet mode \(from.lowercased())`."
}

func modeQuestion(from: String?, to: String) -> (title: String, message: String) {
    let change = from.map { "The modem changes from \(modeWords($0)) to \(modeWords(to)) at once" }
        ?? "The current mode could not be read. The modem changes to \(modeWords(to)) at once"
    return (title: "Change the network mode to \(modeWords(to))?",
            message: "\(change); the connection can drop while it finds a network. "
                + "The modem keeps this setting, also after a restart. " + modeWayBack(from))
}

/// Before and after side by side, with whether the password changes (never its value). Without the
/// earlier settings (they could not be read), it says whether a password is set.
func profileQuestion(id: Int, before: ProfileSettings?, after: ProfileSettings) -> (title: String, message: String) {
    let now = before.map { "Now: \(profileWords($0))." } ?? "Now: the current settings could not be read."
    let password: String
    if let before {
        password = before.password == after.password ? "unchanged" : "changed"
    } else {
        password = after.password.isEmpty ? "none" : "set"
    }
    let new = "New: \(settingsWords(after)); password: \(password)."
    let warning = "A wrong APN breaks the connection. If the radio is on, RMNet switches it off and on again (a redial) "
        + "so that the driver dials with the new settings; the connection drops for about 10 to 30 seconds. "
        + "The modem keeps these settings until they are changed again."
    return (title: "Change profile \(id)?", message: [now, new, warning].joined(separator: "\n"))
}

func pinQuestion(attempts: Int) -> (title: String, message: String) {
    let message: String
    if attempts < 1 {
        message = "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not enter PUKs."
    } else if attempts == 1 {
        message = "1 attempt left. This is the last attempt: a wrong PIN blocks the SIM until its PUK (from the carrier) "
            + "is entered, and RMNet does not enter PUKs."
    } else {
        message = "The SIM has \(attemptsLeft(attempts)); a wrong PIN uses one."
    }
    return (title: "Send the PIN to the SIM?", message: message)
}

/// The window's checkbox while the SIM has 1 PIN attempt left, its `--last-attempt` (ruling R20).
let lastAttemptChoice = "Use the last attempt (a wrong PIN blocks the SIM until its PUK is entered)"

/// Whether the window's Unlock… may be pressed: a PIN of 4 to 8 digits, at least 1 attempt left, and at the
/// last attempt the checkbox ticked (ruling R20).
func unlockAllowed(pin: String, attempts: Int, lastAttemptTicked: Bool) -> Bool {
    pinProblem(pin) == nil && attempts >= 1 && (attempts > 1 || lastAttemptTicked)
}

// MARK: - After a change: the sentences

/// Registered: "The radio is on; <registration words> after <n> s." (ruling R5: the words already say
/// "registered"); not registered within the wait: "…has not registered yet (<words>)".
func radioSentence(_ c: RadioChange) -> String {
    guard c.on else { return "The radio is off. The driver's connection is down until the radio is switched on again." }
    let words = registrationWords(c.registration)
    let registered = c.registration.map { $0.status == .home || $0.status == .roaming } ?? false
    guard registered else { return "The radio is on, but the modem has not registered yet (\(words))." }
    if let n = c.secondsToRegister { return "The radio is on; \(words) after \(n) s." }
    return "The radio is on; \(words)."
}

func modeSentence(_ c: ModeChange) -> String {
    if c.before == c.after { return "The network mode is \(modeWords(c.after)), as it was." }
    return "The network mode is now \(modeWords(c.after)); it was \(modeWords(c.before)). The modem keeps this setting."
}

/// A reason from the service as the middle of a sentence: trimmed, a first word such as "The" lowercased
/// (not "AT+CFUN" or "I/O"), ending in `.`, `?` or `!` (a full stop added otherwise). An empty reason
/// reads "the radio could not be switched on."
private func clause(_ why: String) -> String {
    var scalars = Array(modemTextSafe(why.trimmingCharacters(in: .whitespacesAndNewlines)).unicodeScalars)
    guard let last = scalars.last else { return "the radio could not be switched on." }
    if scalars.count >= 2, (0x41...0x5A).contains(scalars[0].value), (0x61...0x7A).contains(scalars[1].value),
       let lower = Unicode.Scalar(scalars[0].value + 0x20) {
        scalars[0] = lower
    }
    if last != ".", last != "?", last != "!" { scalars.append(".") }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars)
    return String(out)
}

func profileSentence(_ c: ProfileChange) -> String {
    let now = "Profile \(c.id) is now \(profileWords(c.after))."
    switch c.redial {
    case .notAsked:
        return "\(now) The driver uses it the next time it dials (after the radio is switched off and on, or the modem restarts)."
    case .radioWasOff:
        return "\(now) The radio was off; the new settings are used when the radio is switched on."
    case .done(let radio):
        return "\(now) The radio was switched off and on again. \(radioSentence(radio))"
    case .radioLeftOff(let why):
        return "The profile was changed, but the radio is still off: \(clause(why)) \(now) "
            + "Run `RMNet radio on`, or use the Radio switch on the window's Network screen."
    }
}

func pinSentence(_ o: PinOutcome) -> String {
    if o.accepted {
        guard let sim = o.sim else { return "The SIM accepted the PIN." }
        if sim.state == .ready { return "The SIM accepted the PIN and is ready." }
        return "The SIM accepted the PIN (SIM: \(simStateWords(sim.state)))."
    }
    // Only +CME ERROR: 16 (incorrect password) is the SIM refusing the PIN; another line (such as 14, SIM
    // busy) is the modem not taking it, which may or may not have used an attempt (F10).
    let wrongPin = o.refusal.flatMap { atFields($0, prefix: "+CME ERROR") }.flatMap { answerInt($0, 0) } == 16
    guard wrongPin else { return pinNotTakenSentence(o) }
    guard let sim = o.sim else {
        return "The SIM refused the PIN. Its state could not be read; check the attempts left (RMNet sim) before entering it again."
    }
    switch sim.state {
    case .puk:
        return "The SIM refused the PIN and is now blocked: it needs its PUK from the carrier. RMNet does not enter PUKs."
    case .pin:
        guard let n = sim.pinAttempts else { return "The SIM refused the PIN. The attempts left could not be read." }
        if n == 1 {
            return "The SIM refused the PIN. 1 attempt left: the next wrong PIN blocks the SIM until its PUK is entered."
        }
        return "The SIM refused the PIN. \(attemptsLeft(n))."
    default:
        return "The SIM refused the PIN (SIM: \(simStateWords(sim.state)))."
    }
}

/// A PIN not taken with a line other than +CME ERROR: 16: the line (display-safe), then the attempts left
/// as read again, to be checked before the PIN is entered again.
private func pinNotTakenSentence(_ o: PinOutcome) -> String {
    let start = "The modem did not take the PIN" + (o.refusal.map { " (\(modemTextSafe($0)))" } ?? "") + "."
    guard let sim = o.sim else {
        return "\(start) The SIM's state could not be read; check the attempts left (RMNet sim) before entering it again."
    }
    switch sim.state {
    case .puk:
        return "\(start) The SIM is now blocked: it needs its PUK from the carrier. RMNet does not enter PUKs."
    case .pin:
        guard let n = sim.pinAttempts else {
            return "\(start) The attempts left could not be read; check them (RMNet sim) before entering it again."
        }
        return "\(start) \(attemptsLeft(n)); check them before entering it again."
    default:
        return "\(start) SIM: \(simStateWords(sim.state))."
    }
}

// MARK: - Cell lock (`AT+QNWLOCK`)

let validNrScsKHz = [15, 30, 60, 120, 240]

private func asciiDigitsInt(_ s: String) -> Int? {
    guard !s.isEmpty, s.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
    return Int(s)
}

/// AT+QNWLOCK="common/4g": `+QNWLOCK: "common/4g",0` (unlocked) or
/// `+QNWLOCK: "common/4g",<count>,<earfcn1>,<pci1>[,…]` (1 to 10 cells). nil when absent or malformed.
func parseLteCellLock(_ lines: [String]) -> [LteLockedCell]? {
    for line in lines {
        guard let f = atFields(line, prefix: "+QNWLOCK"), answerField(f, 0) == "common/4g" else { continue }
        guard let countStr = answerField(f, 1), let count = asciiDigitsInt(countStr) else { return nil }
        if count == 0 { return f.count == 2 ? [] : nil }
        guard (1...10).contains(count), f.count == 2 + 2 * count else { return nil }
        var cells: [LteLockedCell] = []
        for i in 0..<count {
            guard let earfcn = answerField(f, 2 + 2 * i).flatMap(asciiDigitsInt),
                  let pci = answerField(f, 3 + 2 * i).flatMap(asciiDigitsInt) else { return nil }
            cells.append(LteLockedCell(earfcn: earfcn, pci: pci))
        }
        return cells
    }
    return nil
}

/// AT+QNWLOCK="common/5g": `+QNWLOCK: "common/5g",0` (unlocked) or
/// `+QNWLOCK: "common/5g",<pci>,<arfcn>,<scs>,<band>`. nil when absent or malformed.
func parseNrCellLock(_ lines: [String]) -> ParsedNrCellLock? {
    for line in lines {
        guard let f = atFields(line, prefix: "+QNWLOCK"), answerField(f, 0) == "common/5g" else { continue }
        if f.count == 2 && f[1] == "0" { return .unlocked }
        guard f.count >= 5,
              let pci = answerField(f, 1).flatMap(asciiDigitsInt),
              let arfcn = answerField(f, 2).flatMap(asciiDigitsInt),
              let scs = answerField(f, 3).flatMap(asciiDigitsInt),
              let band = answerField(f, 4).flatMap(asciiDigitsInt),
              arfcn >= 1, scs >= 1, band >= 1 else { return nil }
        return .locked(NrCellLock(pci: pci, arfcn: arfcn, scsKHz: scs, band: band))
    }
    return nil
}

/// AT+QNWLOCK="save_ctrl": `+QNWLOCK: "save_ctrl",<lte_persist>,<nr_persist>` (`0` or `1`).
func parseCellLockPersist(_ lines: [String]) -> (lte: Bool, nr: Bool)? {
    for line in lines {
        guard let f = atFields(line, prefix: "+QNWLOCK"), answerField(f, 0) == "save_ctrl",
              f.count >= 3,
              let lte = answerField(f, 1).flatMap(asciiDigitsInt), (0...1).contains(lte),
              let nr = answerField(f, 2).flatMap(asciiDigitsInt), (0...1).contains(nr) else { continue }
        return (lte: lte == 1, nr: nr == 1)
    }
    return nil
}

func lteCellLockProblem(_ cells: [LteLockedCell]) -> String? {
    if cells.count > 10 { return "At most 10 LTE cells may be locked." }
    var seen = Set<String>()
    for c in cells {
        guard (0...262143).contains(c.earfcn) else { return "EARFCN \(c.earfcn) is out of range (0 to 262143)." }
        guard (0...503).contains(c.pci) else { return "LTE PCI \(c.pci) is out of range (0 to 503)." }
        let key = "\(c.earfcn):\(c.pci)"
        if !seen.insert(key).inserted { return "Duplicate LTE cell (EARFCN \(c.earfcn), PCI \(c.pci))." }
    }
    return nil
}

func nrCellLockProblem(_ lock: NrCellLock?, supportedSaBands: [Int]? = nil) -> String? {
    guard let lock else { return nil }
    guard (0...1007).contains(lock.pci) else { return "5G NR PCI \(lock.pci) is out of range (0 to 1007)." }
    guard (1...3279165).contains(lock.arfcn) else { return "5G NR ARFCN \(lock.arfcn) is out of range (1 to 3279165)." }
    guard validNrScsKHz.contains(lock.scsKHz) else { return "Subcarrier spacing must be 15, 30, 60, 120 or 240 kHz." }
    guard (1...999).contains(lock.band) else { return "5G NR band \(lock.band) is not valid." }
    if let supportedSaBands, !supportedSaBands.isEmpty, !supportedSaBands.contains(lock.band) {
        return "The modem does not support 5G SA band \(lock.band) (supported: \(bandListWords(supportedSaBands)))."
    }
    return nil
}

func lteCellLockCommand(_ cells: [LteLockedCell]) -> String {
    guard !cells.isEmpty else { return "AT+QNWLOCK=\"common/4g\",0" }
    let list = cells.map { "\($0.earfcn),\($0.pci)" }.joined(separator: ",")
    return "AT+QNWLOCK=\"common/4g\",\(cells.count),\(list)"
}

func nrCellLockCommand(_ lock: NrCellLock?) -> String {
    guard let lock else { return "AT+QNWLOCK=\"common/5g\",0" }
    return "AT+QNWLOCK=\"common/5g\",\(lock.pci),\(lock.arfcn),\(lock.scsKHz),\(lock.band)"
}

/// What is wrong with a cell in use before anything is read: its values (nrCellLockProblem, lteCellLockProblem), or a
/// subcarrier spacing given that is not one of validNrScsKHz; nil when nothing is.
func cellInUseProblem(_ cell: CellInUse) -> String? {
    switch cell {
    case .serving(let scs):
        guard let scs else { return nil }
        return validNrScsKHz.contains(scs) ? nil : "Subcarrier spacing must be 15, 30, 60, 120 or 240 kHz."
    case .nr(let lock):
        return nrCellLockProblem(lock)
    case .lte(let cell):
        return lteCellLockProblem([cell])
    }
}

/// The lock for a cell in use, against the serving cell (AT+QENG="servingcell") and the carriers (AT+QCAINFO) read in
/// the session that writes it. A 5G SA cell is in use while the modem is on 5G SA and it is the serving leg or one of
/// the NR carriers (band, PCI and ARFCN the same); an LTE cell while it is an LTE leg or carrier (EARFCN and PCI). A
/// subcarrier spacing the modem gives for the cell must be the lock's; one it does not give is never guessed.
func cellInUseLock(_ cell: CellInUse, serving: ServingCell?, carriers: [CarrierComponent]) -> CellInUseCheck {
    let legs = serving?.cells ?? []
    let onSa = legs.contains { $0.rat == "NR5G-SA" }
    switch cell {
    case .serving(let given):
        if let sa = legs.first(where: { $0.rat == "NR5G-SA" }), let pci = sa.pci, let arfcn = sa.channel,
           let bandText = sa.band, bandText.hasPrefix("n"), let band = Int(bandText.dropFirst()) {
            switch (sa.scsKHz, given) {
            case let (read?, given?) where read != given:
                return .refused("The modem reports a subcarrier spacing of \(read) kHz for its serving 5G SA cell, "
                                + "not \(given) kHz.")
            case let (read?, _):
                return .nr(NrCellLock(pci: pci, arfcn: arfcn, scsKHz: read, band: band))
            case let (nil, given?):
                return .nr(NrCellLock(pci: pci, arfcn: arfcn, scsKHz: given, band: band))
            case (nil, nil):
                return .refused("The modem does not report the subcarrier spacing of its serving 5G SA cell (n\(band), "
                                + "PCI \(pci), ARFCN \(arfcn)); give it with --scs (15, 30, 60, 120 or 240 kHz).")
            }
        }
        if let lte = legs.first(where: { $0.rat == "LTE" }), let earfcn = lte.channel, let pci = lte.pci {
            return .lte(LteLockedCell(earfcn: earfcn, pci: pci))
        }
        return .refused("No lockable 5G SA or LTE serving cell is currently active.")
    case .nr(let lock):
        let band = "n\(lock.band)"
        let leg = legs.first { $0.rat == "NR5G-SA" && $0.band == band && $0.pci == lock.pci && $0.channel == lock.arfcn }
        let carrier = carriers.contains { $0.rat == "NR5G" && $0.band == band && $0.pci == lock.pci && $0.channel == lock.arfcn }
        guard onSa, leg != nil || carrier else {
            return .refused("The modem no longer uses that 5G SA cell (\(band), PCI \(lock.pci), ARFCN \(lock.arfcn)).")
        }
        if let read = leg?.scsKHz, read != lock.scsKHz {
            return .refused("The modem reports a subcarrier spacing of \(read) kHz for that cell, not \(lock.scsKHz) kHz.")
        }
        return .nr(lock)
    case .lte(let cell):
        let inUse = legs.contains { $0.rat == "LTE" && $0.channel == cell.earfcn && $0.pci == cell.pci }
            || carriers.contains { $0.rat == "LTE" && $0.channel == cell.earfcn && $0.pci == cell.pci }
        guard inUse else {
            return .refused("The modem no longer uses that LTE cell (PCI \(cell.pci), EARFCN \(cell.earfcn)).")
        }
        return .lte(cell)
    }
}

func cellLockPersistCommand(lte: Bool, nr: Bool) -> String {
    "AT+QNWLOCK=\"save_ctrl\",\(lte ? 1 : 0),\(nr ? 1 : 0)"
}

func nrCellLockWords(_ nr: NrCellLock?) -> String {
    guard let nr else { return "unlocked" }
    return "band n\(nr.band), PCI \(nr.pci), ARFCN \(nr.arfcn), SCS \(nr.scsKHz) kHz"
}

func lteCellLockWords(_ lte: [LteLockedCell]) -> String {
    guard !lte.isEmpty else { return "unlocked" }
    return lte.map { "EARFCN \($0.earfcn), PCI \($0.pci)" }.joined(separator: "; ")
}

func cellLockRows(_ state: CellLockState) -> [(label: String, value: String)] {
    let persistWords: String
    switch (state.persistLte, state.persistNr) {
    case (false, false): persistWords = "off (temporary until restart)"
    case (true, true): persistWords = "on (kept across restarts)"
    case (true, false): persistWords = "LTE kept across restarts, 5G SA temporary"
    case (false, true): persistWords = "5G SA kept across restarts, LTE temporary"
    }
    var rows: [(label: String, value: String)] = [
        (label: "5G SA lock", value: nrCellLockWords(state.nr)),
        (label: "LTE lock", value: lteCellLockWords(state.lte)),
        (label: "Persist across restart", value: persistWords),
    ]
    for (index, n) in state.neighbours.enumerated() {
        var parts: [String] = [n.rat]
        if let k = n.kind { parts.append(k) }
        if let p = n.pci { parts.append("PCI \(p)") }
        if let c = n.channel { parts.append("\(n.rat == "LTE" ? "EARFCN" : "ARFCN") \(c)") }
        if let r = n.rsrp { parts.append("RSRP \(r) dBm") }
        rows.append((label: "Neighbour \(index + 1)", value: parts.joined(separator: ", ")))
    }
    return rows
}

func cellLockJSON(_ state: CellLockState) -> [String: Any] {
    let nrObj: Any = state.nr.map {
        ["pci": $0.pci, "arfcn": $0.arfcn, "scsKHz": $0.scsKHz, "band": $0.band]
    } ?? NSNull()
    let lteArr: [[String: Any]] = state.lte.map { ["earfcn": $0.earfcn, "pci": $0.pci] }
    let nbArr: [[String: Any]] = state.neighbours.map {
        ["rat": $0.rat, "kind": orNull($0.kind), "channel": orNull($0.channel),
         "pci": orNull($0.pci), "rsrp": orNull($0.rsrp), "rsrq": orNull($0.rsrq), "sinr": orNull($0.sinr)]
    }
    return [
        "nr5gSa": nrObj,
        "lte": lteArr,
        "persist": ["lte": state.persistLte, "nr5g": state.persistNr],
        "neighbours": nbArr,
    ]
}

func cellLockSentence(_ change: CellLockChange) -> String {
    switch change {
    case .unchanged(let state):
        if !state.isLocked { return "Cell lock is already unlocked." }
        return "Cell lock unchanged (5G SA: \(nrCellLockWords(state.nr)); LTE: \(lteCellLockWords(state.lte)))."
    case .changed(let before, let after):
        if after.nr != before.nr {
            if let nr = after.nr {
                return "Locked 5G SA cell to \(nrCellLockWords(nr))."
            }
            return "Unlocked 5G SA cell lock."
        }
        if after.lte != before.lte {
            if !after.lte.isEmpty {
                return "Locked LTE cell to \(lteCellLockWords(after.lte))."
            }
            return "Unlocked LTE cell lock."
        }
        return after.persistsAcrossReboot
            ? "Cell lock now persists across modem restarts."
            : "Cell lock is now temporary (cleared on modem restart)."
    }
}

// MARK: - IMEI (`AT+EGMR`)

/// Standard 3GPP TS 23.003 Luhn check digit for the first 14 ASCII digits of an IMEI.
func imeiCheckDigit(forFirst14 prefix: String) -> Int? {
    let scalars = Array(prefix.unicodeScalars)
    guard scalars.count == 14, scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
    var sum = 0
    for (i, scalar) in scalars.enumerated() {
        var digit = Int(scalar.value - 0x30)
        if i % 2 == 1 {
            digit *= 2
            if digit > 9 { digit -= 9 }
        }
        sum += digit
    }
    return (10 - (sum % 10)) % 10
}

/// AT+EGMR=0,7: `+EGMR: "<15 digits>"`. nil without such a line or when not 15 ASCII digits.
func parseImei(_ lines: [String]) -> String? {
    for line in lines {
        guard let f = atFields(line, prefix: "+EGMR"), let raw = answerField(f, 0) else { continue }
        let scalars = raw.unicodeScalars
        if scalars.count == 15 && scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) {
            return raw
        }
    }
    return nil
}

/// nil when `imei` is 15 ASCII digits with a valid Luhn check digit; else the rule.
func imeiProblem(_ imei: String) -> String? {
    let scalars = Array(imei.unicodeScalars)
    guard scalars.count == 15, scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
        return "An IMEI is 15 ASCII digits (0 to 9)."
    }
    let prefix = String(imei.prefix(14))
    guard let expected = imeiCheckDigit(forFirst14: prefix) else {
        return "An IMEI is 15 ASCII digits (0 to 9)."
    }
    let lastDigit = Int(scalars[14].value - 0x30)
    guard lastDigit == expected else {
        return "The IMEI check digit is not valid (expected \(expected) as the 15th digit)."
    }
    return nil
}

func imeiCommand(_ imei: String) -> String {
    "AT+EGMR=1,7,\"\(imei)\""
}

func imeiQuestion(before: String?, after: String, reboot: Bool, module: String? = nil) -> (title: String, message: String) {
    let current = (module.map { "Module: \($0).\n" } ?? "")
        + (before.map { "Current IMEI: \($0)." } ?? "Current IMEI could not be read.")
    let effect = reboot
        ? "RMNet restarts the modem right away so the network sees the new IMEI (~30 s without service)."
        : "The new IMEI is stored and takes effect after the next modem restart."
    return (title: "Change the modem's IMEI to \(after)?",
            message: "\(current)\nNew IMEI: \(after).\n\(effect)")
}

func imeiSentence(_ change: ImeiChange) -> String {
    switch change {
    case .unchanged(let current):
        return "IMEI is already \(current); nothing changed."
    case .rebooting(_, let after):
        return "IMEI set to \(after); the modem is restarting."
    case .setTakesEffectAfterRestart(_, let after):
        return "IMEI set to \(after); it takes effect at the next restart (AT+CFUN=1,1 or a replug)."
    case .restartFailed(_, _, let sentence):
        return sentence
    }
}

func imeiJSON(_ imei: String) -> [String: Any] {
    ["imei": imei]
}
