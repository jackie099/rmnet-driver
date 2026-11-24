// What became of each part RMNet sent, kept across runs and shared by the window and `RMNet sms send` (SmsService.swift
// writes it, both read it): a part the modem confirmed (+CMSS) is never sent again, also when the modem still lists it
// as unsent after a restart of RMNet, and a part whose send got no answer is marked Not confirmed.
//
// A part is known by the module (its USB serial number), the SIM (a SHA-256 of its IMSI: the IMSI itself is not kept),
// the storage it was written to (<mem2>), its stored index and a SHA-256 of its raw PDU as the modem keeps it: another
// message that takes the same index later is another part. Each event is one JSON line (written, confirmed, not known);
// the latest for a part is its state (a new write at that index with the same PDU starts it again). Nothing in it is
// message text or a number.
//
// Kept in ~/Library/Application Support/RMNet/sms-sends.jsonl and used only as what it should be, as the IMEI history
// (ImeiHistory.swift) is: a regular file of the user's that only they can read and write, in a folder of theirs that
// nobody else can write, opened without following a symbolic link and without waiting (a FIFO is refused, not waited
// on), checked on the opened file itself; read under a shared lock, appended under an exclusive one, on a line of its
// own, every byte written. Foundation and CryptoKit only (tests/app/SmsSendLedgerTests.swift).
import CryptoKit
import Foundation

/// A stored part RMNet sent (see above).
struct SmsPartKey: Hashable {
    let module: String
    let sim: String       // SHA-256 of the IMSI, hex
    let storage: String
    let index: Int
    let pdu: String       // SHA-256 of the raw PDU (upper-case hex), hex

    /// nil without a module or a SIM: such a part cannot be told from another module's or SIM's.
    init?(module: String?, imsi: String?, storage: String?, index: Int, hex: String) {
        guard let module, !module.isEmpty, let imsi, !imsi.isEmpty, let storage, !storage.isEmpty, index >= 0 else {
            return nil
        }
        self.module = module
        sim = sha256Hex(imsi)
        self.storage = storage
        self.index = index
        pdu = sha256Hex(hex.uppercased())
    }

    fileprivate init(module: String, sim: String, storage: String, index: Int, pdu: String) {
        self.module = module
        self.sim = sim
        self.storage = storage
        self.index = index
        self.pdu = pdu
    }
}

/// A part's state: written to the store (not sent yet), confirmed sent, or sent with no answer (it may have gone).
enum SmsPartState: String {
    case written, confirmed, unknown
}

struct SmsLedgerEvent: Equatable {
    let time: Date
    let key: SmsPartKey
    let state: SmsPartState
}

/// Why the record of sent messages could not be read: a sentence.
struct LedgerProblem: Error, Equatable {
    let message: String
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The ledger: each part's latest state. A failure is a sentence.
protocol SmsSendLedgerKeeping {
    func states() -> Result<[SmsPartKey: SmsPartState], LedgerProblem>
    func record(_ events: [SmsLedgerEvent]) -> String?
}

/// One event as a line, keys sorted.
func smsLedgerLine(_ e: SmsLedgerEvent) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    let object: [String: Any] = ["time": f.string(from: e.time), "module": e.key.module, "sim": e.key.sim,
                                 "storage": e.key.storage, "index": e.key.index, "pdu": e.key.pdu,
                                 "state": e.state.rawValue]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// The latest state of each part from the file's bytes; a line that is not an event (not UTF-8, not JSON, a field
/// missing or of the wrong kind) is skipped.
func smsLedgerStates(_ bytes: [UInt8]) -> [SmsPartKey: SmsPartState] {
    var out: [SmsPartKey: SmsPartState] = [:]
    for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard let text = String(bytes: raw, encoding: .utf8), let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let module = o["module"] as? String, let sim = o["sim"] as? String, let storage = o["storage"] as? String,
              let index = o["index"] as? Int, let pdu = o["pdu"] as? String,
              let state = (o["state"] as? String).flatMap(SmsPartState.init(rawValue:)) else { continue }
        out[SmsPartKey(module: module, sim: sim, storage: storage, index: index, pdu: pdu)] = state
    }
    return out
}

/// The ledger in a file (the app and the verbs: `standard`; the tests: a temporary one).
final class SmsSendLedgerFile: SmsSendLedgerKeeping {
    let url: URL
    private let writeBytes: (Int32, UnsafeRawPointer, Int) -> Int

    init(url: URL, write: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) {
        self.url = url
        writeBytes = write
    }

    static var standard: SmsSendLedgerFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SmsSendLedgerFile(url: base.appendingPathComponent("RMNet/sms-sends.jsonl"))
    }

    private var folder: URL { url.deletingLastPathComponent() }
    private var unreadable: String { "The record of sent messages could not be read (\(url.path))." }
    private var unwritable: String { "The record of sent messages could not be written (\(url.path))." }

    /// No file (or folder) yet: no states.
    func states() -> Result<[SmsPartKey: SmsPartState], LedgerProblem> {
        if let problem = folderProblem(creating: false) {
            return problem.isEmpty ? .success([:]) : .failure(LedgerProblem(message: problem))
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return .success([:]) }
            return .failure(LedgerProblem(message: openProblem(errno)))
        }
        defer { close(fd) }
        if let problem = fileProblem(fd) { return .failure(LedgerProblem(message: problem)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard flock(fd, LOCK_SH) == 0 else { return .failure(LedgerProblem(message: unreadable)) }
        defer { flock(fd, LOCK_UN) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(LedgerProblem(message: unreadable))
            }
            bytes.append(contentsOf: chunk[0..<n])
        }
        return .success(smsLedgerStates(bytes))
    }

    func record(_ events: [SmsLedgerEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        if let problem = folderProblem(creating: true) { return problem }
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return openProblem(errno) }
        defer { close(fd) }
        if let problem = fileProblem(fd) { return problem }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard flock(fd, LOCK_EX) == 0 else { return unwritable }
        defer { flock(fd, LOCK_UN) }
        var bytes = Array(events.map { smsLedgerLine($0) + "\n" }.joined().utf8)
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

    private func openProblem(_ code: Int32) -> String {
        code == ELOOP ? "The record of sent messages is a symbolic link, which RMNet does not follow (\(url.path))."
            : "The record of sent messages could not be opened (\(url.path))."
    }

    /// "" when the folder is not there and is not to be made.
    private func folderProblem(creating: Bool) -> String? {
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            guard errno == ENOENT else { return "The record of sent messages' folder could not be checked (\(folder.path))." }
            guard creating else { return "" }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return "The record of sent messages' folder could not be made (\(folder.path))."
            }
            guard lstat(folder.path, &info) == 0 else {
                return "The record of sent messages' folder could not be made (\(folder.path))."
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            return "The record of sent messages' folder is not a folder of yours that only you can write (\(folder.path)). "
                + "RMNet does not use it."
        }
        return nil
    }

    private func fileProblem(_ fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return "The record of sent messages could not be checked (\(url.path))." }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            return "The record of sent messages is not a file of yours that only you can read and write (\(url.path)). "
                + "RMNet does not use it."
        }
        return nil
    }
}

/// The ledger in memory (the tests'), shared by the services that are given it, as the file is by processes.
final class SmsSendLedgerMemory: SmsSendLedgerKeeping {
    private let lock = NSLock()
    private(set) var events: [SmsLedgerEvent] = []
    var refuse: String? = nil          // record fails with this sentence
    var loadFailure: String? = nil     // states fails with this sentence

    func states() -> Result<[SmsPartKey: SmsPartState], LedgerProblem> {
        lock.lock()
        defer { lock.unlock() }
        if let loadFailure { return .failure(LedgerProblem(message: loadFailure)) }
        var out: [SmsPartKey: SmsPartState] = [:]
        for e in events { out[e.key] = e.state }
        return .success(out)
    }

    func record(_ new: [SmsLedgerEvent]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let refuse { return refuse }
        events.append(contentsOf: new)
        return nil
    }
}
