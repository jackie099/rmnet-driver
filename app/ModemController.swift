// The Overview, Network and SIM & Data screens' state and the calls they make to the modem: reads only while one
// of them is shown in a visible window, one call at a time, the result line of the last change, a way back (Put
// Back) for a mode or profile change, the bands each RAT may use (changed or reset to every supported band),
// the serving cell's signal over the last 120 network reads, and quitting that waits for a running call. It
// takes any ModemServing, and the two AppKit calls it needs (the answer to the terminate question, the request
// for attention), the driver's profile number and the clock are closures given by the app delegate, so it uses
// no AppKit or SwiftUI and is tested with a fake service (tests/app/ModemControllerTests.swift), as
// SmsController is.
//
// A PIN is passed to the service and never kept: no stored property holds it (only the block on the queue
// does, until the call returns). A profile's old password is kept in memory only, in `undo`
// (ProfileSettings shows only whether one is set in any string conversion).
import Combine
import Foundation

/// The modem screen shown in the window (`simAndApn`: SIM & Data). The Overview reads the network as the Network
/// screen does, without the bands.
enum ModemTab: Equatable { case overview, network, simAndApn }

/// One serving leg's signal in one network read that succeeded, for the signal history's charts: the read's
/// time, the leg ("NR" for either 5G leg, "LTE", "WCDMA", or another RAT as the modem named it), its RSRP (RSCP
/// for WCDMA), RSRQ and SINR, the read's technology (technologyLabel: "5G SA", "5G NSA", "LTE", "WCDMA") and the
/// leg's band.
struct SignalSample: Equatable {
    let at: Date
    let leg: String
    let rsrp: Int?
    let rsrq: Int?
    let sinr: Double?
    let technology: String?
    let band: String?
}

/// What is running on the service's queue; at most one call at a time.
enum ModemActivity: Equatable { case reading, radio, mode, profile, pin, bands, cellLock, imei, simSlot }

/// The way back from the last mode or profile change: the mode before (as the modem gave it, ruling R8), or
/// the profile's settings before, password included (in memory only).
enum ModemUndo: Equatable {
    case mode(String)
    case profile(id: Int, ProfileSettings)
}

/// The line the window shows above its screen while a quit waits for a call to the modem; "" otherwise.
/// Its own object, so the window can show it without observing the whole controller.
final class ModemQuitNotice: ObservableObject {
    @Published fileprivate(set) var line = ""
}

/// A change on its way through the queue: started at once, or waiting there behind a read that runs
/// (ruling R12). The main thread drops it when the app begins to quit before it started; the queue starts
/// it only if it was not dropped. It holds no value of the change (a PIN is only in the queued block).
private final class ModemChange {
    let activity: ModemActivity
    let line: String       // the result line while it runs
    let quitLine: String   // the window's line while a quit waits for it
    let quiet: Bool        // asked by the app itself (the SIM slot watcher): dropped without a result line
    let dropped: () -> Void  // told on the main thread when it is dropped (it never runs, and never finishes)
    private let lock = NSLock()
    private var started = false
    private var wasDropped = false

    init(_ activity: ModemActivity, line: String, quitLine: String, quiet: Bool = false,
         dropped: @escaping () -> Void = {}) {
        self.activity = activity
        self.line = line
        self.quitLine = quitLine
        self.quiet = quiet
        self.dropped = dropped
    }

    /// On the queue: true when it may run now (it was not dropped); from then on it cannot be dropped.
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if wasDropped { return false }
        started = true
        return true
    }

    /// On the main thread: true when it was dropped before it started (it will never run).
    func drop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return false }
        wasDropped = true
        return true
    }
}

/// The app has exactly one, owned by the app delegate, so that quitting can wait for a running call. Its
/// methods are called on the main thread; every service call runs on `queue` (shared with the Messages
/// screen, so the AT port is never opened twice at once), one at a time, with the result handed back to the
/// main thread.
final class ModemController: ObservableObject {
    @Published private(set) var info: NetworkInfo? = nil         // the last network read that succeeded
    @Published private(set) var infoAt: Date? = nil
    @Published private(set) var infoFailure: String? = nil       // the last network read's failure; nil after a success
    // The last bands() that succeeded, in BandRat.allCases order; a RAT changed since shows the bands its change
    // read back. Read with a network read only while `bandsDue`.
    @Published private(set) var bands: [BandSet]? = nil
    @Published private(set) var bandsFailure: String? = nil      // the last bands read's failure; nil after a success
    @Published private(set) var antennas: [AntennaSignalSet] = []
    @Published private(set) var cellLock: CellLockState? = nil
    @Published private(set) var cellLockFailure: String? = nil
    @Published private(set) var profiles: [DataProfile] = []     // the last profiles() that succeeded
    @Published private(set) var sim: SimInfo? = nil               // the last SIM read that succeeded
    @Published private(set) var imei: String? = nil               // the last IMEI read that succeeded
    @Published private(set) var imeiFailure: String? = nil
    /// The IMEI history (ImeiHistory.swift) as last read: with each SIM & Data read and after each IMEI change; nil
    /// before the first read or without a history. Its failure is a sentence; nil after a read that succeeded.
    @Published private(set) var imeiHistory: ImeiHistory? = nil
    @Published private(set) var imeiHistoryFailure: String? = nil
    /// The attached module's USB serial number, read with the history; nil when none is attached or it gives none.
    @Published private(set) var moduleSerial: String? = nil
    @Published private(set) var settingsAt: Date? = nil           // the last settings read whose two parts succeeded
    @Published private(set) var settingsFailure: String? = nil    // the last settings read's failure; nil after a success
    @Published private(set) var running: ModemActivity? = nil
    // The result of the last change (or what runs or waits now), or why a change asked for was not made.
    // A read never writes here.
    @Published private(set) var result = ""
    @Published private(set) var resultIsFailure = false
    @Published private(set) var resultKind = ResultKind.success   // its banner (ResultLine.swift)
    @Published private(set) var undo: ModemUndo? = nil
    @Published var form: ProfileSettings? = nil   // the editor's values for the driver's profile
    @Published var pickedMode: String? = nil      // the Network screen's picker
    /// One sample a serving leg from each of the last `signalHistoryReads` network reads that succeeded (the
    /// Overview's and the Network screen's), oldest first; a read with no leg adds none but counts.
    @Published private(set) var signalHistory: [SignalSample] = []
    /// The next Network read also reads the bands / cell lock: set when the Network screen comes into view,
    /// on Refresh there and after every change; cleared only by a read that succeeded.
    private(set) var bandsDue = false
    private(set) var cellLockDue = false

    let quitNotice = ModemQuitNotice()

    static let networkInterval: TimeInterval = 5
    static let settingsInterval: TimeInterval = 30
    static let signalHistoryReads = 120   // about 10 minutes at the 5 s turns

    private static let readingQuitLine = "RMNet quits when the current request to the modem has finished."
    private static let radioOnQuitLine = "RMNet quits when the radio has been switched back on."
    private static let bandsQuitLine = "RMNet quits when the bands have been changed."
    private static let cellLockQuitLine = "RMNet quits when the cell lock has been changed."
    private static let imeiQuitLine = "RMNet quits when the IMEI change has finished."
    private static let simSlotQuitLine = "RMNet quits when the SIM slot has been switched."
    private static let anotherChange = "Another change to the modem has not finished yet. Nothing was changed; try again when it has."

    private let service: ModemServing
    private let queue: DispatchQueue
    private let driverProfile: () -> Int?        // the driver's RMNetProfile; nil when it is not attached
    private let replyToQuit: (Bool) -> Void      // NSApp.reply(toApplicationShouldTerminate:)
    private let requestAttention: () -> Void     // NSApp.requestUserAttention(.criticalRequest)
    private let now: () -> Date                  // the time of a network read (infoAt, the signal history)
    private let history: ImeiHistoryRecorder?    // where IMEI changes are recorded; nil: nowhere (the tests' default)
    private var timer: Timer?
    private var timerTab: ModemTab?              // the tab the timer reads
    private var tab: ModemTab?                   // the modem tab shown; nil: neither
    private var windowVisible = true
    private var confirming = false               // a confirmation is open: nothing new is read
    private var stopping = false                 // the app is quitting: nothing new starts
    private var quitWaits = false                // a quit waits for the running call to finish
    private var readingTab: ModemTab?            // the screen the running read is for
    private var readWanted = false               // the shown screen is to be read as soon as nothing runs
    private var change: ModemChange? = nil       // the change running, or waiting on the queue behind a read
    private var driverProfileRead: Int? = nil    // driverProfile() at the last settings refresh
    private var formSource: ProfileSettings? = nil  // the values `form` was last filled from
    private var pickedFrom: String? = nil        // the mode `pickedMode` was last set from
    private var historyReads: [Int] = []         // the samples each read in `signalHistory` added, oldest first

    init(service: ModemServing, queue: DispatchQueue, driverProfile: @escaping () -> Int?,
         replyToQuit: @escaping (Bool) -> Void, requestAttention: @escaping () -> Void,
         now: @escaping () -> Date = { Date() }, imeiHistory: ImeiHistoryRecorder? = nil,
         resultTimer: @escaping (TimeInterval, @escaping () -> Void) -> Void = mainRunLoopAfter) {
        self.resultTimer = resultTimer
        self.service = service
        self.queue = queue
        self.driverProfile = driverProfile
        self.replyToQuit = replyToQuit
        self.requestAttention = requestAttention
        self.now = now
        self.history = imeiHistory
    }

    private let resultTimer: (TimeInterval, @escaping () -> Void) -> Void
    private lazy var expiry = ResultExpiry(after: resultTimer, clear: { [weak self] in self?.setResult("", failure: false) })

    deinit { timer?.invalidate() }

    /// The profile the driver dials, as read at the last settings refresh; 1 when it was not attached.
    var profileID: Int { driverProfileRead ?? 1 }
    /// The driver gave its profile number at the last settings refresh.
    var driverAttached: Bool { driverProfileRead != nil }
    /// The form differs from the values it was filled from.
    var formEdited: Bool { form != formSource }
    // A read does not turn the buttons off (a change asked for during one waits for it); a change that
    // runs or waits, and quitting, do.
    var applyEnabled: Bool {
        guard changeFree, formEdited, let form else { return false }
        return profileProblem(profileID, form) == nil
    }
    // The same RATs in another order are not a change (sameMode).
    var modeChangeEnabled: Bool {
        guard changeFree, let picked = pickedMode, canonicalMode(picked) != nil else { return false }
        return !(info?.mode.map { sameMode(picked, $0) } ?? false)
    }
    var pinEnabled: Bool {
        guard changeFree, let sim, sim.state == .pin, let attempts = sim.pinAttempts else { return false }
        return attempts >= 1
    }
    var refreshEnabled: Bool { changeFree && !confirming }
    /// Change… for a RAT's bands: once the bands are read.
    var bandsChangeEnabled: Bool { refreshEnabled && bands != nil }
    /// Reset for `rat`: while it does not allow every supported band.
    func bandsResetEnabled(_ rat: BandRat) -> Bool {
        refreshEnabled && (bandSet(rat).map(bandsLocked) ?? false)
    }
    /// Reset all: while any RAT does not allow every supported band.
    var resetAllBandsEnabled: Bool { refreshEnabled && (bands?.contains(where: bandsLocked) ?? false) }
    /// The bands sheet's Apply, for `selection` as `rat`'s bands: a change that the modem can take (at least one
    /// band, every band supported: bandsProblem), and not the bands allowed now. Not turned off by the open
    /// sheet itself (it is a confirmation: `setConfirming`).
    func bandsApplyEnabled(_ rat: BandRat, _ selection: [Int]) -> Bool {
        guard changeFree, let set = bandSet(rat) else { return false }
        let wanted = bandSorted(selection)
        return bandsProblem(rat, wanted, supported: set.supported) == nil && Set(wanted) != Set(set.allowed)
    }
    /// What Put Back does, as a command for a terminal, since Put Back is lost when the app quits:
    /// `RMNet mode <m>`, or `RMNet apn set …` (never the password: `--password` asks for it). nil without an
    /// undo, and for a profile other than the driver's one now (`apn set` changes the driver's profile).
    var undoCommand: String? {
        switch undo {
        case .mode(let before)?: return modeRestoreCommand(before)
        case .profile(let id, let before)? where id == profileID: return profileRestoreCommand(before)
        default: return nil
        }
    }

    private var changeFree: Bool { change == nil && !stopping }

    /// The driver's profile's settings in the last profiles read; nil when it is not listed or not read.
    private var driverSettings: ProfileSettings? {
        profiles.first(where: { $0.id == profileID })?.settings
    }

    /// `rat`'s bands in the last read; nil when not read.
    private func bandSet(_ rat: BandRat) -> BandSet? {
        bands?.first(where: { $0.rat == rat })
    }

    // MARK: When the modem is read

    /// The modem screen shown (nil: none, also when the window closes).
    func setTabShown(_ tab: ModemTab?) {
        self.tab = tab
        updateTimer()
    }

    /// The window can be seen (true) or is minimized, hidden or covered (false).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateTimer()
    }

    /// While a confirmation or the bands sheet is open the timer's turns skip and nothing new is read; a read
    /// that was due meanwhile starts when it closes. The view calls the confirmed action (setRadio, changeMode,
    /// applyProfile, putBack, enterPin, or changeBands from the sheet's Apply) before `setConfirming(false)`, so
    /// that the change starts at once rather than after that read (it would still be made after the read, not
    /// refused).
    func setConfirming(_ open: Bool) {
        confirming = open
        readIfDue()
    }

    private var active: Bool { tab != nil && windowVisible && !stopping }

    // Reads the shown screen at once when it becomes active (or another screen is shown), then on each turn of
    // its timer (5 s Overview and Network, 30 s SIM & Data); stops when it is not active. The Network screen
    // coming into view makes the bands due. A Network read that runs serves the Overview shown meanwhile (the same
    // read, less the bands); an Overview read does not serve the Network screen, whose bands are due.
    private func updateTimer() {
        guard active, let tab else {
            timer?.invalidate()
            timer = nil
            timerTab = nil
            readWanted = false
            return
        }
        if timer != nil, timerTab == tab { return }
        if tab == .network {
            bandsDue = true
            cellLockDue = true
        }
        timer?.invalidate()
        let interval = tab == .simAndApn ? ModemController.settingsInterval : ModemController.networkInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerTab = tab
        if running == .reading, readingTab == tab || (tab == .overview && readingTab == .network) {
            readWanted = false  // the read running now is this screen's, or serves it
        } else {
            readWanted = true
            readIfDue()
        }
    }

    /// Starts the read that is due, once nothing runs (`read` checks the rest).
    private func readIfDue() {
        guard readWanted, running == nil else { return }
        read(refreshing: false)
    }

    /// One turn of the timer: skipped while a confirmation is open or a call runs.
    func tick() {
        read(refreshing: false)
    }

    /// Refresh: reads the shown screen at once, on the Network screen the bands too (on the Overview the network
    /// only). Nothing (and the bands not made due) when `read` would start nothing.
    func refresh() {
        read(refreshing: true)
    }

    /// Reads what the shown screen needs: the Network screen networkInfo(), then bands() when they are due and
    /// networkInfo() succeeded (after a failure the port is likely busy or the modem gone, and the bands stay
    /// due); the Overview networkInfo() only; SIM & Data profiles() then sim(); each in one block on the
    /// queue. Nothing while a call runs, no screen is shown, the window is hidden, a confirmation is open or the
    /// app quits.
    private func read(refreshing: Bool) {
        guard running == nil, active, !confirming, let tab else { return }
        readWanted = false
        running = .reading
        readingTab = tab
        let service = self.service
        switch tab {
        case .network, .overview:
            if refreshing, tab == .network {
                bandsDue = true
                cellLockDue = true
            }
            let onNetworkTab = tab == .network
            let withBands = onNetworkTab && bandsDue
            let withCellLock = onNetworkTab && cellLockDue
            queue.async {
                let info = service.networkInfo()
                let readInfo = try? info.get()
                let antennaRead: Result<[AntennaSignalSet], ModemFailure>?
                if onNetworkTab, let readInfo {
                    antennaRead = readInfo.radio == .on ? service.antennas() : .success([])
                } else {
                    antennaRead = nil
                }
                let sets = withBands && readInfo != nil ? service.bands() : nil
                let lockRead = withCellLock && readInfo != nil ? service.cellLock() : nil
                DispatchQueue.main.async { self.finishNetwork(info, antennaRead, sets, lockRead) }
            }
        case .simAndApn:
            let history = self.history
            queue.async {
                let listed = service.profiles()
                let sim = service.sim()
                let imei = service.imei()
                let kept = history.map { ($0.keeper.load(), $0.module()) }
                DispatchQueue.main.async {
                    self.finishSettings(listed, sim, imei)
                    if let kept { self.finishHistory(kept.0, module: kept.1) }
                }
            }
        }
    }

    // `sets` / `lockRead` nil: not read in this turn (not due, Overview tab, or networkInfo() failed).
    private func finishNetwork(_ outcome: Result<NetworkInfo, ModemFailure>,
                               _ antennaRead: Result<[AntennaSignalSet], ModemFailure>?,
                               _ sets: Result<[BandSet], ModemFailure>?,
                               _ lockRead: Result<CellLockState, ModemFailure>?) {
        running = nil
        readingTab = nil
        switch sets {
        case .success(let read)?:
            bands = read
            bandsFailure = nil
            bandsDue = false
        case .failure(let failure)?:
            bandsFailure = failure.message
        case nil:
            break
        }
        switch lockRead {
        case .success(let read)?:
            cellLock = read
            cellLockFailure = nil
            cellLockDue = false
        case .failure(let failure)?:
            cellLockFailure = failure.message
        case nil:
            break
        }
        if case .success(let readAntennas) = antennaRead {
            antennas = readAntennas
        }
        switch outcome {
        case .success(let read):
            let at = now()
            info = read
            infoAt = at
            infoFailure = nil
            recordSignal(read, at: at)
            // The pick follows the modem unless the owner picked another mode (the same mode in another
            // order, as the window's menu names it, is not another).
            if pickedMode == nil || pickedMode == pickedFrom
                || (pickedMode.flatMap { p in pickedFrom.map { sameMode(p, $0) } } ?? false) {
                setPick(read.mode)
            }
        case .failure(let failure):
            infoFailure = failure.message
        }
        readFinished()
    }

    /// One sample a serving leg of `read` at `at`; then only the last `signalHistoryReads` reads are kept.
    private func recordSignal(_ read: NetworkInfo, at: Date) {
        let technology = technologyLabel(read)
        let samples = (read.serving?.cells ?? []).map { leg in
            SignalSample(at: at, leg: leg.rat.hasPrefix("NR5G") ? "NR" : leg.rat, rsrp: leg.rsrp, rsrq: leg.rsrq,
                         sinr: leg.sinr, technology: technology, band: leg.band)
        }
        var history = signalHistory + samples
        historyReads.append(samples.count)
        while historyReads.count > ModemController.signalHistoryReads {
            history.removeFirst(historyReads.removeFirst())
        }
        signalHistory = history
    }

    private func finishSettings(_ listed: Result<[DataProfile], ModemFailure>,
                                _ read: Result<SimInfo, ModemFailure>,
                                _ readImei: Result<String, ModemFailure>) {
        running = nil
        readingTab = nil
        let earlierProfile = profileID
        driverProfileRead = driverProfile()
        var failure: String? = nil
        switch listed {
        case .success(let found): profiles = found
        case .failure(let f): failure = f.message
        }
        switch read {
        case .success(let found): sim = found
        case .failure(let f): failure = failure ?? f.message
        }
        switch readImei {
        case .success(let found):
            imei = found
            imeiFailure = nil
        case .failure(let f):
            imeiFailure = f.message
        }
        settingsFailure = failure
        if failure == nil { settingsAt = Date() }
        // The editor follows the modem unless the owner edited it; an edit for another profile than the
        // driver's now is dropped.
        if form == nil || !formEdited || profileID != earlierProfile { fillForm(driverSettings) }
        readFinished()
    }

    // After a read: a change that waited behind it on the queue runs now (its finish answers a quit and
    // reads again); otherwise as after any call.
    private func readFinished() {
        if let waiting = change {
            running = waiting.activity
            setResult(waiting.line, failure: false, kind: .progress)
            return
        }
        finished(succeeded: true, changed: false)
    }

    private func fillForm(_ settings: ProfileSettings?) {
        form = settings
        formSource = settings
    }

    private func setPick(_ mode: String?) {
        pickedMode = mode
        pickedFrom = mode
    }

    /// The form back to the driver's profile's settings as last read.
    func revertForm() {
        fillForm(driverSettings)
    }

    // MARK: Quitting

    /// Asked when the app is about to end. Stops the timer and anything new; a change that waits behind a
    /// read and has not started is dropped (it is never made). With no call running it returns false and
    /// the app may end now. Otherwise it returns true, and once the running call has finished
    /// `replyToQuit` is called once (a change is never cut short): with true after a read or a change that
    /// succeeded; with false (the quit is cancelled, the app asks for attention and the controller works
    /// again) after a change that did not, so that the owner sees its result line.
    func quitWhenFinished() -> Bool {
        stopping = true
        updateTimer()
        if let waiting = change, running == .reading, waiting.drop() {
            change = nil
            if waiting.quiet {
                setResult("", failure: false)
            } else {
                setResult("RMNet is quitting, so the change that waited for a read was not made.", failure: true)
            }
            waiting.dropped()   // its asker learns it was cancelled (the SIM slot watcher, should the quit be cancelled)
        }
        guard running != nil else { return false }
        quitWaits = true
        // A change running, or one that waited and has already started on the queue, is what the quit waits
        // for; with no change, what runs is a read.
        quitNotice.line = change?.quitLine ?? ModemController.readingQuitLine
        return true
    }

    /// The quit was cancelled elsewhere (the Messages controller's call failed; QuitGate.swift): working
    /// again, the shown screen read at once. A quit of this controller that still waited is cancelled too and
    /// never answered.
    func resumeAfterCancelledQuit() {
        stopping = false
        quitWaits = false
        quitNotice.line = ""
        updateTimer()
    }

    // Called by each finish after `running` is cleared; true when a quit was waiting (it is answered).
    private func answeredQuit(succeeded: Bool) -> Bool {
        guard quitWaits else { return false }
        quitWaits = false
        quitNotice.line = ""
        if succeeded {
            replyToQuit(true)
            return true
        }
        stopping = false
        replyToQuit(false)
        requestAttention()
        updateTimer()  // the app goes on: the shown screen is read again
        return true
    }

    // After every call: the quit's answer, else the shown screen read again after a change, or a read that
    // became due while the call ran.
    private func finished(succeeded: Bool, changed: Bool) {
        if answeredQuit(succeeded: succeeded) { return }
        if changed { readWanted = true }
        readIfDue()
    }

    // MARK: The changes
    //
    // Each change first checks what it was asked to do and, when it does nothing, says why on the result
    // line. While the app quits nothing starts (the quit line says so). One change at a time: while
    // another runs or waits, a new one is refused with a sentence. A change asked for while a read runs
    // waits for it on the queue and starts as soon as it has finished (ruling R12).

    private func refuse(_ why: String) {
        setResult(why, failure: true)
    }

    /// Puts the call on the queue: running at once, or waiting behind the read that runs. `quiet` and `dropped`: as
    /// ModemChange's.
    private func submit<T>(_ activity: ModemActivity, line: String, quitLine: String, quiet: Bool = false,
                           dropped: @escaping () -> Void = {},
                           _ call: @escaping (ModemServing) -> Result<T, ModemFailure>,
                           then finish: @escaping (Result<T, ModemFailure>) -> Void) {
        let next = ModemChange(activity, line: line, quitLine: quitLine, quiet: quiet, dropped: dropped)
        change = next
        if running == nil {
            running = activity
            setResult(line, failure: false, kind: .progress)
        } else {
            setResult("Waiting for the current read to finish…", failure: false, kind: .progress)
        }
        let service = self.service
        queue.async {
            guard next.start() else { return }  // dropped: the app began to quit before it started
            let outcome = call(service)
            DispatchQueue.main.async { finish(outcome) }
        }
    }

    // The change has finished (its result is handed back).
    private func changeEnded() {
        running = nil
        change = nil
    }

    /// Switches the radio on (AT+CFUN=1) or off (AT+CFUN=4). No undo: the other switch is the way back.
    func setRadio(on: Bool) {
        guard !stopping else { return }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        submit(.radio, line: on ? "Switching the radio on…" : "Switching the radio off…",
               quitLine: on ? ModemController.radioOnQuitLine : "RMNet quits when the radio has been switched off.",
               { $0.setRadio(on: on) }) { outcome in
            self.changeEnded()
            switch outcome {
            case .success(let switched): self.setResult(radioSentence(switched), failure: false)
            case .failure(let failure): self.setResult(failure.message, failure: true)
            }
            self.finished(succeeded: (try? outcome.get()) != nil, changed: true)
        }
    }

    /// Changes the network mode to `pickedMode`.
    func changeMode() {
        guard !stopping else { return }
        guard let mode = pickedMode else { return refuse("Choose a network mode first. Nothing was changed.") }
        guard canonicalMode(mode) != nil else {
            return refuse("RMNet cannot set the network mode \(modemTextSafe(mode)). Nothing was changed.")
        }
        guard !(info?.mode.map { sameMode(mode, $0) } ?? false) else {
            return refuse("The network mode is already \(modeWords(mode)). Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        submit(.mode, line: "Changing the network mode to \(modeWords(mode))…",
               quitLine: "RMNet quits when the network mode has been changed.",
               { $0.setMode(mode) }) { self.finishMode($0, puttingBack: false) }
    }

    private func finishMode(_ outcome: Result<ModeChange, ModemFailure>, puttingBack: Bool) {
        changeEnded()
        switch outcome {
        case .success(let done):
            if puttingBack {
                undo = nil
            } else {
                // Put Back only for a mode RMNet can set again (ruling R8).
                undo = canonicalMode(done.before) != nil ? .mode(done.before) : nil
            }
            setPick(done.after)
            // A mode before that RMNet cannot set again: said, with its `RMNet at` line, as `RMNet mode` says it
            // (ruling R8).
            let noWayBack = puttingBack || canonicalMode(done.before) != nil ? ""
                : " The earlier value \(modemTextSafe(done.before)) \(modeAtWayBack(done.before))"
            setResult(modeSentence(done) + noWayBack, failure: false, kind: noWayBack.isEmpty ? .success : .warning)
        case .failure(let failure):
            setPick(info?.mode)
            setResult(failure.message, failure: true)
        }
        finished(succeeded: (try? outcome.get()) != nil, changed: true)
    }

    /// Writes the form to the driver's profile, with a redial (the service switches the radio off and on
    /// again when it was on).
    func applyProfile() {
        guard !stopping else { return }
        let id = profileID
        guard let settings = form else {
            let listed = profiles.isEmpty || profiles.contains(where: { $0.id == id })
            return refuse(listed ? "The settings of profile \(id) have not been read. Nothing was changed."
                                 : "The modem does not list profile \(id). Nothing was changed.")
        }
        guard formEdited else { return refuse("Profile \(id) already has these settings. Nothing was changed.") }
        if let problem = profileProblem(id, settings) { return refuse("\(problem) Nothing was changed.") }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        submit(.profile, line: "Changing profile \(id)…", quitLine: ModemController.radioOnQuitLine,
               { $0.setProfile(id, to: settings, redial: true) }) { self.finishProfile($0, id: id, puttingBack: false) }
    }

    private func finishProfile(_ outcome: Result<ProfileChange, ModemFailure>, id: Int, puttingBack: Bool) {
        changeEnded()
        let succeeded: Bool
        switch outcome {
        case .success(let done):
            undo = puttingBack ? nil : .profile(id: id, done.before)
            // The editor shows what the modem now has (read back by the service); the read that follows
            // fills it again.
            fillForm(id == profileID ? done.after : driverSettings)
            // The profile was changed, but a radio left off is said as a failure: the connection is down.
            if case .radioLeftOff = done.redial { succeeded = false } else { succeeded = true }
            setResult(profileSentence(done), failure: !succeeded)
        case .failure(let failure):
            // The form is kept as it is (ruling R11): an edit can be corrected and applied again.
            if let before = failure.profileBefore {
                // The change may have reached the modem (ruling R19): the way back to the settings before it.
                // A Put Back keeps its undo, the settings it was to restore (they would be lost otherwise). An
                // edited form's source is no longer known to be what the modem has, so the earlier settings
                // typed again still count as a change; an unedited form follows the next read.
                if !puttingBack { undo = .profile(id: id, before) }
                if formEdited { formSource = nil }
            }
            setResult(failure.message, failure: true)
            succeeded = false
        }
        finished(succeeded: succeeded, changed: true)
    }

    /// Applies the undo the way the change was made (a profile put back redials); clears it on success.
    func putBack() {
        guard !stopping else { return }
        guard let undo else { return refuse("There is no change to put back.") }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        switch undo {
        case .mode(let mode):
            submit(.mode, line: "Putting the network mode back to \(modeWords(mode))…",
                   quitLine: "RMNet quits when the network mode has been changed.",
                   { $0.setMode(mode) }) { self.finishMode($0, puttingBack: true) }
        case .profile(let id, let settings):
            submit(.profile, line: "Putting profile \(id) back…", quitLine: ModemController.radioOnQuitLine,
                   { $0.setProfile(id, to: settings, redial: true) }) { self.finishProfile($0, id: id, puttingBack: true) }
        }
    }

    /// Sends the PIN with the attempts left that the owner's confirmation showed, passed to the service
    /// unchanged (ruling R13): the service sends nothing unless the SIM still shows that many. The PIN is
    /// not kept: only the block on the queue holds it, until the call returns.
    func enterPin(_ pin: String, shownAttempts: Int) {
        guard !stopping else { return }
        guard let sim else { return refuse("The SIM has not been read yet. The PIN was not sent.") }
        guard sim.state == .pin else {
            return refuse("The SIM does not ask for its PIN now (SIM: \(simStateWords(sim.state))). The PIN was not sent.")
        }
        guard shownAttempts >= 1 else {
            return refuse("The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not enter "
                          + "PUKs. The PIN was not sent.")
        }
        if let problem = pinProblem(pin) { return refuse("\(problem) The PIN was not sent.") }
        guard change == nil else {
            return refuse("Another change to the modem has not finished yet. The PIN was not sent; enter it again when it has.")
        }
        submit(.pin, line: "Sending the PIN to the SIM…", quitLine: "RMNet quits when the PIN has been checked.",
               { $0.enterPin(pin, shownAttempts: shownAttempts) }) { outcome in
            self.changeEnded()
            let succeeded: Bool
            switch outcome {
            case .success(let checked):
                if let read = checked.sim { self.sim = read }  // the attempts and the Unlock state at once
                succeeded = checked.accepted  // a refused PIN is said as a failure
                self.setResult(pinSentence(checked), failure: !succeeded)
            case .failure(let failure):
                succeeded = false
                self.setResult(failure.message, failure: true)
            }
            self.finished(succeeded: succeeded, changed: true)
        }
    }

    // MARK: The bands
    //
    // Never sent: an empty list or a band the modem does not support (bandsProblem, against the supported
    // bands as last read; the service checks again against what it reads first). A change takes effect at once
    // and the modem keeps it; it has no Put Back: Reset is the way back to every supported band.

    /// Sets `rat`'s bands to `wanted`, sorted, each band once.
    func changeBands(_ rat: BandRat, to wanted: [Int]) {
        guard !stopping else { return }
        guard let set = bandSet(rat) else { return refuse("The \(rat.name) bands have not been read. Nothing was changed.") }
        let list = bandSorted(wanted)
        if let problem = bandsProblem(rat, list, supported: set.supported) { return refuse("\(problem) Nothing was changed.") }
        guard Set(list) != Set(set.allowed) else {
            return refuse("The \(rat.name) bands are already \(bandsWords(list, set.supported)). Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        runBands([BandsStep(rat: rat, bands: list, supported: set.supported)],
                 line: "Changing the \(rat.name) bands to \(bandsWords(list, set.supported))…")
    }

    /// Sets `rat`'s bands to every band it supports.
    func resetBands(_ rat: BandRat) {
        guard !stopping else { return }
        guard let set = bandSet(rat) else { return refuse("The \(rat.name) bands have not been read. Nothing was changed.") }
        let all = bandSorted(set.supported)
        if let problem = bandsProblem(rat, all, supported: all) { return refuse("\(problem) Nothing was changed.") }
        guard bandsLocked(set) else {
            return refuse("The \(rat.name) bands are already \(bandsWords(all, all)). Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        runBands([BandsStep(rat: rat, bands: all, supported: all)],
                 line: "Resetting the \(rat.name) bands to \(bandsWords(all, all))…")
    }

    /// Sets every RAT to all the bands it supports, in the order LTE, 5G NSA, 5G SA, in one change that stops at
    /// the first failure. Offered (and run) while the last read shows a RAT that does not allow them all, but all
    /// three are sent, whatever that read showed (the bands may have changed elsewhere since): the service reads
    /// each RAT's bands first and writes nothing for one that already allows every supported band.
    func resetAllBands() {
        guard !stopping else { return }
        guard let sets = bands else { return refuse("The bands have not been read. Nothing was changed.") }
        guard sets.contains(where: bandsLocked) else {
            return refuse("\(ratList(sets.map { $0.rat })) already allow all their supported bands. Nothing was changed.")
        }
        let steps = BandRat.allCases.compactMap(bandSet).map {
            BandsStep(rat: $0.rat, bands: bandSorted($0.supported), supported: bandSorted($0.supported))
        }
        for step in steps {
            if let problem = bandsProblem(step.rat, step.bands, supported: step.supported) {
                return refuse("\(problem) Nothing was changed.")
            }
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        runBands(steps, all: true,
                 line: "Resetting the \(ratList(steps.map { $0.rat })) bands to all supported bands…")
    }

    /// `steps` in order on the queue, one setBands each, as one change (`.bands`), stopping at the first
    /// failure; then the result line (`all`: Reset all's), and the screen read again with the bands (after a
    /// failure too).
    private func runBands(_ steps: [BandsStep], all: Bool = false, line: String) {
        submit(.bands, line: line, quitLine: ModemController.bandsQuitLine, {
            (service: ModemServing) -> Result<BandsOutcome, ModemFailure> in
            var outcome = BandsOutcome()
            for step in steps {
                switch service.setBands(step.rat, to: step.bands) {
                case .success(let change): outcome.done.append((step.rat, change))
                case .failure(let failure):
                    outcome.failed = failure
                    return .success(outcome)
                }
            }
            return .success(outcome)
        }) { ended in
            switch ended {
            case .success(let outcome): self.finishBands(outcome, steps, all: all)
            case .failure(let failure): self.finishBands(BandsOutcome(done: [], failed: failure), steps, all: all)
            }
        }
    }

    private func finishBands(_ outcome: BandsOutcome, _ steps: [BandsStep], all: Bool) {
        changeEnded()
        // Each RAT set shows at once the bands its change read back (the read that follows replaces them).
        if var sets = bands {
            for (rat, change) in outcome.done {
                if let i = sets.firstIndex(where: { $0.rat == rat }) {
                    sets[i] = BandSet(rat: rat, allowed: change.after, supported: sets[i].supported)
                }
            }
            bands = sets
        }
        bandsDue = true  // read again with the screen, after a failure too
        let line: String
        if !all, let step = steps.first {
            if let failure = outcome.failed {
                line = failure.message
            } else if let done = outcome.done.first?.change, done.before == done.after {
                // The modem had them already (changed elsewhere since the last read): nothing was written.
                line = "The \(step.rat.name) bands are already \(bandsWords(done.after, step.supported)). Nothing was changed."
            } else {
                let after = outcome.done.first?.change.after ?? step.bands
                line = "\(step.rat.name) bands set to \(bandsWords(after, step.supported))."
            }
        } else {
            // Reset all: only the RATs whose bands changed are named (the service wrote nothing for the others).
            let changed = outcome.done.filter { $0.change.before != $0.change.after }.map { $0.rat }
            let made = changed.isEmpty ? "" : "\(ratList(changed)) bands set to all supported bands."
            if let failure = outcome.failed {
                let notReset = steps.dropFirst(outcome.done.count).map { $0.rat }
                line = (made.isEmpty ? "" : "\(made) ") + "\(failure.message) Not reset: \(ratList(notReset))."
            } else {
                line = made.isEmpty ? "Bands: all supported bands were already allowed." : made
            }
        }
        setResult(line, failure: outcome.failed != nil)
        finished(succeeded: outcome.failed == nil, changed: true)
    }

    // MARK: Cell lock and IMEI

    private func finishHistory(_ read: Result<ImeiHistory, ModemFailure>, module: String?) {
        moduleSerial = module
        switch read {
        case .success(let h):
            imeiHistory = h
            imeiHistoryFailure = nil
        case .failure(let f):
            imeiHistoryFailure = f.message
        }
    }

    func setNrCellLock(_ lock: NrCellLock?) {
        guard !stopping else { return }
        if let problem = nrCellLockProblem(lock, supportedSaBands: bandSet(.sa)?.supported) {
            return refuse("\(problem) Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        let line = lock.map { "Locking 5G SA cell to PCI \($0.pci), ARFCN \($0.arfcn)…" }
            ?? "Unlocking 5G SA cell lock…"
        submit(.cellLock, line: line, quitLine: ModemController.cellLockQuitLine,
               { $0.setNrCellLock(lock) }) { outcome in
            self.finishCellLock(outcome)
        }
    }

    func setLteCellLock(_ cells: [LteLockedCell]) {
        guard !stopping else { return }
        if let problem = lteCellLockProblem(cells) { return refuse("\(problem) Nothing was changed.") }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        let line = cells.isEmpty ? "Unlocking LTE cell lock…" : "Locking LTE \(cells.count == 1 ? "cell" : "cells")…"
        submit(.cellLock, line: line, quitLine: ModemController.cellLockQuitLine,
               { $0.setLteCellLock(cells) }) { outcome in
            self.finishCellLock(outcome)
        }
    }

    /// Locks to a cell the modem uses (a cell in use chosen on the Network screen): the service reads the serving cell
    /// again in the session that writes the lock, and changes nothing when the modem no longer uses that cell.
    func lockCellInUse(_ cell: CellInUse) {
        guard !stopping else { return }
        if let problem = cellInUseProblem(cell) { return refuse("\(problem) Nothing was changed.") }
        if case .nr(let lock) = cell, let problem = nrCellLockProblem(lock, supportedSaBands: bandSet(.sa)?.supported) {
            return refuse("\(problem) Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        let line: String
        switch cell {
        case .nr(let lock): line = "Locking 5G SA cell to PCI \(lock.pci), ARFCN \(lock.arfcn)…"
        case .lte(let one): line = "Locking LTE cell to PCI \(one.pci), EARFCN \(one.earfcn)…"
        case .serving: line = "Locking the serving cell…"
        }
        submit(.cellLock, line: line, quitLine: ModemController.cellLockQuitLine,
               { $0.lockCellInUse(cell) }) { outcome in
            self.finishCellLock(outcome)
        }
    }

    func unlockAllCells() {
        guard !stopping else { return }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        submit(.cellLock, line: "Unlocking cell locks…", quitLine: ModemController.cellLockQuitLine,
               { (service: ModemServing) -> Result<CellLockChange, ModemFailure> in
                   switch service.setNrCellLock(nil) {
                   case .failure(let f): return .failure(f)
                   case .success(let nrChange):
                       switch service.setLteCellLock([]) {
                       case .failure(let f): return .failure(f)
                       case .success(let lteChange):
                           let beforeState: CellLockState
                           switch nrChange {
                           case .unchanged(let s), .changed(let s, _): beforeState = s
                           }
                           let afterState: CellLockState
                           switch lteChange {
                           case .unchanged(let s), .changed(_, let s): afterState = s
                           }
                           return .success(beforeState == afterState
                               ? .unchanged(afterState)
                               : .changed(before: beforeState, after: afterState))
                       }
                   }
               }) { outcome in
            self.changeEnded()
            self.cellLockDue = true
            switch outcome {
            case .success(let ch):
                switch ch {
                case .unchanged(let s), .changed(_, let s): self.cellLock = s
                }
                let line = ch == .unchanged(self.cellLock ?? CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false))
                    ? "Cell locks are already unlocked."
                    : "Unlocked 5G SA and LTE cell locks."
                self.setResult(line, failure: false)
            case .failure(let failure):
                self.setResult(failure.message, failure: true)
            }
            self.finished(succeeded: (try? outcome.get()) != nil, changed: true)
        }
    }

    func setCellLockPersist(lte: Bool, nr: Bool) {
        guard !stopping else { return }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        submit(.cellLock, line: "Updating cell-lock persistence…", quitLine: ModemController.cellLockQuitLine,
               { $0.setCellLockPersist(lte: lte, nr: nr) }) { outcome in
            self.finishCellLock(outcome)
        }
    }

    private func finishCellLock(_ outcome: Result<CellLockChange, ModemFailure>) {
        changeEnded()
        cellLockDue = true
        switch outcome {
        case .success(let ch):
            switch ch {
            case .unchanged(let s), .changed(_, let s): cellLock = s
            }
            setResult(cellLockSentence(ch), failure: false)
        case .failure(let failure):
            setResult(failure.message, failure: true)
        }
        finished(succeeded: (try? outcome.get()) != nil, changed: true)
    }

    /// `expect`: what the window's question was confirmed for (the module shown and the IMEI then; for Change Back… the
    /// module the history entry was recorded on): written only when the port that writes finds both
    /// (ModemService.setImei); nil: on any (the tests). An IMEI written whose restart failed is a warning: the IMEI shown
    /// is the new one.
    func changeImei(_ newImei: String, reboot: Bool, expect: ImeiExpectation? = nil) {
        guard !stopping else { return }
        if let problem = imeiProblem(newImei) { return refuse("\(problem) Nothing was changed.") }
        if let current = imei, current == newImei {
            return refuse("IMEI is already \(current). Nothing was changed.")
        }
        guard change == nil else { return refuse(ModemController.anotherChange) }
        let history = self.history
        // The change, then (whatever its outcome) its entry in the IMEI history and the history read again, all on
        // the queue, so the window never waits for the file. The entry's module and IMEI before are those the change's
        // own port open read (ImeiWrite), not the window's last read. The attempt itself always "succeeds": its outcome
        // is in it.
        submit(.imei, line: "Setting IMEI to \(newImei)…", quitLine: ModemController.imeiQuitLine,
               { (service: ModemServing) -> Result<ImeiAttempt, ModemFailure> in
                   let write = service.setImei(newImei, reboot: reboot, expect: expect)
                   let outcome = write.outcome
                   guard let history else { return .success(ImeiAttempt(outcome: outcome)) }
                   var problem: String? = nil
                   if let entry = imeiHistoryEntry(after: newImei, before: write.before, restart: reboot, outcome: outcome,
                                                   source: .app, module: write.module, at: history.now()) {
                       problem = history.keeper.append(entry)
                   }
                   return .success(ImeiAttempt(outcome: outcome, recordProblem: problem,
                                               history: history.keeper.load(), module: history.module()))
               }) { attempt in
            self.changeEnded()
            guard case .success(let done) = attempt else { return }   // the closure never fails
            if let read = done.history { self.finishHistory(read, module: done.module) }
            let notRecorded = done.recordProblem.map { " The change was not recorded in the IMEI history: \($0)" } ?? ""
            switch done.outcome {
            case .success(let ch):
                var later = false
                switch ch {
                case .unchanged(let current): self.imei = current
                case .rebooting(_, let after): self.imei = after
                case .setTakesEffectAfterRestart: later = true
                case .restartFailed(_, let after, _):
                    self.imei = after
                    later = true
                }
                self.setResult(imeiSentence(ch) + notRecorded, failure: false,
                               kind: notRecorded.isEmpty && !later ? .success : .warning)
            case .failure(let failure):
                self.setResult(failure.message + notRecorded, failure: true)
            }
            self.finished(succeeded: (try? done.outcome.get()) != nil, changed: true)
        }
    }

    // MARK: The SIM slot

    /// Switches the SIM slot (AT+QUIMSLOT=, ModemService.setSimSlot), as one change. Asked in the window (the SIM &
    /// Data screen's confirmation): it waits for the new slot's SIM and the registration, and its sentence is the
    /// result line. `automatic` (the SIM slot watcher, SimSlotWatch.swift): it waits for the SIM only, with `expect`
    /// checked on the port that writes, is refused silently (false: nothing started) while another change runs or the
    /// app quits, leaves no result line (the watcher says what came of it), and does not cancel a quit when it fails.
    /// `completion` gets the outcome (or `.cancelled`: it waited behind a read and the app began to quit, so it never
    /// ran) before a quit that waits is answered; the slot it hands back is switched to at once, as part of the same
    /// change: the watcher's switch back, which a quit waits for too (a modem left on an empty slot is what it undoes).
    /// The SIM is read again afterwards.
    @discardableResult
    func changeSimSlot(_ slot: Int, automatic: Bool = false, expect: SimSlotExpectation? = nil,
                       completion: ((SimSlotOutcome) -> Int?)? = nil) -> Bool {
        guard !stopping else { return false }
        guard simSlots.contains(slot) else {
            if !automatic { refuse("The modem has SIM slots 1 and 2. Nothing was changed.") }
            return false
        }
        guard change == nil else {
            if !automatic { refuse(ModemController.anotherChange) }
            return false
        }
        runSimSlot(slot, automatic: automatic, expect: expect, completion: completion)
        return true
    }

    private func runSimSlot(_ slot: Int, automatic: Bool, expect: SimSlotExpectation?,
                            completion: ((SimSlotOutcome) -> Int?)?) {
        submit(.simSlot, line: "Switching to SIM \(slot)…", quitLine: ModemController.simSlotQuitLine, quiet: automatic,
               dropped: { _ = completion?(.cancelled) },
               { $0.setSimSlot(slot, wait: automatic ? .sim : .registration, expect: expect) }) { outcome in
            self.changeEnded()
            switch outcome {
            case .success(let c):
                self.setResult(automatic ? "" : simSlotSentence(c), failure: false)
            case .failure(let failure):
                self.setResult(automatic ? "" : failure.message, failure: !automatic)
            }
            if let back = completion?(.finished(outcome)), simSlots.contains(back) {
                // The switch back: on the module the switch expected, from the slot it went to, while that slot still has
                // no usable SIM with the radio on (checked on the port that writes, as the try was). A quit that waits
                // goes on waiting (its line stays): `running` is set again before this returns.
                let undo = SimSlotExpectation(module: expect?.module, slot: slot, unusableSim: true)
                self.runSimSlot(back, automatic: true, expect: undo, completion: completion)
                return
            }
            self.finished(succeeded: automatic || (try? outcome.get()) != nil, changed: true)
        }
    }

    /// The banner's X: the line is cleared, so it does not come back on another screen or a new window.
    func dismissResult() {
        setResult("", failure: false)
    }

    /// The pointer on the banner (true) or off it: a success does not go while it is on it.
    func hoverResult(_ on: Bool) {
        expiry.hover(on)
    }

    /// `kind`: progress for a change's words while it runs (or waits), warning for a success with something to read;
    /// a failure is one, anything else a success.
    private func setResult(_ line: String, failure: Bool, kind: ResultKind = .success) {
        result = line
        resultIsFailure = failure
        resultKind = failure ? .failure : kind
        expiry.shown(line, resultKind)
    }
}

/// An IMEI change as the queue hands it back: the service's outcome, and when a history is kept, why the change
/// could not be recorded (nil: it was, or there was nothing to record), the history read again and the module.
private struct ImeiAttempt {
    let outcome: Result<ImeiChange, ModemFailure>
    var recordProblem: String? = nil
    var history: Result<ImeiHistory, ModemFailure>? = nil
    var module: String? = nil
}

/// One RAT's part of a bands change: the bands it is set to, and those it supports (as last read).
private struct BandsStep {
    let rat: BandRat
    let bands: [Int]       // sorted, each band once
    let supported: [Int]
}

/// What a bands change did: the RATs set, in order, with what each read back; then the failure that stopped it.
private struct BandsOutcome {
    var done: [(rat: BandRat, change: BandChange)] = []
    var failed: ModemFailure? = nil
}

// MARK: - The bands' words

/// A RAT's bands as the Network screen shows them, the words `RMNet bands` prints: `all 31 supported bands
/// allowed`, or `2 of 31 supported bands allowed: 3, 41` (compared as sets).
func bandsSummary(_ set: BandSet) -> String {
    let allowed = Set(set.allowed)
    if !allowed.isEmpty && allowed == Set(set.supported) { return "all \(allowed.count) supported bands allowed" }
    return "\(allowed.count) of \(Set(set.supported).count) supported bands allowed: \(bandListWords(set.allowed))"
}

/// A band as the bands sheet labels it, as 3GPP names it: `B3` for LTE, `n41` for 5G (NSA and SA).
func bandLabel(_ rat: BandRat, _ band: Int) -> String {
    rat == .lte ? "B\(band)" : "n\(band)"
}

/// The RAT does not allow every band it supports (compared as sets): Reset has something to do.
func bandsLocked(_ set: BandSet) -> Bool {
    Set(set.allowed) != Set(set.supported)
}

/// `3, 41`, or `all 28 supported bands` when `bands` are every one of `supported`.
private func bandsWords(_ bands: [Int], _ supported: [Int]) -> String {
    !bands.isEmpty && Set(bands) == Set(supported) ? "all \(Set(supported).count) supported bands" : bandListWords(bands)
}

/// `LTE`, `5G NSA and 5G SA`, `LTE, 5G NSA and 5G SA`.
private func ratList(_ rats: [BandRat]) -> String {
    let names = rats.map { $0.name }
    guard let last = names.last, names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + last
}
