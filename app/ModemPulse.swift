// The app's background turn over the modem's spare AT port, every 15 s while RMNet runs, window open or not: the menu
// bar's signal bars (MenuBarStatus.pulseSignalCommands), the check for new text messages (SmsController.pulseCommands,
// every other turn) and the SIM slot watcher (SimSlotWatcher.pulseCommands, only while it watches) each say which short
// commands they want this turn. It is the app's only scheduler of background port reads: none of them has a timer of
// its own. The commands go in one port open, on the queue the window's screens share (so the app never opens the port
// twice at once), on a port that does not wait for another program: while `RMNet` in a terminal holds the port the turn
// is skipped, for all of them (each gets the failure, and keeps what it had), and nobody waits. Each gets the answers to
// its own commands, keyed by command: a key that is there was answered (its lines, or the modem's error line); a key
// that is not was not read this turn (a timeout or an I/O error on an earlier command ended the turn there, and the
// answers before it are still given). A turn with nothing wanted opens nothing; nothing listens on the port between
// turns. Foundation only, so `make app-test` tests it (tests/app/ModemPulseTests.swift).
import Foundation

final class ModemPulse {
    /// One of the turn's users: the commands it wants this turn (by the turn's number, from 1), and what to do with
    /// their answers, keyed by command, only those answered (or why the port could not be used). Both on the main
    /// thread.
    struct Rider {
        let commands: (_ turn: Int) -> [String]
        let deliver: (Result<[String: PulseAnswer], ModemFailure>) -> Void
    }

    static let interval: TimeInterval = 15
    static let tolerance: TimeInterval = 3

    private var riders: [Rider] = []
    private var timer: Timer?
    private var running = false
    private(set) var turns = 0
    private let queue: DispatchQueue
    private let read: ([String]) -> Result<[PulseAnswer], ModemFailure>

    /// `read`: the short reads on a port opened without waiting (ModemService.shortReads); it blocks, on `queue`. Its
    /// answers are in the order of the commands, and may stop short of them (the rest were not read).
    init(queue: DispatchQueue, read: @escaping ([String]) -> Result<[PulseAnswer], ModemFailure>) {
        self.queue = queue
        self.read = read
    }

    deinit { timer?.invalidate() }

    func add(_ rider: Rider) {
        riders.append(rider)
    }

    /// A turn now, then every 15 s (up to 3 s late), in the main run loop's common modes.
    func start() {
        guard timer == nil else { return }
        turn()
        let t = Timer(timeInterval: ModemPulse.interval, repeats: true) { [weak self] _ in self?.turn() }
        t.tolerance = ModemPulse.tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One turn: skipped while the last one runs; nothing opened when no rider wants anything.
    func turn() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        turns += 1
        let wanted = riders.map { ($0, $0.commands(turns)) }.filter { !$0.1.isEmpty }
        var commands: [String] = []
        for (_, theirs) in wanted {
            for c in theirs where !commands.contains(c) { commands.append(c) }
        }
        guard !commands.isEmpty else { return }
        running = true
        let read = self.read
        queue.async { [weak self] in
            let result = read(commands)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                let keyed = result.map { answers in
                    Dictionary(zip(commands, answers), uniquingKeysWith: { first, _ in first })
                }
                for (rider, theirs) in wanted {
                    rider.deliver(keyed.map { all in all.filter { theirs.contains($0.key) } })
                }
            }
        }
    }
}
