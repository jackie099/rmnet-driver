// The command-line verbs for the modem's network and settings: `network`, `radio`, `mode`, `apn`, `sim`,
// `usbmode`, `bands`, and `at`, which sends one AT command as typed. The parser (wrong usage is nil:
// main.swift prints the usage line and exits 2 without opening the port; `at` is never nil, see `parseAt`) and
// what each verb prints, over a `ModemServing`, the readSecret that reads a password or a PIN without echo, the
// question asked on the terminal before a restart, and the output. Foundation only, with ModemNetwork.swift
// and ModemSettings.swift: `make app-test` builds it with them and a fake service.
//
// Each verb prints lines starting `<verb>: ` (the `network` rows and the `apn` profile lines aside; `usbmode`
// prints `usb mode: `, `usb mode set to …`, its other-mode warning and `cancelled; nothing changed`; `bands`
// prints `<RAT>: …` and its indented `supported: …`, and `<RAT> bands: …` and `<RAT> bands set to …`). The exit
// codes: 0 on success; 1 after a failure, printed as one line `<verb>: <sentence>` (a `bands reset` of all three
// that stops at a failure adds `bands: not reset: …`), or the modem's error line for `at`; 2 for wrong usage
// (main.swift, which never opens the port), for `at` refusing its command (nothing sent), and for `usbmode set`
// with no terminal to ask on before a restart (nothing changed). `at` prints the modem's answer as
// an AT terminal shows it, and its own lines (`at: …`) on standard error: see `sendAt`. A password or PIN goes
// from readSecret to the service and nowhere else: no line printed holds one. Nothing here logs.
import Foundation

enum CellUnlockScope: Equatable { case both, sa, lte }

enum ModemCommand: Equatable {
    case network(json: Bool)
    case antennas(json: Bool)
    case radio(on: Bool?)                       // nil: show
    case mode(String?)                          // nil: show; else the mode as typed, upper-cased, the RATs in
                                                // the order typed: one canonicalMode accepts, not its reordered
                                                // value, so a put-back restores the modem's own string (R8, R17)
    case apnShow(json: Bool)
    case apnSet(apn: String?, type: PdpType?, user: String?, askPassword: Bool, clearPassword: Bool, auth: AuthMethod?,
                redial: Bool)
    case sim(json: Bool)
    case simUnlock(lastAttempt: Bool)
    case simSlot(json: Bool)                    // the slot in use
    case simSlotSet(Int, yes: Bool)             // 1 or 2
    case usbMode(json: Bool)
    case usbModeSet(UsbNetMode, reboot: Bool, yes: Bool)    // reboot: no --no-reboot; yes: --yes
    case at(String, timeout: Int)               // one line atCommandProblem accepts; seconds, 1 to 300
    case atRefused(String)                      // `at` with a command or option it does not take: why
    case bands(json: Bool)
    case bandsSet(BandRat, [Int])               // the bands sorted, each once (at least one)
    case bandsReset(BandRat?)                   // nil: lte, nsa and sa, in that order
    case cellShow(json: Bool)
    case cellLockNr(NrCellLock)
    case cellLockCurrent(scsKHz: Int?)          // the serving cell's SCS when the modem gives none (`--scs`)
    case cellLockLte([LteLockedCell])
    case cellUnlock(CellUnlockScope)
    case cellPersist(Bool)
    case imeiShow(json: Bool)
    case imeiSet(String, reboot: Bool, yes: Bool)
    case imeiHistory(json: Bool)               // reads only the history file; never the AT port

    /// Radio on or off, a mode set, apn set, sim unlock, usbmode set, bands set/reset, cell lock/persist
    /// and imei set: main.swift ignores the stopping signals for these. Not `at`: it sends what the owner
    /// typed, as an AT terminal would, and Ctrl-C stops it (the modem may still carry out a command already sent).
    var changesModem: Bool {
        switch self {
        case .network, .antennas, .apnShow, .sim, .usbMode, .at, .atRefused, .bands, .cellShow, .imeiShow,
             .imeiHistory, .simSlot:
            return false
        case .radio(let on): return on != nil
        case .mode(let mode): return mode != nil
        case .apnSet, .simUnlock, .usbModeSet, .bandsSet, .bandsReset,
             .cellLockNr, .cellLockCurrent, .cellLockLte, .cellUnlock, .cellPersist, .imeiSet, .simSlotSet:
            return true
        }
    }
}

let modemVerbs: Set<String> = ["network", "antennas", "radio", "mode", "apn", "sim", "usbmode", "at", "bands",
                               "cell", "imei"]

/// Appended to main.swift's usage line.
let modemUsage = "network [--json] | antennas [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…] | "
    + "apn [show] [--json] | apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>] "
    + "[--password | --no-password] [--auth none|pap|chap|pap-or-chap] [--no-redial] | "
    + "sim [--json] | sim unlock [--last-attempt] | sim slot [--json] | sim slot set 1|2 [--yes] | "
    + "usbmode [--json] | usbmode set qmi|ecm|mbim|rndis [--no-reboot] [--yes] | "
    + "at [--timeout <seconds>] <command> | "
    + "bands [--json] | bands set lte|nsa|sa <bands> | bands reset [lte|nsa|sa] | "
    + "cell [--json] | cell lock sa <pci> <arfcn> <scs> <band> | cell lock current [--scs <kHz>] | "
    + "cell lock lte <earfcn>:<pci>[,…] | cell unlock [sa|lte] | cell persist on|off | "
    + "imei [--json] | imei set <imei> [--no-reboot] [--yes] | imei history [--json]"

// MARK: - Parsing

/// The words including the verb; nil for wrong usage.
func parseModem(_ words: [String]) -> ModemCommand? {
    guard let verb = words.first else { return nil }
    let rest = Array(words.dropFirst())
    switch verb {
    case "network":
        return jsonOption(rest).map { .network(json: $0) }
    case "antennas":
        return jsonOption(rest).map { .antennas(json: $0) }
    case "radio":
        switch rest {
        case []: return .radio(on: nil)
        case ["on"]: return .radio(on: true)
        case ["off"]: return .radio(on: false)
        default: return nil
        }
    case "mode":
        if rest.isEmpty { return .mode(nil) }
        guard rest.count == 1, canonicalMode(rest[0]) != nil else { return nil }
        return .mode(rest[0].uppercased())        // ASCII names only, as canonicalMode accepts them
    case "apn":
        if rest.first == "set" { return parseApnSet(Array(rest.dropFirst())) }
        return jsonOption(rest.first == "show" ? Array(rest.dropFirst()) : rest).map { .apnShow(json: $0) }
    case "sim":
        if rest.first == "slot" { return parseSimSlotWords(Array(rest.dropFirst())) }
        guard rest.first == "unlock" else { return jsonOption(rest).map { .sim(json: $0) } }
        switch Array(rest.dropFirst()) {
        case []: return .simUnlock(lastAttempt: false)
        case ["--last-attempt"]: return .simUnlock(lastAttempt: true)
        default: return nil                       // a PIN is never taken from the command line
        }
    case "usbmode":
        guard rest.first == "set" else { return jsonOption(rest).map { .usbMode(json: $0) } }
        return parseUsbModeSet(Array(rest.dropFirst()))
    case "at":
        return parseAt(rest)
    case "bands":
        switch rest.first {
        case "set":
            return parseBandsSet(Array(rest.dropFirst()))
        case "reset":
            switch rest.count {
            case 1: return .bandsReset(nil)
            case 2: return BandRat(rawValue: rest[1]).map { .bandsReset($0) }
            default: return nil
            }
        default:
            return jsonOption(rest).map { .bands(json: $0) }
        }
    case "cell":
        return parseCell(rest)
    case "imei":
        if rest.first == "set" { return parseImeiSet(Array(rest.dropFirst())) }
        if rest.first == "history" { return jsonOption(Array(rest.dropFirst())).map { .imeiHistory(json: $0) } }
        return jsonOption(rest).map { .imeiShow(json: $0) }
    default:
        return nil
    }
}

private func parseAsciiInt(_ word: String) -> Int? {
    guard !word.isEmpty, word.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
    return Int(word)
}

private func parseCell(_ words: [String]) -> ModemCommand? {
    switch words.first {
    case "lock":
        let args = Array(words.dropFirst())
        switch args {
        case ["current"]:
            return .cellLockCurrent(scsKHz: nil)
        case _ where args.count == 3 && args[0] == "current" && args[1] == "--scs":
            return parseAsciiInt(args[2]).map { .cellLockCurrent(scsKHz: $0) }
        case _ where args.count == 5 && args[0] == "sa":
            let bandRaw = (args[4].first == "n" || args[4].first == "N") ? String(args[4].dropFirst()) : args[4]
            guard let pci = parseAsciiInt(args[1]),
                  let arfcn = parseAsciiInt(args[2]),
                  let scs = parseAsciiInt(args[3]),
                  let band = parseBandNumber(bandRaw[...]) else { return nil }
            return .cellLockNr(NrCellLock(pci: pci, arfcn: arfcn, scsKHz: scs, band: band))
        case _ where args.count == 2 && args[0] == "lte":
            let items = args[1].split(separator: ",", omittingEmptySubsequences: false)
            guard !items.isEmpty else { return nil }
            var cells: [LteLockedCell] = []
            for item in items {
                let parts = item.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let earfcn = parseAsciiInt(String(parts[0])),
                      let pci = parseAsciiInt(String(parts[1])) else { return nil }
                cells.append(LteLockedCell(earfcn: earfcn, pci: pci))
            }
            return .cellLockLte(cells)
        default:
            return nil
        }
    case "unlock":
        switch words.dropFirst().map({ $0 }) {
        case []: return .cellUnlock(.both)
        case ["sa"]: return .cellUnlock(.sa)
        case ["lte"]: return .cellUnlock(.lte)
        default: return nil
        }
    case "persist":
        switch words.dropFirst().map({ $0 }) {
        case ["on"]: return .cellPersist(true)
        case ["off"]: return .cellPersist(false)
        default: return nil
        }
    default:
        return jsonOption(words).map { .cellShow(json: $0) }
    }
}

/// The words after `sim slot`: nothing or `--json` (show), or `set` and the slot (`1` or `2`) with `--yes` at most once.
private func parseSimSlotWords(_ words: [String]) -> ModemCommand? {
    guard words.first == "set" else { return jsonOption(words).map { .simSlot(json: $0) } }
    let rest = Array(words.dropFirst())
    guard let slotWord = rest.first, let slot = Int(slotWord), simSlots.contains(slot), slotWord.count == 1 else { return nil }
    switch Array(rest.dropFirst()) {
    case []: return .simSlotSet(slot, yes: false)
    case ["--yes"]: return .simSlotSet(slot, yes: true)
    default: return nil
    }
}

private func parseImeiSet(_ words: [String]) -> ModemCommand? {
    guard let value = words.first, !value.hasPrefix("--") else { return nil }
    var reboot = true
    var yes = false
    var seen = Set<String>()
    for option in words.dropFirst() {
        guard seen.insert(option).inserted else { return nil }
        switch option {
        case "--no-reboot": reboot = false
        case "--yes": yes = true
        default: return nil
        }
    }
    return .imeiSet(value, reboot: reboot, yes: yes)
}

/// The words after `bands set`: the RAT (lower case, as printed in the usage), then one word of band numbers
/// separated by `,` or `:`, each prefixed `b` or `B` (lte) or `n` or `N` (nsa, sa) or not at all; sorted, each
/// band once. A prefix of the other RAT, an empty number or anything but ASCII digits after the prefix is wrong
/// usage; a band the modem does not support is refused when run.
private func parseBandsSet(_ words: [String]) -> ModemCommand? {
    guard words.count == 2, let rat = BandRat(rawValue: words[0]) else { return nil }
    let prefixes: Set<Character> = rat == .lte ? ["b", "B"] : ["n", "N"]
    var bands: [Int] = []
    for item in words[1].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ":" }) {
        let number = item.first.map { prefixes.contains($0) } == true ? item.dropFirst() : item
        guard let band = parseBandNumber(number) else { return nil }
        bands.append(band)
    }
    return .bandsSet(rat, bandSorted(bands))
}

/// `at --timeout`'s range, and the wait without it, in seconds.
private let atTimeouts = 1...300
private let atDefaultTimeout = 10

/// The words after `at`: `--timeout <seconds>` first, if given, then the command's words, joined with single
/// spaces, with spaces at the ends dropped (the port knows its answer by the echo of the line, and an echo
/// loses those spaces). Never nil: a command or timeout `at` does not take is `.atRefused` with the reason,
/// printed as `at: <reason>` in place of the usage line.
private func parseAt(_ words: [String]) -> ModemCommand {
    var rest = words[...]
    var timeout = atDefaultTimeout
    if rest.first == "--timeout" {
        rest = rest.dropFirst()
        guard let seconds = rest.first.flatMap({ Int($0) }), atTimeouts.contains(seconds) else {
            return .atRefused("--timeout takes a whole number of seconds from \(atTimeouts.lowerBound) to "
                              + "\(atTimeouts.upperBound)")
        }
        timeout = seconds
        rest = rest.dropFirst()
    }
    let line = rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " "))
    if let problem = atCommandProblem(line) { return .atRefused(problem) }
    return .at(line, timeout: timeout)
}

private let usbModeOptions: [String: UsbNetMode] =
    Dictionary(uniqueKeysWithValues: UsbNetMode.allCases.map { ($0.name, $0) })

/// The words after `usbmode set`: the mode's name (lower case, as printed), then `--no-reboot` and `--yes`,
/// each at most once, in either order.
private func parseUsbModeSet(_ words: [String]) -> ModemCommand? {
    guard let name = words.first, let mode = usbModeOptions[name] else { return nil }
    var reboot = true
    var yes = false
    var seen = Set<String>()
    for option in words.dropFirst() {
        guard seen.insert(option).inserted else { return nil }
        switch option {
        case "--no-reboot": reboot = false
        case "--yes": yes = true
        default: return nil
        }
    }
    return .usbModeSet(mode, reboot: reboot, yes: yes)
}

/// Nothing: false; `--json`: true; anything else: nil.
private func jsonOption(_ words: [String]) -> Bool? {
    switch words {
    case []: return false
    case ["--json"]: return true
    default: return nil
    }
}

private let typeOptions: [String: PdpType] = ["ipv4": .ipv4, "ipv6": .ipv6, "ipv4v6": .ipv4v6]
private let authOptions: [String: AuthMethod] = ["none": AuthMethod.none, "pap": .pap, "chap": .chap,
                                                  "pap-or-chap": .papOrChap]

/// The words after `apn set`. Each option at most once; `--password` and `--no-password` not together; at
/// least one option that changes a setting (`--no-redial` alone changes nothing). The word after `--apn` or
/// `--user` is the value as given, whatever it is (also '').
private func parseApnSet(_ words: [String]) -> ModemCommand? {
    var apn: String? = nil
    var type: PdpType? = nil
    var user: String? = nil
    var auth: AuthMethod? = nil
    var askPassword = false
    var clearPassword = false
    var redial = true
    var seen = Set<String>()
    var i = 0
    while i < words.count {
        let option = words[i]
        i += 1
        guard seen.insert(option).inserted else { return nil }
        switch option {
        case "--password": askPassword = true
        case "--no-password": clearPassword = true
        case "--no-redial": redial = false
        case "--apn", "--user", "--type", "--auth":
            guard i < words.count else { return nil }
            let value = words[i]
            i += 1
            switch option {
            case "--apn": apn = value
            case "--user": user = value
            case "--type":
                guard let t = typeOptions[value] else { return nil }
                type = t
            default:
                guard let a = authOptions[value] else { return nil }
                auth = a
            }
        default:
            return nil
        }
    }
    guard !(askPassword && clearPassword) else { return nil }
    guard apn != nil || type != nil || user != nil || auth != nil || askPassword || clearPassword else { return nil }
    return .apnSet(apn: apn, type: type, user: user, askPassword: askPassword, clearPassword: clearPassword, auth: auth,
                   redial: redial)
}

// MARK: - Running

/// Runs `command` (blocking: off the main thread) and returns the exit code: 0, 1, or 2 when `usbmode set`
/// would restart the modem without a terminal to ask on or `at` refuses its command. `driverProfile` is the
/// driver's `RMNetProfile` (nil when the driver is not attached); `readSecret` reads a password or PIN without
/// echo after showing its prompt (nil without a terminal); `ask` shows a question on the terminal and reads
/// one line (nil without a terminal, see `askOnTerminal`); `output` prints one line on standard output,
/// `errorOutput` one on standard error (only `at` uses it). `imeiHistory`: where `imei set` records its change and
/// `imei history` reads (main.swift gives ImeiHistoryFile.standard); nil records nothing, and `imei history` fails.
func runModem(_ command: ModemCommand, service: ModemServing, driverProfile: Int?,
              readSecret: (String) -> String?, ask: (String) -> String?, output: (String) -> Void,
              errorOutput: (String) -> Void, imeiHistory: ImeiHistoryRecorder? = nil) -> Int32 {
    switch command {
    case .network(let json):
        return showNetwork(service, json: json, output)
    case .antennas(let json):
        return showAntennas(service, json: json, output)
    case .radio(let on):
        guard let on else { return showRadio(service, output) }
        switch service.setRadio(on: on) {
        case .failure(let failure): return fail("radio", failure.message, output)
        case .success(let change):
            output("radio: \(radioSentence(change))")
            return 0
        }
    case .mode(let mode):
        guard let mode else { return showMode(service, output) }
        return setMode(service, mode, output)
    case .apnShow(let json):
        return showProfiles(service, driverProfile: driverProfile, json: json, output)
    case let .apnSet(apn, type, user, askPassword, clearPassword, auth, redial):
        let options = ProfileOptions(apn: apn, type: type, user: user, auth: auth, askPassword: askPassword,
                                     clearPassword: clearPassword, redial: redial)
        return setProfile(service, driverProfile ?? 1, options, readSecret: readSecret, output)
    case .sim(let json):
        switch service.sim() {
        case .failure(let failure): return fail("sim", failure.message, output)
        case .success(let sim):
            if json { return outputJSON("sim", simJSON(sim), output) }
            for row in simRows(sim) {
                // The SIM row is the state itself: `sim: ready`; the others `sim: pin lock: off`.
                output(row.label == "SIM" ? "sim: \(row.value)" : "sim: \(row.label.lowercased()): \(row.value)")
            }
            return 0
        }
    case .simUnlock(let lastAttempt):
        return unlockSim(service, lastAttempt: lastAttempt, readSecret: readSecret, output)
    case .simSlot(let json):
        switch service.simSlot() {
        case .failure(let failure): return fail("sim", failure.message, output)
        case .success(let slot):
            if json { return outputJSON("sim", ["activeSlot": slot], output) }
            output("sim: slot \(slot)")
            return 0
        }
    case let .simSlotSet(slot, yes):
        return setSimSlot(service, slot, yes: yes, ask: ask, output)
    case .usbMode(let json):
        return showUsbMode(service, json: json, output)
    case let .usbModeSet(mode, reboot, yes):
        return setUsbMode(service, mode, reboot: reboot, yes: yes, ask: ask, output)
    case let .at(line, timeout):
        return sendAt(service, line, timeout: timeout, output, errorOutput)
    case .atRefused(let reason):
        // Nothing is sent: the port is not even opened.
        errorOutput("at: \(reason)")
        return 2
    case .bands(let json):
        return showBands(service, json: json, output)
    case let .bandsSet(rat, bands):
        return changeBands(service, [rat], output) { _ in bands }
    case .bandsReset(let rat):
        return changeBands(service, rat.map { [$0] } ?? BandRat.allCases, output) { $0.supported }
    case .cellShow(let json):
        return showCell(service, json: json, output)
    case .cellLockNr(let lock):
        switch service.setNrCellLock(lock) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .cellLockCurrent(let scs):
        // The serving cell is read and locked in one port session (ModemService.lockCellInUse); its subcarrier
        // spacing is the modem's, or `--scs` when the modem gives none, never guessed.
        switch service.lockCellInUse(.serving(scsKHz: scs)) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .cellLockLte(let cells):
        switch service.setLteCellLock(cells) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .cellUnlock(let scope):
        return unlockCell(service, scope: scope, output)
    case .cellPersist(let persist):
        switch service.setCellLockPersist(lte: persist, nr: persist) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .imeiShow(let json):
        switch service.imei() {
        case .failure(let failure): return fail("imei", failure.message, output)
        case .success(let value):
            if json { return outputJSON("imei", imeiJSON(value), output) }
            output("imei: \(value)")
            return 0
        }
    case let .imeiSet(value, reboot, yes):
        return setImei(service, value, reboot: reboot, yes: yes, ask: ask, history: imeiHistory, output)
    case .imeiHistory(let json):
        guard let keeper = imeiHistory?.keeper else { return fail("imei", "No IMEI history is kept here.", output) }
        switch keeper.load() {
        case .failure(let failure): return fail("imei", failure.message, output)
        case .success(let history):
            if json { return outputJSON("imei", imeiHistoryJSON(history, location: keeper.location), output) }
            for line in imeiHistoryLines(history, location: keeper.location) { output(line) }
            return 0
        }
    }
}

/// One failure line, exit 1.
private func fail(_ verb: String, _ sentence: String, _ output: (String) -> Void) -> Int32 {
    output("\(verb): \(sentence)")
    return 1
}

/// The object (or array) pretty-printed with sorted keys, as one output.
private func outputJSON(_ verb: String, _ object: Any, _ output: (String) -> Void) -> Int32 {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return fail(verb, "The answer could not be written as JSON.", output)
    }
    output(text)
    return 0
}

private func showNetwork(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("network", failure.message, output)
    case .success(let info):
        if json { return outputJSON("network", networkJSON(info), output) }
        for row in networkRows(info) { output("\(row.label.lowercased()): \(row.value)") }
        return 0
    }
}

private func showAntennas(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.antennas() {
    case .failure(let failure): return fail("antennas", failure.message, output)
    case .success(let sets):
        if json { return outputJSON("antennas", antennasJSON(sets), output) }
        if sets.isEmpty {
            output("antennas: none reported")
            return 0
        }
        for row in antennaRows(sets) { output("\(row.label.lowercased()): \(row.value)") }
        return 0
    }
}

private func showCell(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.cellLock() {
    case .failure(let failure): return fail("cell", failure.message, output)
    case .success(let state):
        if json { return outputJSON("cell", cellLockJSON(state), output) }
        for row in cellLockRows(state) { output("\(row.label.lowercased()): \(row.value)") }
        return 0
    }
}

private func unlockCell(_ service: ModemServing, scope: CellUnlockScope, _ output: (String) -> Void) -> Int32 {
    switch scope {
    case .sa:
        switch service.setNrCellLock(nil) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .lte:
        switch service.setLteCellLock([]) {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let ch):
            output("cell: \(cellLockSentence(ch))")
            return 0
        }
    case .both:
        let state: CellLockState
        switch service.cellLock() {
        case .failure(let failure): return fail("cell", failure.message, output)
        case .success(let read): state = read
        }
        if !state.isLocked {
            output("cell: already unlocked")
            return 0
        }
        if state.nr != nil {
            switch service.setNrCellLock(nil) {
            case .failure(let failure): return fail("cell", failure.message, output)
            case .success(let ch): output("cell: \(cellLockSentence(ch))")
            }
        }
        if !state.lte.isEmpty {
            switch service.setLteCellLock([]) {
            case .failure(let failure): return fail("cell", failure.message, output)
            case .success(let ch): output("cell: \(cellLockSentence(ch))")
            }
        }
        return 0
    }
}

/// `imei set`. Reads the IMEI and the module first (one port open), then asks (unless --yes; without a terminal it
/// changes nothing and exits 2), also with --no-reboot, naming both IMEIs and the module, and writes only on that module
/// over that IMEI (ImeiExpectation, checked on the port that writes): a modem swapped or changed meanwhile is left as it
/// is. A module that gives no serial number is not changed (the change could not be tied to it). Once the change has
/// been sent to the service (not when it is refused before, the IMEI is already the one asked or the question is
/// cancelled), it is recorded in the IMEI history, succeeded or failed, with the module and the IMEI before as the
/// change's own port open read them (ImeiWrite); a history that cannot be written adds a line saying so and does not
/// change the exit code. An IMEI written whose restart failed prints its sentence and the way back, and exits 1.
private func setImei(_ service: ModemServing, _ value: String, reboot: Bool, yes: Bool,
                     ask: (String) -> String?, history: ImeiHistoryRecorder?, _ output: (String) -> Void) -> Int32 {
    if let problem = imeiProblem(value) { return fail("imei", "\(problem) Nothing was changed.", output) }
    let reading: ImeiReading
    switch service.imeiReading() {
    case .failure(let failure): return fail("imei", failure.message, output)
    case .success(let read):
        if read.imei == value {
            output("imei: already \(value); nothing changed")
            return 0
        }
        reading = read
    }
    guard let module = reading.module else {
        return fail("imei", "The modem gives no USB serial number, so the change cannot be tied to this module. "
                    + "Nothing was changed.", output)
    }
    if !yes {
        let what = "The IMEI of module \(module) will change from \(reading.imei) to \(value). "
        let question = reboot ? what + restartQuestion
            : what + "It takes effect at the next restart. Continue? [y/N] "
        guard let answer = ask(question) else {
            output("imei: no terminal to ask on, so nothing changed; run again with --yes to change it without asking")
            return 2
        }
        guard ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            output("cancelled; nothing changed")
            return 1
        }
    }
    let write = service.setImei(value, reboot: reboot, expect: ImeiExpectation(module: module, before: reading.imei))
    let outcome = write.outcome
    if let history, let entry = imeiHistoryEntry(after: value, before: write.before, restart: reboot, outcome: outcome,
                                                 source: .cli, module: write.module, at: history.now()),
       let problem = history.keeper.append(entry) {
        output("imei: the change was not recorded in the IMEI history. \(problem)")
    }
    switch outcome {
    case .failure(let failure):
        return fail("imei", failure.message, output)
    case .success(let change):
        output("imei: \(imeiSentence(change))")
        switch change {
        case .unchanged:
            return 0
        case .rebooting(let before, _), .setTakesEffectAfterRestart(let before, _):
            output("imei: to put it back: RMNet imei set \(before)")
            return 0
        case .restartFailed(let before, _, _):
            output("imei: to put it back: RMNet imei set \(before)")
            return 1
        }
    }
}

/// `sim slot set`: reads the slot first (nothing asked or sent when it is already that one), asks (unless --yes; without a
/// terminal it changes nothing and exits 2), then switches and waits for the new slot's SIM and the registration, and
/// prints what came of it and the way back. A new slot without a usable SIM is still a switch made: exit 0.
private func setSimSlot(_ service: ModemServing, _ slot: Int, yes: Bool, ask: (String) -> String?,
                        _ output: (String) -> Void) -> Int32 {
    let before: Int
    switch service.simSlot() {
    case .failure(let failure): return fail("sim", failure.message, output)
    case .success(let current):
        if current == slot {
            output("sim: already on SIM \(slot); nothing changed")
            return 0
        }
        before = current
    }
    if !yes {
        let q = simSlotQuestion(from: before, to: slot)
        guard let answer = ask("\(q.message) \(q.title) [y/N] ") else {
            output("sim: no terminal to ask on, so nothing changed; run again with --yes to switch without asking")
            return 2
        }
        guard ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            output("cancelled; nothing changed")
            return 1
        }
    }
    switch service.setSimSlot(slot, wait: .registration) {
    case .failure(let failure):
        return fail("sim", failure.message, output)
    case .success(let change):
        output("sim: \(simSlotSentence(change))")
        if change.changed { output("sim: to switch back: RMNet sim slot set \(change.before)") }
        return 0
    }
}

/// The network read's Radio row: `on`, `off (airplane mode)`, `minimum functionality`, `AT+CFUN <n>`.
private func showRadio(_ service: ModemServing, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("radio", failure.message, output)
    case .success(let info):
        guard info.radio != nil, let words = networkRows(info).first(where: { $0.label == "Radio" })?.value else {
            return fail("radio", "The modem did not say whether the radio is on.", output)
        }
        output("radio: \(words)")
        return 0
    }
}

private func showMode(_ service: ModemServing, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("mode", failure.message, output)
    case .success(let info):
        guard let mode = info.mode else { return fail("mode", "The modem did not say which network mode it uses.", output) }
        output("mode: \(mode) (\(modeWords(mode)))")
        return 0
    }
}

/// The change, then the way back (ruling R8): a mode RMNet can set again is put back as the modem gave it;
/// another, with its AT command for `RMNet at` (modeAtWayBack).
private func setMode(_ service: ModemServing, _ mode: String, _ output: (String) -> Void) -> Int32 {
    switch service.setMode(mode) {
    case .failure(let failure): return fail("mode", failure.message, output)
    case .success(let change):
        output("mode: \(modeSentence(change))")
        if let back = modeRestoreCommand(change.before) {
            output("mode: to put it back: \(back)")
        } else {
            output("mode: the earlier value \(modemTextSafe(change.before)) \(modeAtWayBack(change.before))")
        }
        return 0
    }
}

/// A listed profile whose AT+QICSGP settings were not read (refused, or above 16): its AT+CGDCONT type
/// and APN (both display-safe already).
private func listedWords(_ p: DataProfile) -> String {
    "\(p.pdpType), APN \"\(p.apn)\"" + (p.apn.isEmpty ? " (the network chooses)" : "") + "; other settings not read"
}

private func showProfiles(_ service: ModemServing, driverProfile: Int?, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.profiles() {
    case .failure(let failure): return fail("apn", failure.message, output)
    case .success(let profiles):
        let driver = driverProfile ?? 1
        if json {
            var object = profilesJSON(profiles, driverProfile: driver)
            object["driverAttached"] = driverProfile != nil
            return outputJSON("apn", object, output)
        }
        if let driverProfile {
            output("apn: the driver dials profile \(driverProfile)")
        } else {
            output("apn: the driver is not attached; it dials profile 1 unless set otherwise")
        }
        for p in profiles {
            let words = p.settings.map(profileWords) ?? listedWords(p)
            output("profile \(p.id): \(words)" + (p.id == driver ? " (the driver's)" : ""))
        }
        return 0
    }
}

/// What `apn set` was given, apart from the password itself.
private struct ProfileOptions {
    let apn: String?
    let type: PdpType?
    let user: String?
    let auth: AuthMethod?
    let askPassword: Bool
    let clearPassword: Bool
    let redial: Bool
}

/// Reads the profile's settings, puts the options over them, checks them, warns, reads a new password if
/// asked, and changes the profile. Nothing is changed before the checks pass, nor when the password was not
/// read or is empty. A password kept from the current settings is sent as it is; none is ever printed.
private func setProfile(_ service: ModemServing, _ id: Int, _ options: ProfileOptions,
                        readSecret: (String) -> String?, _ output: (String) -> Void) -> Int32 {
    // A driver's profile above 16 is not one AT+QICSGP can change: said before anything is read.
    if let problem = profileNumberProblem(id) { return fail("apn", problem, output) }
    var settings: ProfileSettings
    switch service.profiles() {
    case .failure(let failure): return fail("apn", failure.message, output)
    case .success(let profiles):
        guard let current = profiles.first(where: { $0.id == id })?.settings else {
            return fail("apn", "Profile \(id) could not be read. Nothing was changed.", output)
        }
        settings = current
    }
    if let apn = options.apn { settings.apn = apn }
    if let type = options.type { settings.type = type }
    if let user = options.user { settings.user = user }
    if let auth = options.auth { settings.auth = auth }
    if options.clearPassword { settings.password = "" }
    // With --password the new password is read after the warning, and an empty one is refused: the checks
    // before the prompt take it as set (any allowed text stands for it), so a rule it breaks, such as no
    // authentication (ruling R15), is told before anything is typed. The old password is not checked.
    var beforePrompt = settings
    if options.askPassword { beforePrompt.password = "?" }
    if let problem = profileProblem(id, beforePrompt) { return fail("apn", problem, output) }
    output("apn: A wrong APN breaks the connection.")
    if options.askPassword {
        guard let password = readSecret("New password for profile \(id): ") else {
            return fail("apn", "The password was not read (cancelled, or no terminal). Nothing was changed.", output)
        }
        guard !password.isEmpty else {
            return fail("apn", "No password was entered. Nothing was changed; use --no-password to clear the password.",
                        output)
        }
        settings.password = password
        if let problem = profileProblem(id, settings) { return fail("apn", problem, output) }
    }
    switch service.setProfile(id, to: settings, redial: options.redial) {
    case .failure(let failure):
        output("apn: \(failure.message)")
        // The change may have reached the modem: the way back all the same (ruling R19).
        if let before = failure.profileBefore { output("apn: to put it back: \(profileRestoreCommand(before))") }
        return 1
    case .success(let change):
        output("apn: \(profileSentence(change))")
        output("apn: to put it back: \(profileRestoreCommand(change.before))")
        // Changed, but the redial left the radio off: the connection is down until `RMNet radio on`.
        if case .radioLeftOff = change.redial { return 1 }
        return 0
    }
}

/// Sends a PIN only when the SIM asks for one and the attempts left are known and shown first; the last
/// attempt only with `--last-attempt`. The service checks the attempts again before sending.
private func unlockSim(_ service: ModemServing, lastAttempt: Bool, readSecret: (String) -> String?,
                       _ output: (String) -> Void) -> Int32 {
    let sim: SimInfo
    switch service.sim() {
    case .failure(let failure): return fail("sim", failure.message, output)
    case .success(let read): sim = read
    }
    switch sim.state {
    case .pin:
        break
    case .puk:
        return fail("sim", "The SIM is blocked: it needs its PUK from the carrier. RMNet does not enter PUKs.", output)
    default:
        return fail("sim", "The SIM does not ask for a PIN (\(simStateWords(sim.state))).", output)
    }
    guard let attempts = sim.pinAttempts else {
        return fail("sim", "The attempts left could not be read; RMNet does not send a PIN without them.", output)
    }
    guard attempts >= 1 else {
        return fail("sim", "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not "
                    + "enter PUKs.", output)
    }
    output("sim: The SIM asks for its PIN. \(attempts) attempt(s) left; a wrong PIN uses one.")
    if attempts == 1 && !lastAttempt {
        return fail("sim", "This is the last attempt: a wrong PIN blocks the SIM until its PUK is entered. "
                    + "Run again with --last-attempt to send it.", output)
    }
    guard let pin = readSecret("PIN: ") else {
        return fail("sim", "The PIN was not read (cancelled, or no terminal). Nothing was sent.", output)
    }
    if let problem = pinProblem(pin) { return fail("sim", problem, output) }
    switch service.enterPin(pin, shownAttempts: attempts) {
    case .failure(let failure): return fail("sim", failure.message, output)
    case .success(let outcome):
        output("sim: \(pinSentence(outcome))")
        return outcome.accepted ? 0 : 1
    }
}

private func showUsbMode(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.usbMode() {
    case .failure(let failure): return fail("usb mode", failure.message, output)
    case .success(let info):
        if json { return outputJSON("usb mode", usbModeJSON(info), output) }
        let name = usbModeName(info.value)
        output(info.mode == .qmi ? "usb mode: \(name) (the RMNet driver works in this mode)"
                                 : "usb mode: \(name) (the RMNet driver needs qmi: RMNet usbmode set qmi)")
        return 0
    }
}

/// The question before a change that restarts the modem.
private let restartQuestion = "The modem will restart (about 30 s) and the network port will go away until it is back. "
    + "Continue? [y/N] "

/// Reads the mode first, and changes nothing when it is already the one asked. A mode other than qmi is
/// warned about first, also with --yes. A change that restarts the modem is asked about on the terminal
/// unless --yes: only `y` or `yes` (any case) goes on; without a terminal it is refused, exit 2, so the modem
/// is never restarted unasked. With --no-reboot nothing restarts, so nothing is asked.
private func setUsbMode(_ service: ModemServing, _ mode: UsbNetMode, reboot: Bool, yes: Bool,
                        ask: (String) -> String?, _ output: (String) -> Void) -> Int32 {
    switch service.usbMode() {
    case .failure(let failure): return fail("usb mode", failure.message, output)
    case .success(let info):
        if info.value == mode.rawValue {
            output("usb mode: already \(mode.name); nothing changed")
            return 0
        }
    }
    if mode != .qmi {
        output("In \(mode.name) mode this driver does not work; to come back: RMNet usbmode set qmi (if RMNet cannot "
               + "find the modem afterwards, send AT+QCFG=\"usbnet\",0 then AT+CFUN=1,1 from other software that talks "
               + "to the modem over USB, or from another computer)")
    }
    if reboot && !yes {
        guard let answer = ask(restartQuestion) else {
            output("usb mode: no terminal to ask on, so nothing changed; run again with --yes to restart the modem "
                   + "without asking")
            return 2
        }
        guard ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            output("cancelled; nothing changed")
            return 1
        }
    }
    switch service.setUsbMode(mode, reboot: reboot) {
    case .failure(let failure):
        return fail("usb mode", failure.message, output)
    case .success(.unchanged):
        output("usb mode: already \(mode.name); nothing changed")
    case .success(.rebooting):
        output("usb mode set to \(mode.name); the modem is restarting")
    case .success(.setTakesEffectAfterRestart):
        output("usb mode set to \(mode.name); it takes effect at the next restart (AT+CFUN=1,1 or a replug)")
    }
    return 0
}

/// Each RAT's line, `LTE: all 31 supported bands allowed` or `LTE: 2 of 31 supported bands allowed: 3, 41`
/// (compared as sets), then its supported bands, indented: `  supported: 1, 2, 3, …`.
private func showBands(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.bands() {
    case .failure(let failure): return fail("bands", failure.message, output)
    case .success(let sets):
        if json { return outputJSON("bands", sets.map(bandsJSON), output) }
        for set in sets {
            let allowed = Set(set.allowed)
            if !allowed.isEmpty && allowed == Set(set.supported) {
                output("\(set.rat.name): all \(allowed.count) supported bands allowed")
            } else {
                output("\(set.rat.name): \(allowed.count) of \(Set(set.supported).count) supported bands allowed: "
                       + bandListWords(set.allowed))
            }
            output("  supported: \(bandListWords(set.supported))")
        }
        return 0
    }
}

/// Reads the bands once, then puts each of `rats`, in order, to `target` of its bands as read; stops at the
/// first failure (exit 1). A RAT's bands are checked first (`bandsProblem`: not empty, every band supported),
/// and a RAT that already allows exactly those (as a set) is said to and left alone; otherwise the warning,
/// naming the bands before (`all supported` when they were), then the change. No question, as `mode`. Only a
/// failure of the first read ends `Nothing was changed.`; a failure before a RAT's write ends `The <RAT> bands
/// were not changed.` (in a reset of all three the lines before it show any RAT already set). A reset of all
/// three that stops at a failure then names the RATs from the one that failed on: `bands: not reset: 5G NSA,
/// 5G SA (run RMNet bands reset <rat> to try again)`.
private func changeBands(_ service: ModemServing, _ rats: [BandRat], _ output: (String) -> Void,
                         to target: (BandSet) -> [Int]) -> Int32 {
    let sets: [BandSet]
    switch service.bands() {
    case .failure(let failure): return fail("bands", "\(failure.message) Nothing was changed.", output)
    case .success(let read): sets = read
    }
    for (index, rat) in rats.enumerated() {
        // The failure's line; in a reset of all three, then the RATs not reset: this one and those after it.
        func stop(_ sentence: String) -> Int32 {
            output("bands: \(sentence)")
            if rats.count > 1 {
                output("bands: not reset: \(rats[index...].map { $0.name }.joined(separator: ", ")) "
                       + "(run RMNet bands reset <rat> to try again)")
            }
            return 1
        }
        guard let set = sets.first(where: { $0.rat == rat }) else {
            return stop("The modem did not report its \(rat.name) bands. \(bandsNotChanged(rat))")
        }
        let wanted = bandSorted(target(set))
        if let problem = bandsProblem(rat, wanted, supported: set.supported) {
            return stop("\(problem) \(bandsNotChanged(rat))")
        }
        let list = bandListWords(wanted)
        if Set(set.allowed) == Set(wanted) {
            output("\(rat.name) bands: already \(list); nothing changed")
            continue
        }
        let was = Set(set.allowed) == Set(set.supported) ? "all supported" : bandListWords(set.allowed)
        output("\(rat.name) bands: \(list) (was \(was)); the modem may re-select a cell and drop the connection for a few "
               + "seconds")
        switch service.setBands(rat, to: wanted) {
        case .failure(let failure):
            return stop(failure.message)
        case .success(let change) where change.before == change.after:
            output("\(rat.name) bands: already \(bandListWords(change.after)); nothing changed")
        case .success(let change):
            output("\(rat.name) bands set to \(bandListWords(change.after))")
        }
    }
    return 0
}

/// One AT command, its answer printed as an AT terminal shows it: each answer line on standard output, then
/// `OK`, exit 0; the modem's error line (`ERROR`, `+CME ERROR: …`, `+CMS ERROR: …`, or another V.250 final
/// result such as `NO CARRIER`, which `ATA` gives at once with no call) on standard output, exit 1.
/// On standard error, exit 1: `at: no answer in <n> s` (the timeout given), or `at: <sentence>` for any
/// other failure. What the modem sends is printed display-safe, as all text from it (`modemTextSafe`); the
/// line sent and its answer go to the terminal only, never to a log.
private func sendAt(_ service: ModemServing, _ line: String, timeout: Int, _ output: (String) -> Void,
                    _ errorOutput: (String) -> Void) -> Int32 {
    switch service.at(line, timeout: TimeInterval(timeout)) {
    case .success(let lines):
        for answer in lines { output(modemTextSafe(answer)) }
        output("OK")
        return 0
    case .failure(let failure):
        switch failure.atKind {
        case .modemError:
            output(modemTextSafe(failure.message))
            return 1
        case .timeout:
            return fail("at", "no answer in \(timeout) s", errorOutput)
        case nil:
            return fail("at", failure.message, errorOutput)
        }
    }
}

/// Shows `question` on the terminal (no line end after it) and reads one line from standard input. nil, asking
/// nothing, when standard input is not a terminal; "" at the end of input (Ctrl-D), which the caller takes as
/// no. The question goes to /dev/tty, as readSecret's prompt does, so it is seen also when standard output is
/// piped; to standard output when /dev/tty cannot be opened or written.
func askOnTerminal(_ question: String) -> String? {
    askOnTerminal(question, inputIsTerminal: isatty(0) == 1, terminal: writeToTerminal,
                  output: { text in
                      print(text, terminator: "")
                      fflush(stdout)
                  },
                  readAnswer: { readLine(strippingNewline: true) })
}

/// askOnTerminal's steps, each given (the tests give fakes): whether standard input is a terminal; `terminal`
/// writes the question to /dev/tty and says whether it could; `output` writes it to standard output instead;
/// `readAnswer` reads one line from standard input (nil at its end).
func askOnTerminal(_ question: String, inputIsTerminal: Bool, terminal: (String) -> Bool, output: (String) -> Void,
                   readAnswer: () -> String?) -> String? {
    guard inputIsTerminal else { return nil }
    if !terminal(question) { output(question) }
    return readAnswer() ?? ""
}

/// Writes `text` to /dev/tty, the process's controlling terminal. false, with nothing written, when /dev/tty
/// does not open (no controlling terminal) or its first write fails; a write cut short later is not repeated
/// on standard output.
private func writeToTerminal(_ text: String) -> Bool {
    let fd = open("/dev/tty", O_WRONLY | O_NOCTTY | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let bytes = Array(text.utf8)
    var done = 0
    while done < bytes.count {
        let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return done > 0 }
        done += n
    }
    return true
}
