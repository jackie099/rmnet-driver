// What the Overview's cards say (OverviewView.swift draws it): the serving leg's RSRP over the last ten minutes for
// the signal sparkline, and the words in its place while it has too few values; the signal card's readout; the
// not-in-QMI-mode advice lines; the SIM, messages and driver cards' states and calls to action; and the byte counts.
// Foundation only (with the status, network, settings and shell models and ModemController's SignalSample), so
// `make app-test` tests it (tests/app/OverviewModelTests.swift).
import Foundation

// MARK: - Signal

/// The signal history as the sparkline draws it: one value a read, oldest first; the newest read's leg ("NR",
/// "LTE", "WCDMA"; "LTE" with none), whose scale the values are on; and how many reads there were.
struct ServingSignalHistory: Equatable {
    let values: [Double]
    let rat: String
    let reads: Int
}

/// The signal history's reads of the last `window` seconds back from `until` (the last network read that succeeded;
/// the newest sample's time when nil), with a leg: one value a read, the RSRP (RSCP) of the leg that stands for the
/// connection (as servingLeg: the NR leg when it has an RSRP, else the LTE leg, else the read's first), only on the
/// newest read's scale (RSCP for 3G, else RSRP).
func servingSignalHistory(_ samples: [SignalSample], until: Date? = nil, window: TimeInterval = 600)
    -> ServingSignalHistory {
    guard let latest = samples.last?.at else { return ServingSignalHistory(values: [], rat: "LTE", reads: 0) }
    let from = max(until ?? latest, latest).addingTimeInterval(-window)
    var reads: [[SignalSample]] = []
    for sample in samples where sample.at >= from {
        if let last = reads.last?.last, last.at == sample.at {
            reads[reads.count - 1].append(sample)
        } else {
            reads.append([sample])
        }
    }
    let serving = reads.compactMap { read in
        read.first(where: { $0.leg == "NR" && $0.rsrp != nil }) ?? read.first(where: { $0.leg == "LTE" }) ?? read.first
    }
    let rat = serving.last?.leg ?? "LTE"
    let values = serving.filter { ($0.leg == "WCDMA") == (rat == "WCDMA") }.compactMap { $0.rsrp.map(Double.init) }
    return ServingSignalHistory(values: values, rat: rat, reads: reads.count)
}

/// The sparkline's place while it has under two values: "No signal" when the last read says there is none (the
/// radio off, or no serving leg: a read with no leg adds nothing to the history), "No signal data" after two reads
/// without a value or while the reads fail with nothing read before (`failure`: the last read's; the hero says why),
/// else "Collecting…".
func signalPlaceholder(_ info: NetworkInfo?, _ history: ServingSignalHistory, failure: String? = nil) -> String {
    if let info, info.serving.flatMap({ servingLeg($0.cells) }) == nil, signalLevel(info) == 0 { return "No signal" }
    if history.values.isEmpty && history.reads >= 2 { return "No signal data" }
    if info == nil && failure != nil { return "No signal data" }
    return "Collecting…"
}

/// The hero's lock badge: what the modem is locked to, as the Network screen last read it (NetworkCards.lockParts:
/// the cell lock, then each RAT whose bands are locked), the first in words and how many more ("Locked: 5G SA cell
/// n41 · PCI 186 +1"); nil when nothing is locked or it was not read.
func heroLockText(_ parts: [String]) -> String? {
    guard let first = parts.first else { return nil }
    return "Locked: \(first)" + (parts.count > 1 ? " +\(parts.count - 1)" : "")
}

/// The signal card's number: the serving leg's RSRP now (nil when the last read has no leg), the metric's name on
/// its scale (RSCP for 3G, else RSRP; the history's scale with no leg now), and its zone's quality (1 poor …
/// 4 excellent; nil with no value).
struct SignalReadout: Equatable {
    let value: Int?
    let title: String
    let quality: Int?
}

func signalReadout(_ info: NetworkInfo?, _ history: ServingSignalHistory) -> SignalReadout {
    let leg = info?.serving.flatMap { servingLeg($0.cells) }
    let rat = leg?.rat ?? history.rat
    let value = leg?.rsrp
    return SignalReadout(value: value, title: SignalMetric.rsrp.title(rat: rat),
                         quality: metricQuality(.rsrp, value.map(Double.init), rat: rat))
}

// MARK: - Small cards

/// How a card's state is coloured: good (green), neutral (secondary), highlight (blue), attention (orange, the card
/// washed and edged orange), error (red).
enum CardTone: Equatable { case good, neutral, highlight, attention, error }

/// A small card's state: its words, its SF Symbol and its tone.
struct CardState: Equatable {
    let text: String
    let symbol: String
    let tone: CardTone
}

/// The SIM card: its state and its button's title (the button opens SIM & Data; nil: no button).
struct SimSummary: Equatable {
    let state: CardState
    let action: String?
}

/// The SIM as the SIM & Data screen last read it (nil: not read): ready; PIN required (Unlock…); blocked, not
/// inserted or failed (attention); another state in its own words (simStateWords); each with a button, so the three
/// small cards end alike (Open SIM & Data, or Unlock… for a PIN).
func simSummary(_ sim: SimInfo?) -> SimSummary {
    guard let sim else {
        return SimSummary(state: CardState(text: "Not checked yet", symbol: "questionmark.circle", tone: .neutral),
                          action: "Open SIM & Data")
    }
    switch sim.state {
    case .ready:
        return SimSummary(state: CardState(text: "Ready", symbol: "checkmark.circle.fill", tone: .good),
                          action: "Open SIM & Data")
    case .pin:
        return SimSummary(state: CardState(text: "PIN required", symbol: "lock.fill", tone: .attention),
                          action: "Unlock…")
    case .puk, .notInserted, .failure:
        return SimSummary(state: CardState(text: firstLetterUppercased(simStateWords(sim.state)),
                                           symbol: "exclamationmark.triangle.fill", tone: .attention),
                          action: "Open SIM & Data")
    case .pin2, .puk2, .busy, .other:
        return SimSummary(state: CardState(text: firstLetterUppercased(simStateWords(sim.state)), symbol: "info.circle",
                                           tone: .neutral),
                          action: "Open SIM & Data")
    }
}

/// The unread messages at the Messages screen's last listing: not checked before any listing (the unread marks are
/// empty then, which is not 0 unread), the count, all read, or no messages.
func messagesState(listed: Bool, unread: Int, messageCount: Int) -> CardState {
    if !listed { return CardState(text: "Not checked yet", symbol: "questionmark.circle", tone: .neutral) }
    if unread > 0 { return CardState(text: "\(unread) unread", symbol: "envelope.badge.fill", tone: .highlight) }
    if messageCount == 0 { return CardState(text: "No messages", symbol: "tray", tone: .neutral) }
    return CardState(text: "All read", symbol: "checkmark.circle", tone: .neutral)
}

/// The driver card's call to action: Install or Update (StatusController.install), System Settings' extensions
/// pane, or the Driver screen.
enum DriverAction: Equatable { case install, update, openSystemSettings, details }

/// The driver card: its state, the version line, the advice lines shown with it (StatusModel.swift's, unchanged),
/// and its call to action with the button's title.
struct DriverSummary: Equatable {
    let state: CardState
    let version: String
    var lines: [String] = []
    var action: DriverAction? = nil
    var actionTitle: String? = nil
}

/// The driver card for the hero's headline (StatusController.connectionHeadline), the status, whether the system's
/// listing is known, and the app's bundled version.
/// - The driver is fine (Connected, Connecting, Link down, modem not attached): an update bundled (the Driver
///   screen's button reads Update and may be pressed) is orange with Update; else green, Running while attached,
///   Enabled otherwise, with Details (the Driver screen), so the three small cards end alike.
/// - Otherwise the hero's pill's words (connectionPill), so the two always agree: Checking… (neutral); Status unknown
///   (red, Details); and in orange: Not installed (Install; the Overview shows its empty state then), Waiting for
///   approval (Open System Settings), Not in QMI mode (the advice's first sentence and its commands, Details),
///   Needs attention (Details), and a headline not known here (Details).
func driverSummary(headline: String, status: DriverStatus, known: Bool, bundledVersion: String) -> DriverSummary {
    let listed = known ? status.entries.first(where: { !$0.uninstalling }) ?? status.entries.first : nil
    let version = "Version " + (listed?.version ?? "—")
    let attention = "exclamationmark.triangle.fill"
    let words = connectionPill(headline).text
    switch headline {
    case "Connected", "Connecting", "Link down", "Installed, modem not attached":
        let title = installTitle(status, bundledVersion: bundledVersion)
        if let listed, known, !bundledVersion.isEmpty, canActivate(status), title == "Update" {
            return DriverSummary(state: CardState(text: "Update available", symbol: "arrow.down.circle.fill",
                                                  tone: .attention),
                                 version: "Version \(listed.version) → \(bundledVersion)", action: .update,
                                 actionTitle: "Update")
        }
        return DriverSummary(state: CardState(text: status.attached ? "Running" : "Enabled",
                                              symbol: "checkmark.circle.fill", tone: .good),
                             version: version, action: .details, actionTitle: "Details")
    case "Asking the system…":
        return DriverSummary(state: CardState(text: words, symbol: "circle.dotted", tone: .neutral), version: version)
    case unknownHeadline:
        return DriverSummary(state: CardState(text: words, symbol: "questionmark.circle", tone: .error),
                             version: version, action: .details, actionTitle: "Details")
    case "Not installed":
        return DriverSummary(state: CardState(text: words, symbol: attention, tone: .attention), version: version,
                             action: .install, actionTitle: installTitle(status, bundledVersion: bundledVersion))
    case "Waiting for approval in System Settings":
        return DriverSummary(state: CardState(text: words, symbol: "hand.raised.fill", tone: .attention),
                             version: version, action: .openSystemSettings, actionTitle: "Open System Settings")
    case "Modem is not in QMI mode":
        return DriverSummary(state: CardState(text: words, symbol: attention, tone: .attention), version: version,
                             lines: qmiModeAdvice(advice(status, bundledVersion: bundledVersion)), action: .details,
                             actionTitle: "Details")
    default:
        // Needs attention, and any headline not known here: orange, as the hero's pill shows it.
        return DriverSummary(state: CardState(text: words, symbol: attention, tone: .attention), version: version,
                             action: .details, actionTitle: "Details")
    }
}

/// The advice's not-in-QMI-mode sentence and the commands right after it: for the RM520N-GL `RMNet usbmode set
/// qmi` (its fallback is on the Driver screen), for another model its two AT commands.
func qmiModeAdvice(_ lines: [String]) -> [String] {
    guard let first = lines.first else { return [] }
    return [first] + lines.dropFirst().prefix(while: isAdviceCommand)
}

/// The Driver screen's rule for the advice lines it shows in a fixed-width font: the commands.
func isAdviceCommand(_ line: String) -> Bool {
    line.hasPrefix("AT+") || line == usbModeQmiCommand || atFallbackCommands.contains(line)
}

// MARK: - Words

/// A byte count in words ("1.83 GB", ByteCountFormatter's file style); "—" when not known.
func byteText(_ bytes: UInt64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
}

/// The text with its first letter upper case ("not inserted" is "Not inserted", "as of 14:02:11" "As of …").
func firstLetterUppercased(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}
