// Tests for app/SmsSendLedger.swift: a part's key (module, SIM, storage, index, raw PDU; none without a module or a SIM),
// the latest state of each part across processes sharing the file, the lines (no IMSI, number or PDU in them; a bad line
// skipped, a tail without its line end), and the file kept only as it should be (made owner-only, a symbolic link or a
// FIFO refused at once, a short write finished). Built with swiftc by `make app-test`; files in a temporary folder.
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

let imsi = "310150123456789"
let pdu = "0001000B912120550501F000000CCD30B9DCAAC341F4329E0E"   // made up: to +12025550100
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func key(_ index: Int, module: String? = "TESTMODULE1", sim: String? = imsi, hex: String = pdu) -> SmsPartKey? {
    SmsPartKey(module: module, imsi: sim, storage: "ME", index: index, hex: hex)
}

func temporaryLedger() -> (SmsSendLedgerFile, URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rmnet-sms-ledger-tests-\(getpid())-\(UUID().uuidString)")
    return (SmsSendLedgerFile(url: base.appendingPathComponent("RMNet/sms-sends.jsonl")), base)
}

extension Result {
    var value: Success? { if case .success(let v) = self { return v } else { return nil } }
}

@main
struct SmsSendLedgerTests {
    static func main() {
        keys()
        states()
        fileSafety()
        print("sms ledger: \(checks) checks passed")
    }

    static func keys() {
        check(key(5, module: nil) == nil && key(5, module: "") == nil, "key: none without a module")
        check(key(5, sim: nil) == nil, "key: none without a SIM")
        check(key(5) == key(5, hex: pdu.lowercased()), "key: the PDU in either case")
        check(key(5) != key(6), "key: another index")
        check(key(5) != key(5, module: "TESTMODULE2"), "key: another module")
        check(key(5) != key(5, sim: "310150987654321"), "key: another SIM")
        var mr = Array(pdu)
        mr.replaceSubrange(4..<6, with: Array("7F"))
        check(key(5) != key(5, hex: String(mr)), "key: another raw PDU (only its message reference differs)")
        check(key(5)?.sim != imsi && key(5)?.pdu != pdu, "key: the IMSI and the PDU are hashed")
    }

    // The latest state of each part, written by one file object and read by another (two processes).
    static func states() {
        let (file, base) = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: base) }
        equal(file.states().value?.count, 0, "states: no file, none")
        guard let k5 = key(5), let k6 = key(6) else { return check(false, "keys") }
        check(file.record([SmsLedgerEvent(time: t0, key: k5, state: .written),
                           SmsLedgerEvent(time: t0, key: k6, state: .written)]) == nil, "states: recorded")
        check(file.record([SmsLedgerEvent(time: t0, key: k5, state: .confirmed)]) == nil, "states: confirmed")
        let other = SmsSendLedgerFile(url: file.url)
        equal(other.states().value?[k5], .confirmed, "states: the latest, read by another")
        equal(other.states().value?[k6], .written, "states: written")
        check(file.record([SmsLedgerEvent(time: t0, key: k5, state: .written)]) == nil, "states: written again")
        equal(other.states().value?[k5], .written, "states: a new write starts it again")
        let text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        check(!text.contains(imsi) && !text.contains(pdu) && !text.contains("2025550100"),
              "states: no IMSI, PDU or number in the file", text)
        // A bad line, a line cut short: skipped; the next event starts on a line of its own.
        if let h = FileHandle(forWritingAtPath: file.url.path) {
            h.seekToEndOfFile()
            h.write(Data("not json\n{\"index\":5,".utf8))
            h.closeFile()
        }
        check(file.record([SmsLedgerEvent(time: t0, key: k6, state: .unknown)]) == nil, "states: after a cut line")
        let after = other.states().value
        check(after?[k6] == .unknown && after?[k5] == .written, "states: bad lines skipped, the rest read",
              "\(String(describing: after))")
        var info = stat()
        check(stat(file.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "file: made 0600")
        check(stat(file.url.deletingLastPathComponent().path, &info) == 0 && info.st_mode & 0o777 == 0o700,
              "file: its folder made 0700")
        // A short write is finished.
        var calls = 0
        let short = SmsSendLedgerFile(url: file.url, write: { fd, buf, n in
            calls += 1
            return Darwin.write(fd, buf, min(n, 7))
        })
        check(short.record([SmsLedgerEvent(time: t0, key: k6, state: .confirmed)]) == nil && calls > 1,
              "file: short writes finished")
        equal(other.states().value?[k6], .confirmed, "file: read back after short writes")
    }

    // A symbolic link or a FIFO where the file should be, a file others can read, a folder others can write: refused.
    static func fileSafety() {
        let fm = FileManager.default
        let (file, base) = temporaryLedger()
        defer { try? fm.removeItem(at: base) }
        let folder = file.url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let k = key(1) else { return check(false, "key") }

        let target = base.appendingPathComponent("elsewhere.txt")
        fm.createFile(atPath: target.path, contents: Data("keep\n".utf8), attributes: [.posixPermissions: 0o600])
        try? fm.createSymbolicLink(at: file.url, withDestinationURL: target)
        check(file.record([SmsLedgerEvent(time: t0, key: k, state: .confirmed)])?.contains("symbolic link") == true,
              "safety: a symbolic link refused")
        check(file.states().failureMessage?.contains("symbolic link") == true, "safety: read through one refused")
        equal(try? String(contentsOf: target, encoding: .utf8), "keep\n", "safety: the other file untouched")
        try? fm.removeItem(at: file.url)

        check(mkfifo(file.url.path, 0o600) == 0, "safety: a FIFO made")
        let done = DispatchSemaphore(value: 0)
        var read: Result<[SmsPartKey: SmsPartState], LedgerProblem>? = nil
        var wrote: String? = nil
        DispatchQueue.global().async {
            read = file.states()
            wrote = file.record([SmsLedgerEvent(time: t0, key: k, state: .confirmed)])
            done.signal()
        }
        check(done.wait(timeout: .now() + 3) == .success, "safety: a FIFO is not waited on")
        check(read?.failureMessage?.contains("not a file of yours") == true && wrote?.contains("not a file of yours") == true,
              "safety: a FIFO refused")
        try? fm.removeItem(at: file.url)

        fm.createFile(atPath: file.url.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        check(file.record([SmsLedgerEvent(time: t0, key: k, state: .confirmed)])?.contains("not a file of yours") == true,
              "safety: a file others can read refused")
        try? fm.removeItem(at: file.url)
        chmod(folder.path, 0o777)
        check(file.record([SmsLedgerEvent(time: t0, key: k, state: .confirmed)])?.contains("not a folder of yours") == true,
              "safety: a folder others can write refused")
        chmod(folder.path, 0o700)
    }
}

extension Result where Failure == LedgerProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message } else { return nil } }
}
