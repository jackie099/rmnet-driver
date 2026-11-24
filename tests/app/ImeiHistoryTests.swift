// Tests for app/ImeiHistory.swift: an entry's line and its reading back (also a line that is not one), the file in a
// temporary folder (no file, appending, its permissions, a broken line among good ones), the entries made from the
// service's outcomes, the order newest first, what `RMNet imei history` prints with and without --json, and the SIM &
// Data screen's rows (which offer Change Back…). Built with swiftc by `make app-test` from app/ModemNetwork.swift,
// app/ModemSettings.swift, app/ImeiHistory.swift and this file; no AppKit, no modem. The IMEIs are made-up numbers
// with a valid check digit (000000000000000, 123456789012347), never a real modem's.
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

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

let zeros = "000000000000000"
let counting = "123456789012347"
let t0 = Date(timeIntervalSince1970: 1_795_000_000)   // a fixed time

func entry(_ before: String?, _ after: String, at offset: TimeInterval = 0, source: ImeiChangeSource = .app,
           result: ImeiChangeResult = .succeeded, module: String? = "f00dcafe") -> ImeiHistoryEntry {
    ImeiHistoryEntry(time: t0.addingTimeInterval(offset), before: before, after: after, source: source, result: result,
                     restart: true, module: module, message: "IMEI set to \(after); the modem is restarting.", note: nil)
}

func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rmnet-imei-history-tests-\(getpid())-\(UUID().uuidString)")
        .appendingPathComponent("nested/imei-history.jsonl")
}

@main
struct ImeiHistoryTests {
    static func main() {
        check(imeiProblem(zeros) == nil && imeiProblem(counting) == nil, "the made-up IMEIs have valid check digits")
        lines()
        file()
        fileSafety()
        bytesAndTails()
        shortWrites()
        entriesFromOutcomes()
        order()
        printed()
        screenRows()
        restartApart()
        fifo()
        print("ImeiHistory: \(checks) checks passed")
    }

    // An entry's line has every key (null when not known), sorted; read back it is the same entry.
    static func lines() {
        let e = entry(zeros, counting)
        let line = imeiHistoryLine(e)
        check(!line.contains("\n"), "line: one line")
        check(line.hasPrefix("{\"after\":\"\(counting)\",\"before\":\"\(zeros)\""), "line: keys sorted", line)
        equal(imeiHistoryEntry(line: line), e, "line: read back")

        var unknown = e
        unknown.before = nil
        unknown.module = nil
        unknown.restart = nil
        unknown.message = nil
        let nullLine = imeiHistoryLine(unknown)
        check(nullLine.contains("\"before\":null") && nullLine.contains("\"module\":null")
              && nullLine.contains("\"note\":null"), "line: a value not known is null", nullLine)
        equal(imeiHistoryEntry(line: nullLine), unknown, "line: nulls read back as nil")

        // The time keeps its offset; another offset reads as the same instant.
        let written = imeiHistoryTimeText(t0)
        check(written.count == 25 || written.hasSuffix("Z"), "time: ISO 8601 to the second with an offset", written)
        let other = "{\"after\":\"\(counting)\",\"before\":null,\"module\":null,\"result\":\"succeeded\",\"source\":\"other\","
            + "\"time\":\"2026-11-22T02:57:14-05:00\",\"note\":\"recorded afterwards\"}"
        let read = imeiHistoryEntry(line: other)
        equal(read?.time, ISO8601DateFormatter().date(from: "2026-11-22T07:57:14Z"), "time: an offset read back")
        equal(read?.source, .other, "line: source other")
        equal(read?.note, "recorded afterwards", "line: note")

        // Not entries.
        for bad in ["", "not json", "[]", "{\"after\":\"\(counting)\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"succeeded\",\"source\":\"app\",\"time\":\"yesterday\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"maybe\",\"source\":\"app\",\"time\":\"2026-11-22T02:57:14Z\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"failed\",\"source\":\"phone\",\"time\":\"2026-11-22T02:57:14Z\"}",
                    "{\"after\":15,\"result\":\"failed\",\"source\":\"app\",\"time\":\"2026-11-22T02:57:14Z\"}"] {
            check(imeiHistoryEntry(line: bad) == nil, "line: not an entry: \(bad)")
        }

        let text = imeiHistoryLine(entry(zeros, counting)) + "\n\n  \nbroken line\n" + imeiHistoryLine(entry(counting, zeros, at: 60)) + "\n"
        let h = parseImeiHistory(text)
        equal(h.entries.count, 2, "parse: two entries")
        equal(h.skippedLines, 1, "parse: the broken line skipped and counted, blank lines ignored")
    }

    // The file: none yet is an empty history; appending makes the folder and the file (owner only), adds a line each.
    static func file() {
        let url = temporaryFile()
        let keeper = ImeiHistoryFile(url: url)
        equal(keeper.location, url.path, "file: location")
        equal(try? keeper.load().get(), ImeiHistory(entries: [], skippedLines: 0), "file: no file is an empty history")

        let first = entry(zeros, counting)
        let second = entry(counting, zeros, at: 3600, source: .cli, result: .failed)
        check(keeper.append(first) == nil, "file: first append")
        check(keeper.append(second) == nil, "file: second append")
        equal(try? keeper.load().get().entries, [first, second], "file: both entries, in the order written")

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        equal((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "file: owner only")
        let folder = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        equal((folder?[.posixPermissions] as? NSNumber)?.intValue, 0o700, "file: its folder owner only")

        // A line broken by hand does not lose the others.
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write("{\"half\":\n".data(using: .utf8)!)
            handle.closeFile()
        }
        let third = entry(nil, zeros, at: 7200, source: .other)
        check(keeper.append(third) == nil, "file: append after a broken line")
        let h = try? keeper.load().get()
        equal(h?.entries, [first, second, third], "file: entries around a broken line")
        equal(h?.skippedLines, 1, "file: the broken line counted")

        // A file that cannot be written says so.
        let blocked = ImeiHistoryFile(url: URL(fileURLWithPath: "/dev/null/imei-history.jsonl"))
        check(blocked.append(first) != nil, "file: a folder that cannot be made is a sentence")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    // Only a regular file of the user's, owner-only, in a folder of the user's that nobody else can write, opened without
    // following a symbolic link: anything else is a sentence, and nothing is read from it or written to it.
    static func fileSafety() {
        let fm = FileManager.default
        let base = temporaryFile().deletingLastPathComponent().deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("history")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // The history a symbolic link to another file: refused, and the other file untouched.
        let target = base.appendingPathComponent("elsewhere.txt")
        fm.createFile(atPath: target.path, contents: Data("keep\n".utf8), attributes: [.posixPermissions: 0o600])
        let linked = folder.appendingPathComponent("linked.jsonl")
        try? fm.createSymbolicLink(at: linked, withDestinationURL: target)
        let viaLink = ImeiHistoryFile(url: linked)
        check(viaLink.append(entry(zeros, counting)) != nil, "safety: an append through a symbolic link is refused")
        check(viaLink.load().failureMessage?.contains("symbolic link") == true, "safety: a load through one too",
              "\(viaLink.load())")
        equal(try? String(contentsOf: target, encoding: .utf8), "keep\n", "safety: the link's target untouched")

        // Readable by others: refused.
        let open = folder.appendingPathComponent("open.jsonl")
        fm.createFile(atPath: open.path, contents: Data((imeiHistoryLine(entry(zeros, counting)) + "\n").utf8),
                      attributes: [.posixPermissions: 0o644])
        let wide = ImeiHistoryFile(url: open)
        check(wide.load().failureMessage?.contains("only you can read and write") == true, "safety: a 0644 file is refused")
        check(wide.append(entry(zeros, counting)) != nil, "safety: and not appended to")
        equal((try? Data(contentsOf: open)).map { $0.count },
              imeiHistoryLine(entry(zeros, counting)).utf8.count + 1, "safety: the 0644 file unchanged")

        // A folder that is not a regular file: refused.
        let notFile = folder.appendingPathComponent("dir.jsonl")
        try? fm.createDirectory(at: notFile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        check(ImeiHistoryFile(url: notFile).load().failureMessage != nil, "safety: a folder in its place is refused")

        // Its folder writable by others, or a symbolic link: refused.
        let shared = base.appendingPathComponent("shared")
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        _ = chmod(shared.path, 0o777)
        let inShared = ImeiHistoryFile(url: shared.appendingPathComponent("imei-history.jsonl"))
        check(inShared.append(entry(zeros, counting))?.contains("folder") == true, "safety: a folder others can write")
        check(!fm.fileExists(atPath: shared.appendingPathComponent("imei-history.jsonl").path),
              "safety: nothing made in it")
        let linkedFolder = base.appendingPathComponent("linked-folder")
        try? fm.createSymbolicLink(at: linkedFolder, withDestinationURL: folder)
        let throughFolder = ImeiHistoryFile(url: linkedFolder.appendingPathComponent("imei-history.jsonl"))
        check(throughFolder.append(entry(zeros, counting))?.contains("folder") == true, "safety: a linked folder")
        check(throughFolder.load().failureMessage?.contains("folder") == true, "safety: a linked folder, loading")
    }

    // Lines split at LF bytes: bytes that are not UTF-8 cost their line only; a last line without its LF (a write cut
    // short) is counted when broken, and the next append starts on a line of its own.
    static func bytesAndTails() {
        let good = imeiHistoryLine(entry(zeros, counting))
        var bytes = Array((good + "\n").utf8)
        bytes += [0x7B, 0xFF, 0xFE, 0x22, 0x7D, 0x0A]                 // {\xff\xfe"}: not UTF-8
        bytes += Array((imeiHistoryLine(entry(counting, zeros, at: 60)) + "\r\n").utf8)
        bytes += Array("\u{2028}\n".utf8)                                 // a line of a Unicode separator only
        let h = parseImeiHistory(bytes: bytes)
        equal(h.entries, [entry(zeros, counting), entry(counting, zeros, at: 60)], "bytes: both good lines read")
        equal(h.skippedLines, 0 + 1, "bytes: the bad bytes cost one line")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let keeper = ImeiHistoryFile(url: url)
        check(keeper.append(entry(zeros, counting)) == nil, "tail: first append")
        // A write cut short: half a line, no LF.
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(good.utf8.prefix(20)))
            handle.closeFile()
        }
        check(keeper.append(entry(counting, zeros, at: 60)) == nil, "tail: append after a cut-short line")
        let after = try? keeper.load().get()
        equal(after?.entries, [entry(zeros, counting), entry(counting, zeros, at: 60)],
              "tail: the new entry on a line of its own")
        equal(after?.skippedLines, 1, "tail: the cut-short line counted")
        let raw = (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
        equal(raw.filter { $0 == 0x0A }.count, 3, "tail: a LF added before the new line")
        equal(raw.last, 0x0A, "tail: the file ends with a LF")

        // A complete last line without its LF is read, and the next append does not join it.
        let bare = temporaryFile()
        defer { try? FileManager.default.removeItem(at: bare.deletingLastPathComponent().deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: bare.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: bare.path, contents: Data(good.utf8), attributes: [.posixPermissions: 0o600])
        let bareKeeper = ImeiHistoryFile(url: bare)
        equal(try? bareKeeper.load().get().entries, [entry(zeros, counting)], "tail: a last line without LF is read")
        check(bareKeeper.append(entry(counting, zeros, at: 60)) == nil, "tail: append after it")
        equal(try? bareKeeper.load().get(), ImeiHistory(entries: [entry(zeros, counting), entry(counting, zeros, at: 60)],
                                                        skippedLines: 0), "tail: both lines whole")
    }

    // write(2) may write fewer bytes than asked: the append goes on until every byte is written; one that writes
    // nothing is a sentence.
    static func shortWrites() {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        var calls = 0
        let dribble = ImeiHistoryFile(url: url, write: { fd, p, n in
            calls += 1
            return Darwin.write(fd, p, min(n, 7))
        })
        check(dribble.append(entry(zeros, counting)) == nil, "short: append in pieces")
        check(dribble.append(entry(counting, zeros, at: 60)) == nil, "short: another")
        check(calls > 2, "short: more than one write each", "\(calls)")
        equal(try? dribble.load().get(), ImeiHistory(entries: [entry(zeros, counting), entry(counting, zeros, at: 60)],
                                                     skippedLines: 0), "short: both entries whole")

        let stuck = ImeiHistoryFile(url: url, write: { _, _, _ in 0 })
        check(stuck.append(entry(zeros, zeros, at: 120))?.contains("could not be written") == true,
              "short: a write that writes nothing is a sentence")
    }

    // The service's outcome as an entry: nothing for an IMEI already set; the before from the service on success,
    // the one known before on failure.
    static func entriesFromOutcomes() {
        check(imeiHistoryEntry(after: counting, before: counting, restart: true, outcome: .success(.unchanged(counting)),
                               source: .app, module: nil, at: t0) == nil, "outcome: unchanged is not recorded")

        let restarted = imeiHistoryEntry(after: counting, before: nil, restart: true,
                                         outcome: .success(.rebooting(before: zeros, after: counting)),
                                         source: .cli, module: "f00dcafe", at: t0)
        equal(restarted, ImeiHistoryEntry(time: t0, before: zeros, after: counting, source: .cli, result: .succeeded,
                                          restart: true, restartResult: .succeeded, module: "f00dcafe",
                                          message: "IMEI set to \(counting); the modem is restarting.", note: nil),
              "outcome: restarting")

        let later = imeiHistoryEntry(after: counting, before: zeros, restart: false,
                                     outcome: .success(.setTakesEffectAfterRestart(before: zeros, after: counting)),
                                     source: .app, module: nil, at: t0)
        equal(later?.result, .succeeded, "outcome: after the next restart succeeded")
        equal(later?.restart, false, "outcome: no restart asked")
        check(later?.message?.contains("next restart") == true, "outcome: its sentence")

        let failed = imeiHistoryEntry(after: counting, before: zeros, restart: true,
                                      outcome: .failure(ModemFailure(message: "The IMEI was not changed. ERROR")),
                                      source: .app, module: "f00dcafe", at: t0)
        equal(failed?.result, .failed, "outcome: failure recorded as failed")
        equal(failed?.before, zeros, "outcome: a failure keeps the IMEI known before")
        equal(failed?.message, "The IMEI was not changed. ERROR", "outcome: a failure's sentence")
    }

    // Newest first by time; an entry recorded afterwards goes where its time puts it; equal times newest written first.
    static func order() {
        let old = entry(zeros, counting, at: 0, source: .other)
        let new = entry(counting, zeros, at: 100)
        let backfilled = entry(nil, zeros, at: 50, source: .other)
        let same = entry(zeros, counting, at: 100, source: .cli)
        let h = ImeiHistory(entries: [old, new, backfilled, same], skippedLines: 0)
        equal(h.newestFirst, [same, new, backfilled, old], "order: newest first")
    }

    // What `imei history` prints.
    static func printed() {
        let none = imeiHistoryLines(ImeiHistory(entries: [], skippedLines: 0), location: "/tmp/h.jsonl")
        equal(none, ["imei: no IMEI changes recorded on this Mac", "imei: kept in /tmp/h.jsonl"], "print: empty")

        var other = entry(zeros, counting, at: 0, source: .other, module: "f00dcafe")
        other.message = nil
        other.note = "Sent as AT+EGMR=1,7 by another tool; recorded afterwards."
        var failed = entry(counting, zeros, at: 60, result: .failed, module: nil)
        failed.message = "The IMEI was not changed. ERROR"
        let lines = imeiHistoryLines(ImeiHistory(entries: [other, failed], skippedLines: 2), location: "/tmp/h.jsonl")
        equal(lines.count, 7, "print: headline, two entries with a line each, skipped, location")
        equal(lines[0], "imei: 2 IMEI changes recorded on this Mac, newest first", "print: headline")
        check(lines[1].hasSuffix("  \(counting) -> \(zeros)  failed  app"), "print: newest first, no module", lines[1])
        equal(lines[2], "  The IMEI was not changed. ERROR", "print: its sentence indented")
        check(lines[3].hasSuffix("  \(zeros) -> \(counting)  succeeded  other  module f00dcafe"), "print: module", lines[3])
        equal(lines[4], "  Sent as AT+EGMR=1,7 by another tool; recorded afterwards.", "print: note")
        equal(lines[5], "imei: 2 lines of the history could not be read and were skipped", "print: skipped")
        equal(lines[6], "imei: kept in /tmp/h.jsonl", "print: location")
        let one = imeiHistoryLines(ImeiHistory(entries: [other], skippedLines: 1), location: "x")
        equal(one[0], "imei: 1 IMEI change recorded on this Mac, newest first", "print: one change")
        equal(one[3], "imei: 1 line of the history could not be read and was skipped", "print: one skipped")

        let json = imeiHistoryJSON(ImeiHistory(entries: [other, failed], skippedLines: 2), location: "/tmp/h.jsonl")
        check(JSONSerialization.isValidJSONObject(json), "json: valid")
        equal(json["path"] as? String, "/tmp/h.jsonl", "json: path")
        equal(json["skippedLines"] as? Int, 2, "json: skippedLines")
        let entries = json["entries"] as? [[String: Any]] ?? []
        equal(entries.count, 2, "json: entries")
        equal(entries.first?["after"] as? String, zeros, "json: newest first")
        equal(Set(entries.first?.keys.map { $0 } ?? []),
              ["time", "before", "after", "source", "result", "restart", "restartResult", "module", "message", "note"],
              "json: every key (restartResult added)")
        check(entries.first?["module"] is NSNull, "json: unknown module is null")
    }

    // The screen's rows: Change Back… only for a change that succeeded on the attached module (both known and the
    // same: an entry without its module is only shown), back to a valid IMEI other than the current one.
    static func screenRows() {
        let mine = entry(zeros, counting, at: 0, module: "f00dcafe")
        let elsewhere = entry(zeros, counting, at: 10, module: "0badbeef")
        let failed = entry(zeros, counting, at: 20, result: .failed, module: "f00dcafe")
        let unknownBefore = entry(nil, counting, at: 30, module: "f00dcafe")
        let noModule = entry(zeros, counting, at: 40, module: nil)
        let h = ImeiHistory(entries: [mine, elsewhere, failed, unknownBefore, noModule], skippedLines: 0)

        let rows = imeiHistoryRows(h, currentImei: counting, currentModule: "f00dcafe")
        equal(rows.map { $0.entry }, h.newestFirst, "rows: newest first")
        equal(rows.map { $0.canChangeBack }, [false, false, false, false, true], "rows: change back offered")
        check(!rows[0].canChangeBack && rows[0].entry.module == nil, "rows: an entry without its module is only shown")
        equal(rows.map { $0.otherModule }, [false, false, false, true, false], "rows: other module")

        let backNow = imeiHistoryRows(h, currentImei: zeros, currentModule: "f00dcafe")
        check(backNow.allSatisfy { !$0.canChangeBack }, "rows: not back to the IMEI the modem has now")
        let noneAttached = imeiHistoryRows(h, currentImei: counting, currentModule: nil)
        check(noneAttached.allSatisfy { !$0.otherModule }, "rows: no module attached, none is another")
        check(noneAttached.allSatisfy { !$0.canChangeBack }, "rows: no module known attached, no Change Back")
    }

    // The write and the restart recorded apart: an IMEI written and read back whose restart failed succeeded, with its
    // restart failed, and can be changed back; the key is in every line (null when not known), and lines written before
    // it existed read as before.
    static func restartApart() {
        let sentence = "The IMEI is now \(counting), but the modem was not restarted. The modem refused the command (ERROR). "
            + "It takes effect at the next restart (AT+CFUN=1,1 or a replug)."
        let e = imeiHistoryEntry(after: counting, before: zeros, restart: true,
                                 outcome: .success(.restartFailed(before: zeros, after: counting, sentence: sentence)),
                                 source: .app, module: "TESTMODULE1", at: t0)
        check(e?.result == .succeeded && e?.restartResult == .failed && e?.message == sentence,
              "restart apart: written, its restart failed", "\(String(describing: e))")
        guard let e else { return }
        let line = imeiHistoryLine(e)
        check(line.contains("\"restartResult\":\"failed\""), "restart apart: in the line", line)
        equal(imeiHistoryEntry(line: line), e, "restart apart: read back")
        check(imeiHistoryLine(entry(zeros, counting)).contains("\"restartResult\":null"), "restart apart: null when not known")
        // A line from before: no restartResult key; read as it was, with none.
        let old = "{\"after\":\"\(counting)\",\"before\":\"\(zeros)\",\"message\":\"IMEI set.\",\"module\":\"TESTMODULE1\","
            + "\"note\":null,\"restart\":true,\"result\":\"failed\",\"source\":\"app\",\"time\":\"2026-11-22T02:57:14-05:00\"}"
        let read = imeiHistoryEntry(line: old)
        check(read?.result == .failed && read?.restartResult == nil && read?.module == "TESTMODULE1",
              "restart apart: an older line read as before", "\(String(describing: read))")
        let odd = old.replacingOccurrences(of: "\"note\":null", with: "\"note\":null,\"restartResult\":\"maybe\"")
        check(imeiHistoryEntry(line: odd) != nil && imeiHistoryEntry(line: odd)?.restartResult == nil,
              "restart apart: an unknown value is none")
        // Change Back offered for it; printed with `restart failed`; in the JSON.
        let rows = imeiHistoryRows(ImeiHistory(entries: [e], skippedLines: 0), currentImei: counting,
                                   currentModule: "TESTMODULE1")
        check(rows.first?.canChangeBack == true, "restart apart: can be changed back")
        let printed = imeiHistoryLines(ImeiHistory(entries: [e], skippedLines: 0), location: "/x")
        check(printed[1].hasSuffix("module TESTMODULE1  restart failed"), "restart apart: printed", printed[1])
        let json = imeiHistoryJSON(ImeiHistory(entries: [e], skippedLines: 0), location: "/x")
        let first = (json["entries"] as? [[String: Any]])?.first
        equal(first?["restartResult"] as? String, "failed", "restart apart: in the JSON")
        equal(first?["result"] as? String, "succeeded", "restart apart: the JSON's result is the write's")
    }

    // A FIFO where the file should be: refused at once, never waited on (it is opened without blocking and checked).
    static func fifo() {
        let fm = FileManager.default
        let url = temporaryFile()
        let base = url.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? fm.removeItem(at: base) }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        check(mkfifo(url.path, 0o600) == 0, "fifo: made")
        let file = ImeiHistoryFile(url: url)
        let done = DispatchSemaphore(value: 0)
        var loaded: Result<ImeiHistory, ModemFailure>? = nil
        var appended: String? = nil
        DispatchQueue.global().async {
            loaded = file.load()
            appended = file.append(entry(zeros, counting))
            done.signal()
        }
        check(done.wait(timeout: .now() + 3) == .success, "fifo: not waited on")
        check(loaded?.failureMessage?.contains("not a file of yours") == true, "fifo: a load refused",
              "\(String(describing: loaded))")
        check(appended?.contains("not a file of yours") == true, "fifo: an append refused", "\(String(describing: appended))")
    }
}

extension Result {
    var failureMessage: String? {
        if case .failure(let f) = self { return (f as? ModemFailure)?.message ?? "\(f)" }
        return nil
    }
}
