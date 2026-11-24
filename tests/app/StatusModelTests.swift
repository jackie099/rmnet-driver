// Tests for app/StatusModel.swift: the headline, the advice, canRemoveDirectly, the removal texts,
// the install confirmation, the table rows, the JSON form, the Quectel model list, which interface is a
// model's QMI interface, and the status verb's modem line. Built with swiftc by `make app-test`; needs no
// Xcode project and no hardware.
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

let enabled = ExtensionEntry(version: "316.19.56", enabled: true, awaitingApproval: false, uninstalling: false)
let attached4 = ModemState.qmi(interface: 4)

func status(_ entries: [ExtensionEntry], _ modem: ModemState = attached4, model: QuectelModel? = nil,
            attached: Bool = false, _ properties: [String: String] = [:]) -> DriverStatus {
    DriverStatus(entries: entries, modem: modem, modemModel: model, attached: attached, properties: properties)
}

// The QMI-mode lines of the advice, word for word: for the RM520N-GL (the verb first, the two AT
// commands sent with `RMNet at` as the fallback) and for any other model or none known (the two AT
// commands, from software that talks to the modem over USB or from another computer where the AT port is a
// serial device, a replug in place of the second, and why not RMNet's verbs: macOS gives the AT ports no serial
// device, and RMNet's AT port does not open those models).
let rm520NotQMILines = [
    "The modem is attached but not in QMI mode. Run this command in Terminal, answer y when it asks before restarting the modem, and wait for the modem to come back (RMNet is /Applications/RMNet.app/Contents/MacOS/RMNet):",
    "RMNet usbmode set qmi",
    "Or send the two AT commands with RMNet at, then wait for the modem to come back; unplugging it and plugging it in again does the same as the second:",
    "RMNet at 'AT+QCFG=\"usbnet\",0'",
    "RMNet at AT+CFUN=1,1",
]
let otherNotQMILines = [
    "The modem is attached but not in QMI mode. Send it these two AT commands from software that talks to the modem over USB, or from another computer (Linux or Windows) where its AT port is a serial device, then wait for it to come back (macOS gives the AT ports no serial device, and RMNet at and RMNet usbmode work only with the RM520N-GL):",
    "AT+QCFG=\"usbnet\",0",
    "AT+CFUN=1,1",
    "(or unplug and replug the modem instead of AT+CFUN=1,1)",
]

func expectHeadline(_ s: DriverStatus, _ want: String, _ name: String) {
    let got = headline(s)
    check(got == want, "headline: \(name)", "want \"\(want)\", got \"\(got)\"")
}

let alwaysLine = "Do not switch the driver off in System Settings while the modem is attached. Use Remove here."

@main
struct StatusModelTests {
    static func main() {
        // --- headline: one check per value ---------------------------------------------------
        expectHeadline(status([]), "Not installed", "no entry")
        expectHeadline(status([ExtensionEntry(version: "1", enabled: false, awaitingApproval: true, uninstalling: false)]),
                       "Waiting for approval in System Settings", "awaiting approval")
        expectHeadline(status([enabled], .absent), "Installed, modem not attached", "modem absent")
        expectHeadline(status([enabled], .notQMI), "Modem is not in QMI mode", "modem not in QMI mode")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "starting"]), "Connecting", "state starting")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "up"]), "Connected", "state up")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "usb failed"]), "Link down", "state usb failed")
        expectHeadline(status([enabled, ExtensionEntry(version: "316.20.1", enabled: true, awaitingApproval: false, uninstalling: false)]),
                       "Needs attention", "two entries")

        // --- headline: the other mapped inputs ------------------------------------------------
        expectHeadline(status([ExtensionEntry(version: "1", enabled: false, awaitingApproval: false, uninstalling: false)]),
                       "Needs attention", "installed, not enabled")
        expectHeadline(status([ExtensionEntry(version: "1", enabled: true, awaitingApproval: false, uninstalling: true)]),
                       "Needs attention", "uninstalling")
        expectHeadline(status([enabled], attached: false), "Connecting", "QMI modem, driver not attached yet")
        expectHeadline(status([enabled], attached: true), "Connecting", "attached, no state published yet")
        for s in ["idle", "syncing", "configuring", "connecting"] {
            expectHeadline(status([enabled], attached: true, ["RMNetState": s]), "Connecting", "state \(s)")
        }
        expectHeadline(status([enabled], attached: true, ["RMNetState": "refreshing"]), "Connected", "state refreshing")
        for s in ["backoff", "detached", "something new"] {
            expectHeadline(status([enabled], attached: true, ["RMNetState": s]), "Link down", "state \(s)")
        }
        expectHeadline(status([enabled], .absent, attached: true, ["RMNetState": "up"]), "Connected",
                       "attached wins over a stale modem reading")

        // --- advice ----------------------------------------------------------------------------
        let plain = advice(status([enabled], attached: true, ["RMNetState": "up"]), bundledVersion: "316.19.56")
        check(plain == [alwaysLine], "advice: connected, same version gives only the standing line", "\(plain)")

        let notQMI = advice(status([enabled], .notQMI), bundledVersion: "316.19.56")
        check(notQMI.contains("AT+QCFG=\"usbnet\",0"), "advice: notQMI names AT+QCFG=\"usbnet\",0", "\(notQMI)")
        check(notQMI.contains("AT+CFUN=1,1"), "advice: notQMI names AT+CFUN=1,1", "\(notQMI)")
        check(notQMI.last == alwaysLine, "advice: notQMI ends with the standing line", "\(notQMI)")
        check(notQMI == otherNotQMILines + [alwaysLine], "advice: notQMI, model not known, gives the two AT commands only",
              "\(notQMI)")

        // The RM520N-GL (2c7c:0801, the one product the app's AT port opens): `RMNet usbmode set qmi`
        // first, then the two AT commands, sent with `RMNet at`, as the fallback.
        let rm520Model = quectelModel(product: 0x0801)
        let rm520NotQMI = advice(status([enabled], .notQMI, model: rm520Model), bundledVersion: "316.19.56")
        check(rm520NotQMI == rm520NotQMILines + [alwaysLine],
              "advice: an RM520N-GL not in QMI mode leads with RMNet usbmode set qmi, RMNet at as the fallback",
              "\(rm520NotQMI)")
        check(atFallbackCommands == ["RMNet at 'AT+QCFG=\"usbnet\",0'", "RMNet at AT+CFUN=1,1"]
                && rm520NotQMI.filter({ atFallbackCommands.contains($0) }) == atFallbackCommands,
              "advice: the RM520N-GL's fallback lines are atFallbackCommands (the window shows them fixed-width)",
              "\(atFallbackCommands)")
        check(!rm520NotQMI.contains { $0.contains("no general one") || $0.contains("any AT terminal") },
              "advice: the RM520N-GL's advice no longer says RMNet has no AT terminal", "\(rm520NotQMI)")
        check(rm520NotQMI.firstIndex(of: usbModeQmiCommand) == 1, "advice: the verb is the line after the first",
              "\(rm520NotQMI)")
        // Any other model: the two AT commands, from software that talks to the modem over USB or from another
        // computer, and a replug in place of the second; RMNet's verbs are named only to say they work with the
        // RM520N-GL alone (its AT port opens no other model). No terminal program is named: macOS gives the AT
        // ports no serial device to open with one.
        for product in [0x0125, 0x0121, 0x0800] {
            let name = String(format: "%04x", product)
            let other = advice(status([enabled], .notQMI, model: quectelModel(product: product)), bundledVersion: "316.19.56")
            check(other == otherNotQMILines + [alwaysLine],
                  "advice: model \(name) not in QMI mode gives the two AT commands, the replug, and RMNet's limits", "\(other)")
            check(!other.contains(usbModeQmiCommand) && !other.contains { atFallbackCommands.contains($0) }
                    && !other.contains { $0.contains("RMNet usbmode set") || $0.contains("RMNet at '") },
                  "advice: model \(name) is given no RMNet usbmode or RMNet at command", "\(other)")
            check(other[0].contains("RMNet at and RMNet usbmode work only with the RM520N-GL")
                    && other.contains("(or unplug and replug the modem instead of AT+CFUN=1,1)"),
                  "advice: model \(name) is told RMNet's AT verbs work only with the RM520N-GL, and that a replug will do",
                  "\(other)")
            check(!other.contains { $0.contains("console") }, "advice: model \(name): no console", "\(other)")
            check(!other.contains { $0.contains("terminal program") }
                    && other[0].contains("software that talks to the modem over USB")
                    && other[0].contains("another computer (Linux or Windows)"),
                  "advice: model \(name): no terminal program (macOS gives the AT ports no serial device); USB software "
                    + "or another computer", "\(other)")
        }
        // The model alone, without .notQMI, adds no QMI-mode line.
        let rm520Up = advice(status([enabled], model: rm520Model, attached: true, ["RMNetState": "up"]), bundledVersion: "316.19.56")
        check(rm520Up == [alwaysLine], "advice: an RM520N-GL in QMI mode, connected, gives only the standing line", "\(rm520Up)")

        let two = advice(status([enabled, ExtensionEntry(version: "316.20.1", enabled: false, awaitingApproval: false, uninstalling: false)]),
                         bundledVersion: "316.19.56")
        check(two.contains { $0.contains("switched off in System Settings") }, "advice: two entries says it was switched off", "\(two)")
        check(two.contains { $0.contains("Use Remove once for each listed version") }, "advice: two entries says Remove once per version", "\(two)")
        check(two.contains { $0.contains("Install and Update are off") }, "advice: two entries says Install and Update are off", "\(two)")
        check(two.contains { $0.contains("build/installed/RMNet-316.19.56.app") && $0.contains("build/installed/RMNet-316.20.1.app") },
              "advice: two entries names the kept app for each version", "\(two)")
        check(two[two.count - 2].hasPrefix("Install and Update are off"), "advice: the can't-activate line comes just before the standing line", "\(two)")
        check(two.last == alwaysLine, "advice: two entries ends with the standing line", "\(two)")

        let off = advice(status([ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: false, uninstalling: false)]),
                         bundledVersion: "316.19.56")
        check(off.contains { $0.contains("switched off in System Settings") }, "advice: installed, not enabled says it was switched off", "\(off)")

        // More than one entry with none switched off (a replacement under way, say): the listing in
        // words, not the switched-off line. A switched-off entry among them keeps the switched-off line.
        let moreThanOne = "The system lists more than one entry for the driver"
        let bothOn = advice(status([enabled, ExtensionEntry(version: "316.21.4", enabled: true, awaitingApproval: false, uninstalling: false)]),
                            bundledVersion: "316.19.56")
        check(!bothOn.contains { $0.contains("switched off") }, "advice: two enabled entries do not say switched off", "\(bothOn)")
        check(bothOn.contains("The system lists more than one entry for the driver: 316.19.56 (enabled), 316.21.4 (enabled). This can be a replacement still under way; while it lasts, the system refuses a new installation."),
              "advice: two enabled entries say the system lists more than one entry", "\(bothOn)")
        check(bothOn.last == alwaysLine, "advice: two enabled entries end with the standing line", "\(bothOn)")
        let replacing = advice(status([enabled, ExtensionEntry(version: "316.21.4", enabled: false, awaitingApproval: true, uninstalling: false)]),
                               bundledVersion: "316.21.4")
        check(!replacing.contains { $0.contains("switched off") } && replacing.contains { $0.hasPrefix(moreThanOne) },
              "advice: an enabled entry and one awaiting approval are not called switched off", "\(replacing)")
        check(two.contains { $0.contains("switched off in System Settings") } && !two.contains { $0.hasPrefix(moreThanOne) },
              "advice: one switched-off entry among two keeps the switched-off line only", "\(two)")

        let differs = advice(status([enabled], attached: true, ["RMNetState": "up"]), bundledVersion: "316.21.4")
        check(differs.contains { $0.contains("Update will replace version 316.19.56 with version 316.21.4") },
              "advice: differing version says Update will replace it", "\(differs)")
        check(differs.contains { $0.contains("next plugged in") }, "advice: differing version says when the new build loads", "\(differs)")
        check(differs.last == alwaysLine, "advice: differing version ends with the standing line", "\(differs)")
        check(!advice(status([enabled]), bundledVersion: "").contains { $0.contains("Update will replace") },
              "advice: an unknown bundled version says nothing about Update")

        let none = advice(status([]), bundledVersion: "316.19.56")
        check(none.last == alwaysLine, "advice: not installed ends with the standing line", "\(none)")

        // --- canRemoveDirectly -----------------------------------------------------------------
        check(canRemoveDirectly(status([enabled]), bundledVersion: "316.19.56"), "canRemoveDirectly: one matching entry")
        check(!canRemoveDirectly(status([enabled]), bundledVersion: "316.21.4"), "canRemoveDirectly: one differing entry")
        check(!canRemoveDirectly(status([enabled, enabled]), bundledVersion: "316.19.56"), "canRemoveDirectly: two entries")
        check(!canRemoveDirectly(status([]), bundledVersion: "316.19.56"), "canRemoveDirectly: no entry")
        // 317.9 and 317.9.0 are the same version, as installTitle sees them ("Reinstall").
        let short = ExtensionEntry(version: "317.9", enabled: true, awaitingApproval: false, uninstalling: false)
        check(canRemoveDirectly(status([short]), bundledVersion: "317.9.0"), "canRemoveDirectly: 317.9 listed, 317.9.0 bundled")
        check(removalPlan(status([short]), bundledVersion: "317.9.0") == .deactivate,
              "removalPlan: 317.9 listed, 317.9.0 bundled deactivates it")
        let shortOff = ExtensionEntry(version: "317.9", enabled: false, awaitingApproval: false, uninstalling: false)
        let other = ExtensionEntry(version: "317.10.17", enabled: true, awaitingApproval: false, uninstalling: false)
        check(removalPlan(status([shortOff, other]), bundledVersion: "317.9.0") == .deactivate,
              "removalPlan: stuck, 317.9 listed switched off, 317.9.0 bundled deactivates it")

        // --- canActivate -----------------------------------------------------------------------
        let switchedOff = ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: false, uninstalling: false)
        let waiting = ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: true, uninstalling: false)
        let leaving = ExtensionEntry(version: "316.19.56", enabled: true, awaitingApproval: false, uninstalling: true)
        let bEnabled = ExtensionEntry(version: "316.21.4", enabled: true, awaitingApproval: false, uninstalling: false)
        check(canActivate(status([])), "canActivate: no entry")
        check(canActivate(status([enabled])), "canActivate: one enabled entry")
        check(canActivate(status([waiting])), "canActivate: one entry awaiting approval")
        check(!canActivate(status([switchedOff])), "canActivate: one switched-off entry")
        check(!canActivate(status([enabled, bEnabled])), "canActivate: two entries")
        check(!canActivate(status([leaving])), "canActivate: an uninstalling entry")
        check(!advice(status([enabled]), bundledVersion: "316.19.56").contains { $0.contains("Install and Update are off") },
              "advice: no can't-activate line when activation is allowed")
        let leavingAdvice = advice(status([leaving]), bundledVersion: "316.21.4")
        check(leavingAdvice == [removalUnderWayLine], "advice: only uninstalling entries gives only the removal line",
              "\(leavingAdvice)")
        check(!leavingAdvice.contains { $0.contains("build/installed/") || $0.contains("Use Remove") },
              "advice: uninstalling names no kept app and no Remove", "\(leavingAdvice)")
        let leavingNotQMI = advice(status([leaving], .notQMI), bundledVersion: "316.21.4")
        check(leavingNotQMI.contains("AT+QCFG=\"usbnet\",0") && leavingNotQMI.contains("AT+CFUN=1,1"),
              "advice: only uninstalling entries, modem not in QMI mode, still names the two AT commands", "\(leavingNotQMI)")
        check(leavingNotQMI.last == removalUnderWayLine
                && !leavingNotQMI.contains { $0.contains("build/installed/") || $0.contains("Use Remove") },
              "advice: only uninstalling entries, modem not in QMI mode, ends with the removal line and names no Remove",
              "\(leavingNotQMI)")
        check(leavingNotQMI == otherNotQMILines + [removalUnderWayLine],
              "advice: only uninstalling entries, model not known, not in QMI mode: the AT commands, then the removal line",
              "\(leavingNotQMI)")
        let leavingRm520 = advice(status([leaving], .notQMI, model: quectelModel(product: 0x0801)), bundledVersion: "316.21.4")
        check(leavingRm520 == rm520NotQMILines + [removalUnderWayLine],
              "advice: only uninstalling entries, an RM520N-GL not in QMI mode: the verb, the fallback, then the removal line",
              "\(leavingRm520)")

        // --- removalPlan, for an app carrying B = 316.21.4 (A = 316.19.56) --------------------
        let b = "316.21.4"
        let plans: [(String, [ExtensionEntry], RemovalPlan)] = [
            ("[A enabled]", [enabled], .activateThenDeactivate),
            ("[A switched off]", [switchedOff], .cannot),
            ("[A enabled, B enabled]", [enabled, bEnabled], .deactivate),
            ("[A switched off, B enabled]", [switchedOff, bEnabled], .deactivate),
            ("[B enabled]", [bEnabled], .deactivate),
            ("[A uninstalling]", [leaving], .nothingListed),
            ("no entry", [], .nothingListed),
        ]
        for (name, entries, want) in plans {
            let got = removalPlan(status(entries), bundledVersion: b)
            check(got == want, "removalPlan: \(name)", "want \(want), got \(got)")
        }
        check(removalPlan(status([enabled]), bundledVersion: "") == .cannot, "removalPlan: unknown bundled version")

        // --- a removal under way, for an app carrying B (A1) -------------------------------------
        let bLeaving = ExtensionEntry(version: b, enabled: true, awaitingApproval: false, uninstalling: true)
        struct Under { var name: String; var entries: [ExtensionEntry]; var plan: RemovalPlan
                       var canActivate: Bool; var canRemoveDirectly: Bool; var title: String }
        let under: [Under] = [
            Under(name: "[B enabled]", entries: [bEnabled], plan: .deactivate,
                  canActivate: true, canRemoveDirectly: true, title: "Reinstall"),
            Under(name: "[B uninstalling]", entries: [bLeaving], plan: .nothingListed,
                  canActivate: false, canRemoveDirectly: false, title: "Install"),
            Under(name: "[A uninstalling]", entries: [leaving], plan: .nothingListed,
                  canActivate: false, canRemoveDirectly: false, title: "Install"),
            Under(name: "[A enabled, B uninstalling]", entries: [enabled, bLeaving], plan: .cannot,
                  canActivate: false, canRemoveDirectly: false, title: "Update"),
        ]
        for u in under {
            let s = status(u.entries, attached: true, ["RMNetState": "up"])
            let plan = removalPlan(s, bundledVersion: b)
            check(plan == u.plan, "removal under way: plan for \(u.name)", "want \(u.plan), got \(plan)")
            check(canActivate(s) == u.canActivate, "removal under way: canActivate for \(u.name)")
            check(canRemoveDirectly(s, bundledVersion: b) == u.canRemoveDirectly, "removal under way: canRemoveDirectly for \(u.name)")
            let title = installTitle(s, bundledVersion: b)
            check(title == u.title, "removal under way: title for \(u.name)", "want \(u.title), got \(title)")
        }
        check(advice(status([bLeaving], attached: true, ["RMNetState": "up"]), bundledVersion: b) == [removalUnderWayLine],
              "advice: [B uninstalling] gives only the removal line")
        let mixed = advice(status([enabled, bLeaving]), bundledVersion: b)
        check(mixed.contains { $0.contains("build/installed/RMNet-316.19.56.app") }, "advice: [A enabled, B uninstalling] names A's kept app", "\(mixed)")
        check(!mixed.contains { $0.contains("RMNet-316.21.4.app") }, "advice: [A enabled, B uninstalling] leaves B out", "\(mixed)")
        check(keptAppsLine([bLeaving]) == "", "keptAppsLine: only uninstalling entries gives nothing")
        // Wherever Install is off and the advice is not only the removal line, at least one entry is
        // not uninstalling, so the can't-activate line names a kept app.
        let stuck: [(String, [ExtensionEntry])] = [
            ("[A switched off]", [switchedOff]), ("[A enabled, B enabled]", [enabled, bEnabled]),
            ("[A enabled, B uninstalling]", [enabled, bLeaving]), ("[A switched off, A uninstalling]", [switchedOff, leaving]),
        ]
        for (name, entries) in stuck {
            let line = advice(status(entries), bundledVersion: b).first { $0.hasPrefix("Install and Update are off") }
            let kept = keptAppsLine(entries)
            check(!kept.isEmpty && line == "Install and Update are off until this is cleared. " + kept,
                  "advice: the can't-activate line names the kept apps for \(name)", "\(line ?? "no line")")
        }

        // --- what Remove says when it can send nothing -------------------------------------------
        let cannotLeaving = cannotRemoveText(status([enabled, bLeaving]), bundledVersion: b)
        check(cannotLeaving.contains("version 316.21.4, which the system is already removing")
                && !cannotLeaving.contains("not listed") && cannotLeaving.contains("build/installed/RMNet-316.19.56.app"),
              "cannotRemoveText: the bundled version listed as uninstalling is said to be being removed", cannotLeaving)
        let cannotAbsent = cannotRemoveText(status([switchedOff]), bundledVersion: b)
        check(cannotAbsent.contains("version 316.21.4, which is not listed") && cannotAbsent.contains("build/installed/RMNet-316.19.56.app"),
              "cannotRemoveText: the bundled version not listed is said to be not listed", cannotAbsent)
        let cannotNoDriver = cannotRemoveText(status([enabled]), bundledVersion: "")
        check(cannotNoDriver.contains("carries no driver") && !cannotNoDriver.contains("not listed"),
              "cannotRemoveText: with no embedded driver, says the app carries none", cannotNoDriver)
        check(cannotNoDriver == "This app carries no driver (the version of its embedded driver cannot be read), so it cannot remove the listed driver. "
                + keptAppsLine([enabled]),
              "cannotRemoveText: with no embedded driver, the reason then the kept app", cannotNoDriver)

        // --- versions and the install button's title (A2) ----------------------------------------
        let versions: [(String, String, Int)] = [
            ("317.10.2", "317.9.11", 1), ("317.9.11", "317.10.2", -1), ("317.9.11", "317.9.11", 0),
            ("317.9", "317.9.0", 0), ("317.9.1", "317.9", 1), ("317.9a", "317.9b", -1), ("318", "317.99.99", 1),
        ]
        for (x, y, want) in versions {
            check(compareVersions(x, y) == want, "compareVersions(\(x), \(y))", "want \(want), got \(compareVersions(x, y))")
        }
        let installed = ExtensionEntry(version: "317.9.11", enabled: true, awaitingApproval: false, uninstalling: false)
        let titles: [(String, String)] = [("317.10.2", "Update"), ("317.9.11", "Reinstall"), ("317.9.10", "Replace")]
        for (bundled, want) in titles {
            let got = installTitle(status([installed]), bundledVersion: bundled)
            check(got == want, "installTitle: bundled \(bundled) over 317.9.11", "want \(want), got \(got)")
            check(canActivate(status([installed])), "installTitle: the button stays on for \(want)")
        }
        check(installTitle(status([]), bundledVersion: "317.9.11") == "Install", "installTitle: nothing listed")
        check(installTitle(status([installed]), bundledVersion: "") == "Update", "installTitle: unknown bundled version")
        let older = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.9.10")
        check(older.contains { $0.hasPrefix("Replace will replace version 317.9.11 with version 317.9.10") },
              "advice: an older bundled version says Replace", "\(older)")
        let newer = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.10.2")
        check(newer.contains { $0.hasPrefix("Update will replace version 317.9.11 with version 317.10.2") },
              "advice: a newer bundled version says Update", "\(newer)")
        let same = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.9.11")
        check(same == [alwaysLine], "advice: the same version says nothing about replacing", "\(same)")

        // --- describeListing ---------------------------------------------------------------------
        check(describeListing([]) == "none", "describeListing: none")
        check(describeListing([switchedOff, bEnabled]) == "316.19.56 (not enabled), 316.21.4 (enabled)",
              "describeListing: two entries", describeListing([switchedOff, bEnabled]))

        // --- installConfirmed: the listing read after an installation ----------------------------
        check(installConfirmed([enabled], version: "316.19.56"), "installConfirmed: one enabled entry of the version")
        check(installConfirmed([short], version: "317.9.0"), "installConfirmed: 317.9 listed, 317.9.0 installed")
        check(!installConfirmed([switchedOff], version: "316.19.56"), "installConfirmed: one entry of the version, not enabled")
        check(!installConfirmed([waiting], version: "316.19.56"), "installConfirmed: one entry of the version, awaiting approval")
        check(!installConfirmed([enabled, bEnabled], version: "316.19.56"), "installConfirmed: two entries")
        check(!installConfirmed([enabled, enabled], version: "316.19.56"), "installConfirmed: two entries of the version")
        check(!installConfirmed([enabled], version: "316.21.4"), "installConfirmed: one enabled entry of another version")
        check(!installConfirmed([], version: "316.19.56"), "installConfirmed: nothing listed")

        // --- notSentText: why a button press sent nothing ----------------------------------------
        let busyText = "Nothing was sent: another request is still running."
        check(notSentText(action: "Remove", busy: true, known: true) == busyText, "notSentText: busy",
              notSentText(action: "Remove", busy: true, known: true))
        check(notSentText(action: "Remove", busy: true, known: false) == busyText, "notSentText: busy comes before an unknown listing",
              notSentText(action: "Remove", busy: true, known: false))
        check(notSentText(action: "Update", busy: false, known: false)
                == "Nothing was sent: the system's listing is not known right now. Press Update again once the listing has refreshed.",
              "notSentText: listing not known", notSentText(action: "Update", busy: false, known: false))
        check(notSentText(action: "Remove", busy: false, known: true)
                == "Nothing was sent: the listing has changed. Remove is available again only when the new listing allows it.",
              "notSentText: listing changed", notSentText(action: "Remove", busy: false, known: true))

        // --- table rows ------------------------------------------------------------------------
        let props = ["RMNetState": "up", "RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141", "RMNetIPv6": "none",
                     "RMNetProfile": "1", "RMNetTxPackets": "12", "RMNetRxPackets": "7", "RMNetTxDropBusy": "0",
                     "RMNetSomethingNew": "abc"]
        let rows = tableRows(status([enabled], attached: true, props), bundledVersion: "316.21.4", listingKnown: true)
        let names = rows.map { $0.name }
        check(names == ["State", "IPv4", "IPv6", "Profile", "Installed driver version", "Bundled version",
                        "RMNetRxPackets", "RMNetSomethingNew", "RMNetTxPackets"],
              "tableRows: fixed rows, then non-zero counters and unknown keys sorted by name", "\(names)")
        check(rows[0].value == "up" && rows[1].value == "10.62.238.140/29 gw 10.62.238.141",
              "tableRows: state and IPv4 values", "\(rows)")
        check(rows[4].value == "316.19.56" && rows[5].value == "316.21.4", "tableRows: versions", "\(rows)")
        let unknownRows = tableRows(status([enabled], attached: true, props), bundledVersion: "316.21.4", listingKnown: false)
        check(unknownRows.map { $0.name } == names, "tableRows: the same rows when the listing is unknown", "\(unknownRows)")
        check(unknownRows[4].value == "unknown", "tableRows: the installed version is unknown when the listing is unknown",
              "\(unknownRows[4])")
        check(unknownRows[5].value == "316.21.4" && unknownRows[0].value == "up",
              "tableRows: the bundled version and the registry rows stay when the listing is unknown", "\(unknownRows)")
        let unknownNone = tableRows(status([]), bundledVersion: "316.21.4", listingKnown: false)
        check(unknownNone[4].value == "unknown", "tableRows: an unknown listing with no last entry says unknown, not none",
              "\(unknownNone[4])")

        // --- Quectel models ----------------------------------------------------------------------
        let rm520 = quectelModel(product: 0x0801)
        check(rm520?.qmiInterface == 4 && rm520?.tested == true && rm520?.names == "RM520N-GL",
              "quectelModel: 0x0801 is the RM520N-GL, QMI interface 4, tested", "\(String(describing: rm520))")
        let ec25 = quectelModel(product: 0x0125)
        check(ec25?.qmiInterface == 4 && ec25?.tested == false && ec25?.names == "EC25, EC20 R2.0 Mini PCIe",
              "quectelModel: 0x0125 is the EC25, QMI interface 4, untested", "\(String(describing: ec25))")
        let ec21 = quectelModel(product: 0x0121)
        check(ec21?.qmiInterface == 4 && ec21?.tested == false, "quectelModel: 0x0121, QMI interface 4, untested",
              "\(String(describing: ec21))")
        let rm500q = quectelModel(product: 0x0800)
        check(rm500q?.qmiInterface == 4 && rm500q?.tested == false && rm500q?.names == "RM500Q-GL",
              "quectelModel: 0x0800 is the RM500Q-GL, QMI interface 4, untested", "\(String(describing: rm500q))")
        check(quectelModel(product: 0x0316) == nil, "quectelModel: 0x0316 (the RG255C, QMI protocol 0x50) is not listed")
        check(quectelModel(product: 0x1234) == nil, "quectelModel: an unknown product")
        check(quectelModels.first?.product == 0x0801, "quectelModels: the RM520N-GL first, so it is found first")
        check(quectelModels.filter { $0.tested }.map { $0.product } == [0x0801], "quectelModels: only the RM520N-GL is tested")
        check(Set(quectelModels.map { $0.product }).count == quectelModels.count, "quectelModels: each product once")
        check(quectelModels.allSatisfy { $0.qmiInterface == 4 }, "quectelModels: every listed QMI interface is 4")

        // --- which interface is the QMI one --------------------------------------------------------
        func stateWords(_ s: ModemState) -> String {
            switch s {
            case .absent: return "absent"
            case .notQMI: return "notQMI"
            case .qmi(let n): return "qmi \(n)"
            }
        }
        func iface(_ number: Int, _ cls: Int, _ sub: Int, _ proto: Int, _ endpoints: Int?) -> UsbInterface {
            UsbInterface(number: number, interfaceClass: cls, subclass: sub, proto: proto, endpoints: endpoints)
        }
        // The RM520N-GL in QMI mode, as the I/O registry lists it.
        let rm520Interfaces: [UsbInterface] = [
            iface(0, 0xff, 0xff, 0x30, 2), iface(1, 0xff, 0x00, 0x40, 3), iface(2, 0xff, 0x00, 0x00, 3),
            iface(3, 0xff, 0x00, 0x00, 3), iface(4, 0xff, 0xff, 0xff, 3),
        ]
        var got = stateWords(modemState(rm520!, interfaces: rm520Interfaces))
        check(got == "qmi 4", "modemState: the RM520N-GL in QMI mode", got)
        got = stateWords(modemState(rm520!, interfaces: Array(rm520Interfaces.reversed())))
        check(got == "qmi 4", "modemState: the order the registry lists them in does not matter", got)
        got = stateWords(modemState(rm520!, interfaces: [iface(4, 0xff, 0xff, 0xff, nil)]))
        check(got == "qmi 4", "modemState: no endpoint count in the registry: the class decides", got)
        // An EC25 whose DIAG port (ff/ff/ff, 2 endpoints) is there but interface 4 is not.
        got = stateWords(modemState(ec25!, interfaces: [iface(0, 0xff, 0xff, 0xff, 2), iface(2, 0xff, 0x00, 0x00, 3)]))
        check(got == "notQMI", "modemState: a DIAG port with the QMI class is never taken for the QMI interface", got)
        got = stateWords(modemState(ec25!, interfaces: [iface(4, 0xff, 0xff, 0xff, 2)]))
        check(got == "notQMI", "modemState: the QMI number with two endpoints is not the QMI interface", got)
        got = stateWords(modemState(rm500q!, interfaces: [iface(3, 0xff, 0xff, 0xff, 3), iface(4, 0x02, 0x0e, 0x00, 1)]))
        check(got == "notQMI", "modemState: another interface with the QMI class and endpoints is not taken", got)
        got = stateWords(modemState(rm520!, interfaces: [iface(4, 0xff, 0xff, 0x50, 3)]))
        check(got == "notQMI", "modemState: protocol 0x50 is not ff", got)
        got = stateWords(modemState(rm520!, interfaces: []))
        check(got == "notQMI", "modemState: no interfaces", got)

        // --- the status verb's modem line ------------------------------------------------------
        let qmiLine = modemLine(.qmi(interface: 4), model: rm520)
        check(qmiLine == "modem: 2c7c:0801 RM520N-GL attached, QMI interface 4 (class, subclass, protocol ff)",
              "modemLine: the RM520N-GL in QMI mode", qmiLine)
        let untestedLine = modemLine(.qmi(interface: 4), model: rm500q)
        check(untestedLine == "modem: 2c7c:0800 RM500Q-GL (untested) attached, QMI interface 4 (class, subclass, protocol ff)",
              "modemLine: an untested model in QMI mode", untestedLine)
        let notQMILine = modemLine(.notQMI, model: ec21)
        check(notQMILine == "modem: 2c7c:0121 EC21 Mini PCIe (untested) attached, interface 4 is not a QMI interface (class, subclass, protocol ff, 3 endpoints): not in QMI mode",
              "modemLine: an untested model not in QMI mode", notQMILine)
        let absentLine = modemLine(.absent, model: nil)
        check(absentLine == "modem: not attached (no USB device 2c7c with product 0801, 0121, 0122, 0125, 013d, 0191, 0195, 0296, 0306, 030b, 030e, 0512, 0620 or 0800)",
              "modemLine: no listed modem attached", absentLine)

        // --- property strings ------------------------------------------------------------------
        check(propertyString(NSNumber(value: 0)) == "0", "propertyString: number 0")
        check(propertyString(NSNumber(value: 4736)) == "4736", "propertyString: number")
        check(propertyString("up" as NSString) == "up", "propertyString: string")

        // --- JSON ------------------------------------------------------------------------------
        let json = statusJSON(status([enabled], attached: true, ["RMNetState": "up", "RMNetRxBytes": "5"]),
                              bundledVersion: "316.19.56")
        check(JSONSerialization.isValidJSONObject(json), "statusJSON: valid JSON object")
        check(json["headline"] as? String == "Connected", "statusJSON: headline")
        check((json["properties"] as? [String: String])?["RMNetState"] == "up", "statusJSON: flat properties of strings")
        check((json["properties"] as? [String: String])?["RMNetRxBytes"] == "5", "statusJSON: counters as strings")
        check(json["modem"] as? String == "qmi" && json["qmiInterface"] as? Int == 4, "statusJSON: modem", "\(json)")
        check(json["canActivate"] as? Bool == true && json["error"] == nil, "statusJSON: canActivate, no error", "\(json)")
        let unknown = statusJSON(status([], attached: true, ["RMNetState": "up"]), bundledVersion: "316.19.56",
                                 listingError: "no answer from the system in 10 s")
        check(JSONSerialization.isValidJSONObject(unknown), "statusJSON unknown: valid JSON object")
        check(unknown["headline"] as? String == "Unknown", "statusJSON unknown: headline is Unknown, not Not installed", "\(unknown)")
        check(unknown["entries"] is NSNull, "statusJSON unknown: entries null", "\(unknown)")
        check(unknown["error"] as? String == "no answer from the system in 10 s", "statusJSON unknown: error kept")
        check(unknown["canActivate"] as? Bool == false && unknown["canRemoveDirectly"] as? Bool == false,
              "statusJSON unknown: no button may act", "\(unknown)")
        check((unknown["properties"] as? [String: String])?["RMNetState"] == "up", "statusJSON unknown: registry still read")

        // --- the Driver screen's line beside its buttons ----------------------------------------
        let one = status([ExtensionEntry(version: "318.19.40", enabled: true, awaitingApproval: false, uninstalling: false)])
        check(driverActionNote(status([]), bundledVersion: "318.20.1") == "This app carries version 318.20.1.",
              "action note: install")
        check(driverActionNote(one, bundledVersion: "318.20.1")
                == "This app carries version 318.20.1, newer than 318.19.40.", "action note: update")
        check(driverActionNote(one, bundledVersion: "318.19.40") == "This app carries the version installed, 318.19.40.",
              "action note: reinstall")
        check(driverActionNote(one, bundledVersion: "318.18.1")
                == "This app carries version 318.18.1, older than 318.19.40.", "action note: replace")
        check(driverActionNote(one, bundledVersion: "") == "This app carries no driver.", "action note: no driver bundled")

        print("app-test: \(checks) checks passed")
    }
}
