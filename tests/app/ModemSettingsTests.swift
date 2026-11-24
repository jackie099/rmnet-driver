// Tests for app/ModemSettings.swift: reading the modem's data profiles and SIM state, the checks of what
// the owner types (network mode, APN, user name, password, PIN), the AT lines that change the modem, the
// questions asked before a change and the sentences said after it, the JSON, and that a profile's
// password shows in no string conversion of any value. The fixtures are the modem's real answers
// (2026-11-15, firmware RM520NGLAAR03A04M4G_01.204.01.204). Built with swiftc by `make app-test`
// together with app/ModemNetwork.swift; needs no Xcode project and no hardware.
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

// --- the modem's answers ------------------------------------------------------------------------
let cgdcont = [
    "+CGDCONT: 1,\"IPV4V6\",\"\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 3,\"IPV4V6\",\"CMNET\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 4,\"IPV4V6\",\"CMWAP\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 5,\"IPV4V6\",\"SOS\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,1,,,,,,,,,,\"\",,,,0",
]
let qicsgp1 = ["+QICSGP: 3,\"\",\"\",\"\",0"]
let qicsgp3 = ["+QICSGP: 3,\"CMNET\",\"\",\"\",0"]
let qicsgpTest = ["+QICSGP: (1-16),(1-3),<APN>,<username>,<password>,(0-3)"]
let cpinReady = ["+CPIN: READY"]
let qpinc = ["+QPINC: \"SC\",3,10", "+QPINC: \"P2\",3,10"]
let clckOff = ["+CLCK: 0"]

let profile1 = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
let profile3 = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "", password: "", auth: .none)
let cmnetPap = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "u", password: "p", auth: .pap)
let cmnetPapWords = "IPV4V6, APN \"cmnet\", PAP, user \"u\", password set"

// The redaction rules' settings: a distinctive password that no text may contain.
let secret = "hunter2-secret"
let secretSettings = ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: secret, auth: .pap)

let homeSA = Registration(status: .home, domain: "5GS")
let readySim = SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10)

func rowsText(_ rows: [(label: String, value: String)]) -> String {
    rows.map { "\($0.label): \($0.value)" }.joined(separator: " | ")
}

func expectRows(_ got: [(label: String, value: String)], _ want: [(String, String)], _ name: String) {
    let same = got.count == want.count && zip(got, want).allSatisfy { $0.label == $1.0 && $0.value == $1.1 }
    check(same, "simRows: \(name)", "want \(rowsText(want.map { (label: $0.0, value: $0.1) }))\n  got  \(rowsText(got))")
}

func expectEqual(_ got: String, _ want: String, _ name: String) {
    check(got == want, name, "want \"\(want)\"\n  got  \"\(got)\"")
}

func dumped<T>(_ value: T) -> String {
    var text = ""
    dump(value, to: &text)
    return text
}

/// The JSON as a script reads it: compact, keys sorted.
func jsonText(_ object: [String: Any], _ name: String) -> String {
    check(JSONSerialization.isValidJSONObject(object), "\(name) is a valid JSON object", "\(object)")
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        check(false, "\(name) serializes")
        return ""
    }
    return text
}

/// No text may hold the password; a failure shows the text with the password masked.
func expectNoSecret(_ text: String, _ name: String) {
    check(!text.contains(secret), "redaction: \(name)",
          text.replacingOccurrences(of: secret, with: "<the password>"))
}

/// Pins the protocol's shape: a service with no modem.
struct NoModem: ModemServing {
    let failure = ModemFailure(message: "The modem is not attached.")
    func networkInfo() -> Result<NetworkInfo, ModemFailure> { .failure(failure) }
    func antennas() -> Result<[AntennaSignalSet], ModemFailure> { .failure(failure) }
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> { .failure(failure) }
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> { .failure(failure) }
    func profiles() -> Result<[DataProfile], ModemFailure> { .failure(failure) }
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        .failure(failure)
    }
    func sim() -> Result<SimInfo, ModemFailure> { .failure(failure) }
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> { .failure(failure) }
    func usbMode() -> Result<UsbModeInfo, ModemFailure> { .failure(failure) }
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> { .failure(failure) }
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> { .failure(failure) }
    func bands() -> Result<[BandSet], ModemFailure> { .failure(failure) }
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> { .failure(failure) }
    func cellLock() -> Result<CellLockState, ModemFailure> { .failure(failure) }
    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure> { .failure(failure) }
    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure> { .failure(failure) }
    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure> { .failure(failure) }
    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure> { .failure(failure) }
    func imei() -> Result<String, ModemFailure> { .failure(failure) }
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite { ImeiWrite(outcome: .failure(failure)) }
    func simSlot() -> Result<Int, ModemFailure> { .failure(failure) }
    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure> {
        .failure(failure)
    }
}

@main
struct ModemSettingsTests {
    static func main() {
        // --- the values -----------------------------------------------------------------------
        check(PdpType.allCases.map { $0.rawValue } == [1, 2, 3], "PdpType: AT+QICSGP context types 1, 2, 3")
        check(AuthMethod.allCases.map { $0.rawValue } == [0, 1, 2, 3], "AuthMethod: AT+QICSGP authentication 0 to 3")
        let service: ModemServing = NoModem()
        check(service.sim() == .failure(ModemFailure(message: "The modem is not attached.")),
              "ModemServing: a service answers with a ModemFailure")
        let failure: Error = ModemFailure(message: "x")
        check((failure as? ModemFailure)?.message == "x", "ModemFailure: is an Error")
        check(ModemFailure(message: "x").atKind == nil && ModemFailure(message: "ERROR", atKind: .modemError).atKind == .modemError,
              "ModemFailure: atKind is nil unless given (only `at` gives it)")
        let notAttached: Error = ModemFailure(message: "The modem is not attached.")
        expectEqual(notAttached.localizedDescription, "The modem is not attached.",
                    "ModemFailure: localizedDescription is the owner's sentence")
        expectEqual((notAttached as? LocalizedError)?.errorDescription ?? "", "The modem is not attached.",
                    "ModemFailure: is a LocalizedError")

        // --- canonicalMode ---------------------------------------------------------------------
        for (argument, want) in [
            ("auto", "AUTO"), ("AUTO", "AUTO"), ("Auto", "AUTO"),
            ("lte", "LTE"), ("LTE", "LTE"), ("nr5g", "NR5G"), ("NR5G", "NR5G"), ("wcdma", "WCDMA"),
            ("lte:nr5g", "LTE:NR5G"), ("nr5g:lte", "LTE:NR5G"), ("Nr5G:lTe", "LTE:NR5G"),
            ("lte:wcdma", "WCDMA:LTE"), ("nr5g:wcdma", "WCDMA:NR5G"), ("nr5g:wcdma:lte", "WCDMA:LTE:NR5G"),
        ] {
            let got = canonicalMode(argument)
            check(got == want, "canonicalMode: \(argument) -> \(want)", "got \(String(describing: got))")
        }
        for argument in ["", "5g", "nr", "gsm", "lte:lte", "nr5g:lte:nr5g", "auto:lte", "lte:auto", "auto:auto",
                         "lte:", ":lte", ":", "lte::nr5g", " lte", "lte ", "lte,nr5g", "lte nr5g", "ＬＴＥ"] {
            let got = canonicalMode(argument)
            check(got == nil, "canonicalMode: \"\(argument)\" is refused", "got \(String(describing: got))")
        }
        check(networkModeChoices == ["AUTO", "LTE:NR5G", "NR5G", "LTE"], "networkModeChoices: the window's order")
        for choice in networkModeChoices {
            check(canonicalMode(choice) == choice && canonicalMode(choice.lowercased()) == choice,
                  "canonicalMode: the choice \(choice) is canonical")
        }

        // --- the AT lines that change the modem ------------------------------------------------
        expectEqual(modeCommand("LTE:NR5G"), "AT+QNWPREFCFG=\"mode_pref\",LTE:NR5G", "modeCommand: LTE:NR5G")
        expectEqual(modeCommand("AUTO"), "AT+QNWPREFCFG=\"mode_pref\",AUTO", "modeCommand: AUTO")
        expectEqual(pinCommand("1234"), "AT+CPIN=\"1234\"", "pinCommand")
        expectEqual(profileCommand(1, ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "u", password: "p", auth: .chap)),
                    "AT+QICSGP=1,3,\"cmnet\",\"u\",\"p\",2", "profileCommand: the brief's example")
        expectEqual(profileCommand(16, ProfileSettings(type: .ipv4, apn: "", user: "", password: "", auth: .none)),
                    "AT+QICSGP=16,1,\"\",\"\",\"\",0", "profileCommand: empty values")
        expectEqual(profileCommand(2, ProfileSettings(type: .ipv6, apn: "x", user: "a b", password: "c'd", auth: .papOrChap)),
                    "AT+QICSGP=2,2,\"x\",\"a b\",\"c'd\",3", "profileCommand: IPv6, PAP or CHAP")

        // --- parseProfiles (AT+CGDCONT?) -------------------------------------------------------
        let listed = parseProfiles(cgdcont)
        check(listed.map { $0.id } == [1, 2, 3, 4, 5], "parseProfiles: the five fixture profiles", "\(listed)")
        check(listed.allSatisfy { $0.pdpType == "IPV4V6" }, "parseProfiles: PDP types", "\(listed)")
        check(listed.map { $0.apn } == ["", "ims", "CMNET", "CMWAP", "SOS"], "parseProfiles: APNs", "\(listed)")
        check(parseProfiles([]).isEmpty, "parseProfiles: no lines, no profiles")
        let odd = parseProfiles([
            "+CGDCONT: x,\"IP\",\"a\"",                    // no number
            "+CGDCONT: 6",                                 // no type, no APN
            "+CGDCONT: 7,\"IP\"",                          // no APN
            "+CGDCONT: 0,\"IP\",\"zero\"",                 // not a profile number
            "+CGDCONT: 8,\"IP\",\"a,b\",\"0.0.0.0\",0,0",  // a quoted comma
            "+CGDCONT: 8,\"IP\",\"again\"",                // the same number twice: the first is kept
            "+CGDCONT: 9,\"IPV6\",\"x\u{202E}y\u{1B}z\"",  // characters that are not safe to show
            "+CGREG: 0,1",
        ])
        check(odd.count == 2 && odd.first?.id == 8 && odd.first?.pdpType == "IP" && odd.first?.apn == "a,b",
              "parseProfiles: odd lines are skipped, a quoted comma stays in the APN", "\(odd)")
        check(odd.last?.id == 9 && odd.last?.apn == "x\u{FFFD}y\u{FFFD}z",
              "parseProfiles: an APN is made safe to show", "\(odd)")

        // --- parseProfileSettings (AT+QICSGP=<id>) ---------------------------------------------
        check(parseProfileSettings(qicsgp1) == ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none),
              "parseProfileSettings: profile 1", "\(String(describing: parseProfileSettings(qicsgp1)))")
        check(parseProfileSettings(qicsgp3) == profile3, "parseProfileSettings: profile 3",
              "\(String(describing: parseProfileSettings(qicsgp3)))")
        let commas = parseProfileSettings(["+QICSGP: 1,\"a,b\",\"u,v\",\"p,q\",3"])
        check(commas == ProfileSettings(type: .ipv4, apn: "a,b", user: "u,v", password: "p,q", auth: .papOrChap),
              "parseProfileSettings: quoted commas stay in their field", "\(String(describing: commas))")
        let spaced = parseProfileSettings(["+QICSGP: 2,\"x\",\" u \",\" p \",2"])
        check(spaced?.user == " u " && spaced?.password == " p " && spaced?.type == .ipv6 && spaced?.auth == .chap,
              "parseProfileSettings: spaces inside quotes are kept", "\(String(describing: spaced))")
        let extra = parseProfileSettings(["+QICSGP: 3,\"a\",\"u\",\"p\",1,9"])
        check(extra == ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "p", auth: .pap),
              "parseProfileSettings: an extra field is ignored", "\(String(describing: extra))")
        for (lines, name) in [
            (["+QICSGP: 0,\"\",\"\",\"\",0"], "type 0"), (["+QICSGP: 4,\"\",\"\",\"\",0"], "type 4"),
            (["+QICSGP: -,\"\",\"\",\"\",0"], "type -"), (["+QICSGP: ,\"\",\"\",\"\",0"], "type empty"),
            (["+QICSGP: 3,\"\",\"\",\"\",4"], "auth 4"), (["+QICSGP: 3,\"\",\"\",\"\",-1"], "auth -1"),
            (["+QICSGP: 3,\"\",\"\",\"\""], "no auth field"), (["+QICSGP: 3,\"\",\"\""], "three fields"),
            (["+QICSGP: 3"], "one field"), (qicsgpTest, "the test command's answer"), ([], "no lines"),
            (["+CGDCONT: 1,\"IPV4V6\",\"\""], "another prefix"),
        ] {
            check(parseProfileSettings(lines) == nil, "parseProfileSettings: \(name) gives nil",
                  "\(String(describing: parseProfileSettings(lines)))")
        }

        // --- profileProblem --------------------------------------------------------------------
        let idRule = { (id: Int) in "Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16." }
        let apnRule = "An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores; it does not "
            + "start or end with a dot or a hyphen, has no two dots in a row, and has no hyphen next to a dot."
        let userRule = "A user name is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
        let passwordRule = "A password is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
        check(profileProblem(1, cmnetPap) == nil, "profileProblem: a good profile 1")
        check(profileProblem(16, cmnetPap) == nil, "profileProblem: profile 16")
        check(profileProblem(1, profile1) == nil, "profileProblem: an empty APN is allowed (the network chooses)")
        for id in [0, 17, -1, 100] {
            check(profileProblem(id, cmnetPap) == idRule(id), "profileProblem: profile \(id)",
                  "\(String(describing: profileProblem(id, cmnetPap)))")
        }
        check(profileProblem(0, ProfileSettings(type: .ipv4, apn: "a b", user: "\"", password: "\"", auth: .pap)) == idRule(0),
              "profileProblem: the profile number is checked first")
        func withAPN(_ apn: String) -> ProfileSettings { ProfileSettings(type: .ipv4v6, apn: apn, user: "", password: "", auth: .none) }
        for apn in ["a.b-c_D9", String(repeating: "a", count: 100), "cmnet", "3gnet", "_", "a-b", "a--b", "my-apn.mnc001.mcc001.gprs",
                    "_a", "a_", "a._b"] {
            check(profileProblem(3, withAPN(apn)) == nil, "profileProblem: APN \"\(apn)\" is allowed",
                  "\(String(describing: profileProblem(3, withAPN(apn))))")
        }
        for (apn, name) in [
            (String(repeating: "a", count: 101), "101 characters"), ("a b", "a space"), ("a\"b", "a quote"),
            ("caf\u{E9}", "a precomposed accent"), ("cafe\u{301}", "a combining accent"), ("a/b", "a slash"),
            ("a,b", "a comma"), (".a", "a leading dot"), ("a.", "a trailing dot"), (".", "a dot alone"),
            ("a\nb", "a line feed"), ("a\u{0}", "a NUL"), ("ａ", "a full-width letter"),
            // Ruling R21 (3GPP TS 23.003, DNS labels): a label starts and ends with a letter or digit, and none is empty.
            ("-a", "a leading hyphen"), ("a-", "a trailing hyphen"), ("-", "a hyphen alone"),
            ("--no-redial", "an option typed after --apn"), ("a.-b", "a label starting with a hyphen"),
            ("a-.b", "a label ending with a hyphen"), ("a..b", "an empty label"), ("a.b.", "a trailing dot after labels"),
        ] {
            check(profileProblem(1, withAPN(apn)) == apnRule, "profileProblem: APN with \(name) is refused",
                  "\(String(describing: profileProblem(1, withAPN(apn))))")
        }
        func withUser(_ user: String) -> ProfileSettings { ProfileSettings(type: .ipv4v6, apn: "x", user: user, password: "", auth: .pap) }
        func withPassword(_ p: String) -> ProfileSettings { ProfileSettings(type: .ipv4v6, apn: "x", user: "u", password: p, auth: .pap) }
        for value in [" ", "a b", "~!@#$%^&*()_+{}|:<>?`-=[];',./", String(repeating: "x", count: 127)] {
            check(profileProblem(1, withUser(value)) == nil, "profileProblem: user \"\(value)\" is allowed")
            check(profileProblem(1, withPassword(value)) == nil, "profileProblem: a password of printable ASCII is allowed")
        }
        for (value, name) in [
            (String(repeating: "x", count: 128), "128 characters"), ("a\"b", "a double quote"), ("a\tb", "a tab"),
            ("a\\41", "a backslash (V.250 may read \\hh as an escape)"), ("\\", "a backslash alone"),
            ("a\nb", "a line feed"), ("\u{7F}", "DEL"), ("\u{1F}", "a control character"), ("caf\u{E9}", "an accent"),
            ("e\u{301}", "a combining mark"), ("\u{202E}", "a bidirectional override"),
        ] {
            check(profileProblem(1, withUser(value)) == userRule, "profileProblem: user with \(name) is refused",
                  "\(String(describing: profileProblem(1, withUser(value))))")
            check(profileProblem(1, withPassword(value)) == passwordRule, "profileProblem: password with \(name) is refused",
                  "\(String(describing: profileProblem(1, withPassword(value))))")
        }
        let quotedSecret = withPassword(secret + "\"")
        check(profileProblem(1, quotedSecret) == passwordRule, "profileProblem: a refused password names the field")
        expectNoSecret(profileProblem(1, quotedSecret) ?? "", "profileProblem never quotes the password")
        check(profileProblem(1, ProfileSettings(type: .ipv4v6, apn: "a b", user: "\"", password: "\"", auth: .pap)) == apnRule,
              "profileProblem: the APN is checked before the user name")
        check(profileProblem(1, ProfileSettings(type: .ipv4v6, apn: "a", user: "\"", password: "\"", auth: .pap)) == userRule,
              "profileProblem: the user name is checked before the password")
        // Ruling R15: the modem turns a profile with a password and authentication 0 into CHAP by itself, so
        // with no authentication the user name and the password must be empty.
        let noAuthRule = "With no authentication the user name and password must be empty; choose PAP, CHAP or PAP or CHAP to use them."
        for (user, password, name) in [("u", "", "a user name only"), ("", secret, "a password only"),
                                       ("u", secret, "both"), (" ", "", "a user name of one space")] {
            let s = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: user, password: password, auth: .none)
            let problem = profileProblem(1, s)
            check(problem == noAuthRule, "profileProblem: no authentication with \(name) is refused",
                  "\(String(describing: problem))".replacingOccurrences(of: secret, with: "<the password>"))
            expectNoSecret(problem ?? "", "profileProblem: the no-authentication rule never quotes the password")
        }
        check(profileProblem(1, ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)) == nil,
              "profileProblem: no authentication with neither is allowed")
        for auth in [AuthMethod.pap, .chap, .papOrChap] {
            for (user, password, name) in [("u", "", "a user name"), ("", secret, "a password"), ("u", secret, "both")] {
                let s = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: user, password: password, auth: auth)
                check(profileProblem(1, s) == nil, "profileProblem: \(auth) with \(name) is allowed",
                      "\(String(describing: profileProblem(1, s)))".replacingOccurrences(of: secret, with: "<the password>"))
            }
        }
        check(profileProblem(1, ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "\"", auth: .none)) == passwordRule,
              "profileProblem: the password's characters are checked before the no-authentication rule")
        check(profileProblem(0, ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "", auth: .none)) == idRule(0),
              "profileProblem: the profile number is checked before the no-authentication rule")

        // --- pinProblem ------------------------------------------------------------------------
        for pin in ["1234", "0000", "12345678", "98765"] {
            check(pinProblem(pin) == nil, "pinProblem: \(pin) is a PIN")
        }
        for (pin, name) in [
            ("123", "3 digits"), ("123456789", "9 digits"), ("12a4", "a letter"), ("", "empty"),
            ("\u{FF11}\u{FF12}\u{FF13}\u{FF14}", "full-width digits"), ("\u{661}\u{662}\u{663}\u{664}", "Arabic-Indic digits"),
            (" 1234", "a leading space"), ("1234\n", "a line feed"), ("12 34", "a space inside"), ("-1234", "a sign"),
            ("1234\"", "a quote"),
        ] {
            check(pinProblem(pin) == "A PIN is 4 to 8 digits.", "pinProblem: \(name) is refused",
                  "\(String(describing: pinProblem(pin)))")
        }
        check(!(pinProblem("12a4") ?? "").contains("12a4"), "pinProblem: the sentence never quotes the PIN")

        // --- parseSimState and simState(fromError:) ---------------------------------------------
        for (line, want) in [
            ("+CPIN: READY", SimState.ready), ("+CPIN: SIM PIN", .pin), ("+CPIN: SIM PUK", .puk),
            ("+CPIN: SIM PIN2", .pin2), ("+CPIN: SIM PUK2", .puk2), ("+CPIN: PH-SIM PIN", .other("PH-SIM PIN")),
            ("+CPIN:READY", .ready), ("+CPIN: \"SIM PIN\"", .pin), ("+CPIN: ready", .other("ready")),
            ("+CPIN: X\u{202E}Y", .other("X\u{FFFD}Y")),
        ] {
            let got = parseSimState([line])
            check(got == want, "parseSimState: \(line)", "got \(String(describing: got))")
        }
        check(parseSimState(["+QPINC: \"SC\",3,10", "+CPIN: SIM PIN"]) == .pin, "parseSimState: the +CPIN line among others")
        for (lines, name) in [([String](), "no lines"), (["OK"], "no +CPIN line"), (["+CPIN: "], "an empty code"),
                              (["+CPINX: READY"], "another prefix")] {
            check(parseSimState(lines) == nil, "parseSimState: \(name) gives nil", "\(String(describing: parseSimState(lines)))")
        }
        for (line, want) in [
            ("+CME ERROR: 10", SimState.notInserted), ("+CME ERROR: 13", .failure), ("+CME ERROR: 14", .busy),
            ("+CME ERROR: 3", .other("+CME ERROR: 3")), ("+CME ERROR: 100", .other("+CME ERROR: 100")),
            ("ERROR", .other("ERROR")), ("+CMS ERROR: 10", .other("+CMS ERROR: 10")),
            ("+CME ERROR: SIM not inserted", .other("+CME ERROR: SIM not inserted")),
            ("+CME ERROR: \u{202E}", .other("+CME ERROR: \u{FFFD}")),
        ] {
            let got = simState(fromError: line)
            check(got == want, "simState(fromError:): \(line)", "got \(got)")
        }

        // --- parsePinAttempts and parsePinLock -------------------------------------------------
        let attempts = parsePinAttempts(qpinc)
        check(attempts.pin == 3 && attempts.puk == 10, "parsePinAttempts: the SC line", "\(attempts)")
        let p2First = parsePinAttempts(["+QPINC: \"P2\",1,2", "+QPINC: \"SC\",2,9"])
        check(p2First.pin == 2 && p2First.puk == 9, "parsePinAttempts: the SC line, not P2", "\(p2First)")
        for (lines, name) in [(["+QPINC: \"P2\",3,10"], "P2 only"), ([String](), "no lines"),
                              (["+QPINC: \"SC\",-,-"], "dashes"), (["+QPINC: \"SC\",-1,-2"], "negative counts")] {
            let got = parsePinAttempts(lines)
            check(got.pin == nil && got.puk == nil, "parsePinAttempts: \(name) gives nil", "\(got)")
        }
        let pinOnly = parsePinAttempts(["+QPINC: \"SC\",3"])
        check(pinOnly.pin == 3 && pinOnly.puk == nil, "parsePinAttempts: a short line keeps what it has", "\(pinOnly)")
        for (lines, want) in [(clckOff, false as Bool?), (["+CLCK: 1"], true), (["+CLCK: 1,7"], true),
                              (["+CLCK: 2"], nil), (["+CLCK: x"], nil), ([String](), nil), (["+CPIN: READY"], nil)] {
            check(parsePinLock(lines) == want, "parsePinLock: \(lines)", "\(String(describing: parsePinLock(lines)))")
        }

        // --- one rule for text from the modem: Task 1's modemTextSafe --------------------------
        expectEqual(modemTextSafe("\u{0}\u{1B}\u{7F}\u{85}\u{61C}\u{200E}\u{200F}\u{2028}\u{2029}\u{202A}\u{202E}\u{2066}\u{2069}"),
                    String(repeating: "\u{FFFD}", count: 13), "modemTextSafe: each unsafe class becomes U+FFFD")
        expectEqual(modemTextSafe("CMNET \u{4E2D}\u{56FD} e\u{301} \u{200D}"), "CMNET \u{4E2D}\u{56FD} e\u{301} \u{200D}",
                    "modemTextSafe: other text is kept")
        // Every scalar up to U+3000 inside a value (not `"` or `,`, which the AT fields split on): the APN that
        // parseProfiles gives, the text of an unknown SIM state, and the APN in profileWords all follow it.
        var drifted: [String] = []
        for v in UInt32(0)...0x3000 {
            guard let c = Unicode.Scalar(v), c != "\"", c != "," else { continue }
            let raw = "a" + String(c) + "b"
            let safe = modemTextSafe(raw)
            if parseProfiles(["+CGDCONT: 1,\"IP\",\"\(raw)\""]).first?.apn != safe { drifted.append("CGDCONT U+\(String(v, radix: 16))") }
            if parseSimState(["+CPIN: \(raw)"]) != .other(safe) { drifted.append("CPIN U+\(String(v, radix: 16))") }
            if profileWords(ProfileSettings(type: .ipv4, apn: raw, user: "", password: "", auth: .none))
                != "IPV4, APN \"\(safe)\", no authentication" { drifted.append("profileWords U+\(String(v, radix: 16))") }
        }
        check(drifted.isEmpty, "modemTextSafe: ModemSettings shows modem text by Task 1's rule", "\(drifted.prefix(10))")

        // --- profileWords ----------------------------------------------------------------------
        expectEqual(profileWords(cmnetPap), cmnetPapWords, "profileWords: the brief's example")
        expectEqual(profileWords(profile1), "IPV4V6, APN \"\" (the network chooses), no authentication",
                    "profileWords: profile 1")
        expectEqual(profileWords(ProfileSettings(type: .ipv4, apn: "CMNET", user: "", password: "", auth: .chap)),
                    "IPV4, APN \"CMNET\", CHAP", "profileWords: CHAP, no user, no password")
        expectEqual(profileWords(ProfileSettings(type: .ipv6, apn: "x", user: "", password: "p", auth: .papOrChap)),
                    "IPV6, APN \"x\", PAP or CHAP, password set", "profileWords: a password without a user")
        expectEqual(profileWords(ProfileSettings(type: .ipv4v6, apn: "x", user: "me", password: "", auth: .pap)),
                    "IPV4V6, APN \"x\", PAP, user \"me\"", "profileWords: a user without a password")
        expectEqual(profileWords(ProfileSettings(type: .ipv4v6, apn: "a\u{1B}[2J", user: "u\u{202E}", password: "", auth: .pap)),
                    "IPV4V6, APN \"a\u{FFFD}[2J\", PAP, user \"u\u{FFFD}\"", "profileWords: values are made safe to show")
        expectEqual(cmnetPap.description, cmnetPapWords, "ProfileSettings.description is profileWords")
        expectEqual(cmnetPap.debugDescription, cmnetPapWords, "ProfileSettings.debugDescription is profileWords")

        // --- profileRestoreArguments -----------------------------------------------------------
        expectEqual(profileRestoreArguments(profile1), "--apn '' --type ipv4v6 --user '' --auth none --no-password",
                    "profileRestoreArguments: profile 1 (no password) ends --no-password")
        expectEqual(profileRestoreArguments(cmnetPap), "--apn 'cmnet' --type ipv4v6 --user 'u' --auth pap --password",
                    "profileRestoreArguments: a password set ends --password")
        expectEqual(profileRestoreArguments(ProfileSettings(type: .ipv4, apn: "CMNET", user: "o'brien", password: "", auth: .chap)),
                    "--apn 'CMNET' --type ipv4 --user 'o'\\''brien' --auth chap --no-password", "profileRestoreArguments: a quote inside")
        expectEqual(profileRestoreArguments(ProfileSettings(type: .ipv6, apn: "x", user: "''", password: "", auth: .papOrChap)),
                    "--apn 'x' --type ipv6 --user ''\\'''\\''' --auth pap-or-chap --no-password", "profileRestoreArguments: two quotes")
        let combined = profileRestoreArguments(ProfileSettings(type: .ipv4, apn: "", user: "a'\u{301}", password: "", auth: .none))
        check(Array(combined.unicodeScalars) == Array("--apn '' --type ipv4 --user 'a'\\''\u{301}' --auth none --no-password".unicodeScalars),
              "profileRestoreArguments: a quote joined to a combining mark is still escaped", combined)
        expectEqual(profileRestoreArguments(ProfileSettings(type: .ipv4, apn: "", user: "a\nrm", password: "", auth: .none)),
                    "--apn '' --type ipv4 --user 'a\u{FFFD}rm' --auth none --no-password", "profileRestoreArguments: made safe to show")

        // --- redaction --------------------------------------------------------------------------
        let secretProfile = DataProfile(id: 1, pdpType: "IPV4V6", apn: "a", settings: secretSettings)
        let secretChange = ProfileChange(id: 1, before: secretSettings, after: secretSettings, redial: .notAsked)
        let otherChange = ProfileChange(id: 1, before: profile1, after: secretSettings,
                                        redial: .done(RadioChange(on: true, registration: homeSA, secondsToRegister: 3)))
        var printed = ""
        print(secretSettings, to: &printed)
        debugPrint(secretSettings, to: &printed)
        print(secretChange, to: &printed)
        debugPrint(secretChange, to: &printed)
        let forms: [(String, String)] = [
            ("\(secretSettings)", "interpolation"),
            (String(describing: secretSettings), "String(describing:)"),
            (String(reflecting: secretSettings), "String(reflecting:)"),
            (dumped(secretSettings), "dump"),
            ("\([secretSettings])", "interpolation of an array"),
            ("\(Optional(secretSettings) as Any)", "interpolation of an optional"),
            ("\(secretProfile)", "interpolation of a DataProfile"),
            (String(reflecting: secretProfile), "String(reflecting:) of a DataProfile"),
            (dumped(secretProfile), "dump of a DataProfile"),
            ("\(secretChange)", "interpolation of a ProfileChange"),
            (String(describing: secretChange), "String(describing:) of a ProfileChange"),
            (String(reflecting: secretChange), "String(reflecting:) of a ProfileChange"),
            (dumped(secretChange), "dump of a ProfileChange"),
            (dumped(otherChange), "dump of a ProfileChange after a redial"),
            ("\(Result<ProfileChange, ModemFailure>.success(secretChange))", "interpolation of a Result"),
            (printed, "print and debugPrint"),
            (profileWords(secretSettings), "profileWords"),
            (profileRestoreArguments(secretSettings), "profileRestoreArguments"),
            (profileRestoreArguments(otherChange.before), "profileRestoreArguments, --no-password form"),
            (Mirror(reflecting: secretSettings).children.map { "\($0.label ?? ""): \($0.value)" }.joined(), "the mirror's children"),
        ]
        for (text, name) in forms { expectNoSecret(text, name) }
        check(profileRestoreArguments(otherChange.before).hasSuffix(" --no-password")
                && profileRestoreArguments(secretChange.before).hasSuffix(" --password"),
              "redaction: putting back a change that added the password clears it; one that kept it asks for it")
        let labels = Mirror(reflecting: secretSettings).children.compactMap { $0.label }
        check(labels == ["type", "apn", "user", "passwordSet", "auth"], "redaction: the mirror has passwordSet, no password", "\(labels)")
        check(dumped(secretSettings).contains("passwordSet: true"), "redaction: dump shows that a password is set",
              dumped(secretSettings))
        for (before, after, name) in [(secretSettings as ProfileSettings?, secretSettings, "same"),
                                      (profile1, secretSettings, "changed"), (nil, secretSettings, "before unread"),
                                      (secretSettings, profile1, "removed")] {
            let q = profileQuestion(id: 1, before: before, after: after)
            expectNoSecret(q.title + q.message, "profileQuestion, \(name)")
        }
        for redial in [RedialResult.notAsked, .radioWasOff, .radioLeftOff("The modem did not answer in time."),
                       .done(RadioChange(on: true, registration: homeSA, secondsToRegister: 3)),
                       .done(RadioChange(on: true, registration: nil, secondsToRegister: nil))] {
            for change in [ProfileChange(id: 1, before: secretSettings, after: secretSettings, redial: redial),
                           ProfileChange(id: 1, before: profile1, after: secretSettings, redial: redial),
                           ProfileChange(id: 1, before: secretSettings, after: profile1, redial: redial)] {
                expectNoSecret(profileSentence(change), "profileSentence, \(redial)")
            }
        }
        expectNoSecret(jsonText(profilesJSON([secretProfile], driverProfile: 1), "profilesJSON with a password"),
                       "profilesJSON")

        // --- profilesJSON ----------------------------------------------------------------------
        let small = [DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1),
                     DataProfile(id: 2, pdpType: "IPV4V6", apn: "ims", settings: nil)]
        expectEqual(jsonText(profilesJSON(small, driverProfile: 1), "profilesJSON"),
                    "{\"driverProfile\":1,\"profiles\":[" +
                    "{\"apn\":\"\",\"auth\":\"none\",\"driver\":true,\"id\":1,\"passwordSet\":false,\"pdpType\":\"IPV4V6\",\"user\":\"\"}," +
                    "{\"apn\":\"ims\",\"auth\":null,\"driver\":false,\"id\":2,\"passwordSet\":null,\"pdpType\":\"IPV4V6\",\"user\":null}]}",
                    "profilesJSON: settings read and not read")
        let fromFixtures = listed.map { p in
            DataProfile(id: p.id, pdpType: p.pdpType, apn: p.apn,
                        settings: p.id == 1 ? parseProfileSettings(qicsgp1) : p.id == 3 ? parseProfileSettings(qicsgp3) : nil)
        }
        let fixtureJSON = profilesJSON(fromFixtures, driverProfile: 3)
        let rows = fixtureJSON["profiles"] as? [[String: Any]] ?? []
        check(fixtureJSON["driverProfile"] as? Int == 3 && rows.count == 5, "profilesJSON: the fixtures", "\(fixtureJSON)")
        check(rows.map { $0["driver"] as? Bool } == [false, false, true, false, false], "profilesJSON: only profile 3 is the driver's",
              "\(rows)")
        check(rows.map { $0["apn"] as? String } == ["", "ims", "CMNET", "CMWAP", "SOS"], "profilesJSON: APNs", "\(rows)")
        check(rows.map { $0["auth"] is NSNull } == [false, true, false, true, true], "profilesJSON: auth null where unread", "\(rows)")
        for (auth, word) in [(AuthMethod.none, "none"), (.pap, "pap"), (.chap, "chap"), (.papOrChap, "pap-or-chap")] {
            let one = [DataProfile(id: 2, pdpType: "IP", apn: "x",
                                   settings: ProfileSettings(type: .ipv4, apn: "x", user: "me", password: "p", auth: auth))]
            let row = (profilesJSON(one, driverProfile: 1)["profiles"] as? [[String: Any]])?.first ?? [:]
            check(row["auth"] as? String == word && row["user"] as? String == "me" && row["passwordSet"] as? Bool == true,
                  "profilesJSON: auth \(word)", "\(row)")
        }
        expectEqual(jsonText(profilesJSON([], driverProfile: 1), "profilesJSON, none"), "{\"driverProfile\":1,\"profiles\":[]}",
                    "profilesJSON: no profiles")

        // --- simRows and simJSON ----------------------------------------------------------------
        expectRows(simRows(readySim), [("SIM", "ready"), ("PIN lock", "off"), ("Attempts left", "PIN 3, PUK 10")], "ready")
        let simFixture = SimInfo(state: parseSimState(cpinReady) ?? .other("?"), pinLock: parsePinLock(clckOff),
                                 pinAttempts: parsePinAttempts(qpinc).pin, pukAttempts: parsePinAttempts(qpinc).puk)
        check(simFixture == readySim, "SimInfo: from the fixtures", "\(simFixture)")
        for (state, words) in [
            (SimState.ready, "ready"), (.pin, "asks for its PIN"), (.puk, "blocked: needs its PUK from the carrier"),
            (.pin2, "asks for PIN2"), (.puk2, "asks for PUK2"), (.notInserted, "not inserted"), (.failure, "SIM failure"),
            (.busy, "busy"), (.other("PH-SIM PIN"), "PH-SIM PIN"),
        ] {
            expectRows(simRows(SimInfo(state: state, pinLock: true, pinAttempts: nil, pukAttempts: nil)),
                       [("SIM", words), ("PIN lock", "on")], "state \(state)")
            expectEqual(simStateWords(state), words, "simStateWords: \(state)")
        }
        expectRows(simRows(SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil)),
                   [("SIM", "not inserted")], "unknown values are left out")
        expectRows(simRows(SimInfo(state: .pin, pinLock: nil, pinAttempts: 2, pukAttempts: nil)),
                   [("SIM", "asks for its PIN"), ("Attempts left", "PIN 2")], "only the PIN attempts known")
        expectRows(simRows(SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10)),
                   [("SIM", "blocked: needs its PUK from the carrier"), ("PIN lock", "on"), ("Attempts left", "PIN 0, PUK 10")],
                   "blocked")
        expectEqual(jsonText(simJSON(readySim), "simJSON"),
                    "{\"activeSlot\":null,\"pinAttempts\":3,\"pinLock\":false,\"pukAttempts\":10,\"state\":\"ready\"}",
                    "simJSON: ready (activeSlot added, null when not read)")
        var slotted = readySim
        slotted.activeSlot = 2
        expectEqual(jsonText(simJSON(slotted), "simJSON slot"),
                    "{\"activeSlot\":2,\"pinAttempts\":3,\"pinLock\":false,\"pukAttempts\":10,\"state\":\"ready\"}",
                    "simJSON: with the slot")
        expectRows(simRows(slotted), [("SIM", "ready"), ("PIN lock", "off"), ("Attempts left", "PIN 3, PUK 10"), ("Slot", "2")],
                   "the slot as the last row")
        // AT+QUIMSLOT? and the SIM states.
        check(parseSimSlot(["+QUIMSLOT: 1"]) == 1 && parseSimSlot(["+QUIMSLOT: 2"]) == 2, "parseSimSlot: 1 and 2")
        check(parseSimSlot(["+QUIMSLOT: 3"]) == nil && parseSimSlot(["+QUIMSLOT: x"]) == nil && parseSimSlot([]) == nil
                && parseSimSlot(["+QUIMSLOT:"]) == nil, "parseSimSlot: another value, none")
        expectEqual(simSlotCommand(2), "AT+QUIMSLOT=2", "simSlotCommand")
        check(otherSimSlot(1) == 2 && otherSimSlot(2) == 1, "otherSimSlot")
        check(simUnusable(simState(fromError: "+CME ERROR: 10")) && simUnusable(simState(fromError: "+CME ERROR: 13")),
              "simUnusable: CME 10 (not inserted) and 13 (SIM failure)")
        check(!simUnusable(simState(fromError: "+CME ERROR: 14")) && !simUnusable(.ready) && !simUnusable(.pin)
                && !simUnusable(.other("+CME ERROR: 15")), "simUnusable: not busy, ready, a PIN or another answer")
        check(simState(PulseAnswer.refused("+CME ERROR: 10")) == .notInserted
                && simState(PulseAnswer.lines(["+CPIN: READY"])) == .ready && simState(PulseAnswer.lines([])) == nil,
              "simState of a short read")
        let q = simSlotQuestion(from: 1, to: 2)
        check(q.title == "Switch to SIM 2?" && q.message.hasPrefix("The modem uses SIM 1 now. The connection drops"),
              "simSlotQuestion", q.message)
        expectEqual(jsonText(simJSON(SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil)), "simJSON"),
                    "{\"activeSlot\":null,\"pinAttempts\":null,\"pinLock\":null,\"pukAttempts\":null,\"state\":\"not inserted\"}",
                    "simJSON: nulls where unknown")
        for (state, word) in [
            (SimState.ready, "ready"), (.pin, "pin"), (.puk, "puk"), (.pin2, "pin2"), (.puk2, "puk2"),
            (.notInserted, "not inserted"), (.failure, "failure"), (.busy, "busy"), (.other("PH-SIM PIN"), "PH-SIM PIN"),
        ] {
            let got = simJSON(SimInfo(state: state, pinLock: true, pinAttempts: 1, pukAttempts: 2))
            check(got["state"] as? String == word && got["pinLock"] as? Bool == true, "simJSON: state \(word)", "\(got)")
        }

        // --- the questions ----------------------------------------------------------------------
        let radioOff = radioOffQuestion()
        check(radioOff.title == "Switch the radio off?", "radioOffQuestion: title", radioOff.title)
        check(radioOff.message.contains("connection is down until the radio is switched on again")
                && radioOff.message.contains("the Radio switch on the Network screen")
                && radioOff.message.contains("`RMNet radio on`") && !radioOff.message.contains("Radio On"),
              "radioOffQuestion: says the connection is down until the Radio switch on the Network screen or "
                + "`RMNet radio on`", radioOff.message)

        let toLTE = modeQuestion(from: "AUTO", to: "LTE")
        check(toLTE.title == "Change the network mode to LTE only?", "modeQuestion: title", toLTE.title)
        for part in ["automatic (5G, LTE and WCDMA)", "LTE only", "The modem keeps this setting", "Put Back", "`RMNet mode auto`"] {
            check(toLTE.message.contains(part), "modeQuestion: AUTO to LTE says \"\(part)\"", toLTE.message)
        }
        let fromBoth = modeQuestion(from: "LTE:NR5G", to: "NR5G")
        check(fromBoth.message.contains("`RMNet mode lte:nr5g`") && fromBoth.message.contains("5G and LTE"),
              "modeQuestion: the way back is the earlier mode, lowercased", fromBoth.message)
        let fromReordered = modeQuestion(from: "NR5G:LTE", to: "LTE")
        check(fromReordered.message.contains("`RMNet mode nr5g:lte`") && fromReordered.message.contains("Put Back"),
              "modeQuestion: the modem's own order (NR5G:LTE) is offered as the way back (R8)", fromReordered.message)
        let fromOdd = modeQuestion(from: "GSM:LTE", to: "LTE")
        check(!fromOdd.message.contains("`RMNet mode") && !fromOdd.message.contains("Put Back")
                && fromOdd.message.hasSuffix(" The current mode GSM:LTE cannot be set with RMNet mode; "
                                             + "to put it back: RMNet at 'AT+QNWPREFCFG=\"mode_pref\",GSM:LTE'"),
              "modeQuestion: a mode RMNet cannot set is not offered as the way back; its AT command is", fromOdd.message)
        let fromQuoted = modeQuestion(from: "GSM'LTE", to: "LTE")
        check(fromQuoted.message.hasSuffix(" The current mode GSM'LTE cannot be set with RMNet mode; "
                                           + "set it again with RMNet at 'AT+QNWPREFCFG=\"mode_pref\",<value>'"),
              "modeQuestion: a mode with a quote: the AT command with <value> as written", fromQuoted.message)
        check(![toLTE, fromBoth, fromReordered, fromOdd, fromQuoted].contains { $0.message.contains("console") },
              "modeQuestion: no message points to a console", fromOdd.message)
        let fromUnknown = modeQuestion(from: nil, to: "LTE")
        check(!fromUnknown.message.contains("RMNet mode") && fromUnknown.message.contains("could not be read")
                && fromUnknown.message.contains("The modem keeps this setting"),
              "modeQuestion: an unread mode offers no command", fromUnknown.message)

        let changed = profileQuestion(id: 1, before: profile1, after: cmnetPap)
        check(changed.title == "Change profile 1?", "profileQuestion: title", changed.title)
        for part in ["A wrong APN breaks the connection.", "off and on again (a redial)", "password: changed",
                     "Now: IPV4V6, APN \"\" (the network chooses), no authentication.",
                     "New: IPV4V6, APN \"cmnet\", PAP, user \"u\"; password: changed."] {
            check(changed.message.contains(part), "profileQuestion: says \"\(part)\"", changed.message)
        }
        let samePassword = profileQuestion(id: 3, before: cmnetPap,
                                           after: ProfileSettings(type: .ipv4, apn: "cmnet", user: "u", password: "p", auth: .chap))
        check(samePassword.message.contains("password: unchanged") && !samePassword.message.contains("password: changed")
                && samePassword.title == "Change profile 3?",
              "profileQuestion: the same password reads unchanged", samePassword.message)
        let unread = profileQuestion(id: 1, before: nil, after: cmnetPap)
        check(unread.message.contains("could not be read") && unread.message.contains("password: set")
                && unread.message.contains("A wrong APN breaks the connection."),
              "profileQuestion: unread settings", unread.message)
        check(profileQuestion(id: 1, before: nil, after: profile1).message.contains("password: none"),
              "profileQuestion: unread settings, no new password")

        let three = pinQuestion(attempts: 3)
        check(three.message.contains("3 attempts left") && three.message.contains("a wrong PIN uses one"),
              "pinQuestion: 3 attempts", three.message)
        check(pinQuestion(attempts: 2).message.contains("2 attempts left"), "pinQuestion: 2 attempts")
        let last = pinQuestion(attempts: 1)
        check(last.message.contains("This is the last attempt") && last.message.contains("PUK")
                && last.message.contains("1 attempt left") && !last.message.contains("1 attempts"),
              "pinQuestion: the last attempt", last.message)
        check(!three.title.isEmpty && three.title == last.title, "pinQuestion: title", three.title)

        // --- the commands that put a change back (the CLI's lines and the window's, F9) ------------
        expectEqual(profileRestoreCommand(profile1), "RMNet apn set --apn '' --type ipv4v6 --user '' --auth none --no-password",
                    "profileRestoreCommand: no password")
        let withOld = ProfileSettings(type: .ipv4, apn: "it's", user: "u", password: secret, auth: .chap)
        expectEqual(profileRestoreCommand(withOld), "RMNet apn set --apn 'it'\\''s' --type ipv4 --user 'u' --auth chap --password",
                    "profileRestoreCommand: a password is asked for, never shown")
        expectNoSecret(profileRestoreCommand(withOld), "profileRestoreCommand never holds the password")
        for (before, want) in [("NR5G:LTE", "RMNet mode nr5g:lte"), ("AUTO", "RMNet mode auto"), ("LTE", "RMNet mode lte"),
                               ("WCDMA:LTE:NR5G", "RMNet mode wcdma:lte:nr5g")] {
            check(modeRestoreCommand(before) == want, "modeRestoreCommand: \(before)", "\(String(describing: modeRestoreCommand(before)))")
        }
        for before in ["GSM:LTE", "", "LTE:LTE"] {
            check(modeRestoreCommand(before) == nil, "modeRestoreCommand: \"\(before)\" cannot be set by RMNet (R8)")
        }
        // Such a value goes back with `RMNet at` and modeCommand, filled in when it is printable ASCII without
        // quotes (and `RMNet at` would send the line as it is); otherwise `<value>` as written.
        for before in ["GSM:LTE", "LTE:LTE", "AUTO", "GSM LTE", "x!$`\\;&"] {
            let want = "RMNet at '\(modeCommand(before))'"
            check(modeAtRestoreCommand(before) == want, "modeAtRestoreCommand: \(before.debugDescription)",
                  "\(String(describing: modeAtRestoreCommand(before)))")
            check(modeAtWayBack(before) == "cannot be set with RMNet mode; to put it back: \(want)",
                  "modeAtWayBack: \(before.debugDescription) filled in", modeAtWayBack(before))
        }
        check(modeAtRestoreCommand("GSM:LTE") == "RMNet at 'AT+QNWPREFCFG=\"mode_pref\",GSM:LTE'",
              "modeAtRestoreCommand: GSM:LTE word for word", "\(String(describing: modeAtRestoreCommand("GSM:LTE")))")
        for before in ["", "GSM\"LTE", "it's", "GSM:\u{FFFD}", "LTE\u{7F}", "LTE\t", "é", "LTE\n", "LTE ", "LTE&W",
                       String(repeating: "L", count: 512)] {
            check(modeAtRestoreCommand(before) == nil, "modeAtRestoreCommand: \(before.debugDescription) is not filled in",
                  "\(String(describing: modeAtRestoreCommand(before)))")
            check(modeAtWayBack(before)
                    == "cannot be set with RMNet mode; set it again with RMNet at 'AT+QNWPREFCFG=\"mode_pref\",<value>'",
                  "modeAtWayBack: \(before.debugDescription) is written <value>", modeAtWayBack(before))
        }
        check(profileNumberProblem(1) == nil && profileNumberProblem(16) == nil, "profileNumberProblem: 1 and 16")
        check(profileNumberProblem(17) == "Profile 17 cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."
              && profileNumberProblem(0) != nil, "profileNumberProblem: 0 and 17")

        // --- the window's last PIN attempt (ruling R20) --------------------------------------------
        expectEqual(lastAttemptChoice, "Use the last attempt (a wrong PIN blocks the SIM until its PUK is entered)",
                    "lastAttemptChoice: the checkbox's words")
        for (pin, attempts, ticked, want, name) in [
            ("1234", 3, false, true, "3 attempts: no checkbox needed"),
            ("1234", 2, false, true, "2 attempts: no checkbox needed"),
            ("1234", 1, false, false, "the last attempt, unticked"),
            ("1234", 1, true, true, "the last attempt, ticked"),
            ("12a4", 1, true, false, "the last attempt, ticked, a PIN the rules refuse"),
            ("12a4", 3, false, false, "a PIN the rules refuse"),
            ("1234", 0, true, false, "no attempts left"),
            ("1234", -1, true, false, "attempts below 0"),
        ] {
            check(unlockAllowed(pin: pin, attempts: attempts, lastAttemptTicked: ticked) == want, "unlockAllowed: \(name)")
        }

        // --- the sentences ----------------------------------------------------------------------
        expectEqual(radioSentence(RadioChange(on: false, registration: nil, secondsToRegister: nil)),
                    "The radio is off. The driver's connection is down until the radio is switched on again.",
                    "radioSentence: off")
        expectEqual(radioSentence(RadioChange(on: true, registration: homeSA, secondsToRegister: 12)),
                    "The radio is on; registered, home network (5GS) after 12 s.", "radioSentence: registered")
        expectEqual(radioSentence(RadioChange(on: true, registration: Registration(status: .roaming, domain: "EPS"), secondsToRegister: 0)),
                    "The radio is on; registered, roaming (EPS) after 0 s.", "radioSentence: roaming at once")
        expectEqual(radioSentence(RadioChange(on: true, registration: homeSA, secondsToRegister: nil)),
                    "The radio is on; registered, home network (5GS).", "radioSentence: registered, no time")
        expectEqual(radioSentence(RadioChange(on: true, registration: Registration(status: .searching, domain: "5GS"),
                                              secondsToRegister: nil)),
                    "The radio is on, but the modem has not registered yet (searching).", "radioSentence: not registered")
        expectEqual(radioSentence(RadioChange(on: true, registration: nil, secondsToRegister: nil)),
                    "The radio is on, but the modem has not registered yet (unknown).", "radioSentence: nothing read")
        expectEqual(radioSentence(RadioChange(on: true, registration: Registration(status: .denied, domain: "5GS"),
                                              secondsToRegister: 4)),
                    "The radio is on, but the modem has not registered yet (registration denied).",
                    "radioSentence: a time without a registration is not a registration")

        expectEqual(modeSentence(ModeChange(before: "AUTO", after: "LTE")),
                    "The network mode is now LTE only; it was automatic (5G, LTE and WCDMA). The modem keeps this setting.",
                    "modeSentence: AUTO to LTE")
        expectEqual(modeSentence(ModeChange(before: "LTE", after: "LTE")), "The network mode is LTE only, as it was.",
                    "modeSentence: unchanged")

        let toCmnet = { (redial: RedialResult) in ProfileChange(id: 1, before: profile1, after: cmnetPap, redial: redial) }
        expectEqual(profileSentence(toCmnet(.notAsked)),
                    "Profile 1 is now \(cmnetPapWords). The driver uses it the next time it dials " +
                    "(after the radio is switched off and on, or the modem restarts).", "profileSentence: no redial")
        expectEqual(profileSentence(toCmnet(.radioWasOff)),
                    "Profile 1 is now \(cmnetPapWords). The radio was off; the new settings are used when the radio is switched on.",
                    "profileSentence: the radio was off")
        expectEqual(profileSentence(toCmnet(.done(RadioChange(on: true, registration: homeSA, secondsToRegister: 12)))),
                    "Profile 1 is now \(cmnetPapWords). The radio was switched off and on again. " +
                    "The radio is on; registered, home network (5GS) after 12 s.", "profileSentence: redialled")
        let leftOff = profileSentence(toCmnet(.radioLeftOff("The modem did not answer in time.")))
        check(leftOff.hasPrefix("The profile was changed, but the radio is still off: ")
                && leftOff.hasSuffix("Run `RMNet radio on`, or use the Radio switch on the window's Network screen."),
              "profileSentence: the radio left off begins and ends as the brief says", leftOff)
        expectEqual(leftOff, "The profile was changed, but the radio is still off: the modem did not answer in time. " +
                             "Profile 1 is now \(cmnetPapWords). Run `RMNet radio on`, or use the Radio switch on the window's Network screen.",
                    "profileSentence: the radio left off")
        expectEqual(profileSentence(toCmnet(.radioLeftOff("AT+CFUN=1 was refused"))),
                    "The profile was changed, but the radio is still off: AT+CFUN=1 was refused. " +
                    "Profile 1 is now \(cmnetPapWords). Run `RMNet radio on`, or use the Radio switch on the window's Network screen.",
                    "profileSentence: a reason without a full stop")
        for (why, name) in [("", "empty"), ("  \n", "only spaces")] {
            expectEqual(profileSentence(toCmnet(.radioLeftOff(why))),
                        "The profile was changed, but the radio is still off: the radio could not be switched on. " +
                        "Profile 1 is now \(cmnetPapWords). Run `RMNet radio on`, or use the Radio switch on the window's Network screen.",
                        "profileSentence: a reason that is \(name)")
        }
        for (why, shownWhy) in [("Is the modem attached?", "is the modem attached?"), ("AT+CFUN=1 failed!", "AT+CFUN=1 failed!"),
                                ("The modem did not answer in time. ", "the modem did not answer in time.")] {
            expectEqual(profileSentence(toCmnet(.radioLeftOff(why))),
                        "The profile was changed, but the radio is still off: \(shownWhy) " +
                        "Profile 1 is now \(cmnetPapWords). Run `RMNet radio on`, or use the Radio switch on the window's Network screen.",
                        "profileSentence: a reason ending \"\(why.last.map { String($0) } ?? "")\" gets no second stop")
        }

        // Only +CME ERROR: 16 (incorrect password) is the SIM refusing the PIN (F10).
        let wrong = "+CME ERROR: 16"
        func refusedWith(_ line: String?, _ sim: SimInfo?) -> String { pinSentence(PinOutcome(accepted: false, sim: sim, refusal: line)) }
        let asks2 = SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10)
        let asks1 = SimInfo(state: .pin, pinLock: true, pinAttempts: 1, pukAttempts: 10)
        let asksUnread = SimInfo(state: .pin, pinLock: true, pinAttempts: nil, pukAttempts: nil)
        let pukNow = SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10)
        let noSim = SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil)
        expectEqual(refusedWith(wrong, asks2), "The SIM refused the PIN. 2 attempts left.", "pinSentence: refused, 2 left")
        expectEqual(refusedWith(wrong, asks1),
                    "The SIM refused the PIN. 1 attempt left: the next wrong PIN blocks the SIM until its PUK is entered.",
                    "pinSentence: refused, 1 left")
        expectEqual(refusedWith(wrong, asksUnread), "The SIM refused the PIN. The attempts left could not be read.",
                    "pinSentence: refused, attempts unread")
        expectEqual(refusedWith(wrong, pukNow),
                    "The SIM refused the PIN and is now blocked: it needs its PUK from the carrier. RMNet does not enter PUKs.",
                    "pinSentence: blocked")
        expectEqual(refusedWith(wrong, nil),
                    "The SIM refused the PIN. Its state could not be read; check the attempts left (RMNet sim) before entering it again.",
                    "pinSentence: refused, state unread")
        expectEqual(refusedWith(wrong, noSim), "The SIM refused the PIN (SIM: not inserted).", "pinSentence: refused, another state")
        expectEqual(refusedWith("+CME ERROR:16", asks2), "The SIM refused the PIN. 2 attempts left.",
                    "pinSentence: +CME ERROR:16 without a space is the wrong PIN too")
        // Any other line, such as 14 (SIM busy), is the modem not taking the PIN: an attempt may or may not
        // have been used, so the owner checks before entering it again.
        let busy = "+CME ERROR: 14"
        expectEqual(refusedWith(busy, asks2),
                    "The modem did not take the PIN (+CME ERROR: 14). 2 attempts left; check them before entering it again.",
                    "pinSentence: SIM busy, 2 left")
        expectEqual(refusedWith(busy, asks1),
                    "The modem did not take the PIN (+CME ERROR: 14). 1 attempt left; check them before entering it again.",
                    "pinSentence: SIM busy, 1 left")
        expectEqual(refusedWith("ERROR", asks2),
                    "The modem did not take the PIN (ERROR). 2 attempts left; check them before entering it again.",
                    "pinSentence: a bare ERROR")
        expectEqual(refusedWith(busy, asksUnread),
                    "The modem did not take the PIN (+CME ERROR: 14). The attempts left could not be read; check them (RMNet sim) "
                        + "before entering it again.", "pinSentence: SIM busy, attempts unread")
        expectEqual(refusedWith(busy, nil),
                    "The modem did not take the PIN (+CME ERROR: 14). The SIM's state could not be read; check the attempts left "
                        + "(RMNet sim) before entering it again.", "pinSentence: SIM busy, state unread")
        expectEqual(refusedWith(busy, pukNow),
                    "The modem did not take the PIN (+CME ERROR: 14). The SIM is now blocked: it needs its PUK from the carrier. "
                        + "RMNet does not enter PUKs.", "pinSentence: SIM busy, now blocked")
        expectEqual(refusedWith(busy, noSim), "The modem did not take the PIN (+CME ERROR: 14). SIM: not inserted.",
                    "pinSentence: SIM busy, another state")
        expectEqual(refusedWith(nil, asks2),
                    "The modem did not take the PIN. 2 attempts left; check them before entering it again.",
                    "pinSentence: no refusal line")
        expectEqual(refusedWith("+CME ERROR: 14\u{202E}", asks2),
                    "The modem did not take the PIN (+CME ERROR: 14\u{FFFD}). 2 attempts left; check them before entering it again.",
                    "pinSentence: the modem's line is display-safe")
        expectEqual(pinSentence(PinOutcome(accepted: true, sim: readySim)), "The SIM accepted the PIN and is ready.",
                    "pinSentence: accepted")
        expectEqual(pinSentence(PinOutcome(accepted: true, sim: nil)), "The SIM accepted the PIN.", "pinSentence: accepted, unread")
        expectEqual(pinSentence(PinOutcome(accepted: true, sim: SimInfo(state: .pin2, pinLock: true, pinAttempts: 3, pukAttempts: 10))),
                    "The SIM accepted the PIN (SIM: asks for PIN2).", "pinSentence: accepted, another state")

        // --- cell lock (AT+QNWLOCK) ------------------------------------------------------------
        check(parseLteCellLock(["+QNWLOCK: \"common/4g\",0"]) == [], "parseLteCellLock: unlocked")
        check(parseLteCellLock(["+QNWLOCK: \"common/4g\",2,1300,128,100,45"]) == [
            LteLockedCell(earfcn: 1300, pci: 128), LteLockedCell(earfcn: 100, pci: 45),
        ], "parseLteCellLock: 2 cells")
        check(parseLteCellLock(["+QNWLOCK: \"common/4g\",2,1300,128"]) == nil, "parseLteCellLock: count mismatch")
        check(parseLteCellLock([]) == nil, "parseLteCellLock: empty")

        check(parseNrCellLock(["+QNWLOCK: \"common/5g\",0"]) == .unlocked, "parseNrCellLock: unlocked")
        check(parseNrCellLock(["+QNWLOCK: \"common/5g\",147,520110,30,41"]) == .locked(
            NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)), "parseNrCellLock: locked")
        check(parseNrCellLock(["+QNWLOCK: \"common/5g\",147,520110,30"]) == nil, "parseNrCellLock: missing band")

        check(parseCellLockPersist(["+QNWLOCK: \"save_ctrl\",0,0"])! == (lte: false, nr: false), "parseCellLockPersist: 0,0")
        check(parseCellLockPersist(["+QNWLOCK: \"save_ctrl\",1,1"])! == (lte: true, nr: true), "parseCellLockPersist: 1,1")
        check(parseCellLockPersist(["+QNWLOCK: \"save_ctrl\",2,0"]) == nil, "parseCellLockPersist: invalid 2")

        check(nrCellLockProblem(NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41), supportedSaBands: [25, 41, 71]) == nil,
              "nrCellLockProblem: valid")
        check(nrCellLockProblem(NrCellLock(pci: 1008, arfcn: 520110, scsKHz: 30, band: 41)) != nil, "nrCellLockProblem: pci > 1007")
        check(nrCellLockProblem(NrCellLock(pci: 147, arfcn: 0, scsKHz: 30, band: 41)) != nil, "nrCellLockProblem: arfcn 0")
        check(nrCellLockProblem(NrCellLock(pci: 147, arfcn: 520110, scsKHz: 25, band: 41)) != nil, "nrCellLockProblem: bad scs")
        check(nrCellLockProblem(NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 78), supportedSaBands: [25, 41]) != nil,
              "nrCellLockProblem: unsupported band")

        check(lteCellLockProblem([LteLockedCell(earfcn: 1300, pci: 128)]) == nil, "lteCellLockProblem: valid")
        check(lteCellLockProblem([LteLockedCell(earfcn: 1300, pci: 504)]) != nil, "lteCellLockProblem: pci > 503")
        check(lteCellLockProblem([LteLockedCell(earfcn: 1300, pci: 1), LteLockedCell(earfcn: 1300, pci: 1)]) != nil,
              "lteCellLockProblem: duplicate")
        check(lteCellLockProblem((0...10).map { LteLockedCell(earfcn: 100, pci: $0) }) != nil,
              "lteCellLockProblem: > 10 cells")

        expectEqual(nrCellLockCommand(nil), "AT+QNWLOCK=\"common/5g\",0", "nrCellLockCommand: unlock")
        expectEqual(nrCellLockCommand(NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)),
                    "AT+QNWLOCK=\"common/5g\",147,520110,30,41", "nrCellLockCommand: lock")
        expectEqual(lteCellLockCommand([]), "AT+QNWLOCK=\"common/4g\",0", "lteCellLockCommand: unlock")
        expectEqual(lteCellLockCommand([LteLockedCell(earfcn: 1300, pci: 128), LteLockedCell(earfcn: 100, pci: 45)]),
                    "AT+QNWLOCK=\"common/4g\",2,1300,128,100,45", "lteCellLockCommand: lock")
        expectEqual(cellLockPersistCommand(lte: true, nr: false), "AT+QNWLOCK=\"save_ctrl\",1,0", "cellLockPersistCommand")

        // A cell in use, against the serving cell and the carriers read with the lock.
        let saLeg = parseServingCell(
            ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"FDD\",310,260,00A1B2C3D,683,001A2B,396250,25,3,-92,-11,20,0,-"])
        let scc = parseCarrierComponents(["+QCAINFO: \"PCC\",396250,3,\"NR5G BAND 25\",683",
                                          "+QCAINFO: \"SCC\",520110,12,\"NR5G BAND 41\",2,147,0,-,-"])
        let n41 = NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)
        check(cellInUseLock(.nr(n41), serving: saLeg, carriers: scc) == .nr(n41),
              "cellInUseLock: a secondary carrier is in use (its SCS the owner's: the modem gives none for it)")
        check(cellInUseLock(.nr(NrCellLock(pci: 683, arfcn: 396250, scsKHz: 30, band: 25)), serving: saLeg, carriers: scc)
                == .refused("The modem reports a subcarrier spacing of 15 kHz for that cell, not 30 kHz."),
              "cellInUseLock: the serving leg's SCS must be the lock's")
        check(cellInUseLock(.nr(n41), serving: saLeg, carriers: []) == .refused(
                "The modem no longer uses that 5G SA cell (n41, PCI 147, ARFCN 520110)."),
              "cellInUseLock: a carrier gone since")
        let endc = parseServingCell(["+QENG: \"servingcell\",\"NOCONN\"",
                                     "+QENG: \"LTE\",\"FDD\",310,260,0ABC123,101,1300,3,5,5,5A0B,-95,-11,-65,15,9,-,-",
                                     "+QENG: \"NR5G-NSA\",310,260,147,-90,20,-11,520110,41,12,1"])
        check(cellInUseLock(.nr(n41), serving: endc, carriers: scc) == .refused(
                "The modem no longer uses that 5G SA cell (n41, PCI 147, ARFCN 520110)."),
              "cellInUseLock: an NSA leg is not a 5G SA cell in use")
        check(cellInUseLock(.serving(scsKHz: nil), serving: endc, carriers: []) == .lte(LteLockedCell(earfcn: 1300, pci: 101)),
              "cellInUseLock: on EN-DC the serving cell is the LTE leg")
        let lteScc = parseCarrierComponents(["+QCAINFO: \"SCC\",66786,100,\"LTE BAND 66\",1,128,-95,-11,-65,15"])
        check(cellInUseLock(.lte(LteLockedCell(earfcn: 66786, pci: 128)), serving: endc, carriers: lteScc)
                == .lte(LteLockedCell(earfcn: 66786, pci: 128)), "cellInUseLock: an LTE carrier is in use")
        check(cellInUseLock(.serving(scsKHz: nil), serving: nil, carriers: [])
                == .refused("No lockable 5G SA or LTE serving cell is currently active."), "cellInUseLock: nothing serves")
        check(cellInUseProblem(.serving(scsKHz: 45)) != nil && cellInUseProblem(.serving(scsKHz: 60)) == nil
                && cellInUseProblem(.serving(scsKHz: nil)) == nil, "cellInUseProblem: an SCS given must be a spacing")

        let lockState = CellLockState(lte: [], nr: NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41),
                                      persistLte: false, persistNr: false)
        check(JSONSerialization.isValidJSONObject(cellLockJSON(lockState)), "cellLockJSON: valid")
        expectEqual(cellLockSentence(.changed(before: CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false),
                                              after: lockState)),
                    "Locked 5G SA cell to band n41, PCI 147, ARFCN 520110, SCS 30 kHz.", "cellLockSentence: locked NR")

        // --- IMEI (AT+EGMR) --------------------------------------------------------------------
        check(parseImei(["+EGMR: \"000000000000141\""]) == "000000000000141", "parseImei: fixture")
        check(parseImei(["+EGMR: \"123\""]) == nil, "parseImei: short gives nil")
        check(parseImei([]) == nil, "parseImei: empty gives nil")
        check(imeiCheckDigit(forFirst14: "00000000000014") == 1, "imeiCheckDigit: a made-up IMEI")
        check(imeiCheckDigit(forFirst14: "00000000000009") == 1, "imeiCheckDigit: another made-up IMEI")
        check(imeiProblem("000000000000141") == nil, "imeiProblem: valid (made up)")
        check(imeiProblem("000000000000091") == nil, "imeiProblem: valid (another made up)")
        expectEqual(imeiProblem("000000000000142") ?? "",
                    "The IMEI check digit is not valid (expected 1 as the 15th digit).", "imeiProblem: bad check digit")
        expectEqual(imeiProblem("12345") ?? "", "An IMEI is 15 ASCII digits (0 to 9).", "imeiProblem: too short")
        expectEqual(imeiCommand("000000000000141"), "AT+EGMR=1,7,\"000000000000141\"", "imeiCommand")
        check(JSONSerialization.isValidJSONObject(imeiJSON("000000000000141")), "imeiJSON: valid")

        // --- IMEI words and SIM states told apart ------------------------------------------------
        let restartSentence = "The IMEI is now 123456789012347, but the modem was not restarted. Made-up reason."
        expectEqual(imeiSentence(.restartFailed(before: "000000000000091", after: "123456789012347",
                                                sentence: restartSentence)), restartSentence,
                    "imeiSentence: a restart that failed says so")
        expectEqual(imeiQuestion(before: "000000000000091", after: "123456789012347", reboot: false,
                                 module: "TESTMODULE1").message,
                    "Module: TESTMODULE1.\nCurrent IMEI: 000000000000091.\nNew IMEI: 123456789012347.\n"
                    + "The new IMEI is stored and takes effect after the next modem restart.",
                    "imeiQuestion: names the module it is confirmed for")
        check(service.imeiReading() == .failure(ModemFailure(message: "The modem is not attached.")),
              "imeiReading: a service without its own reads the IMEI, on a module not known")
        check(simConclusive(.ready) == true && simConclusive(.pin) == true && simConclusive(.notInserted) == false
                && simConclusive(.failure) == false && simConclusive(.busy) == nil && simConclusive(.other("x")) == nil,
              "simConclusive: usable, none usable, or not told yet")

        print("modem settings: \(checks) checks passed")
    }
}
