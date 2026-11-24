// The window's Driver screen, a settings-style form: the driver's status (the headline's pill, with a badge when this
// app carries an update; the version installed and the one this app carries, whether it is enabled, the modem and its
// USB mode), what to do under "Install and remove" (the advice, or what this app carries beside the buttons; Install
// or Update and Remove…, and System Settings while the driver waits for approval; the caution under them), and, on
// request, the details: the system's entries for the extension and the driver's own properties. Refreshed every 2 seconds while it
// is shown and the window can be seen (the window's poll, WindowPolls in ShellModel.swift). StatusController
// (StatusView.swift; the app delegate's driverStatus) holds the status and runs the requests; the headline, the advice
// and the progress and result words come from StatusModel.swift and the controller unchanged.
import AppKit
import SwiftUI

/// System Settings' Login Items & Extensions pane, where the owner turns a new driver on.
private let extensionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

struct StatusView: View {
    // The process's one controller, owned by the app delegate and shared with the Overview.
    @ObservedObject var controller: StatusController
    @State private var confirmingRemove = false
    @State private var showsDetails = false

    private var headlineText: String {
        switch controller.listing {
        case .asking: return "Asking the system…"
        case .known: return headline(controller.status)
        case .unknown: return unknownHeadline
        }
    }

    // The confirmation's text: what disappears, the password, and the install-first step if any.
    private var removeMessage: String {
        var text = "The Mac's network port for the modem will disappear. macOS will ask for an administrator password."
        if controller.plan == .activateThenDeactivate {
            let listed = controller.status.entries.map { $0.version }.joined(separator: ", ")
            text += " First this app installs version \(controller.bundledVersion) in place of version \(listed), so that it can remove it."
        }
        return text
    }

    /// The one listed entry waits for the owner to turn it on in System Settings (the headline says so).
    private var waitingForApproval: Bool {
        let entries = controller.status.entries
        return controller.known && entries.count == 1 && entries[0].awaitingApproval && !entries[0].uninstalling
    }

    var body: some View {
        let status = controller.status
        let pill = connectionPill(headlineText)
        // advice()'s last line is the warning about System Settings, except while the system removes every listed
        // entry, when it is removalUnderWayLine: the warning goes under the buttons, the rest above them.
        let lines = controller.known ? advice(status, bundledVersion: controller.bundledVersion) : []
        let warning = lines.last.flatMap { $0 == removalUnderWayLine ? nil : $0 }
        let guidance = warning == nil ? lines : Array(lines.dropLast())
        let updateReady = controller.installEnabled && controller.installButtonTitle == "Update"
        Form {
            Section {
                DriverHeadline(state: pill.state, text: pill.text, updateReady: updateReady)
                if case .unknown(let why) = controller.listing {
                    ProblemNote(text: why)
                        .textSelection(.enabled)
                }
                LabeledContent("Installed version") { ValueText(installedText(status)) }
                LabeledContent("Version in this app") {
                    ValueText(controller.bundledVersion.isEmpty ? "—" : controller.bundledVersion)
                }
                LabeledContent("Enabled") { ValueText(enabledText(status)) }
                LabeledContent("Modem") { ValueText(modemText(status)) }
                LabeledContent("USB mode") { UsbModeText(modem: status.modem) }
            } header: {
                Text("Status")
            }

            Section {
                if !guidance.isEmpty {
                    AdviceLines(lines: guidance, attention: pill.state == .attention || pill.state == .error)
                }
                // With no advice above them, the buttons have what this app carries beside them.
                actions(note: guidance.isEmpty && controller.known
                        ? driverActionNote(status, bundledVersion: controller.bundledVersion) : nil)
            } header: {
                Text("Install and remove")
            } footer: {
                if let warning {
                    WarningNote(text: warning)
                }
            }

            Section {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        EntriesTable(entries: controller.known ? status.entries : nil)
                        Divider()
                        PropertiesList(properties: status.properties, attached: status.attached)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.s)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the driver's status again")
            }
        }
        // The request's words while it runs, then its result (ResultLine.swift), as on the other screens.
        .resultBanner(controller.progress, kind: controller.progressKind, dismiss: controller.dismissResult,
                      hover: controller.hoverResult)
        .confirmationDialog("Remove the RMNet driver?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { controller.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }

    /// Open System Settings while the driver waits for approval (then the one to press), Install or Update (the one
    /// to press when nothing waits for approval and the title is one of those two), and Remove…; `note` before them.
    private func actions(note: String?) -> some View {
        let title = controller.installButtonTitle
        let installIsNext = !waitingForApproval && (title == "Install" || title == "Update")
        return HStack(spacing: Spacing.s) {
            if let note {
                Text(verbatim: note)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.s)
            if waitingForApproval {
                Button("Open System Settings") {
                    if let url = extensionsSettingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            if installIsNext {
                Button(title) { controller.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.installEnabled)
            } else {
                Button(title) { controller.install() }
                    .disabled(!controller.installEnabled)
            }
            Button("Remove…") {
                // With nothing it can send, Remove only says which app can.
                if controller.plan == .cannot { controller.remove() } else { confirmingRemove = true }
            }
            .disabled(!controller.removeEnabled)
        }
    }

    /// The versions the system lists; "—" while its listing is not known.
    private func installedText(_ status: DriverStatus) -> String {
        guard controller.known else { return "—" }
        if status.entries.isEmpty { return "None" }
        return status.entries.map { $0.version }.joined(separator: ", ")
    }

    /// Whether the listed entry is enabled (each version's when there are several); "—" with none or no listing.
    private func enabledText(_ status: DriverStatus) -> String {
        guard controller.known, !status.entries.isEmpty else { return "—" }
        if status.entries.count == 1 { return status.entries[0].enabled ? "Yes" : "No" }
        return status.entries.map { "\($0.version): \($0.enabled ? "yes" : "no")" }.joined(separator: ", ")
    }

    /// The modem found on USB by its model's names (untested models say so), or that none is attached.
    private func modemText(_ status: DriverStatus) -> String {
        if case .absent = status.modem { return "Not attached" }
        return status.modemModel.map { $0.names + ($0.tested ? "" : " (untested)") } ?? "Attached"
    }
}

/// The status section's first row: the driver's tile and name, and the headline's pill in connectionPill's words, as
/// the sidebar, the Overview and the menu bar show it ("Not connected", not the headline's "Link down"). The longer
/// headlines add nothing the screen does not say: "Waiting for approval in System Settings" has the advice right under
/// it, which names the pane, and Open System Settings.
private struct DriverHeadline: View {
    let state: ConnectionState
    let text: String
    var updateReady = false   // this app carries a newer version, which Update installs

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("RMNet driver")
                    .font(.headline)
                StatusPill(state: state, text: text)
            }
            Spacer(minLength: 0)
            if updateReady {
                StateBadge(text: "Update available", symbol: "arrow.down.circle.fill", tint: .blue)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// A status value: monospaced digits, selectable.
private struct ValueText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .monospacedDigit()
            .textSelection(.enabled)
    }
}

/// The modem's USB mode: QMI, not QMI (orange: the driver cannot use it), or "—" with no modem attached.
private struct UsbModeText: View {
    let modem: ModemState

    var body: some View {
        switch modem {
        case .absent:
            Text(verbatim: "—")
        case .qmi:
            Text("QMI")
        case .notQMI:
            Label("Not QMI", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// The advice above the buttons, as StatusModel.swift words it: sentences in the body font, the commands to type
/// (RMNet usbmode, RMNet at, the AT commands) in a fixed-width font on a light panel; selectable. Orange when the
/// headline asks for something to be done.
private struct AdviceLines: View {
    let lines: [String]
    let attention: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(attention ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(lines, id: \.self) { line in
                    if line.hasPrefix("AT+") || line == usbModeQmiCommand || atFallbackCommands.contains(line) {
                        Text(verbatim: line)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
                    } else {
                        Text(verbatim: line)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The system's entries for the driver extension, one row each: version, enabled, awaiting approval, uninstalling.
/// nil: the system's listing is not known.
private struct EntriesTable: View {
    let entries: [ExtensionEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            CardSectionHeading("Extension entries", note: "As the system lists them")
            if let entries, !entries.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                    GridRow {
                        ForEach(["Version", "Enabled", "Awaiting approval", "Uninstalling"], id: \.self) { title in
                            Text(verbatim: title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Text(verbatim: entry.version)
                                .monospacedDigit()
                                .textSelection(.enabled)
                            Text(verbatim: entry.enabled ? "Yes" : "No")
                            Text(verbatim: entry.awaitingApproval ? "Yes" : "No")
                            Text(verbatim: entry.uninstalling ? "Yes" : "No")
                        }
                    }
                }
            } else {
                Text(verbatim: entries == nil ? "Not known: the system has not listed the driver." : "None listed.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The driver's RMNet* registry properties, name and value: its state, addresses and profile first, then the others
/// by name, leaving out those at 0 (as the window's old table did, tableRows); nothing while the driver is not
/// attached.
private struct PropertiesList: View {
    let properties: [String: String]
    let attached: Bool

    var body: some View {
        let first = fixedProperties.filter { properties[$0] != nil }
        let rest = properties.keys.sorted().filter { !fixedProperties.contains($0) && properties[$0] != "0" }
        let atZero = properties.count - first.count - rest.count
        VStack(alignment: .leading, spacing: Spacing.s) {
            CardSectionHeading("Driver properties", note: "RMNet* in the I/O registry")
            if !attached {
                Text("None: the driver is not attached to the modem.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                    ForEach(first + rest, id: \.self) { name in
                        GridRow {
                            Text(verbatim: name)
                                .foregroundStyle(.secondary)
                            Text(verbatim: properties[name] ?? "")
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                    }
                }
                if atZero > 0 {
                    Text(verbatim: atZero == 1 ? "1 property at 0 is not listed."
                                                : "\(atZero) properties at 0 are not listed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
