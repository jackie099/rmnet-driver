// The window's SIM & Data screen, a settings-style form: the SIM (its state, the PIN lock and the attempts left as
// rows of dots; while it asks for its PIN, Unlock… opens a sheet with the PIN field), the modem (its IMEI with Change…,
// a sheet, and the module's USB serial number), the IMEI history (every change recorded on this Mac, with Change
// Back… to the IMEI before a change), the profile the driver dials (an editor with Revert and Apply…, and after a
// change Put Back… with the same in a terminal), and every data profile in a disclosure group. ModemController
// (ModemController.swift) holds the state, reads the shown screen and runs one call at a time; the rows, questions and
// sentences come from ModemSettings.swift and ImeiHistory.swift. Apply…, the profile's Put Back…, the Unlock sheet's
// Unlock… and the IMEI sheet's Change… ask first, with words taken when their confirmation opens
// (ModemViewParts.swift). Refresh is in the toolbar; the result of a change shows in the banner at the bottom.
//
// Nothing here logs, prints or stores what is typed. The PIN is only in this screen's own state and is cleared as
// soon as its confirmation is confirmed or cancelled, the Unlock sheet closes, the SIM no longer asks for it or the
// screen goes; the profile's password is only in the controller's form and is shown as dots. An IMEI change is
// recorded in the IMEI history by the controller, never by this screen.
import SwiftUI

private enum SettingsAction {
    case apply
    case putBack
    case pin(attempts: Int)   // the attempts left the confirmation showed (ruling R13)
    case imei(String, reboot: Bool, expect: ImeiExpectation)   // written only on that module over that IMEI
    case simSlot(Int)
}

private let slotNoteTime: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
}()

private func typeLabel(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "IPv4"
    case .ipv6: return "IPv6"
    case .ipv4v6: return "IPv4v6"
    }
}

private func authLabel(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "None"
    case .pap: return "PAP"
    case .chap: return "CHAP"
    case .papOrChap: return "PAP or CHAP"
    }
}

/// The SIM's state as its pill shows it: the SIM row's words (simStateWords) with a capital first letter (another
/// answer as the modem gave it), coloured by what it needs: ready green; a PIN, PIN2 or PUK2 asked for orange;
/// blocked or failed red; busy yellow; not inserted or another answer gray.
private func simPill(_ state: SimState) -> (state: ConnectionState, text: String) {
    let words = simStateWords(state)
    let text = words.prefix(1).uppercased() + words.dropFirst()
    switch state {
    case .ready: return (.connected, text)
    case .pin, .pin2, .puk2: return (.attention, text)
    case .puk, .failure: return (.error, text)
    case .busy: return (.connecting, text)
    case .notInserted: return (.down, text)
    case .other: return (.down, words)
    }
}

/// Attempts left as a row of dots, one for each attempt a SIM starts with (3 for the PIN, 10 for the PUK), those left
/// filled (orange at the last one; every dot when the SIM reports more), then the count; "—" when not read. VoiceOver
/// reads "3 of 3 PIN attempts left".
private struct AttemptDots: View {
    let code: String   // "PIN" or "PUK"
    let left: Int?
    let full: Int

    var body: some View {
        if let left {
            let total = max(full, left)
            let tint: Color = left == 1 ? .orange : .green
            HStack(spacing: Spacing.s) {
                HStack(spacing: 3) {
                    ForEach(0..<full, id: \.self) { i in
                        Circle()
                            .fill(i < left ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                            .frame(width: 7, height: 7)
                    }
                }
                Text(verbatim: left == 0 ? "none left" : "\(left) left")
                    .monospacedDigit()
                    .foregroundStyle(left == 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(code) attempts"))
            .accessibilityValue(Text(verbatim: "\(left) of \(total) \(code) attempts left"))
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: "\(code) attempts"))
                .accessibilityValue(Text("not known"))
        }
    }
}

/// The data profiles: id (the driver's marked), type, APN, authentication, user and whether a password
/// is set (never the password); "—" where a profile's settings were not read (the type then as
/// AT+CGDCONT? lists it).
private struct ProfilesTable: View {
    let profiles: [DataProfile]
    let driverProfile: Int

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                ForEach(["Profile", "Type", "APN", "Authentication", "User", "Password"], id: \.self) { title in
                    Text(verbatim: title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(profiles, id: \.id) { p in
                let driver = p.id == driverProfile
                GridRow {
                    cell(driver ? "\(p.id) (driver's)" : "\(p.id)", driver)
                    cell(p.settings.map { typeLabel($0.type) } ?? p.pdpType, driver)
                    cell(p.apn.isEmpty ? "(none)" : p.apn, driver)
                    cell(p.settings.map { authLabel($0.auth) } ?? "—", driver)
                    cell(p.settings.map { $0.user.isEmpty ? "none" : modemTextSafe($0.user) } ?? "—", driver)
                    cell(p.settings.map { $0.password.isEmpty ? "none" : "set" } ?? "—", driver)
                }
            }
        }
    }

    private func cell(_ text: String, _ driver: Bool) -> some View {
        Text(verbatim: text)
            .fontWeight(driver ? .semibold : .regular)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SimApnTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    // Switching SIM slots by itself (SimSlotWatch.swift): what it last did, and whether it is about to.
    @ObservedObject var simWatcher: SimSlotWatcher
    @State private var slotClicks = 0
    @State private var question: Question<SettingsAction>? = nil   // Apply…, Put Back…, a slot switch
    @State private var pinAsk: Question<SettingsAction>? = nil     // the Unlock sheet's Unlock…, shown over the sheet
    @State private var unlocking = false                          // the Unlock sheet is open
    @State private var pin = ""   // only here; cleared when the confirmation or the sheet closes, or the screen goes
    // The last-attempt checkbox (ruling R20): unticked each time it appears, and when the confirmation closes
    // (after every Unlock… or cancel), the sheet closes or the screen goes.
    @State private var lastAttempt = false
    @State private var allProfilesShown = false
    @State private var editingImei = false
    @State private var draftImei = ""
    @State private var rebootImei = true
    @State private var imeiBack: ImeiHistoryEntry? = nil       // the history's change that Change Back… undoes
    @State private var imeiAsk: Question<SettingsAction>? = nil

    private static let blockedSentence = "The SIM is blocked: it needs its PUK from the carrier, and RMNet does not enter PUKs."
    private static let applyWarning = "A wrong APN breaks the connection. Apply switches the radio off and on again "
        + "(a redial); the connection drops for about 10 to 30 seconds."
    /// How far a grouped form's section titles are from its edge, so that the read line above it lines up with them.
    private static let formTitleInset: CGFloat = 30

    /// A settings read has finished (succeeded or not), so the driver's profile number is known.
    private var settingsRead: Bool { controller.settingsAt != nil || controller.settingsFailure != nil }

    /// The driver's profile's settings in the last read.
    private var listedSettings: ProfileSettings? {
        controller.profiles.first(where: { $0.id == controller.profileID })?.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the form, so it stays in view while the form scrolls.
            readLine
            Divider()
            Form {
                simSection
                modemSection
                imeiHistorySection
                profileSection
                allProfilesSection
            }
            .formStyle(.grouped)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!controller.refreshEnabled)
                .help("Read the SIM and the data profiles again")
            }
        }
        .resultBanner(controller.result, kind: controller.resultKind, dismiss: controller.dismissResult,
                      hover: controller.hoverResult)
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: clearPin))
        .sheet(isPresented: $unlocking, onDismiss: unlockClosed) {
            UnlockSheet(controller: controller, pin: $pin, lastAttempt: $lastAttempt, unlock: askPin,
                        cancel: { unlocking = false })
                .modifier(Confirmation(question: $pinAsk, controller: controller, perform: perform, closed: clearPin))
        }
        .sheet(isPresented: $editingImei, onDismiss: imeiSheetClosed) {
            ImeiSheet(controller: controller, draft: $draftImei, rebootNow: $rebootImei, back: imeiBack,
                      askChange: askImeiChange, cancel: { editingImei = false })
                .modifier(Confirmation(question: $imeiAsk, controller: controller, perform: perform, closed: {}))
        }
        .onChange(of: controller.sim?.state == .pin) { _, asks in
            if !asks {
                clearPin()
                unlocking = false
            }
        }
        .onDisappear {
            clearPin()
            unlocking = false
        }
    }

    // MARK: The read

    /// When the SIM and the profiles were read (readStatusLine), orange with its sentence after a read that failed.
    private var readLine: some View {
        let failed = controller.settingsFailure != nil
        return Label {
            Text(verbatim: readStatusLine(at: controller.settingsAt, failure: controller.settingsFailure,
                                          valuesShown: controller.sim != nil || !controller.profiles.isEmpty,
                                          reading: "Reading the SIM and the data profiles…"))
                .textSelection(.enabled)
        } icon: {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if settingsRead {
                Image(systemName: "clock")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(failed ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SimApnTab.formTitleInset)
        .padding(.vertical, Spacing.s + 2)
    }

    // MARK: SIM

    @ViewBuilder private var simSection: some View {
        Section("SIM") {
            if let sim = controller.sim {
                let pill = simPill(sim.state)
                LabeledContent("Status") {
                    HStack(spacing: Spacing.s) {
                        StatusPill(state: pill.state, text: pill.text)
                        if sim.state == .pin, let attempts = sim.pinAttempts, attempts >= 1 {
                            Button("Unlock…") { openUnlock() }
                                .disabled(!controller.pinEnabled)
                        }
                    }
                }
                if sim.state == .puk {
                    warning(SimApnTab.blockedSentence)
                } else if sim.state == .pin, sim.pinAttempts == nil {
                    warning("The attempts left could not be read; RMNet does not send a PIN without them.")
                } else if sim.state == .pin, let attempts = sim.pinAttempts, attempts < 1 {
                    warning(pinQuestion(attempts: 0).message)
                }
                LabeledContent("Slot") {
                    if let slot = sim.activeSlot {
                        // The modem's slot as read: a click asks first, and the control moves when a read says so.
                        Picker("Slot", selection: Binding(get: { slot }, set: { askSlot(from: slot, to: $0) })) {
                            ForEach(simSlots, id: \.self) { Text(verbatim: "SIM \($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .id(slotClicks)
                        .disabled(!controller.refreshEnabled)
                    } else {
                        Text(verbatim: "—").foregroundStyle(.secondary)
                    }
                }
                if let next = simWatcher.aboutToTry, simUnusable(sim.state) {
                    slotNote("No SIM in slot \(next.empty); trying SIM \(next.other) shortly.", symbol: "clock")
                } else if let line = simWatcher.line {
                    slotNote(line, symbol: "arrow.triangle.swap", at: simWatcher.lineAt)
                }
                LabeledContent("PIN lock", value: sim.pinLock.map { $0 ? "On" : "Off" } ?? "—")
                LabeledContent("PIN attempts") {
                    AttemptDots(code: "PIN", left: sim.pinAttempts, full: 3)
                }
                LabeledContent("PUK attempts") {
                    AttemptDots(code: "PUK", left: sim.pukAttempts, full: 10)
                }
            } else {
                note(settingsRead ? "The SIM has not been read." : "Reading the SIM…")
            }
        }
    }

    /// What the SIM slot watcher did or is about to do, with when.
    private func slotNote(_ text: String, symbol: String, at: Date? = nil) -> some View {
        Label {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(verbatim: text)
                if let at {
                    Text(verbatim: slotNoteTime.string(from: at))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func askSlot(from: Int, to: Int) {
        slotClicks += 1
        guard to != from, controller.refreshEnabled else { return }
        let q = simSlotQuestion(from: from, to: to)
        ask(Question(action: .simSlot(to), title: q.title, message: q.message, confirm: "Switch to SIM \(to)"))
    }

    private func openUnlock() {
        guard controller.pinEnabled else { return }
        clearPin()
        pinAsk = nil
        unlocking = true
    }

    /// The sheet's Unlock…: the PIN question, with the attempts left now.
    private func askPin() {
        guard controller.pinEnabled, let attempts = controller.sim?.pinAttempts,
              unlockAllowed(pin: pin, attempts: attempts, lastAttemptTicked: lastAttempt) else { return }
        let q = pinQuestion(attempts: attempts)
        pinAsk = Question(action: .pin(attempts: attempts), title: q.title, message: q.message, confirm: "Send PIN",
                          destructive: attempts == 1, cancelIsDefault: true)
        controller.setConfirming(true)
    }

    /// However the sheet closed: the PIN cleared, and a question still open over it closed (reads go on).
    private func unlockClosed() {
        clearPin()
        if pinAsk != nil {
            pinAsk = nil
            controller.setConfirming(false)
        }
    }

    private func clearPin() {
        pin = ""
        lastAttempt = false
    }

    // MARK: Modem (IMEI) and its history

    /// The IMEI (selectable) with Change…, and the module's USB serial number, which tells modules apart in the history.
    @ViewBuilder private var modemSection: some View {
        Section("Modem") {
            LabeledContent("IMEI") {
                HStack(spacing: Spacing.m) {
                    Text(verbatim: controller.imei ?? "—")
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                        .foregroundStyle(controller.imei == nil ? .secondary : .primary)
                    Button("Change…") { openImeiSheet(back: nil) }
                        .disabled(!controller.refreshEnabled || controller.imei == nil)
                        .accessibilityLabel(Text("Change the IMEI…"))
                }
            }
            if let failure = controller.imeiFailure {
                warning(failure)
            } else if controller.imei == nil {
                note(settingsRead ? "The IMEI has not been read." : "Reading the IMEI…")
            }
            LabeledContent("Serial number") {
                Text(verbatim: controller.moduleSerial ?? "—")
                    .font(.body.monospacedDigit())
                    .textSelection(.enabled)
                    .foregroundStyle(controller.moduleSerial == nil ? .secondary : .primary)
            }
            .help("The module's USB serial number. Changing the IMEI does not change it, so the IMEI history uses it to "
                  + "tell modules apart.")
        }
    }

    /// Every IMEI change recorded on this Mac, newest first: the change, when, where it came from and on which module,
    /// whether it succeeded (and RMNet's sentence), with Change Back… where the IMEI before can be set again.
    @ViewBuilder private var imeiHistorySection: some View {
        let rows = controller.imeiHistory.map {
            imeiHistoryRows($0, currentImei: controller.imei, currentModule: controller.moduleSerial)
        } ?? []
        Section {
            if let failure = controller.imeiHistoryFailure {
                warning(failure)
            } else if controller.imeiHistory == nil {
                note(settingsRead ? "The IMEI history has not been read." : "Reading the IMEI history…")
            } else if rows.isEmpty {
                note("No IMEI changes recorded on this Mac yet.")
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ImeiHistoryRowView(row: row, changeBackEnabled: controller.refreshEnabled && controller.imei != nil,
                                   changeBack: { openImeiSheet(back: row.entry) })
            }
            if let skipped = controller.imeiHistory?.skippedLines, skipped > 0 {
                warning("\(skipped) line\(skipped == 1 ? "" : "s") of the history could not be read.")
            }
        } header: {
            HStack {
                Text("IMEI history")
                Spacer()
                if !rows.isEmpty {
                    Text(verbatim: "\(rows.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("IMEI changes recorded on this Mac, newest first (RMNet imei history prints the same). Kept in "
                 + "~/Library/Application Support/RMNet/imei-history.jsonl.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The IMEI sheet, empty (Change…) or filled with the IMEI before a change of the history (Change Back…).
    private func openImeiSheet(back: ImeiHistoryEntry?) {
        guard controller.refreshEnabled else { return }
        imeiBack = back
        draftImei = back?.before ?? ""
        rebootImei = true
        imeiAsk = nil
        editingImei = true
    }

    /// The question names the IMEI and the module shown; the change is written only on that module over that IMEI (for
    /// Change Back…, the module its entry was recorded on), so a modem swapped or changed after the question is left
    /// as it is.
    private func askImeiChange() {
        guard imeiProblem(draftImei) == nil, let before = controller.imei,
              let module = imeiBack?.module ?? controller.moduleSerial else { return }
        let q = imeiQuestion(before: before, after: draftImei, reboot: rebootImei, module: module)
        imeiAsk = Question(action: .imei(draftImei, reboot: rebootImei,
                                         expect: ImeiExpectation(module: module, before: before)),
                           title: q.title, message: q.message,
                           confirm: "Change IMEI", destructive: rebootImei, cancelIsDefault: true)
        controller.setConfirming(true)
    }

    private func imeiSheetClosed() {
        draftImei = ""
        imeiBack = nil
        if imeiAsk != nil {
            imeiAsk = nil
            controller.setConfirming(false)
        }
    }

    // MARK: The driver's profile

    /// A binding to one field of the controller's form (the editor is shown only while there is one).
    private func field<T>(_ key: WritableKeyPath<ProfileSettings, T>, _ empty: T) -> Binding<T> {
        Binding(get: { controller.form?[keyPath: key] ?? empty },
                set: { controller.form?[keyPath: key] = $0 })
    }

    /// Why there is no form for the driver's profile.
    private var noFormSentence: String {
        let id = controller.profileID
        if !settingsRead { return "Reading the settings of profile \(id)…" }
        if controller.profiles.isEmpty { return "The settings of profile \(id) have not been read." }
        guard controller.profiles.contains(where: { $0.id == id }) else { return "The modem does not list profile \(id)." }
        return profileNumberProblem(id) ?? "The settings of profile \(id) could not be read."
    }

    @ViewBuilder private var profileSection: some View {
        Section {
            if settingsRead {
                note(controller.driverAttached
                     ? "The driver dials profile \(controller.profileID)."
                     : "The driver is not attached; it dials profile 1 unless set otherwise.")
            }
            if let form = controller.form {
                Group {
                    TextField("APN", text: field(\.apn, ""), prompt: Text("none: the network chooses"))
                    Picker("IP type", selection: field(\.type, .ipv4v6)) {
                        ForEach(PdpType.allCases, id: \.self) { Text(verbatim: typeLabel($0)).tag($0) }
                    }
                    Picker("Authentication", selection: field(\.auth, .none)) {
                        ForEach(AuthMethod.allCases, id: \.self) { Text(verbatim: authLabel($0)).tag($0) }
                    }
                    TextField("User", text: field(\.user, ""), prompt: Text("none"))
                    SecureField("Password", text: field(\.password, ""), prompt: Text("none"))
                }
                .autocorrectionDisabled()
                .disabled(!controller.refreshEnabled)
                if let problem = profileProblem(controller.profileID, form) {
                    Label {
                        Text(verbatim: problem)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Revert") { controller.revertForm() }
                        .disabled(!controller.formEdited || !controller.refreshEnabled)
                    Button("Apply…") { askApply() }
                        .disabled(!controller.applyEnabled)
                }
            } else {
                note(noFormSentence)
            }
            if case .profile(let id, let before)? = controller.undo {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Before the last change, profile \(id) was \(profileWords(before)).")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Put Back…") { askPutBack() }
                        .disabled(!controller.refreshEnabled)
                }
                if let command = controller.undoCommand { PutBackCommand(command: command) }
            }
        } header: {
            Text("Data profile")
        } footer: {
            if controller.form != nil {
                Text(verbatim: SimApnTab.applyWarning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func askApply() {
        guard controller.applyEnabled, let form = controller.form else { return }
        let q = profileQuestion(id: controller.profileID, before: listedSettings, after: form)
        ask(Question(action: .apply, title: q.title, message: q.message, confirm: "Apply"))
    }

    private func askPutBack() {
        guard case .profile(let id, let before)? = controller.undo else { return }
        let now = controller.profiles.first(where: { $0.id == id })?.settings
        let q = profileQuestion(id: id, before: now, after: before)
        ask(Question(action: .putBack, title: "Put profile \(id) back?", message: q.message, confirm: "Put Back"))
    }

    // MARK: All profiles

    private var allProfilesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $allProfilesShown) {
                if !controller.profiles.isEmpty {
                    ProfilesTable(profiles: controller.profiles, driverProfile: controller.profileID)
                        .padding(.vertical, Spacing.xs)
                } else {
                    note(settingsRead ? "The data profiles have not been read." : "Reading the data profiles…")
                }
            } label: {
                LabeledContent("All profiles") {
                    if !controller.profiles.isEmpty {
                        Text(verbatim: "\(controller.profiles.count)")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Confirmations

    private func ask(_ q: Question<SettingsAction>) {
        question = q
        controller.setConfirming(true)
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .apply: controller.applyProfile()
        case .putBack: controller.putBack()
        case .pin(let attempts):
            controller.enterPin(pin, shownAttempts: attempts)
            unlocking = false
        case let .imei(newImei, reboot, expect):
            controller.changeImei(newImei, reboot: reboot, expect: expect)
            editingImei = false
        case .simSlot(let slot):
            simWatcher.switchedByHand()
            controller.changeSimSlot(slot)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// The sheet Unlock… opens while the SIM asks for its PIN: the PIN attempts left, the PIN field (dots), at the last
/// attempt the checkbox that must be ticked too (ruling R20), the PIN's rule when what is typed breaks it, Cancel, and
/// Unlock…, which asks the PIN question over the sheet (Cancel is its default button). The PIN and the checkbox are
/// the screen's state, passed in; nothing here keeps them.
private struct UnlockSheet: View {
    @ObservedObject var controller: ModemController
    @Binding var pin: String
    @Binding var lastAttempt: Bool
    let unlock: () -> Void
    let cancel: () -> Void

    var body: some View {
        let sim = controller.sim
        let attempts = sim?.state == .pin ? sim?.pinAttempts : nil
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Unlock the SIM")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if let sim, sim.state == .pin {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.m) {
                    GridRow {
                        Text("PIN attempts")
                            .foregroundStyle(.secondary)
                        AttemptDots(code: "PIN", left: sim.pinAttempts, full: 3)
                    }
                    if let attempts, attempts >= 1 {
                        GridRow {
                            Text("PIN")
                                .foregroundStyle(.secondary)
                            SecureField("PIN", text: $pin, prompt: Text("4 to 8 digits"))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .labelsHidden()
                                .disabled(!controller.pinEnabled)
                        }
                    }
                }
                if let attempts, attempts >= 1 {
                    if attempts == 1 {
                        // The last attempt needs this extra step, as `RMNet sim unlock` needs --last-attempt (R20).
                        Toggle(isOn: $lastAttempt) {
                            Text(verbatim: lastAttemptChoice)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!controller.pinEnabled)
                        .onAppear { lastAttempt = false }
                    }
                    if !pin.isEmpty, let problem = pinProblem(pin) {
                        Text(verbatim: problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } else if sim.pinAttempts == nil {
                    sentence("The attempts left could not be read; RMNet does not send a PIN without them.")
                } else {
                    sentence(pinQuestion(attempts: 0).message)
                }
            } else {
                sentence("The SIM does not ask for its PIN now.")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Unlock…", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.pinEnabled
                              || !unlockAllowed(pin: pin, attempts: attempts ?? 0, lastAttemptTicked: lastAttempt))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
    }

    private func sentence(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One change of the IMEI history: a green check or a red cross, the IMEIs before and after, when (in full as its
/// tooltip), where it came from and on which module, RMNet's sentence or the note of a change recorded afterwards, and
/// Change Back… where it is offered (imeiHistoryRows).
private struct ImeiHistoryRowView: View {
    let row: ImeiHistoryRow
    let changeBackEnabled: Bool
    let changeBack: () -> Void

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        let e = row.entry
        let ok = e.result == .succeeded
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
                .accessibilityLabel(Text(ok ? "Succeeded" : "Failed"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(verbatim: e.before ?? "unknown")
                        .foregroundStyle(e.before == nil ? .secondary : .primary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("to"))
                    Text(verbatim: e.after)
                }
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
                Text(verbatim: details(e))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(ImeiHistoryRowView.full.string(from: e.time))
                ForEach([e.note, e.message].compactMap { $0 }.filter { !$0.isEmpty }, id: \.self) { text in
                    Text(verbatim: text)
                        .font(.caption)
                        .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.s)
            if row.canChangeBack {
                Button("Change Back…", action: changeBack)
                    .disabled(!changeBackEnabled)
                    .help("Open Change IMEI with \(e.before ?? ""), the IMEI before this change")
            }
        }
        .padding(.vertical, 2)
    }

    /// "Today at 02:57 · Another tool · Module a1b2c3d4 (another module)".
    private func details(_ e: ImeiHistoryEntry) -> String {
        var parts = [ImeiHistoryRowView.when.string(from: e.time), e.source.words]
        if e.restart == false && e.result == .succeeded { parts.append("takes effect at the next restart") }
        if let m = e.module { parts.append("Module \(m)" + (row.otherModule ? " (not the one attached)" : "")) }
        return parts.joined(separator: " · ")
    }
}

/// The sheet Change… (or a history row's Change Back…) opens: the IMEI now, the new one (15 digits; with 14 typed, a
/// button adds the check digit), the rule it breaks, whether the modem restarts now (`AT+CFUN=1,1`) or the IMEI waits
/// for the next restart, what that does to the connection, Cancel and Change…, which asks the IMEI question over the
/// sheet (Cancel is its default button). The new IMEI and the switch are the screen's state, passed in.
struct ImeiSheet: View {
    @ObservedObject var controller: ModemController
    @Binding var draft: String
    @Binding var rebootNow: Bool
    let back: ImeiHistoryEntry?
    let askChange: () -> Void
    let cancel: () -> Void

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var canSubmit: Bool {
        guard imeiProblem(draft) == nil, controller.imei != nil, controller.moduleSerial != nil else { return false }
        return draft != controller.imei
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(symbol: "barcode", title: back == nil ? "Change the IMEI" : "Change the IMEI back",
                        subtitle: back.map { "Back to the IMEI before the change of \(ImeiSheet.when.string(from: $0.time))." }
                            ?? "The modem keeps the new IMEI until it is changed again.")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.m) {
                GridRow {
                    Text("Now").foregroundStyle(.secondary)
                    Text(verbatim: controller.imei ?? "—")
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("New IMEI").foregroundStyle(.secondary)
                    HStack(spacing: Spacing.s) {
                        TextField("New IMEI", text: $draft, prompt: Text("15 digits"))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .autocorrectionDisabled()
                            .labelsHidden()
                        if draft.count == 14, let check = imeiCheckDigit(forFirst14: draft) {
                            Button("Add Check Digit \(check)") { draft.append(String(check)) }
                                .help("The 15th digit is a check digit (Luhn); for these 14 digits it is \(check).")
                        }
                    }
                }
            }
            if !draft.isEmpty, imeiCheckDigit(forFirst14: draft) == nil, let problem = imeiProblem(draft) {
                ProblemNote(text: problem)
            } else if !draft.isEmpty && draft == controller.imei {
                Text("This is the IMEI the modem has now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if controller.moduleSerial == nil {
                ProblemNote(text: "The modem's USB serial number is not known, so the change cannot be tied to this "
                            + "module. Refresh, then try again.")
            }
            Toggle("Restart the modem now", isOn: $rebootNow)
                .toggleStyle(.checkbox)
            WarningNote(text: rebootNow
                         ? "The modem restarts at once so that the network sees the new IMEI: the connection and the "
                            + "network port go away for about 30 seconds."
                         : "The new IMEI takes effect when the modem next restarts (a replug, or RMNet at AT+CFUN=1,1).")
            Text("The change is recorded in the IMEI history, also when it fails.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Change…", action: askChange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
    }
}
