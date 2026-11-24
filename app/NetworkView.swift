// The window's Network screen, as cards: the connection (technology, registration, operator, PLMN, mode, and what the
// modem is locked to), the signal (a gauge for each metric of each serving leg, the RSRP of each receive path, then the
// last ten minutes of RSRP and SINR as charts), the throughput (the driver's counters, sampled every second while the
// screen is shown), the cell (its numbers, the carriers as band chips sized by their bandwidth, and the neighbour cells
// as a table), and then the controls: the radio and the network mode (the radio's switch; the mode's picker with
// Change… and Put Back), the bands each RAT may use (chips; Change…, a sheet of band chips; Reset; Reset all) and the
// cell lock (a row a RAT with Lock…, a sheet, and Unlock; the cells in use with Lock…; whether the lock is kept across
// a restart; Unlock all). Refresh is in the toolbar, the result of the last change in the banner at the bottom, and
// when the values were read (or why the last read failed) above the cards.
// ModemController (ModemController.swift) holds the state, reads the shown screen and runs one call at a time; the
// rows' words, questions and sentences come from ModemNetwork.swift, ModemSettings.swift and the controller. Switching
// the radio off, the mode's Change… and Put Back… ask first, with words taken when their confirmation opens
// (ModemViewParts.swift); a RAT's Change… opens the bands sheet and Lock… the cell-lock sheet, each its own question.
// Switching the radio on, Reset, Reset all, Unlock and Unlock all ask nothing (they give the modem back its own
// choice; the lines beside Reset all and Unlock all warn instead). What the cards show is worked out by NetworkCards,
// at the end of this file: Foundation only, tested by tests/app/NetworkViewTests.swift.
import SwiftUI

private enum NetworkAction { case radioOff, changeMode, putBack }

/// The radio's state beside its switch.
private func radioStateWords(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "On"
    case .airplane: return "Off (airplane mode)"
    case .minimum: return "Minimum functionality"
    case .other(let n): return "AT+CFUN \(n)"
    }
}

/// The bands sheet open for one RAT, with its bands as read when it opened.
private struct BandsEdit: Identifiable {
    let opened: BandSet
    var id: BandRat { opened.rat }
}

/// What the cell-lock sheet opens with: a cell in use to fill in, or the RAT whose Lock… opened it (nil: the lock in
/// place, else 5G SA).
private struct CellLockDraft: Identifiable {
    let id = UUID()
    let target: NetworkCards.LockTarget?
    var mode: CellLockSheet.Mode? = nil
}

/// The widest the cards (and the read line above them) get; the same as the Overview's.
private let contentWidth: CGFloat = 760

struct NetworkTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    // The throughput, sampled every second while this screen is shown; not observed here (ThroughputCard observes
    // it, so that the rest of the screen does not redraw every second).
    let throughput: ThroughputSampler
    @State private var question: Question<NetworkAction>? = nil
    @State private var editing: BandsEdit? = nil
    @State private var cellLockDraft: CellLockDraft? = nil
    @State private var persistClicks = 0
    // Counts the clicks on the radio's switch. Each click makes the switch anew from the modem's state as read, so
    // the switch never shows the click: it moves when a read (after the change, or after Switch Off) says so.
    @State private var radioClicks = 0

    /// The picker's modes: the window's choices, then the modem's mode (or the pick) if it is another mode;
    /// the same RATs in another order (the modem's `NR5G:LTE`) are the choice already there (sameMode).
    private var modeChoices: [String] {
        var choices = networkModeChoices
        for mode in [controller.info?.mode, controller.pickedMode].compactMap({ $0 })
        where !choices.contains(where: { sameMode($0, mode) }) {
            choices.append(mode)
        }
        return choices
    }

    /// The picker's selection: the choice of the same mode as the pick (`LTE:NR5G` for the modem's
    /// `NR5G:LTE`). Picking sets the controller's pick; Put Back still sends the modem's own string (R8).
    private var pickedChoice: Binding<String?> {
        Binding(get: { controller.pickedMode.map { p in modeChoices.first(where: { sameMode($0, p) }) ?? p } },
                set: { controller.pickedMode = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            readStatus
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    connectionCard
                    signalCard
                    ThroughputCard(throughput: throughput)
                    cellCard
                    radioAndModeCard
                    bandsCard
                    cellLockCard
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the network and the bands again")
                .disabled(!controller.refreshEnabled)
            }
        }
        .resultBanner(controller.result, kind: controller.resultKind, dismiss: controller.dismissResult,
                      hover: controller.hoverResult)
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: {}))
        // Reads pause while a sheet is open, as for a confirmation; however it closes, they go on.
        .sheet(item: $editing, onDismiss: { controller.setConfirming(false) }) { edit in
            BandsSheet(controller: controller, opened: edit.opened,
                       apply: { chosen in
                           controller.changeBands(edit.opened.rat, to: chosen)
                           editing = nil
                           controller.setConfirming(false)
                       },
                       cancel: {
                           editing = nil
                           controller.setConfirming(false)
                       })
        }
        .sheet(item: $cellLockDraft, onDismiss: { controller.setConfirming(false) }) { draft in
            CellLockSheet(controller: controller,
                          initialTarget: draft.target,
                          initialMode: draft.mode,
                          quickTargets: NetworkCards.lockTargets(controller.info),
                          lockNr: { nr in
                              controller.setNrCellLock(nr)
                              cellLockDraft = nil
                              controller.setConfirming(false)
                          },
                          lockLte: { cells in
                              controller.setLteCellLock(cells)
                              cellLockDraft = nil
                              controller.setConfirming(false)
                          },
                          lockInUse: { cell in
                              controller.lockCellInUse(cell)
                              cellLockDraft = nil
                              controller.setConfirming(false)
                          },
                          cancel: {
                              cellLockDraft = nil
                              controller.setConfirming(false)
                          })
        }
    }

    // MARK: The read line

    /// When the values were read, or why the last read failed (and that the values may be out of date): above the
    /// cards, so it stays in view while they scroll. Not fixedSize: this part of the window does not scroll.
    private var readStatus: some View {
        let failed = controller.infoFailure != nil
        return Label {
            Text(verbatim: readStatusLine(at: controller.infoAt, failure: controller.infoFailure,
                                          valuesShown: controller.info != nil, reading: "Reading the network…"))
                .textSelection(.enabled)
        } icon: {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(failed ? Color.orange : Color.secondary)
        }
        .font(.callout)
        .foregroundStyle(failed ? Color.primary : Color.secondary)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: Connection

    private var connectionCard: some View {
        let info = controller.info
        return Card("Connection", symbol: "antenna.radiowaves.left.and.right", accessory: {
            if let info {
                if let tech = techBadgeText(info) {
                    TechBadge(text: tech)
                } else if let words = NetworkCards.technologyWithoutBadge(info) {
                    Text(verbatim: words)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(NetworkCards.connectionRows(info), id: \.label) { row in
                    KeyValueRow(label: row.label, value: row.value)
                }
                // A lock explains a connection that will not move to a better cell, or none at all.
                let locks = NetworkCards.lockParts(cellLock: controller.cellLock, bands: controller.bands)
                if !locks.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text("Locked to")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.s)
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(locks, id: \.self) { lock in
                                Label {
                                    Text(verbatim: lock)
                                        .monospacedDigit()
                                        .textSelection(.enabled)
                                } icon: {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Signal

    /// The connection's bars and their word (signalCaption, as the Overview and the menu bar panel say it) in the
    /// title row; a gauge for each metric of each serving leg (EN-DC: a column for LTE and one for NR); then RSRP and
    /// SINR over the last ten minutes.
    private var signalCard: some View {
        let info = controller.info
        let legs = NetworkCards.shownLegs(info)
        let level = info.flatMap(signalLevel)   // nil: not known
        return Card("Signal", symbol: "cellularbars", accessory: {
            if info != nil {
                HStack(spacing: Spacing.s) {
                    SignalBars(level: level)
                    Text(verbatim: signalCaption(info))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let reason = NetworkCards.noLegReason(info) {
                    ChartPlaceholder(text: reason, height: 64)
                } else if legs.count > 1 {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                            LegGauges(leg: leg)
                        }
                    }
                } else {
                    GaugeRow(leg: legs.first)
                }
                if !controller.antennas.isEmpty && NetworkCards.noLegReason(info) == nil {
                    Divider()
                    AntennaSignalStrip(sets: controller.antennas)
                }
                HStack(alignment: .top, spacing: Spacing.l) {
                    historyChart(.rsrp)
                    historyChart(.sinr)
                }
            }
        }
    }

    private func historyChart(_ metric: SignalMetric) -> some View {
        let rat = controller.signalHistory.last?.leg ?? "LTE"
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(verbatim: "\(metric.title(rat: rat)), last 10 minutes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)   // the chart's own label says it
            SignalHistoryChart(samples: controller.signalHistory, metric: metric, height: 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cell

    /// The serving legs' numbers (EN-DC: a column for LTE and one for NR), then the carriers as chips and the
    /// neighbour cells the modem hears, strongest first (only while it has a serving cell: otherwise they are old).
    private var cellCard: some View {
        let info = controller.info
        let carriers = info.map(NetworkCards.carrierChips) ?? []
        let noLeg = NetworkCards.noLegReason(info)
        let neighbours = noLeg == nil ? NetworkCards.neighbourRows(controller.cellLock?.neighbours ?? []) : []
        return Card("Cell", symbol: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let noLeg {
                    ChartPlaceholder(text: noLeg, height: 44)
                } else {
                    CellGrid(legs: NetworkCards.shownLegs(info))
                }
                if !carriers.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        CardSectionHeading("Carriers", note: carriers.count > 1 ? "Primary first" : nil)
                        FlowLayout(spacing: Spacing.s) {
                            ForEach(Array(carriers.enumerated()), id: \.offset) { _, chip in
                                CarrierChipView(chip: chip)
                            }
                        }
                    }
                }
                if !neighbours.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        CardSectionHeading("Neighbour cells", note: "Strongest first")
                        NeighbourTable(rows: neighbours)
                    }
                }
            }
        }
    }

    // MARK: Cell lock

    /// As the Bands card: a row a RAT (5G SA, LTE) with its lock or `Not locked`, Lock… (the sheet, for that RAT) and
    /// Unlock; the cells in use, each with Lock… (the sheet, filled in); whether the lock is kept across a restart;
    /// then what a lock does, beside Unlock all. While the lock is unknown, that it was not read yet or why not.
    private var cellLockCard: some View {
        let lock = controller.cellLock
        let targets = NetworkCards.lockTargets(controller.info)
        return Card("Cell lock", symbol: "lock", accessory: {
            if let lock {
                if lock.isLocked {
                    StateBadge(text: "Locked", symbol: "lock.fill", tint: .orange)
                } else {
                    StateBadge(text: "Not locked", symbol: "lock.open")
                }
            }
        }) {
            if let lock {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let failure = controller.cellLockFailure {
                        warning("\(failure) The cell lock below may be out of date.")
                    }
                    lockRow("5G SA", locked: lock.nr.map(NetworkCards.nrLockText), mode: .sa,
                            unlock: { controller.setNrCellLock(nil) })
                    Divider()
                    lockRow("LTE", locked: lock.lte.isEmpty ? nil : NetworkCards.lteLockText(lock.lte), mode: .lte,
                            unlock: { controller.setLteCellLock([]) })
                    if !targets.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            CardSectionHeading("Cells in use")
                            ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                                lockTargetRow(target, locked: NetworkCards.targetIsLocked(target, lock))
                            }
                        }
                    }
                    Divider()
                    Toggle("Keep the lock when the modem restarts",
                           isOn: Binding(get: { lock.persistsAcrossReboot }, set: { persist in
                               persistClicks += 1
                               controller.setCellLockPersist(lte: persist, nr: persist)
                           }))
                    .toggleStyle(.checkbox)
                    .id(persistClicks)
                    .disabled(!controller.refreshEnabled)
                    HStack(alignment: .center, spacing: Spacing.m) {
                        Text("A locked modem uses only that cell: if it goes away, there is no service until it is "
                             + "unlocked. The connection can drop for a few seconds when a lock changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.m)
                        Button("Unlock all") { controller.unlockAllCells() }
                            .disabled(!controller.refreshEnabled || !lock.isLocked)
                    }
                }
            } else if let failure = controller.cellLockFailure {
                warning(failure)
            } else {
                Text("Not read yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A RAT's lock: its name, the cell (or `Not locked`), Lock… and Unlock, as a RAT's row of the Bands card.
    private func lockRow(_ name: String, locked: String?, mode: CellLockSheet.Mode, unlock: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(verbatim: name)
                .font(.headline)
                .frame(minWidth: 64, alignment: .leading)
            Text(verbatim: locked ?? "Not locked")
                .monospacedDigit()
                .foregroundStyle(locked == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.s)
            Button("Lock…") { openCellLockSheet(nil, mode: mode) }
                .disabled(!controller.refreshEnabled)
                .accessibilityLabel(Text(verbatim: "Lock \(name) to a cell…"))
            Button("Unlock", action: unlock)
                .disabled(!controller.refreshEnabled || locked == nil)
                .accessibilityLabel(Text(verbatim: "Unlock \(name)"))
        }
    }

    /// A cell in use: its band as a chip, its role and numbers, and Lock… (or `Locked` when it is the lock).
    private func lockTargetRow(_ target: NetworkCards.LockTarget, locked: Bool) -> some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            BandTag(band: target.band)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: target.role)
                    .font(.callout.weight(.medium))
                Text(verbatim: target.detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Spacing.s)
            if locked {
                StateBadge(text: "Locked", symbol: "lock.fill", tint: .orange)
            } else {
                Button("Lock…") { openCellLockSheet(target, mode: nil) }
                    .disabled(!controller.refreshEnabled)
                    .accessibilityLabel(Text(verbatim: "Lock to \(target.label)…"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func openCellLockSheet(_ target: NetworkCards.LockTarget?, mode: CellLockSheet.Mode?) {
        guard controller.refreshEnabled else { return }
        cellLockDraft = CellLockDraft(target: target, mode: mode)
        controller.setConfirming(true)
    }

    // MARK: Radio and mode

    private var radioAndModeCard: some View {
        Card("Radio & mode", symbol: "switch.2") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    Text("Radio")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    Text(verbatim: controller.info?.radio.map(radioStateWords) ?? "—")
                    // No switch while the radio is not known (nothing read, or reads failing): "—" only.
                    if NetworkCards.radioSwitchOn(controller.info?.radio) != nil {
                        radioSwitch
                    }
                }
                HStack(alignment: .center, spacing: Spacing.m) {
                    Text("Network mode")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    if controller.pickedMode != nil {
                        Picker("Network mode", selection: pickedChoice) {
                            ForEach(modeChoices, id: \.self) { mode in
                                Text(verbatim: NetworkCards.capitalizedFirst(modeWords(mode))).tag(Optional(mode))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!controller.refreshEnabled)
                        Button("Change…") {
                            guard let picked = controller.pickedMode else { return }
                            let q = modeQuestion(from: controller.info?.mode, to: picked)
                            ask(Question(action: .changeMode, title: q.title, message: q.message, confirm: "Change"))
                        }
                        .disabled(!controller.modeChangeEnabled)
                    } else {
                        Text(verbatim: "—")
                    }
                }
                if case .mode(let before)? = controller.undo {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Put Back to \(modeWords(before))…") {
                            let from = controller.info?.mode.map { "The modem changes from \(modeWords($0)) back to \(modeWords(before)) at once" }
                                ?? "The current mode could not be read. The modem changes back to \(modeWords(before)) at once"
                            ask(Question(action: .putBack, title: "Put the network mode back to \(modeWords(before))?",
                                         message: "\(from); the connection can drop while it finds a network. "
                                            + "The modem keeps this setting, also after a restart.",
                                         confirm: "Put Back"))
                        }
                        .disabled(!controller.refreshEnabled)
                    }
                    if let command = controller.undoCommand { PutBackCommand(command: command) }
                }
            }
        }
    }

    /// On while the modem says the radio is on. Switching it off asks first (radioOffQuestion); switching it on
    /// switches the radio on at once. Either way it shows the modem's state, not the click (radioClicks), and it is
    /// off while a change runs or waits, or a confirmation or the sheet is open. Shown only once the radio is read.
    private var radioSwitch: some View {
        Toggle("Radio", isOn: Binding(get: { NetworkCards.radioSwitchOn(controller.info?.radio) == true }, set: { on in
            radioClicks += 1
            if on {
                controller.setRadio(on: true)
            } else {
                let q = radioOffQuestion()
                ask(Question(action: .radioOff, title: q.title, message: q.message, confirm: "Switch Off",
                             destructive: true))
            }
        }))
        .toggleStyle(.switch)
        .labelsHidden()
        .id(radioClicks)
        .disabled(!controller.refreshEnabled)
    }

    // MARK: Bands

    /// A row a RAT (its count, Change… and Reset, and its bands as chips unless it allows them all), then Reset all
    /// with its warning; while the bands are unknown, that they were not read yet or why the read failed.
    private var bandsCard: some View {
        Card("Bands", symbol: "square.grid.3x3") {
            if let sets = controller.bands {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let failure = controller.bandsFailure {
                        warning("\(failure) The bands below may be out of date.")
                    }
                    ForEach(Array(sets.enumerated()), id: \.element.rat) { i, set in
                        if i > 0 { Divider() }
                        bandsRow(set)
                    }
                    Divider()
                    HStack(alignment: .center, spacing: Spacing.m) {
                        Text("Reset allows every supported band again, at once; the modem may re-select a cell and drop "
                             + "the connection for a few seconds.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.m)
                        Button("Reset all") { controller.resetAllBands() }
                            .disabled(!controller.resetAllBandsEnabled)
                    }
                }
            } else if let failure = controller.bandsFailure {
                warning(failure)
            } else {
                Text("Not read yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bandsRow(_ set: BandSet) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(verbatim: set.rat.name)
                    .font(.headline)
                    .frame(minWidth: 64, alignment: .leading)
                Text(verbatim: NetworkCards.bandsCount(set))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s)
                Button("Change…") { openBands(set) }
                    .disabled(!controller.bandsChangeEnabled)
                    .accessibilityLabel(Text(verbatim: "Change the \(set.rat.name) bands…"))
                Button("Reset") { controller.resetBands(set.rat) }
                    .disabled(!controller.bandsResetEnabled(set.rat))
                    .accessibilityLabel(Text(verbatim: "Reset the \(set.rat.name) bands"))
            }
            if !NetworkCards.bandsAllAllowed(set) {
                FlowLayout(spacing: 5) {
                    ForEach(NetworkCards.bandChips(set), id: \.band) { chip in
                        BandChipView(label: chip.label, allowed: chip.allowed)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(set.rat.name) bands"))
                .accessibilityValue(Text(verbatim: bandsSummary(set)))
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }

    private func openBands(_ set: BandSet) {
        guard controller.bandsChangeEnabled else { return }
        editing = BandsEdit(opened: set)
        controller.setConfirming(true)
    }

    private func ask(_ q: Question<NetworkAction>) {
        question = q
        controller.setConfirming(true)
    }

    private func perform(_ action: NetworkAction) {
        switch action {
        case .radioOff: controller.setRadio(on: false)
        case .changeMode: controller.changeMode()
        case .putBack: controller.putBack()
        }
    }
}

// MARK: - The cards' parts

/// The throughput card: the current rates in large type over the last two minutes as a chart; without the driver's
/// counters (it is not attached) the chart's place says so, as the Overview's does. It observes the sampler (every
/// second) so that only it redraws.
private struct ThroughputCard: View {
    @ObservedObject var throughput: ThroughputSampler

    var body: some View {
        Card("Throughput", symbol: "arrow.up.arrow.down") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ThroughputRates(current: throughput.current)
                if throughput.sessionRx == nil {
                    ChartPlaceholder(text: "No data from the driver", height: 180)
                } else {
                    ThroughputChart(points: throughput.points, height: 180)
                }
            }
        }
    }
}

/// The one serving leg's gauges side by side; before anything is read, the three of them "—".
private struct GaugeRow: View {
    let leg: CellLeg?

    var body: some View {
        let rat = leg?.rat ?? "LTE"
        HStack(alignment: .top, spacing: Spacing.xl) {
            ForEach(NetworkCards.legMetrics(rat), id: \.self) { metric in
                MetricGauge(metric, value: leg.flatMap { NetworkCards.legValue($0, metric) }, rat: rat)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One of EN-DC's legs: its name and band over its gauges, one under the other.
private struct LegGauges: View {
    let leg: CellLeg

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(verbatim: NetworkCards.legTitle(leg))
                    .font(.headline)
                if let band = leg.band {
                    Text(verbatim: band)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(NetworkCards.legMetrics(leg.rat), id: \.self) { metric in
                MetricGauge(metric, value: NetworkCards.legValue(leg, metric), rat: leg.rat)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: NetworkCards.legTitle(leg)))
    }
}

/// The cell's numbers: a label column, then a value column a leg (named above them when there are two).
private struct CellGrid: View {
    let legs: [CellLeg]

    var body: some View {
        let named = legs.count > 1
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.s) {
            if named {
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                        Text(verbatim: NetworkCards.legTitle(leg))
                            .font(.headline)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            ForEach(NetworkCards.cellRows(legs), id: \.label) { row in
                GridRow {
                    Text(verbatim: row.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { i, value in
                        Text(verbatim: value)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .gridColumnAlignment(.trailing)
                            .accessibilityLabel(Text(verbatim: named ? "\(NetworkCards.legTitle(legs[i])) \(row.label)"
                                                                     : row.label))
                            .accessibilityValue(Text(verbatim: value))
                    }
                }
            }
        }
    }
}

/// A carrier: its band, bandwidth and optional PCI/channel, 5G blue and LTE teal; primary fill is stronger.
private struct CarrierChipView: View {
    let chip: NetworkCards.CarrierChip

    var body: some View {
        let tint = techTint(chip.band.hasPrefix("n") ? "5G" : chip.band.hasPrefix("B") ? "LTE" : "")
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let detail = NetworkCards.carrierDetailText(chip)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(verbatim: chip.band)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let bw = chip.bandwidthMHz.map(NetworkCards.bandwidthText) {
                    Text(verbatim: bw)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if chip.bandwidthMHz == nil {
                Text(verbatim: "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.s + 2)
        .padding(.vertical, Spacing.xs + 1)
        .frame(minWidth: NetworkCards.carrierChipWidth(chip.bandwidthMHz), alignment: .leading)
        .background(shape.fill(tint.opacity(chip.primary ? 0.24 : 0.12)))
        .overlay(shape.strokeBorder(tint.opacity(chip.primary ? 0.7 : 0.4), lineWidth: chip.primary ? 1 : 0.5))
        .help(chip.primary ? "Primary carrier" : "Carrier")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Carrier \(chip.band)"))
        .accessibilityValue(Text(verbatim: [chip.primary ? "primary" : nil,
                                            chip.bandwidthMHz.map(NetworkCards.bandwidthText),
                                            detail]
            .compactMap { $0 }.joined(separator: ", ")))
    }
}

/// The receive paths' RSRP (AT+QRSRP, AT+QRSRQ, AT+QSINR), a row of four tiles a RAT (named when there are two).
private struct AntennaSignalStrip: View {
    let sets: [AntennaSignalSet]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            CardSectionHeading("Antennas", note: "RSRP of each receive path")
            ForEach(sets, id: \.rat) { set in
                HStack(alignment: .center, spacing: Spacing.s) {
                    if sets.count > 1 {
                        Text(verbatim: NetworkCards.ratName(set.rat))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    }
                    ForEach(NetworkCards.antennaTiles([set]), id: \.index) { tile in
                        AntennaTileView(tile: tile)
                    }
                }
            }
        }
    }
}

/// One receive path: its name with the bars of its RSRP's quality, the RSRP, then its RSRQ and SINR; dimmed when the
/// modem does not use it.
private struct AntennaTileView: View {
    let tile: NetworkCards.AntennaTile

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(verbatim: tile.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.xs)
                if tile.active {
                    SignalBars(level: tile.quality, height: 10)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: tile.rsrpText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tile.active ? .primary : .tertiary)
                if tile.active && tile.rsrpText != NetworkCards.notReported {
                    Text("dBm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: tile.detailText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.s + 2)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(.quaternary.opacity(tile.active ? 0.5 : 0.2)))
        .opacity(tile.active ? 1 : 0.7)
        .help(tile.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(NetworkCards.ratName(tile.rat)) \(tile.title)"))
        .accessibilityValue(Text(verbatim: tile.active
            ? "RSRP \(tile.rsrpText) dBm" + (tile.quality.map { ", \(signalWord($0).lowercased())" } ?? "") + ", \(tile.detailText)"
            : tile.detailText))
    }
}

/// The neighbour cells as a table: RAT, frequency (the serving cell's or another), PCI, channel, RSRP (in its
/// quality's colour), RSRQ, SINR.
private struct NeighbourTable: View {
    let rows: [NetworkCards.NeighbourRow]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.l, verticalSpacing: 6) {
            GridRow {
                ForEach(["RAT", "Frequency", "PCI", "Channel", "RSRP", "RSRQ", "SINR"], id: \.self) { title in
                    Text(verbatim: title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(["RAT", "Frequency"].contains(title) ? .leading : .trailing)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(verbatim: row.rat).fontWeight(.medium)
                    Text(verbatim: row.frequency).foregroundStyle(.secondary)
                    Text(verbatim: row.pci)
                    Text(verbatim: row.channel)
                    Text(verbatim: row.rsrp)
                        .foregroundStyle(row.quality.map { signalTextTint($0) } ?? .primary)
                    Text(verbatim: row.rsrq)
                    Text(verbatim: row.sinr)
                }
                .monospacedDigit()
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
    }
}

/// A band as a small chip in its technology's colour ("n41" blue, "B66" teal), as the carriers show it.
private struct BandTag: View {
    let band: String

    var body: some View {
        let tint = techTint(band.hasPrefix("n") ? "5G" : band.hasPrefix("B") ? "LTE" : "")
        Text(verbatim: band)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(minWidth: 44)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// The sheet Lock… opens: a 5G SA cell (`AT+QNWLOCK="common/5g"`: band, PCI, ARFCN, subcarrier spacing) or up to ten
/// LTE cells (`AT+QNWLOCK="common/4g"`: EARFCN and PCI each), filled in from a cell in use when one was chosen, else
/// from the lock in place; the cells in use, to fill it in; the rule a value breaks; what a lock does; Lock (the
/// default button) and Cancel. The sheet is the question, as the bands sheet is. The subcarrier spacing is never
/// guessed: one the modem does not report for a cell must be chosen. A cell in use (one of `quickTargets`) is locked
/// with `lockInUse`, which locks it only while the modem still uses it (read again with the lock); any other cell with
/// `lockNr` or `lockLte`, as typed.
struct CellLockSheet: View {
    enum Mode: String, CaseIterable {
        case sa = "5G SA"
        case lte = "LTE"
    }

    private struct LteRowDraft: Identifiable {
        let id = UUID()
        var earfcn: String
        var pci: String
    }

    @ObservedObject var controller: ModemController
    let quickTargets: [NetworkCards.LockTarget]
    let lockNr: (NrCellLock) -> Void
    let lockLte: ([LteLockedCell]) -> Void
    let lockInUse: (CellInUse) -> Void
    let cancel: () -> Void

    @State private var mode: Mode
    @State private var nrBand: String
    @State private var nrPci: String
    @State private var nrArfcn: String
    @State private var nrScs: Int?        // nil: not chosen (the modem did not report it, or nothing was filled in)
    @State private var lteRows: [LteRowDraft]

    init(controller: ModemController, initialTarget: NetworkCards.LockTarget?, initialMode: Mode? = nil,
         quickTargets: [NetworkCards.LockTarget], lockNr: @escaping (NrCellLock) -> Void,
         lockLte: @escaping ([LteLockedCell]) -> Void, lockInUse: @escaping (CellInUse) -> Void,
         cancel: @escaping () -> Void) {
        self.controller = controller
        self.quickTargets = quickTargets
        self.lockNr = lockNr
        self.lockLte = lockLte
        self.lockInUse = lockInUse
        self.cancel = cancel

        var startMode: Mode = initialMode ?? .sa
        var band = ""
        var pci = ""
        var arfcn = ""
        var scs: Int? = nil
        var lte: [LteRowDraft] = [LteRowDraft(earfcn: "", pci: "")]

        let currentNr = controller.cellLock?.nr
        let currentLte = controller.cellLock?.lte ?? []
        if let target = initialTarget {
            switch target.kind {
            case .nr(let nr):
                startMode = .sa
                (band, pci, arfcn, scs) = (String(nr.band), String(nr.pci), String(nr.arfcn), nr.scsKHz)
            case .lte(let cell):
                startMode = .lte
                lte = [LteRowDraft(earfcn: String(cell.earfcn), pci: String(cell.pci))]
            }
        } else {
            if initialMode == nil, currentNr == nil, !currentLte.isEmpty { startMode = .lte }
            if let currentNr {
                (band, pci, arfcn, scs) = (String(currentNr.band), String(currentNr.pci), String(currentNr.arfcn),
                                           currentNr.scsKHz)
            }
            if !currentLte.isEmpty {
                lte = currentLte.map { LteRowDraft(earfcn: String($0.earfcn), pci: String($0.pci)) }
            }
        }
        _mode = State(initialValue: startMode)
        _nrBand = State(initialValue: band)
        _nrPci = State(initialValue: pci)
        _nrArfcn = State(initialValue: arfcn)
        _nrScs = State(initialValue: scs)
        _lteRows = State(initialValue: lte)
    }

    private var parsedNr: NrCellLock? {
        let bandClean = nrBand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBand = (bandClean.first == "n" || bandClean.first == "N") ? String(bandClean.dropFirst()) : bandClean
        guard let pci = Int(nrPci.trimmingCharacters(in: .whitespacesAndNewlines)),
              let arfcn = Int(nrArfcn.trimmingCharacters(in: .whitespacesAndNewlines)),
              let band = Int(trimmedBand), let nrScs else { return nil }
        return NrCellLock(pci: pci, arfcn: arfcn, scsKHz: nrScs, band: band)
    }

    /// The band, PCI and ARFCN are whole numbers (the subcarrier spacing aside).
    private var numbersEntered: Bool {
        let bandClean = nrBand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBand = (bandClean.first == "n" || bandClean.first == "N") ? String(bandClean.dropFirst()) : bandClean
        return Int(nrPci.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && Int(nrArfcn.trimmingCharacters(in: .whitespacesAndNewlines)) != nil && Int(trimmedBand) != nil
    }

    private var supportedSaBands: [Int]? {
        controller.bands?.first(where: { $0.rat == .sa })?.supported
    }

    private var parsedLte: [LteLockedCell]? {
        guard !lteRows.isEmpty else { return nil }
        var out: [LteLockedCell] = []
        for row in lteRows {
            guard let earfcn = Int(row.earfcn.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let pci = Int(row.pci.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            out.append(LteLockedCell(earfcn: earfcn, pci: pci))
        }
        return out
    }

    private var validationError: String? {
        switch mode {
        case .sa:
            if nrBand.isEmpty && nrPci.isEmpty && nrArfcn.isEmpty { return nil }
            guard let parsedNr else {
                return nrScs == nil && numbersEntered
                    ? "Choose the subcarrier spacing: the modem does not report it for every cell."
                    : "Enter the band, PCI and ARFCN as whole numbers."
            }
            return nrCellLockProblem(parsedNr, supportedSaBands: supportedSaBands)
        case .lte:
            if lteRows.allSatisfy({ $0.earfcn.isEmpty && $0.pci.isEmpty }) { return nil }
            guard let parsedLte else { return "Enter each cell's EARFCN and PCI as whole numbers." }
            return lteCellLockProblem(parsedLte)
        }
    }

    /// The values are the lock in place already.
    private var isCurrentLock: Bool {
        switch mode {
        case .sa: return parsedNr != nil && parsedNr == controller.cellLock?.nr
        case .lte: return parsedLte != nil && parsedLte == controller.cellLock?.lte
        }
    }

    private var canApply: Bool {
        guard !isCurrentLock else { return false }
        switch mode {
        case .sa:
            guard let parsedNr else { return false }
            return nrCellLockProblem(parsedNr, supportedSaBands: supportedSaBands) == nil
        case .lte:
            guard let parsedLte, !parsedLte.isEmpty else { return false }
            return lteCellLockProblem(parsedLte) == nil
        }
    }

    private var targetsShown: [NetworkCards.LockTarget] {
        quickTargets.filter { t in
            switch t.kind {
            case .nr: return mode == .sa
            case .lte: return mode == .lte
            }
        }
    }

    private var persistWords: String {
        controller.cellLock?.persistsAcrossReboot == true
            ? "The lock is kept when the modem restarts."
            : "The lock is cleared when the modem restarts."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(symbol: "lock", title: "Lock to a cell",
                        subtitle: "The modem then uses only this cell for \(mode.rawValue).")
            Picker("Technology", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !targetsShown.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Fill in from a cell in use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(Array(targetsShown.enumerated()), id: \.offset) { _, target in
                        Button {
                            applyQuickTarget(target)
                        } label: {
                            HStack(spacing: Spacing.s) {
                                Text(verbatim: target.band).fontWeight(.semibold)
                                Text(verbatim: target.role).foregroundStyle(.secondary)
                                Text(verbatim: target.detail).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if mode == .sa {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.m) {
                    GridRow {
                        Text("Band").foregroundStyle(.secondary)
                        TextField("Band", text: $nrBand, prompt: Text("n41"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("PCI").foregroundStyle(.secondary)
                        TextField("PCI", text: $nrPci, prompt: Text("0 to 1007"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("ARFCN").foregroundStyle(.secondary)
                        TextField("ARFCN", text: $nrArfcn, prompt: Text("520110"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Subcarrier spacing").foregroundStyle(.secondary)
                        Picker("Subcarrier spacing", selection: $nrScs) {
                            if nrScs == nil {
                                Text("Choose").tag(Int?.none)
                            }
                            ForEach(validNrScsKHz, id: \.self) { scs in
                                Text(verbatim: "\(scs) kHz").tag(Int?.some(scs))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .monospacedDigit()
                .autocorrectionDisabled()
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("EARFCN").font(.caption).foregroundStyle(.secondary)
                        Text("PCI").font(.caption).foregroundStyle(.secondary)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    ForEach(Array(lteRows.enumerated()), id: \.element.id) { idx, _ in
                        GridRow {
                            Text(verbatim: "Cell \(idx + 1)")
                                .foregroundStyle(.secondary)
                            TextField("EARFCN", text: $lteRows[idx].earfcn, prompt: Text("66786"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            TextField("PCI", text: $lteRows[idx].pci, prompt: Text("0 to 503"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Button {
                                lteRows.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(lteRows.count == 1)
                            .help("Remove this cell")
                            .accessibilityLabel(Text(verbatim: "Remove cell \(idx + 1)"))
                        }
                    }
                }
                .monospacedDigit()
                .autocorrectionDisabled()
                Button("Add a Cell") { lteRows.append(LteRowDraft(earfcn: "", pci: "")) }
                    .disabled(lteRows.count >= 10)
                    .help("Up to 10 LTE cells")
            }

            if let error = validationError {
                ProblemNote(text: error)
            } else if isCurrentLock {
                Text("This is the lock in place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            WarningNote(text: "If this cell goes away, the modem has no service until it is unlocked. "
                         + "The connection can drop for a few seconds. \(persistWords)")
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Lock") {
                    switch mode {
                    case .sa:
                        guard let parsedNr else { return }
                        if NetworkCards.inUse(parsedNr, among: quickTargets) { lockInUse(.nr(parsedNr)) } else { lockNr(parsedNr) }
                    case .lte:
                        guard let parsedLte else { return }
                        if let one = parsedLte.first, parsedLte.count == 1, NetworkCards.inUse(one, among: quickTargets) {
                            lockInUse(.lte(one))
                        } else {
                            lockLte(parsedLte)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 500)
    }

    private func applyQuickTarget(_ target: NetworkCards.LockTarget) {
        switch target.kind {
        case .nr(let nr):
            mode = .sa
            (nrBand, nrPci, nrArfcn, nrScs) = (String(nr.band), String(nr.pci), String(nr.arfcn), nr.scsKHz)
        case .lte(let cell):
            mode = .lte
            lteRows = [LteRowDraft(earfcn: String(cell.earfcn), pci: String(cell.pci))]
        }
    }
}

/// A band in a RAT's row: filled when the RAT may use it, outlined when not. Blue, not the accent colour: the
/// system's accent can be yellow, under which the white label could not be read.
private struct BandChipView: View {
    let label: String
    let allowed: Bool

    var body: some View {
        let shape = Capsule()
        Text(verbatim: label)
            .font(.caption.weight(allowed ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(allowed ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(minWidth: 28)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background { if allowed { shape.fill(Color.blue) } }
            .overlay { if !allowed { shape.strokeBorder(.tertiary, lineWidth: 1) } }
    }
}

/// Its views left to right, as many to a line as fit, then on the next line.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, let limit, x + size.width > limit {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            line = max(line, size.height)
        }
        return CGSize(width: limit ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - The bands sheet

/// The sheet Change… opens for one RAT: a chip for each band it supports (`B3` for LTE, `n41` for 5G), on for those
/// it may use as read when the sheet opened, and how many are on; Select all and Clear; the warning; Apply (the
/// default button), off with nothing on or with the bands allowed now (the controller's bandsApplyEnabled), and
/// Cancel. Apply calls `apply` with the bands on, sorted; the screen then closes the sheet.
struct BandsSheet: View {
    @ObservedObject var controller: ModemController
    let opened: BandSet
    let apply: ([Int]) -> Void
    let cancel: () -> Void
    @State private var ticked: Set<Int>

    private static let columns = 7

    init(controller: ModemController, opened: BandSet, apply: @escaping ([Int]) -> Void, cancel: @escaping () -> Void) {
        self.controller = controller
        self.opened = opened
        self.apply = apply
        self.cancel = cancel
        _ticked = State(initialValue: Set(opened.allowed).intersection(opened.supported))
    }

    /// The supported bands, ascending, in rows of `columns`.
    private var rows: [[Int]] {
        let all = bandSorted(opened.supported)
        return stride(from: 0, to: all.count, by: BandsSheet.columns).map {
            Array(all[$0..<min($0 + BandsSheet.columns, all.count)])
        }
    }

    private func tick(_ band: Int) -> Binding<Bool> {
        Binding(get: { ticked.contains(band) },
                set: { on in if on { ticked.insert(band) } else { ticked.remove(band) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(opened.rat.name) bands")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(ticked.count) of \(Set(opened.supported).count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { band in
                            Toggle(isOn: tick(band)) {
                                Text(verbatim: bandLabel(opened.rat, band))
                            }
                            .toggleStyle(BandToggleStyle())
                        }
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Button("Select all") { ticked = Set(opened.supported) }
                    .disabled(ticked == Set(opened.supported))
                Button("Clear") { ticked = [] }
                    .disabled(ticked.isEmpty)
            }
            Label {
                Text("The modem may re-select a cell and drop the connection for a few seconds.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply(ticked.sorted()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.bandsApplyEnabled(opened.rat, Array(ticked)))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }
}

/// A band in the sheet: a chip, filled (blue, as in the Bands card) while on; VoiceOver reads it as a checkbox.
private struct BandToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.callout.weight(configuration.isOn ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(width: 60, height: 26)   // seven a row fill the sheet's 472 pt
                .background { if configuration.isOn { shape.fill(Color.blue) } }
                .overlay { if !configuration.isOn { shape.strokeBorder(.tertiary, lineWidth: 1) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

// MARK: - What the cards show

/// The values the Network screen's cards show, worked out from a network read and the bands: Foundation only (with
/// ModemNetwork.swift's, ModemSettings.swift's and SignalQuality.swift's types), so that `make app-test` tests them
/// (tests/app/NetworkViewTests.swift). A value the modem did not report is "—".
enum NetworkCards {
    static let notReported = "—"

    /// The first letter in upper case, for a value shown on its own ("registered, home network (5GS)" reads
    /// "Registered, home network (5GS)"); the words are otherwise those given.
    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// 100 → "100 MHz", 1.4 → "1.4 MHz".
    static func bandwidthText(_ mhz: Double) -> String {
        (mhz == mhz.rounded() && abs(mhz) < 1e15 ? String(Int(mhz)) : String(mhz)) + " MHz"
    }

    // MARK: Connection

    /// The Connection card's rows: the operator (with the network's own name after it when that differs), the
    /// registration, the PLMN (AT+QSPN's, else the first leg's MCC and MNC) and the network mode (with a 5G kind
    /// disabled), each in the words the network rows use (networkRows).
    static func connectionRows(_ info: NetworkInfo?) -> [(label: String, value: String)] {
        let mode = info.flatMap { i in networkRows(i).first(where: { $0.label == "Network mode" })?.value }
        return [
            (label: "Operator", value: info.flatMap(operatorText) ?? notReported),
            (label: "Registration", value: info?.registration.map { capitalizedFirst(registrationWords($0)) } ?? notReported),
            (label: "PLMN", value: info.flatMap(plmnText) ?? notReported),
            (label: "Network mode", value: mode.map(capitalizedFirst) ?? notReported),
        ]
    }

    /// AT+COPS?'s operator, with AT+QSPN's name in brackets when it differs (ignoring case); either alone.
    static func operatorText(_ info: NetworkInfo) -> String? {
        if let op = info.operatorName, let network = info.networkName, op.caseInsensitiveCompare(network) != .orderedSame {
            return "\(op) (\(network))"
        }
        return info.operatorName ?? info.networkName
    }

    /// AT+QSPN's PLMN, else the first leg's MCC and MNC together ("001" + "01").
    static func plmnText(_ info: NetworkInfo) -> String? {
        if let plmn = info.plmn { return plmn }
        guard let leg = info.serving?.cells.first, let mcc = leg.mcc, let mnc = leg.mnc else { return nil }
        return mcc + mnc
    }

    /// The technology in words where the badge has none to show ("Searching", "Limited service", "None (radio
    /// off)"); nil when the badge shows it or it is not known.
    static func technologyWithoutBadge(_ info: NetworkInfo) -> String? {
        guard techBadgeText(info) == nil else { return nil }
        let words = technologyLabel(info)
        return words == "unknown" ? nil : capitalizedFirst(words)
    }

    // MARK: Signal and cell

    /// The serving legs in the cards' order: LTE first (EN-DC's columns read LTE, then NR), the others as read.
    static func shownLegs(_ info: NetworkInfo?) -> [CellLeg] {
        let legs = info?.serving?.cells ?? []
        return legs.filter { $0.rat == "LTE" } + legs.filter { $0.rat != "LTE" }
    }

    /// A leg's name over its column: "NR" for either 5G leg (as the signal history names it), else its RAT.
    static func legTitle(_ leg: CellLeg) -> String {
        leg.rat.hasPrefix("NR5G") ? "NR" : leg.rat
    }

    /// The metrics a leg's RAT reports: WCDMA its RSCP only; the others RSRP, RSRQ and SINR.
    static func legMetrics(_ rat: String) -> [SignalMetric] {
        rat == "WCDMA" ? [.rsrp] : [.rsrp, .rsrq, .sinr]
    }

    static func legValue(_ leg: CellLeg, _ metric: SignalMetric) -> Double? {
        switch metric {
        case .rsrp: return leg.rsrp.map(Double.init)
        case .rsrq: return leg.rsrq.map(Double.init)
        case .sinr: return leg.sinr
        }
    }

    /// Why the Signal and Cell cards have no leg to show: the radio is off (airplane mode or minimum functionality),
    /// or the serving cell was read with no leg (searching, limited or no service). nil when there is a leg, or when
    /// nothing (or no serving cell) was read: the cards then show "—".
    static func noLegReason(_ info: NetworkInfo?) -> String? {
        guard let info else { return nil }
        if info.radio == .airplane || info.radio == .minimum { return "The radio is off." }
        guard let serving = info.serving, serving.cells.isEmpty else { return nil }
        return "No serving cell."
    }

    struct CellRow: Equatable {
        let label: String
        let values: [String]   // one a leg, in the order given; one "—" with no leg
    }

    /// The Cell card's rows, a value a leg: band (with the duplex), bandwidth, channel (ARFCN, EARFCN or UARFCN),
    /// SCS when reported by NR, PCI, cell ID and TAC; PSC and LAC for a WCDMA cell on its own. With no leg, one
    /// column of "—".
    static func cellRows(_ legs: [CellLeg]) -> [CellRow] {
        let shown: [CellLeg?] = legs.isEmpty ? [nil] : legs
        let wcdma = legs.count == 1 && legs[0].rat == "WCDMA"
        func row(_ label: String, _ value: (CellLeg) -> String?) -> CellRow {
            CellRow(label: label, values: shown.map { $0.flatMap(value) ?? notReported })
        }
        var rows = [
            row("Band") { leg in leg.band.map { band in leg.duplex.map { "\(band) (\($0))" } ?? band } },
            row("Bandwidth") { $0.bandwidthMHz.map(bandwidthText) },
            row("Channel") { $0.channel.map { String($0) } },
        ]
        if legs.contains(where: { $0.scsKHz != nil }) {
            rows.append(row("SCS") { $0.scsKHz.map { "\($0) kHz" } })
        }
        rows += [
            row(wcdma ? "PSC" : "PCI") { $0.pci.map { String($0) } },
            row("Cell ID") { $0.cellID },
            row(wcdma ? "LAC" : "TAC") { $0.tac },
        ]
        return rows
    }

    struct CarrierChip: Equatable {
        let band: String
        let bandwidthMHz: Double?
        let primary: Bool
        var channel: Int? = nil
        var pci: Int? = nil
    }

    /// `"PCI 147 · ARFCN 520110"` (or `EARFCN` for `B…`) when PCI or channel is known; nil when neither is.
    static func carrierDetailText(_ chip: CarrierChip) -> String? {
        var parts: [String] = []
        if let pci = chip.pci { parts.append("PCI \(pci)") }
        if let ch = chip.channel {
            let name = chip.band.hasPrefix("n") ? "ARFCN" : chip.band.hasPrefix("B") ? "EARFCN" : "CH"
            parts.append("\(name) \(ch)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The carriers in use: AT+QCAINFO components first when parsed (preserving each PCC/SCC's own bandwidth,
    /// channel and PCI), falling back to `info.carriers`, then any serving leg's band not listed yet.
    static func carrierChips(_ info: NetworkInfo) -> [CarrierChip] {
        let legs = info.serving?.cells ?? []
        var unassigned = legs.filter { $0.band != nil }
        if !info.carrierComponents.isEmpty {
            var chips = info.carrierComponents.enumerated().map { i, comp in
                let matchedLeg = unassigned.firstIndex(where: { $0.band == comp.band && $0.bandwidthMHz != nil })
                    .map { unassigned.remove(at: $0) }
                return CarrierChip(band: comp.band,
                                   bandwidthMHz: comp.bandwidthMHz ?? matchedLeg?.bandwidthMHz,
                                   primary: i == 0,
                                   channel: comp.channel,
                                   pci: comp.pci)
            }
            for leg in legs {
                guard let b = leg.band, !chips.contains(where: { $0.band == b }) else { continue }
                chips.append(CarrierChip(band: b, bandwidthMHz: leg.bandwidthMHz, primary: false,
                                         channel: leg.channel, pci: leg.pci))
            }
            return chips
        }
        var bands = info.carriers
        for leg in legs {
            if let band = leg.band, !bands.contains(band) { bands.append(band) }
        }
        var bwUnassigned = legs.filter { $0.band != nil && $0.bandwidthMHz != nil }
        return bands.enumerated().map { i, band in
            let leg = bwUnassigned.firstIndex(where: { $0.band == band }).map { bwUnassigned.remove(at: $0) }
            return CarrierChip(band: band, bandwidthMHz: leg?.bandwidthMHz, primary: i == 0 && !info.carriers.isEmpty)
        }
    }

    /// A RAT's name as the cards say it: "NR5G" (AT+QRSRP's) is "5G"; others as given ("LTE").
    static func ratName(_ rat: String) -> String { rat.hasPrefix("NR5G") ? "5G" : rat }

    // MARK: Antennas

    /// One receive path's tile: its name (AT+QRSRP's order: PRX, DRX, RX2, RX3) and what it is, its RSRP (the
    /// number; the unit is the tile's) with the quality zone it falls in, its RSRQ and SINR; a path the modem does
    /// not use is "Not in use".
    struct AntennaTile: Equatable {
        let rat: String
        let index: Int
        let title: String       // "PRX"
        let help: String        // "Receive path 1, primary"
        let active: Bool
        let rsrpText: String    // "-84", or "—"
        let detailText: String  // "RSRQ -11 dB · SINR 18 dB", or "Not in use"
        let quality: Int?       // 1 poor … 4 excellent; nil without an RSRP
    }

    private static let pathRoles = ["primary", "diversity", "MIMO", "MIMO"]

    static func antennaTiles(_ sets: [AntennaSignalSet]) -> [AntennaTile] {
        sets.flatMap { set in
            set.ports.map { port in
                var parts: [String] = []
                if let q = port.rsrq { parts.append("RSRQ \(q) dB") }
                if let s = port.sinr { parts.append("SINR \(s) dB") }
                let detail = port.isActive ? (parts.isEmpty ? "In use" : parts.joined(separator: " · ")) : "Not in use"
                let role = port.index < pathRoles.count ? ", \(pathRoles[port.index])" : ""
                return AntennaTile(rat: set.rat, index: port.index, title: port.name,
                                   help: "Receive path \(port.index + 1)\(role) (\(port.name))",
                                   active: port.isActive, rsrpText: port.rsrp.map { String($0) } ?? notReported,
                                   detailText: detail,
                                   quality: port.rsrp.flatMap { metricQuality(.rsrp, Double($0), rat: set.rat) })
            }
        }
    }

    // MARK: Neighbour cells

    /// A neighbour cell as a row of the Cell card's table: its RAT ("5G", "LTE"), whether it is on the serving cell's
    /// channel ("Same", "Other"), PCI, channel and RSRP, RSRQ, SINR ("—" when not given), and the RSRP's quality zone.
    struct NeighbourRow: Equatable {
        let rat: String
        let frequency: String
        let pci: String
        let channel: String
        let rsrp: String
        let rsrq: String
        let sinr: String
        let quality: Int?
    }

    /// The neighbours strongest first (by RSRP; those without one last, in the modem's order).
    static func neighbourRows(_ cells: [NeighbourCell]) -> [NeighbourRow] {
        let sorted = cells.enumerated().sorted { a, b in
            switch (a.element.rsrp, b.element.rsrp) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { $0.element }
        return sorted.map { n in
            let frequency: String
            switch n.kind {
            case "intra": frequency = "Same"
            case "inter": frequency = "Other"
            default: frequency = n.kind.map(capitalizedFirst) ?? notReported
            }
            return NeighbourRow(rat: ratName(n.rat), frequency: frequency, pci: n.pci.map { String($0) } ?? notReported,
                                channel: n.channel.map { String($0) } ?? notReported,
                                rsrp: n.rsrp.map { "\($0) dBm" } ?? notReported,
                                rsrq: n.rsrq.map { "\($0) dB" } ?? notReported,
                                sinr: n.sinr.map { "\($0) dB" } ?? notReported,
                                quality: n.rsrp.flatMap { metricQuality(.rsrp, Double($0), rat: n.rat == "LTE" ? "LTE" : "NR5G-SA") })
        }
    }

    // MARK: Cell lock

    enum LockTargetKind: Equatable {
        case nr(NrCellTarget)
        case lte(LteLockedCell)
    }

    /// A 5G SA cell in use: its band, PCI and ARFCN, and its subcarrier spacing when the modem reports it (the serving
    /// leg's); nil when it does not (a secondary carrier: AT+QCAINFO gives none), to be chosen, never guessed.
    struct NrCellTarget: Equatable {
        let pci: Int
        let arfcn: Int
        let band: Int
        let scsKHz: Int?

        /// The same cell as `lock` (band, PCI and ARFCN; a spacing reported must be the lock's).
        func isCell(_ lock: NrCellLock) -> Bool {
            lock.pci == pci && lock.arfcn == arfcn && lock.band == band && (scsKHz == nil || scsKHz == lock.scsKHz)
        }
    }

    /// A cell in use the modem can be locked to: its band ("n41"), its role ("Primary", "Secondary", "Serving"),
    /// the rest in words ("100 MHz · PCI 186 · ARFCN 520110"), and the lock it makes.
    struct LockTarget: Equatable {
        let band: String
        let role: String
        let detail: String
        let kind: LockTargetKind

        /// "n41 · 100 MHz · PCI 186 · ARFCN 520110".
        var label: String { "\(band) · \(detail)" }
    }

    /// Lockable 5G SA and LTE cells from AT+QCAINFO's carriers (primary, then secondary) and the serving legs, each
    /// once. 5G cells only while the modem is on 5G SA (an NSA leg cannot be locked with "common/5g"); a 5G cell's
    /// subcarrier spacing only as the serving leg reports it.
    static func lockTargets(_ info: NetworkInfo?) -> [LockTarget] {
        guard let info else { return [] }
        let legs = info.serving?.cells ?? []
        let allowNrSa = legs.contains { $0.rat == "NR5G-SA" }
        var targets: [LockTarget] = []
        var seen = Set<String>()

        func add(_ target: LockTarget, key: String) {
            if seen.insert(key).inserted { targets.append(target) }
        }
        func words(_ bandwidth: Double?, pci: Int, channel: String) -> String {
            ([bandwidth.map(bandwidthText)].compactMap { $0 } + ["PCI \(pci)", channel]).joined(separator: " · ")
        }

        for comp in info.carrierComponents {
            guard let channel = comp.channel, let pci = comp.pci else { continue }
            let role = comp.role == "PCC" ? "Primary" : "Secondary"
            if comp.rat == "NR5G", allowNrSa, comp.band.hasPrefix("n"), let bandNum = Int(comp.band.dropFirst()) {
                let legMatch = legs.first { $0.rat == "NR5G-SA" && $0.band == comp.band && $0.pci == pci && $0.channel == channel }
                add(LockTarget(band: comp.band, role: role,
                               detail: words(comp.bandwidthMHz, pci: pci, channel: "ARFCN \(channel)"),
                               kind: .nr(NrCellTarget(pci: pci, arfcn: channel, band: bandNum, scsKHz: legMatch?.scsKHz))),
                    key: "NR:\(bandNum):\(pci):\(channel)")
            } else if comp.rat == "LTE" {
                add(LockTarget(band: comp.band, role: role,
                               detail: words(comp.bandwidthMHz, pci: pci, channel: "EARFCN \(channel)"),
                               kind: .lte(LteLockedCell(earfcn: channel, pci: pci))),
                    key: "LTE:\(channel):\(pci)")
            }
        }

        for leg in legs {
            guard let channel = leg.channel, let pci = leg.pci else { continue }
            if leg.rat == "NR5G-SA", let bandStr = leg.band, bandStr.hasPrefix("n"), let bandNum = Int(bandStr.dropFirst()) {
                add(LockTarget(band: bandStr, role: "Serving",
                               detail: words(leg.bandwidthMHz, pci: pci, channel: "ARFCN \(channel)"),
                               kind: .nr(NrCellTarget(pci: pci, arfcn: channel, band: bandNum, scsKHz: leg.scsKHz))),
                    key: "NR:\(bandNum):\(pci):\(channel)")
            } else if leg.rat == "LTE" {
                add(LockTarget(band: leg.band ?? "LTE", role: "Serving",
                               detail: words(leg.bandwidthMHz, pci: pci, channel: "EARFCN \(channel)"),
                               kind: .lte(LteLockedCell(earfcn: channel, pci: pci))),
                    key: "LTE:\(channel):\(pci)")
            }
        }
        return targets
    }

    /// The target is the lock in place (its 5G SA cell, or the only LTE cell locked).
    static func targetIsLocked(_ target: LockTarget, _ lock: CellLockState?) -> Bool {
        guard let lock else { return false }
        switch target.kind {
        case .nr(let nr): return lock.nr.map(nr.isCell) ?? false
        case .lte(let cell): return lock.lte == [cell]
        }
    }

    /// A 5G SA lock that is one of the cells in use (so the sheet locks it with lockCellInUse, only while it still is).
    static func inUse(_ lock: NrCellLock, among targets: [LockTarget]) -> Bool {
        targets.contains { if case .nr(let t) = $0.kind { return t.isCell(lock) } else { return false } }
    }

    /// An LTE cell that is one of the cells in use.
    static func inUse(_ cell: LteLockedCell, among targets: [LockTarget]) -> Bool {
        targets.contains { $0.kind == .lte(cell) }
    }

    /// A 5G SA lock in the card's words: "n41 · PCI 186 · ARFCN 520110 · SCS 30 kHz".
    static func nrLockText(_ nr: NrCellLock) -> String {
        "n\(nr.band) · PCI \(nr.pci) · ARFCN \(nr.arfcn) · SCS \(nr.scsKHz) kHz"
    }

    /// LTE locks in the card's words: "PCI 128 · EARFCN 66786", or "3 cells (PCI 128, 301, 7)".
    static func lteLockText(_ cells: [LteLockedCell]) -> String {
        if cells.count == 1, let c = cells.first { return "PCI \(c.pci) · EARFCN \(c.earfcn)" }
        return "\(cells.count) cells (PCI \(cells.map { String($0.pci) }.joined(separator: ", ")))"
    }

    /// What restricts where the modem may camp, for the Connection card: the cell lock, then each RAT whose bands
    /// are locked ("5G SA cell n41 · PCI 186; 5G SA bands n25, n41, n71", or "5G SA: 12 of 28 bands" for more than
    /// four); nil when nothing is locked, or neither was read.
    static func lockSummary(cellLock: CellLockState?, bands: [BandSet]?) -> String? {
        let parts = lockParts(cellLock: cellLock, bands: bands)
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// lockSummary's parts, one a line on the card.
    static func lockParts(cellLock: CellLockState?, bands: [BandSet]?) -> [String] {
        var parts: [String] = []
        if let nr = cellLock?.nr { parts.append("5G SA cell n\(nr.band) · PCI \(nr.pci)") }
        if let lte = cellLock?.lte, !lte.isEmpty {
            parts.append(lte.count == 1 ? "LTE cell PCI \(lte[0].pci)" : "\(lte.count) LTE cells")
        }
        for set in bands ?? [] where bandsLocked(set) {
            let allowed = bandSorted(Array(Set(set.allowed).intersection(set.supported)))
            parts.append(allowed.count <= 4
                         ? "\(set.rat.name) band\(allowed.count == 1 ? "" : "s") " + allowed.map { bandLabel(set.rat, $0) }.joined(separator: ", ")
                         : "\(set.rat.name): \(allowed.count) of \(Set(set.supported).count) bands")
        }
        return parts
    }

    /// The radio switch's position: on while the modem says the radio is on, off for airplane mode, minimum
    /// functionality or another AT+CFUN value; nil while the radio is not known (nothing read, or reads failing),
    /// when the screen shows "—" and no switch.
    static func radioSwitchOn(_ radio: RadioState?) -> Bool? {
        radio.map { $0 == .on }
    }

    /// A carrier chip's width in points, by its bandwidth: 40 pt and 1.2 pt a MHz, at least 56 (room for the band and
    /// "1.4 MHz") and at most 220 (wider than 150 MHz all look the same); 56 when the bandwidth is not known.
    static func carrierChipWidth(_ mhz: Double?) -> CGFloat {
        guard let mhz, mhz > 0 else { return 56 }
        return min(220, max(56, 40 + 1.2 * CGFloat(mhz)))
    }

    // MARK: Bands

    struct BandChip: Equatable {
        let band: Int
        let label: String   // as the sheet labels it: B3, n41
        let allowed: Bool
    }

    /// A RAT's bands as chips, ascending: every band it supports, and any it allows that the modem does not list as
    /// supported; each marked allowed or not.
    static func bandChips(_ set: BandSet) -> [BandChip] {
        let allowed = Set(set.allowed)
        return bandSorted(set.supported + set.allowed).map {
            BandChip(band: $0, label: bandLabel(set.rat, $0), allowed: allowed.contains($0))
        }
    }

    /// The RAT allows every band it supports (and at least one): its row shows the count only.
    static func bandsAllAllowed(_ set: BandSet) -> Bool {
        !set.allowed.isEmpty && !bandsLocked(set)
    }

    /// "All 31 allowed" when the RAT allows every band it supports; else "2 of 28 allowed" (as sets, as
    /// bandsSummary counts them).
    static func bandsCount(_ set: BandSet) -> String {
        let supported = Set(set.supported).count
        if bandsAllAllowed(set) { return "All \(supported) allowed" }
        return "\(Set(set.allowed).count) of \(supported) allowed"
    }
}
