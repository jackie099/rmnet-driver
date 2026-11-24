// Tests for app/ModemService.swift: the AT sequences of the modem service (the network read, the radio, the
// network mode, the USB network mode, the LTE and 5G bands, one command as typed for `RMNet at`, the data
// profiles with the redial,
// the SIM and PIN entry), run against
// a scripted port that answers from a queue and records every line sent, an opener that counts the ports it
// hands out, and a fake clock that `sleep` moves on. The fixtures are the modem's real answers (2026-11-15,
// firmware RM520NGLAAR03A04M4G_01.204.01.204); the AT+QCFG="usbnet" answers are in the form Quectel's AT
// manual gives, not read from the modem. Built with swiftc by `make app-test` together with app/AtPort.swift,
// app/SmsModel.swift, app/SmsService.swift (for `describe`), app/ModemNetwork.swift and
// app/ModemSettings.swift; opens no port and needs no hardware.
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

func expectEqual(_ got: String, _ want: String, _ name: String) {
    check(got == want, name, "want \"\(want)\"\n  got  \"\(got)\"")
}

// MARK: - The scripted port

typealias Answer = Result<[String], AtError>

let ok: Answer = .success([])
let timedOut: Answer = .failure(.timeout)
let ioError: Answer = .failure(.io(Int32(bitPattern: 0xE000_02ED)))    // kIOReturnNotResponding
let notOpen = AtError.io(Int32(bitPattern: 0xE000_02CD))               // kIOReturnNotOpen

func cme(_ n: Int) -> Answer { .failure(.modem("+CME ERROR: \(n)")) }

/// Answers each line from its script, in order, and records every line sent with its timeout. Like AtPort
/// after a timeout, it closes itself after a timeout or an I/O error: a line sent after that is refused
/// with `.io(kIOReturnNotOpen)` and noted as a problem, as is a line other than the one expected, or a
/// line when nothing more is expected.
final class ScriptedPort: AtCommanding {
    let name: String
    private var script: [(line: String, answer: Answer)]
    private(set) var sent: [(line: String, timeout: TimeInterval)] = []
    private(set) var problems: [String] = []
    private(set) var closed = false
    private(set) var closedItself = false
    var onCommand: (() -> Void)?      // the rig's clock: the time a command takes
    var deviceSerial: String? = nil   // the module the port is on (AtPort.deviceSerial)

    init(_ name: String, _ script: [(String, Answer)]) {
        self.name = name
        self.script = script.map { (line: $0.0, answer: $0.1) }
    }

    var lines: [String] { sent.map { $0.line } }
    var leftover: [String] { script.map { $0.line } }

    func timeout(of line: String) -> TimeInterval? { sent.first(where: { $0.line == line })?.timeout }

    func command(_ line: String, timeout: TimeInterval) -> Answer {
        sent.append((line: line, timeout: timeout))
        onCommand?()
        if closed || closedItself {
            problems.append("\(line) sent after the port closed")
            return .failure(notOpen)
        }
        guard !script.isEmpty else {
            problems.append("\(line) sent; nothing more was expected")
            closedItself = true
            return timedOut
        }
        let next = script.removeFirst()
        if next.line != line { problems.append("sent \(line), expected \(next.line)") }
        if case .failure(let error) = next.answer, error == .timeout || error == .io(Int32(bitPattern: 0xE000_02ED)) {
            closedItself = true
        }
        return next.answer
    }

    func close() { closed = true }
}

/// A port that answers `line` with raw bytes read by AtPort's own answer logic (AtAnswerCollector, the
/// port echoing), mapped as AtPort.command maps it; any other line is not answered.
final class CollectingPort: AtCommanding {
    private let line: String
    private let bytes: [UInt8]
    private(set) var sent: [String] = []
    private(set) var closed = false

    init(_ line: String, _ raw: String) {
        self.line = line
        self.bytes = Array(raw.utf8)
    }

    func command(_ line: String, timeout: TimeInterval) -> Answer {
        sent.append(line)
        guard line == self.line else { return timedOut }
        var collector = AtAnswerCollector(echo: line)
        switch collector.feed(bytes) {
        case .answer(let lines): return .success(lines)
        case .modemError(let errorLine): return .failure(.modem(errorLine))
        default: return timedOut
        }
    }

    func close() { closed = true }
}

/// A service with scripted ports for its opens (in order), a fake clock and the sleeps it asked for.
final class Rig {
    private var opens: [Result<ScriptedPort, AtError>]
    private(set) var opened: [ScriptedPort] = []
    private(set) var openCount = 0
    private(set) var extraOpens = 0
    private(set) var opensWhileOpen = 0     // ports asked for while an earlier one was not closed
    var clock = Date(timeIntervalSinceReferenceDate: 1000)
    let start: Date
    private(set) var sleeps: [TimeInterval] = []
    var commandSeconds: TimeInterval = 0     // fake time each command takes
    var sleepMovesClock = true               // false: a clock that stands still (or was set back)

    init(_ opens: [Result<ScriptedPort, AtError>]) {
        self.opens = opens
        start = clock
    }

    convenience init(_ scripts: [(String, Answer)]...) {
        self.init(scripts.enumerated().map { .success(ScriptedPort("port \($0.offset + 1)", $0.element)) })
    }

    lazy var service = ModemService(open: { [unowned self] in self.open() },
                                    sleep: { [unowned self] in
                                        self.sleeps.append($0)
                                        if self.sleepMovesClock { self.clock += $0 }
                                    },
                                    now: { [unowned self] in self.clock })

    var elapsed: TimeInterval { clock.timeIntervalSince(start) }

    private func open() -> Result<AtCommanding, AtError> {
        openCount += 1
        // AtPort keeps the interface after an I/O error: a second open while it is held would be busy.
        if opened.contains(where: { !$0.closed }) { opensWhileOpen += 1 }
        guard !opens.isEmpty else {
            extraOpens += 1
            return .failure(.modemNotAttached)
        }
        switch opens.removeFirst() {
        case .success(let port):
            opened.append(port)
            port.onCommand = { [unowned self] in self.clock += self.commandSeconds }
            return .success(port)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The port opened n-th (from 1), or an empty one when it was not opened (the checks then fail).
    func port(_ n: Int) -> ScriptedPort {
        n >= 1 && n <= opened.count ? opened[n - 1] : ScriptedPort("port \(n) (not opened)", [])
    }

    /// Every line sent, over all ports.
    var allLines: [String] { opened.flatMap { $0.lines } }

    /// `opens` ports were asked for, each one opened was closed, every script was used up, and nothing was
    /// sent out of order or on a closed port.
    func finish(_ name: String, opens want: Int) {
        check(openCount == want && extraOpens == 0, "\(name): \(want) port(s) asked for", "asked for \(openCount)")
        check(opens.isEmpty, "\(name): every scripted open happened", "\(opens.count) left")
        check(opensWhileOpen == 0, "\(name): each port was closed before the next was opened")
        for p in opened {
            check(p.closed, "\(name): \(p.name) was closed")
            check(p.problems.isEmpty, "\(name): \(p.name) got its lines in order", p.problems.joined(separator: "; "))
            check(p.leftover.isEmpty, "\(name): \(p.name) was sent every line scripted", "not sent: \(p.leftover)")
        }
    }
}

func linesText(_ lines: [String]) -> String {
    lines.joined(separator: " | ")
}

func expectLines(_ got: [String], _ want: [String], _ name: String) {
    check(got == want, name, "want \(linesText(want))\n  got  \(linesText(got))")
}

func success<T>(_ result: Result<T, ModemFailure>, _ name: String) -> T? {
    switch result {
    case .success(let value):
        return value
    case .failure(let failure):
        check(false, "\(name): succeeds", failure.message)
        return nil
    }
}

func failureMessage<T>(_ result: Result<T, ModemFailure>, _ name: String) -> String {
    failureOf(result, name).message
}

func failureOf<T>(_ result: Result<T, ModemFailure>, _ name: String) -> ModemFailure {
    switch result {
    case .success(let value):
        check(false, "\(name): fails", "succeeded with \(value)")
        return ModemFailure(message: "")
    case .failure(let failure):
        return failure
    }
}

// MARK: - The modem's answers

let cfunOn: Answer = .success(["+CFUN: 1"])
let cfunOff: Answer = .success(["+CFUN: 4"])
let qspn = "+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""
let sa = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"
let qcainfo = ["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32",
               "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]

let networkLines = ["AT+CFUN?", "AT+COPS?", "AT+QSPN", "AT+C5GREG?", "AT+CEREG?", "AT+CGREG?", "AT+CREG?",
                    "AT+QENG=\"servingcell\"", "AT+QCAINFO", "AT+QNWPREFCFG=\"mode_pref\"",
                    "AT+QNWPREFCFG=\"nr5g_disable_mode\""]

func networkScript(qcainfo qca: Answer = .success(qcainfo)) -> [(String, Answer)] {
    [("AT+CFUN?", cfunOn),
     ("AT+COPS?", .success(["+COPS: 0,0,\"CHINA MOBILE\",11"])),
     ("AT+QSPN", .success([qspn])),
     ("AT+C5GREG?", .success(["+C5GREG: 0,1"])),
     ("AT+CEREG?", .success(["+CEREG: 0,0"])),
     ("AT+CGREG?", .success(["+CGREG: 0,0"])),
     ("AT+CREG?", .success(["+CREG: 0,0"])),
     ("AT+QENG=\"servingcell\"", .success([sa])),
     ("AT+QCAINFO", qca),
     ("AT+QNWPREFCFG=\"mode_pref\"", .success(["+QNWPREFCFG: \"mode_pref\",AUTO"])),
     ("AT+QNWPREFCFG=\"nr5g_disable_mode\"", .success(["+QNWPREFCFG: \"nr5g_disable_mode\",0"]))]
}

let saLeg = CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: 32,
                    tac: "1A2B3C", channel: 504990, band: "n41", bandwidthMHz: 100, rsrp: -95, rsrq: -10, sinr: 8,
                    scsKHz: 30)
let homeSA = Registration(status: .home, domain: "5GS")
let searchingSA = Registration(status: .searching, domain: "5GS")

let saInfo: NetworkInfo = {
    var info = NetworkInfo()
    info.radio = .on
    info.registration = homeSA
    info.operatorName = "CHINA MOBILE"
    info.networkName = "\u{4E2D}\u{56FD}\u{79FB}\u{52A8}"
    info.plmn = "46000"
    info.accessTechnology = 11
    info.serving = ServingCell(state: "NOCONN", cells: [saLeg])
    info.carriers = ["n41", "n28"]
    info.carrierComponents = parseCarrierComponents(qcainfo)
    info.mode = "AUTO"
    info.nr5gDisable = 0
    return info
}()

/// The four registration reads, 5GS with `fiveG`, the others not registered.
func registrationReads(_ fiveG: Int) -> [(String, Answer)] {
    [("AT+C5GREG?", .success(["+C5GREG: 0,\(fiveG)"])), ("AT+CEREG?", .success(["+CEREG: 0,0"])),
     ("AT+CGREG?", .success(["+CGREG: 0,0"])), ("AT+CREG?", .success(["+CREG: 0,0"]))]
}

let registered = registrationReads(1)
let searching = registrationReads(2)
let registrationLines = ["AT+C5GREG?", "AT+CEREG?", "AT+CGREG?", "AT+CREG?"]

let cgdcont = [
    "+CGDCONT: 1,\"IPV4V6\",\"\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 3,\"IPV4V6\",\"CMNET\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 4,\"IPV4V6\",\"CMWAP\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 5,\"IPV4V6\",\"SOS\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,1,,,,,,,,,,\"\",,,,0",
]
let profile1 = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
let profile3 = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "", password: "", auth: .none)
let cmnet = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
let qicsgp1: Answer = .success(["+QICSGP: 3,\"\",\"\",\"\",0"])
let qicsgpCmnet: Answer = .success(["+QICSGP: 3,\"cmnet\",\"\",\"\",0"])
let setCmnet = "AT+QICSGP=1,3,\"cmnet\",\"\",\"\",0"

// A password that no failure sentence and no line other than the change may hold.
let secret = "hunter2-secret"
let withSecret = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "u", password: secret, auth: .pap)
let setWithSecret = "AT+QICSGP=1,3,\"cmnet\",\"u\",\"hunter2-secret\",1"
let qicsgpWithSecret: Answer = .success(["+QICSGP: 3,\"cmnet\",\"u\",\"hunter2-secret\",1"])

let cpinReady: Answer = .success(["+CPIN: READY"])
let cpinPin: Answer = .success(["+CPIN: SIM PIN"])
func qpinc(_ pin: Int, _ puk: Int = 10) -> Answer { .success(["+QPINC: \"SC\",\(pin),\(puk)", "+QPINC: \"P2\",3,10"]) }
let clckOff: Answer = .success(["+CLCK: 0"])
let clckOn: Answer = .success(["+CLCK: 1"])
let simLines = ["AT+CPIN?", "AT+QPINC?", "AT+CLCK=\"SC\",2", "AT+QUIMSLOT?"]
let slot1: Answer = .success(["+QUIMSLOT: 1"])

// A PIN that no failure sentence and no line other than AT+CPIN="…" may hold.
let pin = "73519"
let pinLine = "AT+CPIN=\"73519\""

// The bands, as the modem answered on 2026-11-15. AT+QNWPREFCFG="rf_band" lists the bands the modem's hardware
// supports, each list in quotes, nr5g_band before nsa_nr5g_band and no nrdc line (the gw_band line is not
// used); a lock does not change it. Each RAT's own setting (unquoted) allowed every supported band.
// AT+QNWPREFCFG="ue_capability_band" is not used: it follows a lock (after nr5g_band was set to 41 it gave
// `"nr5g_band",41`), so BandModem below answers it that way, to show that RMNet never relies on it.
let lteList = "1:2:3:4:5:7:8:12:13:14:17:18:19:20:25:26:28:29:30:32:34:38:39:40:41:42:43:46:48:66:71"
let nrList = "1:2:3:5:7:8:12:13:14:18:20:25:26:28:29:30:38:40:41:48:66:70:71:75:76:77:78:79"
let lteSupported = [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43,
                    46, 48, 66, 71]
let nrSupported = [1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 66, 70, 71, 75, 76, 77, 78, 79]
let nrWords = "1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 66, 70, 71, 75, 76, 77, 78, 79"
let rfBandLines = [
    "+QNWPREFCFG: \"gw_band\",\"1:2:4:5:8:19\"",
    "+QNWPREFCFG: \"lte_band\",\"\(lteList)\"",
    "+QNWPREFCFG: \"nr5g_band\",\"\(nrList)\"",
    "+QNWPREFCFG: \"nsa_nr5g_band\",\"\(nrList)\"",
]
let supportRead = "AT+QNWPREFCFG=\"rf_band\""
func bandRead(_ key: String) -> String { "AT+QNWPREFCFG=\"\(key)\"" }
func bandAnswer(_ key: String, _ list: String) -> Answer { .success(["+QNWPREFCFG: \"\(key)\",\(list)"]) }

/// The modem's band settings as it behaved on 2026-11-15: each RAT's setting holds the bands it may use (read
/// unquoted, `0` for none; a write replaces it); `rf_band` gives the hardware's bands whatever the settings
/// (rfBandLines); `ue_capability_band` gives the settings themselves, so it follows a lock. Any other line is
/// answered ERROR. Every line sent, over all ports, is in `sent`.
final class BandModem {
    var allowed: [String: [Int]] = ["lte_band": lteSupported, "nsa_nr5g_band": nrSupported, "nr5g_band": nrSupported]
    private(set) var sent: [String] = []

    private func list(_ key: String) -> String {
        let bands = allowed[key] ?? []
        return bands.isEmpty ? "0" : bands.map { String($0) }.joined(separator: ":")
    }

    func answer(_ line: String) -> Answer {
        sent.append(line)
        let error: Answer = .failure(.modem("ERROR"))
        let head = "AT+QNWPREFCFG=\""
        guard line.hasPrefix(head), let close = line.dropFirst(head.count).firstIndex(of: "\"") else { return error }
        let key = String(line[line.index(line.startIndex, offsetBy: head.count)..<close])
        let rest = line[line.index(after: close)...]
        switch key {
        case "rf_band" where rest.isEmpty:
            return .success(rfBandLines)
        case "ue_capability_band" where rest.isEmpty:
            return .success(["+QNWPREFCFG: \"gw_band\",1:2:4:5:8:19", "+QNWPREFCFG: \"lte_band\",\(list("lte_band"))",
                             "+QNWPREFCFG: \"nsa_nr5g_band\",\(list("nsa_nr5g_band"))",
                             "+QNWPREFCFG: \"nr5g_band\",\(list("nr5g_band"))", "+QNWPREFCFG: \"nrdc_nr5g_band\",0"])
        case _ where allowed[key] != nil && rest.isEmpty:
            return .success(["+QNWPREFCFG: \"\(key)\",\(list(key))"])
        case _ where allowed[key] != nil && rest.hasPrefix(","):
            let bands = rest.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard !bands.isEmpty, bands.allSatisfy({ $0 != nil }) else { return error }
            allowed[key] = bands.compactMap { $0 }
            return ok
        default:
            return error
        }
    }
}

/// A port on a BandModem: every open gives a new one on the same modem.
final class BandModemPort: AtCommanding {
    private let modem: BandModem
    init(_ modem: BandModem) { self.modem = modem }
    func command(_ line: String, timeout: TimeInterval) -> Answer { modem.answer(line) }
    func close() {}
}

/// The redial's lines before the change: the settings now, the radio's state, the radio off.
let redialStart: [(String, Answer)] = [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", ok)]

@main
struct ModemServiceTests {
    static func main() {
        conformance()
        networkInfo()
        radio()
        mode()
        usbMode()
        bandsAfterLock()
        bandsRead()
        bandsChange()
        atCommand()
        profiles()
        profileChange()
        profileRedialFailures()
        profileWayBack()
        sim()
        pinEntry()
        antennas()
        simSlotChanges()
        cellLock()
        imei()
        print("modem service: \(checks) checks passed")
    }

    // AtPort is a port the service can use, and the default service and readSecret have the planned shapes.
    // Nothing here opens a port: the service opens one only when a method is called.
    static func conformance() {
        let asPort: (AtPort) -> AtCommanding = { $0 }
        _ = asPort
        let service: ModemServing = ModemService()
        _ = service
        let reader: (String) -> String? = readSecret(prompt:)
        _ = reader
        check(true, "conformance: AtPort is AtCommanding; ModemService() and readSecret(prompt:) compile")
    }

    // MARK: networkInfo

    static func networkInfo() {
        do {
            let rig = Rig(networkScript())
            let info = success(rig.service.networkInfo(), "networkInfo")
            check(info == saInfo, "networkInfo: the fixtures give the SA NetworkInfo", "\(String(describing: info))")
            expectLines(rig.port(1).lines, networkLines, "networkInfo: the eleven reads in order")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "networkInfo: each read has 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            check(rig.sleeps.isEmpty, "networkInfo: no sleep")
            rig.finish("networkInfo", opens: 1)
        }
        do {
            let rig = Rig(networkScript(qcainfo: cme(3)))
            let info = success(rig.service.networkInfo(), "networkInfo, QCAINFO refused")
            var want = saInfo
            want.carriers = []
            want.carrierComponents = []
            check(info == want, "networkInfo: +CME ERROR: 3 for AT+QCAINFO leaves carriers [] and reads on",
                  "\(String(describing: info))")
            expectLines(rig.port(1).lines, networkLines, "networkInfo, QCAINFO refused: all eleven reads")
            rig.finish("networkInfo, QCAINFO refused", opens: 1)
        }
        do {
            // Every read refused: an empty NetworkInfo, not a failure.
            let rig = Rig(networkLines.map { ($0, cme(3)) })
            let info = success(rig.service.networkInfo(), "networkInfo, all refused")
            check(info == NetworkInfo(), "networkInfo: every read refused gives an empty NetworkInfo", "\(String(describing: info))")
            rig.finish("networkInfo, all refused", opens: 1)
        }
        do {
            // AT+QSPN answering a bare OK (not registered): no network name and no PLMN; nothing invented.
            var script = networkScript()
            script[2] = ("AT+QSPN", ok)
            let rig = Rig(script)
            let info = success(rig.service.networkInfo(), "networkInfo, bare QSPN")
            check(info?.networkName == nil && info?.plmn == nil, "networkInfo: a bare OK to AT+QSPN gives no name and no plmn (R1)",
                  "\(String(describing: info))")
            rig.finish("networkInfo, bare QSPN", opens: 1)
        }
        for (answer, word) in [(timedOut, "a timeout"), (ioError, "an I/O error")] {
            var script = Array(networkScript().prefix(2))
            script[1] = ("AT+COPS?", answer)
            let rig = Rig(script)
            let message = failureMessage(rig.service.networkInfo(), "networkInfo, \(word) on COPS")
            guard case .failure(let error) = answer else { continue }
            expectEqual(message, describe(error), "networkInfo: \(word) on AT+COPS? fails with describe(error)")
            expectLines(rig.port(1).lines, ["AT+CFUN?", "AT+COPS?"], "networkInfo: nothing is sent after \(word)")
            rig.finish("networkInfo, \(word) on COPS", opens: 1)
        }
        do {
            let rig = Rig([.failure(.modemNotAttached)])
            let message = failureMessage(rig.service.networkInfo(), "networkInfo, no modem")
            expectEqual(message, describe(.modemNotAttached), "networkInfo: a failed open fails with describe(error)")
            rig.finish("networkInfo, no modem", opens: 1)
        }
    }

    // MARK: setRadio

    static func radio() {
        do {
            let rig = Rig([("AT+CFUN=1", ok)] + searching + searching + registered)
            let change = success(rig.service.setRadio(on: true), "radio on")
            check(change == RadioChange(on: true, registration: homeSA, secondsToRegister: 2),
                  "setRadio(on: true): registered on the third read gives secondsToRegister 2", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+CFUN=1"] + registrationLines + registrationLines + registrationLines,
                        "setRadio(on: true): AT+CFUN=1, then the four registration reads until registered")
            check(rig.port(1).timeout(of: "AT+CFUN=1") == 20, "setRadio: AT+CFUN=1 has 20 s")
            check(rig.port(1).sent.dropFirst().allSatisfy { $0.timeout == 3 }, "setRadio: the registration reads have 3 s")
            check(rig.sleeps == [1, 1], "setRadio(on: true): one second between reads", "\(rig.sleeps)")
            rig.finish("radio on", opens: 1)
        }
        do {
            // Registered at once: 0 s.
            let rig = Rig([("AT+CFUN=1", ok)] + registered)
            let change = success(rig.service.setRadio(on: true), "radio on, registered at once")
            check(change == RadioChange(on: true, registration: homeSA, secondsToRegister: 0),
                  "setRadio(on: true): registered on the first read gives 0 s", "\(String(describing: change))")
            check(rig.sleeps.isEmpty, "setRadio(on: true): no sleep when registered at once", "\(rig.sleeps)")
            rig.finish("radio on, registered at once", opens: 1)
        }
        do {
            // Roaming counts as registered.
            let rig = Rig([("AT+CFUN=1", ok)] + searching + registrationReads(5))
            let change = success(rig.service.setRadio(on: true), "radio on, roaming")
            check(change == RadioChange(on: true, registration: Registration(status: .roaming, domain: "5GS"), secondsToRegister: 1),
                  "setRadio(on: true): roaming is registered", "\(String(describing: change))")
            rig.finish("radio on, roaming", opens: 1)
        }
        do {
            // Never registered: reads at 0, 1, …, 30 s of fake time, then stops.
            let reads = Array(repeating: searching, count: 31).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            let change = success(rig.service.setRadio(on: true), "radio on, never registered")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): never registered gives the last registration and no seconds", "\(String(describing: change))")
            check(rig.elapsed == 30, "setRadio(on: true): stops after 30 s of fake time", "\(rig.elapsed)")
            check(rig.sleeps.count == 30 && rig.sleeps.allSatisfy { $0 == 1 }, "setRadio(on: true): 30 sleeps of 1 s",
                  "\(rig.sleeps)")
            check(rig.port(1).lines.count == 1 + 31 * 4, "setRadio(on: true): 31 reads of four lines",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, never registered", opens: 1)
        }
        do {
            // Reads that take time: the 30 s are counted by the clock, not by the reads. Each command takes
            // 0.5 s, so a read of four takes 2 s and a round 3 s: reads end at 2, 5, …, 32 s after AT+CFUN=1.
            let reads = Array(repeating: searching, count: 11).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.commandSeconds = 0.5
            let change = success(rig.service.setRadio(on: true), "radio on, slow reads")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): slow reads, never registered", "\(String(describing: change))")
            check(rig.port(1).lines.count == 1 + 11 * 4, "setRadio(on: true): slow reads stop once 30 s have passed (11 reads)",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, slow reads", opens: 1)
        }
        do {
            // A read that ends exactly 30 s after AT+CFUN=1 answered is the last: each command takes 1.6875 s,
            // so reads (6.75 s) end at 6.75, 14.5, 22.25 and 30 s.
            let reads = Array(repeating: searching, count: 4).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.commandSeconds = 1.6875
            _ = success(rig.service.setRadio(on: true), "radio on, a read ends at 30 s")
            check(rig.port(1).lines.count == 1 + 4 * 4, "setRadio(on: true): a read ending at exactly 30 s is the last",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, a read ends at 30 s", opens: 1)
        }
        do {
            // Registered on a slow read: the whole seconds from the AT+CFUN=1 answer, not from its sending. Each
            // command takes 0.9375 s: AT+CFUN=1 answers at 0.9375 s; the second read ends 8.5 s later (9.4375 s
            // after the line was sent).
            let rig = Rig([("AT+CFUN=1", ok)] + searching + registered)
            rig.commandSeconds = 0.9375
            let change = success(rig.service.setRadio(on: true), "radio on, slow, registered")
            check(change?.secondsToRegister == 8, "setRadio(on: true): seconds from the AT+CFUN=1 answer to the registered read",
                  "\(String(describing: change))")
            rig.finish("radio on, slow, registered", opens: 1)
        }
        do {
            // A clock that stands still (or was set back) cannot keep the wait going: at most 31 reads.
            let reads = Array(repeating: searching, count: 31).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.sleepMovesClock = false
            let change = success(rig.service.setRadio(on: true), "radio on, clock stands still")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): a clock that stands still", "\(String(describing: change))")
            check(rig.port(1).lines.count == 1 + 31 * 4, "setRadio(on: true): a clock that stands still stops after 31 reads",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, clock stands still", opens: 1)
        }
        do {
            // A read that times out ends the wait: the radio is on all the same.
            let rig = Rig([("AT+CFUN=1", ok)] + searching + [("AT+C5GREG?", .success(["+C5GREG: 0,2"])), ("AT+CEREG?", timedOut)])
            let change = success(rig.service.setRadio(on: true), "radio on, read times out")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): a timed-out read ends the wait with the last full read", "\(String(describing: change))")
            rig.finish("radio on, read times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=4", ok)])
            let change = success(rig.service.setRadio(on: false), "radio off")
            check(change == RadioChange(on: false, registration: nil, secondsToRegister: nil),
                  "setRadio(on: false): no registration and no seconds", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+CFUN=4"], "setRadio(on: false): only AT+CFUN=4")
            check(rig.port(1).timeout(of: "AT+CFUN=4") == 20, "setRadio: AT+CFUN=4 has 20 s")
            check(rig.sleeps.isEmpty, "setRadio(on: false): no sleep")
            rig.finish("radio off", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=1", cme(3))])
            let message = failureMessage(rig.service.setRadio(on: true), "radio on refused")
            expectEqual(message, "The radio could not be switched on. The modem refused the command (+CME ERROR: 3).",
                        "setRadio: a refusal says so")
            rig.finish("radio on refused", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=4", timedOut)])
            let message = failureMessage(rig.service.setRadio(on: false), "radio off times out")
            expectEqual(message, "It is not known whether the radio was switched off. The modem did not answer in time.",
                        "setRadio: a timeout says it is not known")
            rig.finish("radio off times out", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setRadio(on: false), "radio off, busy")
            expectEqual(message, "\(describe(.busy)) The radio was not switched off.", "setRadio: a failed open changes nothing")
            rig.finish("radio off, busy", opens: 1)
        }
    }

    // MARK: setMode

    static func mode() {
        let read = "AT+QNWPREFCFG=\"mode_pref\""
        func pref(_ value: String) -> Answer { .success(["+QNWPREFCFG: \"mode_pref\",\(value)"]) }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, pref("LTE"))])
            let change = success(rig.service.setMode("LTE"), "mode LTE")
            check(change == ModeChange(before: "AUTO", after: "LTE"), "setMode(\"LTE\"): AUTO to LTE", "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read, "AT+QNWPREFCFG=\"mode_pref\",LTE", read], "setMode: read, write, read")
            check(rig.port(1).sent.map { $0.timeout } == [3, 5, 3], "setMode: the write has 5 s, the reads 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            rig.finish("mode LTE", opens: 1)
        }
        do {
            // Lower case is sent upper case; the caller's own order is kept (ruling R8).
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",NR5G:LTE", ok), (read, pref("NR5G:LTE"))])
            let change = success(rig.service.setMode("nr5g:lte"), "mode nr5g:lte")
            check(change == ModeChange(before: "AUTO", after: "NR5G:LTE"),
                  "setMode(\"nr5g:lte\"): sends NR5G:LTE in its own order (R8)", "\(String(describing: change))")
            rig.finish("mode nr5g:lte", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("NR5G:LTE")), ("AT+QNWPREFCFG=\"mode_pref\",AUTO", ok), (read, pref("AUTO"))])
            let change = success(rig.service.setMode("auto"), "mode auto")
            check(change == ModeChange(before: "NR5G:LTE", after: "AUTO"), "setMode(\"auto\"): before is the modem's own string",
                  "\(String(describing: change))")
            rig.finish("mode auto", opens: 1)
        }
        for bad in ["lte:lte", "5g", "auto:lte", "", "lte:", "LTE NR5G"] {
            let rig = Rig()
            let message = failureMessage(rig.service.setMode(bad), "mode \(bad)")
            check(message.hasSuffix("Nothing was changed."), "setMode(\"\(bad)\"): refused, nothing changed", message)
            rig.finish("mode \(bad)", opens: 0)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, pref("LTE:NR5G"))])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back differs")
            expectEqual(message, "The modem answered OK but now reports LTE:NR5G. It was AUTO.",
                        "setMode: a different read-back fails")
            rig.finish("mode read-back differs", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, ok)])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back empty")
            expectEqual(message, "The modem answered OK but now reports no mode. It was AUTO.",
                        "setMode: a read-back without a mode fails")
            rig.finish("mode read-back empty", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, timedOut)])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back times out")
            expectEqual(message, "The modem answered OK, but the network mode could not be read back. "
                        + "The modem did not answer in time. It was AUTO.", "setMode: a read-back that times out fails")
            rig.finish("mode read-back times out", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", cme(3))])
            let message = failureMessage(rig.service.setMode("lte"), "mode refused")
            expectEqual(message, "The network mode was not changed. The modem refused the command (+CME ERROR: 3).",
                        "setMode: a refused write")
            rig.finish("mode refused", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", timedOut)])
            let message = failureMessage(rig.service.setMode("lte"), "mode write times out")
            expectEqual(message, "It is not known whether the network mode changed. The modem did not answer in time. It was AUTO.",
                        "setMode: a write that times out")
            rig.finish("mode write times out", opens: 1)
        }
        for (answer, name) in [(cme(3), "refused"), (ok, "without a mode"), (timedOut, "timed out")] {
            // Without the mode before, there is no way back: nothing is written.
            let rig = Rig([(read, answer)])
            let message = failureMessage(rig.service.setMode("lte"), "mode before \(name)")
            check(message.hasSuffix("Nothing was changed."), "setMode: the mode before \(name): nothing written", message)
            expectLines(rig.port(1).lines, [read], "setMode: the mode before \(name): only the read")
            rig.finish("mode before \(name)", opens: 1)
        }
    }

    // MARK: usbMode, setUsbMode

    static func usbMode() {
        let read = "AT+QCFG=\"usbnet\""
        func usbnet(_ n: Int) -> Answer { .success(["+QCFG: \"usbnet\",\(n)"]) }
        func set(_ n: Int) -> String { "AT+QCFG=\"usbnet\",\(n)" }
        let notRestarted = "The modem was not restarted."

        // Reading.
        for (n, mode) in [(0, UsbNetMode.qmi), (1, .ecm), (2, .mbim), (3, .rndis)] {
            let rig = Rig([(read, usbnet(n))])
            let info = success(rig.service.usbMode(), "usbMode \(n)")
            check(info == UsbModeInfo(value: n) && info?.mode == mode, "usbMode: +QCFG: \"usbnet\",\(n) is \(mode)",
                  "\(String(describing: info))")
            expectLines(rig.port(1).lines, [read], "usbMode \(n): one read")
            check(rig.port(1).timeout(of: read) == 3, "usbMode: the read has 3 s")
            rig.finish("usbMode \(n)", opens: 1)
        }
        do {
            // A number RMNet does not know is kept as the modem gave it, without a mode.
            let rig = Rig([(read, usbnet(5))])
            let info = success(rig.service.usbMode(), "usbMode 5")
            check(info == UsbModeInfo(value: 5) && info?.mode == nil, "usbMode: an unknown number is kept, its mode nil",
                  "\(String(describing: info))")
            rig.finish("usbMode 5", opens: 1)
        }
        for (answer, name) in [(ok, "a bare OK"), (Answer.success(["+QCFG: \"usbnet\""]), "no number"),
                               (Answer.success(["+QCFG: \"usbnet\",-"]), "a dash"),
                               (Answer.success(["+QCFG: \"usbcfg\",0x2C7C,0x0801"]), "another setting")] {
            let rig = Rig([(read, answer)])
            let message = failureMessage(rig.service.usbMode(), "usbMode, \(name)")
            expectEqual(message, "The modem did not say which USB mode it uses.", "usbMode: \(name) is a failure")
            rig.finish("usbMode, \(name)", opens: 1)
        }
        for (answer, words) in [(cme(3), "The modem refused the command (+CME ERROR: 3)."),
                                (timedOut, "The modem did not answer in time.")] {
            let rig = Rig([(read, answer)])
            let message = failureMessage(rig.service.usbMode(), "usbMode, \(words)")
            expectEqual(message, "The USB mode could not be read. \(words)", "usbMode: a read that fails: \(words)")
            rig.finish("usbMode, \(words)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.modemNotAttached)])
            let message = failureMessage(rig.service.usbMode(), "usbMode, no modem")
            expectEqual(message, describe(.modemNotAttached), "usbMode: a failed open fails with describe(error)")
            rig.finish("usbMode, no modem", opens: 1)
        }

        // Setting: already that mode, nothing more is sent.
        for reboot in [true, false] {
            let rig = Rig([(read, usbnet(0))])
            let change = success(rig.service.setUsbMode(.qmi, reboot: reboot), "setUsbMode qmi, already, reboot \(reboot)")
            check(change == .unchanged, "setUsbMode(.qmi): already qmi is unchanged", "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read], "setUsbMode(.qmi, reboot: \(reboot)): already qmi sends only the read")
            rig.finish("setUsbMode qmi, already, reboot \(reboot)", opens: 1)
        }
        do {
            let rig = Rig([(read, usbnet(0)), (set(1), ok), (read, usbnet(1)), ("AT+CFUN=1,1", ok)])
            let change = success(rig.service.setUsbMode(.ecm, reboot: true), "setUsbMode ecm")
            check(change == .rebooting, "setUsbMode(.ecm, reboot: true): rebooting", "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read, set(1), read, "AT+CFUN=1,1"],
                        "setUsbMode(.ecm, reboot: true): read, set, read back, restart")
            check(rig.port(1).sent.map { $0.timeout } == [3, 5, 3, 20],
                  "setUsbMode: the reads have 3 s, the write 5 s, the restart 20 s", "\(rig.port(1).sent.map { $0.timeout })")
            check(rig.sleeps.isEmpty, "setUsbMode: no wait for the modem to come back", "\(rig.sleeps)")
            rig.finish("setUsbMode ecm", opens: 1)
        }
        do {
            let rig = Rig([(read, usbnet(0)), (set(1), ok), (read, usbnet(1))])
            let change = success(rig.service.setUsbMode(.ecm, reboot: false), "setUsbMode ecm, no reboot")
            check(change == .setTakesEffectAfterRestart, "setUsbMode(.ecm, reboot: false): takes effect after a restart",
                  "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read, set(1), read], "setUsbMode(reboot: false): stops before AT+CFUN")
            rig.finish("setUsbMode ecm, no reboot", opens: 1)
        }
        for (from, to) in [(2, UsbNetMode.qmi), (5, .qmi), (0, .mbim), (0, .rndis), (3, .ecm)] {
            let rig = Rig([(read, usbnet(from)), (set(to.rawValue), ok), (read, usbnet(to.rawValue)), ("AT+CFUN=1,1", ok)])
            let change = success(rig.service.setUsbMode(to, reboot: true), "setUsbMode \(from) to \(to)")
            check(change == .rebooting, "setUsbMode: \(from) to \(to) restarts", "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read, set(to.rawValue), read, "AT+CFUN=1,1"], "setUsbMode: \(from) to \(to)")
            rig.finish("setUsbMode \(from) to \(to)", opens: 1)
        }

        // A read-back that disagrees, or none: a failure, and no AT+CFUN.
        for (answer, reports) in [(usbnet(0), "qmi"), (usbnet(9), "unknown (9)"), (ok, "no USB mode")] {
            let rig = Rig([(read, usbnet(0)), (set(1), ok), (read, answer)])
            let message = failureMessage(rig.service.setUsbMode(.ecm, reboot: true), "setUsbMode, read-back \(reports)")
            expectEqual(message, "The modem answered OK but now reports \(reports). It was qmi. \(notRestarted)",
                        "setUsbMode: a read-back of \(reports) fails")
            expectLines(rig.port(1).lines, [read, set(1), read], "setUsbMode: a read-back of \(reports): no AT+CFUN")
            rig.finish("setUsbMode, read-back \(reports)", opens: 1)
        }
        do {
            let rig = Rig([(read, usbnet(2)), (set(0), ok), (read, timedOut)])
            let message = failureMessage(rig.service.setUsbMode(.qmi, reboot: true), "setUsbMode, read-back times out")
            expectEqual(message, "The modem answered OK, but the USB mode could not be read back. The modem did not answer "
                        + "in time. It was mbim. \(notRestarted)", "setUsbMode: a read-back that times out")
            expectLines(rig.port(1).lines, [read, set(0), read], "setUsbMode: a read-back that times out: no AT+CFUN")
            rig.finish("setUsbMode, read-back times out", opens: 1)
        }

        // The write.
        do {
            let rig = Rig([(read, usbnet(0)), (set(2), cme(3))])
            let message = failureMessage(rig.service.setUsbMode(.mbim, reboot: true), "setUsbMode, refused")
            expectEqual(message, "The USB mode was not changed. The modem refused the command (+CME ERROR: 3).",
                        "setUsbMode: a refused write")
            expectLines(rig.port(1).lines, [read, set(2)], "setUsbMode: a refused write: nothing more")
            rig.finish("setUsbMode, refused", opens: 1)
        }
        do {
            let rig = Rig([(read, usbnet(0)), (set(2), timedOut)])
            let message = failureMessage(rig.service.setUsbMode(.mbim, reboot: true), "setUsbMode, write times out")
            expectEqual(message, "It is not known whether the USB mode changed. The modem did not answer in time. "
                        + "It was qmi. \(notRestarted)", "setUsbMode: a write that times out")
            expectLines(rig.port(1).lines, [read, set(2)], "setUsbMode: a write that times out: nothing more")
            rig.finish("setUsbMode, write times out", opens: 1)
        }

        // The mode before not read: nothing is written.
        for (answer, name) in [(cme(3), "refused"), (ok, "without a mode"), (timedOut, "timed out")] {
            let rig = Rig([(read, answer)])
            let message = failureMessage(rig.service.setUsbMode(.qmi, reboot: true), "setUsbMode, before \(name)")
            check(message.hasSuffix("Nothing was changed."), "setUsbMode: the mode before \(name): nothing changed", message)
            expectLines(rig.port(1).lines, [read], "setUsbMode: the mode before \(name): only the read")
            rig.finish("setUsbMode, before \(name)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setUsbMode(.qmi, reboot: true), "setUsbMode, busy")
            expectEqual(message, "\(describe(.busy)) Nothing was changed.", "setUsbMode: a failed open changes nothing")
            rig.finish("setUsbMode, busy", opens: 1)
        }

        // The restart itself.
        do {
            let rig = Rig([(read, usbnet(0)), (set(1), ok), (read, usbnet(1)), ("AT+CFUN=1,1", cme(3))])
            let message = failureMessage(rig.service.setUsbMode(.ecm, reboot: true), "setUsbMode, restart refused")
            expectEqual(message, "The USB mode is now ecm, but the modem was not restarted. The modem refused the command "
                        + "(+CME ERROR: 3). It takes effect at the next restart (AT+CFUN=1,1 or a replug).",
                        "setUsbMode: a refused restart")
            rig.finish("setUsbMode, restart refused", opens: 1)
        }
        for (answer, words) in [(timedOut, "The modem did not answer in time."),
                                (ioError, describe(.io(Int32(bitPattern: 0xE000_02ED))))] {
            let rig = Rig([(read, usbnet(2)), (set(0), ok), (read, usbnet(0)), ("AT+CFUN=1,1", answer)])
            let message = failureMessage(rig.service.setUsbMode(.qmi, reboot: true), "setUsbMode, restart: \(words)")
            expectEqual(message, "The USB mode is now qmi. It is not known whether the modem is restarting. \(words) "
                        + "If it does not restart, the new mode takes effect at the next restart (AT+CFUN=1,1 or a replug).",
                        "setUsbMode: a restart without an answer: \(words)")
            rig.finish("setUsbMode, restart: \(words)", opens: 1)
        }
    }

    // MARK: bands

    // Seen on the modem on 2026-11-15: after `RMNet bands set sa n41`, ue_capability_band said 41 for nr5g_band,
    // so the supported list read 41 and `bands reset sa` would have put back only 41. rf_band does not follow a
    // lock: the supported lists, and so a reset, must stay the hardware's, whatever is locked.
    static func bandsAfterLock() {
        let modem = BandModem()
        let service = ModemService(open: { .success(BandModemPort(modem)) })
        let lockLine = "AT+QNWPREFCFG=\"nr5g_band\",41"

        // The lock, as `RMNet bands set sa n41` makes it.
        let lock = success(service.setBands(.sa, to: [41]), "after a lock: the lock")
        check(lock == BandChange(before: nrSupported, after: [41]), "after a lock: sa locked from every band to 41",
              "\(String(describing: lock))")
        check(modem.sent.filter { $0 == lockLine }.count == 1, "after a lock: one write of 41", "\(modem.sent)")

        // The model answers as the modem did: its setting and ue_capability_band say 41, rf_band still lists all.
        if case .success(let lines) = modem.answer("AT+QNWPREFCFG=\"ue_capability_band\"") {
            check(parseBandList(lines, key: "nr5g_band") == [41], "after a lock: the model's ue_capability_band says 41")
        } else {
            check(false, "after a lock: the model answers ue_capability_band")
        }
        if case .success(let lines) = modem.answer("AT+QNWPREFCFG=\"rf_band\"") {
            check(parseBandList(lines, key: "nr5g_band") == nrSupported, "after a lock: the model's rf_band lists every band")
        } else {
            check(false, "after a lock: the model answers rf_band")
        }
        let marked = modem.sent.count

        // `RMNet bands`: every supported band, though 5G SA allows only 41.
        let sets = success(service.bands(), "after a lock: bands")
        check(sets == [BandSet(rat: .lte, allowed: lteSupported, supported: lteSupported),
                       BandSet(rat: .nsa, allowed: nrSupported, supported: nrSupported),
                       BandSet(rat: .sa, allowed: [41], supported: nrSupported)],
              "after a lock: bands() gives the full supported lists, and 41 allowed for 5G SA", "\(String(describing: sets))")

        // `RMNet bands set sa n99` names every supported band, not 41.
        expectEqual(failureMessage(service.setBands(.sa, to: [99]), "after a lock: sa 99"),
                    "The modem does not support 5G SA band 99 (supported: \(nrWords)). The 5G SA bands were not changed.",
                    "after a lock: an unsupported band is refused with the full supported list")

        // `RMNet bands reset sa`: setBands(.sa, to:) the supported list bands() gave, which writes every band.
        let reset = success(service.setBands(.sa, to: sets?.last?.supported ?? []), "after a lock: reset sa")
        check(reset == BandChange(before: [41], after: nrSupported), "after a lock: reset sa puts back every band",
              "\(String(describing: reset))")
        check(modem.sent.contains("AT+QNWPREFCFG=\"nr5g_band\",\(nrList)"), "after a lock: reset sa writes the full list",
              "\(modem.sent)")
        check(modem.allowed["nr5g_band"] == nrSupported, "after a lock: the modem allows every 5G SA band again",
              "\(String(describing: modem.allowed["nr5g_band"]))")
        check(modem.sent.filter { $0 == "AT+QNWPREFCFG=\"ue_capability_band\"" }.count == 1,
              "after a lock: RMNet never reads ue_capability_band (only the test asked the model once)", "\(modem.sent)")
        check(modem.sent[marked...].first == "AT+QNWPREFCFG=\"rf_band\"", "after a lock: bands() starts with rf_band",
              "\(modem.sent[marked...])")
        check(!modem.sent.contains { $0.hasPrefix("AT+QNWPREFCFG=\"nr5g_band\",") && $0 != lockLine
                                     && $0 != "AT+QNWPREFCFG=\"nr5g_band\",\(nrList)" },
              "after a lock: only the lock and the reset were written", "\(modem.sent)")
    }

    static func bandsRead() {
        let reads = [supportRead, bandRead("lte_band"), bandRead("nsa_nr5g_band"), bandRead("nr5g_band")]
        func script(lte: Answer = bandAnswer("lte_band", lteList), nsa: Answer = bandAnswer("nsa_nr5g_band", nrList),
                    sa: Answer = bandAnswer("nr5g_band", nrList),
                    rf: Answer = .success(rfBandLines)) -> [(String, Answer)] {
            [(supportRead, rf), (bandRead("lte_band"), lte), (bandRead("nsa_nr5g_band"), nsa),
             (bandRead("nr5g_band"), sa)]
        }

        // The values.
        check(BandRat.allCases == [.lte, .nsa, .sa], "BandRat: lte, nsa, sa in that order")
        check(BandRat.allCases.map { $0.rawValue } == ["lte", "nsa", "sa"], "BandRat: raw values lte, nsa, sa")
        check(BandRat.allCases.map { $0.key } == ["lte_band", "nsa_nr5g_band", "nr5g_band"],
              "BandRat: the modem's keys", "\(BandRat.allCases.map { $0.key })")
        check(BandRat.allCases.map { $0.name } == ["LTE", "5G NSA", "5G SA"], "BandRat: the display names",
              "\(BandRat.allCases.map { $0.name })")

        // The modem's answers as they are: every supported band allowed.
        do {
            let rig = Rig(script())
            let sets = success(rig.service.bands(), "bands")
            check(sets == [BandSet(rat: .lte, allowed: lteSupported, supported: lteSupported),
                           BandSet(rat: .nsa, allowed: nrSupported, supported: nrSupported),
                           BandSet(rat: .sa, allowed: nrSupported, supported: nrSupported)],
                  "bands: the three RATs, each allowing every supported band", "\(String(describing: sets))")
            check(sets?.map { $0.supported.count } == [31, 28, 28], "bands: 31 LTE, 28 NSA, 28 SA bands supported")
            expectLines(rig.port(1).lines, reads, "bands: the rf_band read, then lte, nsa, sa")
            check(rig.port(1).sent.map { $0.timeout } == [3, 3, 3, 3], "bands: each read has 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            rig.finish("bands", opens: 1)
        }
        do {
            // Locked: the allowed lists sorted, each band once; 0 alone is none.
            let rig = Rig(script(lte: bandAnswer("lte_band", "41:3:3"), nsa: bandAnswer("nsa_nr5g_band", "0"),
                                 sa: bandAnswer("nr5g_band", "78:41")))
            let sets = success(rig.service.bands(), "bands, locked")
            check(sets == [BandSet(rat: .lte, allowed: [3, 41], supported: lteSupported),
                           BandSet(rat: .nsa, allowed: [], supported: nrSupported),
                           BandSet(rat: .sa, allowed: [41, 78], supported: nrSupported)],
                  "bands: allowed lists sorted and unique; 0 alone is none", "\(String(describing: sets))")
            rig.finish("bands, locked", opens: 1)
        }
        do {
            // The rf_band lines in another order, unquoted as well as quoted, with other lines among them.
            let shuffled: Answer = .success(["+QNWPREFCFG: \"nsa_nr5g_band\",\(nrList)", "+QNWPREFCFG: \"nrdc_nr5g_band\",0",
                                             "+QNWPREFCFG: \"lte_band\",\"\(lteList)\"", "+QNWPREFCFG: \"gw_band\",1:2:4:5:8:19",
                                             "+QNWPREFCFG: \"nr5g_band\",\"\(nrList)\""])
            let rig = Rig(script(rf: shuffled))
            let sets = success(rig.service.bands(), "bands, shuffled rf_band")
            check(sets?.map { $0.rat } == [.lte, .nsa, .sa] && sets?.map { $0.supported.count } == [31, 28, 28],
                  "bands: the rf_band lines found by key, in any order", "\(String(describing: sets))")
            rig.finish("bands, shuffled rf_band", opens: 1)
        }

        // The parsing itself.
        // rf_band's exact answer: quoted lists, nr5g_band before nsa_nr5g_band, no nrdc line.
        check(parseBandList(rfBandLines, key: "lte_band") == lteSupported, "parseBandList: rf_band lte_band, quoted")
        check(parseBandList(rfBandLines, key: "nr5g_band") == nrSupported, "parseBandList: rf_band nr5g_band, quoted")
        check(parseBandList(rfBandLines, key: "nsa_nr5g_band") == nrSupported, "parseBandList: rf_band nsa_nr5g_band, quoted")
        check(parseBandList(rfBandLines, key: "gw_band") == [1, 2, 4, 5, 8, 19], "parseBandList: rf_band gw_band, quoted")
        check(parseBandList(rfBandLines, key: "nrdc_nr5g_band") == nil, "parseBandList: rf_band has no nrdc line, nil")
        check(parseBandList(["+QNWPREFCFG: \"nrdc_nr5g_band\",0"], key: "nrdc_nr5g_band") == [], "parseBandList: 0 alone is none")
        check(parseBandList(["+QNWPREFCFG: \"lte_band\",\"0\""], key: "lte_band") == [], "parseBandList: \"0\" alone is none")
        check(parseBandList(["+QNWPREFCFG: \"lte_band\",\"3:41\""], key: "lte_band") == [3, 41], "parseBandList: a quoted list")
        check(parseBandList(["+QNWPREFCFG: \"lte_band\",41"], key: "lte_band") == [41], "parseBandList: one band")
        check(parseBandList(["+QNWPREFCFG: \"lte_band\",41:3:41"], key: "lte_band") == [3, 41],
              "parseBandList: sorted, each band once")
        check(parseBandList([" +QNWPREFCFG: \"lte_band\",3:41 "], key: "lte_band") == [3, 41],
              "parseBandList: spaces around the line are ignored")
        check(parseBandList(rfBandLines, key: "nr5g") == nil, "parseBandList: a key is matched whole")
        check(parseBandList([], key: "lte_band") == nil, "parseBandList: no lines, nil")
        check(parseBandList(["+QNWPREFCFG: \"mode_pref\",AUTO"], key: "lte_band") == nil, "parseBandList: another key, nil")
        for bad in ["", "1::3", "1:3:", ":1", "1:x:3", "x", "0:3", "3:0", "1;3", "1,3", "+3", "-3", "3 :41", "1.5",
                    "\u{0663}", "99999999999999999999"] {
            check(parseBandList(["+QNWPREFCFG: \"lte_band\",\(bad)"], key: "lte_band") == nil,
                  "parseBandList: \(bad.debugDescription) is unparsable, nil")
        }
        check(parseBandList(["+QNWPREFCFG: \"lte_band\""], key: "lte_band") == nil, "parseBandList: no list, nil")
        check(parseBandList(["+QNWPREFCFG: \"lte_band\",3,41"], key: "lte_band") == nil,
              "parseBandList: a third field is unparsable, nil")
        check(bandsCommand(.lte, [3, 41]) == "AT+QNWPREFCFG=\"lte_band\",3:41", "bandsCommand: lte 3:41")
        check(bandsCommand(.nsa, [78]) == "AT+QNWPREFCFG=\"nsa_nr5g_band\",78", "bandsCommand: nsa 78")
        check(bandsCommand(.sa, [41, 1]) == "AT+QNWPREFCFG=\"nr5g_band\",1:41", "bandsCommand: sorted")
        check(bandsCommand(.sa, [41, 41, 78]) == "AT+QNWPREFCFG=\"nr5g_band\",41:78", "bandsCommand: each band once")
        expectEqual(bandListWords([3, 41]), "3, 41", "bandListWords: comma and space")
        expectEqual(bandListWords([41, 3, 3]), "3, 41", "bandListWords: ascending, each once")
        expectEqual(bandListWords([]), "none", "bandListWords: none")

        // A key the modem did not report, or a list that cannot be read: a failure saying so.
        for (rat, name) in [(BandRat.lte, "LTE"), (.nsa, "5G NSA"), (.sa, "5G SA")] {
            let missing: Answer = .success(rfBandLines.filter { !$0.hasPrefix("+QNWPREFCFG: \"\(rat.key)\",") })
            let rig = Rig([(supportRead, missing)])
            let message = failureMessage(rig.service.bands(), "bands, no supported \(name)")
            expectEqual(message, "The modem did not report its supported \(name) bands.",
                        "bands: no supported \(name) line is a failure")
            rig.finish("bands, no supported \(name)", opens: 1)
        }
        do {
            let rig = Rig([(supportRead, .success(rfBandLines.map { $0.replacingOccurrences(of: ":78:", with: ":x:") }))])
            let message = failureMessage(rig.service.bands(), "bands, unparsable supported")
            expectEqual(message, "The modem did not report its supported 5G NSA bands.",
                        "bands: an unparsable supported list is a failure")
            rig.finish("bands, unparsable supported", opens: 1)
        }
        for (answer, what) in [(ok, "a bare OK"), (bandAnswer("nr5g_band", "1::3"), "an unparsable list"),
                               (bandAnswer("nsa_nr5g_band", nrList), "another key")] {
            let rig = Rig(script(sa: answer))
            let message = failureMessage(rig.service.bands(), "bands, allowed SA \(what)")
            expectEqual(message, "The modem did not report its allowed 5G SA bands.", "bands: allowed SA \(what) is a failure")
            rig.finish("bands, allowed SA \(what)", opens: 1)
        }
        for (answer, words) in [(cme(3), "The modem refused the command (+CME ERROR: 3)."),
                                (timedOut, "The modem did not answer in time.")] {
            let rig = Rig([(supportRead, answer)])
            let message = failureMessage(rig.service.bands(), "bands, rf_band \(words)")
            expectEqual(message, "The supported bands could not be read. \(words)", "bands: an rf_band read that fails")
            rig.finish("bands, rf_band \(words)", opens: 1)
        }
        for (answer, words) in [(cme(3), "The modem refused the command (+CME ERROR: 3)."),
                                (timedOut, "The modem did not answer in time.")] {
            let rig = Rig([(supportRead, .success(rfBandLines)), (bandRead("lte_band"), answer)])
            let message = failureMessage(rig.service.bands(), "bands, allowed LTE \(words)")
            expectEqual(message, "The allowed LTE bands could not be read. \(words)", "bands: an allowed read that fails")
            expectLines(rig.port(1).lines, [supportRead, bandRead("lte_band")], "bands: nothing read after a failed read")
            rig.finish("bands, allowed LTE \(words)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.modemNotAttached)])
            let message = failureMessage(rig.service.bands(), "bands, no modem")
            expectEqual(message, describe(.modemNotAttached), "bands: a failed open fails with describe(error)")
            rig.finish("bands, no modem", opens: 1)
        }
    }

    static func bandsChange() {
        let saRead = bandRead("nr5g_band")
        let lteRead = bandRead("lte_band")
        let rf: (String, Answer) = (supportRead, .success(rfBandLines))
        let allSA = (saRead, bandAnswer("nr5g_band", nrList))
        // A failure before the write names the RAT, not "Nothing was changed." (an earlier RAT of a reset of all
        // three may have been set).
        let notChanged = "The 5G SA bands were not changed."

        // The change: the rf_band read, the RAT's read, the write, the read-back, on one port.
        do {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", ok), (saRead, bandAnswer("nr5g_band", "41"))])
            let change = success(rig.service.setBands(.sa, to: [41]), "setBands sa 41")
            check(change == BandChange(before: nrSupported, after: [41]), "setBands(.sa, [41]): from every band to 41",
                  "\(String(describing: change))")
            expectLines(rig.port(1).lines, [supportRead, saRead, "AT+QNWPREFCFG=\"nr5g_band\",41", saRead],
                        "setBands(.sa, [41]): rf_band, nr5g_band, the write, the read-back")
            check(rig.port(1).sent.map { $0.timeout } == [3, 3, 5, 3], "setBands: the write has 5 s, the reads 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            rig.finish("setBands sa 41", opens: 1)
        }
        do {
            // Sorted and each band once; the read-back compared as a set.
            let rig = Rig([rf, (lteRead, bandAnswer("lte_band", lteList)), ("AT+QNWPREFCFG=\"lte_band\",3:41", ok),
                           (lteRead, bandAnswer("lte_band", "41:3"))])
            let change = success(rig.service.setBands(.lte, to: [41, 3, 3]), "setBands lte 41,3,3")
            check(change == BandChange(before: lteSupported, after: [3, 41]), "setBands(.lte, [41, 3, 3]): sends 3:41",
                  "\(String(describing: change))")
            rig.finish("setBands lte 41,3,3", opens: 1)
        }
        do {
            let rig = Rig([rf, (bandRead("nsa_nr5g_band"), bandAnswer("nsa_nr5g_band", "41")),
                           ("AT+QNWPREFCFG=\"nsa_nr5g_band\",\(nrList)", ok),
                           (bandRead("nsa_nr5g_band"), bandAnswer("nsa_nr5g_band", nrList))])
            let change = success(rig.service.setBands(.nsa, to: nrSupported), "setBands nsa, reset")
            check(change == BandChange(before: [41], after: nrSupported), "setBands(.nsa, supported): the reset",
                  "\(String(describing: change))")
            rig.finish("setBands nsa, reset", opens: 1)
        }
        do {
            // Only the RAT changed needs its supported line.
            let rig = Rig([(supportRead, .success(rfBandLines.filter { !$0.contains("\"lte_band\"") })), allSA,
                           ("AT+QNWPREFCFG=\"nr5g_band\",78", ok), (saRead, bandAnswer("nr5g_band", "78"))])
            _ = success(rig.service.setBands(.sa, to: [78]), "setBands sa, no lte line")
            rig.finish("setBands sa, no lte line", opens: 1)
        }

        // Already allowed: no write.
        for (allowed, asked) in [(nrList, nrSupported), ("41", [41]), ("41:78", [78, 41, 41])] {
            let rig = Rig([rf, (saRead, bandAnswer("nr5g_band", allowed))])
            let change = success(rig.service.setBands(.sa, to: asked), "setBands sa \(asked), unchanged")
            let before = parseBandList(["+QNWPREFCFG: \"nr5g_band\",\(allowed)"], key: "nr5g_band") ?? [-1]
            check(change == BandChange(before: before, after: before), "setBands(.sa, \(asked)): already allowed, unchanged",
                  "\(String(describing: change))")
            expectLines(rig.port(1).lines, [supportRead, saRead], "setBands(.sa, \(asked)): already allowed, only the reads")
            rig.finish("setBands sa \(asked), unchanged", opens: 1)
        }

        // Refused: an empty list (no port opened), or a band not supported (nothing written).
        do {
            let rig = Rig([])
            let message = failureMessage(rig.service.setBands(.sa, to: []), "setBands sa []")
            expectEqual(message, "At least one 5G SA band is needed. \(notChanged)", "setBands(.sa, []): refused")
            rig.finish("setBands sa []", opens: 0)
        }
        for (rat, name) in [(BandRat.lte, "LTE"), (.nsa, "5G NSA")] {
            expectEqual(bandsNotChanged(rat), "The \(name) bands were not changed.", "bandsNotChanged(.\(rat)): names the RAT")
            let rig = Rig([])
            let message = failureMessage(rig.service.setBands(rat, to: []), "setBands \(rat) []")
            expectEqual(message, "At least one \(name) band is needed. The \(name) bands were not changed.",
                        "setBands(.\(rat), []): refused, naming the RAT")
            rig.finish("setBands \(rat) []", opens: 0)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setBands(.nsa, to: [41]), "setBands nsa, busy")
            expectEqual(message, "\(describe(.busy)) The 5G NSA bands were not changed.",
                        "setBands(.nsa): a failed open names the RAT, not \"Nothing was changed.\"")
            rig.finish("setBands nsa, busy", opens: 1)
        }
        for (asked, words) in [([99], "band 99"), ([41, 100, 99], "bands 99, 100"), ([4], "band 4")] {
            let rig = Rig([rf, allSA])
            let message = failureMessage(rig.service.setBands(.sa, to: asked), "setBands sa \(asked)")
            expectEqual(message, "The modem does not support 5G SA \(words) (supported: \(nrWords)). \(notChanged)",
                        "setBands(.sa, \(asked)): refused, naming the bands")
            expectLines(rig.port(1).lines, [supportRead, saRead], "setBands(.sa, \(asked)): no write")
            rig.finish("setBands sa \(asked)", opens: 1)
        }
        do {
            // A RAT with no supported bands: its reset is an empty list, refused.
            let rig = Rig([(supportRead, .success(["+QNWPREFCFG: \"lte_band\",\"0\""])), (lteRead, bandAnswer("lte_band", "3"))])
            let message = failureMessage(rig.service.setBands(.lte, to: [3]), "setBands lte, none supported")
            expectEqual(message, "The modem does not support LTE band 3 (supported: none). The LTE bands were not changed.",
                        "setBands: no band supported")
            rig.finish("setBands lte, none supported", opens: 1)
        }

        // The read-back.
        do {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", ok), (saRead, bandAnswer("nr5g_band", "41:78"))])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, read-back differs")
            expectEqual(message, "The modem answered OK but now reports 5G SA bands 41, 78. They were \(nrWords).",
                        "setBands: a read-back that differs names both lists")
            rig.finish("setBands, read-back differs", opens: 1)
        }
        for (answer, what) in [(ok, "a bare OK"), (bandAnswer("nr5g_band", "4x"), "an unparsable list")] {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", ok), (saRead, answer)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, read-back \(what)")
            expectEqual(message, "The modem answered OK but did not report its 5G SA bands. They were \(nrWords).",
                        "setBands: a read-back with \(what)")
            rig.finish("setBands, read-back \(what)", opens: 1)
        }
        do {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", ok), (saRead, timedOut)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, read-back times out")
            expectEqual(message, "The modem answered OK, but the 5G SA bands could not be read back. The modem did not answer "
                        + "in time. They were \(nrWords).", "setBands: a read-back that times out")
            rig.finish("setBands, read-back times out", opens: 1)
        }

        // The write.
        do {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", cme(3))])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, refused")
            expectEqual(message, "The 5G SA bands were not changed. The modem refused the command (+CME ERROR: 3).",
                        "setBands: a refused write")
            rig.finish("setBands, refused", opens: 1)
        }
        do {
            let rig = Rig([rf, allSA, ("AT+QNWPREFCFG=\"nr5g_band\",41", timedOut)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, write times out")
            expectEqual(message, "It is not known whether the 5G SA bands changed. The modem did not answer in time. "
                        + "They were \(nrWords).", "setBands: a write that times out")
            rig.finish("setBands, write times out", opens: 1)
        }

        // The lists before not read: nothing is written.
        for (answer, words) in [(cme(3), "The supported bands could not be read. The modem refused the command (+CME ERROR: 3)."),
                                (timedOut, "The supported bands could not be read. The modem did not answer in time."),
                                (ok, "The modem did not report its supported 5G SA bands.")] {
            let rig = Rig([(supportRead, answer)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, rf_band: \(words)")
            expectEqual(message, "\(words) \(notChanged)", "setBands: rf_band not read: nothing written")
            expectLines(rig.port(1).lines, [supportRead], "setBands: rf_band not read: only that read")
            rig.finish("setBands, rf_band: \(words)", opens: 1)
        }
        for (answer, words) in [(cme(3), "The allowed 5G SA bands could not be read. The modem refused the command (+CME ERROR: 3)."),
                                (timedOut, "The allowed 5G SA bands could not be read. The modem did not answer in time."),
                                (ok, "The modem did not report its allowed 5G SA bands.")] {
            let rig = Rig([rf, (saRead, answer)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, allowed: \(words)")
            expectEqual(message, "\(words) \(notChanged)", "setBands: allowed not read: nothing written")
            expectLines(rig.port(1).lines, [supportRead, saRead], "setBands: allowed not read: only the reads")
            rig.finish("setBands, allowed: \(words)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setBands(.sa, to: [41]), "setBands, busy")
            expectEqual(message, "\(describe(.busy)) \(notChanged)", "setBands: a failed open changes nothing")
            rig.finish("setBands, busy", opens: 1)
        }
    }

    // MARK: at

    static func atCommand() {
        // The answer: the lines before OK, as AtPort gives them; the line sent once, with the timeout asked.
        do {
            let rig = Rig([("ATI", .success(["Quectel", "RM520N-GL", "Revision: X"]))])
            let lines = success(rig.service.at("ATI", timeout: 10), "at ATI")
            check(lines == ["Quectel", "RM520N-GL", "Revision: X"], "at(\"ATI\"): the three answer lines",
                  "\(String(describing: lines))")
            expectLines(rig.port(1).lines, ["ATI"], "at(\"ATI\"): exactly ATI sent")
            check(rig.port(1).sent.map { $0.timeout } == [10], "at(\"ATI\", timeout: 10): sent with 10 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            rig.finish("at ATI", opens: 1)
        }
        do {
            // Through AtPort's own answer logic: the echo and the final OK are not answer lines.
            let port = CollectingPort("ATI", "ATI\r\r\nQuectel\r\nRM520N-GL\r\nRevision: X\r\n\r\nOK\r\n")
            let service = ModemService(open: { .success(port) })
            let lines = success(service.at("ATI", timeout: 10), "at ATI, raw answer")
            check(lines == ["Quectel", "RM520N-GL", "Revision: X"], "at(\"ATI\"): echo and OK are left out",
                  "\(String(describing: lines))")
            check(port.sent == ["ATI"] && port.closed, "at(\"ATI\"): raw answer: one line sent, the port closed",
                  "\(port.sent)")
        }
        for (line, timeout) in [("AT+QGPS=1", 10.0), ("AT+COPS=?", 60.0), ("AT+QCFG=\"usbnet\"", 1.0), ("at", 300.0),
                                ("AT+COPS=1,0,\"CHINA MOBILE\"", 10.0)] {
            let rig = Rig([(line, ok)])
            let lines = success(rig.service.at(line, timeout: timeout), "at \(line)")
            check(lines == [], "at(\(line)): an answer of OK alone has no lines", "\(String(describing: lines))")
            check(rig.port(1).sent.map { $0.line } == [line] && rig.port(1).sent.map { $0.timeout } == [timeout],
                  "at(\(line), timeout: \(timeout)): sent as it is, once, with that timeout",
                  "\(rig.port(1).sent.map { "\($0.line) \($0.timeout)" })")
            rig.finish("at \(line)", opens: 1)
        }

        // The modem's error line: a failure whose message is that line.
        for errorLine in ["ERROR", "+CME ERROR: 10", "+CMS ERROR: 500"] {
            let rig = Rig([("AT+CPIN?", .failure(.modem(errorLine)))])
            let failure = failureOf(rig.service.at("AT+CPIN?", timeout: 10), "at, \(errorLine)")
            check(failure == ModemFailure(message: errorLine, atKind: .modemError),
                  "at: \(errorLine) is a failure with that text, kind modemError", "\(failure)")
            expectLines(rig.port(1).lines, ["AT+CPIN?"], "at: \(errorLine): one line sent")
            rig.finish("at, \(errorLine)", opens: 1)
        }

        // No answer in time, an I/O error: failures saying so.
        do {
            let rig = Rig([("AT+COPS=?", timedOut)])
            let failure = failureOf(rig.service.at("AT+COPS=?", timeout: 60), "at, timeout")
            check(failure == ModemFailure(message: describe(.timeout), atKind: .timeout),
                  "at: no answer in time is a failure saying so, kind timeout", "\(failure)")
            expectLines(rig.port(1).lines, ["AT+COPS=?"], "at: a timeout: one line sent")
            rig.finish("at, timeout", opens: 1)
        }
        do {
            let rig = Rig([("ATI", ioError)])
            let failure = failureOf(rig.service.at("ATI", timeout: 10), "at, I/O error")
            check(failure == ModemFailure(message: describe(.io(Int32(bitPattern: 0xE000_02ED)))),
                  "at: an I/O error is a failure saying so, no kind", "\(failure)")
            rig.finish("at, I/O error", opens: 1)
        }

        // A port that does not open: nothing sent; also a timeout of the open is not the command's.
        for error in [AtError.modemNotAttached, .noAtInterface, .busy, .timeout] {
            let rig = Rig([.failure(error)])
            let failure = failureOf(rig.service.at("ATI", timeout: 10), "at, open \(error)")
            check(failure == ModemFailure(message: describe(error)), "at: a failed open (\(error)) is describe(error), no kind",
                  "\(failure)")
            rig.finish("at, open \(error)", opens: 1)
        }

        // A line the CLI refuses is not sent here either: no port is opened.
        let long = "AT+" + String(repeating: "A", count: 510)
        for line in ["", "hello", "ATI\rAT+CFUN=0", "ATI\n", "AT+CMGS=\"123\"\u{1A}", "AT\tI", "AT\u{E9}", "AT\u{7F}",
                     long, "AT+CMGS=\"123\"", "at+cmgs=\"123\"", "AT+CMGW", "At+CmGw=\"123\"",
                     "AT+CSQ;+CMGS=\"1\"", "AT +CMGS=1", "AT+CMGC=1", "AT+QCMGS", "ATD*99#", "ATO", "ATV0", "ATQ1",
                     "ATS3=10", "ATE1S4=10", "AT&W", "AT S3 = 13", "AT+CGDATA", "AT+CGDATA=\"PPP\",1", "AT+CSQ;+cgdata",
                     "AT+QCFG=\"usbnet\",1", "AT+QCFG=\"usbnet\",3", "at+qcfg=\"usbnet\",2", "AT+QCFG=\"usbnet\",0;+QCFG=\"usbnet\",1",
                     "AT+QCFG=\"usbcfg\",0x2C7C,0x0801,1,1,1,1,1,0,0", "AT+QCFG = \"usbcfg\" , 0"] {
            let rig = Rig([])
            let message = failureMessage(rig.service.at(line, timeout: 10), "at, refused \(line.debugDescription)")
            check(message.hasSuffix("; nothing was sent"), "at: \(line.debugDescription) is refused, nothing sent", message)
            rig.finish("at, refused \(line.debugDescription)", opens: 0)
        }
        // The USB mode back to QMI (the README's fallback), and the reads of both USB settings, are sent.
        for line in ["AT+QCFG=\"usbnet\",0", "AT+QCFG=\"usbcfg\"", "AT+QCFG=\"usbnet\""] {
            let rig = Rig([(line, ok)])
            _ = success(rig.service.at(line, timeout: 10), "at \(line)")
            expectLines(rig.port(1).lines, [line], "at(\(line)): sent as it is")
            rig.finish("at \(line)", opens: 1)
        }
        do {
            let longest = "AT+" + String(repeating: "A", count: 509)
            let rig = Rig([(longest, ok)])
            _ = success(rig.service.at(longest, timeout: 10), "at, 512 characters")
            rig.finish("at, 512 characters", opens: 1)
        }
    }

    // MARK: profiles

    static func profiles() {
        do {
            let rig = Rig([("AT+CGDCONT?", .success(cgdcont)),
                           ("AT+QICSGP=1", qicsgp1),
                           ("AT+QICSGP=2", .success(["+QICSGP: 3,\"ims\",\"\",\"\",0"])),
                           ("AT+QICSGP=3", .success(["+QICSGP: 3,\"CMNET\",\"\",\"\",0"])),
                           ("AT+QICSGP=4", cme(3)),
                           ("AT+QICSGP=5", .success(["+QICSGP: 3,\"SOS\",\"\",\"\",0"]))])
            let got = success(rig.service.profiles(), "profiles")
            let want = [
                DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1),
                DataProfile(id: 2, pdpType: "IPV4V6", apn: "ims",
                            settings: ProfileSettings(type: .ipv4v6, apn: "ims", user: "", password: "", auth: .none)),
                DataProfile(id: 3, pdpType: "IPV4V6", apn: "CMNET", settings: profile3),
                DataProfile(id: 4, pdpType: "IPV4V6", apn: "CMWAP", settings: nil),
                DataProfile(id: 5, pdpType: "IPV4V6", apn: "SOS",
                            settings: ProfileSettings(type: .ipv4v6, apn: "SOS", user: "", password: "", auth: .none)),
            ]
            check(got == want, "profiles: five profiles; a refused AT+QICSGP=4 leaves its settings nil", "\(String(describing: got))")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "profiles: each read has 3 s")
            rig.finish("profiles", opens: 1)
        }
        do {
            // Profile 20 is listed but AT+QICSGP takes 1 to 16: not asked.
            let rig = Rig([("AT+CGDCONT?", .success([cgdcont[0], "+CGDCONT: 20,\"IP\",\"x\",\"0.0.0.0\",0,0"])),
                           ("AT+QICSGP=1", qicsgp1)])
            let got = success(rig.service.profiles(), "profiles, 20")
            check(got == [DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1),
                          DataProfile(id: 20, pdpType: "IP", apn: "x", settings: nil)],
                  "profiles: a profile above 16 has no settings and is not asked", "\(String(describing: got))")
            rig.finish("profiles, 20", opens: 1)
        }
        do {
            let rig = Rig([("AT+CGDCONT?", .success(cgdcont)), ("AT+QICSGP=1", qicsgp1), ("AT+QICSGP=2", timedOut)])
            let message = failureMessage(rig.service.profiles(), "profiles, QICSGP times out")
            expectEqual(message, "Profile 2 could not be read. The modem did not answer in time.",
                        "profiles: a timeout on one profile fails the call")
            rig.finish("profiles, QICSGP times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CGDCONT?", cme(3))])
            let message = failureMessage(rig.service.profiles(), "profiles, CGDCONT refused")
            expectEqual(message, "The data profiles could not be read. The modem refused the command (+CME ERROR: 3).",
                        "profiles: AT+CGDCONT? refused fails")
            rig.finish("profiles, CGDCONT refused", opens: 1)
        }
    }

    // MARK: setProfile

    static func profileChange() {
        do {
            // The redial: the settings now, the radio's state, the radio off, a second, the change, the
            // read-back, the radio on, the registration.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", ok)] + searching + registered)
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "redial")
            let radio = RadioChange(on: true, registration: homeSA, secondsToRegister: 1)
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .done(radio)),
                  "setProfile(redial: true): before, after and .done with the seconds from the fake clock",
                  "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", "AT+CFUN?", "AT+CFUN=4", setCmnet, "AT+QICSGP=1", "AT+CFUN=1"]
                        + registrationLines + registrationLines, "setProfile(redial: true): the lines sent, exactly")
            check(rig.port(1).sent.map { $0.timeout } == [3, 3, 20, 5, 3, 20, 3, 3, 3, 3, 3, 3, 3, 3],
                  "setProfile: the timeouts (reads 3 s, AT+CFUN= 20 s, the change 5 s)", "\(rig.port(1).sent.map { $0.timeout })")
            check(rig.sleeps == [1, 1], "setProfile: one second after AT+CFUN=4, one between registration reads", "\(rig.sleeps)")
            rig.finish("redial", opens: 1)
        }
        do {
            // The password goes only in the change line.
            let rig = Rig(redialStart + [(setWithSecret, ok), ("AT+QICSGP=1", qicsgpWithSecret), ("AT+CFUN=1", ok)] + registered)
            let change = success(rig.service.setProfile(1, to: withSecret, redial: true), "redial with a password")
            check(change?.after == withSecret, "setProfile: a password set reads back", "\(String(describing: change))")
            check(rig.allLines.filter { $0.contains(secret) } == [setWithSecret],
                  "setProfile: the password is in no line but the change", linesText(rig.allLines.filter { $0 != setWithSecret }))
            rig.finish("redial with a password", opens: 1)
        }
        do {
            // Radio off at the start: no AT+CFUN= at all.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOff), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "radio was off")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .radioWasOff),
                  "setProfile: the radio off at the start gives .radioWasOff", "\(String(describing: change))")
            check(!rig.allLines.contains(where: { $0.hasPrefix("AT+CFUN=") }), "setProfile: radio off: no AT+CFUN= sent",
                  linesText(rig.allLines))
            check(rig.sleeps.isEmpty, "setProfile: radio off: no sleep")
            rig.finish("radio was off", opens: 1)
        }
        do {
            // Minimum functionality (AT+CFUN 0) is not on either.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", .success(["+CFUN: 0"])), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "radio at minimum")
            check(change?.redial == .radioWasOff, "setProfile: CFUN 0 is not on: .radioWasOff", "\(String(describing: change))")
            rig.finish("radio at minimum", opens: 1)
        }
        do {
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: false), "no redial")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .notAsked),
                  "setProfile(redial: false): .notAsked", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", setCmnet, "AT+QICSGP=1"], "setProfile(redial: false): no AT+CFUN")
            rig.finish("no redial", opens: 1)
        }
        do {
            // AT+CFUN=4 refused: the radio stays on, nothing else is sent.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 refused")
            check(message.hasSuffix("Nothing was changed."), "setProfile: AT+CFUN=4 refused ends \"Nothing was changed.\"", message)
            check(!rig.allLines.contains(where: { $0.hasPrefix("AT+QICSGP=1,") }), "setProfile: AT+CFUN=4 refused: no change sent",
                  linesText(rig.allLines))
            check(!rig.allLines.contains("AT+CFUN=1"), "setProfile: AT+CFUN=4 refused: the radio was not switched off, so no AT+CFUN=1")
            rig.finish("CFUN=4 refused", opens: 1)
        }
        do {
            // The read-back differs (APN x): a failure, and the radio is switched back on.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"x\",\"\",\"\",0"])),
                                         ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "read-back differs")
            expectEqual(message, "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"x\", no authentication. "
                        + "The radio was switched back on.", "setProfile: a different read-back fails and names what the modem reports")
            rig.finish("read-back differs", opens: 1)
        }
        do {
            // The read-back with another password: said, never shown.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setWithSecret, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"cmnet\",\"u\",\"****\",1"]))])
            let message = failureMessage(rig.service.setProfile(1, to: withSecret, redial: false), "read-back masked")
            expectEqual(message, "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"cmnet\", PAP, user \"u\", "
                        + "password set. Its password is not the one sent.", "setProfile: a different password is said, not shown")
            check(!message.contains(secret) && !message.contains("****"), "setProfile: no password in the failure", message)
            rig.finish("read-back masked", opens: 1)
        }
        do {
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setCmnet, cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: false), "refused, no redial")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed.", "setProfile(redial: false): a refusal")
            rig.finish("refused, no redial", opens: 1)
        }
        // The checks of what the owner typed: no port is opened.
        for (id, settings, name) in [
            (17, cmnet, "profile 17"), (0, cmnet, "profile 0"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a b", user: "", password: "", auth: .none), "an APN with a space"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a", user: "u\"", password: "", auth: .pap), "a user name with a quote"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "p\\41", auth: .pap), "a password with a backslash"),
        ] {
            let rig = Rig()
            let message = failureMessage(rig.service.setProfile(id, to: settings, redial: true), "problem: \(name)")
            expectEqual(message, profileProblem(id, settings) ?? "(no problem)", "setProfile: \(name) is refused with profileProblem")
            rig.finish("problem: \(name)", opens: 0)
        }
        do {
            // Without the settings before, nothing is changed.
            let rig = Rig([("AT+QICSGP=1", cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "before refused")
            expectEqual(message, "Profile 1 could not be read. The modem refused the command (+CME ERROR: 3). Nothing was changed.",
                        "setProfile: the settings before could not be read")
            rig.finish("before refused", opens: 1)
        }
        do {
            // Without the radio's state, no redial is started and nothing is changed.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", ok)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "radio state unknown")
            expectEqual(message, "The modem did not say whether the radio is on. Nothing was changed.",
                        "setProfile: the radio's state unknown changes nothing")
            rig.finish("radio state unknown", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "busy")
            expectEqual(message, "\(describe(.busy)) Nothing was changed.", "setProfile: a failed open changes nothing")
            rig.finish("busy", opens: 1)
        }
    }

    // A redial whose change, read-back or own port fails in the middle still switches the radio back on, on
    // a new port when the first closed itself, and says plainly when it could not.
    static func profileRedialFailures() {
        let stillOff = "Run `RMNet radio on`, or use the Radio switch on the window's Network screen."
        do {
            // The change refused: AT+CFUN=1 is still sent; nothing changed.
            let rig = Rig(redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "change refused")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed. The radio was switched back on.",
                        "redial: the change refused says the radio was switched back on and nothing changed")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", "AT+CFUN?", "AT+CFUN=4", setCmnet, "AT+CFUN=1"] + registrationLines,
                        "redial: the change refused: AT+CFUN=1 still sent")
            rig.finish("change refused", opens: 1)
        }
        do {
            // The change times out: the port closed itself; a second port switches the radio on.
            let rig = Rig(redialStart + [(setCmnet, timedOut)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "change times out")
            expectEqual(message, "It is not known whether profile 1 was changed. The modem did not answer in time. "
                        + "The radio was switched back on.", "redial: a timeout on the change")
            check(rig.port(1).closedItself, "redial: the first port closed itself")
            expectLines(rig.port(2).lines, ["AT+CFUN=1"] + registrationLines, "redial: AT+CFUN=1 is sent on the second port")
            check(rig.port(2).timeout(of: "AT+CFUN=1") == 20, "redial: AT+CFUN=1 on the second port has 20 s")
            rig.finish("change times out", opens: 2)
        }
        do {
            // An I/O error on the read-back: the same, on a second port.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", ioError)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "read-back I/O error")
            check(message.hasPrefix("Profile 1 could not be read back after the change. An I/O error occurred")
                  && message.hasSuffix("The radio was switched back on."), "redial: an I/O error on the read-back", message)
            rig.finish("read-back I/O error", opens: 2)
        }
        do {
            // The change and its read-back are fine; AT+CFUN=1 fails on both ports: the radio is left off.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", timedOut)],
                          [("AT+CFUN=1", timedOut)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=1 fails twice")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .radioLeftOff("The modem did not answer in time.")),
                  "redial: AT+CFUN=1 failing on both ports gives .radioLeftOff", "\(String(describing: change))")
            if let change {
                check(profileSentence(change).contains("the radio is still off"), "redial: the sentence names the radio still off",
                      profileSentence(change))
            }
            rig.finish("CFUN=1 fails twice", opens: 2)
        }
        do {
            // The change refused and AT+CFUN=1 failing on both ports (the second will not open).
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", ioError)])),
                           .failure(.modemNotAttached)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "refused, radio still off")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed, but the radio is still off. \(describe(.modemNotAttached)) \(stillOff)",
                        "redial: the change refused and the radio still off")
            rig.finish("refused, radio still off", opens: 2)
        }
        do {
            // The change and its read-back are fine; AT+CFUN=1 times out on the first port and works on a new
            // one: the redial is done.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", timedOut)],
                          [("AT+CFUN=1", ok)] + registered)
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=1 times out, reopen works")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet,
                                          redial: .done(RadioChange(on: true, registration: homeSA, secondsToRegister: 0))),
                  "redial: AT+CFUN=1 timing out on port 1 and working on port 2 is .done", "\(String(describing: change))")
            expectLines(rig.port(2).lines, ["AT+CFUN=1"] + registrationLines, "redial: AT+CFUN=1 again on the second port")
            rig.finish("CFUN=1 times out, reopen works", opens: 2)
        }
        do {
            // The change refused and AT+CFUN=1 refused on a working port: no second port; nothing changed, but
            // the radio is still off.
            let rig = Rig(redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", cme(4))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "refused, CFUN=1 refused")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed, but the radio is still off. The modem refused the command (+CME ERROR: 4). "
                        + stillOff, "redial: the change and AT+CFUN=1 both refused")
            rig.finish("refused, CFUN=1 refused", opens: 1)
        }
        do {
            // The reopen finds interface 3 busy (the window's read or another verb took it in the gap): it is
            // tried again every 0.5 s (ruling R22); busy twice, then it opens and the radio is back on.
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet),
                                                                          ("AT+CFUN=1", timedOut)])),
                           .failure(.busy), .failure(.busy),
                           .success(ScriptedPort("port 2", [("AT+CFUN=1", ok)] + registered))])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "reopen busy twice")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet,
                                          redial: .done(RadioChange(on: true, registration: homeSA, secondsToRegister: 0))),
                  "redial: a reopen busy twice, then open: the radio is back on", "\(String(describing: change))")
            check(rig.sleeps == [1, 0.5, 0.5], "redial: 0.5 s between the busy reopens", "\(rig.sleeps)")
            rig.finish("reopen busy twice", opens: 4)
        }
        do {
            // Busy for 15 s: the opens at 0, 0.5, …, 15 s of fake time (31), then the radio is left off, busy.
            let busy = [Result<ScriptedPort, AtError>](repeating: .failure(.busy), count: 31)
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet),
                                                                          ("AT+CFUN=1", timedOut)]))] + busy)
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "reopen busy for 15 s")
            check(change?.redial == .radioLeftOff(describe(.busy)), "redial: busy for 15 s leaves the radio off, and says why",
                  "\(String(describing: change))")
            check(rig.sleeps == [1] + Array(repeating: 0.5, count: 30), "redial: thirty waits of 0.5 s", "\(rig.sleeps)")
            rig.finish("reopen busy for 15 s", opens: 32)
        }
        do {
            // A clock that stands still cannot keep the retries going: at most 30 more opens.
            let busy = [Result<ScriptedPort, AtError>](repeating: .failure(.busy), count: 31)
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet),
                                                                          ("AT+CFUN=1", timedOut)]))] + busy)
            rig.sleepMovesClock = false
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "reopen busy, clock still")
            check(change?.redial == .radioLeftOff(describe(.busy)), "redial: busy with a still clock ends", "\(String(describing: change))")
            rig.finish("reopen busy, clock still", opens: 32)
        }
        do {
            // A reopen that fails otherwise is not tried again.
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet),
                                                                          ("AT+CFUN=1", timedOut)])),
                           .failure(.modemNotAttached)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "reopen fails")
            check(change?.redial == .radioLeftOff(describe(.modemNotAttached)) && rig.sleeps == [1],
                  "redial: a reopen that fails but not busy is not retried", "\(String(describing: change)) \(rig.sleeps)")
            rig.finish("reopen fails", opens: 2)
        }
        do {
            // The change times out and AT+CFUN=1 fails on the second port too.
            let rig = Rig(redialStart + [(setCmnet, timedOut)], [("AT+CFUN=1", ioError)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "unknown, radio still off")
            check(message.hasPrefix("It is not known whether profile 1 was changed. The modem did not answer in time. "
                                    + "The radio is still off. An I/O error occurred") && message.hasSuffix(stillOff),
                  "redial: not known, and the radio still off", message)
            rig.finish("unknown, radio still off", opens: 2)
        }
        do {
            // AT+CFUN=1 refused by the modem on a working port: no second port; the radio is left off.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", cme(3))])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=1 refused")
            check(change?.redial == .radioLeftOff("The modem refused the command (+CME ERROR: 3)."),
                  "redial: AT+CFUN=1 refused leaves the radio off, with the reason", "\(String(describing: change))")
            rig.finish("CFUN=1 refused", opens: 1)
        }
        do {
            // AT+CFUN=4 times out: whether the radio went off is not known; it is switched on again on a new port.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", timedOut)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 times out")
            expectEqual(message, "The radio could not be switched off for the redial. The modem did not answer in time. "
                        + "Nothing was changed. The radio is on.", "redial: AT+CFUN=4 timing out changes nothing and switches the radio on")
            check(!rig.allLines.contains(setCmnet), "redial: AT+CFUN=4 timing out: no change sent")
            rig.finish("CFUN=4 times out", opens: 2)
        }
        do {
            // AT+CFUN=4 times out and the radio cannot be switched on: it may be off.
            let rig = Rig([.success(ScriptedPort("port 1", [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", timedOut)])),
                           .failure(.modemNotAttached)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 times out, no port")
            expectEqual(message, "The radio could not be switched off for the redial. The modem did not answer in time. "
                        + "Nothing was changed, but the radio may be off. \(describe(.modemNotAttached)) \(stillOff)",
                        "redial: AT+CFUN=4 timing out and no second port")
            rig.finish("CFUN=4 times out, no port", opens: 2)
        }
        do {
            // The password is in no failure, also when the change fails in the middle of a redial.
            let rig = Rig(redialStart + [(setWithSecret, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"cmnet\",\"u\",\"\",1"])),
                                         ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: withSecret, redial: true), "redial, password not kept")
            check(!message.contains(secret), "redial: no password in the failure", message)
            check(message.contains("Its password is not the one sent."), "redial: a dropped password is said", message)
            check(rig.allLines.filter { $0.contains(secret) } == [setWithSecret], "redial: the password only in the change line")
            rig.finish("redial, password not kept", opens: 1)
        }
    }

    // A profile change that fails after its line may have reached the modem carries the settings before, so
    // that the CLI and the window can say how to put them back (ruling R19): the write times out, the
    // read-back differs, or the read-back times out, fails or gives no settings; with or without a redial.
    // Not when nothing was sent (or the modem refused the change itself: nothing was changed).
    static func profileWayBack() {
        let differs: Answer = .success(["+QICSGP: 3,\"x\",\"\",\"\",0"])
        for (name, script, opens) in [
            ("no redial: the write times out", [("AT+QICSGP=1", qicsgp1), (setCmnet, timedOut)], [[(String, Answer)]]()),
            ("no redial: the read-back differs", [("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", differs)], []),
            ("no redial: the read-back times out", [("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", timedOut)], []),
            ("no redial: the read-back's I/O error", [("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", ioError)], []),
            ("no redial: the read-back gives no settings", [("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", ok)], []),
            ("redial: the write times out", redialStart + [(setCmnet, timedOut)], [[("AT+CFUN=1", ok)] + registered]),
            ("redial: the read-back differs", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", differs), ("AT+CFUN=1", ok)] + registered, []),
            ("redial: the read-back times out", redialStart + [(setCmnet, ok), ("AT+QICSGP=1", timedOut)],
             [[("AT+CFUN=1", ok)] + registered]),
            ("redial: the write times out and the radio stays off", redialStart + [(setCmnet, timedOut)], [[("AT+CFUN=1", timedOut)]]),
        ] {
            let redial = name.hasPrefix("redial")
            let rig = Rig(([script] + opens).enumerated().map { .success(ScriptedPort("port \($0.offset + 1)", $0.element)) })
            let failure = failureOf(rig.service.setProfile(1, to: cmnet, redial: redial), name)
            check(failure.profileBefore == profile1, "way back: \(name): the failure holds the settings before",
                  "\(String(describing: failure.profileBefore)) | \(failure.message)")
            rig.finish("way back: \(name)", opens: 1 + opens.count)
        }

        // Nothing sent, or the change refused by the modem: no way back is needed.
        let refusedChange: [(String, Answer)] = [("AT+QICSGP=1", qicsgp1), (setCmnet, cme(3))]
        for (name, opens, settings, redial, count) in [
            ("a refused AT+CFUN=4", [Result<ScriptedPort, AtError>.success(ScriptedPort("port 1", [("AT+QICSGP=1", qicsgp1),
                ("AT+CFUN?", cfunOn), ("AT+CFUN=4", cme(3))]))], cmnet, true, 1),
            ("AT+CFUN=4 timing out", [.success(ScriptedPort("port 1", [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn),
                ("AT+CFUN=4", timedOut)])), .success(ScriptedPort("port 2", [("AT+CFUN=1", ok)] + registered))], cmnet, true, 2),
            ("a profileProblem refusal", [], ProfileSettings(type: .ipv4v6, apn: "a b", user: "", password: "", auth: .none), true, 0),
            ("a failed before-read", [.success(ScriptedPort("port 1", [("AT+QICSGP=1", timedOut)]))], cmnet, true, 1),
            ("a failed open", [.failure(.busy)], cmnet, true, 1),
            ("the radio's state not read", [.success(ScriptedPort("port 1", [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", ok)]))],
             cmnet, true, 1),
            ("the change refused, no redial", [.success(ScriptedPort("port 1", refusedChange))], cmnet, false, 1),
            ("the change refused in a redial", [.success(ScriptedPort("port 1", redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", ok)]
                + registered))], cmnet, true, 1),
        ] {
            let rig = Rig(opens)
            let failure = failureOf(rig.service.setProfile(1, to: settings, redial: redial), name)
            check(failure.profileBefore == nil, "way back: \(name): no settings before in the failure",
                  "\(String(describing: failure.profileBefore)) | \(failure.message)")
            rig.finish("way back: \(name)", opens: count)
        }

        // A password before is kept in memory for the put-back, and shown by no string conversion.
        let rig = Rig([("AT+QICSGP=1", qicsgpWithSecret), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", ok), (setCmnet, timedOut)],
                      [("AT+CFUN=1", ok)] + registered)
        let failure = failureOf(rig.service.setProfile(1, to: cmnet, redial: true), "way back with a password")
        check(failure.profileBefore == withSecret, "way back: the settings before, password included",
              "\(String(describing: failure.profileBefore))")
        var dumped = ""
        dump(failure, to: &dumped)
        let error: Error = failure
        for (text, how) in [(String(describing: failure), "String(describing:)"), (String(reflecting: failure), "String(reflecting:)"),
                            ("\(failure)", "interpolation"), (dumped, "dump"), (error.localizedDescription, "localizedDescription"),
                            (String(reflecting: failure.profileBefore), "String(reflecting:) of profileBefore")] {
            check(!text.contains(secret), "way back: \(how) of the failure does not show the password",
                  text.replacingOccurrences(of: secret, with: "<the password>"))
        }
        check(dumped.contains("passwordSet"), "way back: a dump shows only whether a password is set", dumped)
        rig.finish("way back with a password", opens: 2)
    }

    // MARK: sim

    static func sim() {
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3)), ("AT+CLCK=\"SC\",2", clckOff), ("AT+QUIMSLOT?", slot1)])
            let got = success(rig.service.sim(), "sim")
            check(got == SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10, activeSlot: 1), "sim: the READY fixture",
                  "\(String(describing: got))")
            expectLines(rig.port(1).lines, simLines, "sim: the four reads")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "sim: each read has 3 s")
            rig.finish("sim", opens: 1)
        }
        do {
            // AT+CPIN?'s error line is a state.
            let rig = Rig([("AT+CPIN?", cme(10)), ("AT+QPINC?", cme(10)), ("AT+CLCK=\"SC\",2", cme(10)), ("AT+QUIMSLOT?", slot1)])
            let got = success(rig.service.sim(), "sim, no SIM")
            check(got == SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil, activeSlot: 1),
                  "sim: +CME ERROR: 10 is not inserted; the refused reads are nil", "\(String(describing: got))")
            rig.finish("sim, no SIM", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", ok)])
            let message = failureMessage(rig.service.sim(), "sim, no CPIN line")
            expectEqual(message, "The modem did not say what state the SIM is in.", "sim: an answer without +CPIN fails")
            rig.finish("sim, no CPIN line", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", timedOut)])
            let got = success(rig.service.sim(), "sim, QPINC times out")
            check(got == SimInfo(state: .ready, pinLock: nil, pinAttempts: nil, pukAttempts: nil),
                  "sim: a timeout after the state leaves the rest nil, and nothing more is sent", "\(String(describing: got))")
            rig.finish("sim, QPINC times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", timedOut)])
            let message = failureMessage(rig.service.sim(), "sim, CPIN times out")
            expectEqual(message, "The SIM's state could not be read. The modem did not answer in time.", "sim: a timeout on AT+CPIN?")
            rig.finish("sim, CPIN times out", opens: 1)
        }
    }

    // MARK: enterPin

    static func pinEntry() {
        var messages: [String] = []
        var allSent: [String] = []
        func done(_ rig: Rig, _ name: String, opens: Int) {
            allSent += rig.allLines
            rig.finish(name, opens: opens)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, ready")
            expectEqual(message, "The SIM does not ask for a PIN (ready). Nothing was sent.", "enterPin: READY sends nothing")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: READY: only the reads")
            messages.append(message)
            done(rig, "pin, ready", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", .success(["+CPIN: SIM PUK"])), ("AT+QPINC?", qpinc(0, 10))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, puk")
            expectEqual(message, "The SIM does not ask for a PIN (blocked: needs its PUK from the carrier). Nothing was sent.",
                        "enterPin: SIM PUK sends nothing")
            messages.append(message)
            done(rig, "pin, puk", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(2))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, attempts changed")
            expectEqual(message, "The attempts left changed to 2 since they were shown. Nothing was sent; check and enter the PIN again.",
                        "enterPin: 2 attempts when 3 were shown sends nothing")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: attempts changed: only the reads")
            messages.append(message)
            done(rig, "pin, attempts changed", opens: 1)
        }
        for shown in [0, 3] {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(0))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: shown), "pin, 0 attempts (\(shown) shown)")
            check(message.contains("Nothing was sent"), "enterPin: 0 attempts left (\(shown) shown) sends nothing", message)
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: 0 attempts: only the reads")
            messages.append(message)
            done(rig, "pin, 0 attempts (\(shown) shown)", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", cme(3))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, attempts unknown")
            expectEqual(message, "The attempts left could not be read; RMNet does not send a PIN without them. Nothing was sent.",
                        "enterPin: unknown attempts send nothing")
            messages.append(message)
            done(rig, "pin, attempts unknown", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", timedOut)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, QPINC times out")
            check(message.hasSuffix("Nothing was sent."), "enterPin: a timeout on AT+QPINC? sends nothing", message)
            messages.append(message)
            done(rig, "pin, QPINC times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cme(13)), ("AT+QPINC?", cme(13))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, SIM failure")
            expectEqual(message, "The SIM does not ask for a PIN (SIM failure). Nothing was sent.",
                        "enterPin: AT+CPIN?'s error line is the state")
            messages.append(message)
            done(rig, "pin, SIM failure", opens: 1)
        }
        for bad in ["12a4", "123", "123456789", ""] {
            let rig = Rig()
            let message = failureMessage(rig.service.enterPin(bad, shownAttempts: 3), "pin \(bad)")
            expectEqual(message, pinProblem(bad) ?? "(no problem)", "enterPin(\"\(bad)\"): refused before the port opens")
            done(rig, "pin \(bad)", opens: 0)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, ok),
                           ("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3)), ("AT+CLCK=\"SC\",2", clckOn), ("AT+QUIMSLOT?", slot1)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin accepted")
            check(outcome == PinOutcome(accepted: true, sim: SimInfo(state: .ready, pinLock: true, pinAttempts: 3, pukAttempts: 10, activeSlot: 1)),
                  "enterPin: OK is accepted, and the SIM is read again", "\(String(describing: outcome))")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?", pinLine] + simLines, "enterPin: the reads, the PIN, the three SIM reads")
            check(rig.port(1).timeout(of: pinLine) == 10, "enterPin: AT+CPIN=\"…\" has 10 s")
            check(!String(describing: outcome).contains(pin) && !String(reflecting: outcome).contains(pin),
                  "enterPin: the outcome does not hold the PIN")
            done(rig, "pin accepted", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, cme(16)),
                           ("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(2)), ("AT+CLCK=\"SC\",2", clckOn), ("AT+QUIMSLOT?", slot1)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin refused")
            check(outcome == PinOutcome(accepted: false, sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10, activeSlot: 1),
                                        refusal: "+CME ERROR: 16"),
                  "enterPin: +CME ERROR: 16 is not accepted, with the new attempts and the modem's line", "\(String(describing: outcome))")
            done(rig, "pin refused", opens: 1)
        }
        do {
            // Another error line (14: SIM busy) is kept as it is, for pinSentence (F10).
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, cme(14)),
                           ("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), ("AT+CLCK=\"SC\",2", clckOn), ("AT+QUIMSLOT?", slot1)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin, SIM busy")
            check(outcome == PinOutcome(accepted: false, sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 3, pukAttempts: 10, activeSlot: 1),
                                        refusal: "+CME ERROR: 14"),
                  "enterPin: +CME ERROR: 14 is not accepted, with the modem's line", "\(String(describing: outcome))")
            if let outcome {
                expectEqual(pinSentence(outcome), "The modem did not take the PIN (+CME ERROR: 14). 3 attempts left; check them "
                            + "before entering it again.", "enterPin: SIM busy is not said as a wrong PIN")
            }
            done(rig, "pin, SIM busy", opens: 1)
        }
        do {
            // The SIM read after the PIN fails: accepted, without the SIM.
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, ok), ("AT+CPIN?", timedOut)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin accepted, read fails")
            check(outcome == PinOutcome(accepted: true, sim: nil), "enterPin: the read after the PIN failing gives sim nil",
                  "\(String(describing: outcome))")
            done(rig, "pin accepted, read fails", opens: 1)
        }
        for (answer, word) in [(timedOut, "a timeout"), (ioError, "an I/O error")] {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, answer)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, \(word)")
            check(message.hasSuffix("It is not known whether the SIM took the PIN. "
                                    + "Check the attempts left (RMNet sim) before entering it again."),
                  "enterPin: \(word) after sending: not known", message)
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?", pinLine], "enterPin: \(word): nothing after the PIN")
            messages.append(message)
            done(rig, "pin, \(word)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, busy")
            expectEqual(message, "\(describe(.busy)) Nothing was sent.", "enterPin: a failed open sends nothing")
            messages.append(message)
            done(rig, "pin, busy", opens: 1)
        }
        // In every case: the PIN is in no failure, and in no line but the one AT+CPIN="…".
        for message in messages {
            check(!message.contains(pin), "enterPin: the PIN is in no failure", message)
        }
        check(allSent.filter { $0.contains(pin) }.allSatisfy { $0 == pinLine } && allSent.contains(pinLine),
              "enterPin: the PIN is in no line sent but AT+CPIN=\"…\"", linesText(allSent.filter { $0.contains(pin) }))
    }

    // MARK: antennas, cellLock, imei

    static func antennas() {
        do {
            let rig = Rig([
                ("AT+QRSRP", .success(["+QRSRP: -93,-110,-32768,-103,NR5G"])),
                ("AT+QRSRQ", .success(["+QRSRQ: -11,-16,-32768,-11,NR5G"])),
                ("AT+QSINR", .success(["+QSINR: 20,10,-32768,11,NR5G"])),
            ])
            let sets = success(rig.service.antennas(), "antennas: normal")
            check(sets?.count == 1 && sets?[0].ports[0].rsrp == -93 && sets?[0].ports[2].rsrp == nil,
                  "antennas: parsed 4 ports with sentinel filtering")
            rig.finish("antennas: normal", opens: 1)
        }
        do {
            let rig = Rig([("AT+QRSRP", timedOut), ("AT+QRSRQ", ok), ("AT+QSINR", ok)])
            _ = failureMessage(rig.service.antennas(), "antennas: timeout")
            expectLines(rig.port(1).lines, ["AT+QRSRP"], "antennas: stops after timeout")
        }
    }

    /// The SIM slot: read; changed with its read-back, the SIM read until it settles, and the registration when asked;
    /// nothing sent when it is already the slot; the background turn's short reads.
    static func simSlotChanges() {
        let slot2: Answer = .success(["+QUIMSLOT: 2"])
        do {
            let rig = Rig([("AT+QUIMSLOT?", slot2)])
            check(success(rig.service.simSlot(), "simSlot") == 2, "simSlot: read")
            rig.finish("simSlot", opens: 1)
        }
        do {
            let rig = Rig([("AT+QUIMSLOT?", .failure(.modem("ERROR")))])
            expectEqual(failureMessage(rig.service.simSlot(), "simSlot refused"),
                        "The modem does not switch SIM slots. The modem refused the command (ERROR).", "simSlot: refused")
            rig.finish("simSlot refused", opens: 1)
        }
        do {
            // Already on slot 2: nothing sent.
            let rig = Rig([("AT+QUIMSLOT?", slot2)])
            check(success(rig.service.setSimSlot(2, wait: .registration), "setSimSlot same") == SimSlotChange(before: 2, after: 2),
                  "setSimSlot: the same slot changes nothing")
            rig.finish("setSimSlot same", opens: 1)
        }
        do {
            // Switched; the SIM is busy, then ready; then registered.
            let rig = Rig([("AT+QUIMSLOT?", slot1), ("AT+QUIMSLOT=2", ok), ("AT+QUIMSLOT?", slot2),
                           ("AT+CPIN?", cme(14)), ("AT+CPIN?", cme(10)), ("AT+CPIN?", cpinReady)] + searching + registered)
            let change = success(rig.service.setSimSlot(2, wait: .registration), "setSimSlot")
            check(change == SimSlotChange(before: 1, after: 2, sim: .ready, secondsToSim: 2, registration: homeSA,
                                          secondsToRegister: 3), "setSimSlot: switched, the SIM ready, registered",
                  "\(String(describing: change))")
            check(rig.port(1).timeout(of: "AT+QUIMSLOT=2") == 5, "setSimSlot: the write has 5 s")
            rig.finish("setSimSlot", opens: 1)
        }
        do {
            // Waiting for the SIM only: no registration read.
            let rig = Rig([("AT+QUIMSLOT?", slot1), ("AT+QUIMSLOT=2", ok), ("AT+QUIMSLOT?", slot2), ("AT+CPIN?", cpinReady)])
            let change = success(rig.service.setSimSlot(2, wait: .sim), "setSimSlot sim only")
            check(change == SimSlotChange(before: 1, after: 2, sim: .ready, secondsToSim: 0), "setSimSlot: the SIM only",
                  "\(String(describing: change))")
            rig.finish("setSimSlot sim only", opens: 1)
        }
        do {
            // An empty slot: the SIM read for 15 s, then the change reported with it; no registration read.
            var script: [(String, Answer)] = [("AT+QUIMSLOT?", slot1), ("AT+QUIMSLOT=2", ok), ("AT+QUIMSLOT?", slot2)]
            script += Array(repeating: ("AT+CPIN?", cme(10)), count: 16)
            let rig = Rig(script)
            let change = success(rig.service.setSimSlot(2, wait: .registration), "setSimSlot empty")
            check(change?.sim == .notInserted && change?.secondsToSim == nil && change?.registration == nil
                    && change?.after == 2, "setSimSlot: an empty slot", "\(String(describing: change))")
            check(rig.elapsed >= 15 && rig.elapsed < 18, "setSimSlot: an empty slot is read for about 15 s", "\(rig.elapsed)")
            rig.finish("setSimSlot empty", opens: 1)
        }
        do {
            let rig = Rig([("AT+QUIMSLOT?", slot1), ("AT+QUIMSLOT=2", .failure(.modem("ERROR")))])
            expectEqual(failureMessage(rig.service.setSimSlot(2, wait: .sim), "setSimSlot refused"),
                        "The SIM slot was not changed. The modem refused the command (ERROR).", "setSimSlot: the write refused")
            rig.finish("setSimSlot refused", opens: 1)
        }
        do {
            let rig = Rig([("AT+QUIMSLOT?", slot1), ("AT+QUIMSLOT=2", ok), ("AT+QUIMSLOT?", slot1)])
            expectEqual(failureMessage(rig.service.setSimSlot(2, wait: .sim), "setSimSlot not taken"),
                        "The modem answered OK, but still uses SIM slot 1.", "setSimSlot: a read-back that differs")
            rig.finish("setSimSlot not taken", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            expectEqual(failureMessage(rig.service.setSimSlot(2, wait: .sim), "setSimSlot busy"),
                        "\(describe(.busy)) Nothing was changed.", "setSimSlot: busy")
            rig.finish("setSimSlot busy", opens: 1)
        }
        do {
            check(failureMessage(Rig().service.setSimSlot(3, wait: .sim), "slot 3")
                    == "The modem has SIM slots 1 and 2. Nothing was changed.", "setSimSlot: slot 3 refused before the port")
        }
        // An automatic switch's expectation, checked on the port that writes, before the write.
        func onModule(_ serial: String?, _ script: [(String, Answer)]) -> Rig {
            let port = ScriptedPort("port 1", script)
            port.deviceSerial = serial
            return Rig([.success(port)])
        }
        let watched = SimSlotExpectation(module: "c0ffee01", slot: 1)
        let radioOn: Answer = .success(["+CFUN: 1"])
        do {
            // All as expected: the module, slot 1, the radio on, no SIM: switched.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", radioOn), ("AT+CPIN?", cme(10)),
                                            ("AT+QUIMSLOT=2", ok), ("AT+QUIMSLOT?", slot2), ("AT+CPIN?", cpinReady)])
            let change = success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: holds")
            check(change == SimSlotChange(before: 1, after: 2, sim: .ready, secondsToSim: 0), "expect: holds, switched",
                  "\(String(describing: change))")
            rig.finish("expect: holds", opens: 1)
        }
        do {
            // Another module on the port: nothing more read, nothing written.
            let rig = onModule("0badbeef", [("AT+QUIMSLOT?", slot1)])
            let change = success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: another module")
            check(change == SimSlotChange(before: 1, after: 1, skipped: .otherModule), "expect: another module, not written",
                  "\(String(describing: change))")
            rig.finish("expect: another module", opens: 1)
        }
        do {
            // A module that gives no serial number: not known, so never taken for the one expected; not written.
            let rig = onModule(nil, [("AT+QUIMSLOT?", slot1)])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: no serial")?.skipped
                    == .moduleUnknown, "expect: no serial number on the port")
            rig.finish("expect: no serial", opens: 1)
        }
        do {
            // No serial number expected (none was known when the modem attached), even with one on the port: not
            // written, not known which module this is.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1)])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: SimSlotExpectation(module: nil, slot: 1)),
                          "expect: none expected")?.skipped == .moduleUnknown, "expect: no serial number expected")
            rig.finish("expect: none expected", opens: 1)
        }
        do {
            // Neither known: two modules not known are not the same one.
            let rig = onModule(nil, [("AT+QUIMSLOT?", slot1)])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: SimSlotExpectation(module: nil, slot: 1)),
                          "expect: neither")?.skipped == .moduleUnknown, "expect: neither module known, not written")
            rig.finish("expect: neither", opens: 1)
        }
        do {
            // The radio switched off meanwhile: not written.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", .success(["+CFUN: 4"]))])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: radio")?.skipped == .radioNotOn,
                  "expect: the radio not on")
            rig.finish("expect: radio", opens: 1)
        }
        do {
            // The radio not read: not written.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", .failure(.modem("ERROR")))])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: radio unread")?.skipped
                    == .radioNotOn, "expect: the radio not read")
            rig.finish("expect: radio unread", opens: 1)
        }
        do {
            // The SIM ready by now (it was slow to start): not written.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", radioOn), ("AT+CPIN?", cpinReady)])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: SIM")?.skipped == .simUsable,
                  "expect: a SIM usable now")
            rig.finish("expect: SIM", opens: 1)
        }
        do {
            // Still starting (busy) is not "unusable": not written, the SIM not told yet.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", radioOn), ("AT+CPIN?", cme(14))])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: busy")?.skipped == .simUnknown,
                  "expect: a SIM still starting")
            rig.finish("expect: busy", opens: 1)
        }
        do {
            // The SIM not read: not written, not told yet.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot1), ("AT+CFUN?", radioOn), ("AT+CPIN?", timedOut)])
            check(success(rig.service.setSimSlot(2, wait: .sim, expect: watched), "expect: SIM unread")?.skipped
                    == .simUnknown, "expect: the SIM not read")
        }
        do {
            // A switch back: checked as the try was, on the slot tried: the module, the slot, the radio and its SIM.
            let back = SimSlotExpectation(module: "c0ffee01", slot: 2)
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot2), ("AT+CFUN?", radioOn), ("AT+CPIN?", cme(10)),
                                            ("AT+QUIMSLOT=1", ok), ("AT+QUIMSLOT?", slot1),
                                            ("AT+CPIN?", cme(10))] + Array(repeating: ("AT+CPIN?", cme(10)), count: 15))
            let change = success(rig.service.setSimSlot(1, wait: .sim, expect: back), "expect: switch back")
            check(change?.changed == true && change?.after == 1 && change?.skipped == nil, "expect: the switch back written",
                  "\(String(describing: change))")
            rig.finish("expect: switch back", opens: 1)
        }
        do {
            // A switch back whose slot tried has just become ready: not written, that SIM is kept.
            let rig = onModule("c0ffee01", [("AT+QUIMSLOT?", slot2), ("AT+CFUN?", radioOn), ("AT+CPIN?", cpinReady)])
            check(success(rig.service.setSimSlot(1, wait: .sim, expect: SimSlotExpectation(module: "c0ffee01", slot: 2)),
                          "expect: back, ready")?.skipped == .simUsable, "expect: a switch back away from a ready SIM refused")
            rig.finish("expect: back, ready", opens: 1)
        }
        do {
            // A switch back on another module: not written.
            let rig = onModule("0badbeef", [("AT+QUIMSLOT?", slot2)])
            check(success(rig.service.setSimSlot(1, wait: .sim, expect: SimSlotExpectation(module: "c0ffee01", slot: 2)),
                          "expect: back, module")?.skipped == .otherModule, "expect: a switch back on another module refused")
            rig.finish("expect: back, module", opens: 1)
        }
        // The background turn: each command's lines, or the error line; one port.
        do {
            let rig = Rig([("AT+CPMS?", .success(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"])), ("AT+CPIN?", cme(10)),
                           ("AT+CFUN?", .success(["+CFUN: 1"]))])
            let answers = success(rig.service.shortReads(["AT+CPMS?", "AT+CPIN?", "AT+CFUN?"]), "shortReads")
            check(answers == [.lines(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"]), .refused("+CME ERROR: 10"),
                              .lines(["+CFUN: 1"])], "shortReads: lines and the error line", "\(String(describing: answers))")
            check(answers.map { $0[1] }.flatMap(simState) == .notInserted, "shortReads: the error line as a SIM state")
            rig.finish("shortReads", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPMS?", timedOut)])
            _ = failureMessage(rig.service.shortReads(["AT+CPMS?", "AT+CPIN?"]), "shortReads timeout")
            expectLines(rig.port(1).lines, ["AT+CPMS?"], "shortReads: stops at a timeout")
        }
        // A timeout after the first answer: the answers before it kept, nothing sent after it.
        do {
            let rig = Rig([("AT+CPMS?", .success(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"])), ("AT+CPIN?", timedOut)])
            let answers = success(rig.service.shortReads(["AT+CPMS?", "AT+CPIN?", "AT+CFUN?"]), "shortReads partial")
            check(answers == [.lines(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"])],
                  "shortReads: the answers before a timeout kept", "\(String(describing: answers))")
            expectLines(rig.port(1).lines, ["AT+CPMS?", "AT+CPIN?"], "shortReads: nothing sent after the timeout")
        }
        // An I/O error after the first answer: the same.
        do {
            let rig = Rig([("AT+CFUN?", .success(["+CFUN: 1"])), ("AT+CPIN?", .failure(.io(-536870208)))])
            let answers = success(rig.service.shortReads(["AT+CFUN?", "AT+CPIN?", "AT+QUIMSLOT?"]), "shortReads I/O")
            check(answers == [.lines(["+CFUN: 1"])], "shortReads: the answers before an I/O error kept")
            expectLines(rig.port(1).lines, ["AT+CFUN?", "AT+CPIN?"], "shortReads: nothing sent after the I/O error")
        }
    }

    static func cellLock() {
        let unlocked4g: Answer = .success(["+QNWLOCK: \"common/4g\",0"])
        let unlocked5g: Answer = .success(["+QNWLOCK: \"common/5g\",0"])
        let persistOff: Answer = .success(["+QNWLOCK: \"save_ctrl\",0,0"])
        let nr = NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)
        let locked5g: Answer = .success(["+QNWLOCK: \"common/5g\",147,520110,30,41"])

        do {
            let rig = Rig([
                ("AT+QNWLOCK=\"common/4g\"", unlocked4g),
                ("AT+QNWLOCK=\"common/5g\"", locked5g),
                ("AT+QNWLOCK=\"save_ctrl\"", persistOff),
                ("AT+QENG=\"neighbourcell\"", ok),
            ])
            let got = success(rig.service.cellLock(), "cellLock: read")
            check(got == CellLockState(lte: [], nr: nr, persistLte: false, persistNr: false, neighbours: []),
                  "cellLock: parsed", "\(String(describing: got))")
            rig.finish("cellLock: read", opens: 1)
        }
        do {
            let rig = Rig()
            _ = failureMessage(rig.service.setNrCellLock(NrCellLock(pci: 1008, arfcn: 520110, scsKHz: 30, band: 41)),
                               "setNrCellLock: invalid pci")
            rig.finish("setNrCellLock: invalid pci", opens: 0)
        }
        do {
            let rig = Rig([
                ("AT+QNWLOCK=\"common/4g\"", unlocked4g),
                ("AT+QNWLOCK=\"common/5g\"", unlocked5g),
                ("AT+QNWLOCK=\"save_ctrl\"", persistOff),
                ("AT+QNWPREFCFG=\"rf_band\"", .success(rfBandLines)),
                ("AT+QNWLOCK=\"common/5g\",147,520110,30,41", ok),
                ("AT+QNWLOCK=\"common/4g\"", unlocked4g),
                ("AT+QNWLOCK=\"common/5g\"", locked5g),
                ("AT+QNWLOCK=\"save_ctrl\"", persistOff),
            ])
            let ch = success(rig.service.setNrCellLock(nr), "setNrCellLock: lock")
            check(ch == .changed(before: CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false),
                                 after: CellLockState(lte: [], nr: nr, persistLte: false, persistNr: false)),
                  "setNrCellLock: locked and verified")
            rig.finish("setNrCellLock: lock", opens: 1)
        }
        do {
            let rig = Rig([
                ("AT+QNWLOCK=\"common/4g\"", unlocked4g),
                ("AT+QNWLOCK=\"common/5g\"", unlocked5g),
                ("AT+QNWLOCK=\"save_ctrl\"", persistOff),
            ])
            let ch = success(rig.service.setNrCellLock(nil), "setNrCellLock: already unlocked")
            check(ch == .unchanged(CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)),
                  "setNrCellLock: already unlocked writes nothing")
            rig.finish("setNrCellLock: already unlocked", opens: 1)
        }
        cellInUse()
    }

    /// Locking to a cell in use: the serving cell and the carriers read in the session that writes the lock; a cell
    /// that changed since, or a 5G SA cell whose subcarrier spacing is not known, writes nothing.
    static func cellInUse() {
        let unlocked4g: Answer = .success(["+QNWLOCK: \"common/4g\",0"])
        let unlocked5g: Answer = .success(["+QNWLOCK: \"common/5g\",0"])
        let persistOff: Answer = .success(["+QNWLOCK: \"save_ctrl\",0,0"])
        let locked5g: Answer = .success(["+QNWLOCK: \"common/5g\",147,520110,30,41"])
        // A 5G SA serving cell n41 PCI 147 ARFCN 520110, its SCS code 1 (30 kHz), or "-" (not given).
        let saServing: Answer = .success(["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",310,260,00A1B2C3D,147,001A2B,520110,41,12,-92,-11,20,1,-"])
        let saNoScs: Answer = .success(["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",310,260,00A1B2C3D,147,001A2B,520110,41,12,-92,-11,20,-,-"])
        let otherSa: Answer = .success(["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",310,260,00A1B2C3D,186,001A2B,520110,41,12,-92,-11,20,1,-"])
        let lteServing: Answer = .success(["+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",310,260,0ABC123,128,66786,66,5,5,5A0B,-95,-11,-65,15,9,-,-"])
        let qca: Answer = .success(["+QCAINFO: \"PCC\",520110,12,\"NR5G BAND 41\",147"])
        let nr = NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)
        let writeNr: [(String, Answer)] = [
            ("AT+QNWLOCK=\"common/4g\"", unlocked4g), ("AT+QNWLOCK=\"common/5g\"", unlocked5g),
            ("AT+QNWLOCK=\"save_ctrl\"", persistOff), ("AT+QNWPREFCFG=\"rf_band\"", .success(rfBandLines)),
            ("AT+QNWLOCK=\"common/5g\",147,520110,30,41", ok),
            ("AT+QNWLOCK=\"common/4g\"", unlocked4g), ("AT+QNWLOCK=\"common/5g\"", locked5g),
            ("AT+QNWLOCK=\"save_ctrl\"", persistOff),
        ]
        let open = CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)

        // `cell lock current`: the serving 5G SA cell with the SCS the modem gives, read and locked in one session.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", saServing), ("AT+QCAINFO", qca)] + writeNr)
            let ch = success(rig.service.lockCellInUse(.serving(scsKHz: nil)), "lockCellInUse: the serving cell")
            check(ch == .changed(before: open, after: CellLockState(lte: [], nr: nr, persistLte: false, persistNr: false)),
                  "lockCellInUse: the serving 5G SA cell locked")
            rig.finish("lockCellInUse: the serving cell", opens: 1)
        }
        // No SCS given by the modem, none given by the owner: refused, nothing written (no guess).
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", saNoScs), ("AT+QCAINFO", qca)])
            expectEqual(failureMessage(rig.service.lockCellInUse(.serving(scsKHz: nil)), "lockCellInUse: no SCS"),
                        "The modem does not report the subcarrier spacing of its serving 5G SA cell (n41, PCI 147, "
                        + "ARFCN 520110); give it with --scs (15, 30, 60, 120 or 240 kHz). Nothing was changed.",
                        "lockCellInUse: no SCS, refused")
            rig.finish("lockCellInUse: no SCS", opens: 1)
        }
        // The owner's SCS when the modem gives none.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", saNoScs), ("AT+QCAINFO", qca)] + writeNr)
            _ = success(rig.service.lockCellInUse(.serving(scsKHz: 30)), "lockCellInUse: --scs")
            rig.finish("lockCellInUse: --scs", opens: 1)
        }
        // The owner's SCS that is not the one the modem gives: refused.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", saServing), ("AT+QCAINFO", qca)])
            expectEqual(failureMessage(rig.service.lockCellInUse(.serving(scsKHz: 15)), "lockCellInUse: SCS differs"),
                        "The modem reports a subcarrier spacing of 30 kHz for its serving 5G SA cell, not 15 kHz. "
                        + "Nothing was changed.", "lockCellInUse: a different SCS refused")
            rig.finish("lockCellInUse: SCS differs", opens: 1)
        }
        // An SCS that is no spacing: refused before the port.
        do {
            let rig = Rig()
            _ = failureMessage(rig.service.lockCellInUse(.serving(scsKHz: 45)), "lockCellInUse: 45 kHz")
            rig.finish("lockCellInUse: 45 kHz", opens: 0)
        }
        // The window's cell, still the serving cell: locked.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", saServing), ("AT+QCAINFO", qca)] + writeNr)
            _ = success(rig.service.lockCellInUse(.nr(nr)), "lockCellInUse: the window's cell")
            rig.finish("lockCellInUse: the window's cell", opens: 1)
        }
        // The window's cell, gone since it was read (another PCI serves now): nothing written.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", otherSa), ("AT+QCAINFO", .success([]))])
            expectEqual(failureMessage(rig.service.lockCellInUse(.nr(nr)), "lockCellInUse: cell gone"),
                        "The modem no longer uses that 5G SA cell (n41, PCI 147, ARFCN 520110). Nothing was changed.",
                        "lockCellInUse: a cell no longer in use, refused")
            rig.finish("lockCellInUse: cell gone", opens: 1)
        }
        // The serving LTE cell (`cell lock current` on LTE).
        do {
            let lteCell = LteLockedCell(earfcn: 66786, pci: 128)
            let rig = Rig([("AT+QENG=\"servingcell\"", lteServing), ("AT+QCAINFO", .success([])),
                           ("AT+QNWLOCK=\"common/4g\"", unlocked4g), ("AT+QNWLOCK=\"common/5g\"", unlocked5g),
                           ("AT+QNWLOCK=\"save_ctrl\"", persistOff), ("AT+QNWLOCK=\"common/4g\",1,66786,128", ok),
                           ("AT+QNWLOCK=\"common/4g\"", .success(["+QNWLOCK: \"common/4g\",1,66786,128"])),
                           ("AT+QNWLOCK=\"common/5g\"", unlocked5g), ("AT+QNWLOCK=\"save_ctrl\"", persistOff)])
            let ch = success(rig.service.lockCellInUse(.serving(scsKHz: nil)), "lockCellInUse: LTE")
            check(ch == .changed(before: open, after: CellLockState(lte: [lteCell], nr: nil, persistLte: false, persistNr: false)),
                  "lockCellInUse: the serving LTE cell locked")
            rig.finish("lockCellInUse: LTE", opens: 1)
        }
        // The serving-cell read times out: nothing more sent, nothing written.
        do {
            let rig = Rig([("AT+QENG=\"servingcell\"", timedOut)])
            _ = failureMessage(rig.service.lockCellInUse(.serving(scsKHz: nil)), "lockCellInUse: timeout")
            expectLines(rig.port(1).lines, ["AT+QENG=\"servingcell\""], "lockCellInUse: nothing after the timeout")
        }
    }

    static func imei() {
        let first = "000000000000091"
        let next = "000000000000141"
        let readFirst: Answer = .success(["+EGMR: \"\(first)\""])
        let readNext: Answer = .success(["+EGMR: \"\(next)\""])

        do {
            let rig = Rig([("AT+EGMR=0,7", readFirst)])
            check(success(rig.service.imei(), "imei: read") == first, "imei: reads 15 digits")
            rig.finish("imei: read", opens: 1)
        }
        do {
            let rig = Rig()
            let msg = failureMessage(rig.service.setImei("000000000000142", reboot: true), "imei: invalid luhn")
            check(msg.contains("check digit"), "imei: invalid luhn opens no port", msg)
            rig.finish("imei: invalid luhn", opens: 0)
        }
        do {
            let rig = Rig([("AT+EGMR=0,7", readFirst)])
            check(success(rig.service.setImei(first, reboot: true), "imei: unchanged") == .unchanged(first),
                  "imei: unchanged short-circuits")
            rig.finish("imei: unchanged", opens: 1)
        }
        do {
            let rig = Rig([
                ("AT+EGMR=0,7", readFirst),
                ("AT+EGMR=1,7,\"\(next)\"", ok),
                ("AT+EGMR=0,7", readNext),
            ])
            let ch = success(rig.service.setImei(next, reboot: false), "imei: no reboot")
            check(ch == .setTakesEffectAfterRestart(before: first, after: next), "imei: set without reboot")
            rig.finish("imei: no reboot", opens: 1)
        }
        do {
            let rig = Rig([
                ("AT+EGMR=0,7", readFirst),
                ("AT+EGMR=1,7,\"\(next)\"", ok),
                ("AT+EGMR=0,7", readNext),
                ("AT+CFUN=1,1", ok),
            ])
            let ch = success(rig.service.setImei(next, reboot: true), "imei: with reboot")
            check(ch == .rebooting(before: first, after: next), "imei: set with reboot")
            rig.finish("imei: with reboot", opens: 1)
        }
        // The restart refused or not answered after the IMEI was written and read back: a success with that said (the
        // write and the restart are apart).
        do {
            let rig = Rig([("AT+EGMR=0,7", readFirst), ("AT+EGMR=1,7,\"\(next)\"", ok), ("AT+EGMR=0,7", readNext),
                           ("AT+CFUN=1,1", .failure(.modem("ERROR")))])
            let ch = success(rig.service.setImei(next, reboot: true), "imei: restart refused")
            check(ch == .restartFailed(before: first, after: next, sentence: "The IMEI is now \(next), but the modem was not "
                                       + "restarted. The modem refused the command (ERROR). It takes effect at the next "
                                       + "restart (AT+CFUN=1,1 or a replug)."), "imei: restart refused, written",
                  "\(String(describing: ch))")
            rig.finish("imei: restart refused", opens: 1)
        }
        do {
            let rig = Rig([("AT+EGMR=0,7", readFirst), ("AT+EGMR=1,7,\"\(next)\"", ok), ("AT+EGMR=0,7", readNext),
                           ("AT+CFUN=1,1", timedOut)])
            let ch = success(rig.service.setImei(next, reboot: true), "imei: restart not answered")
            if case .restartFailed(let b, let a, let sentence)? = ch {
                check(b == first && a == next && sentence.contains("It is not known whether the modem is restarting."),
                      "imei: restart not answered, written", sentence)
            } else {
                check(false, "imei: restart not answered, written", "\(String(describing: ch))")
            }
        }
        // The change's own port open: the module it is on and the IMEI before go back with the outcome. With what the
        // change was confirmed for, another module (or one with no serial number) is refused before anything is read,
        // and another IMEI before anything is written.
        func onModule(_ serial: String?, _ script: [(String, Answer)]) -> Rig {
            let port = ScriptedPort("port 1", script)
            port.deviceSerial = serial
            return Rig([.success(port)])
        }
        let confirmed = ImeiExpectation(module: "TESTMODULE1", before: first)
        do {
            let rig = onModule("TESTMODULE1", [("AT+EGMR=0,7", readFirst), ("AT+EGMR=1,7,\"\(next)\"", ok),
                                               ("AT+EGMR=0,7", readNext)])
            let write = rig.service.setImei(next, reboot: false, expect: nil)
            check(write == ImeiWrite(outcome: .success(.setTakesEffectAfterRestart(before: first, after: next)),
                                     module: "TESTMODULE1", before: first), "imei: the session's module and IMEI before",
                  "\(write)")
            rig.finish("imei: session", opens: 1)
        }
        do {
            let rig = onModule("TESTMODULE2", [])
            let write = rig.service.setImei(next, reboot: true, expect: confirmed)
            check(write.outcome.failureText?.contains("not the module this change was confirmed for") == true
                    && write.outcome.failureText?.hasSuffix("Nothing was changed.") == true,
                  "imei: another module refused", "\(write)")
            check(write.module == "TESTMODULE2" && write.before == nil, "imei: refused before the IMEI read", "\(write)")
            rig.finish("imei: another module", opens: 1)
        }
        do {
            let rig = onModule(nil, [])
            let write = rig.service.setImei(next, reboot: true, expect: confirmed)
            check(write.outcome.failureText?.contains("this one has none") == true, "imei: no serial number, refused",
                  "\(write)")
            rig.finish("imei: no serial number", opens: 1)
        }
        do {
            // The IMEI changed since the question (another tool): nothing written.
            let rig = onModule("TESTMODULE1", [("AT+EGMR=0,7", .success(["+EGMR: \"123456789012347\""]))])
            let write = rig.service.setImei(next, reboot: true, expect: confirmed)
            check(write.outcome.failureText == "The modem's IMEI is 123456789012347 now, not \(first) as when the change "
                  + "was confirmed. Nothing was changed.", "imei: another IMEI, refused", "\(write)")
            check(write.before == "123456789012347", "imei: the IMEI before as read", "\(write)")
            rig.finish("imei: another IMEI", opens: 1)
        }
        do {
            let rig = onModule("TESTMODULE1", [("AT+EGMR=0,7", readFirst), ("AT+EGMR=1,7,\"\(next)\"", ok),
                                               ("AT+EGMR=0,7", readNext), ("AT+CFUN=1,1", ok)])
            let write = rig.service.setImei(next, reboot: true, expect: confirmed)
            check(write.outcome == .success(.rebooting(before: first, after: next)), "imei: as confirmed, written",
                  "\(write)")
            rig.finish("imei: as confirmed", opens: 1)
        }
        do {
            // The IMEI and the module read for the question: one port open.
            let rig = onModule("TESTMODULE1", [("AT+EGMR=0,7", readFirst)])
            check(success(rig.service.imeiReading(), "imei: reading") == ImeiReading(imei: first, module: "TESTMODULE1"),
                  "imei: the IMEI and the module read together")
            rig.finish("imei: reading", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let write = rig.service.setImei(next, reboot: true, expect: nil)
            check(write.module == nil && write.before == nil && write.outcome.failureText != nil,
                  "imei: a port that does not open: nothing known", "\(write)")
            rig.finish("imei: busy", opens: 1)
        }
        do {
            // The IMEI read fails on the session: the module known, the IMEI before not.
            let rig = onModule("TESTMODULE1", [("AT+EGMR=0,7", .failure(.modem("ERROR")))])
            let write = rig.service.setImei(next, reboot: true, expect: nil)
            check(write.module == "TESTMODULE1" && write.before == nil && write.outcome.failureText != nil,
                  "imei: the read failed, the module known", "\(write)")
            rig.finish("imei: read failed", opens: 1)
        }
    }
}

extension Result where Failure == ModemFailure {
    var failureText: String? {
        if case .failure(let f) = self { return f.message }
        return nil
    }
}
