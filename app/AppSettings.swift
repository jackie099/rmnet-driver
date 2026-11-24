// The app's settings besides the menu bar icon's (MenuBarIconPreference, MenuBarStatus.swift), each on until it is
// turned off in the Settings window (SettingsView.swift): switching SIM slots by itself (SimSlotWatch.swift),
// notifying about new text messages (MessageAlerts.swift) and unblocking incoming text messages when an MMS
// notification holds up the queue (SmsController.swift). Kept in the app's user defaults; a change is in effect at
// once. Foundation only, so `make app-test` tests it.
import Combine
import Foundation

final class AppSettings: ObservableObject {
    static let simAutoSwitchKey = "simAutoSwitch"
    static let notifyMessagesKey = "notifyNewMessages"
    static let smsAutoUnblockKey = "smsAutoUnblock"

    private let defaults: UserDefaults

    /// Switch SIM slots automatically: when the slot in use has no usable SIM, try the other one once a modem attach.
    @Published var simAutoSwitch: Bool { didSet { defaults.set(simAutoSwitch, forKey: AppSettings.simAutoSwitchKey) } }
    /// Notify about new messages: count them while RMNet runs (without reading them), and say when more came in.
    @Published var notifyMessages: Bool { didSet { defaults.set(notifyMessages, forKey: AppSettings.notifyMessagesKey) } }
    /// Unblock incoming messages automatically: when the modem cannot store an MMS notification, stream the queued
    /// messages in short windows and write each back to the modem's store as unread.
    @Published var smsAutoUnblock: Bool { didSet { defaults.set(smsAutoUnblock, forKey: AppSettings.smsAutoUnblockKey) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func on(_ key: String) -> Bool { (defaults.object(forKey: key) as? Bool) ?? true }
        simAutoSwitch = on(AppSettings.simAutoSwitchKey)
        notifyMessages = on(AppSettings.notifyMessagesKey)
        smsAutoUnblock = on(AppSettings.smsAutoUnblockKey)
    }
}
