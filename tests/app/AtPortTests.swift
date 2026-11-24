// Tests for the answer logic of app/AtPort.swift (AtAnswerCollector): scripted byte sequences, each
// fed whole, byte by byte, and split inside every CR LF. Built with swiftc by `make app-test`; needs
// no Xcode project and no hardware (nothing here opens the port).
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

// The ways the same bytes may arrive in transfers.
func chunkings(_ bytes: [UInt8]) -> [(String, [[UInt8]])] {
    var splitInCRLF: [[UInt8]] = [[]]
    for b in bytes {
        splitInCRLF[splitInCRLF.count - 1].append(b)
        if b == 0x0D { splitInCRLF.append([]) }  // a transfer ends between CR and LF
    }
    return [
        ("whole", [bytes]),
        ("byte by byte", bytes.map { [$0] }),
        ("split inside CR LF", splitInCRLF),
    ]
}

func outcome(_ input: String, echo: String?, prompt: Bool = false, _ chunks: [[UInt8]]) -> AtAnswerCollector.Outcome {
    var c = AtAnswerCollector(echo: echo, prompt: prompt)
    for chunk in chunks { c.feed(chunk) }
    return c.outcome
}

// Feeds `input` in every chunking and expects `want` from each.
func expect(_ input: String, echo: String?, prompt: Bool = false, _ want: AtAnswerCollector.Outcome, _ name: String) {
    for (how, chunks) in chunkings(Array(input.utf8)) {
        let got = outcome(input, echo: echo, prompt: prompt, chunks)
        check(got == want, "\(name) (\(how))", "want \(want), got \(got)")
    }
}

// The result after a payload, fed in every chunking.
func expectAfterPayload(_ input: String, payload: String, _ want: AtAnswerCollector.Outcome, _ name: String) {
    for (how, chunks) in chunkings(Array(input.utf8)) {
        var c = AtAnswerCollector(afterPayload: payload)
        for chunk in chunks { c.feed(chunk) }
        check(c.outcome == want, "\(name) (\(how))", "want \(want), got \(c.outcome)")
    }
}

// Successive answers to the echo probe's "AT", each collected without a gate (as open() does) in
// every chunking; `want` is the probe's step after each answer.
func expectProbe(_ answers: [String], _ want: [AtEchoProbe.Step], _ name: String) {
    for index in 0..<3 {
        var probe = AtEchoProbe()
        var steps: [AtEchoProbe.Step] = []
        var how = ""
        for answer in answers {
            let (h, chunks) = chunkings(Array(answer.utf8))[index]
            how = h
            var c = AtAnswerCollector(echo: nil)
            for chunk in chunks { c.feed(chunk) }
            steps.append(probe.record(c.outcome))
        }
        check(steps == want, "probe: \(name) (\(how))", "want \(want), got \(steps)")
    }
}

@main
struct AtPortTests {
    static func main() {
        // --- an echoed command and its answer -----------------------------------------------------
        expect("AT+CPMS?\r\r\n+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255\r\n+X: second\r\n\r\nOK\r\n",
               echo: "AT+CPMS?", .answer(["+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255", "+X: second"]),
               "echoed command, two-line answer")
        expect("AT\r\r\nOK\r\n", echo: "AT", .answer([]), "echoed command, empty answer")
        expect("AT+CPMS?\r\r\n+CPMS: 1\r\n", echo: "AT+CPMS?", .waiting, "no final result yet")

        // --- the echo is the gate (a late answer of an earlier command) -------------------------------
        let late = "\r\n+CMGS: 5\r\n\r\nOK\r\n"
        let listing = "AT+CMGL=4\r\r\n+CMGL: 1,0,,23\r\n0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B\r\n\r\nOK\r\n"
        expect(late + listing, echo: "AT+CMGL=4",
               .answer(["+CMGL: 1,0,,23", "0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B"]),
               "late +CMGS: 5 / OK before the echo neither ends nor enters the listing")
        expect(late, echo: "AT+CMGL=4", .waiting, "a late OK alone does not end the answer")
        expect("\r\n+CMS ERROR: 500\r\n" + listing.replacingOccurrences(of: "+CMGL: 1,0,,23\r\n", with: ""),
               echo: "AT+CMGL=4",
               .answer(["0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B"]),
               "a late error before the echo is discarded")
        expect("\r\n+CMTI: \"ME\",0\r\nATI\r\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", echo: "ATI",
               .answer(["Quectel", "RM520N-GL"]), "an unsolicited line before the echo is discarded")

        // --- final results are exact lines ---------------------------------------------------------
        expect("AT+X\r\r\n+X: OK then\r\nNO ERROR\r\nOKAY\r\n OK\r\n", echo: "AT+X",
               .answer(["+X: OK then", "NO ERROR", "OKAY"]),
               "OK or ERROR inside other text does not end the answer")
        expect("AT+CMGL=4\r\r\n+CMS ERROR: 500\r\n", echo: "AT+CMGL=4", .modemError("+CMS ERROR: 500"), "+CMS ERROR ends it")
        expect("AT+CPMS?\r\r\n+CME ERROR: 10\r\n", echo: "AT+CPMS?", .modemError("+CME ERROR: 10"), "+CME ERROR ends it")
        expect("AT+X\r\r\nERROR\r\n", echo: "AT+X", .modemError("ERROR"), "ERROR ends it")
        expect("AT\r\r\nOK\r\n+CMTI: \"ME\",1\r\n", echo: "AT", .answer([]), "bytes after the final result are ignored")

        // --- V.250's other final results: each ends the answer as the modem's error line ------------
        // (`RMNet at ATA` with no call: NO CARRIER at once, not a wait for OK until the timeout.)
        for final in ["NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE"] {
            expect("ATA\r\r\n\(final)\r\n", echo: "ATA", .modemError(final), "\(final) ends it")
            expect("ATA\r\r\n+X: 1\r\n\r\n\(final)\r\n", echo: "ATA", .modemError(final),
                   "\(final) after an answer line ends it as an error")
            expect("\r\n\(final)\r\n", echo: nil, .modemError(final), "no echo: \(final) ends it")
            expect("AT+CMGS=23\r\r\n\(final)\r\n", echo: "AT+CMGS=23", prompt: true, .modemError(final),
                   "\(final) instead of the prompt")
            expectAfterPayload("\r\n\(final)\r\n", payload: "0011000B916407281553F80000AA0AE8329BFD4697D9EC37",
                               .modemError(final), "\(final) after a payload")
            expect("\r\n\(final)\r\nATA\r\r\nOK\r\n", echo: "ATA", .answer([]), "a late \(final) before the echo is discarded")
            expect("ATA\r\r\n \(final) \r\n", echo: "ATA", .modemError(final), "\(final) with spaces around it ends it")
            expectProbe(["\r\n\(final)\r\n", "AT\r\r\nOK\r\n", "AT\r\r\nOK\r\n"],
                        [.probeAgain, .probeAgain, .settled(echoes: true)],
                        "a late \(final) before the probe makes it probe again, not fail")
        }
        expect("AT+X\r\r\nNO CARRIERS\r\n+X: BUSY\r\nBUSY LINE\r\nNO ANSWER YET\r\nNO DIALTONE!\r\nNO  CARRIER\r\nno carrier\r\nOK\r\n",
               echo: "AT+X",
               .answer(["NO CARRIERS", "+X: BUSY", "BUSY LINE", "NO ANSWER YET", "NO DIALTONE!", "NO  CARRIER", "no carrier"]),
               "the other final results inside other text, or in another case, do not end the answer")
        // OK, ERROR, +CME ERROR and +CMS ERROR as before.
        for (line, want) in [("OK", AtAnswerCollector.Outcome.answer(["+X: 1"])), ("ERROR", .modemError("ERROR")),
                             ("+CME ERROR: 10", .modemError("+CME ERROR: 10")),
                             ("+CMS ERROR: 500", .modemError("+CMS ERROR: 500"))] {
            expect("AT+X\r\r\n+X: 1\r\n\r\n\(line)\r\nNO CARRIER\r\n", echo: "AT+X", want,
                   "\(line) still ends it; a NO CARRIER after it is ignored")
        }
        check(["NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE", "ERROR", "+CME ERROR: 3", "+CMS ERROR: 500"]
                .allSatisfy(AtAnswerCollector.isErrorResult)
              && !["OK", "CONNECT", "RING", "NO CARRIERS", "+X: BUSY", ""].contains(where: AtAnswerCollector.isErrorResult),
              "isErrorResult: the error final results, and nothing else")

        // --- the prompt ----------------------------------------------------------------------------
        expect("AT+CMGS=23\r\r\n> ", echo: "AT+CMGS=23", prompt: true, .prompt, "prompt after the echo")
        expect("\r\n> ", echo: "AT+CMGS=23", prompt: true, .waiting, "a prompt before the echo is not taken")
        expect("\r\n> \r\nAT+CMGS=23\r\r\n> ", echo: "AT+CMGS=23", prompt: true, .prompt,
               "a stale prompt line, then the echo and the prompt")
        expect("AT+CMGS=23\r\r\n+CMS ERROR: 304\r\n", echo: "AT+CMGS=23", prompt: true,
               .modemError("+CMS ERROR: 304"), "an error instead of the prompt")
        expect("AT+CMGS=23\r\r\nOK\r\n", echo: "AT+CMGS=23", prompt: true, .waiting, "OK is not a prompt")

        // --- the result after the payload: no gate, the payload's echo skipped if it comes ---------
        let pdu = "0011000B916407281553F80000AA0AE8329BFD4697D9EC37"
        expectAfterPayload(pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload echoed whole with Ctrl-Z, then +CMGS: 7, OK")
        expectAfterPayload("\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload not echoed at all")
        expectAfterPayload(String(pdu.prefix(20)) + "\r\n" + String(pdu.dropFirst(20)) + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n",
                           payload: pdu, .answer(["+CMGS: 7"]), "payload echo broken by a line end: the pieces are skipped")
        expectAfterPayload(String(pdu.prefix(9)) + "\r\n" + String(pdu.dropFirst(9).prefix(15)) + "\r\n"
                           + String(pdu.dropFirst(24)) + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n",
                           payload: pdu, .answer(["+CMGS: 7"]), "payload echo in three pieces")
        expectAfterPayload("\r\n+CMTI: \"ME\",0\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu,
                           .answer(["+CMTI: \"ME\",0", "+CMGS: 7"]),
                           "an unsolicited line before +CMGS: 7 is an answer line (the caller looks for +CMGS:)")
        expectAfterPayload("> " + pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload echo on the prompt's line")
        expectAfterPayload(pdu + "\u{1A}\r\n+CMS ERROR: 500\r\n", payload: pdu, .modemError("+CMS ERROR: 500"),
                           "payload echo, then an error")
        expectAfterPayload("\r\n+CMS ERROR: 500\r\n", payload: pdu, .modemError("+CMS ERROR: 500"),
                           "no payload echo, an error")

        // --- a port that does not echo ---------------------------------------------------------------
        expect("\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", echo: nil, .answer(["Quectel", "RM520N-GL"]), "no echo: answer")
        expect("\r\n+CME ERROR: 10\r\n", echo: nil, .modemError("+CME ERROR: 10"), "no echo: error")
        expect("\r\nERROR\r\n", echo: nil, .modemError("ERROR"), "no echo: ERROR")
        expect("\r\n+CMS ERROR: 500\r\n", echo: nil, .modemError("+CMS ERROR: 500"), "no echo: +CMS ERROR")
        expect("\r\n> ", echo: nil, prompt: true, .prompt, "no echo: prompt")

        // --- learning whether the port echoes: two agreeing probes -------------------------------
        let echoAnswer = "AT\r\r\nOK\r\n"
        let silentAnswer = "\r\nOK\r\n"
        expectProbe([echoAnswer], [.probeAgain], "one echo answer does not settle")
        expectProbe([echoAnswer, echoAnswer], [.probeAgain, .settled(echoes: true)], "echo: two agreeing probes")
        expectProbe([silentAnswer, silentAnswer], [.probeAgain, .settled(echoes: false)], "no echo: two agreeing probes")
        expectProbe(["\r\n+CMGS: 5\r\n\r\nOK\r\n" + echoAnswer, echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late +CMGS: 5 / OK before the probe's echo does not settle on no echo")
        expectProbe(["\r\nOK\r\n" + echoAnswer, echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late lone OK before the probe's echo does not settle on no echo")
        expectProbe(["\r\n+CMS ERROR: 500\r\n", echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late +CMS ERROR: 500 before the probe makes it probe again, not fail")
        expectProbe([silentAnswer, echoAnswer, silentAnswer], [.probeAgain, .probeAgain, .probeAgain],
                    "disagreeing probes do not settle")
        expectProbe([echoAnswer, "\r\nERROR\r\n", echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .probeAgain, .settled(echoes: true)],
                    "an answer that does not count breaks the run")
        expectProbe(["AT\r\r\n+X: 1\r\n\r\nOK\r\n", echoAnswer], [.probeAgain, .probeAgain],
                    "an echo with more lines does not count")

        // --- the ESC open() writes first (a modem left at the "> " prompt) -------------------------
        expect("\u{1B}AT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "an echoed ESC on the line of the AT echo: the echo is still found")
        expect("\u{1B}\r\nAT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "an echoed ESC on a line of its own is dropped before the echo")
        expect("> \u{1B}\r\n\r\nOK\r\nAT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "the prompt, the ESC and the modem's OK to it come before the echo and are discarded")
        expectProbe(["\u{1B}AT\r\r\nOK\r\n", echoAnswer], [.probeAgain, .settled(echoes: true)],
                    "an echoed ESC before the first AT echo still counts as an echo")
        expectProbe(["\u{1B}\r\nAT\r\r\nOK\r\n", echoAnswer], [.probeAgain, .settled(echoes: true)],
                    "an echoed ESC on a line of its own is dropped; the AT echo counts")
        expectProbe(["\u{1B}\r\n\r\nOK\r\n", "AT\r\r\nOK\r\n", echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "the modem's OK to the ESC, read as a silent answer, does not settle on no echo")

        // --- unsolicited blocked +CMTI and +CMT deliveries (AtUnsolicitedReader) ------------------
        let cmtHex = "07912120550501F0040B912120550561F400006211223202000A05C8329BFD06" // 8 SMSC + 24 TPDU octets
        let mmsHex = "07912120550501F04404C9320000046211223202000A140605040B8423F0010601BE8C82987478008D90" // 8 SMSC + 34 TPDU octets
        for (how, chunks) in chunkings(Array(("\r\n+CMTI: ,3\r\n\r\n+CMTI: ,-1\r\n").utf8)) {
            var r = AtUnsolicitedReader()
            for chunk in chunks { r.feed(chunk) }
            check(r.takeBlockedFlag(), "unsolicited: +CMTI without storage marks blocked (\(how))")
            check(!r.takeBlockedFlag(), "unsolicited: takeBlockedFlag clears it (\(how))")
        }
        check(AtUnsolicitedReader.isBlockedCmti("+CMTI: ,3")
              && AtUnsolicitedReader.isBlockedCmti("+CMTI: ,-1")
              && AtUnsolicitedReader.isBlockedCmti("+CMTI: \"\",3")
              && AtUnsolicitedReader.isBlockedCmti("+CMTI: \"ME\",-1")
              && !AtUnsolicitedReader.isBlockedCmti("+CMTI: \"ME\",0")
              && !AtUnsolicitedReader.isBlockedCmti("+CMTI: \"SM\",29")
              && !AtUnsolicitedReader.isBlockedCmti("+CMTI: garbage"),
              "isBlockedCmti: empty storage or negative index only")

        let stream = "\r\n+CMT: ,34\r\n\(mmsHex)\r\n\r\n+CMT: \"Alerts, US\",24\r\n^RSSI: 12\r\n\(cmtHex)\r\n"
        for (how, chunks) in chunkings(Array(stream.utf8)) {
            var r = AtUnsolicitedReader()
            for chunk in chunks { r.feed(chunk) }
            let got = r.takeDeliveries()
            check(got == [AtDeliveredPdu(tpduLength: 34, hex: mmsHex), AtDeliveredPdu(tpduLength: 24, hex: cmtHex)],
                  "unsolicited: two +CMT deliveries, alpha with comma and stray URC skipped (\(how))", "\(got)")
            check(r.takeDeliveries().isEmpty && !r.waitingForHex, "unsolicited: cleared after take (\(how))")
        }
        // Wrong length or OK before hex drops the incomplete +CMT header without taking a later PDU.
        var mismatch = AtUnsolicitedReader()
        mismatch.feed(Array("\r\n+CMT: ,99\r\n\(cmtHex)\r\nOK\r\n".utf8))
        check(mismatch.takeDeliveries().isEmpty && !mismatch.waitingForHex,
              "unsolicited: mismatched TPDU length is rejected")

        _ = AtPort.takeRescuedDeliveries()
        check(!AtPort.hasRescuedDeliveries, "rescued: empty at start")
        AtPort.keepRescuedDeliveries([AtDeliveredPdu(tpduLength: 24, hex: cmtHex)])
        check(AtPort.hasRescuedDeliveries, "rescued: recorded")
        check(AtPort.takeRescuedDeliveries() == [AtDeliveredPdu(tpduLength: 24, hex: cmtHex)]
              && !AtPort.hasRescuedDeliveries, "rescued: taken once")

        print("at-test: \(checks) checks passed")
    }
}
