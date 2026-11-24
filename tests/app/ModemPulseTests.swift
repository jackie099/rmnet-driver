// Tests for app/ModemPulse.swift as the app wires it: the one background turn every rider shares, over the real
// ModemService.shortReads behind a scripted port, with the real menu bar model (MenuBarStatus, the signal bars) as one
// rider and two recording riders standing in for the check for new messages (AT+CPMS?, every other turn) and the SIM
// slot watcher (AT+CPIN?, AT+CFUN?, AT+QUIMSLOT?), in the order StatusView.swift adds them. The cases: every rider
// answered from one port open, a shared command sent once; a port another program holds (busy: the turn skipped for
// all, the bars kept and marked stale); a timeout part way (the answers before it given, the commands after it absent,
// nothing more sent); a timeout on the first command (the turn fails for all). Built with swiftc by `make app-test`; no
// port is opened. Stops at the first failure, prints which check failed and exits 1.
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

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// A port that answers each command from the turn's script (a command not in it is refused with "ERROR"), records the
/// lines sent, and closes itself after a timeout or an I/O error, as AtPort does.
final class ScriptedPort: AtCommanding {
    private let script: [String: Result<[String], AtError>]
    private(set) var sent: [String] = []
    private(set) var closed = false

    init(_ script: [String: Result<[String], AtError>]) { self.script = script }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        if closed { return .failure(.io(-536870195)) }  // kIOReturnNotOpen
        sent.append(line)
        let answer = script[line] ?? .failure(.modem("ERROR"))
        switch answer {
        case .failure(.timeout), .failure(.io): closed = true
        default: break
        }
        return answer
    }

    func close() { closed = true }
}

/// What the pulse's reads open: each turn's port, or a failure to open (busy). Used on the pulse's queue only.
final class Ports {
    private let lock = NSLock()
    private var next: [Result<ScriptedPort, AtError>] = []
    private(set) var opened: [ScriptedPort] = []
    private(set) var opens = 0

    func give(_ p: Result<ScriptedPort, AtError>) { lock.lock(); next.append(p); lock.unlock() }

    func open() -> Result<AtCommanding, AtError> {
        lock.lock(); defer { lock.unlock() }
        opens += 1
        guard !next.isEmpty else { return .failure(.modemNotAttached) }
        switch next.removeFirst() {
        case .success(let port):
            opened.append(port)
            return .success(port)
        case .failure(let error):
            return .failure(error)
        }
    }
}

/// A rider that wants fixed commands on some turns and records what it was given.
final class Recorder {
    let commands: (Int) -> [String]
    private(set) var got: [Result<[String: PulseAnswer], ModemFailure>] = []
    init(_ commands: @escaping (Int) -> [String]) { self.commands = commands }
    var rider: ModemPulse.Rider {
        ModemPulse.Rider(commands: { [unowned self] in self.commands($0) }, deliver: { [unowned self] in self.got.append($0) })
    }
}

let serving = "AT+QENG=\"servingcell\""
let saLine = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",001,01,FEDCBA987,32,00F00D,504990,41,12,-86,-10,10,1,-"
let storeLine = "+CPMS: \"ME\",2,255,\"ME\",2,255,\"ME\",2,255"
let upProperties: DriverProperties = ["RMNetState": "up", "RMNetIPv4": "192.0.2.10/29 gw 192.0.2.9"]

@main
struct ModemPulseTests {
    static func main() {
        wiring()
        print("modem pulse: \(checks) checks passed")
    }

    static func wiring() {
        let suite = "io.rmnetdriver.RMNet.tests.pulse.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = DispatchQueue(label: "io.rmnetdriver.RMNet.modem.test")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let bars = MenuBarStatus(properties: { upProperties }, modem: { (.qmi(interface: 4), quectelModels[0]) },
                                 listing: { $0(nil) }, network: { .failure(ModemFailure(message: "not used")) },
                                 now: { clock }, queue: queue, preference: MenuBarIconPreference(defaults: defaults))
        bars.poll()
        bars.setIconStyle(.signal)

        let ports = Ports()
        let service = ModemService(open: { ports.open() })
        let pulse = ModemPulse(queue: queue, read: { service.shortReads($0) })
        let sms = Recorder { $0 % 2 == 1 ? ["AT+CPMS?"] : [] }
        let sim = Recorder { _ in ["AT+CPIN?", "AT+CFUN?", "AT+QUIMSLOT?"] }
        pulse.add(ModemPulse.Rider(commands: { _ in bars.pulseSignalCommands() }, deliver: { bars.pulseSignalAnswers($0) }))
        pulse.add(sms.rider)
        pulse.add(sim.rider)

        // Turn 1: every rider answered from one port open, in the riders' order.
        ports.give(.success(ScriptedPort([serving: .success([saLine]), "AT+CPMS?": .success([storeLine]),
                                          "AT+CPIN?": .success(["+CPIN: READY"]), "AT+CFUN?": .success(["+CFUN: 1"]),
                                          "AT+QUIMSLOT?": .success(["+QUIMSLOT: 1"])])))
        pulse.turn()
        pump(until: { sim.got.count == 1 }, "turn 1")
        equal(ports.opens, 1, "turn 1: one port open")
        equal(ports.opened[0].sent, [serving, "AT+CPMS?", "AT+CPIN?", "AT+CFUN?", "AT+QUIMSLOT?"], "turn 1: the commands, once each")
        check(ports.opened[0].closed, "turn 1: the port closed")
        equal(bars.signal, MenuBarSignal(level: 3, technology: "5G", service: .normal, at: clock), "turn 1: the bars")
        equal(try? sms.got[0].get(), ["AT+CPMS?": .lines([storeLine])], "turn 1: the count to its rider, alone")
        equal(try? sim.got[0].get(), ["AT+CPIN?": .lines(["+CPIN: READY"]), "AT+CFUN?": .lines(["+CFUN: 1"]),
                                      "AT+QUIMSLOT?": .lines(["+QUIMSLOT: 1"])], "turn 1: the SIM's three to its rider")

        // Turn 2: the port is busy (`RMNet` in a terminal has it): skipped for all who wanted something; the bars kept,
        // stale; the count's rider wanted nothing this turn and hears nothing.
        clock = clock.addingTimeInterval(15)
        ports.give(.failure(.busy))
        pulse.turn()
        pump(until: { sim.got.count == 2 }, "turn 2")
        equal(ports.opens, 2, "turn 2: one try to open")
        check(bars.signal?.stale == true && bars.signal?.level == 3, "turn 2: busy keeps the bars, stale")
        equal(sms.got.count, 1, "turn 2: the count's rider wanted nothing, got nothing")
        if case .failure(let f) = sim.got[1] {
            equal(f.message, describe(AtError.busy), "turn 2: the SIM's rider told the port is busy")
        } else { check(false, "turn 2: the SIM's rider gets the failure") }

        // Turn 3: AT+CPIN? times out: the bars and the count answered before it are given (the bars current again), the
        // SIM's rider gets none of its three (absent, not read), and nothing is sent after the timeout.
        clock = clock.addingTimeInterval(15)
        ports.give(.success(ScriptedPort([serving: .success([saLine]), "AT+CPMS?": .success([storeLine]),
                                          "AT+CPIN?": .failure(.timeout), "AT+CFUN?": .success(["+CFUN: 1"])])))
        pulse.turn()
        pump(until: { sim.got.count == 3 }, "turn 3")
        equal(ports.opened[1].sent, [serving, "AT+CPMS?", "AT+CPIN?"], "turn 3: nothing sent after the timeout")
        check(ports.opened[1].closed, "turn 3: the port closed")
        check(bars.signal?.stale == false && bars.signal?.level == 3, "turn 3: the bars answered before it, current")
        equal(try? sms.got[1].get(), ["AT+CPMS?": .lines([storeLine])], "turn 3: the count answered before it")
        equal(try? sim.got[2].get(), [:], "turn 3: the SIM's commands after the timeout, absent")

        // Turn 4: the first command (the bars') times out: the whole turn fails for each rider; the bars kept, stale.
        clock = clock.addingTimeInterval(15)
        ports.give(.success(ScriptedPort([serving: .failure(.timeout)])))
        pulse.turn()
        pump(until: { sim.got.count == 4 }, "turn 4")
        equal(ports.opened[2].sent, [serving], "turn 4: only the first command")
        check(bars.signal?.stale == true && bars.signal?.level == 3, "turn 4: the bars kept, stale")
        if case .failure = sim.got[3] {} else { check(false, "turn 4: a failure for the SIM's rider") }

        // Turn 5: the serving cell searching; turn 6: the bars ask the radio, which the SIM's rider asks too: sent once,
        // given to both.
        clock = clock.addingTimeInterval(15)
        ports.give(.success(ScriptedPort([serving: .success(["+QENG: \"servingcell\",\"SEARCH\""]),
                                          "AT+CPMS?": .success([storeLine]), "AT+CPIN?": .success(["+CPIN: READY"]),
                                          "AT+CFUN?": .success(["+CFUN: 1"]), "AT+QUIMSLOT?": .success(["+QUIMSLOT: 1"])])))
        pulse.turn()
        pump(until: { sim.got.count == 5 }, "turn 5")
        equal(bars.signal?.service, .searching, "turn 5: searching")
        clock = clock.addingTimeInterval(15)
        ports.give(.success(ScriptedPort(["AT+CFUN?": .success(["+CFUN: 4"]), "AT+CPIN?": .success(["+CPIN: READY"]),
                                          "AT+QUIMSLOT?": .success(["+QUIMSLOT: 1"])])))
        pulse.turn()
        pump(until: { sim.got.count == 6 }, "turn 6")
        equal(ports.opened[4].sent, ["AT+CFUN?", "AT+CPIN?", "AT+QUIMSLOT?"], "turn 6: the shared command sent once")
        check(bars.signalIcon.airplane, "turn 6: the bars read the radio")
        equal((try? sim.got[5].get())?["AT+CFUN?"], .lines(["+CFUN: 4"]), "turn 6: the SIM's rider gets it too")
        equal(pulse.turns, 6, "turns counted")
    }
}
