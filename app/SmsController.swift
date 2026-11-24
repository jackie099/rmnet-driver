// The Messages screen's state and the calls it makes to the modem: one call at a time, the list's line and
// the result line kept apart, and quitting that waits for a running call. It takes any SmsServing, and
// the two AppKit calls it needs (the answer to the terminate question, the request for attention) are
// closures given by the app delegate, so it uses no AppKit or SwiftUI and is tested with a fake service
// (tests/app/SmsControllerTests.swift). Nothing here logs or stores message text or numbers.
import Combine
import Foundation

/// What is running on the service's queue; at most one call at a time.
enum SmsActivity: Equatable {
    case listing
    case counting     // the background count of unread messages (nothing on the screen shows it)
    case deleting
    case sending
    case unblocking   // streaming queued incoming messages in short windows and storing them unread
}

/// The line the window shows above its screen while a quit waits for a call to the modem; "" otherwise.
/// Its own object, so the window can show it without observing the whole controller (typing a message
/// must not redraw the rest of the window).
final class SmsQuitNotice: ObservableObject {
    @Published fileprivate(set) var line = ""
}

/// How many messages are unread, for the menu bar item's panel: the window's marks (`count`), and the unread stored
/// parts the background count found on the modem since the window last listed (`onModem`; a message of several parts
/// counts each). Its own object for the same reason.
final class SmsUnreadNotice: ObservableObject {
    @Published fileprivate(set) var count = 0
    @Published fileprivate(set) var onModem = 0
}

/// The app has exactly one, owned by the app delegate (StatusView.swift), so that quitting can wait for a
/// running call. Its methods are called on the main thread; every service call runs on `queue`, one at a
/// time, with the result handed back to the main thread.
final class SmsController: ObservableObject {
    @Published private(set) var messages: [SmsMessage] = []
    @Published private(set) var listedAt: Date? = nil        // the last listing that succeeded
    @Published private(set) var listFailure: String? = nil   // the last listing's failure; nil after a success
    @Published private(set) var storeUsed: Int? = nil        // the store's use at the last successful listing
    @Published private(set) var storeTotal: Int? = nil
    @Published private(set) var unread: Set<SmsMessageKey> = [] {
        didSet { if unreadNotice.count != unread.count { unreadNotice.count = unread.count } }
    }
    @Published private(set) var running: SmsActivity? = nil
    // The result of the last send or delete (or what runs now). A listing never writes here. Its banner: dismissed,
    // it is cleared; a success goes by itself (ResultLine.swift).
    @Published private(set) var result = ""
    @Published private(set) var resultIsFailure = false
    @Published private(set) var resultKind = ResultKind.success
    @Published var to = ""     // not saved anywhere
    @Published var text = "" { // not saved anywhere; always the committed text the field shows
        // After a success, starting a new message clears the result line.
        didSet {
            if clearResultOnTyping, !text.isEmpty {
                clearResultOnTyping = false
                setResult("", failure: false)
            }
        }
    }
    @Published var composing = false  // an input method has text in the field that is not committed yet
    /// The conversation shown (conversationKey of its number). Showing it is reading it: its unread marks go. Another
    /// one has its own reply field (SmsView's ReplyField), so nothing is being composed in it yet.
    @Published var selectedConversation: String? = nil {
        didSet {
            markShownConversationRead()
            if selectedConversation != oldValue, replyComposing { replyComposing = false }
        }
    }
    /// Each conversation's reply being written (by conversationKey), so a reply never goes to another conversation
    /// than the one it was written in. Not saved anywhere.
    @Published private(set) var replyDrafts: [String: String] = [:]
    /// The reply of the conversation shown (reading it; the field writes with setReplyDraft, for its own conversation).
    var replyText: String {
        get { selectedConversation.flatMap { replyDrafts[$0] } ?? "" }
        set {
            guard let key = selectedConversation else { return }
            setReplyDraft(newValue, for: key)
        }
    }

    /// The reply written in the conversation `key`, whichever conversation is shown when it comes (an input method can
    /// commit its text after another conversation was chosen: it goes to the one it was typed in).
    func replyDraft(for key: String) -> String { replyDrafts[key] ?? "" }

    func setReplyDraft(_ text: String, for key: String) {
        let value: String? = text.isEmpty ? nil : text
        if replyDrafts[key] != value { replyDrafts[key] = value }
    }
    @Published var replyComposing = false
    /// When this run of RMNet sent each stored part of the last listing (index → time), so a sent message has a time:
    /// the modem keeps none for it. Kept by the part (its index and PDU, sentTimes), so an index that holds another
    /// message later does not take its time. In memory only.
    @Published private(set) var sentAt: [Int: Date] = [:]
    /// The stored indices of the last listing whose send got no answer in this run: they may have gone (Not confirmed).
    @Published private(set) var unconfirmed: Set<Int> = []
    /// Set when a storage-less `+CMTI:` was seen while automatic unblocking is turned off: Messages offers `Unblock`.
    @Published private(set) var incomingBlocked = false

    let quitNotice = SmsQuitNotice()
    let unreadNotice = SmsUnreadNotice()

    private let service: SmsServing
    private let backgroundService: SmsServing    // the background listing's: a busy port fails at once
    private let notifyEnabled: () -> Bool        // Settings' Notify about new messages
    private let autoUnblockEnabled: () -> Bool   // Settings' Unblock incoming messages automatically
    private let hasRescued: () -> Bool           // AtPort.hasRescuedDeliveries
    private let now: () -> Date
    private let alert: (MessageAlert) -> Void    // posts a notification (MessageNotifier.swift)
    private var watch = NewMessageWatch()
    // What the last listing listed (each stored entry) and where from: a delete or a Retry sends them, to be checked
    // against the modem first (SmsService.checkListed).
    private var listedParts: [StoredPdu] = []
    private var listedPlace = SmsPlace(complete: false)
    // In memory only, kept while the listing still has the part: when each part RMNet sent went, the parts the modem
    // confirmed but still lists as unsent (never offered for Retry), and those whose send got no answer.
    private var sentTimes: [StoredPart: Date] = [:]
    private var confirmedParts: Set<StoredPart> = []
    private var unknownParts: Set<StoredPart> = []
    private let queue: DispatchQueue
    private let replyToQuit: (Bool) -> Void      // NSApp.reply(toApplicationShouldTerminate:)
    private let requestAttention: () -> Void     // NSApp.requestUserAttention(.criticalRequest)
    private var timer: Timer?
    private var unblockTimer: Timer?
    private var unblockManual = false
    private var unblockHealOnly = false
    private var unblockDeadline: Date? = nil
    private var unblockParts: [StoredPdu] = []
    private var unblockRestoredCnmi = false
    private var unblockStreaming = false
    private var unblockFinishing = false
    private var sliceInFlight = false
    private var pendingAutoUnblock = false
    private var pendingHeal = false
    private var checkCnmiOnce = false            // armed when a modem attaches, to heal any crashed AT+CNMI=2,2
    private let unblockWindow: TimeInterval
    private let unblockSlicePause: TimeInterval
    private var tabShown = false
    private var windowVisible = true
    private var confirmingDelete = false     // the delete confirmation is open: timer ticks skip
    private var clearResultOnTyping = false
    private var stopping = false             // the app is quitting: nothing new starts
    private var quitWaits = false            // a quit waits for the running call to finish

    static let refreshInterval: TimeInterval = 15
    static let defaultUnblockWindow: TimeInterval = 95
    static let defaultSlicePause: TimeInterval = 0.35

    private let resultTimer: (TimeInterval, @escaping () -> Void) -> Void
    private lazy var expiry = ResultExpiry(after: resultTimer, clear: { [weak self] in self?.setResult("", failure: false) })

    /// `backgroundService`: the background listing's service (nil: `service`). `notifyEnabled`, `autoUnblockEnabled`
    /// and `alert`: whether to check for new messages or unblock incoming ones in the background, and how (the tests'
    /// defaults: never).
    init(service: SmsServing,
         queue: DispatchQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.sms", qos: .userInitiated),
         replyToQuit: @escaping (Bool) -> Void,
         requestAttention: @escaping () -> Void,
         backgroundService: SmsServing? = nil,
         notifyEnabled: @escaping () -> Bool = { false },
         autoUnblockEnabled: @escaping () -> Bool = { false },
         hasRescued: @escaping () -> Bool = { false },
         unblockWindow: TimeInterval = SmsController.defaultUnblockWindow,
         slicePause: TimeInterval = SmsController.defaultSlicePause,
         now: @escaping () -> Date = { Date() },
         alert: @escaping (MessageAlert) -> Void = { _ in },
         resultTimer: @escaping (TimeInterval, @escaping () -> Void) -> Void = mainRunLoopAfter) {
        self.resultTimer = resultTimer
        self.service = service
        self.queue = queue
        self.replyToQuit = replyToQuit
        self.requestAttention = requestAttention
        self.backgroundService = backgroundService ?? service
        self.notifyEnabled = notifyEnabled
        self.autoUnblockEnabled = autoUnblockEnabled
        self.hasRescued = hasRescued
        self.unblockWindow = unblockWindow
        self.unblockSlicePause = slicePause
        self.now = now
        self.alert = alert
    }

    deinit {
        timer?.invalidate()
        unblockTimer?.invalidate()
    }

    var listed: Bool { listedAt != nil }
    var sendEnabled: Bool { running == nil && !stopping && !composing && canSend(number: to, text: text) }
    /// The messages as conversations, the latest first (SmsConversations.swift).
    var conversations: [SmsConversation] {
        RMNetConversations.build(messages, unread: unread, sentAt: sentAt, home: homeCallingCode(imsi: listedPlace.sim))
    }
    var shownConversation: SmsConversation? {
        guard let key = selectedConversation else { return nil }
        return conversations.first { $0.id == key }
    }
    /// The reply can go: a conversation with a number shown, a text, nothing running.
    var replyEnabled: Bool {
        guard running == nil, !stopping, !replyComposing, let number = shownConversation?.number else { return false }
        return canSend(number: number, text: replyText)
    }
    var replyNote: String { composeNote(replyText, composing: replyComposing) }
    var changeEnabled: Bool { running == nil && !stopping }
    var refreshEnabled: Bool { running == nil && !stopping }
    /// The list's own line: when it was listed and how full the store is, or why the last listing failed.
    var listText: String { listLine(updated: listedAt, failure: listFailure, used: storeUsed, total: storeTotal) }
    /// The line under the message being written.
    var composeText: String { composeNote(text, composing: composing) }

    // MARK: When the modem is asked

    /// The Messages screen is the one shown (true) or not (false, also when the window closes).
    func setTabShown(_ shown: Bool) {
        tabShown = shown
        updateTimer()
    }

    /// The window can be seen (true) or is minimized, hidden or covered (false).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateTimer()
    }

    /// While the delete confirmation is open the 15 s refresh skips its turns.
    func setConfirmingDelete(_ open: Bool) {
        confirmingDelete = open
    }

    private var active: Bool { tabShown && windowVisible && !stopping }

    // Lists at once when the screen becomes active, then every 15 s; stops when it is not.
    private func updateTimer() {
        if active {
            guard timer == nil else { return }
            let t = Timer(timeInterval: SmsController.refreshInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// One turn of the 15 s refresh.
    func tick() {
        guard !confirmingDelete else { return }
        refresh()
    }

    // MARK: Quitting

    /// Asked when the app is about to end. With no call running it returns false and the app may end now.
    /// Otherwise nothing new starts, it returns true, and once the running call has finished `replyToQuit`
    /// is called once (a send is never cut short): with true after a listing or a send or delete that
    /// succeeded; with false (the quit is cancelled, and the app asks for attention) after a send or
    /// delete that did not, so that the owner sees its result line.
    func quitWhenFinished() -> Bool {
        stopping = true
        pendingAutoUnblock = false
        pendingHeal = false
        unblockTimer?.invalidate()
        unblockTimer = nil
        updateTimer()
        if running == .unblocking && !sliceInFlight {
            if !unblockStreaming {
                running = nil
                unblockDeadline = nil
                return false
            }
            quitWaits = true
            quitNotice.line = quitWaitLine(.unblocking)
            unblockFinishing = true
            runNextUnblockSlice(start: false, finish: true)
            return true
        }
        guard let now = running else { return false }
        quitWaits = true
        quitNotice.line = quitWaitLine(now)
        return true
    }

    /// The quit was cancelled elsewhere (the modem screens' call failed): working again, the screen listed at once
    /// if it is shown. A quit of this controller that still waited is cancelled too and never answered.
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
        updateTimer()  // the app goes on: the screen lists again if it is shown
        return true
    }

    // MARK: The three calls

    /// Lists the messages, unless a call is already running (a timer tick then skips its turn).
    func refresh() {
        guard running == nil, !stopping else { return }
        running = .listing
        let service = self.service
        queue.async {
            let result = service.list()
            DispatchQueue.main.async { self.finishListing(result) }
        }
    }

    private func finishListing(_ outcome: Result<SmsListing, SmsFailure>) {
        running = nil
        switch outcome {
        case .success(let listing):
            apply(listing)
        case .failure(let failure):
            listFailure = failure.message
        }
        if answeredQuit(succeeded: true) { return }
        runPendingIfIdle()
    }

    /// A listing that succeeded: the messages (settled: what RMNet knows of its own sends), the store, the unread marks,
    /// the parts and their place for a later delete or Retry. The listing made every unread message read on the modem
    /// and shows it, so the background count starts again from none unread.
    private func apply(_ listing: SmsListing) {
        listedParts = listing.parts
        listedPlace = listing.place
        let stored = Set(listing.parts.map(StoredPart.init))
        let unsent = Set(listing.parts.filter { $0.status == .unsent }.map(StoredPart.init))
        sentTimes = sentTimes.filter { stored.contains($0.key) }
        confirmedParts.formIntersection(unsent)
        unknownParts.formIntersection(unsent)
        var times: [Int: Date] = [:]
        for p in listing.parts { if let t = sentTimes[StoredPart(p)] { times[p.index] = t } }
        if times != sentAt { sentAt = times }
        // Confirmed sent: in this run (in memory) or by the record of sent messages (any run, the window's or a verb's).
        let confirmed = listing.sentConfirmed.union(
            listing.parts.filter { confirmedParts.contains(StoredPart($0)) }.map { $0.index })
        let unknown = Set(listing.parts.filter { unknownParts.contains(StoredPart($0)) }.map { $0.index })
            .union(listing.sendUnknown).subtracting(confirmed)
        if unknown != unconfirmed { unconfirmed = unknown }
        let found = settled(listing.messages, confirmedIndices: confirmed)
        messages = found
        listedAt = Date()
        listFailure = nil
        storeUsed = listing.used
        storeTotal = listing.total
        unread = unreadMarks(listed: found, kept: unread)
        if active { markShownConversationRead() }
        watch.listedByWindow(used: listing.used,
                             received: listing.parts.filter { $0.status == .unread || $0.status == .read }.count)
        if unreadNotice.onModem != 0 { unreadNotice.onModem = 0 }
    }

    /// The alert as a notification, while Notify about new messages is on (also when it was turned off while the count
    /// ran: then nothing); new messages not while the Messages screen is shown and seen (it lists them there).
    private func announce(_ a: MessageAlert) {
        guard notifyEnabled() else { return }
        if case .arrived = a, active { return }
        alert(a)
    }

    // MARK: New messages and automatic unblocking in the background

    /// Told when a modem comes onto USB (so its first background turn checks `AT+CNMI?`) or leaves it.
    func modemPresent(_ present: Bool) {
        if present {
            checkCnmiOnce = true
        } else {
            checkCnmiOnce = false
            incomingBlocked = false
            pendingAutoUnblock = false
            pendingHeal = false
        }
    }

    /// Told when Settings' "Unblock incoming messages automatically" changes: turning it on while a blocked queue is
    /// waiting starts the unblock at once.
    func autoUnblockSettingChanged(_ enabled: Bool) {
        if enabled, incomingBlocked {
            incomingBlocked = false
            startUnblock(manual: false, healOnly: false)
        }
    }

    /// Told when any `AtPort` read (in this app, or in a command-line `RMNet` verb via `blockedSmsNotification`) saw a
    /// storage-less `+CMTI:` (`+CMTI: ,3` or `+CMTI: ,-1`) or rescued an unsolicited `+CMT` PDU.
    func blockedSmsSeen() {
        guard !stopping else { return }
        if hasRescued() {
            startUnblock(manual: false, healOnly: !autoUnblockEnabled())
            return
        }
        if autoUnblockEnabled() {
            incomingBlocked = false
            startUnblock(manual: false, healOnly: false)
        } else if running != .unblocking {
            incomingBlocked = true
        }
    }

    /// The window's `Unblock` action (toolbar or notice): streams queued incoming messages and stores them as unread.
    func unblock() {
        guard running == nil, !stopping else { return }
        incomingBlocked = false
        startUnblock(manual: true, healOnly: false)
    }

    private func startUnblock(manual: Bool, healOnly: Bool) {
        guard !stopping else { return }
        guard running == nil else {
            if !manual {
                if healOnly { pendingHeal = true } else { pendingAutoUnblock = true }
            }
            return
        }
        running = .unblocking
        unblockManual = manual
        unblockHealOnly = healOnly
        unblockDeadline = healOnly ? nil : now().addingTimeInterval(unblockWindow)
        unblockParts = []
        unblockRestoredCnmi = false
        unblockStreaming = false
        unblockFinishing = false
        if manual {
            setResult("Unblocking incoming messages (waiting for the carrier, up to \(Int(unblockWindow)) s)…", failure: false, kind: .progress)
        } else if !healOnly {
            setResult("Unblocking incoming messages…", failure: false, kind: .progress)
        }
        runNextUnblockSlice(start: true, finish: false)
    }

    private func runNextUnblockSlice(start: Bool, finish: Bool) {
        sliceInFlight = true
        let service = self.service
        let healOnly = self.unblockHealOnly
        queue.async {
            let result = healOnly ? service.healCnmi() : service.unblockSlice(start: start, finish: finish)
            DispatchQueue.main.async { self.finishUnblockSlice(result, started: start && !healOnly, finished: finish || healOnly) }
        }
    }

    private func finishUnblockSlice(_ outcome: Result<SmsUnblockSlice, SmsFailure>, started: Bool, finished: Bool) {
        sliceInFlight = false
        switch outcome {
        case .failure(let failure):
            unblockTimer?.invalidate()
            unblockTimer = nil
            if unblockStreaming && !finished {
                unblockStreaming = false
                unblockFinishing = true
                let savedFailure = failure.message
                let service = self.service
                sliceInFlight = true
                queue.async {
                    _ = service.unblockSlice(start: false, finish: true)
                    DispatchQueue.main.async {
                        self.sliceInFlight = false
                        self.unblockFinishing = false
                        self.completeUnblockFailure(savedFailure)
                    }
                }
                return
            }
            unblockStreaming = false
            unblockFinishing = false
            completeUnblockFailure(failure.message)
        case .success(let slice):
            unblockParts.append(contentsOf: slice.parts)
            if slice.restoredCnmi { unblockRestoredCnmi = true }
            if started { unblockStreaming = true }
            if finished { unblockStreaming = false; unblockFinishing = false }

            let settled = !unblockParts.isEmpty && slice.parts.isEmpty
            let expired = unblockDeadline.map { now() >= $0 } ?? true
            if unblockHealOnly || finished || stopping || settled || expired {
                unblockTimer?.invalidate()
                unblockTimer = nil
                if unblockStreaming {
                    unblockFinishing = true
                    runNextUnblockSlice(start: false, finish: true)
                    return
                }
                running = nil
                let manual = unblockManual
                unblockDeadline = nil
                let summary = assembleUnblocked(unblockParts, restoredCnmi: unblockRestoredCnmi)
                if manual || summary.stored > 0 || summary.restoredCnmi {
                    setResult(smsUnblockSentence(summary), failure: false)
                    if summary.stored > 0 { clearResultOnTyping = true }
                } else if result == "Unblocking incoming messages…" {
                    setResult("", failure: false)
                }
                if answeredQuit(succeeded: true) { return }
                if active {
                    refresh()
                } else if summary.stored > 0 && notifyEnabled() {
                    countInBackground()
                } else {
                    runPendingIfIdle()
                }
                return
            }
            let t = Timer(timeInterval: unblockSlicePause, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.unblockTimer = nil
                guard self.running == .unblocking, !self.stopping else { return }
                self.runNextUnblockSlice(start: false, finish: false)
            }
            RunLoop.main.add(t, forMode: .common)
            unblockTimer = t
        }
    }

    private func completeUnblockFailure(_ message: String) {
        running = nil
        let manual = unblockManual
        let hadParts = !unblockParts.isEmpty
        unblockDeadline = nil
        if manual || hadParts {
            setResult(message, failure: true)
        } else if result == "Unblocking incoming messages…" {
            setResult("", failure: false)
        }
        if answeredQuit(succeeded: !manual) { return }
        if hadParts {
            if active { refresh() } else if notifyEnabled() { countInBackground() }
        } else {
            runPendingIfIdle()
        }
    }

    private func runPendingIfIdle() {
        guard running == nil, !stopping else { return }
        if pendingAutoUnblock {
            pendingAutoUnblock = false
            pendingHeal = false
            startUnblock(manual: false, healOnly: false)
        } else if pendingHeal {
            pendingHeal = false
            startUnblock(manual: false, healOnly: true)
        }
    }

    /// The background turn's part (ModemPulse.swift): every other turn (about every 30 s, from the first), while
    /// nothing runs, the app does not quit, and the Messages screen does not list by itself (shown and seen: it lists
    /// every 15 s). Reads `AT+CPMS?` while Notify about new messages is on, and `AT+CNMI?` while automatic unblocking
    /// is on (or once after a modem attaches, to heal any `AT+CNMI` left at `2,2` by an earlier crash).
    func pulseCommands(turn: Int) -> [String] {
        let notify = notifyEnabled()
        if !notify {
            if watch != NewMessageWatch() { watch = NewMessageWatch() }
            if unreadNotice.onModem != 0 { unreadNotice.onModem = 0 }
        }
        let checkCnmi = autoUnblockEnabled() || checkCnmiOnce || hasRescued()
        guard notify || checkCnmi else { return [] }
        guard !stopping, running == nil, !active, turn % 2 == 1 else { return [] }
        var commands: [String] = []
        if notify { commands.append("AT+CPMS?") }
        if checkCnmi { commands.append("AT+CNMI?") }
        return commands
    }

    /// The store's count and `AT+CNMI?` read (or why the port could not be used: the turn is skipped): an `AT+CNMI?`
    /// not at `2,1` (or rescued `+CMT` PDUs) heals `AT+CNMI` and stores any pending deliveries; otherwise the count
    /// checks unread messages when needed (countInBackground).
    func pulseAnswers(_ answers: Result<[String: PulseAnswer], ModemFailure>) {
        guard case .success(let a) = answers else { return }
        if let cnmi = a["AT+CNMI?"] {
            checkCnmiOnce = false
            if let parsed = parseCnmi(cnmi.lines), parsed != (2, 1) {
                startUnblock(manual: false, healOnly: !autoUnblockEnabled())
                return
            }
        }
        if hasRescued() {
            startUnblock(manual: false, healOnly: !autoUnblockEnabled())
            return
        }
        guard notifyEnabled(), let store = a["AT+CPMS?"] else { return }
        if watch.storeCount(parseStorage(store.lines)?.used) { countInBackground() }
    }

    /// The count (SmsServing.countUnread, which lists and reads no unread message), with the background service: a busy
    /// port fails at once, and a count that fails is tried again on a later turn.
    private func countInBackground() {
        guard running == nil, !stopping else { return }
        running = .counting
        let service = self.backgroundService
        queue.async {
            let result = service.countUnread()
            DispatchQueue.main.async { self.finishCount(result) }
        }
    }

    private func finishCount(_ outcome: Result<SmsStoreCount, SmsFailure>) {
        running = nil
        if case .success(let count) = outcome, notifyEnabled() {
            let alert = watch.counted(count)
            if unreadNotice.onModem != count.unread { unreadNotice.onModem = count.unread }
            if let alert { announce(alert) }
        }
        if answeredQuit(succeeded: true) { return }
        runPendingIfIdle()
    }

    /// The stored parts of `messages` exactly as the last listing has them, and where they were listed from: what a delete
    /// confirmed now will delete, whatever later listings bring (SmsTarget). nil when a message is not in the last
    /// listing as it is (it changed, or went), or a part of it is missing.
    func target(for messages: [SmsMessage]) -> SmsTarget? {
        guard !messages.isEmpty, messages.allSatisfy({ self.messages.contains($0) }) else { return nil }
        let indices = Set(messages.flatMap { $0.indices })
        let parts = listedParts.filter { indices.contains($0.index) }
        guard Set(parts.map { $0.index }) == indices else { return nil }
        return SmsTarget(parts: parts, place: listedPlace)
    }

    func target(for conversation: SmsConversation) -> SmsTarget? { target(for: conversation.messages) }

    /// Deletes every stored part of `message`, if it is still listed and nothing else runs.
    func delete(_ message: SmsMessage) {
        delete(target(for: [message]))
    }

    /// Deletes what a confirmation was opened for (`target`, frozen when it opened: target(for:)), checked against the
    /// modem first: never a part a later listing has at the same index. nil: it was no longer listed when it opened.
    func delete(_ target: SmsTarget?, then done: (() -> Void)? = nil) {
        guard !stopping else { return }
        // A refresh may have started just before the confirmation closed.
        guard running == nil else {
            setResult("The modem was busy with another request. Nothing was deleted; press Delete again.", failure: true)
            return
        }
        guard let target else {
            setResult("That message is no longer listed. Nothing was deleted.", failure: true)
            return
        }
        running = .deleting
        setResult("Deleting \(target.parts.count) stored part(s)…", failure: false, kind: .progress)
        let service = self.service
        let parts = target.parts
        let place = target.place
        queue.async {
            let result = service.delete(parts, listedFrom: place)
            DispatchQueue.main.async {
                if case .success = result { done?() }
                self.finishDelete(result)
            }
        }
    }

    private func finishDelete(_ outcome: Result<Int, SmsFailure>) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let count):
            setResult("Deleted \(count) stored part(s).", failure: false)
            clearResultOnTyping = true
            succeeded = true
        case .failure(let failure):
            setResult(failure.message, failure: true)
            succeeded = false
        }
        if answeredQuit(succeeded: succeeded) { return }
        if active { refresh() } else { runPendingIfIdle() }
    }

    /// Sends the reply to the conversation shown, as `send` does, once; on success that conversation's reply is cleared.
    func sendReply() {
        guard replyEnabled, let c = shownConversation else { return }
        startSend(to: c.number, body: replyText, reply: c.id)
    }

    /// Sends the stored parts of `message` that are not sent (Retry), once, after checking that the modem still has
    /// them as listed (SmsService.resend): `message` as shown, which must be in the last listing as it is; its parts as
    /// that listing has them, never what a later listing has at the same indices. A part RMNet confirmed sent is never
    /// among them.
    func retry(_ message: SmsMessage) {
        guard running == nil, !stopping, !message.unsentIndices.isEmpty else { return }
        let parts = listedParts.filter { message.unsentIndices.contains($0.index) && $0.status == .unsent }
        guard messages.contains(message), parts.count == message.unsentIndices.count else {
            setResult("That message is no longer listed. Nothing was sent.", failure: true)
            return
        }
        running = .sending
        setResult("Sending \(parts.count) stored part(s) to \(message.sender) again…", failure: false, kind: .progress)
        let service = self.service
        let place = listedPlace
        queue.async {
            let result = service.resend(parts, listedFrom: place)
            DispatchQueue.main.async { self.finishSend(result, number: message.sender, reply: nil) }
        }
    }

    /// Deletes every stored part of every message of `conversation`, checked against the modem first; `target`: what
    /// its confirmation was opened for (nil: the conversation as the last listing has it now).
    func deleteConversation(_ conversation: SmsConversation, target given: SmsTarget?? = nil) {
        guard !conversation.messages.isEmpty else { return }
        let target = given ?? target(for: conversation)
        delete(target) { [weak self] in
            guard let self else { return }
            if self.selectedConversation == conversation.id { self.selectedConversation = nil }
            self.replyDrafts[conversation.id] = nil
        }
    }

    private func markShownConversationRead() {
        guard let c = shownConversation else { return }
        for m in c.messages { unread.remove(m.key) }
    }

    /// Sends the New Message sheet's text to its number once; never retried.
    func send() {
        guard sendEnabled else { return }
        startSend(to: to, body: text, reply: nil, sheet: true)
    }

    /// `reply`: the conversation whose reply this is; nil with `sheet` for the New Message sheet (whose conversation is
    /// then shown), nil without for a Retry.
    private func startSend(to number: String, body: String, reply: String?, sheet: Bool = false) {
        let parts = partCount(body)
        running = .sending
        setResult("Sending \(parts) part(s) to \(number). This can take up to two minutes per part.", failure: false,
                  kind: .progress)
        let service = self.service
        queue.async {
            let result = service.send(to: number, text: body)
            DispatchQueue.main.async { self.finishSend(result, number: number, reply: reply, sheet: sheet) }
        }
    }

    /// What became of the parts (SmsSendRecord) is kept, a success's or a failure's: when each sent part went, which
    /// are sent though listed unsent, which are not known.
    private func keep(_ record: SmsSendRecord) {
        let now = Date()
        for p in record.sent { sentTimes[p] = now }
        confirmedParts.formUnion(record.stillUnsent)
        unknownParts.subtract(record.sent)
        unknownParts.subtract(record.stillUnsent)
        unknownParts.formUnion(record.unknown)
        // Until the next listing, the parts RMNet knows of go on the list it has.
        var times = sentAt
        for p in record.sent { times[p.index] = now }
        if times != sentAt { sentAt = times }
        let unknown = unconfirmed.subtracting((record.sent + record.stillUnsent).map { $0.index })
            .union(record.unknown.map { $0.index })
        if unknown != unconfirmed { unconfirmed = unknown }
    }

    private func finishSend(_ outcome: Result<SmsSent, SmsFailure>, number: String, reply: String?, sheet: Bool = false) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let sent):
            keep(sent.record)
            if let reply {
                replyDrafts[reply] = nil
            } else if sheet {
                text = ""
                selectedConversation = conversationKey(number, home: homeCallingCode(imsi: listedPlace.sim))
            }
            // Sent, and apart from it, what is kept on the modem and in the record of sent messages (a warning).
            let notes = smsArchiveNotes(sent.record)
            setResult((["Sent to \(number) in \(sent.parts) part(s)."]
                       + (sent.stored ? [] : ["It is not stored on the modem: it writes messages to another storage than "
                                              + "the one it lists."]) + notes).joined(separator: " "),
                      failure: false, kind: sent.stored && notes.isEmpty ? .success : .warning)
            clearResultOnTyping = sheet
            succeeded = true
        case .failure(let failure):
            keep(failure.record)
            var line = ([failure.message] + smsArchiveNotes(failure.record)).joined(separator: " ")
            // A part went, may have, or is stored for Retry: the whole text is not offered again.
            if failure.reachedModem {
                if let reply { replyDrafts[reply] = nil } else if sheet { text = "" }
                if reply != nil || sheet { line += " The text was cleared so that no part is sent twice." }
            }
            setResult(line, failure: true)
            succeeded = false
        }
        if answeredQuit(succeeded: succeeded) { return }
        if active { refresh() } else { runPendingIfIdle() }
    }

    /// The banner's X: the line is cleared, so it does not come back on another screen or a new window.
    func dismissResult() {
        setResult("", failure: false)
    }

    /// The pointer on the banner (true) or off it: a success does not go while it is on it.
    func hoverResult(_ on: Bool) {
        expiry.hover(on)
    }

    /// `kind`: progress for a request's words while it runs, warning for a success with something to read; a failure
    /// is one, anything else a success.
    private func setResult(_ line: String, failure: Bool, kind: ResultKind = .success) {
        result = line
        resultIsFailure = failure
        resultKind = failure ? .failure : kind
        if !line.isEmpty { clearResultOnTyping = false }
        expiry.shown(line, resultKind)
    }
}

private func quitWaitLine(_ activity: SmsActivity) -> String {
    switch activity {
    case .sending: return "RMNet quits when the message being sent has finished."
    case .deleting: return "RMNet quits when the message being deleted has finished."
    case .listing, .counting, .unblocking: return "RMNet quits when the current request to the modem has finished."
    }
}
