// RMNet host app: installs, removes and reports on the RMNet driver extension, reads and sends the
// modem's text messages, and shows and changes the modem's network and settings.
// Usage: RMNet activate | deactivate | status [--json]
//        RMNet sms list [--json] | sms send <number> <text> | sms delete <index>... | sms unblock [seconds] [--json]
//        RMNet gps [seconds] [--keep-on]
//        RMNet network [--json] | antennas [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…]
//        RMNet apn [show] [--json] | apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>]
//                  [--password | --no-password] [--auth none|pap|chap|pap-or-chap] [--no-redial]
//        RMNet sim [--json] | sim unlock [--last-attempt] | sim slot [--json] | sim slot set 1|2 [--yes]
//        RMNet usbmode [--json] | usbmode set qmi|ecm|mbim|rndis [--no-reboot] [--yes]
//        RMNet at [--timeout <seconds>] <command>
//        RMNet bands [--json] | bands set lte|nsa|sa <bands> | bands reset [lte|nsa|sa]
//        RMNet cell [--json] | cell lock sa <pci> <arfcn> <scs> <band> | cell lock current [--scs <kHz>]
//        RMNet cell lock lte <earfcn>:<pci>[,…] | cell unlock [sa|lte] | cell persist on|off
//        RMNet imei [--json] | imei set <imei> [--no-reboot] [--yes] | imei history [--json]
//        RMNet (no argument, or opened from the Finder): the status window.
// It must run from /Applications/RMNet.app for activate and deactivate (scripts/install-driver.sh).
// With a verb it opens no window and exits by itself. `status --json` (scripts/soak.sh reads it) keeps
// its form; the `modem:` line of plain `status` names the model found, and no script reads it.
import Foundation

// MARK: - Command-line output

func printModem(_ modem: ModemState, _ model: QuectelModel?) {
    print(modemLine(modem, model: model))
}

func printDriverEntry(_ driver: [String: String]?) {
    guard let props = driver else {
        print("driver: no \(driverClass) registry entry (not attached)")
        return
    }
    print("driver: \(driverClass) attached")
    for key in props.keys.sorted() {
        print("  \(key) = \(props[key]!)")
    }
}

func printRegistry() {
    let (modem, model) = readModemModel()
    printModem(modem, model)
    printDriverEntry(readDriverProperties())
}

// With `error` (the system gave no listing) the headline is "Unknown" and "error" says why.
func printJSON(_ entries: [ExtensionEntry], error: String? = nil) {
    let object = statusJSON(readStatus(entries: entries), bundledVersion: bundledDriverVersion() ?? "",
                            listingError: error)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func outcomeWords(_ outcome: RequestOutcome) -> String {
    switch outcome {
    case .completed: return "completed"
    case .willCompleteAfterReboot: return "completes after a reboot"
    case .other(let raw): return "result \(raw)"
    case .failed(let error): return describe(error)
    }
}

// MARK: - Verbs

enum Command: String { case activate, deactivate, status }

func runActivate(_ manager: ExtensionManager) {
    manager.activate(
        replacing: { old, new in print("replacing version \(old) with \(new)") },
        needsApproval: { print("waiting for approval in System Settings") },
        completion: { finished(.activate, $0) })
}

func runDeactivate(_ manager: ExtensionManager) {
    manager.deactivate(needsApproval: { print("waiting for approval in System Settings") },
                       completion: { finished(.deactivate, $0) })
}

func finished(_ command: Command, _ outcome: RequestOutcome) {
    switch outcome {
    case .completed: print("\(command.rawValue): done")
    case .willCompleteAfterReboot: print("\(command.rawValue): done after a reboot")
    case .other(let raw): print("\(command.rawValue): finished with result \(raw)")
    case .failed(let error):
        print("\(command.rawValue) failed: \(error.localizedDescription) (code \((error as NSError).code))")
        exit(1)
    }
    exit(0)
}

func runStatus(_ manager: ExtensionManager, json: Bool) {
    manager.properties { result in
        switch result {
        case .listed(let found):
            if json {
                printJSON(found.map(ExtensionEntry.init))
                exit(0)
            }
            if found.isEmpty {
                print("driver extension: not installed")
            }
            for p in found {
                var flags = [p.isEnabled ? "enabled" : "not enabled"]
                if p.isAwaitingUserApproval { flags.append("awaiting approval") }
                if p.isUninstalling { flags.append("uninstalling") }
                print("driver extension: \(p.bundleIdentifier) version \(p.bundleVersion) (\(p.bundleShortVersion)), "
                      + flags.joined(separator: ", "))
            }
            printRegistry()
            exit(0)
        case .notListed(.failed(let error)):
            let code = (error as NSError).code
            if json {
                printJSON([], error: "\(error.localizedDescription) (code \(code))")
            } else {
                print("driver extension: unknown (\(error.localizedDescription), code \(code))")
                printRegistry()
            }
            exit(1)
        case .notListed(let outcome):
            // Finished without a listing. The plain verb prints what it printed before the window.
            if json {
                printJSON([], error: "the system finished without listing the driver (\(outcomeWords(outcome)))")
                exit(1)
            }
            switch outcome {
            case .willCompleteAfterReboot: print("status: done after a reboot")
            case .other(let raw): print("status: finished with result \(raw)")
            default: print("status: done")
            }
            printRegistry()
            exit(0)
        case .noAnswer:
            break  // no timeout is passed here; the one below answers
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        if json {
            printJSON([], error: "no answer from the system in 10 s")
        } else {
            print("driver extension: unknown (no answer from the system in 10 s)")
            printRegistry()
        }
        exit(1)
    }
}

// MARK: - Text messages
// The sms verbs take no part in the system-extension machinery: they talk to the modem's spare AT
// port off the main thread, print, and exit. Message text and numbers go only to standard output.

let localTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func localTime(_ date: Date) -> String { localTimeFormatter.string(from: date) }

func printMessages(_ listing: SmsListing) {
    for line in smsListLines(listing, time: localTime) { print(line) }
}

func printMessagesJSON(_ listing: SmsListing) {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    let array = smsListJSON(listing, time: { iso.string(from: $0) })
    if array.isEmpty {
        print("[]")
        return
    }
    let data = try! JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func printUnblockedJSON(_ result: SmsUnblocked) {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    let object = smsUnblockJSON(result, time: { iso.string(from: $0) })
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// Runs on a background queue; returns the exit code. Sender and text are printed as they are: the model
// made them display-safe in decodePart, and nothing else from the modem is printed.
func runSms(_ command: SmsCommand, service: SmsServing) -> Int32 {
    switch command {
    case .list(let json):
        switch service.list() {
        case .success(let listing):
            if json { printMessagesJSON(listing) } else { printMessages(listing) }
            return 0
        case .failure(let failure):
            print("sms: \(failure.message)")
            return 1
        }
    case .send(let number, let text):
        // From before the port opens until the result is printed, Ctrl-C, Ctrl-Z, Ctrl-\, a hang-up or a
        // plain kill do not stop the verb in the middle of a part (at the modem's "> " prompt) or of a
        // multi-part send.
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGQUIT] { signal(sig, SIG_IGN) }
        switch service.send(to: number, text: text) {
        case .success(let sent):
            print("sms: sent to \(number) in \(sent.parts) part(s)")
            if !sent.stored {
                print("sms: not stored: the modem writes messages to another storage than the one it lists (AT+CPMS)")
            }
            // Sent, and what is kept of it on the modem and in the record of sent messages, apart.
            for note in smsArchiveNotes(sent.record) { print("sms: \(note)") }
            return 0
        case .failure(let failure):
            print("sms: \(failure.message)")
            for note in smsArchiveNotes(failure.record) { print("sms: \(note)") }
            if failure.reachedModem {
                print("sms: do not send the whole text again: parts of it went, may have gone, or are stored on the "
                      + "modem as unsent (the window's Retry sends only those)")
            }
            return 1
        }
    case .delete(let indices):
        switch service.delete(indices: indices) {
        case .success(let count):
            print("sms: deleted \(count) stored part(s)")
            return 0
        case .failure(let failure):
            print("sms: \(failure.message)")
            return 1
        }
    case .unblock(let seconds, let json):
        // Ctrl-C, SIGTERM and SIGHUP let the current 1 s slice finish (restoring AT+CNMI=2,1,0,0,0 and storing any
        // PDU already received), then end the verb by that signal; SIGTSTP is ignored so Ctrl-Z cannot suspend the
        // process while AT+CNMI is 2,2.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
        let stopLock = NSLock()
        var stopSignal: Int32? = nil
        let watch = SignalWatch([SIGINT, SIGTERM, SIGHUP, SIGQUIT]) { sig in
            stopLock.lock()
            if stopSignal == nil { stopSignal = sig }
            stopLock.unlock()
        }
        defer { watch.stop() }
        let outcome = service.unblock(seconds: seconds, shouldStop: {
            stopLock.lock()
            defer { stopLock.unlock() }
            return stopSignal != nil
        })
        stopLock.lock()
        let caught = stopSignal
        stopLock.unlock()
        switch outcome {
        case .success(let unblocked):
            if json {
                printUnblockedJSON(unblocked)
            } else {
                for line in smsUnblockLines(unblocked, seconds: seconds, time: localTime) { print(line) }
            }
            if let sig = caught { dieBySignal(sig) }
            return 0
        case .failure(let failure):
            print("sms: \(failure.message)")
            if let sig = caught { dieBySignal(sig) }
            return 1
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
// The Finder (and `open`) may pass a process serial number as the first argument; that still means the
// window. Only the first argument is dropped, so a word of a message's text is never lost.
var verbs = Array(args.dropFirst())
if verbs.first?.hasPrefix("-psn_") == true { verbs.removeFirst() }

if verbs.isEmpty {
    MainActor.assumeIsolated { RMNetApp.main() }
    exit(0)
}

let usage = "usage: RMNet activate | deactivate | status [--json] | sms list [--json] | sms send <number> <text> | sms delete <index>... | sms unblock [seconds] [--json] | gps [seconds] [--keep-on] | \(modemUsage)"

if verbs.first == "sms" {
    guard let smsCommand = parseSms(Array(verbs.dropFirst())) else {
        print(usage)
        exit(2)
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let code = runSms(smsCommand, service: SmsService())
        fflush(stdout)
        exit(code)
    }
    dispatchMain()
}

// gps: switches GNSS over the spare AT port, so it runs off the main thread, as the AT verbs. Ctrl-C, SIGTERM
// and a hang-up are watched by runGps itself: they switch GNSS off again if this run switched it on, and then
// end the verb by that signal. runGps also ignores SIGPIPE before it asks GNSS anything, so that output to a
// pipe that closed (`RMNet gps | head -1`) fails with EPIPE and GNSS is still switched off. The main run loop
// keeps the main thread, as for the modem verbs below.
if verbs.first == "gps" {
    guard let gps = parseGps(Array(verbs.dropFirst())) else {
        print(usage)
        exit(2)
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let code = runGps(seconds: gps.seconds, keepOn: gps.keepOn)
        fflush(stdout)
        exit(code)
    }
    while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
}

// network, radio, mode, apn, sim, usbmode, bands, at: over the modem's spare AT port, off the main thread, as the
// sms verbs. `at` alone writes to standard error (its refusals and failures); it is not a changing verb, so
// Ctrl-C stops it.
if let verb = verbs.first, modemVerbs.contains(verb) {
    guard let modemCommand = parseModem(verbs) else {
        print(usage)
        exit(2)
    }
    if modemCommand.changesModem {
        // From before the port opens until the result is printed, Ctrl-C, Ctrl-Z, Ctrl-\, a hang-up or a
        // plain kill do not stop a change in the middle (a redial with the radio off, a PIN sent).
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGQUIT] { signal(sig, SIG_IGN) }
    }
    // The verb runs on a worker thread; the password and PIN prompts run on the main thread (ruling R16).
    // Worker threads block signals, so there Ctrl-C would not end readpassphrase: the terminal would drop
    // what was typed and the next Return would give an empty answer. On the main thread readpassphrase
    // catches Ctrl-C itself and gives nil, and the verb stops with nothing changed or sent. A hang-up can
    // still give an empty answer, which the verbs refuse. Each line is flushed at once, so that the attempts
    // left and the APN warning are out before a prompt (which goes to /dev/tty) also when output is piped.
    // The usbmode question is read on the main thread too; there Ctrl-C is ignored (the signals above), and
    // Return alone, or Ctrl-D, cancels it.
    DispatchQueue.global(qos: .userInitiated).async {
        let code = runModem(modemCommand, service: ModemService(),
                            driverProfile: readDriverProperties()?["RMNetProfile"].flatMap { Int($0) },
                            readSecret: { prompt in DispatchQueue.main.sync { readSecret(prompt: prompt) } },
                            ask: { question in DispatchQueue.main.sync { askOnTerminal(question) } },
                            output: { print($0); fflush(stdout) },
                            errorOutput: { fputs("\($0)\n", stderr) },
                            imeiHistory: ImeiHistoryRecorder(keeper: ImeiHistoryFile.standard, module: { readModemSerial() }))
        fflush(stdout)
        exit(code)
    }
    // Not dispatchMain(): it ends the main thread, and the main queue then runs on a worker thread, which
    // blocks signals. The main run loop keeps the main thread and runs the main queue's blocks on it.
    while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
}

guard let command = Command(rawValue: verbs.first!),
      verbs.count == 1 || (command == .status && verbs.count == 2 && verbs.last == "--json") else {
    print(usage)
    exit(2)
}

let manager = ExtensionManager()
switch command {
case .activate: runActivate(manager)
case .deactivate: runDeactivate(manager)
case .status: runStatus(manager, json: verbs.count == 2)
}
dispatchMain()
