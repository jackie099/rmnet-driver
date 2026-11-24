// Tests for app/ModemController.swift: the controller driven by a fake ModemServing whose calls block until
// the test releases them, with the main run loop pumped so that results come back as in the app. Built
// with swiftc by `make app-test` from app/ModemNetwork.swift, app/ModemSettings.swift,
// app/ModemController.swift and this file; needs no AppKit, no window and no modem.
// The controller's repeating timer is found by reflection, and its first turn is moved to the distant
// future each time before the run loop runs, so it never fires by itself during a test (its 5 s would
// otherwise depend on how long the test takes); a test fires it when it wants a turn.
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

// MARK: - The fake service

enum Call: Equatable {
    case networkInfo
    case setRadio(Bool)
    case setMode(String)
    case profiles
    case setProfile(Int, ProfileSettings, redial: Bool)
    case sim
    case enterPin(String, shownAttempts: Int)
    case bands                       // in `allCalls` only (it does not block: see bands())
    case setBands(BandRat, [Int])
    case setNrCellLock(NrCellLock?)
    case setLteCellLock([LteLockedCell])
    case setCellLockPersist(Bool, Bool)
    case lockCellInUse(CellInUse)
    case setImei(String, reboot: Bool)
    case setSimSlot(Int, SimSlotWait)
}

let queueKey = DispatchSpecificKey<String>()
let queueName = "io.rmnetdriver.RMNet.modem.test"

/// Records each call, then blocks it (on the controller's queue) until the test releases it with a result.
/// Its mirror is empty: its log holds the test PINs, and the checks that the controller keeps no copy of a
/// PIN reflect over the controller, which holds the service.
/// The bands read is the exception: when the bands are due it follows a network read that succeeded, in the
/// same block, so it does not block and is not in `calls` (whose counts are those of the calls a test
/// releases); it answers at once with the next result queued by `queueBands`, else `bandsAnswer`, and is in
/// `allCalls`, which holds every call in order.
final class FakeService: ModemServing, CustomReflectable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var log: [Call] = []
    private var everything: [Call] = []
    private var bandsQueued: [Result<[BandSet], ModemFailure>] = []
    private var bandsDefault: Result<[BandSet], ModemFailure> = .success(bandSets())
    private var setBandsResults: [Result<BandChange, ModemFailure>] = []
    private var infoResults: [Result<NetworkInfo, ModemFailure>] = []
    private var radioResults: [Result<RadioChange, ModemFailure>] = []
    private var modeResults: [Result<ModeChange, ModemFailure>] = []
    private var profilesResults: [Result<[DataProfile], ModemFailure>] = []
    private var profileResults: [Result<ProfileChange, ModemFailure>] = []
    private var simResults: [Result<SimInfo, ModemFailure>] = []
    private var pinResults: [Result<PinOutcome, ModemFailure>] = []
    private var antennasQueued: [Result<[AntennaSignalSet], ModemFailure>] = []
    private var antennasDefault: Result<[AntennaSignalSet], ModemFailure> = .success([])
    private var cellLockQueued: [Result<CellLockState, ModemFailure>] = []
    private var cellLockDefault: Result<CellLockState, ModemFailure> = .success(
        CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false))
    private var imeiQueued: [Result<String, ModemFailure>] = []
    private var imeiDefault: Result<String, ModemFailure> = .success("000000000000091")
    private var setNrCellLockResults: [Result<CellLockChange, ModemFailure>] = []
    private var setLteCellLockResults: [Result<CellLockChange, ModemFailure>] = []
    private var setCellLockPersistResults: [Result<CellLockChange, ModemFailure>] = []
    private var lockCellInUseResults: [Result<CellLockChange, ModemFailure>] = []
    private var setImeiResults: [Result<ImeiChange, ModemFailure>] = []
    private var setSimSlotResults: [Result<SimSlotChange, ModemFailure>] = []
    private var imeiExpectations: [ImeiExpectation?] = []      // each setImei's `expect` (what the window confirmed)
    private var slotExpectations: [SimSlotExpectation?] = []   // each setSimSlot's `expect`
    private var session: (module: String?, before: String?) = ("c0ffee01", "000000000000091")
    private var antennasCount = 0
    private var cellLockCount = 0
    private var imeiCount = 0
    private var inside = 0   // calls entered and not yet returned
    private var mostInside = 0
    private var misplaced = 0  // calls made on the main thread or on another queue than the controller's

    var customMirror: Mirror { Mirror(self, children: [:]) }
    var calls: [Call] { locked { log } }
    var allCalls: [Call] { locked { everything } }
    var bandsReads: Int { locked { everything.filter { $0 == .bands }.count } }
    var antennasReads: Int { locked { antennasCount } }
    var cellLockReads: Int { locked { cellLockCount } }
    var imeiReads: Int { locked { imeiCount } }
    /// What a bands read answers when nothing is queued.
    var bandsAnswer: Result<[BandSet], ModemFailure> {
        get { locked { bandsDefault } }
        set { locked { bandsDefault = newValue } }
    }
    var antennasAnswer: Result<[AntennaSignalSet], ModemFailure> {
        get { locked { antennasDefault } }
        set { locked { antennasDefault = newValue } }
    }
    var cellLockAnswer: Result<CellLockState, ModemFailure> {
        get { locked { cellLockDefault } }
        set { locked { cellLockDefault = newValue } }
    }
    var imeiAnswer: Result<String, ModemFailure> {
        get { locked { imeiDefault } }
        set { locked { imeiDefault = newValue } }
    }
    var blocked: Int { locked { inside } }
    var mostAtOnce: Int { locked { mostInside } }
    var callsOffQueue: Int { locked { misplaced } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func enter(_ call: Call) {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        locked {
            log.append(call)
            everything.append(call)
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
        }
        gate.wait()
        locked { inside -= 1 }
    }

    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        enter(.networkInfo)
        return locked { infoResults.removeFirst() }
    }

    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        enter(.setRadio(on))
        return locked { radioResults.removeFirst() }
    }

    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> {
        enter(.setMode(mode))
        return locked { modeResults.removeFirst() }
    }

    func profiles() -> Result<[DataProfile], ModemFailure> {
        enter(.profiles)
        return locked { profilesResults.removeFirst() }
    }

    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        enter(.setProfile(id, settings, redial: redial))
        return locked { profileResults.removeFirst() }
    }

    func sim() -> Result<SimInfo, ModemFailure> {
        enter(.sim)
        return locked { simResults.removeFirst() }
    }

    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        enter(.enterPin(pin, shownAttempts: shownAttempts))
        return locked { pinResults.removeFirst() }
    }

    // The window does not read or set the USB mode (only `RMNet usbmode` does): these are never called.
    func usbMode() -> Result<UsbModeInfo, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    // Nor does it send a command as typed (only `RMNet at` does): never called.
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    // Answers at once (see the class's comment), on the controller's queue like every call.
    func bands() -> Result<[BandSet], ModemFailure> {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        return locked {
            everything.append(.bands)
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
            inside -= 1
            return bandsQueued.isEmpty ? bandsDefault : bandsQueued.removeFirst()
        }
    }

    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> {
        enter(.setBands(rat, bands))
        return locked { setBandsResults.removeFirst() }
    }

    func antennas() -> Result<[AntennaSignalSet], ModemFailure> {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        return locked {
            antennasCount += 1
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
            inside -= 1
            return antennasQueued.isEmpty ? antennasDefault : antennasQueued.removeFirst()
        }
    }

    func cellLock() -> Result<CellLockState, ModemFailure> {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        return locked {
            cellLockCount += 1
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
            inside -= 1
            return cellLockQueued.isEmpty ? cellLockDefault : cellLockQueued.removeFirst()
        }
    }

    func imei() -> Result<String, ModemFailure> {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        return locked {
            imeiCount += 1
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
            inside -= 1
            return imeiQueued.isEmpty ? imeiDefault : imeiQueued.removeFirst()
        }
    }

    func setNrCellLock(_ lock: NrCellLock?) -> Result<CellLockChange, ModemFailure> {
        enter(.setNrCellLock(lock))
        return locked { setNrCellLockResults.removeFirst() }
    }

    func setLteCellLock(_ cells: [LteLockedCell]) -> Result<CellLockChange, ModemFailure> {
        enter(.setLteCellLock(cells))
        return locked { setLteCellLockResults.removeFirst() }
    }

    func setCellLockPersist(lte: Bool, nr: Bool) -> Result<CellLockChange, ModemFailure> {
        enter(.setCellLockPersist(lte, nr))
        return locked { setCellLockPersistResults.removeFirst() }
    }

    func lockCellInUse(_ cell: CellInUse) -> Result<CellLockChange, ModemFailure> {
        enter(.lockCellInUse(cell))
        return locked { lockCellInUseResults.removeFirst() }
    }

    /// The module and the IMEI before that setImei's own port open reads (`imeiSession`).
    func setImei(_ imei: String, reboot: Bool, expect: ImeiExpectation?) -> ImeiWrite {
        locked { imeiExpectations.append(expect) }
        enter(.setImei(imei, reboot: reboot))
        return locked { ImeiWrite(outcome: setImeiResults.removeFirst(), module: session.module, before: session.before) }
    }

    func simSlot() -> Result<Int, ModemFailure> { .success(1) }

    func setSimSlot(_ slot: Int, wait: SimSlotWait, expect: SimSlotExpectation?) -> Result<SimSlotChange, ModemFailure> {
        locked { slotExpectations.append(expect) }
        enter(.setSimSlot(slot, wait))
        return locked { setSimSlotResults.removeFirst() }
    }

    var imeiExpectationsAsked: [ImeiExpectation?] { locked { imeiExpectations } }
    var slotExpectationsAsked: [SimSlotExpectation?] { locked { slotExpectations } }
    var imeiSession: (module: String?, before: String?) {
        get { locked { session } }
        set { locked { session = newValue } }
    }

    /// The answer of the next bands read (then `bandsAnswer` again).
    func queueBands(_ r: Result<[BandSet], ModemFailure>) { locked { bandsQueued.append(r) } }
    func queueAntennas(_ r: Result<[AntennaSignalSet], ModemFailure>) { locked { antennasQueued.append(r) } }
    func queueCellLock(_ r: Result<CellLockState, ModemFailure>) { locked { cellLockQueued.append(r) } }
    func queueImei(_ r: Result<String, ModemFailure>) { locked { imeiQueued.append(r) } }

    func releaseInfo(_ r: Result<NetworkInfo, ModemFailure>) { locked { infoResults.append(r) }; gate.signal() }
    func releaseRadio(_ r: Result<RadioChange, ModemFailure>) { locked { radioResults.append(r) }; gate.signal() }
    func releaseMode(_ r: Result<ModeChange, ModemFailure>) { locked { modeResults.append(r) }; gate.signal() }
    func releaseProfiles(_ r: Result<[DataProfile], ModemFailure>) { locked { profilesResults.append(r) }; gate.signal() }
    func releaseProfile(_ r: Result<ProfileChange, ModemFailure>) { locked { profileResults.append(r) }; gate.signal() }
    func releaseSim(_ r: Result<SimInfo, ModemFailure>) { locked { simResults.append(r) }; gate.signal() }
    func releasePin(_ r: Result<PinOutcome, ModemFailure>) { locked { pinResults.append(r) }; gate.signal() }
    func releaseSetBands(_ r: Result<BandChange, ModemFailure>) { locked { setBandsResults.append(r) }; gate.signal() }
    func releaseSetNrCellLock(_ r: Result<CellLockChange, ModemFailure>) { locked { setNrCellLockResults.append(r) }; gate.signal() }
    func releaseSetLteCellLock(_ r: Result<CellLockChange, ModemFailure>) { locked { setLteCellLockResults.append(r) }; gate.signal() }
    func releaseSetCellLockPersist(_ r: Result<CellLockChange, ModemFailure>) { locked { setCellLockPersistResults.append(r) }; gate.signal() }
    func releaseLockCellInUse(_ r: Result<CellLockChange, ModemFailure>) { locked { lockCellInUseResults.append(r) }; gate.signal() }
    func releaseSetImei(_ r: Result<ImeiChange, ModemFailure>) { locked { setImeiResults.append(r) }; gate.signal() }
    func releaseSetSimSlot(_ r: Result<SimSlotChange, ModemFailure>) { locked { setSimSlotResults.append(r) }; gate.signal() }
}

// MARK: - Helpers

/// Every controller a rig made, so that `pump` and `settle` can hold back their timers.
var liveControllers: [() -> ModemController?] = []
var changesSeen = 0  // published changes of the controllers and their quit notices, all on the main thread

/// The controller's repeating timer (its private `timer`), found by reflection; nil when none runs.
func timer(of c: ModemController) -> Timer? {
    Mirror(reflecting: c).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
}

/// The timer is scheduled in the main run loop's common modes (so it turns while a menu or a sheet is open).
func scheduled(_ t: Timer?) -> Bool {
    guard let t else { return false }
    return CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(t, to: CFRunLoopTimer.self), .commonModes)
}

/// Waits for `condition` without running the main run loop, so that results handed to the main thread
/// stay unread (fails the check after 2 s).
func waitOffMain(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        usleep(1000)
    }
}

/// Moves the next turn of every controller's timer to the distant future, so that no turn comes by itself.
func holdTimers() {
    for live in liveControllers {
        if let t = live().flatMap(timer(of:)), t.isValid, t.fireDate != .distantFuture { t.fireDate = .distantFuture }
    }
}

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        holdTimers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end {
        holdTimers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

func onMainOnly(_ what: String) {
    guard Thread.isMainThread else {
        print("FAIL: \(what) changed off the main thread")
        exit(1)
    }
    changesSeen += 1
}

/// Timers that run when the test moves the time on (the result banner's).
final class FakeClock {
    private(set) var now: TimeInterval = 0
    private var timers: [(due: TimeInterval, body: () -> Void)] = []

    func after(_ delay: TimeInterval, _ body: @escaping () -> Void) { timers.append((now + delay, body)) }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.enumerated().filter({ $0.element.due <= end }).min(by: { $0.element.due < $1.element.due }) {
            timers.remove(at: next.offset)
            now = next.element.due
            next.element.body()
        }
        now = end
    }
}

/// A controller with a fake service on its own queue, the driver's profile number it reads, and what it
/// answered to quits and how often it asked for attention.
final class Rig {
    let fake = FakeService()
    let queue = DispatchQueue(label: queueName)
    var driver: Int? = 1
    var clock: Date? = nil   // the controller's clock when set; the real time otherwise
    var replies: [Bool] = []
    var attention = 0
    var history: ImeiHistoryRecorder? = nil   // set before the controller is first used
    var resultClock: FakeClock? = nil          // the result banner's timers when set (before first use); real ones otherwise
    private var watchers: [AnyCancellable] = []
    lazy var controller: ModemController = makeController()

    init() { queue.setSpecific(key: queueKey, value: queueName) }

    private func makeController() -> ModemController {
        let c = ModemController(service: fake, queue: queue,
                                driverProfile: { [unowned self] in self.driver },
                                replyToQuit: { [unowned self] in self.replies.append($0) },
                                requestAttention: { [unowned self] in self.attention += 1 },
                                now: { [unowned self] in self.clock ?? Date() },
                                imeiHistory: history,
                                resultTimer: resultClock.map { $0.after } ?? mainRunLoopAfter)
        watchers.append(c.objectWillChange.sink { _ in onMainOnly("a published value of the controller") })
        watchers.append(c.quitNotice.objectWillChange.sink { _ in onMainOnly("the quit notice") })
        liveControllers.append { [weak c] in c }
        return c
    }

    /// Waits until the fake has had `count` calls in all and one of them is blocked in it.
    func waitForCall(_ count: Int, _ name: String) {
        pump(until: { fake.calls.count == count && fake.blocked == 1 }, name)
    }

    /// Answers the network read that is call `count` and waits for it to come back.
    func answerInfo(_ count: Int, _ result: Result<NetworkInfo, ModemFailure>, _ name: String) {
        waitForCall(count, name)
        fake.releaseInfo(result)
        pump(until: { controller.running == nil }, "\(name): the read comes back")
    }

    /// Answers the settings read whose profiles() is call `count` (sim() is the next) and waits for it.
    func answerSettings(_ count: Int, _ profiles: Result<[DataProfile], ModemFailure>,
                        _ sim: Result<SimInfo, ModemFailure>, _ name: String) {
        waitForCall(count, "\(name): profiles()")
        fake.releaseProfiles(profiles)
        waitForCall(count + 1, "\(name): sim()")
        fake.releaseSim(sim)
        pump(until: { controller.running == nil }, "\(name): the read comes back")
    }
}

/// True when no stored property of the controller holds `secret`: not in any child's description,
/// reflection or dump, nor in a dump of the whole controller.
func keepsNoCopy(_ c: ModemController, of secret: String) -> Bool {
    for child in Mirror(reflecting: c).children {
        var dumped = ""
        dump(child.value, to: &dumped)
        for text in [String(describing: child.value), String(reflecting: child.value), dumped] where text.contains(secret) {
            return false
        }
    }
    var whole = ""
    dump(c, to: &whole)
    return !whole.contains(secret)
}

// MARK: - Fixtures

let home = Registration(status: .home, domain: "5GS")

func network(_ mode: String?) -> NetworkInfo {
    NetworkInfo(radio: .on, registration: home, operatorName: "CHINA MOBILE", mode: mode)
}

let profile1 = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
let profile2 = ProfileSettings(type: .ipv4v6, apn: "ims", user: "", password: "", auth: .none)
let profile3 = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "", password: "", auth: .none)

/// Profiles 1, 2 and 3 as AT+CGDCONT? and AT+QICSGP read them; nil settings: not read.
func listing(_ one: ProfileSettings? = profile1, three: ProfileSettings? = profile3) -> [DataProfile] {
    [DataProfile(id: 1, pdpType: "IPV4V6", apn: one?.apn ?? "", settings: one),
     DataProfile(id: 2, pdpType: "IPV4V6", apn: "ims", settings: profile2),
     DataProfile(id: 3, pdpType: "IPV4V6", apn: three?.apn ?? "", settings: three)]
}

let ready = SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10)

func asksPin(_ attempts: Int?) -> SimInfo {
    SimInfo(state: .pin, pinLock: true, pinAttempts: attempts, pukAttempts: 10)
}

let radioOn = RadioChange(on: true, registration: home, secondsToRegister: 9)
let radioOff = RadioChange(on: false, registration: nil, secondsToRegister: nil)

let portBusy = ModemFailure(message: "Another program is using the modem's spare AT port.")
let notAnswered = ModemFailure(message: "The modem did not answer in time.")
let refused = ModemFailure(message: "The modem refused the command (+CME ERROR: 3). Nothing was changed.")

// The bands, as the modem answered on 2026-11-15 (tests/app/ModemCliTests.swift): every supported band allowed.
let lteSupported = [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43,
                    46, 48, 66, 71]
let nrSupported = [1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 38, 40, 41, 48, 66, 70, 71, 75, 76, 77, 78, 79]

func bandSets(lte: [Int] = lteSupported, nsa: [Int] = nrSupported, sa: [Int] = nrSupported) -> [BandSet] {
    [BandSet(rat: .lte, allowed: lte, supported: lteSupported), BandSet(rat: .nsa, allowed: nsa, supported: nrSupported),
     BandSet(rat: .sa, allowed: sa, supported: nrSupported)]
}

let bandsRefused = ModemFailure(message: "The modem refused the command (+CME ERROR: 3). The 5G NSA bands were not changed.")
let bandsQuitLine = "RMNet quits when the bands have been changed."

// Serving cells for the signal history: 5G SA, EN-DC (LTE + NR) and WCDMA legs, as ModemNetwork.swift parses them.
func cell(_ rat: String, rsrp: Int?, rsrq: Int?, sinr: Double?, band: String?) -> CellLeg {
    CellLeg(rat: rat, duplex: "TDD", mcc: "001", mnc: "01", cellID: "1A2B3C", pci: 101, tac: "1F", channel: 520110,
            band: band, bandwidthMHz: 100, rsrp: rsrp, rsrq: rsrq, sinr: sinr)
}

func served(_ legs: [CellLeg], state: String = "NOCONN") -> NetworkInfo {
    NetworkInfo(radio: .on, registration: home, operatorName: "TEST NETWORK",
                serving: ServingCell(state: state, cells: legs), mode: "AUTO")
}

let saLeg = cell("NR5G-SA", rsrp: -86, rsrq: -11, sinr: 10.5, band: "n41")
let lteLeg = cell("LTE", rsrp: -95, rsrq: -12, sinr: 8, band: "B3")
let nsaLeg = cell("NR5G-NSA", rsrp: -90, rsrq: -10, sinr: 14, band: "n78")
let umtsLeg = cell("WCDMA", rsrp: -80, rsrq: nil, sinr: nil, band: nil)

let waitingLine = "Waiting for the current read to finish…"
let anotherChange = "Another change to the modem has not finished yet. Nothing was changed; try again when it has."
let anotherChangePin = "Another change to the modem has not finished yet. The PIN was not sent; enter it again when it has."

// MARK: - The checks

@main
struct ModemControllerTests {
    static func main() {
        reading()
        tabSwitching()
        settingsReads()
        formAndPick()
        enabledStates()
        modeChanges()
        modeOrder()
        radio()
        profileChanges()
        profileWayBack()
        queuedChanges()
        refreshing()
        nothingDone()
        pinEntry()
        bandsReading()
        bandsEnabled()
        bandsChanges()
        bandsResets()
        bandsNothingDone()
        quitting()
        resuming()
        overviewReading()
        signalHistory()
        antennasCellLockAndImei()
        cellInUseLocks()
        imeiHistoryRecorded()
        simSlotChanges()
        simSlotSwitchBack()
        simSlotDroppedAtQuit()
        resultBanner()
        check(changesSeen > 0, "main thread: the controllers' changes were watched")
        print("modem controller: \(checks) checks passed")
    }

    // The shown tab is read at once and on each timer turn; nothing while no tab is shown, the window is
    // hidden or a confirmation is open; a turn while a call runs is skipped; a failed read keeps the last
    // values and says why, a good one clears that.
    static func reading() {
        let rig = Rig()
        let c = rig.controller
        check(ModemController.networkInterval == 5 && ModemController.settingsInterval == 30,
              "read: the turns are 5 s (Network) and 30 s (SIM & APN)")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.isEmpty && timer(of: c) == nil, "read: nothing is read and no timer runs before a tab is shown",
              "\(rig.fake.calls)")
        check(c.info == nil && c.sim == nil && c.profiles.isEmpty && c.running == nil && c.result == "",
              "read: nothing is known at first")

        // The Network tab: networkInfo() at once, then every 5 s.
        c.setTabShown(.network)
        rig.waitForCall(1, "the Network tab is read at once")
        check(rig.fake.calls == [.networkInfo] && c.running == .reading, "read: the Network tab reads networkInfo() at once",
              "\(rig.fake.calls)")
        check(timer(of: c)?.timeInterval == 5, "read: the Network tab's timer turns every 5 s")
        check(scheduled(timer(of: c)), "read: the Network tab's timer is scheduled in the main run loop")
        check(c.refreshEnabled, "read: a read leaves Refresh on (R12)")
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        c.setTabShown(.network)
        c.setWindowVisible(true)
        settle()
        check(rig.fake.calls == [.networkInfo],
              "read: a tick, a refresh, a timer turn and showing the tab again start nothing while a read runs",
              "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the first network read comes back")
        settle()
        check(c.info == network("AUTO") && c.infoAt != nil && c.infoFailure == nil, "read: a good read sets info and its time")
        check(rig.fake.calls.count == 1 && c.refreshEnabled, "read: nothing more is read until the next turn", "\(rig.fake.calls)")

        timer(of: c)?.fire()
        rig.waitForCall(2, "a timer turn reads")
        check(rig.fake.calls.last == .networkInfo, "read: a timer turn reads networkInfo()")
        let firstAt = c.infoAt
        rig.fake.releaseInfo(.failure(portBusy))
        pump(until: { c.running == nil }, "the failed read comes back")
        check(c.info == network("AUTO") && c.infoAt == firstAt && c.infoFailure == portBusy.message,
              "read: a failed read keeps the last values and says why", "\(String(describing: c.infoFailure))")
        check(c.result == "", "read: a read never writes the result line", c.result)

        c.tick()
        rig.answerInfo(3, .success(network("LTE")), "a tick")
        check(c.info == network("LTE") && c.infoFailure == nil && c.infoAt != nil && c.infoAt != firstAt,
              "read: a good read clears the failure")

        // A confirmation is open: turns skip.
        c.setConfirming(true)
        c.tick()
        timer(of: c)?.fire()
        settle()
        check(rig.fake.calls.count == 3, "read: turns skip while a confirmation is open", "\(rig.fake.calls)")
        c.setConfirming(false)
        settle()
        check(rig.fake.calls.count == 3, "read: closing a confirmation reads nothing by itself", "\(rig.fake.calls)")
        c.tick()
        rig.answerInfo(4, .success(network("LTE")), "a tick after the confirmation")

        // The window shown again while a confirmation is open: the read waits until it closes.
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        settle()
        check(rig.fake.calls.count == 4, "read: nothing is read while a confirmation is open, also when the window shows again",
              "\(rig.fake.calls)")
        c.setConfirming(false)
        rig.answerInfo(5, .success(network("LTE")), "the read that was due starts when the confirmation closes")

        // The window hidden: no timer, no reads; shown again: read at once.
        c.setWindowVisible(false)
        check(timer(of: c) == nil, "read: the timer stops while the window is hidden")
        c.tick()
        settle()
        check(rig.fake.calls.count == 5, "read: a tick reads nothing while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(6, .success(network("LTE")), "the window shown again is read at once")
        check(timer(of: c)?.timeInterval == 5 && scheduled(timer(of: c)), "read: the timer runs again when the window shows")

        // The SIM & APN tab: profiles() then sim() in one queued block, at once and every 30 s.
        c.setTabShown(.simAndApn)
        rig.waitForCall(7, "the SIM & APN tab is read at once")
        check(rig.fake.calls.last == .profiles && c.running == .reading, "read: the SIM & APN tab reads profiles() first",
              "\(rig.fake.calls)")
        check(timer(of: c)?.timeInterval == 30 && scheduled(timer(of: c)),
              "read: the SIM & APN tab's timer turns every 30 s, scheduled in the main run loop")
        rig.fake.releaseProfiles(.success(listing()))
        rig.waitForCall(8, "sim() follows profiles()")
        check(rig.fake.calls.last == .sim && c.running == .reading, "read: sim() follows profiles() in the same read")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 8, "read: nothing starts between profiles() and sim()", "\(rig.fake.calls)")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the settings read comes back")
        check(c.profiles == listing() && c.sim == ready && c.settingsAt != nil && c.settingsFailure == nil,
              "read: a good settings read sets the profiles, the SIM and the time")
        check(c.info == network("LTE"), "read: the network values are kept while the other tab is shown")
        timer(of: c)?.fire()
        rig.answerSettings(9, .success(listing()), .success(ready), "a timer turn on the SIM & APN tab")

        // Neither modem tab shown.
        c.setTabShown(nil)
        check(timer(of: c) == nil, "read: the timer stops while neither modem tab is shown")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 10, "read: nothing is read while neither modem tab is shown", "\(rig.fake.calls)")
        check(rig.fake.mostAtOnce == 1, "read: never two calls in the service at once")
        check(rig.fake.callsOffQueue == 0, "read: every call runs on the controller's queue, off the main thread")
    }

    // A tab shown while a read of the other runs is read as soon as that read has finished (not a turn
    // later); the tab's own read is never doubled; nothing follows while the window is hidden.
    static func tabSwitching() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.waitForCall(1, "the Network tab is read")
        c.setTabShown(.simAndApn)
        settle()
        check(rig.fake.calls == [.networkInfo], "switch: the other tab waits for the running read", "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.answerSettings(2, .success(listing()), .success(ready), "the SIM & APN tab after the running read")
        check(c.info == network("AUTO") && c.sim == ready, "switch: both reads are applied")
        settle()
        check(rig.fake.calls.count == 3, "switch: the new tab is read once", "\(rig.fake.calls)")

        // Hiding and showing the window while the tab's own read runs: no second read.
        c.tick()
        rig.waitForCall(4, "a turn starts")
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        rig.answerSettings(4, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 5, "switch: hiding and showing the window during the tab's own read reads it once",
              "\(rig.fake.calls)")

        // Away and back during a read: once.
        c.tick()
        rig.waitForCall(6, "a turn starts")
        c.setTabShown(.network)
        c.setTabShown(.simAndApn)
        rig.answerSettings(6, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 7, "switch: away and back during the tab's own read reads it once", "\(rig.fake.calls)")

        // Switched while hidden: nothing follows until the window shows again.
        c.tick()
        rig.waitForCall(8, "a turn starts")
        c.setWindowVisible(false)
        c.setTabShown(.network)
        rig.answerSettings(8, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 9, "switch: nothing follows a read while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(10, .success(network("AUTO")), "the Network tab when the window shows")
        check(rig.fake.calls.last == .networkInfo, "switch: the tab shown is read when the window shows")
        c.setTabShown(nil)
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "switch: one call at a time, on the queue")
    }

    // A settings read's two parts: either failing keeps its last values and sets the failure; a good read
    // clears it. The driver's profile number is read at each settings refresh.
    static func settingsReads() {
        let rig = Rig()
        let c = rig.controller
        check(c.profileID == 1 && !c.driverAttached, "settings: before any read, profile 1 and no driver known")
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "the first settings read")
        check(c.profileID == 1 && c.driverAttached, "settings: the driver's profile is read at the refresh")
        let firstAt = c.settingsAt

        c.tick()
        rig.answerSettings(3, .failure(portBusy), .success(asksPin(3)), "profiles() fails")
        check(c.profiles == listing() && c.sim == asksPin(3), "settings: a failed profiles() keeps the profiles; sim() still counts")
        check(c.settingsFailure == portBusy.message && c.settingsAt == firstAt,
              "settings: the failure is said; the time stays that of the last good read")

        let otherOne = ProfileSettings(type: .ipv4, apn: "a.b", user: "u", password: "", auth: .pap)
        c.tick()
        rig.answerSettings(5, .success(listing(otherOne)), .failure(notAnswered), "sim() fails")
        check(c.profiles == listing(otherOne) && c.sim == asksPin(3), "settings: a failed sim() keeps the SIM; profiles() still counts")
        check(c.settingsFailure == notAnswered.message && c.settingsAt == firstAt, "settings: sim()'s failure is said")

        c.tick()
        rig.answerSettings(7, .failure(portBusy), .failure(notAnswered), "both fail")
        check(c.settingsFailure == portBusy.message, "settings: both failing says the first failure",
              "\(String(describing: c.settingsFailure))")

        c.tick()
        rig.answerSettings(9, .success(listing()), .success(ready), "a good read")
        check(c.settingsFailure == nil && c.settingsAt != nil && c.settingsAt != firstAt && c.sim == ready && c.profiles == listing(),
              "settings: a good read clears the failure and sets the time")

        rig.driver = 3
        c.tick()
        rig.answerSettings(11, .success(listing()), .success(ready), "the driver on profile 3")
        check(c.profileID == 3 && c.driverAttached && c.form == profile3 && !c.formEdited,
              "settings: the form is the driver's profile, read at each refresh")
        rig.driver = nil
        c.tick()
        rig.answerSettings(13, .success(listing()), .success(ready), "the driver not attached")
        check(c.profileID == 1 && !c.driverAttached && c.form == profile1, "settings: without the driver, profile 1")
        c.setTabShown(nil)

        // The driver's profile not listed, or listed without its settings: no form, no Apply.
        let rig2 = Rig()
        rig2.driver = 7
        let d = rig2.controller
        d.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(ready), "profile 7 is not listed")
        check(d.profileID == 7 && d.form == nil && !d.formEdited && !d.applyEnabled, "settings: a profile not listed has no form")
        d.revertForm()
        check(d.form == nil, "settings: Revert leaves a profile not listed without a form")
        d.setTabShown(nil)

        let rig3 = Rig()
        rig3.driver = 3
        let e = rig3.controller
        e.setTabShown(.simAndApn)
        rig3.answerSettings(1, .success(listing(three: nil)), .success(ready), "profile 3 without settings")
        check(e.profileID == 3 && e.form == nil && !e.applyEnabled, "settings: a profile whose settings were not read has no form")
        e.setTabShown(nil)
    }

    // The editor's form and the Network tab's pick: filled when nil, never overwritten by a refresh when
    // the owner changed them, following the modem when not.
    static func formAndPick() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "the first settings read")
        check(c.form == profile1 && !c.formEdited, "form: filled from the driver's profile when nil")
        c.form?.apn = "cmnet"
        check(c.formEdited, "form: an edit shows as edited")
        let elsewhere = ProfileSettings(type: .ipv4v6, apn: "internet", user: "", password: "", auth: .none)
        c.tick()
        rig.answerSettings(3, .success(listing(elsewhere)), .success(ready), "the profile changed elsewhere")
        check(c.form?.apn == "cmnet" && c.formEdited, "form: a refresh never overwrites an edited form",
              "\(String(describing: c.form))")
        c.revertForm()
        check(c.form == elsewhere && !c.formEdited, "form: Revert fills it from the last read")
        c.tick()
        rig.answerSettings(5, .success(listing()), .success(ready), "the profile changed back elsewhere")
        check(c.form == profile1 && !c.formEdited, "form: a form not edited follows the modem's values")
        c.form?.apn = "cmnet"
        rig.driver = 3
        c.tick()
        rig.answerSettings(7, .success(listing()), .success(ready), "the driver's profile changes")
        check(c.form == profile3 && !c.formEdited, "form: when the driver's profile changes, the form is that profile's")
        c.setTabShown(nil)

        let rig2 = Rig()
        let m = rig2.controller
        m.setTabShown(.network)
        rig2.answerInfo(1, .success(network(nil)), "a read without the mode")
        check(m.pickedMode == nil && !m.modeChangeEnabled, "pick: nil while the mode is not known")
        m.tick()
        rig2.answerInfo(2, .success(network("AUTO")), "a read with the mode")
        check(m.pickedMode == "AUTO" && !m.modeChangeEnabled, "pick: set from info.mode when nil; Change is off for the current mode")
        m.tick()
        rig2.answerInfo(3, .success(network("LTE")), "the mode changed elsewhere")
        check(m.pickedMode == "LTE" && !m.modeChangeEnabled, "pick: a pick the owner did not change follows the modem's mode")
        m.pickedMode = "NR5G"
        check(m.modeChangeEnabled, "pick: a different pick enables Change")
        m.tick()
        rig2.answerInfo(4, .success(network("AUTO")), "the mode changed elsewhere again")
        check(m.pickedMode == "NR5G" && m.modeChangeEnabled, "pick: a refresh never overwrites a different pick")
        m.pickedMode = "5g"
        check(!m.modeChangeEnabled, "pick: a mode RMNet cannot set does not enable Change")
        m.setTabShown(nil)
    }

    // Apply, Change, Unlock and Refresh are off while a call runs and once the app quits.
    static func enabledStates() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        check(!c.applyEnabled, "apply: off while the form is not edited")
        c.form?.apn = "cm net"
        check(c.formEdited && !c.applyEnabled, "apply: off while profileProblem has a sentence")
        c.form?.apn = "cmnet"
        check(c.applyEnabled, "apply: on for an edited form without a problem")
        check(c.pinEnabled, "pin: on when the SIM asks for its PIN with attempts left")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled, "mode: on for a pick that differs from the mode read (none yet)")

        c.tick()
        rig.waitForCall(3, "a turn starts")
        check(c.applyEnabled && c.pinEnabled && c.modeChangeEnabled && c.refreshEnabled,
              "enabled: a read leaves every button on (R12)")
        rig.fake.releaseProfiles(.success(listing()))
        rig.fake.releaseSim(.success(asksPin(1)))
        pump(until: { c.running == nil }, "the turn comes back")
        check(c.applyEnabled && c.pinEnabled && c.modeChangeEnabled && c.refreshEnabled,
              "enabled: on again afterwards; Unlock is on with 1 attempt left")

        var n = 5
        let puk = SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10)
        for (sim, name) in [(asksPin(0), "no attempts are left"), (asksPin(nil), "the attempts are not known"),
                            (ready, "the SIM is ready"), (puk, "the SIM needs its PUK")] {
            c.tick()
            rig.answerSettings(n, .success(listing()), .success(sim), name)
            n += 2
            check(!c.pinEnabled, "pin: off when \(name)")
        }
        c.tick()
        rig.answerSettings(n, .success(listing()), .success(asksPin(3)), "the SIM asks again")
        check(c.pinEnabled, "pin: on again")
        check(c.quitWhenFinished() == false, "enabled: a quit with nothing running answers at once")
        check(!c.applyEnabled && !c.pinEnabled && !c.modeChangeEnabled && !c.refreshEnabled,
              "enabled: everything is off once the app quits")
        c.setTabShown(nil)
    }

    // changeMode: the pick goes to the service; the sentence; the undo; the pick and the tab read again.
    // putBack sends the modem's own string (ruling R8) and clears the undo on success only.
    static func modeChanges() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.pickedMode = "LTE"
        c.changeMode()
        rig.waitForCall(2, "the mode change reaches the service")
        check(rig.fake.calls.last == .setMode("LTE") && c.running == .mode, "mode: the pick goes to setMode", "\(rig.fake.calls)")
        check(c.result == "Changing the network mode to LTE only…" && !c.resultIsFailure, "mode: the running sentence", c.result)
        check(!c.modeChangeEnabled && !c.refreshEnabled, "mode: Change and Refresh are off while it runs")
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        c.changeMode()
        settle()
        check(rig.fake.calls.count == 2, "mode: nothing else starts while the change runs", "\(rig.fake.calls)")
        check(c.result == anotherChange && c.resultIsFailure, "mode: a second Change while one runs is refused with a sentence",
              c.result)
        let change = ModeChange(before: "AUTO", after: "LTE")
        rig.fake.releaseMode(.success(change))
        rig.waitForCall(3, "the tab is read again after the change")
        check(rig.fake.calls.last == .networkInfo, "mode: the Network tab is read again after the change")
        check(c.result == modeSentence(change) && !c.resultIsFailure, "mode: the success sentence", c.result)
        check(c.undo == .mode("AUTO") && c.pickedMode == "LTE", "mode: the undo is the mode before; the pick is the new mode")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read after the change comes back")
        check(c.result == modeSentence(change) && !c.modeChangeEnabled, "mode: the read after it leaves the result line; Change is off")

        c.pickedMode = "NR5G"
        c.changeMode()
        rig.waitForCall(4, "a second change reaches the service")
        rig.fake.releaseMode(.failure(refused))
        rig.waitForCall(5, "the tab is read again after the failed change")
        check(c.result == refused.message && c.resultIsFailure, "mode: a failure's sentence", c.result)
        check(c.undo == .mode("AUTO") && c.pickedMode == "LTE", "mode: a failure keeps the undo; the pick goes back to the mode read")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")
        c.setTabShown(nil)

        // Put Back: the modem's own string, unchanged (R8).
        let rig2 = Rig()
        let m = rig2.controller
        m.setTabShown(.network)
        rig2.answerInfo(1, .success(network("NR5G:LTE")), "the first read")
        m.pickedMode = "AUTO"
        m.changeMode()
        rig2.waitForCall(2, "the change reaches the service")
        rig2.fake.releaseMode(.success(ModeChange(before: "NR5G:LTE", after: "AUTO")))
        rig2.answerInfo(3, .success(network("AUTO")), "the read after the change")
        check(m.undo == .mode("NR5G:LTE"), "put back: the undo keeps the modem's own string")
        check(m.undoCommand == "RMNet mode nr5g:lte", "put back: the window's command for a terminal (F9)",
              "\(String(describing: m.undoCommand))")
        m.putBack()
        rig2.waitForCall(4, "the put back reaches the service")
        check(rig2.fake.calls.last == .setMode("NR5G:LTE") && m.running == .mode,
              "put back: setMode gets the modem's own string, unchanged (R8)", "\(rig2.fake.calls)")
        check(m.result == "Putting the network mode back to 5G and LTE…", "put back: the running sentence", m.result)
        rig2.fake.releaseMode(.failure(notAnswered))
        rig2.answerInfo(5, .success(network("AUTO")), "the read after the failed put back")
        check(m.result == notAnswered.message && m.resultIsFailure && m.undo == .mode("NR5G:LTE"),
              "put back: a failure keeps the undo", m.result)
        m.putBack()
        rig2.waitForCall(6, "the put back again")
        let back = ModeChange(before: "AUTO", after: "NR5G:LTE")
        rig2.fake.releaseMode(.success(back))
        rig2.waitForCall(7, "the tab is read again after the put back")
        check(m.undo == nil && m.result == modeSentence(back) && !m.resultIsFailure && m.pickedMode == "NR5G:LTE",
              "put back: success clears the undo; its sentence; the pick is the mode put back", m.result)
        check(m.undoCommand == nil, "put back: no command without an undo")
        rig2.fake.releaseInfo(.success(network("NR5G:LTE")))
        pump(until: { m.running == nil }, "the read comes back")
        m.putBack()
        settle()
        check(rig2.fake.calls.count == 7, "put back: with nothing to put back it does nothing", "\(rig2.fake.calls)")
        m.setTabShown(nil)

        // A mode before that RMNet cannot set again gives no Put Back.
        let rig3 = Rig()
        let o = rig3.controller
        o.setTabShown(.network)
        rig3.answerInfo(1, .success(network("GSM:LTE")), "an odd mode")
        o.pickedMode = "LTE"
        o.changeMode()
        rig3.waitForCall(2, "the change reaches the service")
        rig3.fake.releaseMode(.success(ModeChange(before: "GSM:LTE", after: "LTE")))
        rig3.answerInfo(3, .success(network("LTE")), "the read after the change")
        check(o.undo == nil && !o.resultIsFailure && o.undoCommand == nil,
              "mode: no undo and no command when the mode before cannot be set by RMNet")
        check(o.result == modeSentence(ModeChange(before: "GSM:LTE", after: "LTE"))
                + " The earlier value GSM:LTE cannot be set with RMNet mode; "
                + "to put it back: RMNet at 'AT+QNWPREFCFG=\"mode_pref\",GSM:LTE'",
              "mode: the result line says the mode before cannot be put back by RMNet, and its AT command (R8)", o.result)
        o.setTabShown(nil)

        // An earlier value that is not printable ASCII without quotes: the AT command with `<value>` as written.
        let rig4 = Rig()
        let q = rig4.controller
        q.setTabShown(.network)
        rig4.answerInfo(1, .success(network("GSM\"LTE")), "a mode with a quote")
        q.pickedMode = "LTE"
        q.changeMode()
        rig4.waitForCall(2, "the change reaches the service")
        rig4.fake.releaseMode(.success(ModeChange(before: "GSM\"LTE", after: "LTE")))
        rig4.answerInfo(3, .success(network("LTE")), "the read after the change")
        check(q.undo == nil && !q.resultIsFailure && q.undoCommand == nil,
              "mode: no undo and no command when the mode before has a quote")
        check(q.result == modeSentence(ModeChange(before: "GSM\"LTE", after: "LTE"))
                + " The earlier value GSM\"LTE cannot be set with RMNet mode; "
                + "set it again with RMNet at 'AT+QNWPREFCFG=\"mode_pref\",<value>'",
              "mode: a value that cannot go into the command is written <value> (R8)", q.result)
        q.setTabShown(nil)
    }

    // setRadio: its sentence, no undo of its own (an earlier one stays), the tab read again; not while
    // the window is hidden, until it shows.
    // The same RATs in another order are the same mode (compared by canonicalMode): no change to make, and
    // the pick follows the modem. (Put Back still sends the modem's own string: modeChanges, R8.)
    static func modeOrder() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("NR5G:LTE")), "the first read")
        check(c.pickedMode == "NR5G:LTE" && !c.modeChangeEnabled, "mode order: the modem's own value, no change")
        c.pickedMode = "LTE:NR5G"
        check(!c.modeChangeEnabled, "mode order: LTE:NR5G for NR5G:LTE is not a change")
        c.changeMode()
        settle()
        check(rig.fake.calls.count == 1, "mode order: changeMode sends nothing for the same mode", "\(rig.fake.calls)")
        check(c.result == "The network mode is already 5G and LTE. Nothing was changed." && c.resultIsFailure,
              "mode order: changeMode says it is the mode already", c.result)
        timer(of: c)?.fire()
        rig.answerInfo(2, .success(network("AUTO")), "a read after the modem changed")
        check(c.pickedMode == "AUTO", "mode order: the pick of the same mode in another order follows the modem",
              "\(String(describing: c.pickedMode))")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled, "mode order: another mode is a change")
        c.setTabShown(nil)
    }

    static func radio() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.pickedMode = "LTE"
        c.changeMode()
        rig.waitForCall(2, "a mode change, for an undo")
        rig.fake.releaseMode(.success(ModeChange(before: "AUTO", after: "LTE")))
        rig.answerInfo(3, .success(network("LTE")), "the read after it")

        c.setRadio(on: false)
        rig.waitForCall(4, "the radio switch reaches the service")
        check(rig.fake.calls.last == .setRadio(false) && c.running == .radio, "radio: off goes to setRadio(on: false)")
        check(c.result == "Switching the radio off…" && !c.resultIsFailure, "radio: the running sentence", c.result)
        rig.fake.releaseRadio(.success(radioOff))
        rig.waitForCall(5, "the tab is read again after the radio")
        check(rig.fake.calls.last == .networkInfo, "radio: the Network tab is read again")
        check(c.result == radioSentence(radioOff) && !c.resultIsFailure, "radio: off's sentence", c.result)
        check(c.undo == .mode("AUTO"), "radio: no undo of its own; the earlier one stays")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")

        c.setRadio(on: true)
        rig.waitForCall(6, "radio on")
        check(rig.fake.calls.last == .setRadio(true) && c.result == "Switching the radio on…", "radio: on", c.result)
        rig.fake.releaseRadio(.success(radioOn))
        rig.waitForCall(7, "the tab is read again")
        check(c.result == radioSentence(radioOn) && !c.resultIsFailure, "radio: on's sentence", c.result)
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")

        c.setRadio(on: true)
        rig.waitForCall(8, "radio on again")
        c.setWindowVisible(false)
        rig.fake.releaseRadio(.failure(notAnswered))
        pump(until: { c.running == nil }, "the failed switch comes back")
        settle()
        check(c.result == notAnswered.message && c.resultIsFailure && c.undo == .mode("AUTO"), "radio: a failure's sentence", c.result)
        check(rig.fake.calls.count == 8, "radio: no read after a change while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(9, .success(network("LTE")), "the window shows again")
        c.setTabShown(nil)
    }

    // applyProfile: the form to the driver's profile with redial; the sentence; the undo with the settings
    // before (the old password in memory only); the form filled after; putBack the same way.
    static func profileChanges() {
        let rig = Rig()
        rig.driver = 3
        let c = rig.controller
        let old = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "carrier", password: "oldSecret1", auth: .pap)
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing(three: old)), .success(ready), "the first settings read")
        check(c.form == old, "profile: the form holds the driver's profile")
        c.form?.apn = "cmnet.example"
        let applied = c.form!
        check(c.applyEnabled, "profile: Apply is on")
        c.applyProfile()
        rig.waitForCall(3, "the profile change reaches the service")
        check(rig.fake.calls.last == .setProfile(3, applied, redial: true) && c.running == .profile,
              "profile: the form goes to the driver's profile, with redial")
        check(c.result == "Changing profile 3…" && !c.resultIsFailure, "profile: the running sentence", c.result)
        check(!c.applyEnabled && !c.refreshEnabled, "profile: Apply and Refresh are off while it runs")
        let change = ProfileChange(id: 3, before: old, after: applied, redial: .done(radioOn))
        rig.fake.releaseProfile(.success(change))
        rig.waitForCall(4, "the tab is read again after the change")
        check(rig.fake.calls.last == .profiles, "profile: the SIM & APN tab is read again")
        check(c.result == profileSentence(change) && !c.resultIsFailure, "profile: the success sentence", c.result)
        check(c.undo == .profile(id: 3, old), "profile: the undo holds the settings before, password included")
        check(c.undoCommand == "RMNet apn set --apn 'CMNET' --type ipv4v6 --user 'carrier' --auth pap --password",
              "profile: the window's command for a terminal, without the password (F9)", "\(String(describing: c.undoCommand))")
        check(c.form == applied && !c.formEdited, "profile: the form is filled with the new settings")
        rig.fake.releaseProfiles(.success(listing(three: applied)))
        rig.waitForCall(5, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == applied && !c.formEdited && !c.applyEnabled, "profile: the read after it leaves the form as read")

        var dumped = ""
        dump(c, to: &dumped)
        check(!dumped.contains("oldSecret1") && dumped.contains("passwordSet"),
              "profile: a dump of the controller does not show the old password")
        check(!String(describing: c.undo).contains("oldSecret1") && !String(reflecting: c.undo).contains("oldSecret1"),
              "profile: the undo's descriptions do not show the old password")

        // Put Back: the settings before, with redial; the undo cleared; an edit replaced by what the modem has.
        c.form?.user = "typed"
        c.putBack()
        rig.waitForCall(6, "the put back reaches the service")
        check(rig.fake.calls.last == .setProfile(3, old, redial: true) && c.running == .profile,
              "put back: the settings before, with redial")
        check(c.result == "Putting profile 3 back…", "put back: the running sentence", c.result)
        let back = ProfileChange(id: 3, before: applied, after: old, redial: .done(radioOn))
        rig.fake.releaseProfile(.success(back))
        rig.waitForCall(7, "the tab is read again after the put back")
        check(c.undo == nil && c.result == profileSentence(back) && !c.resultIsFailure, "put back: success clears the undo", c.result)
        check(c.form == old && !c.formEdited, "put back: the form is filled with the settings put back")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(8, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")

        // A change that fails: its sentence, the undo unchanged, the owner's edit kept to be corrected (R11).
        c.form?.apn = "x"
        c.form?.password = "newSecret2"
        let typed = c.form!
        c.applyProfile()
        rig.waitForCall(9, "a change that will fail")
        rig.fake.releaseProfile(.failure(refused))
        rig.waitForCall(10, "the tab is read again after the failure")
        check(c.result == refused.message && c.resultIsFailure && c.undo == nil, "profile: a failure's sentence; no undo", c.result)
        check(c.form == typed && c.formEdited, "profile: a failed Apply keeps the edited form (R11)")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(11, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == typed && c.formEdited && c.applyEnabled, "profile: the read after it keeps the edit; Apply is on to try again")
        var afterFailure = ""
        dump(c, to: &afterFailure)
        check(!afterFailure.contains("newSecret2") && !afterFailure.contains("oldSecret1"),
              "profile: a dump of the controller shows neither password")
        c.revertForm()

        // A change whose redial left the radio off: said as a failure; it can be put back.
        c.form?.apn = "y"
        let tried = c.form!
        c.applyProfile()
        rig.waitForCall(12, "a change whose redial fails")
        let leftOff = ProfileChange(id: 3, before: old, after: tried, redial: .radioLeftOff("The modem did not answer in time."))
        rig.fake.releaseProfile(.success(leftOff))
        rig.waitForCall(13, "the tab is read again")
        check(c.result == profileSentence(leftOff) && c.resultIsFailure, "profile: the radio left off is said as a failure", c.result)
        check(c.undo == .profile(id: 3, old), "profile: a change that left the radio off can be put back")
        check(c.form == tried && !c.formEdited, "profile: a change made (radio left off) fills the form")
        rig.fake.releaseProfiles(.success(listing(three: tried)))
        rig.waitForCall(14, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")

        // A Put Back that fails keeps an edit made meanwhile and the undo; one that succeeds fills the form.
        c.form?.user = "edited"
        let edit = c.form!
        c.putBack()
        rig.waitForCall(15, "a put back that will fail")
        rig.fake.releaseProfile(.failure(notAnswered))
        rig.answerSettings(16, .success(listing(three: tried)), .success(ready), "the read after the failed put back")
        check(c.form == edit && c.formEdited && c.undo == .profile(id: 3, old) && c.resultIsFailure,
              "put back: a failure keeps the edited form and the undo (R11)", c.result)
        c.putBack()
        rig.waitForCall(18, "the put back again")
        rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: tried, after: old, redial: .done(radioOn))))
        rig.waitForCall(19, "the read after the put back")
        check(c.form == old && !c.formEdited && c.undo == nil, "put back: success fills the form with what the modem has")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(20, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == old && !c.formEdited, "put back: the read after it fills the form from what was read")
        c.setTabShown(nil)
    }

    // A profile change that failed after its line may have reached the modem (ruling R19), one for each of
    // the service's paths: its sentence, the undo set to the settings before it, and the owner's edit kept
    // (R11) with the form's source reset, so that the earlier settings typed again count as a change.
    static func profileWayBack() {
        let old = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "carrier", password: "oldSecret1", auth: .pap)
        for sentence in [
            "It is not known whether profile 3 was changed. The modem did not answer in time. The radio was switched back on.",
            "Profile 3 does not read back as sent: the modem now reports IPV4V6, APN \"x\", no authentication. "
                + "The radio was switched back on.",
            "Profile 3 could not be read back after the change. The modem did not answer in time. The radio was switched back on.",
        ] {
            let name = "way back after \"\(sentence.prefix(40))…\""
            let rig = Rig()
            rig.driver = 3
            let c = rig.controller
            c.setTabShown(.simAndApn)
            rig.answerSettings(1, .success(listing(three: old)), .success(ready), "\(name): the first read")
            c.form?.apn = "cmnet.example"
            c.form?.password = "newSecret2"
            let typed = c.form!
            c.applyProfile()
            rig.waitForCall(3, "\(name): the change")
            rig.fake.releaseProfile(.failure(ModemFailure(message: sentence, profileBefore: old)))
            rig.waitForCall(4, "\(name): the tab is read again")
            check(c.result == sentence && c.resultIsFailure, "\(name): the failure's sentence", c.result)
            check(c.undo == .profile(id: 3, old), "\(name): the undo holds the settings before, password included",
                  "\(String(describing: c.undo))")
            check(c.form == typed && c.formEdited, "\(name): the edit is kept (R11)")
            rig.fake.releaseProfiles(.success(listing(three: typed)))
            rig.waitForCall(5, "\(name): sim()")
            rig.fake.releaseSim(.success(ready))
            pump(until: { c.running == nil }, "\(name): the read comes back")
            check(c.form == typed && c.formEdited && c.applyEnabled, "\(name): the read after it keeps the edit; Apply is on")
            c.form = old
            check(c.formEdited && c.applyEnabled, "\(name): the settings before typed again are a change Apply can make")
            var dumped = ""
            dump(c, to: &dumped)
            check(!dumped.contains("oldSecret1") && !dumped.contains("newSecret2"), "\(name): a dump shows neither password")
            c.putBack()
            rig.waitForCall(6, "\(name): Put Back")
            check(rig.fake.calls.last == .setProfile(3, old, redial: true), "\(name): Put Back writes the settings before")
            rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: typed, after: old, redial: .done(radioOn))))
            rig.answerSettings(7, .success(listing(three: old)), .success(ready), "\(name): the read after Put Back")
            check(c.undo == nil && c.form == old && !c.formEdited, "\(name): Put Back clears the undo and fills the form")
            c.setTabShown(nil)
        }

        // Without the settings before (nothing was sent), the undo stays as it was; a Put Back that fails keeps
        // the undo it was to apply, also when it may have changed the profile.
        let rig = Rig()
        rig.driver = 3
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing(three: old)), .success(ready), "the first read")
        c.form?.apn = "a"
        c.applyProfile()
        rig.waitForCall(3, "a change that sends nothing")
        rig.fake.releaseProfile(.failure(ModemFailure(message: "Profile 3 could not be read. Nothing was changed.")))
        rig.answerSettings(4, .success(listing(three: old)), .success(ready), "the read after it")
        check(c.undo == nil && c.resultIsFailure, "way back: nothing sent: no undo", "\(String(describing: c.undo))")
        let applied = c.form!
        c.applyProfile()
        rig.waitForCall(6, "a change made")
        rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: old, after: applied, redial: .done(radioOn))))
        rig.answerSettings(7, .success(listing(three: applied)), .success(ready), "the read after it")
        check(c.undo == .profile(id: 3, old), "way back: a change made sets the undo")
        c.putBack()
        rig.waitForCall(9, "a put back that will fail")
        rig.fake.releaseProfile(.failure(ModemFailure(message: "It is not known whether profile 3 was changed.", profileBefore: applied)))
        rig.answerSettings(10, .success(listing(three: applied)), .success(ready), "the read after it")
        check(c.undo == .profile(id: 3, old) && c.resultIsFailure, "way back: a failed Put Back keeps the undo it was to apply",
              "\(String(describing: c.undo))")
        check(c.form == applied && !c.formEdited, "way back: an unedited form follows the read after a failed Put Back")
        c.setTabShown(nil)
    }

    // A change asked for while a read runs (a turn began just before its confirmation opened) waits for
    // it on the queue and starts as soon as it has finished (R12); at most one waits; a change running or
    // waiting turns the buttons off, a read does not.
    static func queuedChanges() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.tick()
        rig.waitForCall(2, "a turn starts")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled && c.refreshEnabled, "queue: a read leaves Change and Refresh on")
        c.changeMode()
        check(c.result == waitingLine && !c.resultIsFailure && c.running == .reading, "queue: the change waits for the read", c.result)
        check(!c.modeChangeEnabled && !c.refreshEnabled && !c.pinEnabled && !c.applyEnabled,
              "queue: a waiting change turns the buttons off")
        c.setRadio(on: false)
        check(c.result == anotherChange && c.resultIsFailure, "queue: a second change while one waits is refused with a sentence",
              c.result)
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls == [.networkInfo, .networkInfo], "queue: the waiting change has not reached the service yet",
              "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.waitForCall(3, "the waiting change starts after the read")
        check(rig.fake.calls.last == .setMode("LTE") && c.running == .mode, "queue: the change starts as soon as the read has finished",
              "\(rig.fake.calls)")
        check(c.result == "Changing the network mode to LTE only…" && !c.resultIsFailure, "queue: then its running line", c.result)
        check(c.info == network("AUTO") && c.infoAt != nil, "queue: the read before it was applied")
        let change = ModeChange(before: "AUTO", after: "LTE")
        rig.fake.releaseMode(.success(change))
        rig.answerInfo(4, .success(network("LTE")), "the read after the change")
        check(c.undo == .mode("AUTO") && c.result == modeSentence(change) && !c.resultIsFailure, "queue: the change was made", c.result)
        settle()
        check(rig.fake.calls.count == 4 && rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0,
              "queue: the refused radio switch never ran; one call at a time, on the queue", "\(rig.fake.calls)")

        // The view calls the action before setConfirming(false): it starts at once, before the read that
        // became due while the confirmation was open; that read follows it.
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        c.setRadio(on: false)
        rig.waitForCall(5, "the confirmed change starts at once")
        check(rig.fake.calls.last == .setRadio(false) && c.running == .radio, "queue: a confirmed change starts at once")
        c.setConfirming(false)
        settle()
        check(rig.fake.calls.count == 5, "queue: no read while the change runs")
        rig.fake.releaseRadio(.success(radioOff))
        rig.answerInfo(6, .success(network("LTE")), "the read after the change")
        check(c.result == radioSentence(radioOff), "queue: the change's sentence", c.result)

        // The other order (setConfirming(false) first, so the due read starts): the change is not refused,
        // it waits for that read (reviewer minor 8).
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        c.setConfirming(false)
        rig.waitForCall(7, "the read that was due starts")
        c.setRadio(on: true)
        check(c.result == waitingLine, "queue: a change confirmed after the read started waits for it", c.result)
        rig.fake.releaseInfo(.success(network("LTE")))
        rig.waitForCall(8, "the change after the read")
        check(rig.fake.calls.last == .setRadio(true) && c.running == .radio, "queue: then it starts")
        rig.fake.releaseRadio(.success(radioOn))
        rig.answerInfo(9, .success(network("LTE")), "the read after the change")
        check(c.result == radioSentence(radioOn) && !c.resultIsFailure, "queue: the change was made", c.result)
        c.setTabShown(nil)

        // A PIN that waits: the attempts the confirmation showed go to the service unchanged, not the ones
        // read meanwhile (R13), and no stored property holds the PIN while it waits.
        let rig2 = Rig()
        let p = rig2.controller
        p.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        p.tick()
        rig2.waitForCall(3, "a turn starts")
        let pin = "75318642"
        p.enterPin(pin, shownAttempts: 3)
        check(p.result == waitingLine && !p.pinEnabled, "queue: the PIN waits for the read", p.result)
        check(keepsNoCopy(p, of: pin), "queue: no stored property holds a waiting PIN")
        p.enterPin(pin, shownAttempts: 3)
        check(p.result == anotherChangePin && p.resultIsFailure, "queue: a second PIN while one waits is refused", p.result)
        rig2.fake.releaseProfiles(.success(listing()))
        rig2.waitForCall(4, "sim()")
        rig2.fake.releaseSim(.success(asksPin(2)))
        rig2.waitForCall(5, "the PIN after the read")
        check(rig2.fake.calls.last == .enterPin(pin, shownAttempts: 3) && p.running == .pin,
              "queue: the attempts shown are passed unchanged, not the ones read meanwhile (R13)")
        check(p.sim == asksPin(2), "queue: the read before the PIN was applied")
        rig2.fake.releasePin(.success(PinOutcome(accepted: false, sim: asksPin(2), refusal: "+CME ERROR: 16")))
        rig2.answerSettings(6, .success(listing()), .success(asksPin(2)), "the read after the PIN")
        check(keepsNoCopy(p, of: pin), "queue: no stored property holds the PIN afterwards")
        check(rig2.fake.calls.count == 7, "queue: the refused second PIN was never sent", "\(rig2.fake.calls.count)")
        p.setTabShown(nil)
    }

    // An explicit Refresh: works in a visible window with a tab shown; does nothing (and is off) while a
    // confirmation is open; does nothing while the window is hidden; adds nothing to a read that runs.
    static func refreshing() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.refresh()
        rig.answerInfo(2, .success(network("AUTO")), "Refresh in a visible window reads at once")
        c.setConfirming(true)
        check(!c.refreshEnabled, "refresh: off while a confirmation is open")
        c.refresh()
        settle()
        check(rig.fake.calls.count == 2, "refresh: does nothing while a confirmation is open", "\(rig.fake.calls)")
        c.setConfirming(false)
        check(c.refreshEnabled, "refresh: on again when the confirmation closes")
        settle()
        check(rig.fake.calls.count == 2, "refresh: a Refresh refused during the confirmation is not run later", "\(rig.fake.calls)")
        c.setWindowVisible(false)
        c.refresh()
        settle()
        check(rig.fake.calls.count == 2, "refresh: does nothing while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(3, .success(network("AUTO")), "the window shows again")
        c.refresh()
        rig.waitForCall(4, "a Refresh")
        c.refresh()
        settle()
        check(rig.fake.calls.count == 4, "refresh: a second Refresh while a read runs adds nothing", "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        c.setTabShown(nil)
        c.refresh()
        settle()
        check(rig.fake.calls.count == 4, "refresh: does nothing with no modem tab shown", "\(rig.fake.calls)")
    }

    // Every change that does nothing says why on the result line, and nothing reaches the service.
    static func nothingDone() {
        let rig = Rig()
        let c = rig.controller
        c.putBack()
        check(c.result == "There is no change to put back." && c.resultIsFailure, "nothing: Put Back with no undo", c.result)
        c.applyProfile()
        check(c.result == "The settings of profile 1 have not been read. Nothing was changed.", "nothing: Apply before a read", c.result)
        c.changeMode()
        check(c.result == "Choose a network mode first. Nothing was changed.", "nothing: Change with no pick", c.result)
        c.enterPin("1234", shownAttempts: 3)
        check(c.result == "The SIM has not been read yet. The PIN was not sent.", "nothing: Unlock before the SIM is read", c.result)

        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.changeMode()
        check(c.result == "The network mode is already automatic (5G, LTE and WCDMA). Nothing was changed.",
              "nothing: Change to the mode the modem has", c.result)
        c.pickedMode = "5g"
        c.changeMode()
        check(c.result == "RMNet cannot set the network mode 5g. Nothing was changed.", "nothing: Change to a mode RMNet cannot set",
              c.result)

        c.setTabShown(.simAndApn)
        rig.answerSettings(2, .success(listing()), .success(ready), "the settings read")
        c.applyProfile()
        check(c.result == "Profile 1 already has these settings. Nothing was changed.", "nothing: Apply of an unedited form", c.result)
        c.form?.apn = "cm net"
        c.applyProfile()
        check(c.result == profileProblem(1, c.form!)! + " Nothing was changed." && c.resultIsFailure,
              "nothing: Apply with a problem says the rule", c.result)
        c.enterPin("1234", shownAttempts: 3)
        check(c.result == "The SIM does not ask for its PIN now (SIM: ready). The PIN was not sent.",
              "nothing: Unlock when the SIM does not ask for its PIN", c.result)
        rig.driver = 7
        c.tick()
        rig.answerSettings(4, .success(listing()), .success(ready), "the driver on profile 7")
        c.applyProfile()
        check(c.result == "The modem does not list profile 7. Nothing was changed.", "nothing: Apply to a profile not listed", c.result)
        settle()
        check(rig.fake.calls == [.networkInfo, .profiles, .sim, .profiles, .sim], "nothing: none of them reached the service",
              "\(rig.fake.calls)")
        c.setTabShown(nil)
    }

    // enterPin: the PIN with the attempts the owner was shown; pinSentence, a refusal said as a failure;
    // the controller keeps no copy of the PIN; a malformed PIN or a SIM not asking sends nothing.
    static func pinEntry() {
        let pin = "97538642"
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        c.enterPin(pin, shownAttempts: 3)
        rig.waitForCall(3, "the PIN reaches the service")
        check(rig.fake.calls.last == .enterPin(pin, shownAttempts: 3), "pin: the PIN goes with the attempts the owner was shown")
        check(c.running == .pin && c.result == "Sending the PIN to the SIM…" && !c.pinEnabled, "pin: the running sentence", c.result)
        check(keepsNoCopy(c, of: pin), "pin: no stored property holds the PIN while it is checked")
        let taken = PinOutcome(accepted: true, sim: ready)
        rig.fake.releasePin(.success(taken))
        rig.waitForCall(4, "the tab is read again after the PIN")
        check(rig.fake.calls.last == .profiles, "pin: the SIM & APN tab is read again")
        check(c.result == pinSentence(taken) && !c.resultIsFailure, "pin: the accepted sentence", c.result)
        check(keepsNoCopy(c, of: pin), "pin: no stored property holds the PIN after the call")
        rig.fake.releaseProfiles(.success(listing()))
        rig.waitForCall(5, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(!c.pinEnabled && c.sim == ready, "pin: Unlock is off once the SIM is ready")
        c.enterPin(pin, shownAttempts: 3)
        settle()
        check(rig.fake.calls.count == 5, "pin: nothing is sent while the SIM does not ask for its PIN")
        check(c.result == "The SIM does not ask for its PIN now (SIM: ready). The PIN was not sent." && c.resultIsFailure,
              "pin: and it says why", c.result)
        c.setTabShown(nil)

        // A refused PIN, the last attempt, a failure, and a malformed PIN.
        let rig2 = Rig()
        let p = rig2.controller
        p.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(asksPin(2)), "the first settings read")
        let other = "86420135"
        p.enterPin(other, shownAttempts: 2)
        rig2.waitForCall(3, "the PIN reaches the service")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 2), "pin: 2 attempts shown, 2 passed")
        let wrong = PinOutcome(accepted: false, sim: asksPin(1), refusal: "+CME ERROR: 16")
        rig2.fake.releasePin(.success(wrong))
        rig2.waitForCall(4, "the read after the refused PIN starts")
        check(p.sim == asksPin(1) && p.pinEnabled, "pin: the SIM read with the outcome is shown at once (1 attempt left)")
        rig2.fake.releaseProfiles(.success(listing()))
        rig2.waitForCall(5, "sim()")
        rig2.fake.releaseSim(.success(asksPin(1)))
        pump(until: { p.running == nil }, "the read comes back")
        check(p.result == pinSentence(wrong) && p.resultIsFailure, "pin: a refused PIN is said as a failure", p.result)
        check(keepsNoCopy(p, of: other), "pin: no stored property holds a refused PIN")

        p.enterPin(other, shownAttempts: 1)
        rig2.waitForCall(6, "the last attempt")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 1), "pin: the last attempt passes 1")
        rig2.fake.releasePin(.failure(notAnswered))
        rig2.answerSettings(7, .success(listing()), .success(asksPin(1)), "the read after the failure")
        check(p.result == notAnswered.message && p.resultIsFailure, "pin: a failure's sentence", p.result)

        p.enterPin("12a4", shownAttempts: 1)
        p.enterPin("123", shownAttempts: 1)
        settle()
        check(rig2.fake.calls.count == 8, "pin: a malformed PIN is not sent")
        check(p.result == "A PIN is 4 to 8 digits. The PIN was not sent." && p.resultIsFailure,
              "pin: a malformed PIN is refused with the rule", p.result)
        p.enterPin(other, shownAttempts: 0)
        settle()
        check(rig2.fake.calls.count == 8, "pin: nothing is sent when the confirmation showed no attempts left")
        check(p.result == "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not enter PUKs. "
              + "The PIN was not sent.", "pin: and it says why", p.result)
        p.enterPin(other, shownAttempts: 2)
        rig2.waitForCall(9, "attempts shown that differ from the SIM read")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 2), "pin: the attempts shown are passed unchanged (R13)")
        rig2.fake.releasePin(.failure(ModemFailure(message: "The SIM now shows 1 attempt left, not 2. The PIN was not sent.")))
        rig2.answerSettings(10, .success(listing()), .success(asksPin(1)), "the read after it")
        check(keepsNoCopy(p, of: other), "pin: still no copy afterwards")
        p.setTabShown(nil)
    }

    // The bands are read with the Network tab's read, in its block after networkInfo(), only while they are
    // due: when the Network tab comes into view (shown, or its window seen again), on Refresh there, and after
    // a bands change (bandsChanges); not on the timer's other turns, nor with the SIM & APN tab's read, nor
    // while no modem tab is shown, the window is hidden or a confirmation (or the bands sheet) is open. A turn
    // whose network read failed skips them and leaves them due; a bands read that failed keeps the last bands,
    // says why and leaves them due; only one that succeeded clears that.
    static func bandsReading() {
        let rig = Rig()
        let c = rig.controller
        check(c.bands == nil && c.bandsFailure == nil && !c.bandsDue, "bands: nothing is known or due at first")
        c.setTabShown(.network)
        check(c.bandsDue, "bands: due once the Network tab is shown")
        rig.waitForCall(1, "the Network tab is read")
        check(rig.fake.bandsReads == 0 && c.bands == nil, "bands: read after networkInfo() has returned", "\(rig.fake.allCalls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the first read comes back")
        check(rig.fake.allCalls == [.networkInfo, .bands], "bands: the first read is networkInfo() then bands()",
              "\(rig.fake.allCalls)")
        check(c.bands == bandSets() && c.bandsFailure == nil && !c.bandsDue, "bands: a good read sets the bands; no longer due")
        check(c.result == "", "bands: a read never writes the result line", c.result)

        // The turns that follow read the network only.
        c.tick()
        rig.answerInfo(2, .success(network("AUTO")), "a tick")
        timer(of: c)?.fire()
        rig.answerInfo(3, .success(network("AUTO")), "a timer turn")
        check(rig.fake.bandsReads == 1 && !c.bandsDue, "bands: not read on the timer's turns", "\(rig.fake.allCalls)")

        // Refresh reads them again.
        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        c.refresh()
        check(c.bandsDue, "bands: due again on Refresh")
        rig.answerInfo(4, .success(network("AUTO")), "a Refresh")
        check(rig.fake.bandsReads == 2 && c.bands == bandSets(sa: [41]) && !c.bandsDue,
              "bands: Refresh reads them, and they are no longer due", "\(rig.fake.allCalls)")

        // A turn whose network read fails skips them: still due, and read on the next turn whose read succeeds.
        rig.fake.bandsAnswer = .success(bandSets(lte: [3]))
        c.refresh()
        rig.answerInfo(5, .failure(portBusy), "a Refresh whose network read fails")
        check(rig.fake.bandsReads == 2 && c.bandsDue, "bands: skipped after a failed network read, and still due",
              "\(rig.fake.allCalls)")
        check(c.bands == bandSets(sa: [41]) && c.bandsFailure == nil && c.infoFailure == portBusy.message,
              "bands: the last bands are kept; the failure is the network read's own")
        c.tick()
        rig.answerInfo(6, .success(network("LTE")), "the next turn")
        check(rig.fake.bandsReads == 3 && c.bands == bandSets(lte: [3]) && !c.bandsDue,
              "bands: read on the next turn, then no longer due", "\(rig.fake.allCalls)")

        // A bands read that fails: the bands are kept, the failure said, and they stay due until one succeeds.
        rig.fake.queueBands(.failure(portBusy))
        c.refresh()
        rig.answerInfo(7, .success(network("LTE")), "a Refresh whose bands read fails")
        check(rig.fake.bandsReads == 4 && c.bands == bandSets(lte: [3]) && c.bandsFailure == portBusy.message && c.bandsDue,
              "bands: a failed bands read keeps the bands, says why, and leaves them due",
              "\(String(describing: c.bandsFailure))")
        check(c.info == network("LTE") && c.infoFailure == nil, "bands: their failure is not the network read's")
        c.tick()
        rig.answerInfo(8, .success(network("LTE")), "the next turn")
        check(rig.fake.bandsReads == 5 && c.bandsFailure == nil && !c.bandsDue,
              "bands: read again on the next turn; a good read clears the failure", "\(rig.fake.allCalls)")

        // The other tab never reads them nor makes them due; back on the Network tab they are due and read at once.
        c.setTabShown(.simAndApn)
        rig.answerSettings(9, .success(listing()), .success(ready), "the SIM & APN tab")
        c.refresh()
        rig.answerSettings(11, .success(listing()), .success(ready), "a Refresh of the SIM & APN tab")
        check(rig.fake.bandsReads == 5 && !c.bandsDue, "bands: not read or made due by the SIM & APN tab",
              "\(rig.fake.allCalls)")
        check(c.bands == bandSets(lte: [3]), "bands: kept while the other tab is shown")
        c.setTabShown(.network)
        check(c.bandsDue, "bands: due when the Network tab is shown again")
        rig.answerInfo(13, .success(network("LTE")), "back on the Network tab")
        check(rig.fake.bandsReads == 6 && !c.bandsDue, "bands: read when the Network tab is shown again", "\(rig.fake.allCalls)")

        // The window hidden: nothing, and Refresh makes nothing due; seen again: due and read at once.
        c.setWindowVisible(false)
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.bandsReads == 6 && rig.fake.calls.count == 13 && !c.bandsDue,
              "bands: nothing is read, nor made due by Refresh, while the window is hidden")
        c.setWindowVisible(true)
        check(c.bandsDue, "bands: due when the window is seen again")
        rig.answerInfo(14, .success(network("LTE")), "the window seen again")
        check(rig.fake.bandsReads == 7 && !c.bandsDue, "bands: read when the window is seen again")

        // A confirmation (or the bands sheet) open: nothing is read, and Refresh makes nothing due.
        c.setConfirming(true)
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        settle()
        check(rig.fake.bandsReads == 7 && rig.fake.calls.count == 14 && !c.bandsDue,
              "bands: nothing is read while a confirmation is open")
        c.setConfirming(false)
        c.setTabShown(nil)
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.bandsReads == 7 && rig.fake.calls.count == 14, "bands: nothing is read with no modem tab shown")
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "bands: one call at a time, on the queue")

        // A first network read that fails: the bands are not read, stay unknown (not read yet) and due.
        let rig2 = Rig()
        let d = rig2.controller
        d.setTabShown(.network)
        rig2.answerInfo(1, .failure(notAnswered), "a first network read that fails")
        check(rig2.fake.bandsReads == 0 && d.bands == nil && d.bandsFailure == nil && d.bandsDue,
              "bands: not read after a failed first network read, and still due", "\(rig2.fake.allCalls)")
        d.tick()
        rig2.answerInfo(2, .success(network("AUTO")), "the next turn")
        check(rig2.fake.bandsReads == 1 && d.bands == bandSets() && !d.bandsDue, "bands: read on the next turn")
        d.setTabShown(nil)

        // A first bands read that fails: the bands stay unknown, and the failure is said.
        let rig3 = Rig()
        let e = rig3.controller
        rig3.fake.bandsAnswer = .failure(notAnswered)
        e.setTabShown(.network)
        rig3.answerInfo(1, .success(network("AUTO")), "a first read whose bands fail")
        check(e.bands == nil && e.bandsFailure == notAnswered.message && e.info == network("AUTO") && e.bandsDue,
              "bands: a failed first read leaves them unknown, says why, and leaves them due")
        check(!e.bandsChangeEnabled && !e.resetAllBandsEnabled, "bands: no Change… or Reset all while they are unknown")
        e.setTabShown(nil)
    }

    // The bands' words as the tab shows them (as `RMNet bands` prints them), and when its buttons are on:
    // Change… once the bands are read; Reset for a RAT that does not allow every supported band; Reset all
    // when any does not. All off while a change runs or waits, a confirmation (or the sheet) is open, or the
    // app quits; a read leaves them on (R12). The sheet's Apply: on for a selection that is a change the
    // modem can take (bandsProblem: not empty, every band supported), also while the sheet is open.
    static func bandsEnabled() {
        check(bandsSummary(BandSet(rat: .lte, allowed: lteSupported, supported: lteSupported)) == "all 31 supported bands allowed",
              "words: every supported band allowed", bandsSummary(BandSet(rat: .lte, allowed: lteSupported, supported: lteSupported)))
        check(bandsSummary(BandSet(rat: .lte, allowed: [41, 3], supported: lteSupported)) == "2 of 31 supported bands allowed: 3, 41",
              "words: some bands allowed", bandsSummary(BandSet(rat: .lte, allowed: [41, 3], supported: lteSupported)))
        check(bandsSummary(BandSet(rat: .nsa, allowed: [], supported: nrSupported)) == "0 of 28 supported bands allowed: none",
              "words: no band allowed")
        check(bandLabel(.lte, 3) == "B3" && bandLabel(.nsa, 78) == "n78" && bandLabel(.sa, 41) == "n41",
              "words: the sheet's labels, B for LTE and n for 5G")

        let rig = Rig()
        let c = rig.controller
        check(!c.bandsChangeEnabled && !c.resetAllBandsEnabled && !c.bandsResetEnabled(.lte) && !c.bandsApplyEnabled(.sa, [41]),
              "enabled: all off before the bands are read")
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        check(c.bandsChangeEnabled, "enabled: Change… on once the bands are read")
        check(BandRat.allCases.allSatisfy { !c.bandsResetEnabled($0) } && !c.resetAllBandsEnabled,
              "enabled: no Reset and no Reset all while every RAT allows every supported band")

        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        c.refresh()
        rig.answerInfo(2, .success(network("AUTO")), "5G SA locked to 41, read on Refresh")
        check(c.bandsResetEnabled(.sa) && !c.bandsResetEnabled(.lte) && !c.bandsResetEnabled(.nsa) && c.resetAllBandsEnabled,
              "enabled: Reset for the RAT locked, and Reset all")
        check(!c.bandsApplyEnabled(.sa, []), "apply: off with nothing checked")
        check(!c.bandsApplyEnabled(.sa, [41]) && !c.bandsApplyEnabled(.sa, [41, 41]), "apply: off for the bands allowed now")
        check(c.bandsApplyEnabled(.sa, [78, 41]) && c.bandsApplyEnabled(.sa, nrSupported), "apply: on for another selection")
        check(!c.bandsApplyEnabled(.sa, [41, 4]), "apply: off with a band the modem does not support")
        check(c.bandsApplyEnabled(.lte, [3]) && !c.bandsApplyEnabled(.lte, lteSupported), "apply: per RAT")

        c.tick()
        rig.waitForCall(3, "a turn starts")
        check(c.bandsChangeEnabled && c.bandsResetEnabled(.sa) && c.resetAllBandsEnabled && c.bandsApplyEnabled(.sa, [78]),
              "enabled: a read leaves them on (R12)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the turn comes back")

        c.setConfirming(true)
        check(!c.bandsChangeEnabled && !c.bandsResetEnabled(.sa) && !c.resetAllBandsEnabled,
              "enabled: Change…, Reset and Reset all off while a confirmation or the sheet is open")
        check(c.bandsApplyEnabled(.sa, [78]), "apply: on in the open sheet")
        c.setConfirming(false)

        c.setRadio(on: false)
        rig.waitForCall(4, "a change runs")
        check(!c.bandsChangeEnabled && !c.bandsResetEnabled(.sa) && !c.resetAllBandsEnabled && !c.bandsApplyEnabled(.sa, [78]),
              "enabled: all off while a change runs")
        rig.fake.releaseRadio(.success(radioOff))
        rig.answerInfo(5, .success(network("AUTO")), "the read after the change")
        check(c.bandsChangeEnabled && c.bandsResetEnabled(.sa) && c.resetAllBandsEnabled && c.bandsApplyEnabled(.sa, [78]),
              "enabled: on again afterwards")
        check(c.quitWhenFinished() == false, "enabled: a quit with nothing running answers at once")
        check(!c.bandsChangeEnabled && !c.bandsResetEnabled(.sa) && !c.resetAllBandsEnabled && !c.bandsApplyEnabled(.sa, [78]),
              "enabled: all off once the app quits")
        c.setTabShown(nil)
    }

    // changeBands: the bands asked go to setBands once, sorted, each once; `.bands` runs and nothing else can
    // start; the result line; the RAT shows the bands read back at once, then the tab (the bands with it) is
    // read again, after a failure too. A change asked for while a read runs waits for it (R12).
    static func bandsChanges() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.changeBands(.sa, to: [41])
        rig.waitForCall(2, "the bands change reaches the service")
        check(rig.fake.calls.last == .setBands(.sa, [41]) && c.running == .bands, "change: setBands(.sa, [41]); .bands runs",
              "\(rig.fake.calls)")
        check(c.result == "Changing the 5G SA bands to 41…" && !c.resultIsFailure, "change: the running sentence", c.result)
        check(!c.bandsChangeEnabled && !c.resetAllBandsEnabled && !c.refreshEnabled && !c.modeChangeEnabled,
              "change: the buttons are off while it runs")
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        c.changeBands(.lte, to: [3])
        c.resetBands(.sa)
        c.resetAllBands()
        c.setRadio(on: false)
        settle()
        check(rig.fake.calls.count == 2 && rig.fake.bandsReads == 1, "change: nothing else starts while .bands runs",
              "\(rig.fake.allCalls)")
        check(c.result == anotherChange && c.resultIsFailure, "change: another change while it runs is refused with a sentence",
              c.result)
        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        rig.fake.releaseSetBands(.success(BandChange(before: nrSupported, after: [41])))
        rig.waitForCall(3, "the tab is read again after the change")
        check(rig.fake.calls.last == .networkInfo, "change: the Network tab is read again")
        check(c.bandsDue, "change: the bands are due again after the change")
        check(c.result == "5G SA bands set to 41." && !c.resultIsFailure, "change: the result line, ending with a period", c.result)
        check(c.bands == bandSets(sa: [41]), "change: the RAT shows the bands read back at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read after the change comes back")
        check(Array(rig.fake.allCalls.suffix(3)) == [.setBands(.sa, [41]), .networkInfo, .bands] && !c.bandsDue,
              "change: then the bands are read again, and are no longer due", "\(rig.fake.allCalls)")
        check(rig.fake.calls.filter({ $0 == .setBands(.sa, [41]) }).count == 1, "change: setBands is called once")
        check(c.bands == bandSets(sa: [41]) && c.result == "5G SA bands set to 41.", "change: the read after it leaves the result line")

        // Unsorted, a band twice: sorted, each once. A failure: its sentence, and the bands read again all the same.
        c.changeBands(.sa, to: [78, 41, 78])
        rig.waitForCall(4, "a change that will fail")
        check(rig.fake.calls.last == .setBands(.sa, [41, 78]), "change: the bands sorted, each once", "\(rig.fake.calls)")
        check(c.result == "Changing the 5G SA bands to 41, 78…", "change: the running sentence names them", c.result)
        let saRefused = ModemFailure(message: "The modem refused the command (+CME ERROR: 3). The 5G SA bands were not changed.")
        rig.fake.releaseSetBands(.failure(saRefused))
        rig.waitForCall(5, "the tab is read again after the failed change")
        check(c.bandsDue, "change: the bands are due again after a failed change too")
        check(c.result == saRefused.message && c.resultIsFailure, "change: a failure's sentence", c.result)
        check(c.bands == bandSets(sa: [41]), "change: a failure leaves the bands as last read")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read after the failure comes back")
        check(rig.fake.bandsReads == 3 && rig.fake.allCalls.last == .bands, "change: the bands are read again after a failure",
              "\(rig.fake.allCalls)")
        check(c.result == saRefused.message && c.resultIsFailure, "change: the read after it leaves the failure's sentence")

        // Every supported band: said so.
        c.changeBands(.sa, to: nrSupported)
        rig.waitForCall(6, "a change to every supported band")
        check(c.result == "Changing the 5G SA bands to all 28 supported bands…", "change: the running sentence for all", c.result)
        rig.fake.bandsAnswer = .success(bandSets())
        rig.fake.releaseSetBands(.success(BandChange(before: [41], after: nrSupported)))
        rig.answerInfo(7, .success(network("AUTO")), "the read after it")
        check(c.result == "5G SA bands set to all 28 supported bands." && !c.resultIsFailure, "change: the sentence for all", c.result)
        check(c.bands == bandSets(), "change: the bands as read")

        // The modem had them already (changed elsewhere since the last read): nothing written, and said.
        c.changeBands(.lte, to: [3])
        rig.waitForCall(8, "a change the modem has already")
        rig.fake.bandsAnswer = .success(bandSets(lte: [3]))
        rig.fake.releaseSetBands(.success(BandChange(before: [3], after: [3])))
        rig.answerInfo(9, .success(network("AUTO")), "the read after it")
        check(c.result == "The LTE bands are already 3. Nothing was changed." && !c.resultIsFailure,
              "change: bands the modem already had", c.result)
        check(c.bands == bandSets(lte: [3]), "change: the bands as read")

        // Asked for while a read runs: it waits for the read, then starts.
        c.tick()
        rig.waitForCall(10, "a turn starts")
        c.changeBands(.lte, to: [41, 3])
        check(c.result == waitingLine && c.running == .reading && !c.bandsChangeEnabled, "change: it waits for the read", c.result)
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.waitForCall(11, "the change after the read")
        check(rig.fake.calls.last == .setBands(.lte, [3, 41]) && c.running == .bands, "change: then it starts", "\(rig.fake.calls)")
        check(c.result == "Changing the LTE bands to 3, 41…", "change: then its running line", c.result)
        rig.fake.bandsAnswer = .success(bandSets(lte: [3, 41]))
        rig.fake.releaseSetBands(.success(BandChange(before: [3], after: [3, 41])))
        rig.answerInfo(12, .success(network("AUTO")), "the read after it")
        check(c.result == "LTE bands set to 3, 41." && !c.resultIsFailure && c.bands == bandSets(lte: [3, 41]),
              "change: made after the read", c.result)
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "change: one call at a time, on the queue")
        c.setTabShown(nil)
    }

    // resetBands: setBands(rat, its supported bands). resetAllBands: all three RATs, whatever the last read
    // showed, in the order LTE, 5G NSA, 5G SA, in one change (`.bands` throughout, no read between), then one
    // read; its result names only the RATs whose bands changed (or says none did); it stops at the first failure
    // and says which RATs were not reset.
    static func bandsResets() {
        let rig = Rig()
        let c = rig.controller
        rig.fake.bandsAnswer = .success(bandSets(lte: [3, 41], sa: [41]))
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.resetBands(.lte)
        rig.waitForCall(2, "the reset reaches the service")
        check(rig.fake.calls.last == .setBands(.lte, lteSupported) && c.running == .bands,
              "reset: setBands(.lte, its supported bands)", "\(rig.fake.calls)")
        check(c.result == "Resetting the LTE bands to all 31 supported bands…" && !c.resultIsFailure, "reset: the running sentence",
              c.result)
        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        rig.fake.releaseSetBands(.success(BandChange(before: [3, 41], after: lteSupported)))
        rig.waitForCall(3, "the tab is read again after the reset")
        check(c.result == "LTE bands set to all 31 supported bands." && !c.resultIsFailure, "reset: the result line", c.result)
        check(c.bands == bandSets(sa: [41]), "reset: the RAT shows the bands read back at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        check(rig.fake.allCalls.last == .bands && rig.fake.bandsReads == 2, "reset: the bands are read again", "\(rig.fake.allCalls)")

        // Reset all: the three in order in one change, then one read.
        rig.fake.bandsAnswer = .success(bandSets(lte: [3], nsa: [78], sa: [41]))
        c.refresh()
        rig.answerInfo(4, .success(network("AUTO")), "all three locked, read on Refresh")
        c.resetAllBands()
        rig.waitForCall(5, "Reset all starts with LTE")
        check(rig.fake.calls.last == .setBands(.lte, lteSupported) && c.running == .bands, "reset all: LTE first", "\(rig.fake.calls)")
        check(c.result == "Resetting the LTE, 5G NSA and 5G SA bands to all supported bands…", "reset all: the running sentence",
              c.result)
        rig.fake.releaseSetBands(.success(BandChange(before: [3], after: lteSupported)))
        rig.waitForCall(6, "then 5G NSA")
        check(rig.fake.calls.last == .setBands(.nsa, nrSupported) && c.running == .bands, "reset all: 5G NSA second, no read between",
              "\(rig.fake.calls)")
        rig.fake.releaseSetBands(.success(BandChange(before: [78], after: nrSupported)))
        rig.waitForCall(7, "then 5G SA")
        check(rig.fake.calls.last == .setBands(.sa, nrSupported) && c.running == .bands, "reset all: 5G SA third", "\(rig.fake.calls)")
        check(rig.fake.bandsReads == 3, "reset all: no read between the RATs", "\(rig.fake.allCalls)")
        rig.fake.bandsAnswer = .success(bandSets())
        rig.fake.releaseSetBands(.success(BandChange(before: [41], after: nrSupported)))
        rig.waitForCall(8, "one read after")
        check(rig.fake.calls.last == .networkInfo, "reset all: the tab is read again once")
        check(c.result == "LTE, 5G NSA and 5G SA bands set to all supported bands." && !c.resultIsFailure, "reset all: the result line",
              c.result)
        check(c.bands == bandSets(), "reset all: the bands read back, at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")

        // It stops at the first failure: the RATs from that one on are not reset, and the bands are read again.
        rig.fake.bandsAnswer = .success(bandSets(lte: [3], nsa: [78], sa: [41]))
        c.refresh()
        rig.answerInfo(9, .success(network("AUTO")), "all three locked again")
        c.resetAllBands()
        rig.waitForCall(10, "LTE")
        rig.fake.releaseSetBands(.success(BandChange(before: [3], after: lteSupported)))
        rig.waitForCall(11, "5G NSA, which will fail")
        check(rig.fake.calls.last == .setBands(.nsa, nrSupported), "reset all: 5G NSA after LTE", "\(rig.fake.calls)")
        rig.fake.bandsAnswer = .success(bandSets(nsa: [78], sa: [41]))
        rig.fake.releaseSetBands(.failure(bandsRefused))
        rig.waitForCall(12, "the read after the failure")
        check(rig.fake.calls.last == .networkInfo, "reset all: stops at the first failure: 5G SA is not tried", "\(rig.fake.calls)")
        check(c.result == "LTE bands set to all supported bands. " + bandsRefused.message + " Not reset: 5G NSA and 5G SA."
              && c.resultIsFailure, "reset all: the RATs reset, the failure, and the RATs not reset", c.result)
        check(c.bands == bandSets(nsa: [78], sa: [41]), "reset all: the RAT reset shows its bands read back")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        check(rig.fake.allCalls.last == .bands, "reset all: the bands are read again after a failure", "\(rig.fake.allCalls)")

        // A RAT that the last read showed allowing every supported band is sent all the same (the service leaves
        // it as it is) and not named; a failure on the first RAT that was to change: the result names none set.
        check(c.bands == bandSets(nsa: [78], sa: [41]), "reset all: LTE allows every supported band, as read")
        c.resetAllBands()
        rig.waitForCall(13, "Reset all with LTE not locked")
        check(rig.fake.calls.last == .setBands(.lte, lteSupported), "reset all: LTE, not locked, is sent all the same",
              "\(rig.fake.calls)")
        check(c.result == "Resetting the LTE, 5G NSA and 5G SA bands to all supported bands…", "reset all: all three, always",
              c.result)
        rig.fake.releaseSetBands(.success(BandChange(before: lteSupported, after: lteSupported)))
        rig.waitForCall(14, "then 5G NSA, which will fail")
        check(rig.fake.calls.last == .setBands(.nsa, nrSupported), "reset all: 5G NSA after LTE", "\(rig.fake.calls)")
        rig.fake.releaseSetBands(.failure(notAnswered))
        rig.answerInfo(15, .success(network("AUTO")), "the read after the failure")
        check(c.result == notAnswered.message + " Not reset: 5G NSA and 5G SA." && c.resultIsFailure,
              "reset all: LTE, unchanged, is not named; the failure and the RATs not reset", c.result)

        // Only the RATs whose bands changed are named.
        check(c.bands == bandSets(nsa: [78], sa: [41]), "reset all: 5G NSA and 5G SA still locked, as read again")
        c.resetAllBands()
        rig.waitForCall(16, "LTE")
        rig.fake.releaseSetBands(.success(BandChange(before: lteSupported, after: lteSupported)))
        rig.waitForCall(17, "5G NSA")
        rig.fake.releaseSetBands(.success(BandChange(before: [78], after: nrSupported)))
        rig.waitForCall(18, "5G SA")
        rig.fake.bandsAnswer = .success(bandSets())
        rig.fake.releaseSetBands(.success(BandChange(before: [41], after: nrSupported)))
        rig.answerInfo(19, .success(network("AUTO")), "the read after it")
        check(c.result == "5G NSA and 5G SA bands set to all supported bands." && !c.resultIsFailure,
              "reset all: only the RATs whose bands changed are named", c.result)
        check(rig.fake.calls.filter({ if case .setBands = $0 { return true } else { return false } }).count == 11,
              "reset all: one setBands for each RAT of each Reset all, and for the Reset", "\(rig.fake.calls)")

        // None changed (the modem had every supported band again, set elsewhere since the last read): said so, not
        // as a failure, and the bands shown are those read back.
        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        c.refresh()
        rig.answerInfo(20, .success(network("AUTO")), "5G SA locked, read on Refresh")
        rig.fake.bandsAnswer = .success(bandSets())
        c.resetAllBands()
        rig.waitForCall(21, "LTE")
        rig.fake.releaseSetBands(.success(BandChange(before: lteSupported, after: lteSupported)))
        rig.waitForCall(22, "5G NSA")
        rig.fake.releaseSetBands(.success(BandChange(before: nrSupported, after: nrSupported)))
        rig.waitForCall(23, "5G SA")
        rig.fake.releaseSetBands(.success(BandChange(before: nrSupported, after: nrSupported)))
        rig.waitForCall(24, "the read after it")
        check(c.result == "Bands: all supported bands were already allowed." && !c.resultIsFailure,
              "reset all: none changed", c.result)
        check(c.bands == bandSets(), "reset all: the bands read back, at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "reset: one call at a time, on the queue")
        c.setTabShown(nil)
    }

    // A bands change that would do nothing, or that the modem cannot take, says why on the result line and
    // nothing reaches the service: never an empty list or a band not supported. Nothing starts once the
    // app quits.
    static func bandsNothingDone() {
        let rig = Rig()
        let c = rig.controller
        c.changeBands(.sa, to: [41])
        check(c.result == "The 5G SA bands have not been read. Nothing was changed." && c.resultIsFailure,
              "nothing: Change before the bands are read", c.result)
        c.resetBands(.lte)
        check(c.result == "The LTE bands have not been read. Nothing was changed." && c.resultIsFailure,
              "nothing: Reset before the bands are read", c.result)
        c.resetAllBands()
        check(c.result == "The bands have not been read. Nothing was changed." && c.resultIsFailure,
              "nothing: Reset all before the bands are read", c.result)

        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.changeBands(.sa, to: [])
        check(c.result == "At least one 5G SA band is needed. Nothing was changed." && c.resultIsFailure,
              "nothing: no band", c.result)
        c.changeBands(.sa, to: [41, 4])
        check(c.result == "The modem does not support 5G SA band 4 (supported: \(bandListWords(nrSupported))). Nothing was changed."
              && c.resultIsFailure, "nothing: a band the modem does not support", c.result)
        c.changeBands(.sa, to: nrSupported.reversed())
        check(c.result == "The 5G SA bands are already all 28 supported bands. Nothing was changed." && c.resultIsFailure,
              "nothing: Change to the bands allowed now", c.result)
        c.resetBands(.lte)
        check(c.result == "The LTE bands are already all 31 supported bands. Nothing was changed." && c.resultIsFailure,
              "nothing: Reset of a RAT that allows every supported band", c.result)
        c.resetAllBands()
        check(c.result == "LTE, 5G NSA and 5G SA already allow all their supported bands. Nothing was changed."
              && c.resultIsFailure, "nothing: Reset all when every RAT allows every supported band", c.result)
        rig.fake.bandsAnswer = .success(bandSets(sa: [41]))
        c.refresh()
        rig.answerInfo(2, .success(network("AUTO")), "5G SA locked")
        c.changeBands(.sa, to: [41])
        check(c.result == "The 5G SA bands are already 41. Nothing was changed." && c.resultIsFailure,
              "nothing: Change to the band allowed now", c.result)
        settle()
        check(rig.fake.calls == [.networkInfo, .networkInfo], "nothing: none of them reached the service", "\(rig.fake.calls)")

        check(c.quitWhenFinished() == false, "nothing: the quit answers at once")
        c.changeBands(.sa, to: [41, 78])
        c.resetBands(.sa)
        c.resetAllBands()
        settle()
        check(rig.fake.calls.count == 2 && c.running == nil, "nothing: no bands change starts once the app quits",
              "\(rig.fake.calls)")
        c.setTabShown(nil)
    }

    // Quitting: at once with nothing running; otherwise the line for what runs, then true after a read or
    // a change that succeeded, false (and attention, and working again) after one that failed.
    static func quitting() {
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.network)
            rig.answerInfo(1, .success(network("AUTO")), "the first read")
            check(c.quitWhenFinished() == false, "quit: nothing running answers at once (terminate now)")
            check(timer(of: c) == nil && c.quitNotice.line == "", "quit: the timer stops; no line")
            c.tick()
            c.refresh()
            c.setRadio(on: false)
            c.pickedMode = "LTE"
            c.changeMode()
            c.changeBands(.sa, to: [41])
            c.resetAllBands()
            c.setWindowVisible(false)
            c.setWindowVisible(true)
            c.setTabShown(.simAndApn)
            settle()
            check(rig.fake.calls.count == 1 && rig.replies.isEmpty && rig.attention == 0 && timer(of: c) == nil,
                  "quit: nothing starts and no later reply", "\(rig.fake.calls)")
            check(!c.refreshEnabled && !c.modeChangeEnabled && !c.bandsChangeEnabled, "quit: nothing is enabled while the app ends")
        }

        struct Case {
            let name: String
            let tab: ModemTab
            let notice: String
            let goesAhead: Bool
            let calls: Int  // calls the activity makes
            let start: (ModemController) -> Void
            let end: (FakeService) -> Void
            let result: String?  // the result line after a failure
            var bands = bandSets()  // what the bands reads answer
        }
        let reading = "RMNet quits when the current request to the modem has finished."
        let radioBack = "RMNet quits when the radio has been switched back on."
        let radioOffLine = "RMNet quits when the radio has been switched off."
        let modeLine = "RMNet quits when the network mode has been changed."
        let pinLine = "RMNet quits when the PIN has been checked."
        let edited = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
        let applied = ProfileChange(id: 1, before: profile1, after: edited, redial: .done(radioOn))
        let leftOff = ProfileChange(id: 1, before: profile1, after: edited, redial: .radioLeftOff("The modem did not answer in time."))
        let refusedPin = PinOutcome(accepted: false, sim: asksPin(2), refusal: "+CME ERROR: 16")
        let tick: (ModemController) -> Void = { $0.tick() }
        let apply: (ModemController) -> Void = { $0.form?.apn = "cmnet"; $0.applyProfile() }
        let changeMode: (ModemController) -> Void = { $0.pickedMode = "LTE"; $0.changeMode() }
        let unlock: (ModemController) -> Void = { $0.enterPin("24681357", shownAttempts: 3) }
        let cases: [Case] = [
            Case(name: "a network read", tab: .network, notice: reading, goesAhead: true, calls: 1, start: tick,
                 end: { $0.releaseInfo(.success(network("AUTO"))) }, result: nil),
            Case(name: "a network read that fails", tab: .network, notice: reading, goesAhead: true, calls: 1, start: tick,
                 end: { $0.releaseInfo(.failure(portBusy)) }, result: nil),
            Case(name: "a settings read", tab: .simAndApn, notice: reading, goesAhead: true, calls: 2, start: tick,
                 end: { $0.releaseProfiles(.success(listing())); $0.releaseSim(.success(asksPin(3))) }, result: nil),
            Case(name: "a radio switch", tab: .network, notice: radioBack, goesAhead: true, calls: 1,
                 start: { $0.setRadio(on: true) }, end: { $0.releaseRadio(.success(radioOn)) }, result: nil),
            Case(name: "a radio switch off", tab: .network, notice: radioOffLine, goesAhead: true, calls: 1,
                 start: { $0.setRadio(on: false) }, end: { $0.releaseRadio(.success(radioOff)) }, result: nil),
            Case(name: "a radio switch off that fails", tab: .network, notice: radioOffLine, goesAhead: false, calls: 1,
                 start: { $0.setRadio(on: false) }, end: { $0.releaseRadio(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a radio switch on that fails", tab: .network, notice: radioBack, goesAhead: false, calls: 1,
                 start: { $0.setRadio(on: true) }, end: { $0.releaseRadio(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a mode change", tab: .network, notice: modeLine, goesAhead: true, calls: 1, start: changeMode,
                 end: { $0.releaseMode(.success(ModeChange(before: "AUTO", after: "LTE"))) }, result: nil),
            Case(name: "a mode change that fails", tab: .network, notice: modeLine, goesAhead: false, calls: 1, start: changeMode,
                 end: { $0.releaseMode(.failure(refused)) }, result: refused.message),
            Case(name: "a profile change", tab: .simAndApn, notice: radioBack, goesAhead: true, calls: 1, start: apply,
                 end: { $0.releaseProfile(.success(applied)) }, result: nil),
            Case(name: "a profile change that fails", tab: .simAndApn, notice: radioBack, goesAhead: false, calls: 1, start: apply,
                 end: { $0.releaseProfile(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a profile change that left the radio off", tab: .simAndApn, notice: radioBack, goesAhead: false, calls: 1,
                 start: apply, end: { $0.releaseProfile(.success(leftOff)) }, result: profileSentence(leftOff)),
            Case(name: "a PIN taken", tab: .simAndApn, notice: pinLine, goesAhead: true, calls: 1, start: unlock,
                 end: { $0.releasePin(.success(PinOutcome(accepted: true, sim: ready))) }, result: nil),
            Case(name: "a PIN refused", tab: .simAndApn, notice: pinLine, goesAhead: false, calls: 1, start: unlock,
                 end: { $0.releasePin(.success(refusedPin)) }, result: pinSentence(refusedPin)),
            Case(name: "a PIN that fails", tab: .simAndApn, notice: pinLine, goesAhead: false, calls: 1, start: unlock,
                 end: { $0.releasePin(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a bands change", tab: .network, notice: bandsQuitLine, goesAhead: true, calls: 1,
                 start: { $0.changeBands(.sa, to: [41]) },
                 end: { $0.releaseSetBands(.success(BandChange(before: nrSupported, after: [41]))) }, result: nil),
            Case(name: "a bands change that fails", tab: .network, notice: bandsQuitLine, goesAhead: false, calls: 1,
                 start: { $0.changeBands(.sa, to: [41]) }, end: { $0.releaseSetBands(.failure(bandsRefused)) },
                 result: bandsRefused.message),
            Case(name: "a bands reset", tab: .network, notice: bandsQuitLine, goesAhead: true, calls: 1,
                 start: { $0.resetBands(.sa) },
                 end: { $0.releaseSetBands(.success(BandChange(before: [41], after: nrSupported))) }, result: nil,
                 bands: bandSets(sa: [41])),
            Case(name: "a reset of all the bands", tab: .network, notice: bandsQuitLine, goesAhead: true, calls: 3,
                 start: { $0.resetAllBands() },
                 end: { fake in
                     fake.releaseSetBands(.success(BandChange(before: [3], after: lteSupported)))
                     fake.releaseSetBands(.success(BandChange(before: [78], after: nrSupported)))
                     fake.releaseSetBands(.success(BandChange(before: [41], after: nrSupported)))
                 }, result: nil, bands: bandSets(lte: [3], nsa: [78], sa: [41])),
        ]
        for k in cases {
            let name = "quit during \(k.name)"
            let rig = Rig()
            let c = rig.controller
            rig.fake.bandsAnswer = .success(k.bands)
            c.setTabShown(k.tab)
            if k.tab == .network {
                rig.answerInfo(1, .success(network("AUTO")), "\(name): the first read")
            } else {
                rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "\(name): the first read")
            }
            let before = rig.fake.calls.count
            k.start(c)
            rig.waitForCall(before + 1, "\(name): the call reaches the service")
            check(c.quitWhenFinished() == true, "\(name): the quit waits (terminate later)")
            check(c.quitNotice.line == k.notice, "\(name): the window's quit line", c.quitNotice.line)
            check(timer(of: c) == nil, "\(name): the timer stops")
            check(rig.replies.isEmpty, "\(name): no reply while the call runs", "\(rig.replies)")
            c.tick()
            c.refresh()
            k.end(rig.fake)
            pump(until: { !rig.replies.isEmpty }, "\(name): the reply")
            settle()
            check(rig.replies == [k.goesAhead], "\(name): replies \(k.goesAhead) exactly once", "\(rig.replies)")
            check(c.quitNotice.line == "", "\(name): the quit line goes when the call has finished", c.quitNotice.line)
            if k.goesAhead {
                check(rig.attention == 0, "\(name): no request for attention")
                check(rig.fake.calls.count == before + k.calls, "\(name): no read follows", "\(rig.fake.calls)")
                c.tick()
                c.refresh()
                settle()
                check(rig.fake.calls.count == before + k.calls && !c.refreshEnabled && timer(of: c) == nil,
                      "\(name): nothing starts while the app ends", "\(rig.fake.calls)")
            } else {
                check(rig.attention == 1, "\(name): asks for attention once", "\(rig.attention)")
                check(c.result == k.result && c.resultIsFailure, "\(name): the result line keeps the sentence", c.result)
                // The quit is cancelled: the controller works again and the shown tab is read at once.
                if k.tab == .network {
                    rig.answerInfo(before + 2, .success(network("AUTO")), "\(name): the tab is read again")
                } else {
                    rig.answerSettings(before + 2, .success(listing()), .success(asksPin(3)), "\(name): the tab is read again")
                }
                check(c.result == k.result, "\(name): the read after the cancelled quit leaves the result line", c.result)
                check(c.refreshEnabled && timer(of: c) != nil, "\(name): the controller works again after the cancelled quit")
                settle()
                check(rig.replies == [false] && rig.attention == 1, "\(name): still exactly one reply", "\(rig.replies)")
            }
            c.setTabShown(nil)
        }

        // A change waiting behind a read when the quit begins is dropped: it is never made, and the quit
        // waits only for the read (R12).
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.simAndApn)
            rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first read")
            c.tick()
            rig.waitForCall(3, "a turn starts")
            c.form?.apn = "cmnet"
            c.applyProfile()
            check(c.result == waitingLine, "quit with a waiting change: the change waits", c.result)
            check(c.quitWhenFinished() == true, "quit with a waiting change: the quit waits for the read")
            check(c.quitNotice.line == reading, "quit with a waiting change: the line is the read's", c.quitNotice.line)
            check(c.result == "RMNet is quitting, so the change that waited for a read was not made." && c.resultIsFailure,
                  "quit with a waiting change: the result line says it was not made", c.result)
            rig.fake.releaseProfiles(.success(listing()))
            rig.fake.releaseSim(.success(asksPin(3)))
            pump(until: { !rig.replies.isEmpty }, "the reply")
            settle()
            check(rig.replies == [true] && rig.attention == 0, "quit with a waiting change: replies true once after the read",
                  "\(rig.replies)")
            check(rig.fake.calls == [.profiles, .sim, .profiles, .sim], "quit with a waiting change: it never reached the service",
                  "\(rig.fake.calls)")
            c.setTabShown(nil)
        }

        // A waiting change that has already started on the queue when the quit begins (the main thread has
        // not yet heard that the read finished): the quit waits for the change, with its line.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.network)
            rig.answerInfo(1, .success(network("AUTO")), "the first read")
            c.tick()
            rig.waitForCall(2, "a turn starts")
            c.setRadio(on: false)
            rig.fake.releaseInfo(.success(network("AUTO")))
            waitOffMain(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the change starts on the queue")
            check(c.running == .reading, "quit with a started change: the main thread has not heard yet")
            check(c.quitWhenFinished() == true, "quit with a started change: the quit waits")
            check(c.quitNotice.line == radioOffLine, "quit with a started change: the line is the change's", c.quitNotice.line)
            pump(until: { c.running == .radio }, "the main thread hears the read has finished")
            check(c.result == "Switching the radio off…" && rig.replies.isEmpty, "quit with a started change: it runs", c.result)
            rig.fake.releaseRadio(.success(radioOff))
            pump(until: { !rig.replies.isEmpty }, "the reply")
            settle()
            check(rig.replies == [true] && c.result == radioSentence(radioOff), "quit with a started change: replies true once after it",
                  "\(rig.replies)")
            check(rig.fake.calls.count == 3, "quit with a started change: no read follows", "\(rig.fake.calls)")
            c.setTabShown(nil)
        }
    }

    // resumeAfterCancelledQuit (the Messages controller cancelled the quit): working again, the timer
    // back if a tab is shown; a quit still waiting is cancelled too and never answered.
    static func resuming() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        check(c.quitWhenFinished() == false, "resume: the quit answered at once")
        c.resumeAfterCancelledQuit()
        rig.answerInfo(2, .success(network("AUTO")), "resume: the shown tab is read at once")
        check(timer(of: c)?.timeInterval == 5 && c.refreshEnabled && c.quitNotice.line == "",
              "resume: the timer runs again and the controller works")

        c.tick()
        rig.waitForCall(3, "a turn starts")
        check(c.quitWhenFinished() == true, "resume: a quit waits for the turn")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { rig.replies == [true] }, "the quit goes ahead")
        c.resumeAfterCancelledQuit()
        rig.answerInfo(4, .success(network("AUTO")), "resume after the quit went ahead: read at once")
        check(c.refreshEnabled && timer(of: c) != nil && rig.replies == [true] && rig.attention == 0,
              "resume: works again after the Messages controller cancelled")

        c.setTabShown(nil)
        _ = c.quitWhenFinished()
        c.resumeAfterCancelledQuit()
        settle()
        check(rig.fake.calls.count == 4 && timer(of: c) == nil && c.refreshEnabled,
              "resume: with no tab shown, nothing is read and no timer runs", "\(rig.fake.calls)")

        c.setTabShown(.network)
        rig.waitForCall(5, "the tab is read")
        check(c.quitWhenFinished() == true, "resume: a quit waits for the read")
        c.resumeAfterCancelledQuit()
        check(c.quitNotice.line == "", "resume: the quit line goes at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        settle()
        check(rig.replies == [true] && rig.attention == 0, "resume: a cancelled quit that was waiting is never answered",
              "\(rig.replies)")
        check(rig.fake.calls.count == 5 && c.refreshEnabled && timer(of: c) != nil,
              "resume: the read is not doubled and the controller works", "\(rig.fake.calls)")
        c.setTabShown(nil)
    }

    // The Overview reads the network as the Network tab does (at once, then every 5 s, only while it is shown in a
    // window that can be seen, nothing while a confirmation is open, nothing once the app quits), and nothing
    // else: never the bands, and its Refresh makes none due. A Network read that runs when the Overview is shown
    // serves it; an Overview read that runs when the Network tab is shown does not (the bands are due).
    static func overviewReading() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.overview)
        check(!c.bandsDue, "overview: the bands are not due")
        rig.waitForCall(1, "the Overview is read at once")
        check(rig.fake.calls == [.networkInfo] && c.running == .reading, "overview: networkInfo() at once",
              "\(rig.fake.calls)")
        check(timer(of: c)?.timeInterval == 5 && scheduled(timer(of: c)), "overview: its timer turns every 5 s")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the Overview's first read comes back")
        settle()
        check(c.info == network("AUTO") && c.infoFailure == nil && c.infoAt != nil, "overview: the read sets info")
        check(rig.fake.bandsReads == 0 && c.bands == nil && !c.bandsDue, "overview: the bands are not read",
              "\(rig.fake.allCalls)")

        c.tick()
        rig.answerInfo(2, .success(network("AUTO")), "an Overview tick")
        timer(of: c)?.fire()
        rig.answerInfo(3, .success(network("AUTO")), "an Overview timer turn")
        c.refresh()
        check(!c.bandsDue, "overview: Refresh makes no bands due")
        rig.answerInfo(4, .success(network("LTE")), "an Overview Refresh")
        check(rig.fake.allCalls == Array(repeating: Call.networkInfo, count: 4),
              "overview: ticks, turns and Refresh read the network only", "\(rig.fake.allCalls)")
        check(c.info == network("LTE"), "overview: each read is applied")

        // The window hidden: nothing, and no timer; seen again: read at once.
        c.setWindowVisible(false)
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 4 && timer(of: c) == nil, "overview: nothing is read while the window is hidden")
        c.setWindowVisible(true)
        rig.answerInfo(5, .success(network("AUTO")), "the Overview when the window is seen again")
        check(rig.fake.bandsReads == 0 && !c.bandsDue, "overview: no bands when the window is seen again")

        // A confirmation open: nothing.
        c.setConfirming(true)
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        settle()
        check(rig.fake.calls.count == 5, "overview: nothing is read while a confirmation is open", "\(rig.fake.calls)")
        c.setConfirming(false)
        settle()
        check(rig.fake.calls.count == 5, "overview: closing it reads nothing that was not due")

        // To the Network tab: the bands are due and read with its first read.
        c.setTabShown(.network)
        check(c.bandsDue, "overview: the Network tab after it makes the bands due")
        rig.answerInfo(6, .success(network("AUTO")), "the Network tab after the Overview")
        check(rig.fake.bandsReads == 1 && c.bands == bandSets() && !c.bandsDue, "overview: the Network tab reads the bands")

        // Back to the Overview while a Network read runs: that read serves it.
        c.tick()
        rig.waitForCall(7, "a Network turn starts")
        c.setTabShown(.overview)
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the Network turn comes back")
        settle()
        check(rig.fake.calls.count == 7 && timer(of: c)?.timeInterval == 5,
              "overview: a running Network read serves the Overview (no second read)", "\(rig.fake.calls)")

        // To the Network tab while an Overview read runs: the Network tab reads again, with the bands.
        c.tick()
        rig.waitForCall(8, "an Overview turn starts")
        c.setTabShown(.network)
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.waitForCall(9, "the Network tab's own read follows")
        check(rig.fake.bandsReads == 1, "overview: its read did not read the bands", "\(rig.fake.allCalls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the Network tab's read comes back")
        check(rig.fake.bandsReads == 2 && !c.bandsDue, "overview: the Network tab's read after it reads the bands")

        // To the Overview with nothing running: read at once; then the SIM & APN tab reads the settings.
        c.setTabShown(.overview)
        rig.answerInfo(10, .success(network("AUTO")), "the Overview again")
        c.setTabShown(.simAndApn)
        rig.answerSettings(11, .success(listing()), .success(ready), "the SIM & APN tab after the Overview")
        check(timer(of: c)?.timeInterval == 30 && rig.fake.bandsReads == 2, "overview: the SIM & APN tab as before")
        c.setTabShown(nil)
        check(timer(of: c) == nil, "overview: no timer with no modem screen shown")

        // Quitting stops it.
        c.setTabShown(.overview)
        rig.answerInfo(13, .success(network("AUTO")), "the Overview before a quit")
        check(c.quitWhenFinished() == false && timer(of: c) == nil, "overview: a quit stops its timer")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 13, "overview: nothing is read once the app quits", "\(rig.fake.calls)")
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "overview: one call at a time, on the queue")
    }

    // Every network read that succeeds (the Overview's or the Network tab's) adds one sample a serving leg, at the
    // read's time: the leg ("NR", "LTE", "WCDMA"), RSRP, RSRQ, SINR, the technology and the band. A failed read
    // adds none; a read with no leg adds none but counts as a read. The last 120 reads are kept.
    static func signalHistory() {
        let rig = Rig()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        rig.clock = t0
        let c = rig.controller
        var published = 0
        let watch = c.$signalHistory.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        check(c.signalHistory.isEmpty && ModemController.signalHistoryReads == 120, "history: empty at first; 120 reads kept")

        c.setTabShown(.overview)
        rig.answerInfo(1, .success(served([saLeg])), "a 5G SA read")
        check(c.signalHistory == [SignalSample(at: t0, leg: "NR", rsrp: -86, rsrq: -11, sinr: 10.5, technology: "5G SA",
                                               band: "n41")],
              "history: one sample for the 5G SA leg", "\(c.signalHistory)")
        check(c.infoAt == t0 && published == 1, "history: at the read's time; published")

        rig.clock = t0.addingTimeInterval(5)
        c.tick()
        rig.answerInfo(2, .success(served([lteLeg, nsaLeg])), "an EN-DC read")
        check(Array(c.signalHistory.dropFirst()) == [
            SignalSample(at: t0.addingTimeInterval(5), leg: "LTE", rsrp: -95, rsrq: -12, sinr: 8, technology: "5G NSA", band: "B3"),
            SignalSample(at: t0.addingTimeInterval(5), leg: "NR", rsrp: -90, rsrq: -10, sinr: 14, technology: "5G NSA", band: "n78"),
        ], "history: one sample a leg for EN-DC", "\(c.signalHistory)")

        rig.clock = t0.addingTimeInterval(10)
        c.tick()
        rig.answerInfo(3, .failure(portBusy), "a failed read")
        check(c.signalHistory.count == 3, "history: a failed read adds nothing")

        rig.clock = t0.addingTimeInterval(15)
        c.tick()
        rig.answerInfo(4, .success(served([], state: "SEARCH")), "a read while searching")
        check(c.signalHistory.count == 3, "history: a read with no leg adds nothing")

        rig.clock = t0.addingTimeInterval(20)
        c.tick()
        rig.answerInfo(5, .success(served([umtsLeg])), "a WCDMA read")
        check(c.signalHistory.last == SignalSample(at: t0.addingTimeInterval(20), leg: "WCDMA", rsrp: -80, rsrq: nil, sinr: nil,
                                                   technology: "WCDMA", band: nil),
              "history: the WCDMA leg", "\(String(describing: c.signalHistory.last))")

        // Kept across the screens; the Network tab's reads add too; the settings read adds none.
        c.setTabShown(.simAndApn)
        rig.answerSettings(6, .success(listing()), .success(ready), "the SIM & APN tab")
        check(c.signalHistory.count == 4, "history: kept, and not added to, on the SIM & APN tab")
        rig.clock = t0.addingTimeInterval(25)
        c.setTabShown(.network)
        rig.answerInfo(8, .success(served([saLeg])), "a Network tab read")
        check(c.signalHistory.count == 5 && c.signalHistory.last?.at == t0.addingTimeInterval(25),
              "history: the Network tab's read adds its sample")

        // 5 reads so far count (the failed one does not). 115 more fill the 120.
        var count = 8
        for i in 1...115 {
            rig.clock = t0.addingTimeInterval(25 + Double(i) * 5)
            c.tick()
            count += 1
            rig.answerInfo(count, .success(served([saLeg])), "read \(i) of the 115")
        }
        check(c.signalHistory.count == 120 && c.signalHistory.first?.at == t0,
              "history: 120 reads are all kept", "\(c.signalHistory.count)")
        // The 121st drops the oldest read (one sample); the next drops the EN-DC read (two samples); the next the
        // read with no leg (none).
        let more: [(samples: Int, first: String)] = [(120, "LTE"), (119, "WCDMA"), (120, "WCDMA"), (120, "NR")]
        for (n, want) in more.enumerated() {
            rig.clock = t0.addingTimeInterval(1_000 + Double(n) * 5)
            c.tick()
            count += 1
            rig.answerInfo(count, .success(served([saLeg])), "read \(121 + n)")
            check(c.signalHistory.count == want.samples && c.signalHistory.first?.leg == want.first,
                  "history: read \(121 + n) keeps the last 120 reads",
                  "\(c.signalHistory.count) samples, first \(String(describing: c.signalHistory.first?.leg))")
        }
        check(c.signalHistory.last?.at == t0.addingTimeInterval(1_015), "history: the newest sample is last")
        c.setTabShown(nil)
    }

    /// Locking to a cell in use (the Network screen's cells in use): the service's lockCellInUse, which reads the cell
    /// again in the session that writes the lock; values out of range refused before the service; a cell the modem no
    /// longer uses comes back as a failure, and the lock as read stays.
    static func cellInUseLocks() {
        let rig = Rig()
        let c = rig.controller
        let nr = NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)
        let lte = LteLockedCell(earfcn: 66786, pci: 128)
        let unlocked = CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)
        let lteLocked = CellLockState(lte: [lte], nr: nil, persistLte: false, persistNr: false)

        c.lockCellInUse(.nr(NrCellLock(pci: 2000, arfcn: 520110, scsKHz: 30, band: 41)))
        check(c.resultIsFailure && rig.fake.calls.isEmpty, "cellInUse: an invalid PCI refused without the service")

        c.lockCellInUse(.nr(nr))
        rig.waitForCall(1, "cellInUse: the 5G SA cell")
        check(rig.fake.calls.last == .lockCellInUse(.nr(nr)), "cellInUse: the service is asked for the cell in use")
        equal(c.result, "Locking 5G SA cell to PCI 147, ARFCN 520110…", "cellInUse: the line while it runs")
        let gone = "The modem no longer uses that 5G SA cell (n41, PCI 147, ARFCN 520110). Nothing was changed."
        rig.fake.releaseLockCellInUse(.failure(ModemFailure(message: gone)))
        pump(until: { c.running == nil }, "cellInUse: refused")
        check(c.resultIsFailure && c.result == gone && c.cellLock == nil, "cellInUse: a cell gone, nothing changed", c.result)

        c.lockCellInUse(.lte(lte))
        rig.waitForCall(2, "cellInUse: the LTE cell")
        equal(c.result, "Locking LTE cell to PCI 128, EARFCN 66786…", "cellInUse: the LTE line")
        rig.fake.releaseLockCellInUse(.success(.changed(before: unlocked, after: lteLocked)))
        pump(until: { c.running == nil }, "cellInUse: locked")
        check(!c.resultIsFailure && c.cellLock == lteLocked, "cellInUse: the lock as read back", c.result)
    }

    static func antennasCellLockAndImei() {
        let rig = Rig()
        let c = rig.controller

        // Overview does NOT read antennas or cellLock.
        c.setTabShown(.overview)
        rig.answerInfo(1, .success(served([saLeg])), "overview read")
        check(rig.fake.antennasReads == 0 && rig.fake.cellLockReads == 0,
              "overview: skips antennas and cellLock reads")

        // Network tab reads antennas when radio is on, and reads cellLock when due (cleared on success).
        let antSample = [AntennaSignalSet(rat: "NR5G", ports: [
            AntennaPort(index: 0, name: "PRX", rsrp: -90, rsrq: -10, sinr: 22),
            AntennaPort(index: 1, name: "DRX", rsrp: nil, rsrq: nil, sinr: nil),
            AntennaPort(index: 2, name: "RX2", rsrp: nil, rsrq: nil, sinr: nil),
            AntennaPort(index: 3, name: "RX3", rsrp: nil, rsrq: nil, sinr: nil),
        ])]
        let nr = NrCellLock(pci: 147, arfcn: 520110, scsKHz: 30, band: 41)
        let unlocked = CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)
        let lockedNr = CellLockState(lte: [], nr: nr, persistLte: false, persistNr: false)

        rig.fake.queueAntennas(.success(antSample))
        rig.fake.queueCellLock(.failure(portBusy))
        c.setTabShown(.network)
        rig.answerInfo(2, .success(served([saLeg])), "network first read with cellLock failure")
        check(c.antennas == antSample && c.cellLock == nil && c.cellLockFailure == portBusy.message && c.cellLockDue,
              "network: failed cellLock read keeps cellLockDue true", "\(c.cellLockFailure ?? "")")

        // Next turn retries due cellLock; when radio is airplane, antennas are cleared without calling antennas().
        rig.fake.queueCellLock(.success(unlocked))
        c.tick()
        rig.answerInfo(3, .success(NetworkInfo(radio: .airplane)), "network read in airplane mode")
        check(c.antennas.isEmpty && rig.fake.antennasReads == 1 && rig.fake.cellLockReads == 2
                && c.cellLock == unlocked && c.cellLockFailure == nil && !c.cellLockDue,
              "network: airplane clears antennas without reading; successful cellLock clears failure and cellLockDue")

        // Validation refusal before submitting change.
        c.setNrCellLock(NrCellLock(pci: 2000, arfcn: 520110, scsKHz: 30, band: 41))
        check(c.resultIsFailure && rig.fake.calls.count == 3, "cellLock: invalid PCI refused without calling service")

        // Locking NR cell updates state and reads again; QuitGate wait works with cellLock quitLine.
        c.setNrCellLock(nr)
        rig.waitForCall(4, "setNrCellLock runs")
        check(c.quitWhenFinished() && c.quitNotice.line == "RMNet quits when the cell lock has been changed.",
              "cellLock: quit notice while locking")
        rig.fake.releaseSetNrCellLock(.success(.changed(before: unlocked, after: lockedNr)))
        pump(until: { rig.replies == [true] }, "quit answers true after cellLock")
        c.resumeAfterCancelledQuit()
        rig.answerInfo(5, .success(served([saLeg])), "read after resume")

        // Unlock all runs both unlocks and updates cellLock.
        c.unlockAllCells()
        rig.waitForCall(6, "unlockAllCells: setNrCellLock(nil)")
        rig.fake.releaseSetNrCellLock(.success(.changed(before: lockedNr, after: unlocked)))
        rig.waitForCall(7, "unlockAllCells: setLteCellLock([])")
        rig.fake.releaseSetLteCellLock(.success(.unchanged(unlocked)))
        rig.answerInfo(8, .success(served([saLeg])), "read after unlockAllCells")
        check(!c.resultIsFailure && c.cellLock == unlocked, "unlockAllCells: result updated", c.result)

        // SIM & Data reads IMEI independently of profiles/sim; invalid Luhn rejected before queueing.
        rig.fake.queueImei(.failure(portBusy))
        c.setTabShown(.simAndApn)
        rig.answerSettings(9, .success(listing()), .success(ready), "sim&apn first read with imei failure")
        check(c.imei == nil && c.imeiFailure == portBusy.message && c.settingsFailure == nil,
              "sim&apn: imei failure does not break settingsAt/settingsFailure")

        rig.fake.queueImei(.success("000000000000091"))
        c.refresh()
        rig.answerSettings(11, .success(listing()), .success(ready), "sim&apn refresh imei")
        check(c.imei == "000000000000091" && c.imeiFailure == nil, "sim&apn: imei read and failure cleared")

        c.changeImei("000000000000142", reboot: true)
        check(c.resultIsFailure && c.result.contains("check digit"), "changeImei: rejects invalid Luhn")

        c.changeImei("000000000000141", reboot: true)
        rig.waitForCall(13, "setImei runs")
        rig.fake.releaseSetImei(.success(.rebooting(before: "000000000000091", after: "000000000000141")))
        pump(until: { c.imei == "000000000000141" && !c.resultIsFailure && c.result.contains("restarting") },
             "setImei finishes")
        rig.fake.queueImei(.success("000000000000141"))
        rig.answerSettings(14, .success(listing()), .success(ready), "settings refresh after setImei")
        check(c.imei == "000000000000141" && !c.resultIsFailure, "changeImei: updated and reported", c.result)
        c.setTabShown(nil)
    }

    /// The SIM & Data read also reads the IMEI history and the module's serial number; each IMEI change asked in the
    /// window is recorded (`app`, succeeded or failed, with the module and the IMEI before that the change's own port
    /// open read, not the module shown) and the history read again. Change Back… writes only on its entry's module.
    static func imeiHistoryRecorded() {
        let rig = Rig()
        let keeper = MemoryHistory()
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        rig.history = ImeiHistoryRecorder(keeper: keeper, module: { "f00dcafe" }, now: { when })
        let c = rig.controller

        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "history: first settings read")
        check(c.imeiHistory == ImeiHistory(entries: [], skippedLines: 0) && c.moduleSerial == "f00dcafe",
              "history: read with the settings", "\(String(describing: c.imeiHistory)) \(String(describing: c.moduleSerial))")

        // As the window asks it: on the module shown, over the IMEI shown.
        let confirmed = ImeiExpectation(module: "f00dcafe", before: "000000000000091")
        c.changeImei("000000000000141", reboot: true, expect: confirmed)
        rig.waitForCall(3, "history: setImei runs")
        rig.fake.releaseSetImei(.success(.rebooting(before: "000000000000091", after: "000000000000141")))
        pump(until: { c.result.contains("restarting") }, "history: the change finishes")
        check(keeper.entries == [ImeiHistoryEntry(time: when, before: "000000000000091", after: "000000000000141",
                                                  source: .app, result: .succeeded, restart: true,
                                                  restartResult: .succeeded, module: "c0ffee01",
                                                  message: "IMEI set to 000000000000141; the modem is restarting.",
                                                  note: nil)],
              "history: the change recorded with its own port's module", "\(keeper.entries)")
        equal(rig.fake.imeiExpectationsAsked, [confirmed], "history: Change… writes only what was confirmed")
        check(c.moduleSerial == "f00dcafe", "history: the module shown is the registry's")
        check(c.imeiHistory?.entries == keeper.entries, "history: read again after the change")
        rig.fake.queueImei(.success("000000000000141"))
        rig.answerSettings(4, .success(listing()), .success(ready), "history: the read after the change")

        keeper.refuse = "The IMEI history could not be written (/x)."
        c.changeImei("000000000000091", reboot: false)
        rig.waitForCall(6, "history: second setImei runs")
        rig.fake.releaseSetImei(.failure(ModemFailure(message: "The IMEI was not changed. ERROR")))
        pump(until: { c.resultIsFailure }, "history: the failed change finishes")
        check(c.resultIsFailure && c.result == "The IMEI was not changed. ERROR The change was not recorded in the "
              + "IMEI history: The IMEI history could not be written (/x).", "history: not written is said", c.result)
        check(keeper.entries.count == 1, "history: nothing appended when refused")
        keeper.refuse = nil

        // Change Back… of an entry: on its module only; the session's module and IMEI before are what is recorded, also
        // when the window's last read had another IMEI.
        rig.fake.queueImei(.success("000000000000141"))
        rig.answerSettings(7, .success(listing()), .success(ready), "history: the read after the failed change")
        rig.fake.imeiSession = (module: "c0ffee01", before: "000000000000117")
        let back = ImeiExpectation(module: "c0ffee01", before: "000000000000141")
        c.changeImei("000000000000091", reboot: true, expect: back)
        rig.waitForCall(9, "history: Change Back runs")
        rig.fake.releaseSetImei(.success(.rebooting(before: "000000000000117", after: "000000000000091")))
        pump(until: { keeper.entries.count == 2 && c.result.contains("restarting") }, "history: Change Back finishes")
        equal(rig.fake.imeiExpectationsAsked.last, back, "history: Change Back asks for its entry's module")
        equal(keeper.entries.last?.before, "000000000000117", "history: the IMEI before as the change's port read it")
        equal(keeper.entries.last?.module, "c0ffee01", "history: and its module")

        // Written and read back, the restart refused: a warning, the new IMEI shown, recorded as a change that
        // succeeded with its restart failed, so it can still be changed back.
        rig.fake.queueImei(.success("000000000000091"))
        rig.answerSettings(10, .success(listing()), .success(ready), "history: the read after Change Back")
        rig.fake.imeiSession = (module: "f00dcafe", before: "000000000000091")
        let sentence = "The IMEI is now 000000000000141, but the modem was not restarted. The modem refused the command "
            + "(ERROR). It takes effect at the next restart (AT+CFUN=1,1 or a replug)."
        c.changeImei("000000000000141", reboot: true, expect: confirmed)
        rig.waitForCall(12, "history: a change whose restart fails")
        rig.fake.releaseSetImei(.success(.restartFailed(before: "000000000000091", after: "000000000000141",
                                                        sentence: sentence)))
        pump(until: { keeper.entries.count == 3 && c.resultKind != .progress }, "history: it finishes")
        check(c.result == sentence && c.resultKind == .warning, "history: restart failed, a warning", "\(c.resultKind) \(c.result)")
        equal(c.imei, "000000000000141", "history: the new IMEI shown")
        let last = keeper.entries.last
        check(last?.result == .succeeded && last?.restartResult == .failed && last?.restart == true,
              "history: written, its restart failed, recorded apart", "\(String(describing: last))")
        let rows = imeiHistoryRows(ImeiHistory(entries: keeper.entries, skippedLines: 0), currentImei: "000000000000141",
                                   currentModule: "f00dcafe")
        check(rows.first?.canChangeBack == true, "history: and it can be changed back")
        c.setTabShown(nil)
    }
}

extension ModemControllerTests {
    // The result banner of the Network and SIM & Data screens: dismissed, the line is cleared in the controller, so
    // another screen and back does not bring it back; a success goes after 8 s; a failure stays; a warning stays; the
    // next result replaces the old one.
    static func resultBanner() {
        let rig = Rig()
        let clock = FakeClock()
        rig.resultClock = clock
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "banner: first settings read")

        // Each change asks for an IMEI the modem does not have (the same one is refused before the port).
        func setImei(_ outcome: Result<ImeiChange, ModemFailure>, _ name: String) {
            let n = rig.fake.calls.count + 1
            let wanted = c.imei == "000000000000141" ? "000000000000091" : "000000000000141"
            c.changeImei(wanted, reboot: true)
            rig.waitForCall(n, "\(name): setImei runs")
            check(c.resultKind == .progress, "\(name): the change's words while it runs", "\(c.resultKind)")
            rig.fake.releaseSetImei(outcome)
            pump(until: { c.resultKind != .progress }, "\(name): the change finishes")
            rig.fake.queueImei(.success(c.imei ?? wanted))
            rig.answerSettings(n + 1, .success(listing()), .success(ready), "\(name): the read after it")
        }

        // Dismissed: cleared; another screen and back (with its read) does not bring it back.
        setImei(.success(.rebooting(before: "000000000000091", after: "000000000000141")), "dismissed")
        equal(c.result, "IMEI set to 000000000000141; the modem is restarting.", "banner: the success")
        check(c.resultKind == .success, "banner: a success")
        c.dismissResult()
        equal(c.result, "", "banner: dismissed, cleared")
        let before = rig.fake.calls.count
        c.setTabShown(nil)
        rig.fake.queueImei(.success(c.imei ?? "000000000000141"))
        c.setTabShown(.simAndApn)
        rig.answerSettings(before + 1, .success(listing()), .success(ready), "banner: back on SIM & Data")
        equal(c.result, "", "banner: dismissed, it does not come back on another screen and back")

        // A success goes after 8 s, not before.
        setImei(.success(.rebooting(before: "000000000000091", after: "000000000000141")), "expires")
        clock.advance(7.5)
        equal(c.result, "IMEI set to 000000000000141; the modem is restarting.", "banner: still there at 7.5 s")
        clock.advance(0.5)
        equal(c.result, "", "banner: gone at 8 s")

        // A failure stays; the next result replaces it.
        setImei(.failure(ModemFailure(message: "The IMEI was not changed. ERROR")), "failure")
        clock.advance(3600)
        equal(c.result, "The IMEI was not changed. ERROR", "banner: a failure stays")
        check(c.resultKind == .failure, "banner: a failure")
        // A success that takes effect later: a warning, which stays too; it replaces the failure.
        setImei(.success(.setTakesEffectAfterRestart(before: "000000000000091", after: "000000000000141")), "warning")
        check(c.resultKind == .warning && c.result.hasPrefix("IMEI set to 000000000000141; it takes effect"),
              "banner: the next result replaces the failure, as a warning", c.result)
        clock.advance(3600)
        check(!c.result.isEmpty, "banner: a warning stays")
        c.setTabShown(nil)
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

extension ModemControllerTests {
    /// The SIM slot: by hand it waits for the registration and leaves its sentence; automatic it waits for the SIM only,
    /// leaves no line, and is refused silently (false) while another change runs; both report their outcome.
    static func simSlotChanges() {
        let rig = Rig()
        let c = rig.controller
        var outcomes: [SimSlotOutcome] = []
        check(c.changeSimSlot(2) { outcomes.append($0); return nil }, "slot by hand: started")
        rig.waitForCall(1, "slot by hand: setSimSlot")
        equal(rig.fake.allCalls.last, .setSimSlot(2, .registration), "slot by hand: waits for the registration")
        rig.fake.releaseSetSimSlot(.success(SimSlotChange(before: 1, after: 2, sim: .ready, secondsToSim: 2,
                                                          registration: Registration(status: .home, domain: "5GS"),
                                                          secondsToRegister: 4)))
        pump(until: { outcomes.count == 1 }, "slot by hand: finished")
        equal(c.result, "Switched to SIM 2. SIM ready; registered, home network (5GS) after 4 s.", "slot by hand: the sentence")
        check(!c.resultIsFailure, "slot by hand: not a failure")

        let expect = SimSlotExpectation(module: "c0ffee01", slot: 2)
        check(c.changeSimSlot(1, automatic: true, expect: expect) { outcomes.append($0); return nil }, "automatic: started")
        rig.waitForCall(2, "automatic: setSimSlot")
        equal(rig.fake.allCalls.last, .setSimSlot(1, .sim), "automatic: waits for the SIM only")
        equal(rig.fake.slotExpectationsAsked, [nil, expect], "automatic: its expectation goes to the port that writes")
        // Another change asked meanwhile: refused (by hand, with a line); an automatic one silently.
        check(!c.changeSimSlot(2, automatic: true), "automatic: refused while a change runs")
        rig.fake.releaseSetSimSlot(.success(SimSlotChange(before: 2, after: 1, sim: .notInserted)))
        pump(until: { outcomes.count == 2 }, "automatic: finished")
        equal(c.result, "", "automatic: no result line")
        check(!c.changeSimSlot(3), "slot 3: refused")
        equal(c.result, "The modem has SIM slots 1 and 2. Nothing was changed.", "slot 3: the line")
    }

    /// The watcher's try and its switch back are one unit: the completion hands back the slot to switch back to, which
    /// runs at once (with the module and the slot tried as its expectation); a quit asked during the try waits for the
    /// switch back too, and is answered only after the watcher has heard of both. A failed automatic switch does not
    /// cancel the quit.
    static func simSlotSwitchBack() {
        let rig = Rig()
        let c = rig.controller
        var heard: [SimSlotOutcome] = []
        var repliesWhenHeard: [Int] = []
        let expect = SimSlotExpectation(module: "c0ffee01", slot: 1)
        check(c.changeSimSlot(2, automatic: true, expect: expect) { outcome in
            heard.append(outcome)
            repliesWhenHeard.append(rig.replies.count)
            return heard.count == 1 ? 1 : nil   // the first: switch back to 1
        }, "switch back: the try started")
        rig.waitForCall(1, "switch back: the try runs")
        check(c.quitWhenFinished(), "switch back: the quit waits for the try")
        equal(c.quitNotice.line, "RMNet quits when the SIM slot has been switched.", "switch back: the quit's line")
        rig.fake.releaseSetSimSlot(.success(SimSlotChange(before: 1, after: 2, sim: .notInserted)))
        rig.waitForCall(2, "switch back: runs at once, while the app quits")
        equal(rig.fake.allCalls.last, .setSimSlot(1, .sim), "switch back: to slot 1")
        equal(rig.fake.slotExpectationsAsked.last, SimSlotExpectation(module: "c0ffee01", slot: 2, unusableSim: true),
              "switch back: expects the module, on the slot tried")
        check(rig.replies.isEmpty && c.running == .simSlot, "switch back: the quit still waits", "\(rig.replies)")
        equal(c.quitNotice.line, "RMNet quits when the SIM slot has been switched.", "switch back: the line stays")
        rig.fake.releaseSetSimSlot(.failure(ModemFailure(message: "The SIM slot was not changed. ERROR")))
        pump(until: { !rig.replies.isEmpty }, "switch back: the quit is answered")
        equal(rig.replies, [true], "switch back: the app quits, also after a failed automatic switch")
        equal(repliesWhenHeard, [0, 0], "switch back: the watcher heard of each before the quit was answered")
        equal(heard.count, 2, "switch back: both outcomes")
        equal(rig.attention, 0, "switch back: no attention asked")
    }

    /// An automatic switch that waits behind a read when the app begins to quit is dropped: its asker hears
    /// `.cancelled` (so the watcher is free again should the quit be cancelled), and no result line is left.
    static func simSlotDroppedAtQuit() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.waitForCall(1, "dropped: a read runs")
        var heard: [SimSlotOutcome] = []
        check(c.changeSimSlot(2, automatic: true, expect: SimSlotExpectation(module: nil, slot: 1)) {
            heard.append($0)
            return 2   // ignored for a cancelled one
        }, "dropped: the switch waits behind the read")
        check(c.quitWhenFinished(), "dropped: the quit waits for the read")
        equal(heard, [.cancelled], "dropped: the asker hears it was cancelled")
        equal(c.result, "", "dropped: no result line for an automatic switch")
        check(!c.resultIsFailure, "dropped: not a failure")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { !rig.replies.isEmpty }, "dropped: the read comes back")
        equal(rig.replies, [true], "dropped: the app quits")
        settle()
        equal(rig.fake.calls.count, 1, "dropped: the switch never ran")
        c.resumeAfterCancelledQuit()
        c.setTabShown(nil)
    }
}

/// An IMEI history in memory, written from the controller's queue and read on the main thread.
final class MemoryHistory: ImeiHistoryKeeping {
    private let lock = NSLock()
    private var stored: [ImeiHistoryEntry] = []
    private var refusal: String? = nil
    var entries: [ImeiHistoryEntry] { lock.lock(); defer { lock.unlock() }; return stored }
    var refuse: String? {
        get { lock.lock(); defer { lock.unlock() }; return refusal }
        set { lock.lock(); refusal = newValue; lock.unlock() }
    }
    var location: String { "/memory/imei-history.jsonl" }

    func load() -> Result<ImeiHistory, ModemFailure> {
        .success(ImeiHistory(entries: entries, skippedLines: 0))
    }

    func append(_ entry: ImeiHistoryEntry) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let refusal { return refusal }
        stored.append(entry)
        return nil
    }
}
