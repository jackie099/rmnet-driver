// What the RMNet app knows about the driver, and what it says about it. Foundation only: the window,
// `RMNet status --json` and `make app-test` all use these pure functions.
import Foundation

// One entry the system lists for the driver extension (a properties request).
struct ExtensionEntry {
    var version: String  // CFBundleVersion
    var enabled: Bool
    var awaitingApproval: Bool
    var uninstalling: Bool
}

// The modem on USB (a model from quectelModels): absent, attached without its QMI interface, or
// attached with it (modemState says which).
enum ModemState {
    case absent, notQMI, qmi(interface: Int)
}

// A Quectel modem the driver matches (an RMNetDriver personality in driver/Info.plist): its USB
// product under vendor 0x2C7C, the number of its QMI interface, its model names, and whether the
// driver has run on it.
struct QuectelModel {
    let product: Int
    let qmiInterface: Int
    let names: String
    let tested: Bool
}

// One model per line, in this form: tests/scripts/test-personalities.sh reads the products and
// interfaces from these lines and compares them with the model list in scripts/check-personalities.sh
// and the RMNetDriver personalities in driver/Info.plist. The RM520N-GL first, so it is the one found
// when several are attached; it is the modem the driver was built for and tested on, its QMI
// interface 4 found on the modem. The others are untested Quectel entries of the Linux kernel's
// drivers/net/usb/qmi_wwan.c (torvalds/linux, master, fetched 2026-11-15); each line's comment gives
// the entry and, where the entry has no interface number (QMI_MATCH_FF_FF_FF, a match by class), the
// source of the number: Quectel's UMTS_LTE_5G Linux USB Driver User Guide v3.0 (2022-03-18), Table 1
// (qmi_wwan_q on interface 4), or the kernel commit that added the model. Not listed: the RG255C
// (0x0316), whose QMI interface 3 is ff/ff/50, which the driver's Start refuses.
let quectelModels: [QuectelModel] = [
    QuectelModel(product: 0x0801, qmiInterface: 4, names: "RM520N-GL", tested: true),
    QuectelModel(product: 0x0121, qmiInterface: 4, names: "EC21 Mini PCIe", tested: false),  // {QMI_QUIRK_SET_DTR(0x2c7c, 0x0121, 4)}, /* Quectel EC21 Mini PCIe */
    QuectelModel(product: 0x0122, qmiInterface: 4, names: "RG650V", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0122)}; interface 4: commit 6b3f18a76be6's listing
    QuectelModel(product: 0x0125, qmiInterface: 4, names: "EC25, EC20 R2.0 Mini PCIe", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0125)}; interface 4: Quectel's guide, Table 1
    QuectelModel(product: 0x013d, qmiInterface: 4, names: "RG660QB", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x013d)}; interface 4: commit 4ff75f130d1b's message
    QuectelModel(product: 0x0191, qmiInterface: 4, names: "EG91", tested: false),  // {QMI_QUIRK_SET_DTR(0x2c7c, 0x0191, 4)}, /* Quectel EG91 */
    QuectelModel(product: 0x0195, qmiInterface: 4, names: "EG95", tested: false),  // {QMI_QUIRK_SET_DTR(0x2c7c, 0x0195, 4)}, /* Quectel EG95 */
    QuectelModel(product: 0x0296, qmiInterface: 4, names: "BG96", tested: false),  // {QMI_FIXED_INTF(0x2c7c, 0x0296, 4)}, /* Quectel BG96 */
    QuectelModel(product: 0x0306, qmiInterface: 4, names: "EP06/EG06/EM06", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0306)}; interface 4: Quectel's guide, Table 1
    QuectelModel(product: 0x030b, qmiInterface: 4, names: "EM060K/EG120K-EA", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x030b)}; interface 4: Quectel's guide, Table 1
    QuectelModel(product: 0x030e, qmiInterface: 4, names: "EM05GV2", tested: false),  // {QMI_QUIRK_SET_DTR(0x2c7c, 0x030e, 4)}, /* Quectel EM05GV2 */
    QuectelModel(product: 0x0512, qmiInterface: 4, names: "EG12/EM12", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0512)}; interface 4: Quectel's guide, Table 1
    QuectelModel(product: 0x0620, qmiInterface: 4, names: "EM160R-GL", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0620)}; interface 4: Quectel's guide, Table 1
    QuectelModel(product: 0x0800, qmiInterface: 4, names: "RM500Q-GL", tested: false),  // {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0800)}; interface 4: Quectel's guide, Table 1
]

func quectelModel(product: Int) -> QuectelModel? {
    quectelModels.first { $0.product == product }
}

// The one product the app's AT port opens (AtPort in app/AtPort.swift): the RM520N-GL. Only on it can
// `RMNet usbmode` and `RMNet at` reach the modem, so only for it does the advice name those verbs.
let atPortProduct = 0x0801

// The command the advice gives to put an RM520N-GL in QMI mode; the window shows it in a fixed-width font.
let usbModeQmiCommand = "RMNet usbmode set qmi"

// The fallback for an RM520N-GL: the two AT commands, sent with `RMNet at`; also fixed-width in the window.
let atFallbackCommands = ["RMNet at 'AT+QCFG=\"usbnet\",0'", "RMNet at AT+CFUN=1,1"]

// One of the modem's USB interfaces, as the I/O registry describes it (nil: the property is missing).
struct UsbInterface {
    let number: Int?
    let interfaceClass: Int?
    let subclass: Int?
    let proto: Int?
    let endpoints: Int?  // bNumEndpoints
}

// In QMI mode only when the model's own QMI interface is there with class, subclass and protocol
// 0xff and, when the registry gives the count, three endpoints: what the driver's Start takes. No
// other interface is ever taken for it, so a DIAG port with the same class (two endpoints, on
// another number) is not, and a modem in another USB configuration shows as not in QMI mode.
func modemState(_ model: QuectelModel, interfaces: [UsbInterface]) -> ModemState {
    let found = interfaces.contains {
        $0.number == model.qmiInterface && $0.interfaceClass == 0xff && $0.subclass == 0xff && $0.proto == 0xff
            && ($0.endpoints == nil || $0.endpoints == 3)
    }
    return found ? .qmi(interface: model.qmiInterface) : .notQMI
}

// The `status` verb's modem line: the model found (its vid:pid, its names, and "(untested)" for
// any but the RM520N-GL) and whether it is in QMI mode, or the products looked for.
func modemLine(_ modem: ModemState, model: QuectelModel?) -> String {
    let name = model.map { String(format: "2c7c:%04x ", $0.product) + $0.names + ($0.tested ? "" : " (untested)") }
        ?? "2c7c"
    switch modem {
    case .absent:
        let products = quectelModels.map { String(format: "%04x", $0.product) }
        return "modem: not attached (no USB device 2c7c with product "
            + products.dropLast().joined(separator: ", ") + " or " + (products.last ?? "") + ")"
    case .qmi(let number):
        return "modem: \(name) attached, QMI interface \(number) (class, subclass, protocol ff)"
    case .notQMI:
        let number = model.map { "interface \($0.qmiInterface)" } ?? "its QMI interface"
        return "modem: \(name) attached, \(number) is not a QMI interface (class, subclass, protocol ff, 3 endpoints): "
            + "not in QMI mode"
    }
}

struct DriverStatus {
    var entries: [ExtensionEntry]
    var modem: ModemState
    var modemModel: QuectelModel? = nil  // the model `modem` is about (readModemModel); nil when none is attached
    var attached: Bool                 // a registry entry with IOUserClass RMNetDriver exists
    var properties: [String: String]   // that entry's RMNet* properties, as strings
}

// The driver's session states (driver/core_host.cpp) on the way up.
let startingStates: Set<String> = ["", "starting", "idle", "syncing", "configuring", "connecting"]
// The states in which the link is up: Refreshing re-reads the settings with the link kept up.
let upStates: Set<String> = ["up", "refreshing"]

// The headline, decided in this order (the first rule that applies):
//   no entry listed                                          -> Not installed
//   more than one entry, or the one entry is uninstalling,
//     or it is neither enabled nor awaiting approval          -> Needs attention
//   the one entry awaits approval                             -> Waiting for approval in System Settings
//   driver attached, RMNetState up or refreshing              -> Connected
//   driver attached, RMNetState missing, starting, idle,
//     syncing, configuring or connecting                      -> Connecting
//   driver attached, any other RMNetState (backoff,
//     usb failed, detached, anything new)                     -> Link down
//   driver not attached, modem absent                         -> Installed, modem not attached
//   driver not attached, modem not in QMI mode                -> Modem is not in QMI mode
//   driver not attached, modem in QMI mode                    -> Connecting (the driver is loading)
func headline(_ s: DriverStatus) -> String {
    guard let entry = s.entries.first else { return "Not installed" }
    if s.entries.count > 1 || entry.uninstalling || (!entry.enabled && !entry.awaitingApproval) {
        return "Needs attention"
    }
    if entry.awaitingApproval { return "Waiting for approval in System Settings" }
    if s.attached {
        let state = s.properties["RMNetState"] ?? ""
        if upStates.contains(state) { return "Connected" }
        if startingStates.contains(state) { return "Connecting" }
        return "Link down"
    }
    switch s.modem {
    case .absent: return "Installed, modem not attached"
    case .notQMI: return "Modem is not in QMI mode"
    case .qmi: return "Connecting"
    }
}

// True when the entry is installed but switched off: the state the owner reaches by turning the
// driver off in System Settings while the modem is attached.
private func isSwitchedOff(_ e: ExtensionEntry) -> Bool {
    !e.enabled && !e.awaitingApproval && !e.uninstalling
}

let removalUnderWayLine = "The system is removing the driver; the removal finishes when the modem is unplugged or the Mac restarts. Install is available after that."

// The lines shown under the headline, most specific first; the last line is the warning, except
// while every listed entry is uninstalling, when it is `removalUnderWayLine` (after the QMI-mode lines
// if the modem is not in QMI mode). When it is not: for the RM520N-GL, the one model the app's AT port
// opens, `RMNet usbmode set qmi` first, with the two AT commands sent with `RMNet at` as the fallback; for
// any other model (or none known), the two AT commands, to be sent from software that talks to the modem over
// USB or from another computer where the AT port is a serial device (macOS gives the AT ports no serial device,
// and RMNet's AT verbs, which the advice says work only with the RM520N-GL, cannot reach it), and a replug in
// place of the second.
func advice(_ s: DriverStatus, bundledVersion: String) -> [String] {
    var lines: [String] = []
    if case .notQMI = s.modem {
        if s.modemModel?.product == atPortProduct {
            lines.append("The modem is attached but not in QMI mode. Run this command in Terminal, answer y when it asks before restarting the modem, and wait for the modem to come back (RMNet is /Applications/RMNet.app/Contents/MacOS/RMNet):")
            lines.append(usbModeQmiCommand)
            lines.append("Or send the two AT commands with RMNet at, then wait for the modem to come back; unplugging it and plugging it in again does the same as the second:")
            lines.append(contentsOf: atFallbackCommands)
        } else {
            lines.append("The modem is attached but not in QMI mode. Send it these two AT commands from software that talks to the modem over USB, or from another computer (Linux or Windows) where its AT port is a serial device, then wait for it to come back (macOS gives the AT ports no serial device, and RMNet at and RMNet usbmode work only with the RM520N-GL):")
            lines.append("AT+QCFG=\"usbnet\",0")
            lines.append("AT+CFUN=1,1")
            lines.append("(or unplug and replug the modem instead of AT+CFUN=1,1)")
        }
    }
    // A listing made only of entries the system is removing: the removal is under way, and the
    // window says only that (no Remove to press, Install off until the entries are gone).
    if !s.entries.isEmpty && s.entries.allSatisfy({ $0.uninstalling }) {
        return lines + [removalUnderWayLine]
    }
    // From here at least one listed entry is not uninstalling (or none is listed). Switched off is
    // said only of a listing that shows a switched-off entry; more than one entry otherwise can be a
    // replacement still under way, and the listing is given as it is.
    if s.entries.contains(where: isSwitchedOff) {
        lines.append("The driver was switched off in System Settings, so the system keeps an old entry and refuses every new installation.")
    } else if s.entries.count > 1 {
        lines.append("The system lists more than one entry for the driver: \(describeListing(s.entries)). This can be a replacement still under way; while it lasts, the system refuses a new installation.")
    } else if let entry = s.entries.first {
        if entry.awaitingApproval {
            lines.append("Open System Settings, General, Login Items & Extensions, Driver Extensions, and turn RMNet on.")
        } else if !bundledVersion.isEmpty && compareVersions(bundledVersion, entry.version) != 0 {
            lines.append("\(installTitle(s, bundledVersion: bundledVersion)) will replace version \(entry.version) with version \(bundledVersion). The new build loads when the modem is next plugged in or the Mac restarts.")
        }
    }
    if s.entries.count == 1, !s.attached, case .qmi = s.modem, headline(s) == "Connecting" {
        lines.append("The modem is in QMI mode but the driver has not attached. If this lasts, unplug the modem and plug it in again.")
    }
    if !canActivate(s) {
        // Some entry is not uninstalling, so keptAppsLine names at least one kept app.
        lines.append("Install and Update are off until this is cleared. " + keptAppsLine(s.entries))
    }
    lines.append("Do not switch the driver off in System Settings while the modem is attached. Use Remove here.")
    return lines
}

// Deactivation works only from an app that embeds the installed version, and only with one entry,
// which the system is not already removing. Versions are compared as installTitle compares them, so
// 317.9 and 317.9.0 are the same version.
func canRemoveDirectly(_ s: DriverStatus, bundledVersion: String) -> Bool {
    s.entries.count == 1 && isBundled(s.entries[0], bundledVersion) && !s.entries[0].uninstalling
}

// True when the entry is the version this app carries (compared field by field, see compareVersions).
private func isBundled(_ e: ExtensionEntry, _ bundledVersion: String) -> Bool {
    compareVersions(e.version, bundledVersion) == 0
}

// Whether an activation may be sent. Not when the listing shows the stuck state: more than one
// entry, a switched-off entry or an uninstalling one. An activation then fails, or adds an entry
// that needs its own removal. One entry awaiting approval is fine (asking again is harmless).
func canActivate(_ s: DriverStatus) -> Bool {
    s.entries.count <= 1 && !s.entries.contains(where: { isSwitchedOff($0) || $0.uninstalling })
}

// Which kept app removes each listed version. Entries the system is already removing are left out:
// they need no Remove. Empty when no other entry is listed.
func keptAppsLine(_ entries: [ExtensionEntry]) -> String {
    let apps = entries.filter { !$0.uninstalling }.map { "\($0.version) from build/installed/RMNet-\($0.version).app" }
    if apps.isEmpty { return "" }
    return "Use Remove once for each listed version, from the app that carries it, kept in the project folder: "
        + apps.joined(separator: "; ") + "."
}

// Compares two versions such as "317.9.11" and "317.10.2" field by field (fields split on dots):
// two numeric fields compare as numbers, any other pair as text, and a missing field counts as "0".
// Returns -1 when `a` is older, 0 when equal, 1 when newer.
func compareVersions(_ a: String, _ b: String) -> Int {
    let x = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let y = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : "0"
        let q = i < y.count ? y[i] : "0"
        if let m = Int(p), let n = Int(q) {
            if m != n { return m < n ? -1 : 1 }
        } else if p != q {
            return p < q ? -1 : 1
        }
    }
    return 0
}

// The install button's title, and the word the advice uses for it: Install when nothing is listed
// (entries the system is removing do not count), else by the bundled version against the listed
// one: Update when newer, Reinstall when equal, Replace when older. Update when the bundled version
// is unknown (the button is off then).
func installTitle(_ s: DriverStatus, bundledVersion: String) -> String {
    guard let listed = s.entries.first(where: { !$0.uninstalling }) else { return "Install" }
    if bundledVersion.isEmpty { return "Update" }
    switch compareVersions(bundledVersion, listed.version) {
    case 1: return "Update"
    case 0: return "Reinstall"
    default: return "Replace"
    }
}

// The Driver screen's line beside its buttons, when no advice stands above them: what this app carries against what
// is installed, in the words of its install button (installTitle). "This app carries no driver." without one.
func driverActionNote(_ s: DriverStatus, bundledVersion: String) -> String {
    guard !bundledVersion.isEmpty else { return "This app carries no driver." }
    let listed = s.entries.first(where: { !$0.uninstalling })
    switch installTitle(s, bundledVersion: bundledVersion) {
    case "Install": return "This app carries version \(bundledVersion)."
    case "Update": return "This app carries version \(bundledVersion), newer than \(listed?.version ?? "the one installed")."
    case "Reinstall": return "This app carries the version installed, \(bundledVersion)."
    default: return "This app carries version \(bundledVersion), older than \(listed?.version ?? "the one installed")."
    }
}

// Whether the listing read again after an installation of `version` shows it installed: exactly one
// entry, of that version (compared as installTitle compares, so 317.9 and 317.9.0 are the same
// version), enabled.
func installConfirmed(_ entries: [ExtensionEntry], version: String) -> Bool {
    entries.count == 1 && compareVersions(entries[0].version, version) == 0 && entries[0].enabled
}

// Why a press of the install button (`action` is its title) or of Remove sent nothing: the button was
// on when the window drew it, but by the press another request was running, the listing was no
// longer known, or the listing no longer allowed the request.
func notSentText(action: String, busy: Bool, known: Bool) -> String {
    if busy { return "Nothing was sent: another request is still running." }
    if !known {
        return "Nothing was sent: the system's listing is not known right now. Press \(action) again once the listing has refreshed."
    }
    return "Nothing was sent: the listing has changed. \(action) is available again only when the new listing allows it."
}

// The listing in words: "316.19.56 (enabled)", "none".
func describeListing(_ entries: [ExtensionEntry]) -> String {
    if entries.isEmpty { return "none" }
    return entries.map { e -> String in
        var flags = [e.enabled ? "enabled" : "not enabled"]
        if e.awaitingApproval { flags.append("awaiting approval") }
        if e.uninstalling { flags.append("uninstalling") }
        return "\(e.version) (\(flags.joined(separator: ", ")))"
    }.joined(separator: ", ")
}

// What Remove… sends for a listing, with this app carrying `bundledVersion`.
enum RemovalPlan: Equatable {
    case nothingListed           // nothing to remove (no entry, or every entry is uninstalling); the button is off
    case deactivate              // the bundled version is listed and not uninstalling: deactivate it
    case activateThenDeactivate  // one entry of another version: replace it with the bundled one first
    case cannot                  // stuck, and the bundled version is not listed apart from uninstalling: send nothing
}

func removalPlan(_ s: DriverStatus, bundledVersion: String) -> RemovalPlan {
    if s.entries.allSatisfy({ $0.uninstalling }) { return .nothingListed }  // true for no entry too
    if canRemoveDirectly(s, bundledVersion: bundledVersion) { return .deactivate }
    if !canActivate(s) {
        // An entry the system is already removing is never deactivated a second time.
        return s.entries.contains(where: { isBundled($0, bundledVersion) && !$0.uninstalling }) ? .deactivate : .cannot
    }
    return bundledVersion.isEmpty ? .cannot : .activateThenDeactivate
}

// Why Remove sends nothing when the plan is `.cannot`, and which kept apps can remove what is listed.
// With no bundled version the app has no driver to install first or to deactivate, whatever is listed.
func cannotRemoveText(_ s: DriverStatus, bundledVersion: String) -> String {
    if bundledVersion.isEmpty {
        return "This app carries no driver (the version of its embedded driver cannot be read), so it cannot remove the listed driver. "
            + keptAppsLine(s.entries)
    }
    let removing = s.entries.contains(where: { isBundled($0, bundledVersion) && $0.uninstalling })
    return "This app carries version \(bundledVersion), "
        + (removing ? "which the system is already removing" : "which is not listed")
        + ", and the listing does not allow installing it first. "
        + keptAppsLine(s.entries)
}

// A registry property as text: strings as they are, numbers in decimal, data as Foundation prints
// it. The same text `RMNet status` prints after "key = ".
func propertyString(_ value: Any) -> String {
    "\(value)"
}

struct TableRow {
    var name: String
    var value: String
}

let fixedProperties = ["RMNetState", "RMNetIPv4", "RMNetIPv6", "RMNetProfile"]

// The window's table: state, addresses, profile, the two versions, then every other property that
// is not "0", sorted by name (the counters; their list is not fixed here). Unless `listingKnown`
// (the system's last answer was a listing), the installed version is "unknown", not the entries
// last listed.
func tableRows(_ s: DriverStatus, bundledVersion: String, listingKnown: Bool) -> [TableRow] {
    let p = s.properties
    let listed = s.entries.map { $0.version }.joined(separator: ", ")
    let installed = !listingKnown ? "unknown" : listed.isEmpty ? "none" : listed
    var rows = [
        TableRow(name: "State", value: p["RMNetState"] ?? (s.attached ? "" : "not attached")),
        TableRow(name: "IPv4", value: p["RMNetIPv4"] ?? ""),
        TableRow(name: "IPv6", value: p["RMNetIPv6"] ?? ""),
        TableRow(name: "Profile", value: p["RMNetProfile"] ?? ""),
        TableRow(name: "Installed driver version", value: installed),
        TableRow(name: "Bundled version", value: bundledVersion.isEmpty ? "unknown" : bundledVersion),
    ]
    for key in p.keys.sorted() where !fixedProperties.contains(key) && p[key] != "0" {
        rows.append(TableRow(name: key, value: p[key]!))
    }
    return rows
}

// The status as one JSON object (`RMNet status --json`). Properties stay a flat object of strings
// under "properties"; scripts read RMNetState and the counters there. With `listingError` (the
// system gave no listing) the extension's state is unknown: the headline is "Unknown", "entries" is
// null, no button may act, and the error is under "error". The registry part is still read.
let unknownHeadline = "Unknown"

func statusJSON(_ s: DriverStatus, bundledVersion: String, listingError: String? = nil) -> [String: Any] {
    let known = listingError == nil
    var object: [String: Any] = [
        "headline": known ? headline(s) : unknownHeadline,
        "advice": known ? advice(s, bundledVersion: bundledVersion) : [],
        "entries": known ? s.entries.map {
            ["version": $0.version, "enabled": $0.enabled, "awaitingApproval": $0.awaitingApproval,
             "uninstalling": $0.uninstalling] as [String: Any]
        } as Any : NSNull(),
        "attached": s.attached,
        "bundledVersion": bundledVersion,
        "canActivate": known && canActivate(s),
        "canRemoveDirectly": known && canRemoveDirectly(s, bundledVersion: bundledVersion),
        "properties": s.properties,
    ]
    if let error = listingError { object["error"] = error }
    switch s.modem {
    case .absent: object["modem"] = "absent"
    case .notQMI: object["modem"] = "notQMI"
    case .qmi(let number):
        object["modem"] = "qmi"
        object["qmiInterface"] = number
    }
    return object
}
