// The modem over its spare AT port (USB interface 3): the network read, the radio, the network mode, the
// USB network mode (with the restart that puts it in effect), the bands LTE and 5G may use, one command as the
// owner typed it (`RMNet at`),
// the data profiles (with the redial that makes the driver dial with new settings) and the SIM's PIN. The
// models in ModemNetwork.swift and ModemSettings.swift read the answers and write the lines that change the
// modem; this file only puts them in order. Each call opens a port, works and closes it, also on failure.
// After a timeout or an I/O error nothing more is sent on that port (AtPort closes itself after a timeout),
// so the call ends there; only a redial then opens a second port, to switch the radio back on. Calls block
// (a redial usually up to about 40 s, longer when the port fails) and must not be made on the main thread.
//
// Nothing here logs, prints or stores what goes over the port. A profile's password appears only in the one
// AT+QICSGP=<id>,… line sent and a PIN only in the one AT+CPIN="…" line; neither is ever put in a failure's
// sentence. A profile change that failed after its line may have reached the modem keeps the settings before,
// password included, in its failure's `profileBefore` (in memory only, for the way back; ruling R19).
import Foundation

/// What the service needs of a port: one command at a time, and closing (closing twice is harmless). AtPort
/// is one; the tests use a scripted port.
protocol AtCommanding: AnyObject {
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError>
    func close()
    /// The USB serial number of the module the port was opened on (AtPort.deviceSerial); nil when not known.
    var deviceSerial: String? { get }
}

extension AtCommanding {
    var deviceSerial: String? { nil }
}

extension AtPort: AtCommanding {}

/// One open port, and the failure that ended its use. After a timeout or an I/O error nothing more is sent
/// on it: AtPort has closed itself after a timeout, and after an I/O error the port is not trusted. Each
/// later command then fails at once with that failure, without sending anything.
private final class Link {
    private let port: AtCommanding
    private(set) var broken: AtError?

    init(_ port: AtCommanding) { self.port = port }

    /// The module this port was opened on: the one every command of this open goes to.
    var deviceSerial: String? { port.deviceSerial }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        if let broken { return .failure(broken) }
        let result = port.command(line, timeout: timeout)
        if case .failure(let error) = result, !isRefusal(error) { broken = error }
        return result
    }

    /// A read whose refusal by the modem only leaves its part unknown: no lines. After a timeout or an I/O
    /// error (`broken` says which) also no lines.
    func read(_ line: String) -> [String] {
        guard case .success(let lines) = command(line, timeout: ModemService.readTimeout) else { return [] }
        return lines
    }

    func close() { port.close() }
}

/// The modem's own error line: it answered, and the port still works.
private func isRefusal(_ error: AtError) -> Bool {
    if case .modem = error { return true }
    return false
}

private func failure<T>(_ message: String) -> Result<T, ModemFailure> {
    .failure(ModemFailure(message: message))
}

private let stillOffAdvice = "Run `RMNet radio on`, or use the Radio switch on the window's Network screen."

final class ModemService: ModemServing {
    fileprivate static let readTimeout: TimeInterval = 3
    private static let radioTimeout: TimeInterval = 20        // AT+CFUN=: the manual allows 15 s
    private static let writeTimeout: TimeInterval = 5         // AT+QICSGP= and AT+QNWPREFCFG= writes
    private static let pinTimeout: TimeInterval = 10          // AT+CPIN="…"
    private static let registrationWait: TimeInterval = 30
    private static let registrationInterval: TimeInterval = 1
    // Reads at 0, 1, …, 30 s; also the bound should the clock go back.
    private static let registrationReads = Int(registrationWait / registrationInterval) + 1
    private static let redialPause: TimeInterval = 1          // between AT+CFUN=4 and the change
    // The reopen that switches the radio back on, while interface 3 is busy (ruling R22): every 0.5 s for up
    // to 15 s; the count bounds it should the clock stand still or go back.
    private static let reopenWait: TimeInterval = 15
    private static let reopenInterval: TimeInterval = 0.5
    private static let reopenRetries = Int(reopenWait / reopenInterval)

    private static let modeRead = "AT+QNWPREFCFG=\"mode_pref\""
    // The bands the modem's hardware supports. Not "ue_capability_band": on the RM520N-GL that follows a lock
    // (after nr5g_band was set to 41 it listed only 41; seen on 2026-11-15), and rf_band does not.
    private static let bandSupportRead = "AT+QNWPREFCFG=\"rf_band\""
    private static func bandRead(_ rat: BandRat) -> String { "AT+QNWPREFCFG=\"\(rat.key)\"" }
    private static let usbModeRead = "AT+QCFG=\"usbnet\""
    private static let restart = "AT+CFUN=1,1"
    private static let simStateRead = "AT+CPIN?"
    private static let pinAttemptsRead = "AT+QPINC?"
    private static let pinLockRead = "AT+CLCK=\"SC\",2"
    private static let lteLockRead = "AT+QNWLOCK=\"common/4g\""
    private static let nrLockRead = "AT+QNWLOCK=\"common/5g\""
    private static let lockPersistRead = "AT+QNWLOCK=\"save_ctrl\""
    private static let imeiRead = "AT+EGMR=0,7"
    private static let simSlotRead = "AT+QUIMSLOT?"
    private static let simWait: TimeInterval = 15             // after AT+QUIMSLOT=: the new slot's SIM to settle

    private let open: () -> Result<AtCommanding, AtError>
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date

    init(open: @escaping () -> Result<AtCommanding, AtError> = { AtPort.open().map { $0 as AtCommanding } },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> Date = { Date() }) {
        self.open = open
        self.sleep = sleep
        self.now = now
    }

    /// Opens a port, runs `body` on it and closes it, also on failure; `openFailed` words a failed open.
    private func withPort<T>(_ openFailed: (AtError) -> String, _ body: (Link) -> Result<T, ModemFailure>) -> Result<T, ModemFailure> {
        switch open() {
        case .failure(let error):
            return failure(openFailed(error))
        case .success(let port):
            defer { port.close() }
            return body(Link(port))
        }
    }

    // MARK: The network

    /// The eleven reads, 3 s each. A refusal leaves its part unknown; a timeout or an I/O error fails the call.
    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        withPort({ describe($0) }) { link in
            var info = NetworkInfo()
            info.radio = parseRadio(link.read("AT+CFUN?"))
            let op = parseOperator(link.read("AT+COPS?"))
            info.operatorName = op.name
            info.accessTechnology = op.accessTechnology
            let provider = parseServiceProvider(link.read("AT+QSPN"))
            info.networkName = provider.fullName
            info.plmn = provider.plmn                 // from AT+QSPN only (ruling R1)
            info.registration = readRegistration(link)
            info.serving = parseServingCell(link.read("AT+QENG=\"servingcell\""))
            let qca = link.read("AT+QCAINFO")
            info.carriers = parseCarriers(qca)
            info.carrierComponents = parseCarrierComponents(qca)
            info.mode = parseModePreference(link.read(ModemService.modeRead))
            info.nr5gDisable = parseNr5gDisable(link.read("AT+QNWPREFCFG=\"nr5g_disable_mode\""))
            if let broken = link.broken { return failure(describe(broken)) }
            return .success(info)
        }
    }

    /// AT+QRSRP, AT+QRSRQ, AT+QSINR (3 s each); refusals leave missing RATs empty, timeouts/I/O fail.
    func antennas() -> Result<[AntennaSignalSet], ModemFailure> {
        withPort({ describe($0) }) { link in
            let rsrp = link.read("AT+QRSRP")
            let rsrq = link.read("AT+QRSRQ")
            let sinr = link.read("AT+QSINR")
            if let broken = link.broken { return failure(describe(broken)) }
            return .success(parseAntennaSignals(rsrp: rsrp, rsrq: rsrq, sinr: sinr))
        }
    }

    /// AT+C5GREG?, AT+CEREG?, AT+CGREG?, AT+CREG?, summarized.
    private func readRegistration(_ link: Link) -> Registration? {
        summarizeRegistration(fiveG: parseRegistrationStat(link.read("AT+C5GREG?"), prefix: "+C5GREG"),
                              eps: parseRegistrationStat(link.read("AT+CEREG?"), prefix: "+CEREG"),
                              ps: parseRegistrationStat(link.read("AT+CGREG?"), prefix: "+CGREG"),
                              cs: parseRegistrationStat(link.read("AT+CREG?"), prefix: "+CREG"))
    }

    // MARK: The radio

    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        let state = on ? "on" : "off"
        return withPort({ "\(describe($0)) The radio was not switched \(state)." }) { link in
            switch link.command(on ? "AT+CFUN=1" : "AT+CFUN=4", timeout: ModemService.radioTimeout) {
            case .success:
                guard on else { return .success(RadioChange(on: false, registration: nil, secondsToRegister: nil)) }
                return .success(waitForRegistration(link, since: now()))
            case .failure(let error) where isRefusal(error):
                return failure("The radio could not be switched \(state). \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the radio was switched \(state). \(describe(error))")
            }
        }
    }

    /// After AT+CFUN=1 answered at `start`: reads the registration every second until it is registered (home
    /// or roaming) or 30 s have passed, or until a read times out or fails (the radio is on all the same).
    /// The seconds are whole ones, from `start` to the first registered read; nil when it did not register.
    private func waitForRegistration(_ link: Link, since start: Date) -> RadioChange {
        var last: Registration? = nil
        for n in 0..<ModemService.registrationReads {
            if n > 0 { sleep(ModemService.registrationInterval) }
            let read = readRegistration(link)
            if link.broken != nil { break }           // an incomplete read is not kept
            last = read
            let elapsed = now().timeIntervalSince(start)
            if let status = last?.status, status == .home || status == .roaming {
                return RadioChange(on: true, registration: last, secondsToRegister: Int(max(0, elapsed)))
            }
            if elapsed >= ModemService.registrationWait { break }
        }
        return RadioChange(on: true, registration: last, secondsToRegister: nil)
    }

    // MARK: The network mode

    /// Sends `mode` upper-cased in its own order, so that a put-back restores the modem's own string (such as
    /// NR5G:LTE) exactly (ruling R8); the read-back must be what was sent.
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> {
        guard canonicalMode(mode) != nil else {
            return failure("RMNet does not set the network mode \"\(modemTextSafe(mode))\": a mode is auto, or one or more "
                           + "of wcdma, lte and nr5g joined by \":\", each at most once. Nothing was changed.")
        }
        let value = mode.uppercased()      // canonicalMode accepts ASCII names only: this is the RATs as named
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in
            let before: String
            switch link.command(ModemService.modeRead, timeout: ModemService.readTimeout) {
            case .success(let lines):
                guard let current = parseModePreference(lines) else {
                    return failure("The modem did not say which network mode it uses. Nothing was changed.")
                }
                before = current
            case .failure(let error):
                return failure("The network mode could not be read. \(describe(error)) Nothing was changed.")
            }
            switch link.command(modeCommand(value), timeout: ModemService.writeTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("The network mode was not changed. \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the network mode changed. \(describe(error)) It was \(before).")
            }
            switch link.command(ModemService.modeRead, timeout: ModemService.readTimeout) {
            case .success(let lines):
                let after = parseModePreference(lines)
                guard after == value else {
                    return failure("The modem answered OK but now reports \(after ?? "no mode"). It was \(before).")
                }
                return .success(ModeChange(before: before, after: value))
            case .failure(let error):
                return failure("The modem answered OK, but the network mode could not be read back. \(describe(error)) "
                               + "It was \(before).")
            }
        }
    }

    // MARK: The USB network mode

    func usbMode() -> Result<UsbModeInfo, ModemFailure> {
        withPort({ describe($0) }) { readUsbMode($0) }
    }

    /// AT+QCFG="usbnet" (3 s); fails on an answer without its line, a refusal, a timeout or an I/O error.
    private func readUsbMode(_ link: Link) -> Result<UsbModeInfo, ModemFailure> {
        switch link.command(ModemService.usbModeRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let info = parseUsbMode(lines) else { return failure("The modem did not say which USB mode it uses.") }
            return .success(info)
        case .failure(let error):
            return failure("The USB mode could not be read. \(describe(error))")
        }
    }

    /// Reads the mode first: when it is already `mode`, nothing more is sent. Otherwise the change (5 s) and
    /// its read-back, which must be `mode`; then, only with `reboot`, AT+CFUN=1,1 (20 s, as AT+CFUN=), and
    /// no wait for the modem to come back: it leaves USB while it restarts, and this port with it. Nothing
    /// is restarted after a change that failed or did not read back as sent.
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> {
        withPort({ "\(describe($0)) Nothing was changed." }) { link in
            let before: UsbModeInfo
            switch readUsbMode(link) {
            case .success(let info): before = info
            case .failure(let f): return failure("\(f.message) Nothing was changed.")
            }
            if before.value == mode.rawValue { return .success(.unchanged) }
            let was = "It was \(usbModeName(before.value)). The modem was not restarted."
            switch link.command(usbModeCommand(mode), timeout: ModemService.writeTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("The USB mode was not changed. \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the USB mode changed. \(describe(error)) \(was)")
            }
            switch link.command(ModemService.usbModeRead, timeout: ModemService.readTimeout) {
            case .success(let lines):
                let after = parseUsbMode(lines)
                guard after?.value == mode.rawValue else {
                    let reports = after.map { usbModeName($0.value) } ?? "no USB mode"
                    return failure("The modem answered OK but now reports \(reports). \(was)")
                }
            case .failure(let error):
                return failure("The modem answered OK, but the USB mode could not be read back. \(describe(error)) \(was)")
            }
            guard reboot else { return .success(.setTakesEffectAfterRestart) }
            let nextRestart = "takes effect at the next restart (AT+CFUN=1,1 or a replug)."
            switch link.command(ModemService.restart, timeout: ModemService.radioTimeout) {
            case .success:
                return .success(.rebooting)
            case .failure(let error) where isRefusal(error):
                return failure("The USB mode is now \(mode.name), but the modem was not restarted. \(describe(error)) "
                               + "It \(nextRestart)")
            case .failure(let error):
                return failure("The USB mode is now \(mode.name). It is not known whether the modem is restarting. "
                               + "\(describe(error)) If it does not restart, the new mode \(nextRestart)")
            }
        }
    }

    // MARK: The bands

    /// AT+QNWPREFCFG="rf_band" (the bands the modem's hardware supports, every RAT's on one answer, whatever is
    /// locked), then each RAT's own setting (the bands it may use), in BandRat.allCases order, 3 s each. Fails on
    /// a read that is refused, times out or fails, and on an answer without a RAT's list.
    func bands() -> Result<[BandSet], ModemFailure> {
        withPort({ describe($0) }) { link in
            let supported: [BandRat: [Int]]
            switch readSupportedBands(link, BandRat.allCases) {
            case .success(let lists): supported = lists
            case .failure(let f): return .failure(f)
            }
            var sets: [BandSet] = []
            for rat in BandRat.allCases {
                switch readAllowedBands(link, rat) {
                case .success(let allowed): sets.append(BandSet(rat: rat, allowed: allowed, supported: supported[rat] ?? []))
                case .failure(let f): return .failure(f)
                }
            }
            return .success(sets)
        }
    }

    /// AT+QNWPREFCFG="rf_band": the supported bands of each of `rats` (its lists are in quotes); a failure when
    /// one is not there.
    private func readSupportedBands(_ link: Link, _ rats: [BandRat]) -> Result<[BandRat: [Int]], ModemFailure> {
        switch link.command(ModemService.bandSupportRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            var supported: [BandRat: [Int]] = [:]
            for rat in rats {
                guard let list = parseBandList(lines, key: rat.key) else {
                    return failure("The modem did not report its supported \(rat.name) bands.")
                }
                supported[rat] = list
            }
            return .success(supported)
        case .failure(let error):
            return failure("The supported bands could not be read. \(describe(error))")
        }
    }

    /// AT+QNWPREFCFG="<key>": the bands `rat` may use.
    private func readAllowedBands(_ link: Link, _ rat: BandRat) -> Result<[Int], ModemFailure> {
        switch link.command(ModemService.bandRead(rat), timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let allowed = parseBandList(lines, key: rat.key) else {
                return failure("The modem did not report its allowed \(rat.name) bands.")
            }
            return .success(allowed)
        case .failure(let error):
            return failure("The allowed \(rat.name) bands could not be read. \(describe(error))")
        }
    }

    /// Reads `rat`'s supported and allowed bands first. Refused, nothing written: an empty list (before the
    /// port is opened) or a band the modem does not support (`bandsProblem`). When the bands allowed are
    /// already those asked (as a set), nothing more is sent. Otherwise the change (5 s), sorted, each band once,
    /// and its read-back, which must be the bands asked as a set. A failure before the write ends `The <RAT>
    /// bands were not changed.` (not "Nothing was changed.": in `bands reset` of all three an earlier RAT may
    /// have been set).
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> {
        let wanted = bandSorted(bands)
        let unchanged = bandsNotChanged(rat)
        if wanted.isEmpty, let problem = bandsProblem(rat, wanted, supported: []) {
            return failure("\(problem) \(unchanged)")
        }
        return withPort({ "\(describe($0)) \(unchanged)" }) { link in
            let supported: [Int]
            switch readSupportedBands(link, [rat]) {
            case .success(let lists): supported = lists[rat] ?? []
            case .failure(let f): return failure("\(f.message) \(unchanged)")
            }
            let before: [Int]
            switch readAllowedBands(link, rat) {
            case .success(let allowed): before = allowed
            case .failure(let f): return failure("\(f.message) \(unchanged)")
            }
            if let problem = bandsProblem(rat, wanted, supported: supported) { return failure("\(problem) \(unchanged)") }
            if before == wanted { return .success(BandChange(before: before, after: before)) }   // both sorted, each once
            let was = "They were \(bandListWords(before))."
            switch link.command(bandsCommand(rat, wanted), timeout: ModemService.writeTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("\(unchanged) \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the \(rat.name) bands changed. \(describe(error)) \(was)")
            }
            switch link.command(ModemService.bandRead(rat), timeout: ModemService.readTimeout) {
            case .success(let lines):
                guard let after = parseBandList(lines, key: rat.key) else {
                    return failure("The modem answered OK but did not report its \(rat.name) bands. \(was)")
                }
                guard after == wanted else {
                    return failure("The modem answered OK but now reports \(rat.name) bands \(bandListWords(after)). \(was)")
                }
                return .success(BandChange(before: before, after: after))
            case .failure(let error):
                return failure("The modem answered OK, but the \(rat.name) bands could not be read back. \(describe(error)) "
                               + was)
            }
        }
    }

    // MARK: One command as typed (`RMNet at`)

    /// Sends `line` as it is, once, and gives the modem `timeout` to answer: on its final OK, the answer's lines
    /// (AtPort's, without the echo and the OK). The modem's error line is a failure whose message is that line
    /// (`atKind` .modemError); no answer in time is a failure saying so (.timeout); a port that does not open,
    /// or an I/O error, a failure saying so (no `atKind`). A line `atCommandProblem` refuses is not sent: no
    /// port is opened.
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> {
        if let problem = atCommandProblem(line) { return failure("\(problem); nothing was sent") }
        return withPort({ describe($0) }) { link in
            switch link.command(line, timeout: timeout) {
            case .success(let lines):
                return .success(lines)
            case .failure(.modem(let errorLine)):
                return .failure(ModemFailure(message: errorLine, atKind: .modemError))
            case .failure(.timeout):
                return .failure(ModemFailure(message: describe(.timeout), atKind: .timeout))
            case .failure(let error):
                return failure(describe(error))
            }
        }
    }

    // MARK: The data profiles

    /// AT+CGDCONT?, then AT+QICSGP=<id> for each profile 1 to 16 listed; a refusal leaves its settings nil.
    func profiles() -> Result<[DataProfile], ModemFailure> {
        withPort({ describe($0) }) { link in
            let listed: [(id: Int, pdpType: String, apn: String)]
            switch link.command("AT+CGDCONT?", timeout: ModemService.readTimeout) {
            case .success(let lines): listed = parseProfiles(lines)
            case .failure(let error): return failure("The data profiles could not be read. \(describe(error))")
            }
            var profiles: [DataProfile] = []
            for p in listed {
                var settings: ProfileSettings? = nil
                if (1...16).contains(p.id) {
                    switch link.command("AT+QICSGP=\(p.id)", timeout: ModemService.readTimeout) {
                    case .success(let lines): settings = parseProfileSettings(lines)
                    case .failure(let error) where isRefusal(error): settings = nil
                    case .failure(let error): return failure("Profile \(p.id) could not be read. \(describe(error))")
                    }
                }
                profiles.append(DataProfile(id: p.id, pdpType: p.pdpType, apn: p.apn, settings: settings))
            }
            return .success(profiles)
        }
    }

    /// The change and its read-back. With `redial`, when the radio is on: the radio off, a second, the change,
    /// the read-back, and then always the radio on again (on a new port if this one closed itself) and the
    /// wait for registration. A redial is never started when the radio was not on.
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        if let problem = profileProblem(id, settings) { return failure(problem) }
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in
            let before: ProfileSettings
            switch link.command("AT+QICSGP=\(id)", timeout: ModemService.readTimeout) {
            case .success(let lines):
                guard let current = parseProfileSettings(lines) else {
                    return failure("The modem did not give profile \(id)'s settings. Nothing was changed.")
                }
                before = current
            case .failure(let error):
                return failure("Profile \(id) could not be read. \(describe(error)) Nothing was changed.")
            }

            var radioOn = false
            if redial {
                switch link.command("AT+CFUN?", timeout: ModemService.readTimeout) {
                case .success(let lines):
                    guard let radio = parseRadio(lines) else {
                        return failure("The modem did not say whether the radio is on. Nothing was changed.")
                    }
                    radioOn = radio == .on
                case .failure(let error):
                    return failure("The radio's state could not be read. \(describe(error)) Nothing was changed.")
                }
            }

            // A change that failed after its line may have reached the modem says what the profile was, so that
            // it can be put back (ruling R19); one the modem refused changed nothing.
            func changeFailed(_ problem: ChangeProblem, _ message: String) -> Result<ProfileChange, ModemFailure> {
                .failure(ModemFailure(message: message, profileBefore: problem.changedNothing ? nil : before))
            }

            guard radioOn else {
                switch change(link, id, settings) {
                case .success(let after):
                    return .success(ProfileChange(id: id, before: before, after: after, redial: redial ? .radioWasOff : .notAsked))
                case .failure(let problem):
                    return changeFailed(problem, problem.sentence + (problem.changedNothing ? " Nothing was changed." : ""))
                }
            }

            switch link.command("AT+CFUN=4", timeout: ModemService.radioTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("The radio could not be switched off for the redial. \(describe(error)) Nothing was changed.")
            case .failure(let error):
                // Whether the radio went off is not known: switch it on (harmless if it is on).
                let start = "The radio could not be switched off for the redial. \(describe(error))"
                switch switchBackOn(link) {
                case .success: return failure("\(start) Nothing was changed. The radio is on.")
                case .failure(let why):
                    return failure("\(start) Nothing was changed, but the radio may be off. \(describe(why)) \(stillOffAdvice)")
                }
            }
            sleep(ModemService.redialPause)
            let changed = change(link, id, settings)
            let radio = switchBackOn(link)
            switch (changed, radio) {
            case (.success(let after), .success(let back)):
                return .success(ProfileChange(id: id, before: before, after: after, redial: .done(back)))
            case (.success(let after), .failure(let why)):
                return .success(ProfileChange(id: id, before: before, after: after, redial: .radioLeftOff(describe(why))))
            case (.failure(let problem), .success):
                let nothing = problem.changedNothing ? " Nothing was changed." : ""
                return changeFailed(problem, "\(problem.sentence)\(nothing) The radio was switched back on.")
            case (.failure(let problem), .failure(let why)):
                let stillOff = problem.changedNothing ? "Nothing was changed, but the radio is still off." : "The radio is still off."
                return changeFailed(problem, "\(problem.sentence) \(stillOff) \(describe(why)) \(stillOffAdvice)")
            }
        }
    }

    /// Why a change did not end as asked. `sentence` never holds the password.
    private struct ChangeProblem: Error {
        let sentence: String
        let changedNothing: Bool          // the modem refused the change itself
    }

    /// Sends the settings (5 s) and reads them back; the read-back must equal them (the password compared in
    /// memory only).
    private func change(_ link: Link, _ id: Int, _ settings: ProfileSettings) -> Result<ProfileSettings, ChangeProblem> {
        switch link.command(profileCommand(id, settings), timeout: ModemService.writeTimeout) {
        case .success:
            break
        case .failure(let error) where isRefusal(error):
            return .failure(ChangeProblem(sentence: "The new settings for profile \(id) were refused. \(describe(error))",
                                          changedNothing: true))
        case .failure(let error):
            return .failure(ChangeProblem(sentence: "It is not known whether profile \(id) was changed. \(describe(error))",
                                          changedNothing: false))
        }
        let notReadBack = "Profile \(id) could not be read back after the change."
        switch link.command("AT+QICSGP=\(id)", timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let after = parseProfileSettings(lines) else {
                return .failure(ChangeProblem(sentence: "\(notReadBack) The modem did not give its settings.", changedNothing: false))
            }
            guard after == settings else {
                let password = after.password == settings.password ? "" : " Its password is not the one sent."
                return .failure(ChangeProblem(sentence: "Profile \(id) does not read back as sent: the modem now reports "
                                              + "\(profileWords(after)).\(password)", changedNothing: false))
            }
            return .success(after)
        case .failure(let error):
            return .failure(ChangeProblem(sentence: "\(notReadBack) \(describe(error))", changedNothing: false))
        }
    }

    /// AT+CFUN=1 after the redial's AT+CFUN=4, then the wait for registration. On `link` while it works; when
    /// it closed itself (a timeout or an I/O error, before or on this line), it is closed and a new port is
    /// opened (tried again while busy, see `reopen`). The failure is why the radio is still off.
    private func switchBackOn(_ link: Link) -> Result<RadioChange, AtError> {
        if link.broken == nil {
            switch link.command("AT+CFUN=1", timeout: ModemService.radioTimeout) {
            case .success: return .success(waitForRegistration(link, since: now()))
            case .failure(let error) where isRefusal(error): return .failure(error)
            case .failure: break
            }
        }
        // AtPort keeps the interface after an I/O error: close it, or the new open finds it busy.
        link.close()
        switch reopen() {
        case .failure(let error):
            return .failure(error)
        case .success(let port):
            defer { port.close() }
            let second = Link(port)
            switch second.command("AT+CFUN=1", timeout: ModemService.radioTimeout) {
            case .success: return .success(waitForRegistration(second, since: now()))
            case .failure(let error): return .failure(error)
            }
        }
    }

    /// The open for switching the radio back on. Once the broken port is closed, the window's read or another
    /// RMNet verb can take interface 3 before it, and the radio would be left off: while the open fails busy
    /// (each open itself waits up to 2 s, AtPort's own wait), it is tried again every 0.5 s, for up to 15 s
    /// from the first try (ruling R22).
    private func reopen() -> Result<AtCommanding, AtError> {
        let start = now()
        var opened = open()
        var retries = 0
        while case .failure(.busy) = opened, retries < ModemService.reopenRetries,
              now().timeIntervalSince(start) < ModemService.reopenWait {
            sleep(ModemService.reopenInterval)
            retries += 1
            opened = open()
        }
        return opened
    }

    // MARK: The SIM

    func sim() -> Result<SimInfo, ModemFailure> {
        withPort({ describe($0) }) { link in
            readSimState(link).map { readSimDetails(link, $0) }
        }
    }

    /// AT+CPIN?: its error line is a state too. Fails on an answer without a +CPIN line, a timeout or an I/O error.
    private func readSimState(_ link: Link) -> Result<SimState, ModemFailure> {
        switch link.command(ModemService.simStateRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let state = parseSimState(lines) else { return failure("The modem did not say what state the SIM is in.") }
            return .success(state)
        case .failure(.modem(let line)):
            return .success(simState(fromError: line))
        case .failure(let error):
            return failure("The SIM's state could not be read. \(describe(error))")
        }
    }

    /// AT+QPINC?, AT+CLCK="SC",2 and AT+QUIMSLOT? after the state; one that is refused or fails is nil.
    private func readSimDetails(_ link: Link, _ state: SimState) -> SimInfo {
        let attempts = parsePinAttempts(link.read(ModemService.pinAttemptsRead))
        let lock = parsePinLock(link.read(ModemService.pinLockRead))
        let slot = parseSimSlot(link.read(ModemService.simSlotRead))
        return SimInfo(state: state, pinLock: lock, pinAttempts: attempts.pin, pukAttempts: attempts.puk, activeSlot: slot)
    }

    // MARK: The SIM slot

    func simSlot() -> Result<Int, ModemFailure> {
        withPort({ describe($0) }) { readSimSlot($0, nothingChanged: false) }
    }

    private func readSimSlot(_ link: Link, nothingChanged: Bool) -> Result<Int, ModemFailure> {
        let tail = nothingChanged ? " Nothing was changed." : ""
        switch link.command(ModemService.simSlotRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let slot = parseSimSlot(lines) else { return failure("The modem did not say which SIM slot it uses.\(tail)") }
            return .success(slot)
        case .failure(let error) where isRefusal(error):
            return failure("The modem does not switch SIM slots. \(describe(error))\(tail)")
        case .failure(let error):
            return failure("The SIM slot could not be read. \(describe(error))\(tail)")
        }
    }

    /// Reads the slot (nothing is sent when it is already `slot`), checks `expect` (an automatic switch's: nothing is
    /// sent when the port finds otherwise, SimSlotExpectation), sends AT+QUIMSLOT=<slot> (5 s) and reads it back;
    /// then reads AT+CPIN? every second until the new slot's SIM settles (ready, or asking for a PIN or PUK) or 15 s
    /// have passed (an empty slot stays `not inserted`); with `wait` .registration and the SIM ready, the registration
    /// every second for up to 30 s, as the radio switched on does. All on one port open.
    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure> {
        guard simSlots.contains(slot) else {
            return failure("The modem has SIM slots 1 and 2. Nothing was changed.")
        }
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in
            let before: Int
            switch readSimSlot(link, nothingChanged: true) {
            case .success(let s): before = s
            case .failure(let f): return .failure(f)
            }
            if before == slot { return .success(SimSlotChange(before: slot, after: slot)) }
            if let expect, let skip = recheck(link, expect, slot: before) {
                return .success(SimSlotChange(before: before, after: before, skipped: skip))
            }
            switch link.command(simSlotCommand(slot), timeout: ModemService.writeTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("The SIM slot was not changed. \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the SIM slot changed. \(describe(error))")
            }
            switch readSimSlot(link, nothingChanged: false) {
            case .success(let now) where now == slot:
                break
            case .success(let now):
                return failure("The modem answered OK, but still uses SIM slot \(now).")
            case .failure(let f):
                return failure("The modem answered OK, but its SIM slot could not be read back. \(f.message)")
            }
            let start = now()
            var state: SimState? = nil
            var secondsToSim: Int? = nil
            for n in 0... {
                if n > 0 { sleep(ModemService.registrationInterval) }
                guard case .success(let read) = readSimState(link) else { break }
                state = read
                let elapsed = now().timeIntervalSince(start)
                if read != .busy && !simUnusable(read) {
                    secondsToSim = Int(max(0, elapsed))
                    break
                }
                if elapsed >= ModemService.simWait { break }
            }
            var change = SimSlotChange(before: before, after: slot, sim: state, secondsToSim: secondsToSim)
            if wait == .registration, state == .ready {
                let registered = waitForRegistration(link, since: start)
                change.registration = registered.registration
                change.secondsToRegister = registered.secondsToRegister
            }
            return .success(change)
        }
    }

    /// An automatic switch's expectation against what this port finds: nil when it holds (the switch may be made). A
    /// module not known (no serial number expected, or none on this port) is never the same one.
    private func recheck(_ link: Link, _ expect: SimSlotExpectation, slot: Int) -> SimSlotSkip? {
        guard let module = expect.module, let here = link.deviceSerial else { return .moduleUnknown }
        guard here == module else { return .otherModule }
        guard slot == expect.slot else { return .otherSlot }
        guard expect.unusableSim else { return nil }
        guard parseRadio(link.read("AT+CFUN?")) == .on else { return .radioNotOn }
        guard case .success(let sim) = readSimState(link), let usable = simConclusive(sim) else { return .simUnknown }
        return usable ? .simUsable : nil
    }

    // MARK: Short reads (the app's background turn)

    /// Sends each command (3 s each) on one port, in order: its lines, or the modem's error line for a command the
    /// modem refuses (a state for AT+CPIN?). A timeout or an I/O error ends the turn there (nothing more is sent on that
    /// port): the answers read before it are kept, and the commands from it on have none, so the array is shorter than
    /// `commands` (ModemPulse gives each rider only the answers there are). A port that does not open, or a first command
    /// that already fails so, fails the whole turn. For the app's background turn (ModemPulse.swift), on a service whose
    /// port opens without waiting.
    func shortReads(_ commands: [String]) -> Result<[PulseAnswer], ModemFailure> {
        withPort({ describe($0) }) { link in
            var answers: [PulseAnswer] = []
            for command in commands {
                switch link.command(command, timeout: ModemService.readTimeout) {
                case .success(let lines): answers.append(.lines(lines))
                case .failure(.modem(let line)): answers.append(.refused(line))
                case .failure(let error):
                    if answers.isEmpty { return failure(describe(error)) }
                    return .success(answers)
                }
            }
            return .success(answers)
        }
    }

    /// Sends the PIN only when the SIM, read again now, asks for it and has the attempts left that the owner was
    /// shown (at least 1). The PIN goes in the AT+CPIN="…" line and nowhere else.
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        if let problem = pinProblem(pin) { return failure(problem) }
        return withPort({ "\(describe($0)) Nothing was sent." }) { link in
            let state: SimState
            switch readSimState(link) {
            case .success(let s): state = s
            case .failure(let f): return failure("\(f.message) Nothing was sent.")
            }
            let attemptLines: [String]
            switch link.command(ModemService.pinAttemptsRead, timeout: ModemService.readTimeout) {
            case .success(let lines): attemptLines = lines
            case .failure(let error) where isRefusal(error): attemptLines = []
            case .failure(let error): return failure("The attempts left could not be read. \(describe(error)) Nothing was sent.")
            }
            guard state == .pin else {
                return failure("The SIM does not ask for a PIN (\(simStateWords(state))). Nothing was sent.")
            }
            guard let left = parsePinAttempts(attemptLines).pin else {
                return failure("The attempts left could not be read; RMNet does not send a PIN without them. Nothing was sent.")
            }
            guard left >= 1 else {
                return failure("The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not "
                               + "enter PUKs. Nothing was sent.")
            }
            guard left == shownAttempts else {
                return failure("The attempts left changed to \(left) since they were shown. Nothing was sent; "
                               + "check and enter the PIN again.")
            }
            let accepted: Bool
            var refusal: String? = nil
            switch link.command(pinCommand(pin), timeout: ModemService.pinTimeout) {
            case .success: accepted = true
            case .failure(.modem(let line)):   // the modem's error line: 16 is a wrong PIN, another is not (F10)
                accepted = false
                refusal = line
            case .failure(let error):
                return failure("\(describe(error)) It is not known whether the SIM took the PIN. "
                               + "Check the attempts left (RMNet sim) before entering it again.")
            }
            let after: SimInfo?
            switch readSimState(link) {
            case .success(let s): after = readSimDetails(link, s)
            case .failure: after = nil
            }
            return .success(PinOutcome(accepted: accepted, sim: after, refusal: refusal))
        }
    }

    // MARK: Cell lock (`AT+QNWLOCK`)

    func cellLock() -> Result<CellLockState, ModemFailure> {
        withPort({ describe($0) }) { link in
            readCellLock(link, includeNeighbours: true)
        }
    }

    private func readCellLock(_ link: Link, includeNeighbours: Bool) -> Result<CellLockState, ModemFailure> {
        let lte: [LteLockedCell]
        switch link.command(ModemService.lteLockRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let parsed = parseLteCellLock(lines) else {
                return failure("The modem did not report its LTE cell lock.")
            }
            lte = parsed
        case .failure(let error):
            return failure("The LTE cell lock could not be read. \(describe(error))")
        }

        let nr: NrCellLock?
        switch link.command(ModemService.nrLockRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let parsed = parseNrCellLock(lines) else {
                return failure("The modem did not report its 5G SA cell lock.")
            }
            switch parsed {
            case .unlocked: nr = nil
            case .locked(let value): nr = value
            }
        case .failure(let error):
            return failure("The 5G SA cell lock could not be read. \(describe(error))")
        }

        let persist: (lte: Bool, nr: Bool)
        switch link.command(ModemService.lockPersistRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let parsed = parseCellLockPersist(lines) else {
                return failure("The modem did not report whether cell locks persist across restarts.")
            }
            persist = parsed
        case .failure(let error):
            return failure("The cell-lock persistence setting could not be read. \(describe(error))")
        }

        var neighbours: [NeighbourCell] = []
        if includeNeighbours {
            neighbours = parseNeighbourCells(link.read("AT+QENG=\"neighbourcell\""))
            if let broken = link.broken { return failure(describe(broken)) }
        }
        return .success(CellLockState(lte: lte, nr: nr, persistLte: persist.lte, persistNr: persist.nr,
                                      neighbours: neighbours))
    }

    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure> {
        if let problem = nrCellLockProblem(lock, supportedSaBands: nil) { return failure("\(problem) Nothing was changed.") }
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in self.writeNrCellLock(lock, on: link) }
    }

    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure> {
        if let problem = lteCellLockProblem(cells) { return failure("\(problem) Nothing was changed.") }
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in self.writeLteCellLock(cells, on: link) }
    }

    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure> {
        withPort({ "\(describe($0)) Nothing was changed." }) { link in
            writeCellLock(link, what: "The cell-lock persistence setting", command: cellLockPersistCommand(lte: lte, nr: nr),
                          alreadyEqual: { $0.persistLte == lte && $0.persistNr == nr },
                          verified: { $0.persistLte == lte && $0.persistNr == nr })
        }
    }

    /// Locks to a cell the modem uses now, in one port session: the serving cell (AT+QENG="servingcell") and the
    /// carriers (AT+QCAINFO) read, the cell checked against them (cellInUseLock: still in use, its subcarrier spacing
    /// the one the modem gives, never guessed), then written as setNrCellLock or setLteCellLock does. A cell no longer
    /// in use, or a read that fails, changes nothing.
    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure> {
        if let problem = cellInUseProblem(cell) { return failure("\(problem) Nothing was changed.") }
        return withPort({ "\(describe($0)) Nothing was changed." }) { link in
            let serving = parseServingCell(link.read("AT+QENG=\"servingcell\""))
            let carriers = parseCarrierComponents(link.read("AT+QCAINFO"))
            if let broken = link.broken { return failure("\(describe(broken)) Nothing was changed.") }
            switch cellInUseLock(cell, serving: serving, carriers: carriers) {
            case .refused(let why): return failure("\(why) Nothing was changed.")
            case .nr(let lock): return self.writeNrCellLock(lock, on: link)
            case .lte(let one): return self.writeLteCellLock([one], on: link)
            }
        }
    }

    private func writeNrCellLock(_ lock: NrCellLock?, on link: Link) -> Result<CellLockChange, ModemFailure> {
        writeCellLock(link, what: "The 5G SA cell lock", command: nrCellLockCommand(lock),
                      validate: { link, _ in
                          guard let lock else { return nil }
                          switch self.readSupportedBands(link, [.sa]) {
                          case .failure(let f): return "\(f.message) Nothing was changed."
                          case .success(let lists):
                              if let problem = nrCellLockProblem(lock, supportedSaBands: lists[.sa] ?? []) {
                                  return "\(problem) Nothing was changed."
                              }
                              return nil
                          }
                      },
                      alreadyEqual: { $0.nr == lock },
                      verified: { $0.nr == lock })
    }

    private func writeLteCellLock(_ cells: [LteLockedCell], on link: Link) -> Result<CellLockChange, ModemFailure> {
        writeCellLock(link, what: "The LTE cell lock", command: lteCellLockCommand(cells),
                      alreadyEqual: { $0.lte == cells },
                      verified: { $0.lte == cells })
    }

    private func writeCellLock(_ link: Link, what: String, command: String,
                               validate: ((Link, CellLockState) -> String?)? = nil,
                               alreadyEqual: (CellLockState) -> Bool,
                               verified: (CellLockState) -> Bool) -> Result<CellLockChange, ModemFailure> {
        let before: CellLockState
        switch readCellLock(link, includeNeighbours: false) {
        case .success(let state): before = state
        case .failure(let f): return failure("\(f.message) Nothing was changed.")
        }
        if let problem = validate?(link, before) { return failure(problem) }
        if alreadyEqual(before) { return .success(.unchanged(before)) }
        switch link.command(command, timeout: ModemService.writeTimeout) {
        case .success:
            break
        case .failure(let error) where isRefusal(error):
            return failure("\(what) was not changed. \(describe(error))")
        case .failure(let error):
            return failure("It is not known whether \(what.lowercased()) changed. \(describe(error))")
        }
        switch readCellLock(link, includeNeighbours: false) {
        case .success(let after):
            guard verified(after) else {
                return failure("The modem answered OK, but read back a different cell-lock state.")
            }
            return .success(.changed(before: before, after: after))
        case .failure(let f):
            return failure("The modem answered OK, but the cell lock could not be read back. \(f.message)")
        }
    }

    // MARK: IMEI (`AT+EGMR`)

    func imei() -> Result<String, ModemFailure> {
        withPort({ describe($0) }) { readImei($0) }
    }

    private func readImei(_ link: Link) -> Result<String, ModemFailure> {
        switch link.command(ModemService.imeiRead, timeout: ModemService.readTimeout) {
        case .success(let lines):
            guard let imei = parseImei(lines) else { return failure("The modem did not report its IMEI.") }
            return .success(imei)
        case .failure(let error):
            return failure("The IMEI could not be read. \(describe(error))")
        }
    }

    func imeiReading() -> Result<ImeiReading, ModemFailure> {
        withPort({ describe($0) }) { link in readImei(link).map { ImeiReading(imei: $0, module: link.deviceSerial) } }
    }

    /// Reads the module (the port's) and the IMEI before on the port that writes, and hands them back with the outcome
    /// (ImeiWrite), so the history records the module written to. With `expect` (what the change was confirmed for),
    /// writes only when this port finds that module (a module that gives no serial number is not it) and that IMEI.
    /// A restart that fails after the IMEI was written and read back is a success with that said (restartFailed).
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite {
        if let problem = imeiProblem(imei) { return ImeiWrite(outcome: failure("\(problem) Nothing was changed.")) }
        var seen = ImeiWrite(outcome: failure("Nothing was changed."))
        seen.outcome = withPort({ "\(describe($0)) Nothing was changed." }) { link in
            seen.module = link.deviceSerial
            if let expect, link.deviceSerial != expect.module {
                return failure("The modem attached is not the module this change was confirmed for (serial number "
                               + "\(expect.module); this one has \(link.deviceSerial ?? "none")). Nothing was changed.")
            }
            let before: String
            switch readImei(link) {
            case .success(let current): before = current
            case .failure(let f): return failure("\(f.message) Nothing was changed.")
            }
            seen.before = before
            if let expect, before != expect.before {
                return failure("The modem's IMEI is \(before) now, not \(expect.before) as when the change was confirmed. "
                               + "Nothing was changed.")
            }
            if before == imei { return .success(.unchanged(before)) }
            let was = "It was \(before). The modem was not restarted."
            switch link.command(imeiCommand(imei), timeout: ModemService.writeTimeout) {
            case .success:
                break
            case .failure(let error) where isRefusal(error):
                return failure("The IMEI was not changed. \(describe(error))")
            case .failure(let error):
                return failure("It is not known whether the IMEI changed. \(describe(error)) \(was)")
            }
            switch readImei(link) {
            case .success(let after):
                guard after == imei else {
                    return failure("The modem answered OK but now reports IMEI \(after). \(was)")
                }
            case .failure(let f):
                return failure("The modem answered OK, but the IMEI could not be read back. \(f.message) \(was)")
            }
            guard reboot else { return .success(.setTakesEffectAfterRestart(before: before, after: imei)) }
            let nextRestart = "takes effect at the next restart (AT+CFUN=1,1 or a replug)."
            switch link.command(ModemService.restart, timeout: ModemService.radioTimeout) {
            case .success:
                return .success(.rebooting(before: before, after: imei))
            case .failure(let error) where isRefusal(error):
                return .success(.restartFailed(before: before, after: imei, sentence: "The IMEI is now \(imei), but the "
                                               + "modem was not restarted. \(describe(error)) It \(nextRestart)"))
            case .failure(let error):
                return .success(.restartFailed(before: before, after: imei, sentence: "The IMEI is now \(imei). It is not "
                                               + "known whether the modem is restarting. \(describe(error)) If it does not "
                                               + "restart, the new IMEI \(nextRestart)"))
            }
        }
        return seen
    }
}

/// Reads a secret (a password, a PIN) from the terminal without echo: readpassphrase(3) with RPP_REQUIRE_TTY,
/// so it reads /dev/tty and never a pipe or a file. nil without a terminal, or when reading fails. The buffer
/// is wiped after use; the secret is not kept or shown here.
func readSecret(prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
