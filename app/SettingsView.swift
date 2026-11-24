// The app's Settings window (the Settings scene of RMNetApp, StatusView.swift; Cmd-, or the gear in the menu bar
// item's panel): how the menu bar item draws itself, the antenna or the signal bars, and whether the bars show 5G or
// LTE beside them (kept by MenuBarStatus, MenuBarIconPreference); switching SIM slots by itself; and the notifications
// for new messages (AppSettings.swift). Kept in the user defaults and in effect at once.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var menuBar: MenuBarStatus
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Menu bar icon", selection: Binding(get: { menuBar.iconStyle },
                                                           set: { menuBar.setIconStyle($0) })) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        HStack(spacing: Spacing.s) {
                            preview(style)
                                .frame(width: 34, alignment: .center)
                            Text(verbatim: style.title)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Show 5G/LTE next to the bars", isOn: Binding(get: { menuBar.showsTechnology },
                                                                     set: { menuBar.setShowsTechnology($0) }))
                    .disabled(menuBar.iconStyle != .signal)
                    .help("Only with the signal bars: the technology in small type after them, as a phone shows it")
            } header: {
                Text("Menu bar")
            } footer: {
                Text(verbatim: footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Switch SIM slots automatically", isOn: $settings.simAutoSwitch)
            } header: {
                Text("SIM")
            } footer: {
                Text(verbatim: "When the slot in use has no usable SIM for about 25 seconds after the modem is plugged in, "
                     + "RMNet switches to the other slot, and back if that one has none either: once each time the "
                     + "modem is plugged in. The SIM & Data screen says what it did.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Notify about new messages", isOn: $settings.notifyMessages)
                Toggle("Unblock incoming messages automatically", isOn: $settings.smsAutoUnblock)
            } header: {
                Text("Messages")
            } footer: {
                Text(verbatim: "While RMNet runs, also with its window closed, it checks the modem's message count about "
                     + "every 30 seconds (one short command, skipped while another program uses the modem's AT port). "
                     + "A notification says only that new messages came in: reading one on the modem marks it read, so "
                     + "RMNet reads them only when Messages is opened.\n\n"
                     + "The modem cannot store an incoming MMS notification by itself, which holds up later text messages "
                     + "at the carrier. When RMNet sees that happen, it receives the waiting messages in short windows "
                     + "and stores them on the modem as unread (an MMS notification is saved as a note with its sender "
                     + "and time). With this turned off, Messages offers an Unblock button instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: String {
        switch menuBar.iconStyle {
        case .antenna:
            return "The antenna is struck through unless the connection is up. It never asks the modem anything."
        case .signal:
            return "The bars show the modem's signal like a phone's" + (menuBar.showsTechnology ? ", with 5G or LTE beside them. " : ". ")
                + "While RMNet runs they read the "
                + "signal every 15 seconds: one short command over the modem's AT port, skipped while another program "
                + "uses the port (the last bars stay, dimmed). A slash means no connection; an airplane, the radio is off."
        }
    }

    @ViewBuilder private func preview(_ style: MenuBarIconStyle) -> some View {
        switch style {
        case .antenna:
            Image(systemName: "antenna.radiowaves.left.and.right")
        case .signal:
            Image(nsImage: menuBarSignalImage(MenuBarSignalIcon(bars: .filled(3), text: menuBar.showsTechnology ? "5G" : nil,
                                                                accessibilityLabel: "")))
                .accessibilityHidden(true)
        }
    }
}
