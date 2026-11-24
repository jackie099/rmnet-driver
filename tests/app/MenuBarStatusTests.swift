// Tests for app/MenuBarStatus.swift: the menu bar item's model, driven by fake sources (the driver's registry
// properties, the modem on USB, the system's listing and the network read) and a clock the test sets, with the
// main run loop pumped so that the network read's result comes back as in the app. Built with swiftc by
// `make app-test` from the status model, the AT port's and the modem's files (for the failures' wording, and the
// real ModemService behind a port that does not open) and this file; needs no AppKit, no window and no modem:
// no port is ever opened.
// Stops at the first failure, prints which check failed and exits 1.
import Combine
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

// MARK: - Fakes

let queueKey = DispatchSpecificKey<String>()
let queueName = "io.rmnetdriver.RMNet.modem.test"

/// The network read: records each call and where it ran, and answers with the next result given. With
/// `holding`, a call blocks (on the model's queue) until the test releases it.
final class FakeNetwork {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var results: [Result<NetworkInfo, ModemFailure>] = []
    private var count = 0
    private var misplaced = 0   // calls made on the main thread or on another queue than the model's
    var holding = false

    var calls: Int { locked { count } }
    var callsOffQueue: Int { locked { misplaced } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func answer(_ r: Result<NetworkInfo, ModemFailure>) { locked { results.append(r) } }

    func release(_ r: Result<NetworkInfo, ModemFailure>) {
        answer(r)
        gate.signal()
    }

    func read() -> Result<NetworkInfo, ModemFailure> {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        let hold = locked { () -> Bool in
            count += 1
            if !placed { misplaced += 1 }
            return holding
        }
        if hold { gate.wait() }
        return locked { results.isEmpty ? .failure(ModemFailure(message: "no result given")) : results.removeFirst() }
    }
}

/// The system's listing: answers at once with `answer` (nil: no listing), or, with `holding`, keeps the
/// completion until the test answers.
final class FakeListing {
    var answer: [ExtensionEntry]? = []
    var holding = false
    var asked = 0
    private var waiting: [([ExtensionEntry]?) -> Void] = []

    func ask(_ done: @escaping ([ExtensionEntry]?) -> Void) {
        asked += 1
        if holding { waiting.append(done) } else { done(answer) }
    }

    func answerWaiting(_ entries: [ExtensionEntry]?) {
        let all = waiting
        waiting = []
        for done in all { done(entries) }
    }
}

let enabled = ExtensionEntry(version: "318.17.57", enabled: true, awaitingApproval: false, uninstalling: false)
let awaiting = ExtensionEntry(version: "318.17.57", enabled: false, awaitingApproval: true, uninstalling: false)
let rm520 = quectelModels[0]
let upProperties: DriverProperties = ["RMNetState": "up", "RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141",
                                      "RMNetIPv6": "2001:db8:1:2::1/64", "RMNetProfile": "1"]

/// A model on fakes, and the clock it reads.
final class Rig {
    var properties: DriverProperties? = nil
    var modem: (state: ModemState, model: QuectelModel?) = (.absent, nil)
    let listing = FakeListing()
    let network = FakeNetwork()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var registryReads = 0
    let queue: DispatchQueue
    var status: MenuBarStatus!

    init(network source: (() -> Result<NetworkInfo, ModemFailure>)? = nil) {
        queue = DispatchQueue(label: queueName)
        queue.setSpecific(key: queueKey, value: queueName)
        let net = network
        status = MenuBarStatus(
            properties: { [unowned self] in self.registryReads += 1; return self.properties },
            modem: { [unowned self] in self.modem },
            listing: { [unowned self] in self.listing.ask($0) },
            network: source ?? { net.read() },
            now: { [unowned self] in self.clock },
            queue: queue)
    }

    /// Opens the panel and waits until the read it started (if any) has come back.
    func open() {
        status.panelOpened()
        pump(until: { !status.reading }, "the read to finish")
    }
}

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

/// One leg of a serving cell, with only what the menu bar shows.
func leg(_ rat: String, band: String?, rsrp: Int?, rsrq: Int? = -11, sinr: Double?) -> CellLeg {
    CellLeg(rat: rat, duplex: "TDD", mcc: "460", mnc: "00", cellID: "1A2B3C", pci: 893, tac: "5A0B", channel: 504990,
            band: band, bandwidthMHz: 100, rsrp: rsrp, rsrq: rsrq, sinr: sinr)
}

let saInfo = NetworkInfo(radio: .on, registration: Registration(status: .home, domain: "5GS"),
                         operatorName: "CHINA MOBILE", networkName: "CHINA MOBILE", plmn: "46000",
                         accessTechnology: 11,
                         serving: ServingCell(state: "NOCONN", cells: [leg("NR5G-SA", band: "n41", rsrp: -86, sinr: 10)]),
                         carriers: ["n41"], mode: "AUTO", nr5gDisable: 0)

@main
struct MenuBarStatusTests {
    static func main() {
        icons()
        headlines()
        addresses()
        polling()
        starting()
        listingWhenNeeded()
        staleListing()
        panelSignals()
        throttle()
        oneReadAtATime()
        notes()
        realServiceWording()
        networkLines()
        asOf()
        readInfo()
        iconStyle()
        signalModel()
        signalIcons()
        signalPolling()
        pulseSignal()
        print("menu bar status: \(checks) checks passed")
    }

    // The icon from the registry and the listing only: no properties → no driver (waiting for approval when the
    // listing says so); RMNetState up or refreshing → up; any other state → down. Each with its symbol and
    // accessibility label.
    static func icons() {
        let rig = Rig()
        let s = rig.status!
        equal(s.icon, .noDriver, "icon: before any poll")

        // No driver: the first poll asks the listing at once (a fresh model each time).
        func noDriverIcon(_ answer: [ExtensionEntry]?, modem: (ModemState, QuectelModel?) = (.absent, nil)) -> MenuBarIcon {
            let r = Rig()
            r.listing.answer = answer
            r.modem = modem
            r.status.poll()
            equal(r.listing.asked, 1, "icon: the listing asked with no driver")
            return r.status.icon
        }
        equal(noDriverIcon([]), .noDriver, "icon: no properties, nothing listed")
        equal(noDriverIcon([enabled], modem: (.qmi(interface: 4), rm520)), .noDriver,
              "icon: no properties, the driver listed and enabled")
        equal(noDriverIcon(nil), .noDriver, "icon: no properties, no listing")
        equal(noDriverIcon([awaiting]), .waitingForApproval, "icon: the listing says waiting for approval")

        rig.listing.answer = [enabled]
        for state in ["up", "refreshing"] {
            rig.properties = ["RMNetState": state]
            s.poll()
            equal(s.icon, .up, "icon: RMNetState \(state)")
        }
        for state in ["", "starting", "idle", "connecting", "backoff", "usb failed", "detached", "something new"] {
            rig.properties = ["RMNetState": state]
            s.poll()
            equal(s.icon, .down, "icon: RMNetState \"\(state)\"")
        }
        rig.properties = [:]
        s.poll()
        equal(s.icon, .down, "icon: attached without RMNetState")
        // The connection decides while the driver is attached, whatever the listing says (an update waiting for
        // approval while the old build runs).
        equal(menuBarIcon(properties: ["RMNetState": "up"], entries: [enabled, awaiting]), .up,
              "icon: up while a new version waits for approval")
        equal(menuBarIcon(properties: ["RMNetState": "up"], entries: nil), .up, "icon: up while the system gives no listing")
        rig.properties = ["RMNetState": "up"]
        rig.listing.answer = [enabled, awaiting]
        rig.open()
        equal(s.icon, .up, "icon: up with the panel open and the listing saying an update waits")

        equal(MenuBarIcon.up.symbolName, "antenna.radiowaves.left.and.right", "symbol: up")
        for icon in [MenuBarIcon.down, .noDriver, .waitingForApproval] {
            equal(icon.symbolName, "antenna.radiowaves.left.and.right.slash", "symbol: \(icon)")
        }
        equal(MenuBarIcon.up.accessibilityLabel, "RMNet: connected", "label: up")
        equal(MenuBarIcon.down.accessibilityLabel, "RMNet: not connected", "label: down")
        equal(MenuBarIcon.noDriver.accessibilityLabel, "RMNet: no driver", "label: no driver")
        equal(MenuBarIcon.waitingForApproval.accessibilityLabel, "RMNet: waiting for approval", "label: waiting")
        s.panelClosed()
    }

    // The headline. With the driver attached: the Driver tab's headline for it from the registry at once
    // (`Connected`, `Connecting`, `Link down`), never `Asking the system…`, also when the panel opens; once the
    // listing answers, headline() over it (`Needs attention` while an update waits beside the old build). With
    // no driver: "Asking the system…" until the listing first answers, "Unknown" while the system gives none, else
    // headline() over the listing, the modem and the registry.
    static func headlines() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.holding = true
        rig.modem = (.qmi(interface: 4), rm520)
        rig.properties = ["RMNetState": "up"]
        s.poll()
        equal(rig.listing.asked, 0, "listing: not asked with the driver attached and the panel closed")
        equal(s.headline, "Connected", "headline: with the driver attached, from the registry before any listing")
        equal(s.icon, .up, "headline: the icon does not wait for the listing")
        rig.open()
        equal(rig.listing.asked, 1, "listing: asked when the panel opens")
        equal(s.headline, "Connected", "headline: no `Asking the system…` when the panel opens with the driver attached")
        s.poll()
        equal(rig.listing.asked, 1, "listing: not asked again while a question is pending")
        rig.listing.answerWaiting([enabled, awaiting])
        equal(s.headline, "Needs attention", "headline: the listing's once it answers (an update waits beside the old build)")
        rig.listing.answerWaiting(nil)   // nothing waits: no change
        equal(s.headline, "Needs attention", "headline: a stray answer changes nothing")
        s.poll()
        equal(rig.listing.asked, 2, "listing: asked again on the next poll")
        rig.listing.answerWaiting(nil)
        equal(s.headline, "Connected", "headline: the system gave no listing: the registry's, with the driver attached")
        for (state, want) in [("connecting", "Connecting"), ("backoff", "Link down"), ("refreshing", "Connected"),
                              ("", "Connecting")] {
            rig.properties = ["RMNetState": state]
            s.poll()
            equal(s.headline, want, "headline: RMNetState \"\(state)\" from the registry while the listing is pending")
            rig.listing.answerWaiting(nil)
        }

        // The panel closed: the answer is dropped, and the headline is the registry's again.
        s.panelClosed()
        rig.properties = ["RMNetState": "up"]
        s.poll()
        equal(s.headline, "Connected", "headline: the registry's once the answer is dropped")
        // No driver: asking until the system answers; Unknown while it gives no listing.
        rig.properties = nil
        rig.modem = (.absent, nil)
        s.poll()
        equal(s.headline, "Asking the system…", "headline: no driver, before the listing answers")
        rig.listing.answerWaiting(nil)
        equal(s.headline, "Unknown", "headline: no driver, the system gave no listing")
        rig.listing.holding = false

        // The panel open (the listing asked on each poll), each state with its answer.
        rig.open()
        let cases: [(DriverProperties?, ModemState, [ExtensionEntry], String)] = [
            (nil, .absent, [], "Not installed"),
            (nil, .absent, [awaiting], "Waiting for approval in System Settings"),
            (nil, .absent, [enabled], "Installed, modem not attached"),
            (nil, .notQMI, [enabled], "Modem is not in QMI mode"),
            (nil, .qmi(interface: 4), [enabled], "Connecting"),
            (["RMNetState": "connecting"], .qmi(interface: 4), [enabled], "Connecting"),
            (["RMNetState": "backoff"], .qmi(interface: 4), [enabled], "Link down"),
            (["RMNetState": "up"], .qmi(interface: 4), [enabled], "Connected"),
            (["RMNetState": "up"], .qmi(interface: 4), [enabled, awaiting], "Needs attention"),
        ]
        for (props, modem, entries, want) in cases {
            rig.properties = props
            if case .absent = modem { rig.modem = (modem, nil) } else { rig.modem = (modem, rm520) }
            rig.listing.answer = entries
            s.poll()
            equal(s.headline, want, "headline: \(want)")
        }
        s.panelClosed()

        // The rule itself.
        for (state, want) in [("up", "Connected"), ("refreshing", "Connected"), ("starting", "Connecting"),
                              ("connecting", "Connecting"), ("backoff", "Link down"), ("usb failed", "Link down")] {
            equal(menuBarHeadline(driver: ["RMNetState": state], modem: .qmi(interface: 4), model: rm520, answered: false,
                                  entries: nil), want, "rule: attached, not answered, \(state)")
        }
        equal(menuBarHeadline(driver: ["RMNetState": "up"], modem: .qmi(interface: 4), model: rm520, answered: true,
                              entries: nil), "Connected", "rule: attached, no listing: the registry's")
        equal(menuBarHeadline(driver: ["RMNetState": "up"], modem: .qmi(interface: 4), model: rm520, answered: true,
                              entries: [enabled, awaiting]), "Needs attention", "rule: attached, the listing's")
        equal(menuBarHeadline(driver: nil, modem: .absent, model: nil, answered: false, entries: nil), "Asking the system…",
              "rule: no driver, not answered")
        equal(menuBarHeadline(driver: nil, modem: .absent, model: nil, answered: true, entries: nil), "Unknown",
              "rule: no driver, no listing")
        equal(menuBarHeadline(driver: nil, modem: .absent, model: nil, answered: true, entries: [awaiting]),
              "Waiting for approval in System Settings", "rule: no driver, the listing's")
    }

    // The addresses only while the connection is up: the address and its prefix (not the gateway); "none" and
    // an empty value are left out.
    static func addresses() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [enabled]
        rig.modem = (.qmi(interface: 4), rm520)
        rig.properties = upProperties
        s.poll()
        equal(s.addressLines, ["IPv4 10.62.238.140/29", "IPv6 2001:db8:1:2::1/64"], "addresses: up")
        rig.properties = ["RMNetState": "refreshing", "RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141", "RMNetIPv6": "none"]
        s.poll()
        equal(s.addressLines, ["IPv4 10.62.238.140/29"], "addresses: no IPv6")
        rig.properties = ["RMNetState": "up", "RMNetIPv4": "none", "RMNetIPv6": ""]
        s.poll()
        equal(s.addressLines, [], "addresses: none given")
        var down = upProperties
        down["RMNetState"] = "backoff"
        rig.properties = down
        s.poll()
        equal(s.addressLines, [], "addresses: none while down, even when properties hold some")
        rig.properties = nil
        s.poll()
        equal(s.addressLines, [], "addresses: none without the driver")
    }

    // poll() reads the registry each time and never reads the network, also over many turns. With the driver
    // attached and the panel closed it never asks the listing; with no driver it asks at once (no fresh answer:
    // at launch, or once the driver has gone away) and then on every 12th poll, about once a minute.
    static func polling() {
        let rig = Rig()
        let s = rig.status!
        rig.properties = upProperties
        for _ in 0..<20 {
            s.poll()
            rig.clock = rig.clock.addingTimeInterval(5)
        }
        equal(rig.listing.asked, 0, "poll: the listing is not asked with the driver attached")
        rig.properties = nil
        var askedAt: [Int] = []
        for n in 1...25 {
            let before = rig.listing.asked
            s.poll()
            if rig.listing.asked > before { askedAt.append(n) }
            rig.clock = rig.clock.addingTimeInterval(5)
        }
        settle()
        equal(askedAt, [1, 13, 25], "poll: with no driver, the listing at once, then on every 12th poll")
        equal(rig.network.calls, 0, "poll: never reads the network")
        equal(rig.registryReads, 45, "poll: reads the registry each time")
        equal(MenuBarStatus.pollInterval, 5, "poll: every 5 s")
        equal(MenuBarStatus.listingEvery, 12, "poll: the listing every 12th poll with no driver: once a minute")
        equal(MenuBarStatus.networkSpacing, 10, "network: at most once in 10 s")
        check(!s.reading, "poll: nothing is being read")
        equal(s.networkLines, [], "poll: no network lines")
        check(s.networkAt == nil && s.networkNote == nil, "poll: no network time or note")

        // A question still pending when the 12th poll comes: not asked twice; the next poll asks.
        let slow = Rig()
        let t = slow.status!
        slow.listing.holding = true
        t.poll()
        equal(slow.listing.asked, 1, "poll: asked at launch with no driver")
        for _ in 0..<12 { t.poll() }
        equal(slow.listing.asked, 1, "poll: not asked again while the question is pending")
        slow.listing.answerWaiting([])
        t.poll()
        equal(slow.listing.asked, 2, "poll: asked on the next poll once the pending question has answered")
        slow.listing.answerWaiting([])
        slow.listing.holding = false
    }

    // start() polls at once (the listing asked at launch while no driver is attached), then every 5 s on a timer
    // that may fire up to 1 s late (its tolerance, so the system can group wake-ups); a second start does nothing.
    static func starting() {
        let rig = Rig()
        let s = rig.status!
        s.start()
        equal(rig.registryReads, 1, "start: polls at once")
        equal(rig.listing.asked, 1, "start: asks the listing at launch with no driver")
        let timer = Mirror(reflecting: s).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
        check(timer != nil && timer!.isValid, "start: a timer runs")
        equal(timer?.timeInterval, 5, "start: every 5 s")
        equal(timer?.tolerance, 1, "start: up to 1 s late")
        s.start()
        equal(rig.registryReads, 1, "start: a second start does nothing")
        timer?.invalidate()
    }

    // The listing (the system's properties request) is asked only when needed: while the panel is open (its
    // headline), and while the registry shows no driver (no driver, or waiting for approval?) at once and then
    // every 12th poll. With the driver attached and the panel closed, a poll reads the registry only. Opening the
    // panel asks it at once.
    static func listingWhenNeeded() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [enabled]
        rig.properties = upProperties
        s.poll()
        s.poll()
        equal(rig.listing.asked, 0, "listing: not asked with the driver attached and the panel closed")
        rig.properties = nil
        s.poll()
        equal(rig.listing.asked, 1, "listing: asked at once when no driver is attached")
        rig.listing.answer = [awaiting]
        for _ in 0..<11 { s.poll() }
        equal(rig.listing.asked, 1, "listing: not asked on the next 11 polls with no driver")
        equal(s.icon, .noDriver, "listing: the last answer is kept until the next question")
        s.poll()
        equal(rig.listing.asked, 2, "listing: asked again on the 12th poll")
        equal(s.icon, .waitingForApproval, "listing: tells waiting for approval apart")
        rig.listing.answer = [enabled]
        rig.properties = upProperties
        s.poll()
        equal(rig.listing.asked, 2, "listing: not asked once the driver is attached")
        equal(s.headline, "Connected", "listing: an answer not asked again is stale: the registry's headline, not its own")

        rig.open()
        equal(rig.listing.asked, 3, "listing: asked when the panel opens")
        equal(s.headline, "Connected", "listing: the panel's headline is fresh")
        s.poll()
        s.poll()
        equal(rig.listing.asked, 5, "listing: asked on each poll while the panel is open")
        // Opened again within 10 s: no network read, but the listing is asked all the same.
        rig.open()
        equal(rig.listing.asked, 6, "listing: asked again when the panel opens again")
        equal(rig.network.calls, 1, "listing: the network was read once")
        s.panelClosed()
        s.poll()
        s.poll()
        equal(rig.listing.asked, 6, "listing: not asked once the panel is closed")
        s.panelClosed()
        equal(rig.listing.asked, 6, "listing: closing twice is harmless")

        // With no driver and the panel open: asked on each poll, not only every 12th.
        rig.properties = nil
        s.poll()
        equal(rig.listing.asked, 7, "listing: asked at once when the driver has gone away")
        rig.open()
        s.poll()
        s.poll()
        equal(rig.listing.asked, 10, "listing: asked on each poll while the panel is open, also with no driver")
        s.panelClosed()
        s.poll()
        equal(rig.listing.asked, 10, "listing: then every 12th poll again")
    }

    // A listing that was not asked again (the driver attached, the panel closed) is stale: when the driver goes
    // away the icon is `.noDriver` until a fresh listing says that the system waits for approval, never the old
    // answer's `.waitingForApproval`. Its headline asks the system again too.
    static func staleListing() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [awaiting]
        s.poll()
        equal(s.icon, .waitingForApproval, "stale: waiting for approval, no driver")
        rig.listing.answer = [enabled]
        rig.properties = ["RMNetState": "up"]
        s.poll()
        equal(s.icon, .up, "stale: the driver attached and up")
        equal(rig.listing.asked, 1, "stale: not asked with the driver attached")

        rig.listing.holding = true
        rig.properties = nil
        s.poll()
        equal(rig.listing.asked, 2, "stale: asked once the driver is gone")
        equal(s.icon, .noDriver, "stale: no driver until the fresh answer, not the old waiting for approval")
        equal(s.headline, "Asking the system…", "stale: the headline asks again")
        rig.listing.answerWaiting([awaiting])
        equal(s.icon, .waitingForApproval, "stale: the fresh answer says waiting")
        equal(s.headline, "Waiting for approval in System Settings", "stale: and its headline")

        // A question asked while no driver was attached (the 12th poll), answered after it attached: still the
        // latest answer, and its headline is used.
        rig.properties = nil
        for _ in 0..<MenuBarStatus.listingEvery { s.poll() }
        equal(rig.listing.asked, 3, "stale: the 12th poll with no driver asks")
        rig.properties = ["RMNetState": "up"]
        s.poll()
        rig.listing.answerWaiting([enabled, awaiting])
        equal(s.headline, "Needs attention", "stale: an answer to a question already asked is used")
        rig.listing.holding = false
    }

    // The panel's window events: shown only while on screen, and never on resigning key (the panel resigns key
    // as it closes, while it may still be on screen, and no read may start then); hidden when it is off screen
    // or the view left it.
    static func panelSignals() {
        let cases: [(MenuBarPanelEvent, Bool, MenuBarPanelSignal?)] = [
            (.attached, true, .shown), (.attached, false, .hidden),
            (.detached, true, .hidden), (.detached, false, .hidden),
            (.becameKey, true, .shown), (.becameKey, false, nil),
            (.resignedKey, true, nil), (.resignedKey, false, .hidden),
            (.occlusionChanged, true, .shown), (.occlusionChanged, false, .hidden),
        ]
        for (event, onScreen, want) in cases {
            equal(menuBarPanelSignal(event, onScreen: onScreen), want, "panel signal: \(event), on screen \(onScreen)")
        }
    }

    // Opening the panel reads the network once, on the model's queue; opening it again less than 10 s after
    // that read finished reads nothing; 10 s after, it reads again. The registry is read too (the panel shows
    // the latest headline).
    static func throttle() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [enabled]
        rig.properties = upProperties
        rig.network.answer(.success(saInfo))
        let reads = rig.registryReads
        rig.open()
        equal(rig.network.calls, 1, "panel: one read when it opens")
        equal(rig.network.callsOffQueue, 0, "panel: the read runs on the model's queue")
        check(rig.registryReads > reads, "panel: the registry is read when it opens")
        equal(s.networkAt, rig.clock, "panel: the time of the read")
        equal(s.networkLines, ["5G SA, band n41", "CHINA MOBILE, PLMN 46000", "RSRP -86 dBm, SINR 10 dB"],
              "panel: the network lines")
        check(s.networkNote == nil, "panel: no note after a read that succeeded")
        let first = rig.clock

        for later in [0.0, 1, 5, 9.9] {
            rig.clock = first.addingTimeInterval(later)
            rig.open()
            settle()
            equal(rig.network.calls, 1, "panel: no read \(later) s after the last")
        }
        equal(s.networkAt, first, "panel: the time stays that of the read")

        rig.clock = first.addingTimeInterval(10)
        rig.network.answer(.success(saInfo))
        rig.open()
        equal(rig.network.calls, 2, "panel: a read 10 s after the last")
        equal(s.networkAt, first.addingTimeInterval(10), "panel: the new read's time")

        // The 10 s count from when a read finished, also a read that failed.
        rig.clock = first.addingTimeInterval(30)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.busy))))
        rig.open()
        equal(rig.network.calls, 3, "panel: a read 20 s later")
        rig.clock = first.addingTimeInterval(35)
        rig.open()
        settle()
        equal(rig.network.calls, 3, "panel: no read 5 s after a busy one")

        // A clock set back does not stop the reads for good.
        rig.clock = first.addingTimeInterval(-3600)
        rig.network.answer(.success(saInfo))
        rig.open()
        equal(rig.network.calls, 4, "panel: a read after the clock went back")
    }

    // While a read runs, opening the panel again starts no other; `reading` says one runs.
    static func oneReadAtATime() {
        let rig = Rig()
        let s = rig.status!
        rig.network.holding = true
        s.panelOpened()
        pump(until: { rig.network.calls == 1 }, "the read to start")
        check(s.reading, "reading: true while the read runs")
        rig.clock = rig.clock.addingTimeInterval(60)
        s.panelOpened()
        s.panelOpened()
        settle()
        equal(rig.network.calls, 1, "reading: no second read while one runs")
        rig.network.release(.success(saInfo))
        pump(until: { !s.reading }, "the read to finish")
        equal(s.networkAt, rig.clock, "reading: finished at the clock's time")
        equal(rig.network.calls, 1, "reading: still one read")
    }

    // A busy port says so, and keeps the lines of the last read with their time; a modem not attached says so
    // and clears them; another failure gives its sentence and keeps them. A read that succeeds clears the note.
    static func notes() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [enabled]
        rig.properties = upProperties
        rig.network.answer(.success(saInfo))
        rig.open()
        let readAt = rig.clock
        let lines = s.networkLines

        rig.clock = rig.clock.addingTimeInterval(10)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.busy))))
        rig.open()
        equal(s.networkNote, "The modem's AT port is busy; open the panel again in a moment.", "note: busy")
        equal(s.networkLines, lines, "note: busy keeps the last lines")
        equal(s.networkAt, readAt, "note: busy keeps their time")
        equal(s.icon, .up, "note: busy does not hide the connection state")
        equal(s.headline, "Connected", "note: busy does not change the headline")

        rig.clock = rig.clock.addingTimeInterval(10)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.timeout))))
        rig.open()
        equal(s.networkNote, "The network could not be read. The modem did not answer in time.", "note: a failure")
        equal(s.networkLines, lines, "note: a failure keeps the last lines")
        equal(s.networkAt, readAt, "note: a failure keeps their time")

        rig.clock = rig.clock.addingTimeInterval(10)
        rig.network.answer(.success(saInfo))
        rig.open()
        check(s.networkNote == nil, "note: cleared by a read that succeeded")
        equal(s.networkAt, rig.clock, "note: the new time")

        rig.clock = rig.clock.addingTimeInterval(10)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.modemNotAttached))))
        rig.open()
        equal(s.networkNote, "The RM520N-GL (USB 2c7c:0801) is not attached.", "note: not attached")
        equal(s.networkLines, [], "note: not attached clears the lines")
        check(s.networkAt == nil, "note: not attached clears their time")
    }

    // The notes from the real ModemService, whose port does not open (busy, not attached): the wording the
    // model recognizes is the service's own. No port is opened.
    static func realServiceWording() {
        for (error, want) in [(AtError.busy, "The modem's AT port is busy; open the panel again in a moment."),
                              (.modemNotAttached, "The RM520N-GL (USB 2c7c:0801) is not attached."),
                              (.noAtInterface, "The network could not be read. The modem has no spare AT port.")] {
            let service = ModemService(open: { .failure(error) }, sleep: { _ in }, now: { Date() })
            let rig = Rig(network: { service.networkInfo() })
            rig.open()
            equal(rig.status.networkNote, want, "service: \(error)")
        }
    }

    // The lines from a read: the technology with its band(s), the operator as `RMNet network` gives it, and the
    // signal (RSRP and SINR) once a leg, named on EN-DC.
    static func networkLines() {
        equal(menuBarNetworkLines(saInfo), ["5G SA, band n41", "CHINA MOBILE, PLMN 46000", "RSRP -86 dBm, SINR 10 dB"],
              "lines: 5G SA")

        var nsa = NetworkInfo(radio: .on, operatorName: "CMCC", networkName: "CHINA MOBILE", plmn: "46000")
        nsa.serving = ServingCell(state: "CONNECT", cells: [leg("LTE", band: "B3", rsrp: -95, sinr: 8.5),
                                                            leg("NR5G-NSA", band: "n78", rsrp: -88, sinr: 12)])
        nsa.carriers = ["B3"]
        equal(menuBarNetworkLines(nsa), ["5G NSA, bands B3 + n78", "CMCC (CHINA MOBILE), PLMN 46000",
                                         "LTE: RSRP -95 dBm, SINR 8.5 dB", "5G: RSRP -88 dBm, SINR 12 dB"],
              "lines: 5G NSA")

        var ca = saInfo
        ca.carriers = ["n41", "n28"]
        equal(menuBarNetworkLines(ca)[0], "5G SA, bands n41 + n28 (carrier aggregation)", "lines: carrier aggregation")

        var wcdma = NetworkInfo(radio: .on, operatorName: "CHINA UNICOM")
        wcdma.serving = ServingCell(state: "NOCONN", cells: [CellLeg(rat: "WCDMA", duplex: nil, mcc: "460", mnc: "01",
            cellID: "1", pci: 2, tac: "3", channel: 10700, band: nil, bandwidthMHz: nil, rsrp: -80, rsrq: nil, sinr: nil)])
        equal(menuBarNetworkLines(wcdma), ["WCDMA", "CHINA UNICOM, PLMN 46001", "RSCP -80 dBm"], "lines: WCDMA")

        let searching = NetworkInfo(radio: .on, serving: ServingCell(state: "SEARCH", cells: []))
        equal(menuBarNetworkLines(searching), ["Searching"], "lines: searching")
        let limited = NetworkInfo(radio: .on, serving: ServingCell(state: "LIMSRV", cells: []))
        equal(menuBarNetworkLines(limited), ["Limited service"], "lines: limited service")
        var off = saInfo
        off.radio = .airplane
        equal(menuBarNetworkLines(off)[0], "Radio off (airplane mode)", "lines: radio off")
        equal(menuBarNetworkLines(NetworkInfo()), ["Technology unknown"], "lines: nothing read")

        var noSignal = saInfo
        noSignal.serving = ServingCell(state: "NOCONN", cells: [leg("NR5G-SA", band: "n41", rsrp: nil, sinr: nil)])
        equal(menuBarNetworkLines(noSignal), ["5G SA, band n41", "CHINA MOBILE, PLMN 46000"], "lines: no signal read")
    }

    // "as of HH:mm:ss" in the Mac's time zone.
    static func asOf() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 16, 9, 5, 7)
        let date = Calendar.current.date(from: c)!
        equal(asOfText(date), "as of 09:05:07", "as of")
    }

    // The last read's NetworkInfo (the panel's badge, bars and band), from the same read as the lines and kept and
    // cleared exactly as they are: nil before any read and on polls; set by a read that succeeded; unchanged when
    // the panel opens again within 10 s (no read) and while a read runs; kept by a busy port and by another
    // failure; replaced by the next read that succeeds; cleared with the lines when the modem is not attached.
    static func readInfo() {
        let rig = Rig()
        let s = rig.status!
        rig.listing.answer = [enabled]
        rig.properties = upProperties
        check(s.info == nil, "info: nil before any read")
        s.poll()
        check(s.info == nil, "info: a poll reads no network")

        rig.network.answer(.success(saInfo))
        rig.open()
        equal(s.info, saInfo, "info: set by a read that succeeded")
        equal(s.networkLines, menuBarNetworkLines(saInfo), "info: from the read that set the lines")
        let first = rig.clock

        // Opened again within 10 s: no read, nothing changes.
        rig.clock = first.addingTimeInterval(5)
        rig.open()
        settle()
        equal(rig.network.calls, 1, "info: no read 5 s after the last")
        equal(s.info, saInfo, "info: unchanged without a read")

        // A busy port and another failure keep it, with the lines.
        rig.clock = first.addingTimeInterval(10)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.busy))))
        rig.open()
        equal(s.networkNote, menuBarBusyNote, "info: the busy read was made")
        equal(s.info, saInfo, "info: kept by a busy port")
        equal(s.networkLines, menuBarNetworkLines(saInfo), "info: the lines kept with it")
        rig.clock = first.addingTimeInterval(20)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.timeout))))
        rig.open()
        equal(s.networkNote, "The network could not be read. The modem did not answer in time.",
              "info: the failed read was made")
        equal(s.info, saInfo, "info: kept by a read that failed")
        equal(s.networkLines, menuBarNetworkLines(saInfo), "info: the lines kept with it after a failure")

        // The next read that succeeds replaces it; while that read runs, the last one stays.
        var nsa = NetworkInfo(radio: .on, operatorName: "CMCC", networkName: "CHINA MOBILE", plmn: "46000")
        nsa.serving = ServingCell(state: "CONNECT", cells: [leg("LTE", band: "B3", rsrp: -95, sinr: 8.5),
                                                            leg("NR5G-NSA", band: "n78", rsrp: -88, sinr: 12)])
        nsa.carriers = ["B3"]
        rig.clock = first.addingTimeInterval(30)
        rig.network.holding = true
        s.panelOpened()
        pump(until: { rig.network.calls == 4 }, "the read to start")
        check(s.reading, "info: a read runs")
        equal(s.info, saInfo, "info: the last one while a read runs")
        rig.network.release(.success(nsa))
        pump(until: { !s.reading }, "the read to finish")
        rig.network.holding = false
        equal(s.info, nsa, "info: replaced by the next read that succeeded")
        equal(s.networkLines, menuBarNetworkLines(nsa), "info: with its lines")
        check(s.networkNote == nil, "info: and no note")

        // The modem not attached: cleared with the lines and their time.
        rig.clock = first.addingTimeInterval(40)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.modemNotAttached))))
        rig.open()
        check(s.info == nil, "info: cleared when the modem is not attached")
        equal(s.networkLines, [], "info: as the lines are")
        check(s.networkAt == nil, "info: and their time")
        rig.clock = first.addingTimeInterval(50)
        rig.network.answer(.failure(ModemFailure(message: describe(AtError.busy))))
        rig.open()
        check(s.info == nil, "info: a busy read keeps none when there was none")

        // It comes back with the next read that succeeds; one read per opening throughout.
        rig.clock = first.addingTimeInterval(60)
        rig.network.answer(.success(saInfo))
        rig.open()
        equal(s.info, saInfo, "info: set again by a read that succeeded")
        equal(rig.network.calls, 7, "info: one read per opening, not within 10 s")
    }

    // MARK: The signal bars

    /// The style is kept in the user defaults under menuBarIconStyle; unset or unknown reads as the antenna.
    static func iconStyle() {
        let suite = "io.rmnetdriver.RMNet.tests.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = MenuBarIconPreference(defaults: defaults)
        equal(preference.load(), .antenna, "style: unset is the antenna")
        preference.save(.signal)
        equal(defaults.string(forKey: "menuBarIconStyle"), "signal", "style: kept under menuBarIconStyle")
        equal(preference.load(), .signal, "style: read back")
        defaults.set("rainbow", forKey: "menuBarIconStyle")
        equal(preference.load(), .antenna, "style: an unknown value is the antenna")
        equal(MenuBarIconStyle.allCases.map { $0.title }, ["Antenna", "Signal bars"], "style: titles")
        check(preference.loadShowsTechnology(), "technology: unset shows it")
        preference.saveShowsTechnology(false)
        equal(defaults.object(forKey: "menuBarShowsTechnology") as? Bool, false, "technology: kept under menuBarShowsTechnology")
        check(!preference.loadShowsTechnology(), "technology: read back off")
        defaults.set("maybe", forKey: "menuBarShowsTechnology")
        check(preference.loadShowsTechnology(), "technology: a value not a Bool shows it")

        // The model reads it at once, and setIconStyle keeps it.
        preference.save(.signal)
        let s = MenuBarStatus(properties: { nil }, modem: { (.absent, nil) }, listing: { $0([]) },
                              network: { .failure(ModemFailure(message: "x")) }, queue: DispatchQueue(label: queueName),
                              preference: preference)
        equal(s.iconStyle, .signal, "style: read when the model is made")
        s.setIconStyle(.antenna)
        equal(s.iconStyle, .antenna, "style: set")
        equal(preference.load(), .antenna, "style: set is kept")
        preference.saveShowsTechnology(false)
        let off = MenuBarStatus(properties: { nil }, modem: { (.absent, nil) }, listing: { $0([]) },
                                network: { .failure(ModemFailure(message: "x")) }, queue: DispatchQueue(label: queueName),
                                preference: preference)
        check(!off.showsTechnology, "technology: read when the model is made")
        off.setShowsTechnology(true)
        check(off.showsTechnology && preference.loadShowsTechnology(), "technology: set and kept")
        let none = MenuBarStatus(properties: { nil }, modem: { (.absent, nil) }, listing: { $0([]) },
                                 network: { .failure(ModemFailure(message: "x")) }, queue: DispatchQueue(label: queueName))
        equal(none.iconStyle, .antenna, "style: without a preference, the antenna")
    }

    /// What a read gives the bars, which command comes next, and what a failure keeps.
    static func signalModel() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func serving(_ state: String, _ legs: [CellLeg]) -> NetworkInfo {
            NetworkInfo(serving: ServingCell(state: state, cells: legs))
        }
        let sa = serving("NOCONN", [leg("NR5G-SA", band: "n41", rsrp: -86, sinr: 10)])
        equal(menuBarSignal(from: sa, at: t), MenuBarSignal(level: 3, technology: "5G", service: .normal, at: t),
              "signal: 5G SA from the serving cell alone")
        let lte = serving("CONNECT", [leg("LTE", band: "B3", rsrp: -112, sinr: 2)])
        equal(menuBarSignal(from: lte, at: t), MenuBarSignal(level: 0, technology: "LTE", service: .normal, at: t),
              "signal: LTE, no bars")
        let endc = serving("CONNECT", [leg("LTE", band: "B3", rsrp: -95, sinr: 8), leg("NR5G-NSA", band: "n78", rsrp: -80, sinr: 20)])
        equal(menuBarSignal(from: endc, at: t).technology, "5G", "signal: EN-DC is 5G")
        equal(menuBarSignal(from: serving("SEARCH", []), at: t),
              MenuBarSignal(level: 0, technology: nil, service: .searching, at: t), "signal: searching")
        equal(menuBarSignal(from: serving("LIMSRV", []), at: t).service, .searching, "signal: limited service")
        equal(menuBarSignal(from: serving("NOCONN", []), at: t).service, .searching, "signal: no leg")
        equal(menuBarSignal(from: NetworkInfo(radio: .airplane), at: t),
              MenuBarSignal(level: 0, technology: nil, service: .radioOff, at: t), "signal: airplane mode")
        equal(menuBarSignal(from: NetworkInfo(radio: .minimum), at: t).service, .radioOff, "signal: minimum functionality")
        equal(menuBarSignal(from: NetworkInfo(radio: .on), at: t),
              MenuBarSignal(level: 0, technology: nil, service: .searching, at: t), "signal: a radio read that says on")
        equal(menuBarSignal(from: NetworkInfo(), at: t),
              MenuBarSignal(level: nil, technology: nil, service: .normal, at: t), "signal: nothing read")
        let unknownRsrp = serving("NOCONN", [leg("NR5G-SA", band: "n41", rsrp: nil, sinr: nil)])
        equal(menuBarSignal(from: unknownRsrp, at: t).level, nil, "signal: a leg without RSRP is not known")
        equal(menuBarSignal(from: saInfo, at: t).level, 3, "signal: a full read")

        // One command a read: the serving cell, the radio while it is off, both in turn while searching.
        let normal = MenuBarSignal(level: 3, technology: "5G", service: .normal, at: t)
        let searching = MenuBarSignal(level: 0, technology: nil, service: .searching, at: t)
        let off = MenuBarSignal(level: 0, technology: nil, service: .radioOff, at: t)
        equal(nextSignalQuery(previous: nil, lastQuery: nil), .servingCell, "query: first")
        equal(nextSignalQuery(previous: normal, lastQuery: .servingCell), .servingCell, "query: with service")
        equal(nextSignalQuery(previous: off, lastQuery: .radio), .radio, "query: radio off")
        equal(nextSignalQuery(previous: searching, lastQuery: .servingCell), .radio, "query: searching, then the radio")
        equal(nextSignalQuery(previous: searching, lastQuery: .radio), .servingCell, "query: searching, then the cell")

        // A busy port or no answer keeps the level, stale; the modem gone clears it.
        var stale = normal
        stale.stale = true
        equal(menuBarSignal(after: ModemFailure(message: describe(AtError.busy)), previous: normal), stale, "failure: busy keeps")
        equal(menuBarSignal(after: ModemFailure(message: "No answer in 3 s."), previous: normal), stale, "failure: timeout keeps")
        check(menuBarSignal(after: ModemFailure(message: describe(AtError.modemNotAttached)), previous: normal) == nil,
              "failure: the modem gone clears")
        check(menuBarSignal(after: ModemFailure(message: describe(AtError.busy)), previous: nil) == nil,
              "failure: nothing to keep")
    }

    /// The icon for each state: every one told apart, and the antenna's label first in what VoiceOver says.
    static func signalIcons() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let good = MenuBarSignal(level: 3, technology: "5G", service: .normal, at: t)
        equal(menuBarSignalIcon(.up, good, now: t),
              MenuBarSignalIcon(bars: .filled(3), text: "5G", accessibilityLabel: "RMNet: connected, 3 of 4 bars, 5G"),
              "icon: connected")
        equal(menuBarSignalIcon(.down, good, now: t),
              MenuBarSignalIcon(bars: .filled(3), mark: .slash, accessibilityLabel: "RMNet: not connected, 3 of 4 bars"),
              "icon: not connected, with signal")
        equal(menuBarSignalIcon(.noDriver, good, now: t),
              MenuBarSignalIcon(bars: .outlined, mark: .slash, accessibilityLabel: "RMNet: no driver"), "icon: no driver")
        equal(menuBarSignalIcon(.waitingForApproval, nil, now: t),
              MenuBarSignalIcon(bars: .outlined, mark: .exclamation, accessibilityLabel: "RMNet: waiting for approval"),
              "icon: waiting for approval")
        equal(menuBarSignalIcon(.down, MenuBarSignal(level: 0, technology: nil, service: .radioOff, at: t), now: t),
              MenuBarSignalIcon(bars: .filled(0), airplane: true, accessibilityLabel: "RMNet: not connected, radio off"),
              "icon: radio off")
        equal(menuBarSignalIcon(.down, MenuBarSignal(level: 0, technology: nil, service: .searching, at: t), now: t),
              MenuBarSignalIcon(bars: .filled(0), mark: .ellipsis, accessibilityLabel: "RMNet: not connected, searching"),
              "icon: searching")
        equal(menuBarSignalIcon(.up, nil, now: t),
              MenuBarSignalIcon(bars: .outlined, accessibilityLabel: "RMNet: connected, signal not known"),
              "icon: connected, nothing read yet")
        equal(menuBarSignalIcon(.down, nil, now: t),
              MenuBarSignalIcon(bars: .filled(0), mark: .slash, accessibilityLabel: "RMNet: not connected, signal not known"),
              "icon: not connected, nothing read yet")
        equal(menuBarSignalIcon(.up, MenuBarSignal(level: nil, technology: "LTE", service: .normal, at: t), now: t),
              MenuBarSignalIcon(bars: .outlined, text: "LTE", accessibilityLabel: "RMNet: connected, signal not known, LTE"),
              "icon: connected, level not known")

        var stale = good
        stale.stale = true
        let dimmed = menuBarSignalIcon(.up, stale, now: t)
        check(dimmed.dimmed && dimmed.bars == .filled(3), "icon: stale keeps its bars, dimmed")
        equal(dimmed.accessibilityLabel, "RMNet: connected, 3 of 4 bars, 5G, not current", "icon: stale is said")
        check(!menuBarSignalIcon(.up, good, now: t.addingTimeInterval(44)).dimmed, "icon: 44 s old is current")
        check(menuBarSignalIcon(.up, good, now: t.addingTimeInterval(46)).dimmed, "icon: 46 s old is dimmed")
        // Without the technology: the bars alone, and VoiceOver still hears it.
        equal(menuBarSignalIcon(.up, good, now: t, showsTechnology: false),
              MenuBarSignalIcon(bars: .filled(3), text: nil, accessibilityLabel: "RMNet: connected, 3 of 4 bars, 5G"),
              "icon: connected, technology hidden")
        equal(menuBarSignalIcon(.waitingForApproval, nil, now: t, showsTechnology: false).mark, .exclamation,
              "icon: the marks stay without the technology")
        equal(menuBarSignalIcon(.down, MenuBarSignal(level: 0, technology: nil, service: .searching, at: t), now: t,
                                showsTechnology: false).mark, .ellipsis, "icon: searching keeps its ellipsis")
        // The antenna's labels are unchanged.
        equal(MenuBarIcon.up.accessibilityLabel, "RMNet: connected", "antenna: label kept")
    }

    /// The reads, all in the background turn (the bars have no timer of their own): only with the bars chosen and the
    /// driver attached; the window's fresh read instead of one of the bars' own; one command a turn; a busy port, or a
    /// turn that ended before the bars' command (a timeout on an earlier one), keeps the bars, stale.
    static func signalPolling() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var properties: DriverProperties? = upProperties
        var fresh: (info: NetworkInfo, at: Date)? = nil
        let suite = "io.rmnetdriver.RMNet.tests.poll.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = DispatchQueue(label: queueName)
        let s = MenuBarStatus(
            properties: { properties }, modem: { (.qmi(interface: 4), rm520) }, listing: { $0([enabled]) },
            network: { .success(saInfo) }, now: { clock }, queue: queue,
            freshInfo: { fresh },
            preference: MenuBarIconPreference(defaults: defaults))
        var asked: [[String]] = []
        // One background turn: the bars' command, if they want one, and the turn's answer to it.
        func turn(_ answer: (String) -> Result<[String: PulseAnswer], ModemFailure>) {
            let commands = s.pulseSignalCommands()
            guard !commands.isEmpty else { return }
            asked.append(commands)
            s.pulseSignalAnswers(answer(commands[0]))
        }
        func lines(_ l: [String]) -> (String) -> Result<[String: PulseAnswer], ModemFailure> {
            { command in .success([command: .lines(l)]) }
        }
        let sa = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",001,01,FEDCBA987,32,00F00D,504990,41,12,-86,-10,10,1,-"
        s.poll()

        // The antenna: no read.
        turn(lines([sa]))
        equal(asked.count, 0, "turn: the antenna reads nothing")

        // The bars: the serving cell.
        s.setIconStyle(.signal)
        turn(lines([sa]))
        equal(asked, [["AT+QENG=\"servingcell\""]], "turn: one serving-cell read")
        equal(s.signal, MenuBarSignal(level: 3, technology: "5G", service: .normal, at: clock), "turn: the bars")
        equal(s.signalIcon.bars, .filled(3), "turn: drawn")
        equal(s.signalIcon.text, "5G", "turn: with the technology")
        s.setShowsTechnology(false)
        check(s.signalIcon.text == nil && s.signalIcon.bars == .filled(3), "turn: the technology turned off at once")
        equal(asked.count, 1, "turn: turning it off reads nothing")
        s.setShowsTechnology(true)

        // A busy port: the bars kept, stale.
        clock = clock.addingTimeInterval(15)
        turn { _ in .failure(ModemFailure(message: describe(AtError.busy))) }
        check(s.signal?.stale == true && s.signal?.level == 3, "turn: busy keeps the level, stale")
        check(s.signalIcon.dimmed, "turn: busy dims the bars")

        // A turn that ended before the bars' command (another rider's command timed out first): kept, stale.
        turn(lines([sa]))
        equal(s.signal?.stale, false, "turn: an answer is current again")
        turn { _ in .success(["AT+CPMS?": .lines(["+CPMS: \"ME\",1,255,\"ME\",1,255,\"ME\",1,255"])]) }
        check(s.signal?.stale == true && s.signal?.level == 3, "turn: no answer to the bars' command keeps the level, stale")
        // A refusal is an answer: the serving cell not known.
        turn { command in .success([command: .refused("ERROR")]) }
        check(s.signal?.stale == false && s.signal?.level == nil, "turn: a refusal leaves the level unknown")

        // The window's fresh read stands in: no read of the bars' own; then a fresh success is current.
        fresh = (saInfo, clock.addingTimeInterval(-3))
        let before = asked.count
        turn(lines([sa]))
        equal(asked.count, before, "turn: the window's fresh read, no port")
        equal(s.signal?.stale, false, "turn: the fresh read is current")
        equal(s.signal?.level, 3, "turn: the fresh read's level")
        fresh = (saInfo, clock.addingTimeInterval(-16))
        turn(lines(["+QENG: \"servingcell\",\"SEARCH\""]))
        equal(asked.count, before + 1, "turn: an old window read does not count")
        equal(s.signal?.service, .searching, "turn: searching")

        // Searching: next the radio, which says it is off.
        turn(lines(["+CFUN: 4"]))
        equal(asked.last, ["AT+CFUN?"], "turn: searching asks the radio")
        check(s.signalIcon.airplane, "turn: an airplane")

        // No driver: no read.
        properties = nil
        s.poll()
        let quiet = asked.count
        turn(lines([sa]))
        equal(asked.count, quiet, "turn: no driver, no read")
        equal(s.signalIcon.mark, .slash, "turn: no driver is struck through")

        // Back to the antenna: turns read nothing.
        properties = upProperties
        s.poll()
        s.setIconStyle(.antenna)
        turn(lines([sa]))
        equal(asked.count, quiet, "turn: the antenna again, no read")
    }

    /// The signal bars ride the background turn: the command they want, then its answers.
    static func pulseSignal() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = "io.rmnetdriver.RMNet.tests.pulse.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = DispatchQueue(label: queueName)
        let s = MenuBarStatus(properties: { upProperties }, modem: { (.qmi(interface: 4), rm520) }, listing: { $0([enabled]) },
                              network: { .success(saInfo) }, now: { clock }, queue: queue,
                              preference: MenuBarIconPreference(defaults: defaults))
        s.poll()
        equal(s.pulseSignalCommands(), [], "pulse: the antenna wants nothing")
        check(s.modemOnUsb, "pulse: the modem on USB, from the registry")
        s.setIconStyle(.signal)
        equal(s.pulseSignalCommands(), ["AT+QENG=\"servingcell\""], "pulse: the serving cell")
        equal(s.pulseSignalCommands(), [], "pulse: not again while one runs")
        s.pulseSignalAnswers(.success(["AT+QENG=\"servingcell\"": .lines([
            "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",001,01,FEDCBA987,32,00F00D,504990,41,12,-86,-10,10,1,-"])]))
        equal(s.signal?.level, 3, "pulse: the answer read")
        clock = clock.addingTimeInterval(15)
        _ = s.pulseSignalCommands()
        s.pulseSignalAnswers(.failure(ModemFailure(message: describe(AtError.busy))))
        check(s.signal?.stale == true && s.signal?.level == 3, "pulse: a busy turn keeps the bars, stale")
    }
}
