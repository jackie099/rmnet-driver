// Tests for app/ModemCli.swift: the command-line verbs `network`, `radio`, `mode`, `apn`, `sim`, `usbmode`,
// `at` and `bands`. The parser for every form and each wrong usage or refusal, and what each verb prints (on standard
// output and standard error) and returns, against a fake
// ModemServing that records its calls and returns set results (no port is opened). The fixtures are the
// modem's real answers (2026-11-15, firmware RM520NGLAAR03A04M4G_01.204.01.204). A password or PIN that
// the fake `readSecret` gives must reach the service and appear in no output line. Built with swiftc by
// `make app-test` together with app/ModemNetwork.swift and app/ModemSettings.swift; needs no Xcode project
// and no hardware. Stops at the first failure, prints which check failed and exits 1.
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

// --- the modem's answers ------------------------------------------------------------------------
let saInfo: NetworkInfo = {
    var info = NetworkInfo()
    info.radio = parseRadio(["+CFUN: 1"])
    let op = parseOperator(["+COPS: 0,0,\"CHINA MOBILE\",11"])
    info.operatorName = op.name
    info.accessTechnology = op.accessTechnology
    let sp = parseServiceProvider(["+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""])
    info.networkName = sp.fullName
    info.plmn = sp.plmn
    info.registration = summarizeRegistration(fiveG: parseRegistrationStat(["+C5GREG: 0,1"], prefix: "+C5GREG"),
                                              eps: parseRegistrationStat(["+CEREG: 0,0"], prefix: "+CEREG"),
                                              ps: parseRegistrationStat(["+CGREG: 0,0"], prefix: "+CGREG"),
                                              cs: parseRegistrationStat(["+CREG: 0,0"], prefix: "+CREG"))
    info.serving = parseServingCell(
        ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"])
    let qca = ["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32",
               "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]
    info.carriers = parseCarriers(qca)
    info.carrierComponents = parseCarrierComponents(qca)
    info.mode = parseModePreference(["+QNWPREFCFG: \"mode_pref\",AUTO"])
    info.nr5gDisable = parseNr5gDisable(["+QNWPREFCFG: \"nr5g_disable_mode\",0"])
    return info
}()

let readySim: SimInfo = {
    let attempts = parsePinAttempts(["+QPINC: \"SC\",3,10", "+QPINC: \"P2\",3,10"])
    return SimInfo(state: parseSimState(["+CPIN: READY"])!, pinLock: parsePinLock(["+CLCK: 0"]),
                   pinAttempts: attempts.pin, pukAttempts: attempts.puk)
}()

let profile1 = parseProfileSettings(["+QICSGP: 3,\"\",\"\",\"\",0"])!
let profile3 = parseProfileSettings(["+QICSGP: 3,\"CMNET\",\"\",\"\",0"])!
let listed = parseProfiles([
    "+CGDCONT: 1,\"IPV4V6\",\"\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 3,\"IPV4V6\",\"CMNET\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 4,\"IPV4V6\",\"CMWAP\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 5,\"IPV4V6\",\"SOS\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,1,,,,,,,,,,\"\",,,,0",
])

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

func settings(_ apn: String, password: String = "") -> ProfileSettings {
    ProfileSettings(type: .ipv4v6, apn: apn, user: "", password: password, auth: .none)
}

/// The five profiles as the modem lists them; profile 2's settings are left unread (as after a refusal).
let fixtureProfiles: [DataProfile] = listed.map { p in
    let s: ProfileSettings?
    switch p.id {
    case 1: s = profile1
    case 2: s = nil
    case 3: s = profile3
    default: s = settings(p.apn)
    }
    return DataProfile(id: p.id, pdpType: p.pdpType, apn: p.apn, settings: s)
}

// The bands, as the modem answered on 2026-11-15: every supported band allowed.
let lteSupported = [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43,
                    46, 48, 66, 71]
let nrSupported = [1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 66, 70, 71, 75, 76, 77, 78, 79]
let lteWords = "1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, "
    + "66, 71"
let nrWords = "1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 66, 70, 71, 75, 76, 77, 78, 79"

func bandSets(lte: [Int] = lteSupported, nsa: [Int] = nrSupported, sa: [Int] = nrSupported) -> [BandSet] {
    [BandSet(rat: .lte, allowed: lte, supported: lteSupported), BandSet(rat: .nsa, allowed: nsa, supported: nrSupported),
     BandSet(rat: .sa, allowed: sa, supported: nrSupported)]
}

let homeSA = Registration(status: .home, domain: "5GS")
let radioOn = RadioChange(on: true, registration: homeSA, secondsToRegister: 12)
let radioOff = RadioChange(on: false, registration: nil, secondsToRegister: nil)

// Distinctive secrets that no output line may contain.
let secret = "hunter2-secret"
let oldSecret = "old-secret-77"
let pinSecret = "4711"

// --- the fake service ---------------------------------------------------------------------------

/// Records every call, in order, in `events` (shared with the fake readSecret and the output), and answers
/// with the results set. `setProfile` answers by default with the change asked for, its `before` being the
/// profile as `profiles` gives it.
final class FakeModem: ModemServing {
    var events: [String] = []
    var networkResult: Result<NetworkInfo, ModemFailure> = .success(saInfo)
    var radioResult: Result<RadioChange, ModemFailure>? = nil        // nil: as asked, registered after 12 s
    var modeResult: Result<ModeChange, ModemFailure>? = nil          // nil: from AUTO to what was asked
    var profilesResult: Result<[DataProfile], ModemFailure> = .success(fixtureProfiles)
    var setProfileResult: Result<ProfileChange, ModemFailure>? = nil
    var redialResult: RedialResult = .done(radioOn)                  // when the default change redials
    var simResult: Result<SimInfo, ModemFailure> = .success(readySim)
    var pinResult: Result<PinOutcome, ModemFailure> =
        .success(PinOutcome(accepted: true, sim: SimInfo(state: .ready, pinLock: true, pinAttempts: 3, pukAttempts: 10)))
    var usbModeResult: Result<UsbModeInfo, ModemFailure> = .success(UsbModeInfo(value: 0))
    var setUsbModeResult: Result<UsbModeChange, ModemFailure>? = nil  // nil: rebooting, or set for the next restart
    var atResult: Result<[String], ModemFailure> = .success([])
    var bandsResult: Result<[BandSet], ModemFailure> = .success(bandSets())
    var setBandsResults: [BandRat: Result<BandChange, ModemFailure>] = [:]   // none: from the allowed list to the one asked
    var antennasResult: Result<[AntennaSignalSet], ModemFailure> = .success([
        AntennaSignalSet(rat: "NR5G", ports: [
            AntennaPort(index: 0, name: "PRX", rsrp: -93, rsrq: -11, sinr: 20),
            AntennaPort(index: 1, name: "DRX", rsrp: -110, rsrq: -16, sinr: 10),
            AntennaPort(index: 2, name: "RX2", rsrp: nil, rsrq: nil, sinr: nil),
            AntennaPort(index: 3, name: "RX3", rsrp: nil, rsrq: nil, sinr: nil),
        ])
    ])
    var cellLockResult: Result<CellLockState, ModemFailure> = .success(
        CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false))
    var setNrLockResult: Result<CellLockChange, ModemFailure>? = nil
    var setLteLockResult: Result<CellLockChange, ModemFailure>? = nil
    var setPersistResult: Result<CellLockChange, ModemFailure>? = nil
    var imeiResult: Result<String, ModemFailure> = .success("000000000000091")
    var setImeiResult: Result<ImeiChange, ModemFailure>? = nil
    var sessionModule: String? = "c0ffee01"     // the module setImei's own port open is on
    var readingModule: String? = "c0ffee01"     // the module imeiReading's port open is on (what is confirmed)
    var imeiExpectAsked: [ImeiExpectation?] = []
    var sessionBefore: String? = nil            // the IMEI it reads before the write (nil: imeiResult's)
    var simSlotResult: Result<Int, ModemFailure> = .success(1)
    var setSimSlotResult: Result<SimSlotChange, ModemFailure>? = nil
    var simSlotsAsked: [(slot: Int, wait: SimSlotWait)] = []

    var radioAsked: [Bool] = []
    var modesAsked: [String] = []
    var profilesSet: [(id: Int, settings: ProfileSettings, redial: Bool)] = []
    var pinsEntered: [(pin: String, shownAttempts: Int)] = []
    var usbModesSet: [String] = []                                    // "<mode> reboot" or "<mode> no reboot"
    var atSent: [String] = []                                         // "<line> <timeout>"
    var bandsAsked: [String] = []                                     // "<rat> <bands joined by :>"
    var nrLockSet: [NrCellLock?] = []
    var lteLockSet: [[LteLockedCell]] = []
    var persistSet: [(Bool, Bool)] = []
    var cellsInUse: [CellInUse] = []
    var lockCellInUseResult: Result<CellLockChange, ModemFailure>? = nil
    var imeiSetAsked: [(imei: String, reboot: Bool)] = []

    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        events.append("networkInfo")
        return networkResult
    }
    func antennas() -> Result<[AntennaSignalSet], ModemFailure> {
        events.append("antennas")
        return antennasResult
    }
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        events.append("setRadio")
        radioAsked.append(on)
        return radioResult ?? .success(on ? radioOn : radioOff)
    }
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> {
        events.append("setMode")
        modesAsked.append(mode)
        return modeResult ?? .success(ModeChange(before: "AUTO", after: mode))
    }
    func profiles() -> Result<[DataProfile], ModemFailure> {
        events.append("profiles")
        return profilesResult
    }
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        events.append("setProfile")
        profilesSet.append((id: id, settings: settings, redial: redial))
        if let setProfileResult { return setProfileResult }
        let before = (try? profilesResult.get())?.first(where: { $0.id == id })?.settings ?? profile1
        return .success(ProfileChange(id: id, before: before, after: settings, redial: redial ? redialResult : .notAsked))
    }
    func sim() -> Result<SimInfo, ModemFailure> {
        events.append("sim")
        return simResult
    }
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        events.append("enterPin")
        pinsEntered.append((pin: pin, shownAttempts: shownAttempts))
        return pinResult
    }
    func usbMode() -> Result<UsbModeInfo, ModemFailure> {
        events.append("usbMode")
        return usbModeResult
    }
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> {
        events.append("setUsbMode")
        usbModesSet.append("\(mode.name) \(reboot ? "reboot" : "no reboot")")
        return setUsbModeResult ?? .success(reboot ? .rebooting : .setTakesEffectAfterRestart)
    }
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> {
        events.append("at")
        atSent.append("\(line) \(timeout)")
        return atResult
    }
    func bands() -> Result<[BandSet], ModemFailure> {
        events.append("bands")
        return bandsResult
    }
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> {
        events.append("setBands")
        bandsAsked.append("\(rat.rawValue) \(bands.map { String($0) }.joined(separator: ":"))")
        if let result = setBandsResults[rat] { return result }
        let before = (try? bandsResult.get())?.first(where: { $0.rat == rat })?.allowed ?? []
        return .success(BandChange(before: before, after: bands))
    }
    func cellLock() -> Result<CellLockState, ModemFailure> {
        events.append("cellLock")
        return cellLockResult
    }
    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure> {
        events.append("setNrCellLock")
        nrLockSet.append(lock)
        if let r = setNrLockResult { return r }
        let before = (try? cellLockResult.get()) ?? CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)
        let after = CellLockState(lte: before.lte, nr: lock, persistLte: before.persistLte, persistNr: before.persistNr)
        return .success(before == after ? .unchanged(after) : .changed(before: before, after: after))
    }
    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure> {
        events.append("setLteCellLock")
        lteLockSet.append(cells)
        if let r = setLteLockResult { return r }
        let before = (try? cellLockResult.get()) ?? CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)
        let after = CellLockState(lte: cells, nr: before.nr, persistLte: before.persistLte, persistNr: before.persistNr)
        return .success(before == after ? .unchanged(after) : .changed(before: before, after: after))
    }
    // As the service: the serving cell (networkResult's) checked by cellInUseLock, then locked as setNrCellLock or
    // setLteCellLock does here.
    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure> {
        events.append("lockCellInUse")
        cellsInUse.append(cell)
        if let r = lockCellInUseResult { return r }
        if let problem = cellInUseProblem(cell) { return .failure(ModemFailure(message: "\(problem) Nothing was changed.")) }
        let info = (try? networkResult.get()) ?? NetworkInfo()
        switch cellInUseLock(cell, serving: info.serving, carriers: info.carrierComponents) {
        case .refused(let why): return .failure(ModemFailure(message: "\(why) Nothing was changed."))
        case .nr(let lock): return setNrCellLock(lock)
        case .lte(let one): return setLteCellLock([one])
        }
    }
    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure> {
        events.append("setCellLockPersist")
        persistSet.append((lte, nr))
        if let r = setPersistResult { return r }
        let before = (try? cellLockResult.get()) ?? CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)
        let after = CellLockState(lte: before.lte, nr: before.nr, persistLte: lte, persistNr: nr)
        return .success(before == after ? .unchanged(after) : .changed(before: before, after: after))
    }
    func imei() -> Result<String, ModemFailure> {
        events.append("imei")
        return imeiResult
    }
    func imeiReading() -> Result<ImeiReading, ModemFailure> {
        events.append("imeiReading")
        return imeiResult.map { ImeiReading(imei: $0, module: readingModule) }
    }
    func simSlot() -> Result<Int, ModemFailure> {
        events.append("simSlot")
        return simSlotResult
    }
    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure> {
        events.append("setSimSlot")
        simSlotsAsked.append((slot: slot, wait: wait))
        if let r = setSimSlotResult { return r }
        let before = (try? simSlotResult.get()) ?? 1
        if before == slot { return .success(SimSlotChange(before: slot, after: slot)) }
        return .success(SimSlotChange(before: before, after: slot, sim: .ready, secondsToSim: 2,
                                      registration: Registration(status: .home, domain: "5GS"), secondsToRegister: 5))
    }
    /// The module and the IMEI before that the change's own port open reads (ImeiWrite): `sessionModule`, and the IMEI
    /// `imeiResult` gives (or `sessionBefore` when set). An expectation they do not meet writes nothing, as the service.
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite {
        events.append("setImei")
        imeiSetAsked.append((imei: imei, reboot: reboot))
        imeiExpectAsked.append(expect)
        let before = sessionBefore ?? (try? imeiResult.get()) ?? "000000000000091"
        if let expect, sessionModule != expect.module {
            return ImeiWrite(outcome: .failure(ModemFailure(message: "The modem attached is not the module this change "
                                                            + "was confirmed for. Nothing was changed.")),
                             module: sessionModule)
        }
        if let expect, before != expect.before {
            return ImeiWrite(outcome: .failure(ModemFailure(message: "The modem's IMEI is \(before) now, not "
                                                            + "\(expect.before) as when the change was confirmed. Nothing was changed.")),
                             module: sessionModule, before: before)
        }
        if let r = setImeiResult { return ImeiWrite(outcome: r, module: sessionModule, before: before) }
        if before == imei { return ImeiWrite(outcome: .success(.unchanged(before)), module: sessionModule, before: before) }
        return ImeiWrite(outcome: .success(reboot ? .rebooting(before: before, after: imei)
                                                  : .setTakesEffectAfterRestart(before: before, after: imei)),
                         module: sessionModule, before: before)
    }
}

/// One run of a verb: what it printed on standard output (`lines`) and on standard error (`errors`), its
/// exit code, the prompts the fake readSecret was asked, the questions the fake terminal was asked.
struct Run {
    let lines: [String]
    let code: Int32
    let prompts: [String]
    var questions: [String] = []
    var errors: [String] = []
}

/// Parses `words` (which must be right usage) and runs it against `fake`; readSecret answers `secretAnswer`,
/// the terminal's question `answer` (nil: no terminal).
@discardableResult
func run(_ words: [String], _ fake: FakeModem, driverProfile: Int? = 1, secretAnswer: String? = nil,
         answer: String? = nil, history: ImeiHistoryRecorder? = nil, _ name: String) -> Run {
    guard let command = parseModem(words) else {
        check(false, "\(name): \(words.joined(separator: " ")) parses")
        return Run(lines: [], code: -1, prompts: [])
    }
    var lines: [String] = []
    var prompts: [String] = []
    var questions: [String] = []
    var errors: [String] = []
    let code = runModem(command, service: fake, driverProfile: driverProfile,
                        readSecret: { prompt in
                            fake.events.append("readSecret")
                            prompts.append(prompt)
                            return secretAnswer
                        },
                        ask: { question in
                            fake.events.append("ask")
                            questions.append(question)
                            return answer
                        },
                        output: { line in
                            fake.events.append("output")
                            lines.append(line)
                        },
                        errorOutput: { line in
                            fake.events.append("error")
                            errors.append(line)
                        },
                        imeiHistory: history)
    return Run(lines: lines, code: code, prompts: prompts, questions: questions, errors: errors)
}

func linesText(_ lines: [String]) -> String {
    lines.map { "    \($0)" }.joined(separator: "\n")
}

/// The lines on standard output and the exit code; nothing on standard error.
func expectLines(_ got: Run, _ want: [String], code: Int32, _ name: String) {
    check(got.lines == want, "\(name): the lines", "want\n\(linesText(want))\n  got\n\(linesText(got.lines))")
    check(got.errors.isEmpty, "\(name): nothing on standard error", linesText(got.errors))
    check(got.code == code, "\(name): exit \(code)", "got \(got.code)")
}

/// The lines on standard output and on standard error, and the exit code.
func expectOutput(_ got: Run, out: [String], err: [String], code: Int32, _ name: String) {
    check(got.lines == out, "\(name): standard output", "want\n\(linesText(out))\n  got\n\(linesText(got.lines))")
    check(got.errors == err, "\(name): standard error", "want\n\(linesText(err))\n  got\n\(linesText(got.errors))")
    check(got.code == code, "\(name): exit \(code)", "got \(got.code)")
}

/// No line printed (nor any prompt) may hold the secret; a failure shows the lines with it masked.
func expectNoSecret(_ got: Run, _ value: String, _ name: String) {
    let text = (got.lines + got.prompts).joined(separator: "\n")
    check(!text.contains(value), "redaction: \(name)", text.replacingOccurrences(of: value, with: "<the secret>"))
}

func expectParse(_ words: [String], _ want: ModemCommand) {
    let got = parseModem(words)
    check(got == want, "parseModem: \(words)", "want \(want)\n  got  \(String(describing: got))")
}

func expectWrongUsage(_ words: [String]) {
    let got = parseModem(words)
    check(got == nil, "parseModem: \(words) is wrong usage", "got \(String(describing: got))")
}

/// The JSON text a verb must print: the object pretty-printed with sorted keys.
func prettyJSON(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func apnSet(apn: String? = nil, type: PdpType? = nil, user: String? = nil, askPassword: Bool = false,
            clearPassword: Bool = false, auth: AuthMethod? = nil, redial: Bool = true) -> ModemCommand {
    .apnSet(apn: apn, type: type, user: user, askPassword: askPassword, clearPassword: clearPassword, auth: auth,
            redial: redial)
}

let warning = "apn: A wrong APN breaks the connection."
let noAuthentication = "apn: With no authentication the user name and password must be empty; "
    + "choose PAP, CHAP or PAP or CHAP to use them."

/// What `apn --json` prints: profilesJSON with `driverAttached` (ruling R17).
func apnJSON(_ profiles: [DataProfile], driverProfile: Int?) -> [String: Any] {
    var object = profilesJSON(profiles, driverProfile: driverProfile ?? 1)
    object["driverAttached"] = driverProfile != nil
    return object
}

/// The `driverAttached` value of one printed JSON object.
func driverAttached(_ got: Run) -> Bool? {
    guard got.lines.count == 1, let data = got.lines[0].data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["driverAttached"] as? Bool
}
let restoreProfile1 = "apn: to put it back: RMNet apn set --apn '' --type ipv4v6 --user '' --auth none --no-password"

@main
struct ModemCliTests {
    static func main() {
        // --- the verbs and the usage -------------------------------------------------------------
        check(modemVerbs == ["network", "antennas", "radio", "mode", "apn", "sim", "usbmode", "at", "bands",
                             "cell", "imei"], "modemVerbs", "\(modemVerbs.sorted())")
        check(modemUsage == "network [--json] | antennas [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…] | "
              + "apn [show] [--json] | apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>] "
              + "[--password | --no-password] [--auth none|pap|chap|pap-or-chap] [--no-redial] | "
              + "sim [--json] | sim unlock [--last-attempt] | sim slot [--json] | sim slot set 1|2 [--yes] | "
              + "usbmode [--json] | usbmode set qmi|ecm|mbim|rndis [--no-reboot] [--yes] | "
              + "at [--timeout <seconds>] <command> | "
              + "bands [--json] | bands set lte|nsa|sa <bands> | bands reset [lte|nsa|sa] | "
              + "cell [--json] | cell lock sa <pci> <arfcn> <scs> <band> | cell lock current [--scs <kHz>] | "
              + "cell lock lte <earfcn>:<pci>[,…] | cell unlock [sa|lte] | cell persist on|off | "
              + "imei [--json] | imei set <imei> [--no-reboot] [--yes] | imei history [--json]",
              "modemUsage: the brief's usage without the leading RMNet", modemUsage)

        // --- parseModem: every form --------------------------------------------------------------
        expectParse(["network"], .network(json: false))
        expectParse(["network", "--json"], .network(json: true))
        expectParse(["antennas"], .antennas(json: false))
        expectParse(["antennas", "--json"], .antennas(json: true))
        expectParse(["cell"], .cellShow(json: false))
        expectParse(["cell", "--json"], .cellShow(json: true))
        expectParse(["cell", "lock", "current"], .cellLockCurrent(scsKHz: nil))
        expectParse(["cell", "lock", "current", "--scs", "30"], .cellLockCurrent(scsKHz: 30))
        for words in [["cell", "lock", "current", "--scs"], ["cell", "lock", "current", "--scs", "x"],
                      ["cell", "lock", "current", "--scs", "30", "extra"], ["cell", "lock", "current", "30"],
                      ["cell", "lock", "current", "--scs", "-15"]] {
            check(parseModem(words) == nil, "parseModem: \(words.joined(separator: " ")) is wrong usage")
        }
        expectParse(["cell", "lock", "sa", "147", "520110", "30", "n41"],
                    .cellLockNr(NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)))
        expectParse(["cell", "lock", "lte", "1300:128,100:45"],
                    .cellLockLte([LteLockedCell(earfcn: 1300, pci: 128), LteLockedCell(earfcn: 100, pci: 45)]))
        expectParse(["cell", "unlock"], .cellUnlock(.both))
        expectParse(["cell", "unlock", "sa"], .cellUnlock(.sa))
        expectParse(["cell", "unlock", "lte"], .cellUnlock(.lte))
        expectParse(["cell", "persist", "on"], .cellPersist(true))
        expectParse(["cell", "persist", "off"], .cellPersist(false))
        expectParse(["imei"], .imeiShow(json: false))
        expectParse(["imei", "history"], .imeiHistory(json: false))
        expectParse(["imei", "history", "--json"], .imeiHistory(json: true))
        for words in [["imei", "history", "x"], ["imei", "history", "--json", "--json"], ["imei", "history", "--yes"]] {
            check(parseModem(words) == nil, "parseModem: \(words.joined(separator: " ")) is wrong usage")
        }
        expectParse(["imei", "--json"], .imeiShow(json: true))
        expectParse(["imei", "set", "000000000000141"], .imeiSet("000000000000141", reboot: true, yes: false))
        expectParse(["imei", "set", "000000000000141", "--no-reboot", "--yes"],
                    .imeiSet("000000000000141", reboot: false, yes: true))
        expectParse(["radio"], .radio(on: nil))
        expectParse(["radio", "on"], .radio(on: true))
        expectParse(["radio", "off"], .radio(on: false))
        expectParse(["mode"], .mode(nil))
        expectParse(["mode", "auto"], .mode("AUTO"))
        expectParse(["mode", "AUTO"], .mode("AUTO"))
        expectParse(["mode", "lte"], .mode("LTE"))
        expectParse(["mode", "nr5g"], .mode("NR5G"))
        expectParse(["mode", "lte:nr5g"], .mode("LTE:NR5G"))
        expectParse(["mode", "Lte:Nr5g"], .mode("LTE:NR5G"))
        // Ruling R8: the RATs keep the order typed, so a put-back restores the modem's own string.
        expectParse(["mode", "nr5g:lte"], .mode("NR5G:LTE"))
        expectParse(["mode", "wcdma:nr5g:lte"], .mode("WCDMA:NR5G:LTE"))
        expectParse(["apn"], .apnShow(json: false))
        expectParse(["apn", "--json"], .apnShow(json: true))
        expectParse(["apn", "show"], .apnShow(json: false))
        expectParse(["apn", "show", "--json"], .apnShow(json: true))
        expectParse(["apn", "set", "--apn", "cmnet"], apnSet(apn: "cmnet"))
        expectParse(["apn", "set", "--apn", ""], apnSet(apn: ""))
        expectParse(["apn", "set", "--type", "ipv4"], apnSet(type: .ipv4))
        expectParse(["apn", "set", "--type", "ipv6"], apnSet(type: .ipv6))
        expectParse(["apn", "set", "--type", "ipv4v6"], apnSet(type: .ipv4v6))
        expectParse(["apn", "set", "--user", "u"], apnSet(user: "u"))
        expectParse(["apn", "set", "--user", ""], apnSet(user: ""))
        expectParse(["apn", "set", "--password"], apnSet(askPassword: true))
        expectParse(["apn", "set", "--no-password"], apnSet(clearPassword: true))
        expectParse(["apn", "set", "--auth", "none"], apnSet(auth: AuthMethod.none))
        expectParse(["apn", "set", "--auth", "pap"], apnSet(auth: .pap))
        expectParse(["apn", "set", "--auth", "chap"], apnSet(auth: .chap))
        expectParse(["apn", "set", "--auth", "pap-or-chap"], apnSet(auth: .papOrChap))
        expectParse(["apn", "set", "--apn", "cmnet", "--no-redial"], apnSet(apn: "cmnet", redial: false))
        expectParse(["apn", "set", "--no-redial", "--apn", "cmnet"], apnSet(apn: "cmnet", redial: false))
        expectParse(["apn", "set", "--apn", "x", "--type", "ipv4", "--user", "u", "--password", "--auth", "pap-or-chap",
                     "--no-redial"],
                    apnSet(apn: "x", type: .ipv4, user: "u", askPassword: true, auth: .papOrChap, redial: false))
        expectParse(["apn", "set", "--auth", "chap", "--no-password", "--user", "u v", "--type", "ipv6", "--apn", "a.b"],
                    apnSet(apn: "a.b", type: .ipv6, user: "u v", clearPassword: true, auth: .chap))
        // Any value after --apn or --user is taken as given, also one that looks like an option.
        expectParse(["apn", "set", "--apn", "--no-redial"], apnSet(apn: "--no-redial"))
        expectParse(["apn", "set", "--user", "--apn"], apnSet(user: "--apn"))
        expectParse(["sim"], .sim(json: false))
        expectParse(["sim", "--json"], .sim(json: true))
        expectParse(["sim", "unlock"], .simUnlock(lastAttempt: false))
        expectParse(["sim", "unlock", "--last-attempt"], .simUnlock(lastAttempt: true))
        expectParse(["sim", "slot"], .simSlot(json: false))
        expectParse(["sim", "slot", "--json"], .simSlot(json: true))
        expectParse(["sim", "slot", "set", "2"], .simSlotSet(2, yes: false))
        expectParse(["sim", "slot", "set", "1", "--yes"], .simSlotSet(1, yes: true))
        for words in [["sim", "slot", "set"], ["sim", "slot", "set", "3"], ["sim", "slot", "set", "0"],
                      ["sim", "slot", "set", "02"], ["sim", "slot", "set", "+1"], ["sim", "slot", "set", "1", "--yes", "--yes"],
                      ["sim", "slot", "set", "1", "--json"], ["sim", "slot", "2"], ["sim", "slot", "--yes"]] {
            check(parseModem(words) == nil, "parseModem: \(words.joined(separator: " ")) is wrong usage")
        }
        check(ModemCommand.simSlotSet(2, yes: true).changesModem, "changesModem: sim slot set")
        check(!ModemCommand.simSlot(json: false).changesModem, "changesModem: sim slot only reads")
        expectParse(["usbmode"], .usbMode(json: false))
        expectParse(["usbmode", "--json"], .usbMode(json: true))
        expectParse(["usbmode", "set", "qmi"], .usbModeSet(.qmi, reboot: true, yes: false))
        expectParse(["usbmode", "set", "ecm"], .usbModeSet(.ecm, reboot: true, yes: false))
        expectParse(["usbmode", "set", "mbim"], .usbModeSet(.mbim, reboot: true, yes: false))
        expectParse(["usbmode", "set", "rndis"], .usbModeSet(.rndis, reboot: true, yes: false))
        expectParse(["usbmode", "set", "qmi", "--no-reboot"], .usbModeSet(.qmi, reboot: false, yes: false))
        expectParse(["usbmode", "set", "ecm", "--yes"], .usbModeSet(.ecm, reboot: true, yes: true))
        expectParse(["usbmode", "set", "mbim", "--no-reboot", "--yes"], .usbModeSet(.mbim, reboot: false, yes: true))
        expectParse(["usbmode", "set", "rndis", "--yes", "--no-reboot"], .usbModeSet(.rndis, reboot: false, yes: true))

        // --- parseModem: wrong usage -------------------------------------------------------------
        for words in [
            ["radio", "up"], ["mode", "5g"], ["apn", "set"], ["apn", "set", "--apn"],
            ["apn", "set", "--apn", "a", "--apn", "b"], ["sim", "unlock", "1234"], ["network", "--xml"],
            ["apn", "set", "--password", "--no-password"], ["apn", "set", "--no-password", "--password"],
            [], ["status"], ["sms"], ["Network"], ["network", "--json", "--json"], ["network", "json"],
            ["radio", "on", "off"], ["radio", "ON"], ["radio", "--json"],
            ["mode", ""], ["mode", "lte:lte"], ["mode", "auto:lte"], ["mode", "lte", "nr5g"], ["mode", "nr"],
            ["mode", "--json"],
            ["apn", "list"], ["apn", "show", "--xml"], ["apn", "--json", "show"], ["apn", "show", "show"],
            ["apn", "--json", "--json"],
            ["apn", "set", "--no-redial"], ["apn", "set", "--type"], ["apn", "set", "--type", "ipv5"],
            ["apn", "set", "--type", "IPV4"], ["apn", "set", "--auth"], ["apn", "set", "--auth", "md5"],
            ["apn", "set", "--user"], ["apn", "set", "--apn", "x", "extra"], ["apn", "set", "cmnet"],
            ["apn", "set", "--password", "--password"], ["apn", "set", "--no-password", "--no-password"],
            ["apn", "set", "--apn", "x", "--no-redial", "--no-redial"], ["apn", "set", "--user", "a", "--user", "b"],
            ["apn", "set", "--type", "ipv4", "--type", "ipv6"], ["apn", "set", "--auth", "pap", "--auth", "pap"],
            ["apn", "set", "--apn", "x", "--pin", "1234"], ["apn", "set", "--password", "secret"],
            ["sim", "--xml"], ["sim", "lock"], ["sim", "unlock", "--last-attempt", "--last-attempt"],
            ["sim", "unlock", "--json"], ["sim", "--json", "unlock"], ["sim", "unlock", "--last-attempt", "1234"],
            ["usbmode", "set"], ["usbmode", "set", "foo"], ["usbmode", "set", "qmi", "extra"], ["usbmode", "set", "QMI"],
            ["usbmode", "set", "0"], ["usbmode", "set", "--yes", "qmi"], ["usbmode", "set", "--yes"],
            ["usbmode", "set", "qmi", "--yes", "--yes"], ["usbmode", "set", "qmi", "--no-reboot", "--no-reboot"],
            ["usbmode", "set", "qmi", "--json"], ["usbmode", "set", "qmi", "--reboot"], ["usbmode", "set", "qmi", "ecm"],
            ["usbmode", "--json", "--json"], ["usbmode", "show"], ["usbmode", "qmi"], ["usbmode", "--yes"],
            ["usbmode", "--json", "set", "qmi"], ["usbmode", "set", "rmnet"], ["usbmode", "set", ""], ["usbMode"],
            ["AT", "ATI"], ["At", "ATI"],
        ] {
            expectWrongUsage(words)
        }

        // --- changesModem: exactly the changing forms --------------------------------------------
        let changing: [ModemCommand] = [.radio(on: true), .radio(on: false), .mode("LTE"), apnSet(apn: "x"),
                                        .simUnlock(lastAttempt: false), .simUnlock(lastAttempt: true),
                                        .usbModeSet(.qmi, reboot: true, yes: false), .usbModeSet(.ecm, reboot: false, yes: true),
                                        .bandsSet(.sa, [41]), .bandsSet(.lte, [3, 41]), .bandsReset(nil), .bandsReset(.nsa),
                                        .cellLockCurrent(scsKHz: nil), .cellLockCurrent(scsKHz: 30),
                                        .cellUnlock(.both), .cellPersist(true),
                                        .imeiSet("000000000000141", reboot: true, yes: false)]
        let reading: [ModemCommand] = [.network(json: false), .network(json: true), .antennas(json: false),
                                       .radio(on: nil), .mode(nil),
                                       .apnShow(json: false), .apnShow(json: true), .sim(json: false), .sim(json: true),
                                       .usbMode(json: false), .usbMode(json: true), .bands(json: false), .bands(json: true),
                                       .cellShow(json: false), .imeiShow(json: false),
                                       .imeiHistory(json: false), .imeiHistory(json: true)]
        for c in changing { check(c.changesModem, "changesModem: \(c) changes the modem") }
        for c in reading { check(!c.changesModem, "changesModem: \(c) only reads") }
        // `at` sends what the owner typed, also a change such as AT+CFUN=1,1, and Ctrl-C stops it all the same.
        for c in [ModemCommand.at("AT+CFUN=1,1", timeout: 10), .at("ATI", timeout: 300), .atRefused("x")] {
            check(!c.changesModem, "changesModem: \(c) is not a changing verb (Ctrl-C works)")
        }

        // --- network -----------------------------------------------------------------------------
        let saLines = [
            "registration: registered, home network (5GS)",
            "operator: CHINA MOBILE (中国移动), PLMN 46000",
            "technology: 5G SA (TDD)",
            "band: n41 + n28 (carrier aggregation)",
            "signal: RSRP -95 dBm, RSRQ -10 dB, SINR 8 dB",
            "cell: PCI 32, cell ID 123456789, TAC 1A2B3C",
            "channel: ARFCN 504990, 100 MHz, SCS 30 kHz",
            "connection: idle",
            "radio: on",
            "network mode: automatic (5G, LTE and WCDMA)",
        ]
        var fake = FakeModem()
        expectLines(run(["network"], fake, "network"), saLines, code: 0, "network: the SA fixture")
        check(fake.events.filter { $0 != "output" } == ["networkInfo"], "network: one read", "\(fake.events)")

        fake = FakeModem()
        expectLines(run(["network", "--json"], fake, "network --json"), [prettyJSON(networkJSON(saInfo))], code: 0,
                    "network --json: networkJSON, pretty, sorted keys")

        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["network"], fake, "network failed"), ["network: Fake: no modem."], code: 1, "network: a failure")
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["network", "--json"], fake, "network --json failed"), ["network: Fake: no modem."], code: 1,
                    "network --json: a failure")

        // --- radio -------------------------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["radio"], fake, "radio"), ["radio: on"], code: 0, "radio: on")
        check(fake.radioAsked.isEmpty, "radio: showing changes nothing")
        fake = FakeModem()
        var airplane = saInfo
        airplane.radio = .airplane
        fake.networkResult = .success(airplane)
        expectLines(run(["radio"], fake, "radio airplane"), ["radio: off (airplane mode)"], code: 0, "radio: airplane mode")
        fake = FakeModem()
        var minimum = saInfo
        minimum.radio = .minimum
        fake.networkResult = .success(minimum)
        expectLines(run(["radio"], fake, "radio minimum"), ["radio: minimum functionality"], code: 0, "radio: minimum")
        fake = FakeModem()
        var unread = saInfo
        unread.radio = nil
        fake.networkResult = .success(unread)
        let radioUnread = run(["radio"], fake, "radio unread")
        check(radioUnread.code == 1 && radioUnread.lines.count == 1 && radioUnread.lines[0].hasPrefix("radio: "),
              "radio: a state not read is one failure line, exit 1", linesText(radioUnread.lines))
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: busy."))
        expectLines(run(["radio"], fake, "radio failed"), ["radio: Fake: busy."], code: 1, "radio: a failure")

        fake = FakeModem()
        expectLines(run(["radio", "off"], fake, "radio off"),
                    ["radio: The radio is off. The driver's connection is down until the radio is switched on again."],
                    code: 0, "radio off")
        check(fake.radioAsked == [false], "radio off: setRadio(on: false)", "\(fake.radioAsked)")
        fake = FakeModem()
        expectLines(run(["radio", "on"], fake, "radio on"),
                    ["radio: The radio is on; registered, home network (5GS) after 12 s."], code: 0, "radio on")
        check(fake.radioAsked == [true], "radio on: setRadio(on: true)", "\(fake.radioAsked)")
        check(fake.events.filter { $0 != "output" } == ["setRadio"], "radio on: nothing read before", "\(fake.events)")
        fake = FakeModem()
        let searching = RadioChange(on: true, registration: Registration(status: .searching, domain: "5GS"),
                                    secondsToRegister: nil)
        fake.radioResult = .success(searching)
        expectLines(run(["radio", "on"], fake, "radio on, searching"), ["radio: " + radioSentence(searching)],
                    code: 0, "radio on: not registered yet is still on")
        fake = FakeModem()
        fake.radioResult = .failure(ModemFailure(message: "Fake: the radio could not be switched."))
        expectLines(run(["radio", "off"], fake, "radio off failed"), ["radio: Fake: the radio could not be switched."],
                    code: 1, "radio off: a failure")

        // --- mode --------------------------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["mode"], fake, "mode"), ["mode: AUTO (automatic (5G, LTE and WCDMA))"], code: 0, "mode: AUTO")
        check(fake.modesAsked.isEmpty, "mode: showing changes nothing")
        fake = FakeModem()
        var nr5gLte = saInfo
        nr5gLte.mode = "NR5G:LTE"
        fake.networkResult = .success(nr5gLte)
        expectLines(run(["mode"], fake, "mode NR5G:LTE"), ["mode: NR5G:LTE (5G and LTE)"], code: 0,
                    "mode: the modem's own order")
        fake = FakeModem()
        var noMode = saInfo
        noMode.mode = nil
        fake.networkResult = .success(noMode)
        let modeUnread = run(["mode"], fake, "mode unread")
        check(modeUnread.code == 1 && modeUnread.lines.count == 1 && modeUnread.lines[0].hasPrefix("mode: "),
              "mode: a mode not read is one failure line, exit 1", linesText(modeUnread.lines))
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: timeout."))
        expectLines(run(["mode"], fake, "mode failed"), ["mode: Fake: timeout."], code: 1, "mode: a failure")

        fake = FakeModem()
        expectLines(run(["mode", "lte:nr5g"], fake, "mode lte:nr5g"),
                    ["mode: " + modeSentence(ModeChange(before: "AUTO", after: "LTE:NR5G")),
                     "mode: to put it back: RMNet mode auto"], code: 0, "mode lte:nr5g")
        check(fake.modesAsked == ["LTE:NR5G"], "mode lte:nr5g: setMode(LTE:NR5G)", "\(fake.modesAsked)")
        check(fake.events.filter { $0 != "output" } == ["setMode"], "mode lte:nr5g: one call", "\(fake.events)")
        fake = FakeModem()
        fake.modeResult = .success(ModeChange(before: "NR5G:LTE", after: "LTE"))
        expectLines(run(["mode", "lte"], fake, "mode lte from NR5G:LTE"),
                    ["mode: " + modeSentence(ModeChange(before: "NR5G:LTE", after: "LTE")),
                     "mode: to put it back: RMNet mode nr5g:lte"], code: 0, "mode: the put-back keeps the modem's order (R8)")
        fake = FakeModem()
        expectLines(run(["mode", "nr5g:lte"], fake, "mode nr5g:lte"),
                    ["mode: " + modeSentence(ModeChange(before: "AUTO", after: "NR5G:LTE")),
                     "mode: to put it back: RMNet mode auto"], code: 0, "mode nr5g:lte")
        check(fake.modesAsked == ["NR5G:LTE"], "mode nr5g:lte: sent in the order typed (R8)", "\(fake.modesAsked)")
        fake = FakeModem()
        fake.modeResult = .success(ModeChange(before: "GSM:LTE", after: "LTE"))
        expectLines(run(["mode", "lte"], fake, "mode lte from GSM:LTE"),
                    ["mode: " + modeSentence(ModeChange(before: "GSM:LTE", after: "LTE")),
                     "mode: the earlier value GSM:LTE cannot be set with RMNet mode; "
                        + "to put it back: RMNet at 'AT+QNWPREFCFG=\"mode_pref\",GSM:LTE'"],
                    code: 0, "mode: an earlier value RMNet cannot set (R8): its AT command, the value filled in")
        // A value that is not printable ASCII without quotes: the command with `<value>` as written.
        for (before, shown) in [("GSM:\u{FFFD}", "GSM:\u{FFFD}"), ("GSM\"LTE", "GSM\"LTE"), ("it's", "it's")] {
            fake = FakeModem()
            fake.modeResult = .success(ModeChange(before: before, after: "LTE"))
            expectLines(run(["mode", "lte"], fake, "mode lte from \(before)"),
                        ["mode: " + modeSentence(ModeChange(before: before, after: "LTE")),
                         "mode: the earlier value \(shown) cannot be set with RMNet mode; "
                            + "set it again with RMNet at 'AT+QNWPREFCFG=\"mode_pref\",<value>'"],
                        code: 0, "mode: an earlier value \(before.debugDescription) is not filled in")
        }
        fake = FakeModem()
        fake.modeResult = .failure(ModemFailure(message: "Fake: refused. It was AUTO."))
        expectLines(run(["mode", "nr5g"], fake, "mode nr5g failed"), ["mode: Fake: refused. It was AUTO."], code: 1,
                    "mode nr5g: a failure")

        // --- apn / apn show ----------------------------------------------------------------------
        let shown = [
            "profile 1: IPV4V6, APN \"\" (the network chooses), no authentication (the driver's)",
            "profile 2: IPV4V6, APN \"ims\"; other settings not read",
            "profile 3: IPV4V6, APN \"CMNET\", no authentication",
            "profile 4: IPV4V6, APN \"CMWAP\", no authentication",
            "profile 5: IPV4V6, APN \"SOS\", no authentication",
        ]
        for words in [["apn"], ["apn", "show"]] {
            fake = FakeModem()
            expectLines(run(words, fake, "\(words)"), ["apn: the driver dials profile 1"] + shown, code: 0, "\(words)")
            check(fake.events.filter { $0 != "output" } == ["profiles"], "\(words): one read", "\(fake.events)")
            check(fake.profilesSet.isEmpty, "\(words): changes nothing")
        }
        fake = FakeModem()
        let notAttached = run(["apn"], fake, driverProfile: nil, "apn, driver not attached")
        expectLines(notAttached, ["apn: the driver is not attached; it dials profile 1 unless set otherwise"] + shown, code: 0,
                    "apn: the driver not attached")
        fake = FakeModem()
        expectLines(run(["apn"], fake, driverProfile: 3, "apn, driver on 3"), [
            "apn: the driver dials profile 3",
            "profile 1: IPV4V6, APN \"\" (the network chooses), no authentication",
            "profile 2: IPV4V6, APN \"ims\"; other settings not read",
            "profile 3: IPV4V6, APN \"CMNET\", no authentication (the driver's)",
            "profile 4: IPV4V6, APN \"CMWAP\", no authentication",
            "profile 5: IPV4V6, APN \"SOS\", no authentication",
        ], code: 0, "apn: the driver dials profile 3")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 17, pdpType: "IPV4", apn: "", settings: nil),
                                        DataProfile(id: 1, pdpType: "IPV4V6", apn: "x",
                                                    settings: ProfileSettings(type: .ipv4v6, apn: "x", user: "u",
                                                                              password: secret, auth: .pap))])
        let withPassword = run(["apn"], fake, "apn with a password")
        expectLines(withPassword, [
            "apn: the driver dials profile 1",
            "profile 17: IPV4, APN \"\" (the network chooses); other settings not read",
            "profile 1: IPV4V6, APN \"x\", PAP, user \"u\", password set (the driver's)",
        ], code: 0, "apn: a password shows as set, a profile above 16 unread")
        expectNoSecret(withPassword, secret, "apn shows no password")
        fake.events = []
        let jsonWithPassword = run(["apn", "show", "--json"], fake, "apn show --json with a password")
        expectNoSecret(jsonWithPassword, secret, "apn show --json shows no password")
        check(jsonWithPassword.lines.count == 1 && jsonWithPassword.lines[0].contains("\"passwordSet\" : true"),
              "apn show --json: passwordSet true", linesText(jsonWithPassword.lines))

        for words in [["apn", "--json"], ["apn", "show", "--json"]] {
            fake = FakeModem()
            let got = run(words, fake, "\(words)")
            expectLines(got, [prettyJSON(apnJSON(fixtureProfiles, driverProfile: 1))], code: 0,
                        "\(words): profilesJSON and driverAttached, pretty, sorted keys")
            check(driverAttached(got) == true, "\(words): driverAttached true", linesText(got.lines))
        }
        fake = FakeModem()
        expectLines(run(["apn", "--json"], fake, driverProfile: 3, "apn --json, driver on 3"),
                    [prettyJSON(apnJSON(fixtureProfiles, driverProfile: 3))], code: 0, "apn --json: the driver's profile 3")
        fake = FakeModem()
        let jsonNotAttached = run(["apn", "--json"], fake, driverProfile: nil, "apn --json, driver not attached")
        expectLines(jsonNotAttached, [prettyJSON(apnJSON(fixtureProfiles, driverProfile: nil))], code: 0,
                    "apn --json: not attached, profile 1")
        check(driverAttached(jsonNotAttached) == false, "apn --json: driverAttached false without the driver",
              linesText(jsonNotAttached.lines))
        check(jsonNotAttached.lines.first?.contains("\"driverProfile\" : 1") == true,
              "apn --json: driverProfile 1 without the driver", linesText(jsonNotAttached.lines))
        fake = FakeModem()
        fake.profilesResult = .failure(ModemFailure(message: "Fake: the profiles could not be read."))
        expectLines(run(["apn"], fake, "apn failed"), ["apn: Fake: the profiles could not be read."], code: 1, "apn: a failure")

        // --- apn set -----------------------------------------------------------------------------
        fake = FakeModem()
        let cmnet = run(["apn", "set", "--apn", "cmnet"], fake, "apn set --apn cmnet")
        let cmnetSettings = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 1 && fake.profilesSet[0].settings == cmnetSettings
              && fake.profilesSet[0].redial == true,
              "apn set --apn cmnet: setProfile(1, to: profile 1 with apn cmnet, redial: true)",
              "\(fake.profilesSet.map { "(\($0.id), \($0.settings), \($0.redial))" })")
        let cmnetChange = ProfileChange(id: 1, before: profile1, after: cmnetSettings, redial: .done(radioOn))
        expectLines(cmnet, [warning, "apn: " + profileSentence(cmnetChange), restoreProfile1], code: 0, "apn set --apn cmnet")
        check(fake.events == ["profiles", "output", "setProfile", "output", "output"],
              "apn set --apn cmnet: read, warn, change, say", "\(fake.events)")
        check(cmnet.prompts.isEmpty, "apn set --apn cmnet: no password asked")

        fake = FakeModem()
        run(["apn", "set", "--apn", "cmnet", "--no-redial"], fake, "apn set --no-redial")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].redial == false, "apn set --no-redial: redial: false")

        fake = FakeModem()
        let full = run(["apn", "set", "--type", "ipv4", "--user", "me", "--auth", "chap"], fake, driverProfile: 3, "apn set 3")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 3
              && fake.profilesSet[0].settings
                == ProfileSettings(type: .ipv4, apn: "CMNET", user: "me", password: "", auth: .chap),
              "apn set on profile 3: the options over its current settings",
              "\(fake.profilesSet.map { "(\($0.id), \($0.settings))" })")
        check(full.code == 0
              && full.lines.last == "apn: to put it back: RMNet apn set --apn 'CMNET' --type ipv4v6 --user '' --auth none --no-password",
              "apn set on profile 3: the put-back line", linesText(full.lines))

        // A password kept from the current settings: sent as it was, never printed; the put-back ends --password.
        fake = FakeModem()
        let keptPassword = ProfileSettings(type: .ipv4v6, apn: "old", user: "u", password: oldSecret, auth: .pap)
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let kept = run(["apn", "set", "--apn", "new"], fake, "apn set keeping the password")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == oldSecret
              && fake.profilesSet[0].settings.apn == "new" && fake.profilesSet[0].settings.user == "u",
              "apn set without a password option keeps the current password")
        check(kept.code == 0
              && kept.lines.last == "apn: to put it back: RMNet apn set --apn 'old' --type ipv4v6 --user 'u' --auth pap --password",
              "apn set: the put-back of a profile with a password ends --password (R6)", linesText(kept.lines))
        expectNoSecret(kept, oldSecret, "apn set keeping the password")

        // --no-password sends an empty password (R6).
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let cleared = run(["apn", "set", "--no-password"], fake, "apn set --no-password")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == ""
              && fake.profilesSet[0].settings.apn == "old",
              "apn set --no-password: an empty password, the rest as it was")
        check(cleared.code == 0 && cleared.prompts.isEmpty, "apn set --no-password: no password asked")
        expectNoSecret(cleared, oldSecret, "apn set --no-password")

        // --password: read by readSecret after the warning, sent, never printed.
        fake = FakeModem()
        let typed = run(["apn", "set", "--password", "--auth", "pap"], fake, secretAnswer: secret, "apn set --password")
        check(typed.prompts == ["New password for profile 1: "], "apn set --password: the prompt (R16)", "\(typed.prompts)")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == secret
              && fake.profilesSet[0].settings.auth == .pap,
              "apn set --password: the password read reaches setProfile")
        check(fake.events == ["profiles", "output", "readSecret", "setProfile", "output", "output"],
              "apn set --password: read, warn, ask, change, say", "\(fake.events)")
        check(typed.code == 0 && typed.lines.first == warning, "apn set --password: the warning first", linesText(typed.lines))
        expectNoSecret(typed, secret, "apn set --password")
        // An empty answer (a hang-up gives one too) is refused: --no-password clears a password (R16).
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let typedEmpty = run(["apn", "set", "--password"], fake, secretAnswer: "", "apn set --password, empty")
        expectLines(typedEmpty, [warning, "apn: No password was entered. Nothing was changed; use --no-password to clear the password."],
                    code: 1, "apn set --password: an empty answer is refused")
        check(fake.profilesSet.isEmpty && fake.events.filter { $0 != "output" } == ["profiles", "readSecret"],
              "apn set --password: an empty answer changes nothing", "\(fake.events)")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1)])
        let quoteSecret = "pa\"ss-\(secret)"
        let badPassword = run(["apn", "set", "--password", "--auth", "chap"], fake, secretAnswer: quoteSecret,
                              "apn set --password with a quote")
        check(badPassword.code == 1 && fake.profilesSet.isEmpty && badPassword.lines.count == 2
              && badPassword.lines[1].hasPrefix("apn: "),
              "apn set --password: a password the rules refuse is one failure line, nothing set", linesText(badPassword.lines))
        expectNoSecret(badPassword, secret, "apn set --password refused")
        // Not read (Ctrl-C at the prompt, or no terminal): nothing is changed (R16).
        fake = FakeModem()
        let noTerminal = run(["apn", "set", "--password", "--auth", "pap"], fake, secretAnswer: nil,
                             "apn set --password, not read")
        expectLines(noTerminal, [warning, "apn: The password was not read (cancelled, or no terminal). Nothing was changed."],
                    code: 1, "apn set --password: a password not read")
        check(fake.profilesSet.isEmpty && fake.events.filter { $0 != "output" } == ["profiles", "readSecret"],
              "apn set --password: a password not read changes nothing", "\(fake.events)")
        // With no authentication a password is refused before the prompt (R15).
        fake = FakeModem()
        let noAuthPassword = run(["apn", "set", "--password"], fake, secretAnswer: secret, "apn set --password, no auth")
        expectLines(noAuthPassword, [noAuthentication], code: 1, "apn set --password on a profile with no authentication")
        check(noAuthPassword.prompts.isEmpty && fake.profilesSet.isEmpty,
              "apn set --password with no authentication: nothing asked, nothing set")
        for words in [["apn", "set", "--user", "u"], ["apn", "set", "--password", "--auth", "none"],
                      ["apn", "set", "--auth", "none"]] {
            fake = FakeModem()
            fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: keptPassword)])
            if words.contains("--user") { fake.profilesResult = .success(fixtureProfiles) }
            let got = run(words, fake, secretAnswer: secret, "\(words)")
            expectLines(got, [noAuthentication], code: 1, "\(words): credentials with no authentication are refused")
            check(got.prompts.isEmpty && fake.profilesSet.isEmpty, "\(words): nothing asked, nothing set")
            expectNoSecret(got, oldSecret, "\(words)")
        }
        fake = FakeModem()
        run(["apn", "set", "--user", "u", "--auth", "pap-or-chap"], fake, "apn set --user with PAP or CHAP")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.user == "u"
              && fake.profilesSet[0].settings.auth == .papOrChap, "apn set: a user name with an authentication method is sent")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: keptPassword)])
        run(["apn", "set", "--no-password", "--user", "", "--auth", "none"], fake, "apn set back to no authentication")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings
                == ProfileSettings(type: .ipv4v6, apn: "old", user: "", password: "", auth: .none),
              "apn set: back to no authentication with the credentials cleared")
        // An old password the rules refuse does not stop a new one being typed.
        fake = FakeModem()
        let badOld = ProfileSettings(type: .ipv4v6, apn: "x", user: "", password: "a\"b", auth: .pap)
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: badOld)])
        let replaced = run(["apn", "set", "--password"], fake, secretAnswer: secret, "apn set --password over a refused one")
        check(replaced.code == 0 && fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == secret,
              "apn set --password: an old password with a quote is replaced", linesText(replaced.lines))

        // Checked before any change: the profile, then the rules.
        fake = FakeModem()
        let badApn = run(["apn", "set", "--apn", "bad apn", "--password"], fake, secretAnswer: secret, "apn set, bad APN")
        check(badApn.code == 1 && badApn.lines.count == 1 && badApn.lines[0].hasPrefix("apn: ") && badApn.lines[0] != warning,
              "apn set: an APN the rules refuse is one line, exit 1", linesText(badApn.lines))
        check(fake.profilesSet.isEmpty && badApn.prompts.isEmpty, "apn set: a refused APN asks nothing and sets nothing")
        // `--apn` takes the next word as it is; an option typed there is refused as an APN (ruling R21).
        fake = FakeModem()
        let optionAsApn = run(["apn", "set", "--apn", "--no-redial"], fake, "apn set --apn --no-redial")
        expectLines(optionAsApn, ["apn: An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores; "
                                  + "it does not start or end with a dot or a hyphen, has no two dots in a row, and has no hyphen "
                                  + "next to a dot."], code: 1, "apn set --apn --no-redial: refused before anything is changed")
        check(fake.profilesSet.isEmpty, "apn set --apn --no-redial: nothing set")
        fake = FakeModem()
        let unreadProfile = run(["apn", "set", "--apn", "x"], fake, driverProfile: 2, "apn set, profile 2 unread")
        expectLines(unreadProfile, ["apn: Profile 2 could not be read. Nothing was changed."], code: 1,
                    "apn set: settings not read")
        check(fake.profilesSet.isEmpty, "apn set: settings not read, nothing set")
        fake = FakeModem()
        let unlisted = run(["apn", "set", "--apn", "x"], fake, driverProfile: 7, "apn set, profile 7 unlisted")
        expectLines(unlisted, ["apn: Profile 7 could not be read. Nothing was changed."], code: 1, "apn set: profile not listed")
        // A driver's profile above 16: AT+QICSGP cannot change it; said before anything is read.
        for id in [17, 255] {
            fake = FakeModem()
            expectLines(run(["apn", "set", "--apn", "x"], fake, driverProfile: id, "apn set, profile \(id)"),
                        ["apn: Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."], code: 1,
                        "apn set: profile \(id) is refused with the 1-16 rule")
            check(fake.events.filter { $0 != "output" }.isEmpty, "apn set: profile \(id): nothing read, asked or set",
                  "\(fake.events)")
        }
        fake = FakeModem()
        run(["apn", "set", "--apn", "x"], fake, driverProfile: nil, "apn set, driver not attached")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 1, "apn set: without the driver, profile 1")
        fake = FakeModem()
        fake.profilesResult = .failure(ModemFailure(message: "Fake: the profiles could not be read."))
        expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, read failed"),
                    ["apn: Fake: the profiles could not be read."], code: 1, "apn set: the read failed")
        check(fake.profilesSet.isEmpty, "apn set: the read failed, nothing set")
        fake = FakeModem()
        fake.setProfileResult = .failure(ModemFailure(message: "Fake: refused. The radio was switched back on."))
        expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, change failed"),
                    [warning, "apn: Fake: refused. The radio was switched back on."], code: 1, "apn set: the change failed")
        // A change that failed after its line may have reached the modem: the failure, then the way back
        // (ruling R19), one for each of the service's paths.
        for sentence in [
            "It is not known whether profile 1 was changed. The modem did not answer in time. The radio was switched back on.",
            "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"y\", no authentication. "
                + "The radio was switched back on.",
            "Profile 1 could not be read back after the change. The modem did not answer in time. The radio was switched back on.",
        ] {
            fake = FakeModem()
            fake.setProfileResult = .failure(ModemFailure(message: sentence, profileBefore: profile1))
            expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, \(sentence)"), [warning, "apn: \(sentence)", restoreProfile1],
                        code: 1, "apn set: a failure that may have changed the profile says how to put it back: \(sentence)")
        }
        fake = FakeModem()
        let hadPassword = ProfileSettings(type: .ipv4v6, apn: "old", user: "u", password: oldSecret, auth: .pap)
        fake.setProfileResult = .failure(ModemFailure(message: "Fake: not known.", profileBefore: hadPassword))
        let unknownWithPassword = run(["apn", "set", "--apn", "x"], fake, "apn set, not known, a password before")
        expectLines(unknownWithPassword, [warning, "apn: Fake: not known.",
                                          "apn: to put it back: RMNet apn set --apn 'old' --type ipv4v6 --user 'u' --auth pap --password"],
                    code: 1, "apn set: the way back after a failure asks for the password again (--password)")
        expectNoSecret(unknownWithPassword, oldSecret, "apn set, a failure's way back")

        // The redial's outcomes.
        fake = FakeModem()
        fake.redialResult = .radioWasOff
        let wasOff = run(["apn", "set", "--apn", "x"], fake, "apn set, radio was off")
        check(wasOff.code == 0 && wasOff.lines.count == 3, "apn set: the radio was off", linesText(wasOff.lines))
        fake = FakeModem()
        fake.redialResult = .radioLeftOff("Fake: the modem did not answer in time.")
        let leftOff = run(["apn", "set", "--apn", "x"], fake, "apn set, radio left off")
        let leftOffChange = ProfileChange(id: 1, before: profile1, after: settings("x"),
                                          redial: .radioLeftOff("Fake: the modem did not answer in time."))
        expectLines(leftOff, [warning, "apn: " + profileSentence(leftOffChange), restoreProfile1], code: 1,
                    "apn set: the radio left off is exit 1, with the put-back")

        // --- sim ---------------------------------------------------------------------------------
        fake = FakeModem()
        simSlotVerbs()
        expectLines(run(["sim"], fake, "sim"), ["sim: ready", "sim: pin lock: off", "sim: attempts left: PIN 3, PUK 10"],
                    code: 0, "sim: the READY fixture")
        fake = FakeModem()
        expectLines(run(["sim", "--json"], fake, "sim --json"), [prettyJSON(simJSON(readySim))], code: 0,
                    "sim --json: simJSON, pretty, sorted keys")
        fake = FakeModem()
        fake.simResult = .failure(ModemFailure(message: "Fake: the SIM's state could not be read."))
        expectLines(run(["sim"], fake, "sim failed"), ["sim: Fake: the SIM's state could not be read."], code: 1,
                    "sim: a failure")

        // --- sim unlock --------------------------------------------------------------------------
        let askingSim = SimInfo(state: .pin, pinLock: true, pinAttempts: 3, pukAttempts: 10)
        fake = FakeModem()
        let notAsked = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, READY")
        expectLines(notAsked, ["sim: The SIM does not ask for a PIN (ready)."], code: 1, "sim unlock: READY")
        check(notAsked.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: READY never reads a PIN or sends one")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil))
        expectLines(run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, no SIM"),
                    ["sim: The SIM does not ask for a PIN (not inserted)."], code: 1, "sim unlock: no SIM")
        check(fake.pinsEntered.isEmpty, "sim unlock: no SIM, nothing sent")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10))
        let blocked = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, PUK")
        check(blocked.code == 1 && blocked.lines.count == 1 && blocked.lines[0].hasPrefix("sim: ")
              && blocked.lines[0].contains("PUK") && blocked.lines[0].contains("RMNet does not enter PUKs"),
              "sim unlock: blocked, one line naming the PUK", linesText(blocked.lines))
        check(blocked.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: blocked never reads a PIN or sends one")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .pin, pinLock: true, pinAttempts: nil, pukAttempts: nil))
        let unknown = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, attempts unread")
        expectLines(unknown, ["sim: The attempts left could not be read; RMNet does not send a PIN without them."], code: 1,
                    "sim unlock: attempts not read")
        check(unknown.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: attempts not read, nothing asked or sent")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .pin, pinLock: true, pinAttempts: 0, pukAttempts: 10))
        let none = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, 0 attempts")
        check(none.code == 1 && none.lines.count == 1 && none.lines[0].hasPrefix("sim: ") && none.prompts.isEmpty
              && fake.pinsEntered.isEmpty, "sim unlock: 0 attempts, nothing asked or sent", linesText(none.lines))

        let lastAttempt = SimInfo(state: .pin, pinLock: true, pinAttempts: 1, pukAttempts: 10)
        fake = FakeModem()
        fake.simResult = .success(lastAttempt)
        let refusedLast = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, 1 attempt")
        expectLines(refusedLast, [
            "sim: The SIM asks for its PIN. 1 attempt(s) left; a wrong PIN uses one.",
            "sim: This is the last attempt: a wrong PIN blocks the SIM until its PUK is entered. "
                + "Run again with --last-attempt to send it.",
        ], code: 1, "sim unlock: the last attempt without --last-attempt")
        check(refusedLast.prompts.isEmpty && fake.pinsEntered.isEmpty
              && fake.events.filter { $0 != "output" } == ["sim"],
              "sim unlock: the last attempt without --last-attempt never reads a PIN or calls enterPin", "\(fake.events)")

        fake = FakeModem()
        fake.simResult = .success(lastAttempt)
        let sentLast = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock --last-attempt")
        expectLines(sentLast, [
            "sim: The SIM asks for its PIN. 1 attempt(s) left; a wrong PIN uses one.",
            "sim: The SIM accepted the PIN and is ready.",
        ], code: 0, "sim unlock --last-attempt: accepted")
        check(sentLast.prompts == ["PIN: "], "sim unlock: the prompt", "\(sentLast.prompts)")
        check(fake.pinsEntered.count == 1 && fake.pinsEntered[0].pin == pinSecret && fake.pinsEntered[0].shownAttempts == 1,
              "sim unlock --last-attempt: enterPin(pin, shownAttempts: 1)")
        check(fake.events == ["sim", "output", "readSecret", "enterPin", "output"],
              "sim unlock: read, show the attempts, ask, send, say", "\(fake.events)")
        expectNoSecret(sentLast, pinSecret, "sim unlock --last-attempt")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let refusedOutcome = PinOutcome(accepted: false,
                                        sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10),
                                        refusal: "+CME ERROR: 16")
        fake.pinResult = .success(refusedOutcome)
        let refused = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, refused")
        expectLines(refused, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                              "sim: " + pinSentence(refusedOutcome)], code: 1, "sim unlock: refused is exit 1")
        check(fake.pinsEntered.count == 1 && fake.pinsEntered[0].shownAttempts == 3, "sim unlock: shownAttempts 3")
        expectNoSecret(refused, pinSecret, "sim unlock refused")

        check(refused.lines.last == "sim: The SIM refused the PIN. 2 attempts left.", "sim unlock: +CME ERROR: 16 is a wrong PIN",
              linesText(refused.lines))
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        fake.pinResult = .success(PinOutcome(accepted: false, sim: askingSim, refusal: "+CME ERROR: 14"))
        let simBusy = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, SIM busy")
        expectLines(simBusy, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                              "sim: The modem did not take the PIN (+CME ERROR: 14). 3 attempts left; check them before "
                                + "entering it again."], code: 1, "sim unlock: SIM busy is not said as a wrong PIN (F10)")
        expectNoSecret(simBusy, pinSecret, "sim unlock, SIM busy")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        fake.pinResult = .failure(ModemFailure(message: "Fake: the attempts left changed. Nothing was sent."))
        let changed = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, service refused")
        check(changed.code == 1 && changed.lines.last == "sim: Fake: the attempts left changed. Nothing was sent.",
              "sim unlock: the service's failure", linesText(changed.lines))
        expectNoSecret(changed, pinSecret, "sim unlock failed")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let wrongPin = run(["sim", "unlock"], fake, secretAnswer: "12ab", "sim unlock, a PIN with letters")
        check(wrongPin.code == 1 && wrongPin.lines.count == 2 && wrongPin.lines[1].hasPrefix("sim: ") && fake.pinsEntered.isEmpty,
              "sim unlock: a PIN the rules refuse is one failure line, nothing sent", linesText(wrongPin.lines))
        expectNoSecret(wrongPin, "12ab", "sim unlock, a PIN refused")
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let noTty = run(["sim", "unlock"], fake, secretAnswer: nil, "sim unlock, not read")
        expectLines(noTty, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                            "sim: The PIN was not read (cancelled, or no terminal). Nothing was sent."],
                    code: 1, "sim unlock: a PIN not read (R16)")
        check(fake.pinsEntered.isEmpty, "sim unlock: a PIN not read, nothing sent")
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let emptyPin = run(["sim", "unlock"], fake, secretAnswer: "", "sim unlock, empty")
        check(emptyPin.code == 1 && emptyPin.lines.count == 2 && emptyPin.lines[1].hasPrefix("sim: ") && fake.pinsEntered.isEmpty,
              "sim unlock: an empty answer (a hang-up) sends nothing", linesText(emptyPin.lines))
        fake = FakeModem()
        fake.simResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, read failed"), ["sim: Fake: no modem."],
                    code: 1, "sim unlock: the read failed")
        check(fake.pinsEntered.isEmpty, "sim unlock: the read failed, nothing sent")

        usbModeVerb()
        atVerb()
        bandsVerb()

        print("modem cli: \(checks) checks passed")
    }

    // --- at --------------------------------------------------------------------------------------
    static func atVerb() {
        let noCommand = "at: no command given; usage: RMNet at [--timeout <seconds>] <command>"
        let badTimeout = "at: --timeout takes a whole number of seconds from 1 to 300"
        let notAT = "at: a command starts with AT"
        let notPrintable = "at: a command is printable ASCII only (no line end, tab or Ctrl-Z)"
        let tooLong = "at: a command is at most 512 characters"
        let cmgs = "at: AT+CMGS needs a message body; use RMNet sms send"
        let cmgw = "at: AT+CMGW needs a message body; use RMNet sms send"
        let cmgc = "at: AT+CMGC needs a second stage after a > prompt; RMNet at sends one line only"
        let qcmgs = "at: AT+QCMGS needs a second stage after a > prompt; RMNet at sends one line only"
        let usbnet = "at: use RMNet usbmode set to change the USB mode; it warns and checks first"
        let usbcfg = "at: RMNet at does not change the USB configuration (usbcfg): the modem could disappear from RMNet"
        func lockout(_ what: String) -> String {
            "at: RMNet at does not send \(what) (it would switch the AT port to data mode or change how the modem answers, "
                + "and RMNet's own AT features would stop working)"
        }
        let longest = "AT+" + String(repeating: "A", count: 509)       // 512 characters
        let tooLongLine = longest + "A"                                // 513

        // Parsing: the words after the options joined with single spaces, sent as typed.
        expectParse(["at", "ATI"], .at("ATI", timeout: 10))
        expectParse(["at", "AT+CSQ"], .at("AT+CSQ", timeout: 10))
        expectParse(["at", "--timeout", "60", "AT+COPS=?"], .at("AT+COPS=?", timeout: 60))
        expectParse(["at", "--timeout", "1", "ATI"], .at("ATI", timeout: 1))
        expectParse(["at", "--timeout", "300", "ATI"], .at("ATI", timeout: 300))
        // `RMNet at AT+QCFG=\"usbnet\"` and `RMNet at 'AT+QCFG="usbnet"'` both give the shell's one word.
        expectParse(["at", "AT+QCFG=\"usbnet\""], .at("AT+QCFG=\"usbnet\"", timeout: 10))
        // `RMNet at AT+COPS=1,0,\"CHINA MOBILE\"`: two words, joined with one space.
        expectParse(["at", "AT+COPS=1,0,\"CHINA", "MOBILE\""], .at("AT+COPS=1,0,\"CHINA MOBILE\"", timeout: 10))
        expectParse(["at", "AT+QCFG=\"usbnet\",0"], .at("AT+QCFG=\"usbnet\",0", timeout: 10))
        expectParse(["at", "ati"], .at("ati", timeout: 10))
        expectParse(["at", "AT"], .at("AT", timeout: 10))
        expectParse(["at", "AT+CMGL=4"], .at("AT+CMGL=4", timeout: 10))
        // The other SMS commands, and settings that leave the port working, are sent.
        for line in ["AT+CMGR=1", "AT+QCMGR=1", "AT+CMGD=1", "AT+CMGF=0", "AT+CPMS?", "ATS3?", "ATS4?", "ATS0=0", "AT&F",
                     "AT&V", "ATZ", "ATE0", "ATE1", "ATI", "AT+QCFG=\"usbnet\"", "AT+CGDCONT?"] {
            expectParse(["at", line], .at(line, timeout: 10))
        }
        // The USB mode back to QMI (the README's fallback) and the reads of both USB settings are sent.
        for line in ["at+qcfg=\"usbnet\",0", "AT+QCFG=\"usbnet\",0;+CSQ", "AT+QCFG=\"usbcfg\"", "AT+QCFG=?", "AT+QCFG=\"usbnet\";+QCFG=\"usbcfg\""] {
            expectParse(["at", line], .at(line, timeout: 10))
        }
        expectParse(["at", "AT+QCFG=\"usbnet\"", ",", "0"], .at("AT+QCFG=\"usbnet\" , 0", timeout: 10))
        expectParse(["at", longest], .at(longest, timeout: 10))
        // Spaces at the ends are dropped (the port's echo check would never match them); inside, kept.
        expectParse(["at", "ATI "], .at("ATI", timeout: 10))
        expectParse(["at", "ATI", ""], .at("ATI", timeout: 10))
        expectParse(["at", "", "ATI"], .at("ATI", timeout: 10))
        expectParse(["at", "AT+COPS=1,0,\"A  B\""], .at("AT+COPS=1,0,\"A  B\"", timeout: 10))

        // Refused: one line on standard error, exit 2, nothing sent (the fake records no call).
        let refusals: [([String], String)] = [
            (["at"], noCommand), (["at", ""], noCommand), (["at", " "], noCommand), (["at", "--timeout", "10"], noCommand),
            (["at", "--timeout", "0", "ATI"], badTimeout), (["at", "--timeout", "301", "ATI"], badTimeout),
            (["at", "--timeout"], badTimeout), (["at", "--timeout", "abc", "ATI"], badTimeout),
            (["at", "--timeout", "-5", "ATI"], badTimeout), (["at", "--timeout", "1.5", "ATI"], badTimeout),
            (["at", "--timeout", "", "ATI"], badTimeout), (["at", "--timeout", "ATI"], badTimeout),
            (["at", "hello"], notAT), (["at", "A"], notAT), (["at", "+CSQ"], notAT), (["at", "--json", "ATI"], notAT),
            (["at", "--timeout", "5", "--timeout", "6", "ATI"], notAT),
            (["at", "ATI\rAT+CFUN=0"], notPrintable), (["at", "ATI\r"], notPrintable), (["at", "ATI\n"], notPrintable),
            (["at", "ATI\u{1A}"], notPrintable), (["at", "AT+CMGS=\"123\"\u{1A}"], notPrintable),
            (["at", "AT\tI"], notPrintable), (["at", "AT\u{E9}"], notPrintable), (["at", "AT\u{7F}"], notPrintable),
            (["at", "AT\u{1B}"], notPrintable), (["at", "AT\u{202E}I"], notPrintable),
            (["at", tooLongLine], tooLong),
            (["at", "at+cmgs=\"123\""], cmgs), (["at", "AT+CMGS=\"123\""], cmgs), (["at", "At+CmGs"], cmgs),
            (["at", "AT+CMGS=23"], cmgs), (["at", "AT+CMGW"], cmgw), (["at", "at+cmgw=\"123\""], cmgw),
            // A prompt command anywhere in the line, spaces removed; also inside a quoted string.
            (["at", "AT+CSQ;+CMGS=\"1\""], cmgs), (["at", "ATE1+CMGS=1"], cmgs), (["at", "AT", "+CMGS=1"], cmgs),
            (["at", "AT+C", "MGS=1"], cmgs), (["at", "AT+QCFG=\"x+cmgs\""], cmgs), (["at", "AT+CSQ;+cmgw=1"], cmgw),
            (["at", "AT+CMGC=1"], cmgc), (["at", "at+cmgc"], cmgc), (["at", "AT+CSQ;+CMGC=2"], cmgc), (["at", "AT +CMGC"], cmgc),
            (["at", "AT+QCMGS=\"1\",1,1,1"], qcmgs), (["at", "at+qcmgs"], qcmgs), (["at", "AT+CSQ;+QCMGS"], qcmgs),
            (["at", "AT", "+QCMGS"], qcmgs),
            // Data mode, and how the modem answers: the first basic command after AT, spaces removed.
            (["at", "ATD*99#"], lockout("ATD")), (["at", "ATDT123;"], lockout("ATD")), (["at", "atd123"], lockout("ATD")),
            (["at", "AT", "D123"], lockout("ATD")), (["at", "ATD"], lockout("ATD")),
            (["at", "ATO"], lockout("ATO")), (["at", "ATO0"], lockout("ATO")), (["at", "ato"], lockout("ATO")),
            (["at", "ATV0"], lockout("ATV")), (["at", "ATV1"], lockout("ATV")), (["at", "atv"], lockout("ATV")),
            (["at", "AT V0"], lockout("ATV")),
            (["at", "ATQ1"], lockout("ATQ")), (["at", "ATQ0"], lockout("ATQ")), (["at", "atq"], lockout("ATQ")),
            // The line-end characters (S3, S4) anywhere, and &W, which would keep such settings.
            (["at", "ATS3=10"], lockout("ATS3=")), (["at", "ATE1S3=13"], lockout("ATS3=")),
            (["at", "AT", "S3", "=", "13"], lockout("ATS3=")), (["at", "ats3=13"], lockout("ATS3=")),
            (["at", "ATS4=10"], lockout("ATS4=")), (["at", "AT+CSQ;S4=10"], lockout("ATS4=")),
            (["at", "AT&W"], lockout("AT&W")), (["at", "AT&W0"], lockout("AT&W")), (["at", "ATE0&W"], lockout("AT&W")),
            (["at", "AT&F&W"], lockout("AT&W")), (["at", "at&w"], lockout("AT&W")), (["at", "AT+CSQ;& W"], lockout("AT&W")),
            // +CGDATA (enter data state) anywhere.
            (["at", "AT+CGDATA"], lockout("AT+CGDATA")), (["at", "AT+CGDATA=\"PPP\",1"], lockout("AT+CGDATA")),
            (["at", "at+cgdata=1"], lockout("AT+CGDATA")), (["at", "AT+CSQ;+CGDATA"], lockout("AT+CGDATA")),
            (["at", "AT", "+CG", "DATA"], lockout("AT+CGDATA")),
            // A USB mode other than QMI (0): `RMNet usbmode set` warns and checks first.
            (["at", "AT+QCFG=\"usbnet\",1"], usbnet), (["at", "AT+QCFG=\"usbnet\",2"], usbnet),
            (["at", "AT+QCFG=\"usbnet\",3"], usbnet), (["at", "at+qcfg=\"USBNet\",1"], usbnet),
            (["at", "AT+QCFG=usbnet,1"], usbnet), (["at", "AT+QCFG", "=", "\"usbnet\"", ",", "1"], usbnet),
            (["at", "AT+QCFG=\"usbnet\",0;+QCFG=\"usbnet\",2"], usbnet), (["at", "AT+CSQ;+QCFG=\"usbnet\",1"], usbnet),
            (["at", "AT+QCFG=\"usbnet\",01"], usbnet), (["at", "AT+QCFG=\"usbnet\",0,1"], usbnet),
            (["at", "AT+QCFG=\"usbnet\","], usbnet), (["at", "AT+QCFG=\"usbnet\",\"0\""], usbnet),
            // Any write of the USB configuration (the read is sent).
            (["at", "AT+QCFG=\"usbcfg\",0x2C7C,0x0801,1,1,1,1,1,0,0"], usbcfg), (["at", "at+qcfg=\"usbcfg\",0"], usbcfg),
            (["at", "AT+QCFG=usbcfg,0"], usbcfg), (["at", "AT+CSQ;+QCFG=\"usbcfg\",0x2C7C"], usbcfg),
            (["at", "AT+QCFG=\"usbnet\",0;+QCFG=\"usbcfg\",0"], usbcfg),
        ]
        for (words, line) in refusals {
            let fake = FakeModem()
            let refused = run(words, fake, "\(words.debugDescription)")
            expectOutput(refused, out: [], err: [line], code: 2, "\(words.debugDescription): refused")
            check(fake.atSent.isEmpty && fake.events == ["error"], "\(words.debugDescription): refused, nothing sent",
                  "\(fake.events) \(fake.atSent)")
        }

        // The answer: each line, then OK.
        var fake = FakeModem()
        fake.atResult = .success(["Quectel", "RM520N-GL", "Revision: X"])
        expectOutput(run(["at", "ATI"], fake, "at ATI"), out: ["Quectel", "RM520N-GL", "Revision: X", "OK"], err: [],
                     code: 0, "at ATI: the answer lines, then OK")
        check(fake.atSent == ["ATI 10.0"] && fake.events.filter({ $0 != "output" }) == ["at"],
              "at ATI: one call, ATI with 10 s", "\(fake.atSent) \(fake.events)")
        fake = FakeModem()
        expectOutput(run(["at", "--timeout", "60", "AT+COPS=?"], fake, "at --timeout 60"), out: ["OK"], err: [], code: 0,
                     "at AT+COPS=?: OK alone")
        check(fake.atSent == ["AT+COPS=? 60.0"], "at --timeout 60: the service gets 60 s", "\(fake.atSent)")
        fake = FakeModem()
        fake.atResult = .success(["+CSQ: 20,99"])
        expectOutput(run(["at", "AT+COPS=1,0,\"CHINA", "MOBILE\""], fake, "at, two words"), out: ["+CSQ: 20,99", "OK"],
                     err: [], code: 0, "at, two words: the answer")
        check(fake.atSent == ["AT+COPS=1,0,\"CHINA MOBILE\" 10.0"], "at, two words: one line, one space", "\(fake.atSent)")
        // An answer line is printed display-safe, as all text from the modem.
        fake = FakeModem()
        fake.atResult = .success(["a\u{202E}b\u{85}c"])
        expectOutput(run(["at", "AT+CMGL=4"], fake, "at, unsafe text"), out: ["a\u{FFFD}b\u{FFFD}c", "OK"], err: [], code: 0,
                     "at: an answer line is made display-safe")

        // The modem's error line: on standard output, as an AT terminal shows it; exit 1. V.250's other final
        // results (AtPort ends the answer on them) are such lines too: `RMNet at ATA` with no call prints
        // NO CARRIER.
        for errorLine in ["ERROR", "+CME ERROR: 10", "+CMS ERROR: 500", "NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE"] {
            fake = FakeModem()
            fake.atResult = .failure(ModemFailure(message: errorLine, atKind: .modemError))
            expectOutput(run(["at", "ATA"], fake, "at, \(errorLine)"), out: [errorLine], err: [], code: 1,
                         "at: \(errorLine) on standard output, exit 1")
        }

        // No answer in time: `at: no answer in <n> s` with the timeout given; exit 1.
        for (words, seconds) in [(["at", "ATI"], 10), (["at", "--timeout", "60", "AT+COPS=?"], 60),
                                 (["at", "--timeout", "1", "ATI"], 1)] {
            fake = FakeModem()
            fake.atResult = .failure(ModemFailure(message: "The modem did not answer in time.", atKind: .timeout))
            expectOutput(run(words, fake, "\(words), timeout"), out: [], err: ["at: no answer in \(seconds) s"], code: 1,
                         "\(words): a timeout")
        }

        // Any other failure: its text on standard error, exit 1.
        for message in ["The RM520N-GL (USB 2c7c:0801) is not attached.", "The modem did not answer in time.",
                        "Another program is using the modem's spare AT port."] {
            fake = FakeModem()
            fake.atResult = .failure(ModemFailure(message: message))
            expectOutput(run(["at", "ATI"], fake, "at, \(message)"), out: [], err: ["at: \(message)"], code: 1,
                         "at: a failure (\(message))")
        }
    }

    // --- usbmode ---------------------------------------------------------------------------------
    static func usbModeVerb() {
        let question = "The modem will restart (about 30 s) and the network port will go away until it is back. Continue? [y/N] "
        func otherModeWarning(_ name: String) -> String {
            "In \(name) mode this driver does not work; to come back: RMNet usbmode set qmi (if RMNet cannot find the modem "
                + "afterwards, send AT+QCFG=\"usbnet\",0 then AT+CFUN=1,1 from other software that talks to the modem "
                + "over USB, or from another computer)"
        }
        let noTerminal = "usb mode: no terminal to ask on, so nothing changed; run again with --yes to restart the modem "
            + "without asking"
        func reads(_ value: Int) -> FakeModem {
            let fake = FakeModem()
            fake.usbModeResult = .success(UsbModeInfo(value: value))
            return fake
        }
        func calls(_ fake: FakeModem) -> [String] { fake.events.filter { $0 != "output" } }

        // Showing.
        var fake = FakeModem()
        let shown = run(["usbmode"], fake, answer: "y", "usbmode")
        expectLines(shown, ["usb mode: qmi (the RMNet driver works in this mode)"], code: 0, "usbmode: qmi")
        check(calls(fake) == ["usbMode"] && shown.questions.isEmpty, "usbmode: one read, nothing asked", "\(fake.events)")
        for (value, name) in [(1, "ecm"), (2, "mbim"), (3, "rndis"), (7, "unknown (7)"), (-1, "unknown (-1)")] {
            fake = reads(value)
            expectLines(run(["usbmode"], fake, "usbmode \(value)"),
                        ["usb mode: \(name) (the RMNet driver needs qmi: RMNet usbmode set qmi)"], code: 0, "usbmode: \(name)")
            check(fake.usbModesSet.isEmpty, "usbmode \(value): changes nothing")
        }
        fake = FakeModem()
        let json = run(["usbmode", "--json"], fake, "usbmode --json")
        expectLines(json, [prettyJSON(["mode": "qmi", "value": 0, "driverWorks": true])], code: 0,
                    "usbmode --json: mode, value, driverWorks; pretty, sorted keys")
        if let data = json.lines.first?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            check(object.keys.sorted() == ["driverWorks", "mode", "value"] && object["mode"] as? String == "qmi"
                  && object["value"] as? Int == 0 && object["driverWorks"] as? Bool == true,
                  "usbmode --json: {\"mode\":\"qmi\",\"value\":0,\"driverWorks\":true}", json.lines[0])
        } else {
            check(false, "usbmode --json: one JSON object", linesText(json.lines))
        }
        for (value, name) in [(2, "mbim"), (9, "unknown (9)")] {
            fake = reads(value)
            expectLines(run(["usbmode", "--json"], fake, "usbmode --json \(value)"),
                        [prettyJSON(["mode": name, "value": value, "driverWorks": false])], code: 0,
                        "usbmode --json: \(name), the driver does not work")
        }
        for words in [["usbmode"], ["usbmode", "--json"]] {
            fake = FakeModem()
            fake.usbModeResult = .failure(ModemFailure(message: "Fake: no modem."))
            expectLines(run(words, fake, "\(words) failed"), ["usb mode: Fake: no modem."], code: 1, "\(words): a failure")
        }

        // Already in the mode asked: nothing asked, nothing set, no restart.
        for words in [["usbmode", "set", "qmi"], ["usbmode", "set", "qmi", "--yes"], ["usbmode", "set", "qmi", "--no-reboot"]] {
            fake = FakeModem()
            let already = run(words, fake, answer: "y", "\(words), already")
            expectLines(already, ["usb mode: already qmi; nothing changed"], code: 0, "\(words): already qmi")
            check(calls(fake) == ["usbMode"] && already.questions.isEmpty && fake.usbModesSet.isEmpty,
                  "\(words): already qmi: one read, nothing asked or set", "\(fake.events)")
        }
        fake = reads(2)
        expectLines(run(["usbmode", "set", "mbim"], fake, answer: "y", "set mbim, already"),
                    ["usb mode: already mbim; nothing changed"], code: 0, "usbmode set mbim: already mbim")
        check(fake.usbModesSet.isEmpty, "usbmode set mbim: already mbim, nothing set")

        // To qmi: the question, then the change and the restart.
        for typed in ["y", "yes", "Y", "YES", "Yes", " y ", "yes\r"] {
            fake = reads(2)
            let toQmi = run(["usbmode", "set", "qmi"], fake, answer: typed, "set qmi, \(typed.debugDescription)")
            expectLines(toQmi, ["usb mode set to qmi; the modem is restarting"], code: 0,
                        "usbmode set qmi: \(typed.debugDescription) restarts")
            check(toQmi.questions == [question], "usbmode set qmi: the question", "\(toQmi.questions)")
            check(fake.usbModesSet == ["qmi reboot"], "usbmode set qmi: setUsbMode(.qmi, reboot: true)", "\(fake.usbModesSet)")
            check(fake.events == ["usbMode", "ask", "setUsbMode", "output"], "usbmode set qmi: read, ask, set, say",
                  "\(fake.events)")
        }
        fake = reads(7)
        expectLines(run(["usbmode", "set", "qmi"], fake, answer: "y", "set qmi from unknown"),
                    ["usb mode set to qmi; the modem is restarting"], code: 0, "usbmode set qmi from an unknown mode")

        // To another mode: the warning line, then the question.
        for (mode, name) in [(UsbNetMode.ecm, "ecm"), (.mbim, "mbim"), (.rndis, "rndis")] {
            fake = FakeModem()
            let other = run(["usbmode", "set", name], fake, answer: "y", "set \(name)")
            expectLines(other, [otherModeWarning(name), "usb mode set to \(name); the modem is restarting"], code: 0,
                        "usbmode set \(name): the warning, then the result")
            check(other.questions == [question], "usbmode set \(name): the question", "\(other.questions)")
            check(fake.usbModesSet == ["\(mode.name) reboot"], "usbmode set \(name): setUsbMode(.\(name), reboot: true)",
                  "\(fake.usbModesSet)")
            check(fake.events == ["usbMode", "output", "ask", "setUsbMode", "output"],
                  "usbmode set \(name): read, warn, ask, set, say", "\(fake.events)")
        }

        // Anything but y or yes cancels.
        for typed in ["", "n", "no", "N", "yess", "y es", "ye", "ok", "q"] {
            fake = reads(2)
            let cancelled = run(["usbmode", "set", "qmi"], fake, answer: typed, "set qmi, \(typed.debugDescription)")
            expectLines(cancelled, ["cancelled; nothing changed"], code: 1, "usbmode set qmi: \(typed.debugDescription) cancels")
            check(fake.usbModesSet.isEmpty && calls(fake) == ["usbMode", "ask"],
                  "usbmode set qmi: \(typed.debugDescription): nothing set", "\(fake.events)")
        }
        fake = FakeModem()
        expectLines(run(["usbmode", "set", "ecm"], fake, answer: "n", "set ecm, n"),
                    [otherModeWarning("ecm"), "cancelled; nothing changed"], code: 1, "usbmode set ecm: n cancels")
        check(fake.usbModesSet.isEmpty, "usbmode set ecm: cancelled, nothing set")

        // No terminal and no --yes: refused, exit 2, setUsbMode never called.
        fake = reads(2)
        let unasked = run(["usbmode", "set", "qmi"], fake, answer: nil, "set qmi, no terminal")
        expectLines(unasked, [noTerminal], code: 2, "usbmode set qmi: no terminal, no --yes")
        check(fake.usbModesSet.isEmpty && calls(fake) == ["usbMode", "ask"], "usbmode set qmi: no terminal: no setUsbMode",
              "\(fake.events)")
        fake = FakeModem()
        expectLines(run(["usbmode", "set", "rndis"], fake, answer: nil, "set rndis, no terminal"),
                    [otherModeWarning("rndis"), noTerminal], code: 2, "usbmode set rndis: no terminal, no --yes")
        check(fake.usbModesSet.isEmpty, "usbmode set rndis: no terminal: no setUsbMode")

        // --yes: nothing asked; the warning line still printed.
        fake = reads(1)
        let yesQmi = run(["usbmode", "set", "qmi", "--yes"], fake, answer: nil, "set qmi --yes")
        expectLines(yesQmi, ["usb mode set to qmi; the modem is restarting"], code: 0, "usbmode set qmi --yes")
        check(yesQmi.questions.isEmpty && fake.usbModesSet == ["qmi reboot"], "usbmode set qmi --yes: set without asking",
              "\(fake.events)")
        fake = FakeModem()
        let yesEcm = run(["usbmode", "set", "ecm", "--yes"], fake, answer: "n", "set ecm --yes")
        expectLines(yesEcm, [otherModeWarning("ecm"), "usb mode set to ecm; the modem is restarting"], code: 0,
                    "usbmode set ecm --yes: the warning, no question")
        check(yesEcm.questions.isEmpty && fake.events == ["usbMode", "output", "setUsbMode", "output"],
              "usbmode set ecm --yes: read, warn, set, say", "\(fake.events)")

        // --no-reboot: set for the next restart; nothing restarts, so nothing is asked.
        for words in [["usbmode", "set", "qmi", "--no-reboot"], ["usbmode", "set", "qmi", "--no-reboot", "--yes"]] {
            fake = reads(3)
            let later = run(words, fake, answer: nil, "\(words)")
            expectLines(later, ["usb mode set to qmi; it takes effect at the next restart (AT+CFUN=1,1 or a replug)"], code: 0,
                        "\(words): set for the next restart")
            check(later.questions.isEmpty && fake.usbModesSet == ["qmi no reboot"],
                  "\(words): setUsbMode(.qmi, reboot: false), nothing asked", "\(fake.usbModesSet)")
        }
        fake = FakeModem()
        expectLines(run(["usbmode", "set", "mbim", "--no-reboot"], fake, answer: nil, "set mbim --no-reboot"),
                    [otherModeWarning("mbim"),
                     "usb mode set to mbim; it takes effect at the next restart (AT+CFUN=1,1 or a replug)"],
                    code: 0, "usbmode set mbim --no-reboot: the warning, then the result")
        check(fake.usbModesSet == ["mbim no reboot"], "usbmode set mbim --no-reboot: reboot false", "\(fake.usbModesSet)")

        // The service's answers.
        fake = reads(2)
        fake.setUsbModeResult = .success(.unchanged)
        expectLines(run(["usbmode", "set", "qmi"], fake, answer: "y", "set qmi, unchanged meanwhile"),
                    ["usb mode: already qmi; nothing changed"], code: 0, "usbmode set qmi: the service found it already qmi")
        fake = FakeModem()
        fake.setUsbModeResult = .failure(ModemFailure(message: "Fake: refused."))
        expectLines(run(["usbmode", "set", "ecm"], fake, answer: "y", "set ecm failed"),
                    [otherModeWarning("ecm"), "usb mode: Fake: refused."], code: 1, "usbmode set ecm: a failure")
        fake = FakeModem()
        fake.usbModeResult = .failure(ModemFailure(message: "Fake: no modem."))
        let unread = run(["usbmode", "set", "ecm", "--yes"], fake, answer: "y", "set ecm, read failed")
        expectLines(unread, ["usb mode: Fake: no modem."], code: 1, "usbmode set ecm: the read failed")
        check(unread.questions.isEmpty && fake.usbModesSet.isEmpty, "usbmode set ecm: the read failed, nothing asked or set")

        // The real `ask` (askOnTerminal), its steps injected: the question goes to /dev/tty when that opens, as
        // the PIN prompt does (so it is seen also when standard output is piped), else to standard output as
        // before; the answer is read from standard input, and only when standard input is a terminal.
        func askSteps(stdinIsTerminal: Bool, ttyOpens: Bool, answer: String?) -> (got: String?, steps: [String]) {
            var steps: [String] = []
            let got = askOnTerminal(question, inputIsTerminal: stdinIsTerminal,
                                    terminal: { text in
                                        steps.append(ttyOpens ? "tty: \(text)" : "tty did not open")
                                        return ttyOpens
                                    },
                                    output: { text in steps.append("stdout: \(text)") },
                                    readAnswer: {
                                        steps.append("read")
                                        return answer
                                    })
            return (got, steps)
        }
        let onTty = askSteps(stdinIsTerminal: true, ttyOpens: true, answer: "y")
        check(onTty.got == "y" && onTty.steps == ["tty: \(question)", "read"],
              "askOnTerminal: the question on /dev/tty, nothing on standard output, then the answer read",
              "\(onTty)")
        let noTty = askSteps(stdinIsTerminal: true, ttyOpens: false, answer: "n")
        check(noTty.got == "n" && noTty.steps == ["tty did not open", "stdout: \(question)", "read"],
              "askOnTerminal: /dev/tty does not open: the question on standard output, then the answer read",
              "\(noTty)")
        let ended = askSteps(stdinIsTerminal: true, ttyOpens: true, answer: nil)
        check(ended.got == "" && ended.steps == ["tty: \(question)", "read"],
              "askOnTerminal: the end of input (Ctrl-D) is an empty answer, which cancels", "\(ended)")
        for ttyOpens in [true, false] {
            let piped = askSteps(stdinIsTerminal: false, ttyOpens: ttyOpens, answer: "y")
            check(piped.got == nil && piped.steps.isEmpty,
                  "askOnTerminal: standard input not a terminal: nil, nothing shown or read (tty opens: \(ttyOpens))",
                  "\(piped)")
        }
    }

    // --- bands -----------------------------------------------------------------------------------
    static func bandsVerb() {
        func warning(_ name: String, _ list: String, was: String) -> String {
            "\(name) bands: \(list) (was \(was)); the modem may re-select a cell and drop the connection for a few seconds"
        }
        func joined(_ bands: [Int]) -> String { bands.map { String($0) }.joined(separator: ":") }
        func calls(_ fake: FakeModem) -> [String] { fake.events.filter { $0 != "output" } }
        func with(_ sets: [BandSet]) -> FakeModem {
            let fake = FakeModem()
            fake.bandsResult = .success(sets)
            return fake
        }
        let refused = ModemFailure(message: "Fake: refused.")
        func notReset(_ names: String) -> String { "bands: not reset: \(names) (run RMNet bands reset <rat> to try again)" }

        // Parsing: every form.
        expectParse(["bands"], .bands(json: false))
        expectParse(["bands", "--json"], .bands(json: true))
        expectParse(["bands", "set", "sa", "n41"], .bandsSet(.sa, [41]))
        expectParse(["bands", "set", "sa", "41"], .bandsSet(.sa, [41]))
        expectParse(["bands", "set", "lte", "3,41"], .bandsSet(.lte, [3, 41]))
        expectParse(["bands", "set", "nsa", "41:78"], .bandsSet(.nsa, [41, 78]))
        expectParse(["bands", "set", "sa", "n41:n78"], .bandsSet(.sa, [41, 78]))
        expectParse(["bands", "set", "sa", "N78,n41"], .bandsSet(.sa, [41, 78]))
        expectParse(["bands", "set", "nsa", "n78:41,N1"], .bandsSet(.nsa, [1, 41, 78]))
        expectParse(["bands", "set", "lte", "b3,B41"], .bandsSet(.lte, [3, 41]))
        expectParse(["bands", "set", "lte", "41,3,b3,3"], .bandsSet(.lte, [3, 41]))       // each band once, ascending
        expectParse(["bands", "set", "lte", "99"], .bandsSet(.lte, [99]))                // not supported: the run refuses it
        expectParse(["bands", "reset"], .bandsReset(nil))
        expectParse(["bands", "reset", "lte"], .bandsReset(.lte))
        expectParse(["bands", "reset", "nsa"], .bandsReset(.nsa))
        expectParse(["bands", "reset", "sa"], .bandsReset(.sa))

        // Parsing: wrong usage (exit 2, nothing opened).
        for words in [
            ["bands", "set"], ["bands", "set", "sa"], ["bands", "set", "xx", "41"], ["bands", "set", "sa", "n41,abc"],
            ["bands", "reset", "foo"], ["bands", "set", "sa", "41", "78"], ["bands", "set", "sa", "41", "--json"],
            ["bands", "reset", "lte", "sa"], ["bands", "reset", "--json"], ["bands", "--json", "--json"], ["bands", "show"],
            ["bands", "json"], ["bands", "--json", "set", "sa", "41"], ["bands", "set", "41"], ["bands", "set", "SA", "41"],
            ["bands", "set", "Lte", "3"], ["bands", "reset", "LTE"], ["bands", "set", "5g", "41"], ["bands", "set", "nr5g", "41"],
            // A prefix for the other RAT: b only for lte, n only for nsa and sa.
            ["bands", "set", "lte", "n3"], ["bands", "set", "lte", "N3"], ["bands", "set", "sa", "b41"],
            ["bands", "set", "nsa", "B41"], ["bands", "set", "lte", "3,n41"],
            // Not a list of band numbers.
            ["bands", "set", "sa", ""], ["bands", "set", "sa", ","], ["bands", "set", "sa", "41,"], ["bands", "set", "sa", ",41"],
            ["bands", "set", "sa", "41,,78"], ["bands", "set", "sa", "41::78"], ["bands", "set", "sa", "n"],
            ["bands", "set", "sa", "nn41"], ["bands", "set", "sa", "n 41"], ["bands", "set", "sa", "4 1"],
            ["bands", "set", "sa", "+41"], ["bands", "set", "sa", "-41"], ["bands", "set", "sa", "0"], ["bands", "set", "sa", "n0"],
            ["bands", "set", "sa", "41;78"], ["bands", "set", "sa", "41.5"], ["bands", "set", "sa", "41n"],
            ["bands", "set", "lte", "\u{0663}"], ["bands", "set", "sa", "99999999999999999999"], ["bands", "set", "sa", "all"],
            ["Bands"], ["band"],
        ] {
            expectWrongUsage(words)
        }

        // Showing: one line per RAT, then its supported bands, indented.
        var fake = FakeModem()
        let shown = run(["bands"], fake, "bands")
        expectLines(shown, ["LTE: all 31 supported bands allowed", "  supported: \(lteWords)",
                            "5G NSA: all 28 supported bands allowed", "  supported: \(nrWords)",
                            "5G SA: all 28 supported bands allowed", "  supported: \(nrWords)"],
                    code: 0, "bands: every supported band allowed")
        check(calls(fake) == ["bands"], "bands: one read, nothing set", "\(fake.events)")
        fake = with(bandSets(lte: [3, 41], nsa: [], sa: [41]))
        expectLines(run(["bands"], fake, "bands, locked"),
                    ["LTE: 2 of 31 supported bands allowed: 3, 41", "  supported: \(lteWords)",
                     "5G NSA: 0 of 28 supported bands allowed: none", "  supported: \(nrWords)",
                     "5G SA: 1 of 28 supported bands allowed: 41", "  supported: \(nrWords)"],
                    code: 0, "bands: locked to some bands")
        // The same bands in another order are all of them.
        fake = with(bandSets(lte: lteSupported.reversed()))
        check(run(["bands"], fake, "bands, reversed").lines.first == "LTE: all 31 supported bands allowed",
              "bands: compared as a set")

        // --json: one array, a RAT an object.
        fake = with(bandSets(sa: [41, 78]))
        let json = run(["bands", "--json"], fake, "bands --json")
        let want: [[String: Any]] = [["rat": "lte", "allowed": lteSupported, "supported": lteSupported],
                                     ["rat": "nsa", "allowed": nrSupported, "supported": nrSupported],
                                     ["rat": "sa", "allowed": [41, 78], "supported": nrSupported]]
        let wantText = String(data: try! JSONSerialization.data(withJSONObject: want, options: [.prettyPrinted, .sortedKeys]),
                              encoding: .utf8)!
        expectLines(json, [wantText], code: 0, "bands --json: pretty, sorted keys")
        if let data = json.lines.first?.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            check(array.map { $0["rat"] as? String } == ["lte", "nsa", "sa"]
                  && array.allSatisfy { $0.keys.sorted() == ["allowed", "rat", "supported"] }
                  && array[2]["allowed"] as? [Int] == [41, 78] && array[0]["supported"] as? [Int] == lteSupported,
                  "bands --json: [{\"rat\":\"lte\",\"allowed\":[…],\"supported\":[…]}, …]", json.lines[0])
        } else {
            check(false, "bands --json: one JSON array", linesText(json.lines))
        }
        for words in [["bands"], ["bands", "--json"]] {
            fake = FakeModem()
            fake.bandsResult = .failure(ModemFailure(message: "Fake: no modem."))
            expectLines(run(words, fake, "\(words) failed"), ["bands: Fake: no modem."], code: 1, "\(words): a failure")
        }

        // set: the warning, the change, the result; no prompt.
        fake = FakeModem()
        let setSA = run(["bands", "set", "sa", "n41"], fake, answer: nil, "bands set sa n41")
        expectLines(setSA, [warning("5G SA", "41", was: "all supported"), "5G SA bands set to 41"], code: 0, "bands set sa n41")
        check(fake.bandsAsked == ["sa 41"], "bands set sa n41: setBands(.sa, [41])", "\(fake.bandsAsked)")
        check(fake.events == ["bands", "output", "setBands", "output"] && setSA.questions.isEmpty,
              "bands set sa n41: read, warn, set, say; nothing asked", "\(fake.events)")
        fake = FakeModem()
        expectLines(run(["bands", "set", "lte", "3,41"], fake, "bands set lte 3,41"),
                    [warning("LTE", "3, 41", was: "all supported"), "LTE bands set to 3, 41"], code: 0, "bands set lte 3,41")
        check(fake.bandsAsked == ["lte 3:41"], "bands set lte 3,41: setBands(.lte, [3, 41])", "\(fake.bandsAsked)")
        fake = FakeModem()
        expectLines(run(["bands", "set", "nsa", "78:n41,41"], fake, "bands set nsa 78:n41,41"),
                    [warning("5G NSA", "41, 78", was: "all supported"), "5G NSA bands set to 41, 78"], code: 0,
                    "bands set nsa: sorted, each band once")
        check(fake.bandsAsked == ["nsa 41:78"], "bands set nsa: setBands(.nsa, [41, 78])", "\(fake.bandsAsked)")
        fake = with(bandSets(lte: [3, 41]))
        expectLines(run(["bands", "set", "lte", "b3"], fake, "bands set lte b3 from 3, 41"),
                    [warning("LTE", "3", was: "3, 41"), "LTE bands set to 3"], code: 0, "bands set lte: was a list")

        // Already allowed: nothing set.
        for words in [["bands", "set", "lte", "41,3"], ["bands", "set", "lte", "b3:B41:3"]] {
            fake = with(bandSets(lte: [3, 41]))
            expectLines(run(words, fake, "\(words), already"), ["LTE bands: already 3, 41; nothing changed"], code: 0,
                        "\(words): already allowed")
            check(calls(fake) == ["bands"], "\(words): already allowed, nothing set", "\(fake.events)")
        }

        // Refused before the warning: a band the modem does not support (exit 1, nothing set).
        fake = FakeModem()
        expectLines(run(["bands", "set", "sa", "n99"], fake, "bands set sa n99"),
                    ["bands: The modem does not support 5G SA band 99 (supported: \(nrWords)). The 5G SA bands were not changed."],
                    code: 1, "bands set sa n99: not supported")
        check(calls(fake) == ["bands"], "bands set sa n99: nothing set", "\(fake.events)")
        fake = FakeModem()
        expectLines(run(["bands", "set", "lte", "41,9,6"], fake, "bands set lte 41,9,6"),
                    ["bands: The modem does not support LTE bands 6, 9 (supported: \(lteWords)). The LTE bands were not changed."],
                    code: 1, "bands set lte 41,9,6: names the bands not supported")
        check(fake.bandsAsked.isEmpty, "bands set lte 41,9,6: nothing set")

        // Failures.
        fake = FakeModem()
        fake.bandsResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["bands", "set", "sa", "41"], fake, "bands set, read failed"),
                    ["bands: Fake: no modem. Nothing was changed."], code: 1, "bands set: the read failed")
        check(fake.bandsAsked.isEmpty, "bands set: the read failed, nothing set")
        fake = FakeModem()
        fake.setBandsResults[.sa] = .failure(refused)
        expectLines(run(["bands", "set", "sa", "41"], fake, "bands set, refused"),
                    [warning("5G SA", "41", was: "all supported"), "bands: Fake: refused."], code: 1, "bands set: a failure")
        fake = FakeModem()
        fake.setBandsResults[.sa] = .success(BandChange(before: [41], after: [41]))
        expectLines(run(["bands", "set", "sa", "41"], fake, "bands set, unchanged meanwhile"),
                    [warning("5G SA", "41", was: "all supported"), "5G SA bands: already 41; nothing changed"], code: 0,
                    "bands set: the service found it already set")
        fake = with([BandSet(rat: .lte, allowed: lteSupported, supported: lteSupported)])
        expectLines(run(["bands", "set", "sa", "41"], fake, "bands set, no SA read"),
                    ["bands: The modem did not report its 5G SA bands. The 5G SA bands were not changed."], code: 1,
                    "bands set: a RAT not read")
        check(fake.bandsAsked.isEmpty, "bands set: a RAT not read, nothing set")

        // reset one RAT: to every supported band.
        fake = with(bandSets(sa: [41]))
        expectLines(run(["bands", "reset", "sa"], fake, "bands reset sa"),
                    [warning("5G SA", nrWords, was: "41"), "5G SA bands set to \(nrWords)"], code: 0, "bands reset sa")
        check(fake.bandsAsked == ["sa \(joined(nrSupported))"], "bands reset sa: setBands(.sa, supported)", "\(fake.bandsAsked)")
        fake = FakeModem()
        expectLines(run(["bands", "reset", "lte"], fake, "bands reset lte, already"),
                    ["LTE bands: already \(lteWords); nothing changed"], code: 0, "bands reset lte: already every band")
        check(calls(fake) == ["bands"], "bands reset lte: already, nothing set", "\(fake.events)")
        fake = with([BandSet(rat: .lte, allowed: [3], supported: []), BandSet(rat: .nsa, allowed: [], supported: nrSupported),
                     BandSet(rat: .sa, allowed: [], supported: nrSupported)])
        expectLines(run(["bands", "reset", "lte"], fake, "bands reset lte, none supported"),
                    ["bands: At least one LTE band is needed. The LTE bands were not changed."], code: 1,
                    "bands reset lte: no band supported, never an empty write")
        check(fake.bandsAsked.isEmpty, "bands reset lte: no band supported, nothing set")

        // reset all: lte, nsa, sa in that order, each reported.
        fake = with(bandSets(lte: [3, 41], sa: [41]))
        expectLines(run(["bands", "reset"], fake, "bands reset"),
                    [warning("LTE", lteWords, was: "3, 41"), "LTE bands set to \(lteWords)",
                     "5G NSA bands: already \(nrWords); nothing changed",
                     warning("5G SA", nrWords, was: "41"), "5G SA bands set to \(nrWords)"], code: 0, "bands reset: all three")
        check(fake.bandsAsked == ["lte \(joined(lteSupported))", "sa \(joined(nrSupported))"],
              "bands reset: lte and sa set, nsa already", "\(fake.bandsAsked)")
        check(fake.events == ["bands", "output", "setBands", "output", "output", "output", "setBands", "output"],
              "bands reset: one read, then each RAT in order", "\(fake.events)")
        fake = FakeModem()
        expectLines(run(["bands", "reset"], fake, "bands reset, already"),
                    ["LTE bands: already \(lteWords); nothing changed", "5G NSA bands: already \(nrWords); nothing changed",
                     "5G SA bands: already \(nrWords); nothing changed"], code: 0, "bands reset: all already")
        check(calls(fake) == ["bands"], "bands reset: all already, nothing set", "\(fake.events)")

        // reset all stops at the first failure.
        fake = with(bandSets(lte: [3], nsa: [41], sa: [78]))
        fake.setBandsResults[.nsa] = .failure(refused)
        expectLines(run(["bands", "reset"], fake, "bands reset, nsa fails"),
                    [warning("LTE", lteWords, was: "3"), "LTE bands set to \(lteWords)", warning("5G NSA", nrWords, was: "41"),
                     "bands: Fake: refused.", notReset("5G NSA, 5G SA")], code: 1,
                    "bands reset: stops at the NSA failure, naming the RATs not reset")
        check(fake.bandsAsked == ["lte \(joined(lteSupported))", "nsa \(joined(nrSupported))"],
              "bands reset: nothing set after the failure", "\(fake.bandsAsked)")
        fake = with(bandSets(lte: [3], nsa: [41], sa: [78]))
        fake.setBandsResults[.lte] = .failure(refused)
        expectLines(run(["bands", "reset"], fake, "bands reset, lte fails"),
                    [warning("LTE", lteWords, was: "3"), "bands: Fake: refused.", notReset("LTE, 5G NSA, 5G SA")], code: 1,
                    "bands reset: stops at the LTE failure, naming all three")
        check(fake.bandsAsked == ["lte \(joined(lteSupported))"], "bands reset: only LTE tried", "\(fake.bandsAsked)")
        fake = with(bandSets(lte: [3], nsa: [41], sa: [78]))
        fake.setBandsResults[.sa] = .failure(refused)
        expectLines(run(["bands", "reset"], fake, "bands reset, sa fails"),
                    [warning("LTE", lteWords, was: "3"), "LTE bands set to \(lteWords)", warning("5G NSA", nrWords, was: "41"),
                     "5G NSA bands set to \(nrWords)", warning("5G SA", nrWords, was: "78"), "bands: Fake: refused.",
                     notReset("5G SA")], code: 1, "bands reset: stops at the SA failure, naming SA alone")
        // LTE set, then a failure before NSA's write: it names NSA, never "Nothing was changed.".
        fake = with([BandSet(rat: .lte, allowed: [3], supported: lteSupported), BandSet(rat: .sa, allowed: [78], supported: nrSupported)])
        let partial = run(["bands", "reset"], fake, "bands reset, nsa not read")
        expectLines(partial, [warning("LTE", lteWords, was: "3"), "LTE bands set to \(lteWords)",
                              "bands: The modem did not report its 5G NSA bands. The 5G NSA bands were not changed.",
                              notReset("5G NSA, 5G SA")], code: 1, "bands reset: LTE set, NSA not read")
        check(!partial.lines.contains { $0.contains("Nothing was changed") }, "bands reset: after LTE was set, never \"Nothing was changed.\"",
              linesText(partial.lines))
        check(fake.bandsAsked == ["lte \(joined(lteSupported))"], "bands reset: NSA not read, nothing more set", "\(fake.bandsAsked)")
        fake = with([BandSet(rat: .lte, allowed: [3], supported: lteSupported), BandSet(rat: .nsa, allowed: [], supported: []),
                     BandSet(rat: .sa, allowed: [78], supported: nrSupported)])
        expectLines(run(["bands", "reset"], fake, "bands reset, nsa none supported"),
                    [warning("LTE", lteWords, was: "3"), "LTE bands set to \(lteWords)",
                     "bands: At least one 5G NSA band is needed. The 5G NSA bands were not changed.", notReset("5G NSA, 5G SA")],
                    code: 1, "bands reset: LTE set, NSA with no supported band")
        fake = with(bandSets(lte: [3], nsa: [41], sa: [78]))
        fake.setBandsResults[.nsa] = .failure(ModemFailure(message: "Fake: busy. The 5G NSA bands were not changed."))
        expectLines(run(["bands", "reset"], fake, "bands reset, nsa busy"),
                    [warning("LTE", lteWords, was: "3"), "LTE bands set to \(lteWords)", warning("5G NSA", nrWords, was: "41"),
                     "bands: Fake: busy. The 5G NSA bands were not changed.", notReset("5G NSA, 5G SA")], code: 1,
                    "bands reset: the service's sentence for NSA, then the RATs not reset")
        // One RAT reset, or a set, that fails: its line alone.
        fake = with(bandSets(sa: [41]))
        fake.setBandsResults[.sa] = .failure(refused)
        expectLines(run(["bands", "reset", "sa"], fake, "bands reset sa, fails"),
                    [warning("5G SA", nrWords, was: "41"), "bands: Fake: refused."], code: 1, "bands reset sa: a failure, one line")
        fake = FakeModem()
        fake.bandsResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["bands", "reset"], fake, "bands reset, read failed"),
                    ["bands: Fake: no modem. Nothing was changed."], code: 1, "bands reset: the read failed")
        check(fake.bandsAsked.isEmpty, "bands reset: the read failed, nothing set")

        // --- antennas, cell & imei ---------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["antennas"], fake, "antennas"), [
            "prx: RSRP -93 dBm, RSRQ -11 dB, SINR 20 dB",
            "drx: RSRP -110 dBm, RSRQ -16 dB, SINR 10 dB",
            "rx2: inactive",
            "rx3: inactive",
        ], code: 0, "antennas: prints 4 paths")

        fake = FakeModem()
        expectLines(run(["cell"], fake, "cell"), [
            "5g sa lock: unlocked",
            "lte lock: unlocked",
            "persist across restart: off (temporary until restart)",
        ], code: 0, "cell: unlocked")

        fake = FakeModem()
        expectLines(run(["cell", "lock", "current"], fake, "cell lock current"), [
            "cell: Locked 5G SA cell to band n41, PCI 32, ARFCN 504990, SCS 30 kHz.",
        ], code: 0, "cell lock current: locks SA leg")
        check(fake.nrLockSet == [NrCellLock(pci: 32, arfcn: 504990, scsKHz: 30, band: 41)],
              "cell lock current: passed right NR parameters")
        check(fake.cellsInUse == [.serving(scsKHz: nil)], "cell lock current: the serving cell, read with the lock")
        check(!fake.events.contains("networkInfo"), "cell lock current: no separate network read before the lock")

        // A serving 5G SA cell whose subcarrier spacing the modem does not give: refused, never guessed; `--scs` gives it.
        var noScs = saInfo
        noScs.serving = parseServingCell(
            ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",001,01,FEDCBA987,32,00F00D,504990,41,12,-95,-10,8,-,-"])
        fake = FakeModem()
        fake.networkResult = .success(noScs)
        expectLines(run(["cell", "lock", "current"], fake, "cell lock current, no SCS"), [
            "cell: The modem does not report the subcarrier spacing of its serving 5G SA cell (n41, PCI 32, ARFCN 504990); "
                + "give it with --scs (15, 30, 60, 120 or 240 kHz). Nothing was changed.",
        ], code: 1, "cell lock current: no SCS, refused")
        check(fake.nrLockSet.isEmpty, "cell lock current: no SCS, nothing locked")
        fake = FakeModem()
        fake.networkResult = .success(noScs)
        expectLines(run(["cell", "lock", "current", "--scs", "30"], fake, "cell lock current --scs"), [
            "cell: Locked 5G SA cell to band n41, PCI 32, ARFCN 504990, SCS 30 kHz.",
        ], code: 0, "cell lock current --scs: locks with the SCS given")
        fake = FakeModem()
        expectLines(run(["cell", "lock", "current", "--scs", "15"], fake, "cell lock current --scs differs"), [
            "cell: The modem reports a subcarrier spacing of 30 kHz for its serving 5G SA cell, not 15 kHz. Nothing was changed.",
        ], code: 1, "cell lock current --scs: one the modem contradicts is refused")
        check(fake.nrLockSet.isEmpty, "cell lock current --scs differs: nothing locked")

        fake = FakeModem()
        expectLines(run(["cell", "lock", "sa", "147", "520110", "30", "n41"], fake, "cell lock sa"), [
            "cell: Locked 5G SA cell to band n41, PCI 147, ARFCN 520110, SCS 30 kHz.",
        ], code: 0, "cell lock sa")

        fake = FakeModem()
        fake.cellLockResult = .success(CellLockState(lte: [],
                                                     nr: NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41),
                                                     persistLte: false, persistNr: false))
        expectLines(run(["cell", "unlock"], fake, "cell unlock"), [
            "cell: Unlocked 5G SA cell lock.",
        ], code: 0, "cell unlock: unlocks active lock")

        fake = FakeModem()
        expectLines(run(["imei"], fake, "imei"), ["imei: 000000000000091"], code: 0, "imei")

        fake = FakeModem()
        let badImeiRun = run(["imei", "set", "000000000000142"], fake, "imei bad luhn")
        expectLines(badImeiRun, [
            "imei: The IMEI check digit is not valid (expected 1 as the 15th digit). Nothing was changed.",
        ], code: 1, "imei set: rejects invalid Luhn without opening modem")
        check(fake.events.filter { $0 != "output" }.isEmpty, "imei set: bad Luhn touched nothing")

        fake = FakeModem()
        expectLines(run(["imei", "set", "000000000000091"], fake, "imei unchanged"), [
            "imei: already 000000000000091; nothing changed",
        ], code: 0, "imei set: unchanged")

        fake = FakeModem()
        expectLines(run(["imei", "set", "000000000000141"], fake, answer: nil, "imei no tty"), [
            "imei: no terminal to ask on, so nothing changed; run again with --yes to change it without asking",
        ], code: 2, "imei set: refuses restart without terminal")
        check(!fake.events.contains("setImei"), "imei set: nothing written without an answer")

        fake = FakeModem()
        expectLines(run(["imei", "set", "000000000000141", "--yes"], fake, "imei --yes"), [
            "imei: IMEI set to 000000000000141; the modem is restarting.",
            "imei: to put it back: RMNet imei set 000000000000091",
        ], code: 0, "imei set --yes")
        equal(fake.imeiExpectAsked, [ImeiExpectation(module: "c0ffee01", before: "000000000000091")],
              "imei set: written only on the module and over the IMEI read first")

        // --no-reboot asks too (the write is a change), naming the module and both IMEIs.
        fake = FakeModem()
        expectLines(run(["imei", "set", "000000000000141", "--no-reboot"], fake, answer: nil, "imei no-reboot no tty"), [
            "imei: no terminal to ask on, so nothing changed; run again with --yes to change it without asking",
        ], code: 2, "imei set --no-reboot: asks, and without a terminal changes nothing")
        check(!fake.events.contains("setImei"), "imei set --no-reboot: nothing written unasked")
        fake = FakeModem()
        let asked = run(["imei", "set", "000000000000141", "--no-reboot"], fake, answer: "y", "imei no-reboot asked")
        equal(asked.code, 0, "imei set --no-reboot: answered yes, written")
        equal(asked.questions, ["The IMEI of module c0ffee01 will change from 000000000000091 to 000000000000141. "
                                + "It takes effect at the next restart. Continue? [y/N] "], "imei set --no-reboot: the question")
        equal(fake.imeiSetAsked.last?.reboot, false, "imei set --no-reboot: not restarted")

        // Another module on the port that writes (swapped after the question): nothing written, said, exit 1.
        fake = FakeModem()
        fake.sessionModule = "0badbeef"
        let swapped = run(["imei", "set", "000000000000141", "--yes"], fake, "imei swapped")
        check(swapped.code == 1 && swapped.lines.last?.hasPrefix("imei: The modem attached is not the module") == true,
              "imei set: another module when writing, nothing written", "\(swapped.lines)")
        // The IMEI changed meanwhile (another tool): nothing written, said.
        fake = FakeModem()
        fake.sessionBefore = "000000000000117"
        let moved = run(["imei", "set", "000000000000141", "--yes"], fake, "imei moved")
        check(moved.code == 1 && moved.lines.last?.contains("now, not 000000000000091") == true,
              "imei set: another IMEI when writing, nothing written", "\(moved.lines)")
        // A module that gives no serial number: not changed, not even asked.
        fake = FakeModem()
        fake.readingModule = nil
        expectLines(run(["imei", "set", "000000000000141", "--yes"], fake, "imei no module"), [
            "imei: The modem gives no USB serial number, so the change cannot be tied to this module. Nothing was changed.",
        ], code: 1, "imei set: no module, nothing changed")
        check(!fake.events.contains("setImei"), "imei set: no module, nothing written")

        // Written and read back, the restart refused: said, the way back, exit 1.
        fake = FakeModem()
        let sentence = "The IMEI is now 000000000000141, but the modem was not restarted. The modem refused the command "
            + "(ERROR). It takes effect at the next restart (AT+CFUN=1,1 or a replug)."
        fake.setImeiResult = .success(.restartFailed(before: "000000000000091", after: "000000000000141", sentence: sentence))
        expectLines(run(["imei", "set", "000000000000141", "--yes"], fake, "imei restart failed"), [
            "imei: \(sentence)",
            "imei: to put it back: RMNet imei set 000000000000091",
        ], code: 1, "imei set: written, the restart failed")

        imeiHistoryVerbs()
    }

    /// `imei set` records each change it sends in the IMEI history (with the IMEI before and the module as the change's
    /// own port open read them, not the registry's module or an earlier read; `cli`; the result), and nothing when it
    /// sends none; `imei history` prints the history, also as JSON, and never asks the modem anything.
    static func imeiHistoryVerbs() {
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        let keeper = MemoryHistory()
        let recorder = ImeiHistoryRecorder(keeper: keeper, module: { "f00dcafe" }, now: { when })

        var fake = FakeModem()
        _ = run(["imei", "set", "000000000000141", "--yes"], fake, history: recorder, "history: set")
        equal(keeper.entries.count, 1, "history: one entry after a change")
        equal(keeper.entries.first, ImeiHistoryEntry(time: when, before: "000000000000091", after: "000000000000141",
                                                     source: .cli, result: .succeeded, restart: true,
                                                     restartResult: .succeeded, module: "c0ffee01",
                                                     message: "IMEI set to 000000000000141; the modem is restarting.",
                                                     note: nil), "history: the entry")

        // The IMEI before and the module as the change's port read them (another tool changed the IMEI after the verb's
        // first read): nothing written, recorded as failed with what that port read.
        fake = FakeModem()
        fake.sessionBefore = "000000000000117"
        _ = run(["imei", "set", "000000000000141", "--yes"], fake, history: recorder, "history: the session's")
        equal(keeper.entries.last?.before, "000000000000117", "history: the IMEI before from the change's port")
        equal(keeper.entries.last?.module, "c0ffee01", "history: the module from the change's port")
        equal(keeper.entries.last?.result, .failed, "history: not written over another IMEI")
        keeper.entries.removeLast()
        // Written, the restart refused: recorded as written, its restart failed.
        fake = FakeModem()
        fake.setImeiResult = .success(.restartFailed(before: "000000000000091", after: "000000000000141",
                                                     sentence: "Made-up sentence."))
        _ = run(["imei", "set", "000000000000141", "--yes"], fake, history: recorder, "history: restart failed")
        check(keeper.entries.last?.result == .succeeded && keeper.entries.last?.restartResult == .failed,
              "history: written, its restart failed, recorded apart")
        keeper.entries.removeLast()

        fake = FakeModem()
        _ = run(["imei", "set", "000000000000091"], fake, history: recorder, "history: unchanged")
        fake = FakeModem()
        _ = run(["imei", "set", "000000000000141"], fake, answer: "n", history: recorder, "history: cancelled")
        fake = FakeModem()
        _ = run(["imei", "set", "000000000000142", "--yes"], fake, history: recorder, "history: bad check digit")
        equal(keeper.entries.count, 1, "history: nothing recorded when nothing was sent")

        fake = FakeModem()
        fake.setImeiResult = .failure(ModemFailure(message: "The IMEI was not changed. ERROR"))
        let failed = run(["imei", "set", "000000000000141", "--no-reboot", "--yes"], fake, history: recorder, "history: failed")
        equal(failed.code, 1, "history: a failure still exits 1")
        equal(keeper.entries.last?.result, .failed, "history: a failure recorded as failed")
        equal(keeper.entries.last?.restart, false, "history: --no-reboot recorded")
        equal(keeper.entries.last?.message, "The IMEI was not changed. ERROR", "history: the failure's sentence")

        // A history that cannot be written adds a line; the change's own result and exit code stand.
        keeper.refuse = "The IMEI history could not be written (/x)."
        fake = FakeModem()
        expectLines(run(["imei", "set", "000000000000141", "--yes"], fake, history: recorder, "history: not written"), [
            "imei: the change was not recorded in the IMEI history. The IMEI history could not be written (/x).",
            "imei: IMEI set to 000000000000141; the modem is restarting.",
            "imei: to put it back: RMNet imei set 000000000000091",
        ], code: 0, "history: not written")
        keeper.refuse = nil

        fake = FakeModem()
        let shown = run(["imei", "history"], fake, history: recorder, "history: show")
        equal(shown.code, 0, "history: show exits 0")
        equal(shown.lines.first, "imei: 2 IMEI changes recorded on this Mac, newest first", "history: headline")
        equal(shown.lines.last, "imei: kept in /memory/imei-history.jsonl", "history: location")
        check(fake.events.allSatisfy { $0 == "output" }, "history: the modem is not asked", "\(fake.events)")

        fake = FakeModem()
        let json = run(["imei", "history", "--json"], fake, history: recorder, "history: json")
        equal(json.code, 0, "history json: exits 0")
        let object = (try? JSONSerialization.jsonObject(with: Data(json.lines.joined(separator: "\n").utf8))) as? [String: Any]
        equal((object?["entries"] as? [Any])?.count, 2, "history json: entries")
        equal(object?["path"] as? String, "/memory/imei-history.jsonl", "history json: path")

        fake = FakeModem()
        expectLines(run(["imei", "history"], fake, "history: none kept"), ["imei: No IMEI history is kept here."], code: 1,
                    "history: no recorder")
        keeper.loadFailure = "The IMEI history could not be read (/x)."
        fake = FakeModem()
        expectLines(run(["imei", "history"], fake, history: recorder, "history: unreadable"),
                    ["imei: The IMEI history could not be read (/x)."], code: 1, "history: unreadable")
    }
}

/// `sim slot` and `sim slot set`, and the slot in `sim` and `sim --json` (a field added, none changed).
func simSlotVerbs() {
    var fake = FakeModem()
    var withSlot = readySim
    withSlot.activeSlot = 2
    fake.simResult = .success(withSlot)
    expectLines(run(["sim"], fake, "sim with slot"),
                ["sim: ready", "sim: pin lock: off", "sim: attempts left: PIN 3, PUK 10", "sim: slot: 2"], code: 0,
                "sim: the slot as its last line")
    let json = simJSON(withSlot)
    check(json["activeSlot"] as? Int == 2 && json["state"] as? String == "ready" && json["pinLock"] as? Bool == false
            && json["pinAttempts"] as? Int == 3 && json["pukAttempts"] as? Int == 10,
          "sim --json: activeSlot added, the other keys kept", "\(json)")
    check(simJSON(readySim)["activeSlot"] is NSNull, "sim --json: activeSlot null when not read")

    fake = FakeModem()
    fake.simSlotResult = .success(2)
    expectLines(run(["sim", "slot"], fake, "sim slot"), ["sim: slot 2"], code: 0, "sim slot")
    let shown = run(["sim", "slot", "--json"], fake, "sim slot --json")
    let object = (try? JSONSerialization.jsonObject(with: Data(shown.lines.joined(separator: "\n").utf8))) as? [String: Any]
    check(shown.code == 0 && object?["activeSlot"] as? Int == 2, "sim slot --json", "\(shown.lines)")
    fake.simSlotResult = .failure(ModemFailure(message: "The modem does not switch SIM slots. ERROR"))
    expectLines(run(["sim", "slot"], fake, "sim slot refused"), ["sim: The modem does not switch SIM slots. ERROR"],
                code: 1, "sim slot: refused")

    // Already there: nothing asked or sent.
    fake = FakeModem()
    expectLines(run(["sim", "slot", "set", "1"], fake, "slot already"), ["sim: already on SIM 1; nothing changed"],
                code: 0, "sim slot set: already")
    check(fake.simSlotsAsked.isEmpty && !fake.events.contains("ask"), "sim slot set: already, nothing sent or asked")

    // No terminal, or a no: nothing changed.
    fake = FakeModem()
    let noTerminal = run(["sim", "slot", "set", "2"], fake, answer: nil, "slot no terminal")
    expectLines(noTerminal, ["sim: no terminal to ask on, so nothing changed; run again with --yes to switch without asking"],
                code: 2, "sim slot set: no terminal")
    check(fake.simSlotsAsked.isEmpty, "sim slot set: no terminal, nothing sent")
    fake = FakeModem()
    expectLines(run(["sim", "slot", "set", "2"], fake, answer: "n", "slot cancelled"), ["cancelled; nothing changed"],
                code: 1, "sim slot set: cancelled")
    check(fake.simSlotsAsked.isEmpty, "sim slot set: cancelled, nothing sent")

    // Asked, then switched: the question says the connection drops; the result waits for the registration.
    fake = FakeModem()
    let asked = run(["sim", "slot", "set", "2"], fake, answer: "y", "slot asked")
    check(asked.questions.count == 1 && asked.questions[0].contains("The connection drops")
            && asked.questions[0].hasSuffix("Switch to SIM 2? [y/N] "), "sim slot set: the question", "\(asked.questions)")
    expectLines(asked, ["sim: Switched to SIM 2. SIM ready; registered, home network (5GS) after 5 s.",
                        "sim: to switch back: RMNet sim slot set 1"], code: 0, "sim slot set: switched")
    check(fake.simSlotsAsked.count == 1 && fake.simSlotsAsked[0].slot == 2 && fake.simSlotsAsked[0].wait == .registration,
          "sim slot set: waits for the registration")

    // --yes; a new slot with no SIM is still a switch made.
    fake = FakeModem()
    fake.setSimSlotResult = .success(SimSlotChange(before: 1, after: 2, sim: .notInserted))
    expectLines(run(["sim", "slot", "set", "2", "--yes"], fake, "slot empty"),
                ["sim: Switched to SIM 2, but it has no usable SIM (not inserted).", "sim: to switch back: RMNet sim slot set 1"],
                code: 0, "sim slot set: an empty slot")
    check(!fake.events.contains("ask"), "sim slot set --yes: not asked")

    fake = FakeModem()
    fake.setSimSlotResult = .failure(ModemFailure(message: "The SIM slot was not changed. ERROR"))
    expectLines(run(["sim", "slot", "set", "2", "--yes"], fake, "slot refused"),
                ["sim: The SIM slot was not changed. ERROR"], code: 1, "sim slot set: refused")

    // The sentences.
    check(simSlotSentence(SimSlotChange(before: 2, after: 2)) == "Already on SIM 2; nothing changed.", "sentence: same")
    check(simSlotSentence(SimSlotChange(before: 1, after: 2, sim: .ready, secondsToSim: 2))
            == "Switched to SIM 2. SIM ready.", "sentence: ready, no registration waited for")
    check(simSlotSentence(SimSlotChange(before: 1, after: 2, sim: .ready, registration: Registration(status: .searching, domain: "5GS")))
            == "Switched to SIM 2. SIM ready; searching (not registered yet).", "sentence: not registered yet",
          simSlotSentence(SimSlotChange(before: 1, after: 2, sim: .ready, registration: Registration(status: .searching, domain: "5GS"))))
    check(simSlotSentence(SimSlotChange(before: 1, after: 2, sim: .pin)) == "Switched to SIM 2. SIM: asks for its PIN.",
          "sentence: PIN")
    check(simSlotSentence(SimSlotChange(before: 1, after: 2, sim: .failure))
            == "Switched to SIM 2, but it has no usable SIM (SIM failure).", "sentence: failure")
    check(simSlotSentence(SimSlotChange(before: 1, after: 2)) == "Switched to SIM 2; its SIM state could not be read.",
          "sentence: not read")
}

/// An IMEI history in memory.
final class MemoryHistory: ImeiHistoryKeeping {
    var entries: [ImeiHistoryEntry] = []
    var refuse: String? = nil
    var loadFailure: String? = nil
    var location: String { "/memory/imei-history.jsonl" }

    func load() -> Result<ImeiHistory, ModemFailure> {
        if let loadFailure { return .failure(ModemFailure(message: loadFailure)) }
        return .success(ImeiHistory(entries: entries, skippedLines: 0))
    }

    func append(_ entry: ImeiHistoryEntry) -> String? {
        if let refuse { return refuse }
        entries.append(entry)
        return nil
    }
}
