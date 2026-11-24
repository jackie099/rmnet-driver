// The IMEI history: one entry for each change of the modem's IMEI made with RMNet (the SIM & Data screen's Change…,
// `RMNet imei set`), and for a change made otherwise that was recorded afterwards. Each entry has the time, the
// IMEI before and after, where the change came from, whether the IMEI was written (and, apart from it, whether the
// restart asked for went), the module (its USB serial number, which
// an IMEI change does not touch, so that the history of a module plugged into several Macs can be told apart) and the
// sentence RMNet showed.
//
// The history is kept on this Mac only, in ~/Library/Application Support/RMNet/imei-history.jsonl: one JSON object a
// line, appended (never rewritten), readable by the owner only. A line that cannot be read is skipped and counted.
// The file is used only as what it should be: a regular file of the user's, owner-only, in a folder of the user's
// that nobody else can write, opened without following a symbolic link (checked on the opened file itself); anything
// else is refused with a sentence. Lines are split at LF bytes, so bytes that are not UTF-8 cost their line only; an
// append is made under an exclusive lock (flock) shared with every RMNet process, starts on a line of its own when the
// file does not end with a LF (a write cut short), and writes until every byte is written.
// Foundation only, so `make app-test` builds it (tests/app/ImeiHistoryTests.swift); nothing here talks to the modem.
import Foundation

/// Where a change came from: the window, the `imei set` verb, or another tool (recorded afterwards).
enum ImeiChangeSource: String, Codable, CaseIterable {
    case app, cli, other

    var words: String {
        switch self {
        case .app: return "RMNet window"
        case .cli: return "RMNet imei set"
        case .other: return "Another tool"
        }
    }
}

enum ImeiChangeResult: String, Codable {
    case succeeded, failed
}

struct ImeiHistoryEntry: Equatable {
    var time: Date
    var before: String?          // nil: not known
    var after: String            // the IMEI asked for
    var source: ImeiChangeSource
    var result: ImeiChangeResult // the IMEI written and read back (succeeded), or not (failed: it may still have changed)
    var restart: Bool?           // the modem was to restart at once (nil: not known)
    /// The restart asked for (`restart` true) after a write that succeeded: the modem took the command (succeeded), or it
    /// refused it or did not answer (failed: the new IMEI takes effect at the next restart). nil: none asked, or an entry
    /// written before RMNet recorded it apart (those recorded a failed restart as a failed change).
    var restartResult: ImeiChangeResult? = nil
    var module: String?          // the module's USB serial number (nil: not known)
    var message: String?         // the sentence RMNet showed for the change
    var note: String?            // for an entry recorded afterwards: how it was made
}

/// The history as read: its entries in the order they were written, and how many lines could not be read.
struct ImeiHistory: Equatable {
    var entries: [ImeiHistoryEntry]
    var skippedLines: Int

    /// Newest first (an entry recorded afterwards goes where its time puts it); equal times keep the order written.
    var newestFirst: [ImeiHistoryEntry] {
        entries.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time > b.element.time : a.offset > b.offset
        }.map { $0.element }
    }
}

// MARK: - One line of the file

/// "2026-11-22T02:57:14-05:00": the time with the Mac's offset at the time, to the second.
private func isoFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}

private func isoParser(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)
}

func imeiHistoryTimeText(_ date: Date) -> String { isoFormatter().string(from: date) }

/// The entry as a JSON object: every key is always there, a value not known is null.
func imeiHistoryObject(_ e: ImeiHistoryEntry) -> [String: Any] {
    func orNull<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
    return ["time": imeiHistoryTimeText(e.time), "before": orNull(e.before), "after": e.after,
            "source": e.source.rawValue, "result": e.result.rawValue, "restart": orNull(e.restart),
            "restartResult": orNull(e.restartResult?.rawValue),
            "module": orNull(e.module), "message": orNull(e.message), "note": orNull(e.note)]
}

/// One line of the file (no newline), keys sorted.
func imeiHistoryLine(_ e: ImeiHistoryEntry) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: imeiHistoryObject(e), options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// A line read back; nil when it is not an entry (not JSON, no valid time, no `after`, an unknown source or result). A
/// line without `restartResult` (written before it was recorded) has none; an unknown value is none too.
func imeiHistoryEntry(line: String) -> ImeiHistoryEntry? {
    guard let data = line.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let time = (o["time"] as? String).flatMap(isoParser),
          let after = o["after"] as? String,
          let source = (o["source"] as? String).flatMap(ImeiChangeSource.init(rawValue:)),
          let result = (o["result"] as? String).flatMap(ImeiChangeResult.init(rawValue:)) else { return nil }
    return ImeiHistoryEntry(time: time, before: o["before"] as? String, after: after, source: source, result: result,
                            restart: o["restart"] as? Bool,
                            restartResult: (o["restartResult"] as? String).flatMap(ImeiChangeResult.init(rawValue:)),
                            module: o["module"] as? String, message: o["message"] as? String, note: o["note"] as? String)
}

/// The file's text read back: blank lines ignored, any other line that is not an entry skipped and counted.
func parseImeiHistory(_ text: String) -> ImeiHistory {
    parseImeiHistory(bytes: Array(text.utf8))
}

/// The file's bytes read back, split at each LF: a line that is not UTF-8 or not an entry is skipped and counted (only
/// that line), a blank one ignored; a last line without its LF (a write cut short) is read like any other.
func parseImeiHistory(bytes: [UInt8]) -> ImeiHistory {
    var entries: [ImeiHistoryEntry] = []
    var skipped = 0
    for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard let text = String(bytes: raw, encoding: .utf8) else {
            skipped += 1
            continue
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if let e = imeiHistoryEntry(line: line) { entries.append(e) } else { skipped += 1 }
    }
    return ImeiHistory(entries: entries, skippedLines: skipped)
}

// MARK: - The file

/// Where the history is kept and how it is read and added to. The app and the verbs use ImeiHistoryFile; the tests
/// use a file of their own.
protocol ImeiHistoryKeeping {
    /// The file's path, as shown to the owner.
    var location: String { get }
    /// The history; no file yet is an empty history. A failure is a sentence.
    func load() -> Result<ImeiHistory, ModemFailure>
    /// Adds one entry at the end; nil on success, else why not.
    func append(_ entry: ImeiHistoryEntry) -> String?
}

final class ImeiHistoryFile: ImeiHistoryKeeping {
    let url: URL
    private let writeBytes: (Int32, UnsafeRawPointer, Int) -> Int

    /// `write`: write(2), or in the tests one that writes fewer bytes than asked.
    init(url: URL, write: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) {
        self.url = url
        self.writeBytes = write
    }

    /// ~/Library/Application Support/RMNet/imei-history.jsonl, for the window and the verbs alike (the app is not
    /// sandboxed, so both see the same file).
    static var standard: ImeiHistoryFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ImeiHistoryFile(url: base.appendingPathComponent("RMNet/imei-history.jsonl"))
    }

    var location: String { url.path }
    private var folder: URL { url.deletingLastPathComponent() }

    /// No file (or no folder) yet is an empty history. Read under a shared lock, so never half an append.
    func load() -> Result<ImeiHistory, ModemFailure> {
        if let problem = folderProblem(creating: false) {
            if problem.isEmpty { return .success(ImeiHistory(entries: [], skippedLines: 0)) }
            return .failure(ModemFailure(message: problem))
        }
        // Without blocking: a FIFO put where the file should be would otherwise hold the open until a writer comes; it is
        // refused by the check on the opened file instead. A regular file reads the same either way.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return .success(ImeiHistory(entries: [], skippedLines: 0)) }
            return .failure(ModemFailure(message: openProblem(errno)))
        }
        defer { close(fd) }
        if let problem = fileProblem(fd) { return .failure(ModemFailure(message: problem)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard flock(fd, LOCK_SH) == 0 else { return .failure(ModemFailure(message: unreadable)) }
        defer { flock(fd, LOCK_UN) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(ModemFailure(message: unreadable))
            }
            bytes.append(contentsOf: chunk[0..<n])
        }
        return .success(parseImeiHistory(bytes: bytes))
    }

    /// The line and its newline, appended under an exclusive lock (a change recorded by the window and one by a verb at
    /// the same moment do not mix their lines), after a newline of its own when the file does not end with one, every
    /// byte written however many writes it takes. The file is made owner-only, its folder too.
    func append(_ entry: ImeiHistoryEntry) -> String? {
        if let problem = folderProblem(creating: true) { return problem }
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return openProblem(errno) }
        defer { close(fd) }
        if let problem = fileProblem(fd) { return problem }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard flock(fd, LOCK_EX) == 0 else { return unwritable }
        defer { flock(fd, LOCK_UN) }
        var bytes = Array((imeiHistoryLine(entry) + "\n").utf8)
        var info = stat()
        guard fstat(fd, &info) == 0 else { return unwritable }
        if info.st_size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, info.st_size - 1) == 1 else { return unwritable }
            if last != 0x0A { bytes.insert(0x0A, at: 0) }
        }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { writeBytes(fd, $0.baseAddress! + done, bytes.count - done) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return unwritable }
            done += n
        }
        return nil
    }

    private var unreadable: String { "The IMEI history could not be read (\(url.path))." }
    private var unwritable: String { "The IMEI history could not be written (\(url.path))." }

    private func openProblem(_ code: Int32) -> String {
        code == ELOOP ? "The IMEI history is a symbolic link, which RMNet does not follow (\(url.path))."
            : "The IMEI history could not be opened (\(url.path))."
    }

    /// The folder (made owner-only when `creating` and missing): a directory of the user's, not a symbolic link, that
    /// nobody else can write. nil: fine; "": missing (not `creating`); else why not.
    private func folderProblem(creating: Bool) -> String? {
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            guard errno == ENOENT else { return "The IMEI history's folder could not be checked (\(folder.path))." }
            guard creating else { return "" }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return "The IMEI history's folder could not be made (\(folder.path))."
            }
            guard lstat(folder.path, &info) == 0 else { return "The IMEI history's folder could not be made (\(folder.path))." }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            return "The IMEI history's folder is not a folder of yours that only you can write (\(folder.path)). "
                + "RMNet does not use it."
        }
        return nil
    }

    /// The file opened: a regular file of the user's that only the user can read or write. nil: fine; else why not.
    private func fileProblem(_ fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return "The IMEI history could not be checked (\(url.path))." }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            return "The IMEI history is not a file of yours that only you can read and write (\(url.path)). "
                + "RMNet does not use it."
        }
        return nil
    }
}

/// What a change needs to record itself: the file and the clock; and the attached module's serial number, which the
/// SIM & Data screen shows beside the history (an entry takes its module from the change's own port open, ImeiWrite).
struct ImeiHistoryRecorder {
    let keeper: ImeiHistoryKeeping
    let module: () -> String?
    var now: () -> Date = { Date() }
}

// MARK: - Entries from changes

/// The entry for a change asked for (`after`), from the IMEI and the module the change's port open read (ImeiWrite) and
/// the service's answer; nil when the modem already had that IMEI (nothing was written). A failure is recorded as
/// failed with its sentence: it may still have changed the IMEI (the sentence then says so). The write and the restart
/// are recorded apart: an IMEI written and read back whose restart failed is a change that succeeded, with its restart
/// failed (so it can be changed back).
func imeiHistoryEntry(after: String, before: String?, restart: Bool, outcome: Result<ImeiChange, ModemFailure>,
                      source: ImeiChangeSource, module: String?, at time: Date) -> ImeiHistoryEntry? {
    switch outcome {
    case .success(.unchanged):
        return nil
    case .success(let change):
        let was: String
        let restarted: ImeiChangeResult?
        switch change {
        case .rebooting(let b, _): was = b; restarted = .succeeded
        case .setTakesEffectAfterRestart(let b, _): was = b; restarted = nil
        case .restartFailed(let b, _, _): was = b; restarted = .failed
        case .unchanged(let b): was = b; restarted = nil
        }
        return ImeiHistoryEntry(time: time, before: was, after: after, source: source, result: .succeeded,
                                restart: restart, restartResult: restarted, module: module, message: imeiSentence(change),
                                note: nil)
    case .failure(let failure):
        return ImeiHistoryEntry(time: time, before: before, after: after, source: source, result: .failed,
                                restart: restart, module: module, message: failure.message, note: nil)
    }
}

// MARK: - What `RMNet imei history` prints

private let localTimeText: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// `imei history`: a headline, then each entry newest first on one line (time in the Mac's time zone, before and
/// after, the result, where it came from, the module, `restart failed` when the restart after a write did), its
/// sentence or note indented below; then where it is kept.
func imeiHistoryLines(_ history: ImeiHistory, location: String) -> [String] {
    var lines: [String] = []
    let n = history.entries.count
    if n == 0 {
        lines.append("imei: no IMEI changes recorded on this Mac")
    } else {
        lines.append("imei: \(n) IMEI change\(n == 1 ? "" : "s") recorded on this Mac, newest first")
    }
    for e in history.newestFirst {
        var parts = ["\(localTimeText.string(from: e.time))", "\(e.before ?? "unknown") -> \(e.after)",
                     e.result.rawValue, e.source.rawValue]
        if let m = e.module { parts.append("module \(m)") }
        if e.restartResult == .failed { parts.append("restart failed") }
        lines.append(parts.joined(separator: "  "))
        for text in [e.note, e.message].compactMap({ $0 }) where !text.isEmpty {
            lines.append("  \(text)")
        }
    }
    if history.skippedLines > 0 {
        lines.append("imei: \(history.skippedLines) line\(history.skippedLines == 1 ? "" : "s") of the history could not be read and \(history.skippedLines == 1 ? "was" : "were") skipped")
    }
    lines.append("imei: kept in \(location)")
    return lines
}

/// `imei history --json`: `path`, `skippedLines` and `entries` (newest first; each with every key, null when not
/// known).
func imeiHistoryJSON(_ history: ImeiHistory, location: String) -> [String: Any] {
    ["path": location, "skippedLines": history.skippedLines, "entries": history.newestFirst.map(imeiHistoryObject)]
}

// MARK: - What the SIM & Data screen shows

/// A row of the screen's history: the change in words, and whether Change Back… is offered for it (a change that
/// succeeded on the module attached, both known and the same, whose IMEI before is known and is not the one the modem
/// has now). An entry whose module is not known is only shown: it cannot be told which module it would change back.
struct ImeiHistoryRow: Equatable {
    let entry: ImeiHistoryEntry
    let otherModule: Bool        // made on another module than the one attached
    let canChangeBack: Bool
}

func imeiHistoryRows(_ history: ImeiHistory, currentImei: String?, currentModule: String?) -> [ImeiHistoryRow] {
    history.newestFirst.map { e in
        let other = currentModule != nil && e.module != nil && e.module != currentModule
        let sameModule = e.module != nil && e.module == currentModule
        let back = sameModule && e.result == .succeeded
            && e.before.map { imeiProblem($0) == nil && $0 != currentImei } == true
        return ImeiHistoryRow(entry: e, otherModule: other, canChangeBack: back)
    }
}
