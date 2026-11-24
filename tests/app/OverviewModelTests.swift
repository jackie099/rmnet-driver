// Tests for app/OverviewModel.swift: what the Overview's cards say. The serving leg's RSRP history for the signal
// sparkline (one value a read, the serving leg, a ten-minute window ending at the last read, one scale) and its
// placeholder words, the signal card's readout, the not-in-QMI-mode advice lines, the SIM, messages and driver
// cards' states (the driver's never green under an orange or red hero), and the byte counts. Built with swiftc by
// `make app-test` from app/StatusModel.swift, app/ModemNetwork.swift, app/ModemSettings.swift,
// app/ModemController.swift, app/ShellModel.swift, app/SignalQuality.swift, app/OverviewModel.swift and this file;
// no AppKit, no window, no registry. Stops at the first failure, prints which check failed and exits 1.
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

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// One leg's sample of a read `dt` seconds after t0.
func sample(_ dt: Double, _ leg: String, _ rsrp: Int?) -> SignalSample {
    SignalSample(at: t0.addingTimeInterval(dt), leg: leg, rsrp: rsrp, rsrq: nil, sinr: nil, technology: nil, band: nil)
}

func cellLeg(_ rat: String, rsrp: Int?, sinr: Double?, band: String?) -> CellLeg {
    CellLeg(rat: rat, duplex: "TDD", mcc: "001", mnc: "01", cellID: "1A2B3C4D", pci: 245, tac: "3F2A", channel: 504990,
            band: band, bandwidthMHz: 100, rsrp: rsrp, rsrq: -11, sinr: sinr)
}

let saInfo = NetworkInfo(radio: .on, serving: ServingCell(state: "NOCONN",
                                                          cells: [cellLeg("NR5G-SA", rsrp: -86, sinr: 14.5, band: "n41")]),
                         carriers: ["n41", "n78"])

let installed = ExtensionEntry(version: "318.19.40", enabled: true, awaitingApproval: false, uninstalling: false)
let rm520n = quectelModel(product: 0x0801)

func driverStatus(_ entries: [ExtensionEntry] = [installed], modem: ModemState = .qmi(interface: 4),
                  model: QuectelModel? = rm520n, state: String? = nil) -> DriverStatus {
    DriverStatus(entries: entries, modem: modem, modemModel: model, attached: state != nil,
                 properties: state.map { ["RMNetState": $0] } ?? [:])
}

@main
struct OverviewModelTests {
    static func main() {
        signalHistory()
        placeholders()
        lockBadge()
        readouts()
        qmiAdvice()
        simCards()
        messageCards()
        driverCards()
        byteCounts()
        print("overview model: \(checks) checks passed")
    }

    // One value a read: the serving leg's RSRP (NR with an RSRP, else LTE, else the first), the last ten minutes
    // back from the last read, on the newest read's scale.
    static func signalHistory() {
        var h = servingSignalHistory([])
        check(h.values.isEmpty && h.reads == 0 && h.rat == "LTE", "history: empty", "got \(h)")
        h = servingSignalHistory([sample(0, "NR", -90), sample(5, "NR", -85)])
        equal(h, ServingSignalHistory(values: [-90, -85], rat: "NR", reads: 2), "history: SA reads")
        h = servingSignalHistory([sample(0, "LTE", -100), sample(0, "NR", -88), sample(5, "LTE", -99), sample(5, "NR", nil)])
        equal(h, ServingSignalHistory(values: [-88, -99], rat: "LTE", reads: 2), "history: EN-DC, NR with RSRP, else LTE")
        h = servingSignalHistory([sample(0, "NR", -90), sample(601, "NR", -80), sample(700, "NR", -82)])
        equal(h, ServingSignalHistory(values: [-80, -82], rat: "NR", reads: 2), "history: the ten-minute window")
        h = servingSignalHistory([sample(0, "NR", -90), sample(300, "NR", -85), sample(305, "NR", -84)],
                                 until: t0.addingTimeInterval(900))
        equal(h, ServingSignalHistory(values: [-85, -84], rat: "NR", reads: 2), "history: the window ends at the last read")
        h = servingSignalHistory([sample(0, "NR", -90), sample(5, "NR", -85)], until: t0.addingTimeInterval(700))
        check(h.values.isEmpty && h.reads == 0, "history: no leg for ten minutes", "got \(h)")
        h = servingSignalHistory([sample(0, "LTE", -100), sample(5, "WCDMA", -70), sample(10, "WCDMA", -72)])
        equal(h, ServingSignalHistory(values: [-70, -72], rat: "WCDMA", reads: 3), "history: only the newest read's scale")
        h = servingSignalHistory([sample(0, "NR", nil), sample(5, "NR", nil)])
        equal(h, ServingSignalHistory(values: [], rat: "NR", reads: 2), "history: reads without values")
    }

    // The sparkline's place while it has under two values.
    static func placeholders() {
        let none = ServingSignalHistory(values: [], rat: "LTE", reads: 0)
        let noLeg = NetworkInfo(radio: .on, serving: ServingCell(state: "LIMSRV", cells: []))
        equal(signalPlaceholder(noLeg, none), "No signal", "placeholder: no serving leg")
        equal(signalPlaceholder(NetworkInfo(radio: .airplane), none), "No signal", "placeholder: radio off")
        equal(signalPlaceholder(NetworkInfo(radio: .on), ServingSignalHistory(values: [], rat: "LTE", reads: 3)),
              "No signal data", "placeholder: not read now, reads without values")
        equal(signalPlaceholder(nil, ServingSignalHistory(values: [], rat: "LTE", reads: 1)), "Collecting…",
              "placeholder: the first read")
        equal(signalPlaceholder(saInfo, ServingSignalHistory(values: [-90], rat: "NR", reads: 1)), "Collecting…",
              "placeholder: one value")
        equal(signalPlaceholder(nil, none, failure: "The RM520N-GL (USB 2c7c:0801) is not attached."), "No signal data",
              "placeholder: the reads fail with nothing read")
        equal(signalPlaceholder(nil, none, failure: nil), "Collecting…", "placeholder: no failure yet")
        equal(signalPlaceholder(saInfo, ServingSignalHistory(values: [-90], rat: "NR", reads: 1), failure: "busy"),
              "Collecting…", "placeholder: a failure after a read")
    }

    // The hero's lock badge: the first lock in words and how many more.
    static func lockBadge() {
        check(heroLockText([]) == nil, "lock badge: nothing locked")
        equal(heroLockText(["5G SA cell n41 · PCI 186"]), "Locked: 5G SA cell n41 · PCI 186", "lock badge: one")
        equal(heroLockText(["5G SA cell n41 · PCI 186", "5G SA bands n25, n41, n71"]),
              "Locked: 5G SA cell n41 · PCI 186 +1", "lock badge: two")
    }

    // The serving leg's RSRP now, its name on its scale and its zone's quality.
    static func readouts() {
        let none = ServingSignalHistory(values: [], rat: "LTE", reads: 0)
        equal(signalReadout(saInfo, none), SignalReadout(value: -86, title: "RSRP", quality: 3), "readout: SA")
        let wcdma = NetworkInfo(radio: .on, serving: ServingCell(state: "NOCONN",
                                                                 cells: [cellLeg("WCDMA", rsrp: -80, sinr: nil, band: nil)]))
        equal(signalReadout(wcdma, none), SignalReadout(value: -80, title: "RSCP", quality: 3), "readout: 3G is RSCP")
        let noLeg = NetworkInfo(radio: .on, serving: ServingCell(state: "SEARCH", cells: []))
        equal(signalReadout(noLeg, ServingSignalHistory(values: [-70], rat: "WCDMA", reads: 1)),
              SignalReadout(value: nil, title: "RSCP", quality: nil), "readout: no leg now, the history's scale")
        equal(signalReadout(nil, none), SignalReadout(value: nil, title: "RSRP", quality: nil), "readout: nothing read")
    }

    // The advice's not-in-QMI-mode sentence and the commands right after it.
    static func qmiAdvice() {
        let rm = driverStatus(modem: .notQMI)
        let rmLines = qmiModeAdvice(advice(rm, bundledVersion: "318.19.40"))
        check(rmLines.count == 2 && rmLines[1] == usbModeQmiCommand
              && rmLines[0].hasPrefix("The modem is attached but not in QMI mode"), "advice: the RM520N-GL",
              "got \(rmLines)")
        let other = driverStatus(modem: .notQMI, model: quectelModel(product: 0x0125))
        let otherLines = qmiModeAdvice(advice(other, bundledVersion: "318.19.40"))
        check(otherLines.count == 3 && otherLines[1] == "AT+QCFG=\"usbnet\",0" && otherLines[2] == "AT+CFUN=1,1",
              "advice: another model's two AT commands", "got \(otherLines)")
        equal(qmiModeAdvice([]), [], "advice: none")
        check(isAdviceCommand(usbModeQmiCommand) && isAdviceCommand("AT+CFUN=1,1")
              && atFallbackCommands.allSatisfy(isAdviceCommand) && !isAdviceCommand(rmLines[0]),
              "advice: the fixed-width lines")
    }

    // The SIM as last read: not read, ready, PIN required, and the other states in their own words.
    static func simCards() {
        func sim(_ state: SimState) -> SimInfo { SimInfo(state: state, pinLock: true, pinAttempts: 3, pukAttempts: 10) }
        equal(simSummary(nil), SimSummary(state: CardState(text: "Not checked yet", symbol: "questionmark.circle",
                                                           tone: .neutral), action: "Open SIM & Data"), "SIM: not read")
        equal(simSummary(sim(.ready)), SimSummary(state: CardState(text: "Ready", symbol: "checkmark.circle.fill",
                                                                   tone: .good), action: "Open SIM & Data"), "SIM: ready")
        equal(simSummary(sim(.pin)), SimSummary(state: CardState(text: "PIN required", symbol: "lock.fill",
                                                                 tone: .attention), action: "Unlock…"), "SIM: PIN required")
        let puk = simSummary(sim(.puk))
        check(puk.state.text == "Blocked: needs its PUK from the carrier" && puk.state.tone == .attention
              && puk.action == "Open SIM & Data", "SIM: PUK", "got \(puk)")
        equal(simSummary(sim(.notInserted)).state.text, "Not inserted", "SIM: not inserted")
        check(simSummary(sim(.notInserted)).state.tone == .attention && simSummary(sim(.failure)).state.tone == .attention,
              "SIM: not inserted and failure need attention")
        let busy = simSummary(sim(.busy))
        check(busy.state.text == "Busy" && busy.state.tone == .neutral && busy.action == "Open SIM & Data",
              "SIM: busy", "got \(busy)")
    }

    // The unread messages at the last listing.
    static func messageCards() {
        equal(messagesState(listed: false, unread: 0, messageCount: 0),
              CardState(text: "Not checked yet", symbol: "questionmark.circle", tone: .neutral), "messages: not listed")
        equal(messagesState(listed: true, unread: 3, messageCount: 5),
              CardState(text: "3 unread", symbol: "envelope.badge.fill", tone: .highlight), "messages: unread")
        equal(messagesState(listed: true, unread: 0, messageCount: 0),
              CardState(text: "No messages", symbol: "tray", tone: .neutral), "messages: none")
        equal(messagesState(listed: true, unread: 0, messageCount: 4),
              CardState(text: "All read", symbol: "checkmark.circle", tone: .neutral), "messages: all read")
    }

    // The driver card: its state (the hero's pill's words wherever the pill is not connected or connecting), the
    // version line, the advice, the call to action; never green under an orange or red hero.
    static func driverCards() {
        func summary(_ s: DriverStatus, known: Bool = true, bundled: String = "318.19.40",
                     headline words: String? = nil) -> DriverSummary {
            driverSummary(headline: words ?? headline(s), status: s, known: known, bundledVersion: bundled)
        }
        var d = summary(driverStatus(state: "up"))
        check(d.state.text == "Running" && d.state.tone == .good && d.action == .details && d.actionTitle == "Details"
                && d.version == "Version 318.19.40", "driver: running", "got \(d)")
        d = summary(driverStatus(modem: .absent))
        check(d.state.text == "Enabled" && d.state.tone == .good && d.action == .details, "driver: enabled, no modem",
              "got \(d)")
        d = summary(driverStatus(state: "up"), bundled: "318.20.1")
        check(d.state.text == "Update available" && d.state.tone == .attention && d.action == .update
              && d.actionTitle == "Update" && d.version == "Version 318.19.40 → 318.20.1", "driver: update", "got \(d)")
        check(summary(driverStatus(state: "up"), bundled: "318.19.40").action == .details, "driver: same version, no update")
        check(summary(driverStatus(state: "up"), bundled: "318.18.1").action == .details,
              "driver: an older bundled version (Replace) is no call to action")
        check(summary(driverStatus(state: "up"), bundled: "").action == .details, "driver: no bundled version, no update")
        d = summary(driverStatus([ExtensionEntry(version: "318.19.40", enabled: false, awaitingApproval: true,
                                                 uninstalling: false)]))
        check(d.state.text == "Waiting for approval" && d.state.tone == .attention && d.action == .openSystemSettings
              && d.actionTitle == "Open System Settings" && d.lines.isEmpty, "driver: waiting for approval", "got \(d)")
        d = summary(driverStatus(modem: .notQMI))
        check(d.state.text == "Not in QMI mode" && d.state.tone == .attention && d.action == .details
              && d.actionTitle == "Details" && d.lines.count == 2 && d.lines[1] == usbModeQmiCommand,
              "driver: not in QMI mode", "got \(d)")
        d = summary(driverStatus([]))
        check(d.state.text == "Not installed" && d.state.tone == .attention && d.action == .install
              && d.actionTitle == "Install" && d.version == "Version —", "driver: not installed", "got \(d)")
        let older = ExtensionEntry(version: "318.18.1", enabled: true, awaitingApproval: false, uninstalling: false)
        d = summary(driverStatus([installed, older]))
        check(d.state.text == "Needs attention" && d.state.tone == .attention && d.action == .details,
              "driver: two entries", "got \(d)")
        d = summary(driverStatus(), known: false, headline: "Asking the system…")
        check(d.state.text == "Checking…" && d.state.tone == .neutral && d.action == nil && d.version == "Version —",
              "driver: asking", "got \(d)")
        d = summary(driverStatus(), known: false, headline: unknownHeadline)
        check(d.state.text == "Status unknown" && d.state.tone == .error && d.action == .details,
              "driver: no listing", "got \(d)")
        d = summary(driverStatus(state: "up"), known: false, headline: "Connected")
        check(d.state.text == "Running" && d.version == "Version —" && d.action == .details,
              "driver: attached, the listing not known", "got \(d)")

        // A headline not known here is shown as the hero shows it, in orange with Details, never as green Running.
        d = summary(driverStatus(state: "up"), headline: "Something new")
        check(d.state.text == "Something new" && d.state.tone == .attention && d.action == .details
              && d.actionTitle == "Details", "driver: a headline not known here", "got \(d)")

        // Never green under an orange or red hero: for every headline, an attention or error pill gives an attention
        // or error card, with the pill's own words.
        let waiting = ExtensionEntry(version: "318.19.40", enabled: false, awaitingApproval: true, uninstalling: false)
        let off = ExtensionEntry(version: "318.19.40", enabled: false, awaitingApproval: false, uninstalling: false)
        let headlines = [driverStatus([]), driverStatus([installed, older]), driverStatus([off]), driverStatus([waiting]),
                         driverStatus(state: "up"), driverStatus(state: "connecting"), driverStatus(state: "backoff"),
                         driverStatus(modem: .absent), driverStatus(modem: .notQMI), driverStatus()].map { headline($0) }
            + ["Asking the system…", unknownHeadline, "Something new"]
        for words in headlines {
            let pill = connectionPill(words)
            let card = summary(driverStatus(state: "up"), known: true, headline: words).state
            switch pill.state {
            case .attention:
                check(card.tone == .attention && card.text == pill.text, "driver: \(words) is attention, as the hero",
                      "got \(card)")
            case .error:
                check(card.tone == .error && card.text == pill.text, "driver: \(words) is an error, as the hero",
                      "got \(card)")
            case .connected, .connecting, .down:
                check(card.tone != .error, "driver: \(words) is not an error", "got \(card)")
            }
        }
    }

    // ByteCountFormatter's file style, "—" when not known; a count past Int64 is clamped, not a crash.
    static func byteCounts() {
        equal(byteText(nil), "—", "bytes: not known")
        equal(byteText(1_834_567_890), ByteCountFormatter.string(fromByteCount: 1_834_567_890, countStyle: .file),
              "bytes: file style")
        equal(byteText(UInt64.max), ByteCountFormatter.string(fromByteCount: Int64.max, countStyle: .file),
              "bytes: clamped")
    }
}
