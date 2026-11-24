// Tests for app/ModemNetwork.swift: reading the modem's AT answers (radio, registration, operator,
// serving cell, carriers, network mode) and what the window and `RMNet network` say about them.
// The fixtures are the modem's real answers (2026-11-15, firmware RM520NGLAAR03A04M4G_01.204.01.204).
// Built with swiftc by `make app-test`; needs no Xcode project and no hardware.
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

// --- the modem's answers ------------------------------------------------------------------------
let cfun = ["+CFUN: 1"]
let cops = ["+COPS: 0,0,\"CHINA MOBILE\",11"]
let qspn = ["+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""]
let c5greg = ["+C5GREG: 0,1"]
let cereg = ["+CEREG: 0,0"]
let cgreg = ["+CGREG: 0,0"]
let creg = ["+CREG: 0,0"]
let sa = ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"]
let qcainfo = ["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32",
               "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]
let modePref = ["+QNWPREFCFG: \"mode_pref\",AUTO"]
let nr5gDisable = ["+QNWPREFCFG: \"nr5g_disable_mode\",0"]
// EN-DC (5G NSA): three lines; the NR line has SINR before RSRQ.
let endc = ["+QENG: \"servingcell\",\"CONNECT\"",
            "+QENG: \"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,5,3,2B3C,-98,-11,-68,14,8,230,52",
            "+QENG: \"NR5G-NSA\",460,00,513,-90,15,-11,627264,78,12,1"]

let saLeg = CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: 32,
                    tac: "1A2B3C", channel: 504990, band: "n41", bandwidthMHz: 100, rsrp: -95, rsrq: -10, sinr: 8,
                    scsKHz: 30)
let lteLeg = CellLeg(rat: "LTE", duplex: "FDD", mcc: "460", mnc: "00", cellID: "1C2D3E4", pci: 128, tac: "2B3C",
                     channel: 1300, band: "B3", bandwidthMHz: 10, rsrp: -98, rsrq: -11, sinr: 8)
let nsaLeg = CellLeg(rat: "NR5G-NSA", duplex: nil, mcc: "460", mnc: "00", cellID: nil, pci: 513, tac: nil,
                     channel: 627264, band: "n78", bandwidthMHz: 100, rsrp: -90, rsrq: -11, sinr: 15, scsKHz: 30)

// Every read above combined, as the service puts them together (R1: plmn only from AT+QSPN).
func combined(radio: [String] = cfun, fiveG: [String] = c5greg, eps: [String] = cereg, ps: [String] = cgreg,
              cs: [String] = creg, cops: [String] = cops, qspn: [String] = qspn, qeng: [String] = sa,
              qcainfo: [String] = qcainfo, mode: [String] = modePref, nr5g: [String] = nr5gDisable) -> NetworkInfo {
    var info = NetworkInfo()
    info.radio = parseRadio(radio)
    info.registration = summarizeRegistration(fiveG: parseRegistrationStat(fiveG, prefix: "+C5GREG"),
                                              eps: parseRegistrationStat(eps, prefix: "+CEREG"),
                                              ps: parseRegistrationStat(ps, prefix: "+CGREG"),
                                              cs: parseRegistrationStat(cs, prefix: "+CREG"))
    let op = parseOperator(cops)
    info.operatorName = op.name
    info.accessTechnology = op.accessTechnology
    let sp = parseServiceProvider(qspn)
    info.networkName = sp.fullName
    info.plmn = sp.plmn
    info.serving = parseServingCell(qeng)
    info.carriers = parseCarriers(qcainfo)
    info.carrierComponents = parseCarrierComponents(qcainfo)
    info.mode = parseModePreference(mode)
    info.nr5gDisable = parseNr5gDisable(nr5g)
    return info
}

func rowsText(_ rows: [(label: String, value: String)]) -> String {
    rows.map { "\($0.label): \($0.value)" }.joined(separator: " | ")
}

func expectRows(_ info: NetworkInfo, _ want: [(String, String)], _ name: String) {
    let got = networkRows(info)
    let same = got.count == want.count && zip(got, want).allSatisfy { $0.label == $1.0 && $0.value == $1.1 }
    check(same, "networkRows: \(name)", "want \(rowsText(want.map { (label: $0.0, value: $0.1) }))\n  got  \(rowsText(got))")
}

func value(_ info: NetworkInfo, _ label: String) -> String? {
    networkRows(info).first(where: { $0.label == label })?.value
}

// The JSON as a script reads it: serialized and parsed back.
func roundTrip(_ object: [String: Any], _ name: String) -> [String: Any] {
    check(JSONSerialization.isValidJSONObject(object), "networkJSON: \(name) is a valid JSON object", "\(object)")
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let back = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "networkJSON: \(name) survives a JSONSerialization round trip")
        return [:]
    }
    return back
}

let jsonKeys: Set<String> = ["radio", "registration", "roaming", "operator", "networkName", "plmn", "technology",
                             "state", "cells", "carriers", "carrierComponents", "mode", "nr5gDisableMode"]
let cellKeys: Set<String> = ["rat", "duplex", "mcc", "mnc", "cellId", "pci", "tac", "channel", "band",
                             "bandwidthMHz", "scsKHz", "rsrp", "rsrq", "sinr"]

@main
struct ModemNetworkTests {
    static func main() {
        // --- atFields --------------------------------------------------------------------------
        check(atFields("+QSPN: \"a,b\",1", prefix: "+QSPN") == ["a,b", "1"], "atFields: a quoted comma stays in its field",
              "\(String(describing: atFields("+QSPN: \"a,b\",1", prefix: "+QSPN")))")
        check(atFields("+CGDCONT: 1,\"IPV4V6\",\"\",x,,", prefix: "+CGDCONT") == ["1", "IPV4V6", "", "x", "", ""],
              "atFields: empty fields stay empty",
              "\(String(describing: atFields("+CGDCONT: 1,\"IPV4V6\",\"\",x,,", prefix: "+CGDCONT")))")
        check(atFields("+CEREG: 0,1", prefix: "+CREG") == nil, "atFields: another prefix gives nil")
        check(atFields("+CREGX: 0,1", prefix: "+CREG") == nil, "atFields: a longer name is another prefix")
        check(atFields("OK", prefix: "+CFUN") == nil, "atFields: OK is not an answer line")
        check(atFields("+CFUN:1", prefix: "+CFUN") == ["1"], "atFields: no space after the colon")
        check(atFields("+COPS: 0 , 0 ,\"CHINA MOBILE\" , 11", prefix: "+COPS") == ["0", "0", "CHINA MOBILE", "11"],
              "atFields: each field trimmed")
        check(atFields("+QICSGP: 1,\" a b \",0", prefix: "+QICSGP") == ["1", " a b ", "0"],
              "atFields: spaces inside quotes are kept",
              "\(String(describing: atFields("+QICSGP: 1,\" a b \",0", prefix: "+QICSGP")))")
        check(atFields("+QSPN: \"a,b", prefix: "+QSPN") == ["a,b"], "atFields: an unclosed quote runs to the end")
        // Quotes are found by Unicode scalar: a quote that a combining mark, a ZWJ or a Prepend character
        // joins into one Character is still a quote, and the fields split where the modem split them.
        for (line, want, name) in [
            ("+COPS: 0,0,\"\u{301}X\",7", ["0", "0", "\u{301}X", "7"], "a combining mark after the opening quote"),
            ("+COPS: 0,0,\"\u{301}A,9\",7", ["0", "0", "\u{301}A,9", "7"], "a combining mark, then a quoted comma"),
            ("+COPS: 0,0,\"X\"\u{200D},7", ["0", "0", "X\u{200D}", "7"], "a ZWJ after the closing quote"),
            ("+COPS: 0,0,\"X\u{0600}\",7", ["0", "0", "X\u{0600}", "7"], "a Prepend character before the closing quote"),
            ("+QICSGP: 1,\"\u{301}a,b\",\"\u{301}\",0", ["1", "\u{301}a,b", "\u{301}", "0"], "combining marks in an APN and a user"),
        ] {
            let got = atFields(line, prefix: String(line.prefix(while: { $0 != ":" })))
            check(got == want, "atFields: \(name)", "\(String(describing: got?.map { $0.unicodeScalars.map { String($0.value, radix: 16) } }))")
        }
        let marked = parseOperator(["+COPS: 0,0,\"\u{301}A,9\",7"])
        check(marked.name == "\u{301}A,9" && marked.accessTechnology == 7,
              "parseOperator: a combining mark after the quote neither splits the name nor makes up an AcT", "\(marked)")

        // --- parseRadio ------------------------------------------------------------------------
        check(parseRadio(cfun) == .on, "parseRadio: 1 is on")
        check(parseRadio(["+CFUN: 4"]) == .airplane, "parseRadio: 4 is airplane")
        check(parseRadio(["+CFUN: 0"]) == .minimum, "parseRadio: 0 is minimum")
        check(parseRadio(["+CFUN: 7"]) == .other(7), "parseRadio: 7 is other(7)")
        check(parseRadio([]) == nil, "parseRadio: no line gives nil")
        check(parseRadio(["+CFUN: x"]) == nil, "parseRadio: not a number gives nil")

        // --- registration ----------------------------------------------------------------------
        check(parseRegistrationStat(c5greg, prefix: "+C5GREG") == 1, "parseRegistrationStat: C5GREG 1")
        check(parseRegistrationStat(cereg, prefix: "+CEREG") == 0, "parseRegistrationStat: CEREG 0")
        check(parseRegistrationStat(["+CEREG: 2,5,\"2B3C\",\"1C2D3E4\",7"], prefix: "+CEREG") == 5,
              "parseRegistrationStat: the stat is the second field, with location fields after it")
        check(parseRegistrationStat(cereg, prefix: "+CREG") == nil, "parseRegistrationStat: another prefix gives nil")
        check(parseRegistrationStat(["+CREG: 0"], prefix: "+CREG") == nil, "parseRegistrationStat: no stat gives nil")
        check(parseRegistrationStat([], prefix: "+CREG") == nil, "parseRegistrationStat: no line gives nil")
        check(parseRegistrationStat(["+CREG: 0,-"], prefix: "+CREG") == nil, "parseRegistrationStat: - gives nil")

        check(summarizeRegistration(fiveG: 1, eps: 0, ps: 0, cs: 0) == Registration(status: .home, domain: "5GS"), "SA home")
        check(summarizeRegistration(fiveG: nil, eps: 5, ps: nil, cs: 1) == Registration(status: .roaming, domain: "EPS"), "roaming")
        check(summarizeRegistration(fiveG: 2, eps: 1, ps: 0, cs: 0) == Registration(status: .home, domain: "EPS"),
              "summarizeRegistration: registered beats an earlier searching")
        check(summarizeRegistration(fiveG: 0, eps: 0, ps: 1, cs: 5) == Registration(status: .home, domain: "PS"),
              "summarizeRegistration: the first registered domain in the order 5GS, EPS, PS, CS")
        check(summarizeRegistration(fiveG: 0, eps: 2, ps: 3, cs: 0) == Registration(status: .searching, domain: "EPS"),
              "summarizeRegistration: searching beats denied")
        check(summarizeRegistration(fiveG: 8, eps: 3, ps: 0, cs: 0) == Registration(status: .denied, domain: "EPS"),
              "summarizeRegistration: denied beats emergency only")
        check(summarizeRegistration(fiveG: 0, eps: 8, ps: nil, cs: nil) == Registration(status: .emergencyOnly, domain: "EPS"),
              "summarizeRegistration: emergency only")
        check(summarizeRegistration(fiveG: 0, eps: 4, ps: 0, cs: 0) == Registration(status: .notRegistered, domain: ""),
              "summarizeRegistration: 0 and 4 read give not registered")
        check(summarizeRegistration(fiveG: nil, eps: nil, ps: nil, cs: 4) == Registration(status: .notRegistered, domain: ""),
              "summarizeRegistration: one 4 read gives not registered")
        check(summarizeRegistration(fiveG: nil, eps: nil, ps: nil, cs: nil) == nil, "summarizeRegistration: nothing read gives nil")

        // --- operator --------------------------------------------------------------------------
        let op = parseOperator(cops)
        check(op.name == "CHINA MOBILE" && op.accessTechnology == 11, "parseOperator: the fixture", "\(op)")
        let bare = parseOperator(["+COPS: 0"])
        check(bare.name == nil && bare.accessTechnology == nil, "parseOperator: +COPS: 0 gives no name and no AcT", "\(bare)")
        let noAct = parseOperator(["+COPS: 0,0,\"CMCC\""])
        check(noAct.name == "CMCC" && noAct.accessTechnology == nil, "parseOperator: no AcT", "\(noAct)")
        check(parseOperator([]).name == nil, "parseOperator: no line")
        let rlo = parseOperator(["+COPS: 0,0,\"EVIL\u{202E}OP\",7"])
        check(rlo.name == "EVIL\u{FFFD}OP" && rlo.accessTechnology == 7, "parseOperator: U+202E becomes U+FFFD", "\(rlo)")
        // Control characters and bidirectional controls (and the line separators and Arabic letter mark,
        // which also reorder or break what is shown) each become U+FFFD.
        for (unsafe, label) in [("\u{0}", "NUL"), ("\u{1B}", "ESC"), ("\u{7F}", "DEL"), ("\u{85}", "C1 NEL"),
                                ("\u{9B}", "C1 CSI"), ("\u{200E}", "LRM"), ("\u{200F}", "RLM"), ("\u{202A}", "LRE"),
                                ("\u{202D}", "LRO"), ("\u{2066}", "LRI"), ("\u{2069}", "PDI"), ("\u{061C}", "ALM"),
                                ("\u{2028}", "LS"), ("\u{2029}", "PS")] {
            let name = parseOperator(["+COPS: 0,0,\"A\(unsafe)B\",7"]).name
            check(name == "A\u{FFFD}B", "parseOperator: \(label) becomes U+FFFD",
                  "\(String(describing: name?.unicodeScalars.map { String($0.value, radix: 16) }))")
        }
        check(parseOperator(["+COPS: 0,0,\"Telefónica 中国 \u{1F4F6}\",7"]).name == "Telefónica 中国 \u{1F4F6}",
              "parseOperator: other text is kept")

        // --- service provider (AT+QSPN) --------------------------------------------------------
        check(parseServiceProvider(qspn) == ("中国移动", "46000"), "parseServiceProvider: UCS-2 name and PLMN",
              "\(parseServiceProvider(qspn))")
        check(parseServiceProvider(["+QSPN: \"CMCC\",\"CMCC\",\"\",0,\"46000\""]) == ("CMCC", "46000"),
              "parseServiceProvider: alphabet 0 keeps the name as given")
        check(parseServiceProvider(["+QSPN: \"4E2\",\"\",\"\",1,\"46000\""]) == ("4E2", "46000"),
              "parseServiceProvider: odd-length hex is kept as given")
        check(parseServiceProvider(["+QSPN: \"4E2D56\",\"\",\"\",1,\"46000\""]) == ("4E2D56", "46000"),
              "parseServiceProvider: hex that is not whole UCS-2 characters is kept as given")
        check(parseServiceProvider(["+QSPN: \"CMCC\",\"\",\"\",1,\"46000\""]) == ("CMCC", "46000"),
              "parseServiceProvider: not hex is kept as given")
        check(parseServiceProvider(["+QSPN: \"D800\",\"\",\"\",1,\"46000\""]) == ("D800", "46000"),
              "parseServiceProvider: a lone surrogate is not valid UCS-2, kept as given")
        check(parseServiceProvider(["+QSPN: \"0041202E0042\",\"\",\"\",1,\"46000\""]) == ("A\u{FFFD}B", "46000"),
              "parseServiceProvider: a decoded U+202E becomes U+FFFD", "\(parseServiceProvider(["+QSPN: \"0041202E0042\",\"\",\"\",1,\"46000\""]))")
        check(parseServiceProvider(["+QSPN: \"\",\"\",\"\",0,\"46000\""]) == (nil, "46000"),
              "parseServiceProvider: an empty name gives nil")
        check(parseServiceProvider(["+QSPN: \"\",\"\",\"\",1,\"\""]) == (nil, nil),
              "parseServiceProvider: empty name and PLMN give nil")
        check(parseServiceProvider([]) == (nil, nil), "parseServiceProvider: a bare OK gives (nil, nil)")
        check(parseServiceProvider(["+QSPN: \"CMCC\""]) == ("CMCC", nil), "parseServiceProvider: a short line")

        // --- serving cell ----------------------------------------------------------------------
        check(parseServingCell(sa) != nil, "SA: parsed")
        let cell = parseServingCell(sa)!
        check(cell.state == "NOCONN" && cell.cells.count == 1, "SA: one leg", "\(cell)")
        check(cell.cells.first == saLeg, "SA leg", "\(cell.cells)")

        let nsa = parseServingCell(endc)
        check(nsa?.state == "CONNECT" && nsa?.cells.count == 2, "EN-DC: state and two legs", "\(String(describing: nsa))")
        check(nsa?.cells.first == lteLeg, "EN-DC: the LTE leg (band B3, EARFCN 1300, 10 MHz, SINR 14 × 2 − 20)",
              "\(String(describing: nsa?.cells.first))")
        check(nsa?.cells.last == nsaLeg, "EN-DC: the NR leg (SINR before RSRQ)", "\(String(describing: nsa?.cells.last))")

        check(parseServingCell(["+QENG: \"servingcell\",\"SEARCH\""]) == ServingCell(state: "SEARCH", cells: []), "searching")
        check(parseServingCell(["+QENG: \"servingcell\",\"LIMSRV\""]) == ServingCell(state: "LIMSRV", cells: []), "limited service")
        check(parseServingCell([]) == nil, "parseServingCell: no line gives nil")
        check(parseServingCell(["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32"]) == nil,
              "parseServingCell: no +QENG line gives nil")

        let truncated = parseServingCell(["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32"])
        check(truncated?.cells == [CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: 32,
                                           tac: nil, channel: nil, band: nil, bandwidthMHz: nil, rsrp: nil, rsrq: nil, sinr: nil)],
              "parseServingCell: a line cut after <PCID> leaves the rest nil", "\(String(describing: truncated))")

        let dashes = parseServingCell(["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,-,-,,x,99,-,,abc,1,-"])
        check(dashes?.cells == [CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: nil,
                                        tac: nil, channel: nil, band: nil, bandwidthMHz: nil, rsrp: nil, rsrq: nil, sinr: nil,
                                        scsKHz: 30)],
              "parseServingCell: -, empty, not a number and an unknown bandwidth code give nil", "\(String(describing: dashes))")

        let extra = parseServingCell([sa[0] + ",7,8,\"x\",9"])
        check(extra == cell, "parseServingCell: extra fields are ignored", "\(String(describing: extra))")

        for odd in ["nan", "inf", "-infinity", "0x10"] {
            let line = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,\(odd),1,-"
            let leg = parseServingCell([line])?.cells.first
            check(leg != nil && leg?.sinr == nil, "parseServingCell: SINR \(odd) is not a number", "\(String(describing: leg))")
        }
        // A raw LTE SINR that is finite but whose dB (× 2 − 20) is not: the SINR is nil, the JSON stays valid.
        let hugeLine = "+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,5,3,2B3C,-98,-11,-68,"
            + String(repeating: "9", count: 308) + ",8,230,52"
        let hugeLeg = parseServingCell([hugeLine])?.cells.first
        check(hugeLeg != nil && hugeLeg?.sinr == nil && hugeLeg?.rsrp == -98 && hugeLeg?.rsrq == -11,
              "parseServingCell: an LTE SINR whose conversion is not finite is nil", "\(String(describing: hugeLeg))")
        let hugeInfo = combined(qeng: [hugeLine])
        check(JSONSerialization.isValidJSONObject(networkJSON(hugeInfo)), "networkJSON: valid with a huge raw LTE SINR")
        check(value(hugeInfo, "Signal") == "RSRP -98 dBm, RSRQ -11 dB", "networkRows: no SINR inf dB",
              "\(String(describing: value(hugeInfo, "Signal")))")

        let lte = parseServingCell(["+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,5,3,2B3C,-98,-11,-68,14,8,230,52"])
        check(lte == ServingCell(state: "CONNECT", cells: [lteLeg]), "parseServingCell: LTE on one line", "\(String(describing: lte))")
        let lteWide = parseServingCell(["+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"TDD\",460,00,1C2D3E4,128,38950,41,0,5,2B3C,-98,-11,-68,-,8,230,52"])
        check(lteWide?.cells.first?.bandwidthMHz == 20 && lteWide?.cells.first?.band == "B41" && lteWide?.cells.first?.sinr == nil,
              "parseServingCell: LTE bandwidth code 5 is 20 MHz; SINR - is nil", "\(String(describing: lteWide))")
        let lteNarrow = parseServingCell(["+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,0,0,2B3C,-98,-11,-68,0,8,230,52"])
        check(lteNarrow?.cells.first?.bandwidthMHz == 1.4 && lteNarrow?.cells.first?.sinr == -20,
              "parseServingCell: LTE bandwidth code 0 is 1.4 MHz; raw SINR 0 is -20 dB", "\(String(describing: lteNarrow))")

        let wcdmaLine = "+QENG: \"servingcell\",\"NOCONN\",\"WCDMA\",460,01,5A2B,1234567,10700,123,1,-80,-6,-,-,-,-,-"
        let wcdmaLeg = CellLeg(rat: "WCDMA", duplex: nil, mcc: "460", mnc: "01", cellID: "1234567", pci: 123, tac: "5A2B",
                               channel: 10700, band: nil, bandwidthMHz: nil, rsrp: -80, rsrq: nil, sinr: nil)
        let wcdma = parseServingCell([wcdmaLine])
        check(wcdma == ServingCell(state: "NOCONN", cells: [wcdmaLeg]),
              "parseServingCell: WCDMA (LAC as TAC, PSC as PCI, RSCP as RSRP)", "\(String(describing: wcdma))")

        let unknownRat = parseServingCell(["+QENG: \"servingcell\",\"NOCONN\",\"GSM\",460,00,1,2,3"])
        check(unknownRat == ServingCell(state: "NOCONN", cells: [CellLeg(rat: "GSM", duplex: nil, mcc: nil, mnc: nil, cellID: nil,
                                                                         pci: nil, tac: nil, channel: nil, band: nil,
                                                                         bandwidthMHz: nil, rsrp: nil, rsrq: nil, sinr: nil)]),
              "parseServingCell: another RAT keeps its name and invents no field", "\(String(describing: unknownRat))")

        // --- carriers --------------------------------------------------------------------------
        check(parseCarriers(["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32", "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]) == ["n41", "n28"], "carriers")
        check(parseCarriers(["+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-",
                             "+QCAINFO: \"SCC\",100,3,\"LTE BAND 1\",1,6,0,-,-",
                             "+QCAINFO: \"PCC\",1300,75,\"LTE BAND 3\",1,128,-98,-11,-68,14"]) == ["B3", "n28", "B1"],
              "parseCarriers: PCC first, then SCC lines in order")
        check(parseCarriers(["+QCAINFO: \"PCC\",10700,0,\"WCDMA BAND 1\",1"]) == ["WCDMA BAND 1"],
              "parseCarriers: another text kept as given")
        check(parseCarriers(["+QCAINFO: \"PCC\",504990,12"]) == [], "parseCarriers: a line without a band")
        check(parseCarriers([]) == [], "parseCarriers: no line")

        // --- mode ------------------------------------------------------------------------------
        check(parseModePreference(modePref) == "AUTO", "parseModePreference: AUTO")
        check(parseModePreference(["+QNWPREFCFG: \"mode_pref\",LTE:NR5G"]) == "LTE:NR5G", "parseModePreference: LTE:NR5G")
        check(parseModePreference(nr5gDisable) == nil, "parseModePreference: another setting gives nil")
        check(parseModePreference([]) == nil, "parseModePreference: no line")
        check(parseNr5gDisable(nr5gDisable) == 0, "parseNr5gDisable: 0")
        check(parseNr5gDisable(["+QNWPREFCFG: \"nr5g_disable_mode\",1"]) == 1, "parseNr5gDisable: 1")
        check(parseNr5gDisable(modePref) == nil, "parseNr5gDisable: another setting gives nil")
        check(parseNr5gDisable([]) == nil, "parseNr5gDisable: no line")

        // --- technologyLabel -------------------------------------------------------------------
        let saInfo = combined()
        let endcInfo = combined(fiveG: ["+C5GREG: 0,0"], eps: ["+CEREG: 0,1"], cops: ["+COPS: 0,0,\"CHINA MOBILE\",13"],
                                qeng: endc,
                                qcainfo: ["+QCAINFO: \"PCC\",1300,75,\"LTE BAND 3\",1,128,-98,-11,-68,14",
                                          "+QCAINFO: \"SCC\",627264,12,\"NR5G BAND 78\",1,513,-90,-11,15"])
        func withServing(_ s: ServingCell?, act: Int? = nil, radio: RadioState? = .on) -> NetworkInfo {
            var i = NetworkInfo()
            i.serving = s
            i.accessTechnology = act
            i.radio = radio
            return i
        }
        check(technologyLabel(saInfo) == "5G SA", "technologyLabel: NR5G-SA leg")
        check(technologyLabel(endcInfo) == "5G NSA", "technologyLabel: NR5G-NSA leg")
        check(technologyLabel(withServing(ServingCell(state: "CONNECT", cells: [lteLeg]))) == "LTE", "technologyLabel: LTE alone")
        check(technologyLabel(withServing(ServingCell(state: "NOCONN", cells: [wcdmaLeg]))) == "WCDMA", "technologyLabel: WCDMA")
        check(technologyLabel(withServing(ServingCell(state: "SEARCH", cells: []), act: 11)) == "searching", "technologyLabel: SEARCH")
        check(technologyLabel(withServing(ServingCell(state: "LIMSRV", cells: []))) == "limited service", "technologyLabel: LIMSRV")
        check(technologyLabel(withServing(ServingCell(state: "NOCONN", cells: []), act: 7)) == "LTE",
              "technologyLabel: no legs in another state falls back to the AcT")
        for (act, want) in [(11, "5G SA"), (12, "5G SA"), (13, "5G NSA"), (7, "LTE"), (10, "LTE (5G core)"), (2, "WCDMA"),
                            (4, "WCDMA"), (5, "WCDMA"), (6, "WCDMA"), (0, "unknown"), (3, "unknown")] {
            let got = technologyLabel(withServing(nil, act: act))
            check(got == want, "technologyLabel: no serving cell, AcT \(act)", "want \(want), got \(got)")
        }
        check(technologyLabel(withServing(nil, act: nil)) == "unknown", "technologyLabel: nothing read")
        check(technologyLabel(NetworkInfo()) == "unknown", "technologyLabel: empty info")
        var airplane = saInfo
        airplane.radio = .airplane
        check(technologyLabel(airplane) == "none (radio off)", "technologyLabel: airplane whatever else was read")
        check(technologyLabel(withServing(nil, act: 11, radio: .airplane)) == "none (radio off)", "technologyLabel: airplane over AcT")

        // --- words -----------------------------------------------------------------------------
        check(registrationWords(Registration(status: .home, domain: "5GS")) == "registered, home network (5GS)", "registrationWords: home")
        check(registrationWords(Registration(status: .roaming, domain: "EPS")) == "registered, roaming (EPS)", "registrationWords: roaming")
        check(registrationWords(Registration(status: .searching, domain: "EPS")) == "searching", "registrationWords: searching")
        check(registrationWords(Registration(status: .denied, domain: "EPS")) == "registration denied", "registrationWords: denied")
        check(registrationWords(Registration(status: .emergencyOnly, domain: "EPS")) == "emergency services only",
              "registrationWords: emergency only")
        check(registrationWords(Registration(status: .notRegistered, domain: "")) == "not registered", "registrationWords: not registered")
        check(registrationWords(Registration(status: .unknown, domain: "")) == "unknown", "registrationWords: unknown")
        check(registrationWords(nil) == "unknown", "registrationWords: nil")

        check(modeWords("AUTO") == "automatic (5G, LTE and WCDMA)", "modeWords: AUTO")
        check(modeWords("NR5G") == "5G only", "modeWords: NR5G")
        check(modeWords("LTE") == "LTE only", "modeWords: LTE")
        check(modeWords("LTE:NR5G") == "5G and LTE", "modeWords: LTE:NR5G")
        check(modeWords("WCDMA") == "WCDMA only", "modeWords: WCDMA")
        check(modeWords("WCDMA:LTE") == "WCDMA and LTE", "modeWords: another mode, its RATs joined")
        check(modeWords("WCDMA:LTE:NR5G") == "WCDMA and LTE and NR5G", "modeWords: three RATs joined")
        // Any order of the same RATs reads the same (compared by canonicalMode), so the window's menu never
        // shows one mode twice.
        for (mode, words) in [("NR5G:LTE", "5G and LTE"), ("LTE:WCDMA", "WCDMA and LTE"), ("NR5G:LTE:WCDMA", "WCDMA and LTE and NR5G"),
                              ("NR5G:WCDMA", "WCDMA and NR5G"), ("GSM:LTE", "GSM and LTE"), ("LTE:LTE", "LTE and LTE")] {
            check(modeWords(mode) == words, "modeWords: \(mode) reads \(words)", modeWords(mode))
        }
        for (a, b, same) in [("NR5G:LTE", "LTE:NR5G", true), ("LTE:NR5G", "LTE:NR5G", true), ("WCDMA:LTE", "LTE:WCDMA", true),
                             ("AUTO", "AUTO", true), ("LTE", "NR5G", false), ("LTE:NR5G", "NR5G", false),
                             ("GSM:LTE", "GSM:LTE", true), ("GSM:LTE", "LTE:GSM", false), ("AUTO", "WCDMA:LTE:NR5G", false)] {
            check(sameMode(a, b) == same && sameMode(b, a) == same, "sameMode: \(a) and \(b): \(same)")
        }

        // --- networkRows -----------------------------------------------------------------------
        expectRows(saInfo, [
            ("Registration", "registered, home network (5GS)"),
            ("Operator", "CHINA MOBILE (中国移动), PLMN 46000"),
            ("Technology", "5G SA (TDD)"),
            ("Band", "n41 + n28 (carrier aggregation)"),
            ("Signal", "RSRP -95 dBm, RSRQ -10 dB, SINR 8 dB"),
            ("Cell", "PCI 32, cell ID 123456789, TAC 1A2B3C"),
            ("Channel", "ARFCN 504990, 100 MHz, SCS 30 kHz"),
            ("Connection", "idle"),
            ("Radio", "on"),
            ("Network mode", "automatic (5G, LTE and WCDMA)"),
        ], "the SA fixture")

        let endcRows: [(String, String)] = [
            ("Registration", "registered, home network (EPS)"),
            ("Operator", "CHINA MOBILE (中国移动), PLMN 46000"),
            ("Technology", "5G NSA (LTE FDD + 5G)"),
            ("Band", "B3 + n78"),
            ("Signal (LTE)", "RSRP -98 dBm, RSRQ -11 dB, SINR 8 dB"),
            ("Signal (5G)", "RSRP -90 dBm, RSRQ -11 dB, SINR 15 dB"),
            ("Cell (LTE)", "PCI 128, cell ID 1C2D3E4, TAC 2B3C"),
            ("Cell (5G)", "PCI 513"),
            ("Channel (LTE)", "EARFCN 1300, 10 MHz"),
            ("Channel (5G)", "ARFCN 627264, 100 MHz, SCS 30 kHz"),
            ("Connection", "connected"),
            ("Radio", "on"),
            ("Network mode", "automatic (5G, LTE and WCDMA)"),
        ]
        expectRows(endcInfo, endcRows, "the EN-DC fixture (LTE PCC and NR SCC are dual connectivity, not aggregation)")
        expectRows(combined(fiveG: ["+C5GREG: 0,0"], eps: ["+CEREG: 0,1"], cops: ["+COPS: 0,0,\"CHINA MOBILE\",13"],
                            qeng: endc, qcainfo: []),
                   endcRows, "the EN-DC fixture without AT+QCAINFO: bands from the legs")
        let lteCA = combined(qeng: endc, qcainfo: ["+QCAINFO: \"PCC\",1300,75,\"LTE BAND 3\",1",
                                                   "+QCAINFO: \"SCC\",100,75,\"LTE BAND 1\",1"])
        check(value(lteCA, "Band") == "B3 + B1 + n78 (carrier aggregation)",
              "networkRows: two LTE carriers are aggregation; the NR leg's band is added", "\(String(describing: value(lteCA, "Band")))")

        // Operator
        let sameName = combined(qspn: ["+QSPN: \"China Mobile\",\"\",\"\",0,\"46000\""])
        check(value(sameName, "Operator") == "CHINA MOBILE, PLMN 46000",
              "networkRows: no parenthesis when the network name equals the operator ignoring case",
              "\(String(describing: value(sameName, "Operator")))")
        let noQspn = combined(qspn: [])
        check(value(noQspn, "Operator") == "CHINA MOBILE, PLMN 46000",
              "networkRows: without AT+QSPN, no parenthesis and the PLMN from the first leg (R1)",
              "\(String(describing: value(noQspn, "Operator")))")
        let noPlmn = combined(qspn: [], qeng: [])
        check(value(noPlmn, "Operator") == "CHINA MOBILE", "networkRows: no PLMN anywhere leaves out \", PLMN\"",
              "\(String(describing: value(noPlmn, "Operator")))")
        let onlyNetworkName = combined(cops: ["+COPS: 0"], qeng: [])
        check(value(onlyNetworkName, "Operator") == "中国移动, PLMN 46000", "networkRows: the network name alone",
              "\(String(describing: value(onlyNetworkName, "Operator")))")
        check(value(combined(cops: [], qspn: [], qeng: []), "Operator") == nil, "networkRows: no operator row without a value")
        let truncatedPlmn = combined(qspn: [], qeng: ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460"])
        check(value(truncatedPlmn, "Operator") == "CHINA MOBILE", "networkRows: no fallback PLMN without the leg's MNC",
              "\(String(describing: value(truncatedPlmn, "Operator")))")

        // A cut-off line: values that are nil are left out of their rows; rows with none are left out.
        let cut = combined(qeng: ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32"], qcainfo: [])
        expectRows(cut, [
            ("Registration", "registered, home network (5GS)"),
            ("Operator", "CHINA MOBILE (中国移动), PLMN 46000"),
            ("Technology", "5G SA (TDD)"),
            ("Cell", "PCI 32, cell ID 123456789"),
            ("Connection", "idle"),
            ("Radio", "on"),
            ("Network mode", "automatic (5G, LTE and WCDMA)"),
        ], "a line cut after <PCID>")

        expectRows(combined(radio: ["+CFUN: 4"], fiveG: ["+C5GREG: 0,0"], cops: ["+COPS: 0"], qspn: [],
                            qeng: ["+QENG: \"servingcell\",\"SEARCH\""], qcainfo: []), [
            ("Registration", "not registered"),
            ("Technology", "none (radio off)"),
            ("Connection", "searching"),
            ("Radio", "off (airplane mode)"),
            ("Network mode", "automatic (5G, LTE and WCDMA)"),
        ], "the radio off")

        expectRows(NetworkInfo(), [("Registration", "unknown"), ("Technology", "unknown")], "nothing read")

        let wcdmaInfo = combined(cops: ["+COPS: 0,0,\"CHINA UNICOM\",2"], qspn: [], qeng: [wcdmaLine], qcainfo: [],
                                 mode: ["+QNWPREFCFG: \"mode_pref\",WCDMA"])
        check(value(wcdmaInfo, "Technology") == "WCDMA" && value(wcdmaInfo, "Signal") == "RSCP -80 dBm"
                && value(wcdmaInfo, "Cell") == "PSC 123, cell ID 1234567, LAC 5A2B"
                && value(wcdmaInfo, "Channel") == "UARFCN 10700" && value(wcdmaInfo, "Band") == nil
                && value(wcdmaInfo, "Operator") == "CHINA UNICOM, PLMN 46001"
                && value(wcdmaInfo, "Network mode") == "WCDMA only",
              "networkRows: WCDMA names RSCP, PSC, LAC and UARFCN", rowsText(networkRows(wcdmaInfo)))
        let lteInfo = combined(qeng: ["+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,5,3,2B3C,-98,-11,-68,14,8,230,52"],
                               qcainfo: [])
        check(value(lteInfo, "Technology") == "LTE (FDD)" && value(lteInfo, "Band") == "B3",
              "networkRows: LTE alone", rowsText(networkRows(lteInfo)))

        for (state, words) in [("NOCONN", "idle"), ("CONNECT", "connected"), ("SEARCH", "searching"),
                               ("LIMSRV", "limited service"), ("SOMETHING", "SOMETHING")] {
            let got = value(combined(qeng: ["+QENG: \"servingcell\",\"\(state)\""]), "Connection")
            check(got == words, "networkRows: Connection for \(state)", "\(String(describing: got))")
        }
        for (answer, words) in [("+CFUN: 1", "on"), ("+CFUN: 4", "off (airplane mode)"), ("+CFUN: 0", "minimum functionality"),
                                ("+CFUN: 7", "AT+CFUN 7")] {
            let got = value(combined(radio: [answer]), "Radio")
            check(got == words, "networkRows: Radio for \(answer)", "\(String(describing: got))")
        }
        check(value(combined(radio: []), "Radio") == nil, "networkRows: no Radio row when it was not read")
        check(value(combined(nr5g: ["+QNWPREFCFG: \"nr5g_disable_mode\",1"]), "Network mode")
                == "automatic (5G, LTE and WCDMA); 5G SA is disabled", "networkRows: SA disabled")
        check(value(combined(nr5g: ["+QNWPREFCFG: \"nr5g_disable_mode\",2"]), "Network mode")
                == "automatic (5G, LTE and WCDMA); 5G NSA is disabled", "networkRows: NSA disabled")
        check(value(combined(mode: ["+QNWPREFCFG: \"mode_pref\",LTE:NR5G"]), "Network mode") == "5G and LTE",
              "networkRows: another mode")
        check(value(combined(mode: [], nr5g: []), "Network mode") == nil, "networkRows: no mode row when it was not read")
        check(value(combined(fiveG: [], eps: [], ps: [], cs: []), "Registration") == "unknown",
              "networkRows: registration not read")

        // --- networkJSON -----------------------------------------------------------------------
        let json = roundTrip(networkJSON(saInfo), "the SA fixture")
        check(Set(json.keys) == jsonKeys, "networkJSON: exactly the keys", "\(json.keys.sorted())")
        check(json["radio"] as? String == "on", "networkJSON: radio")
        let reg = json["registration"] as? [String: Any]
        check(reg?["status"] as? String == "home" && reg?["domain"] as? String == "5GS", "networkJSON: registration", "\(String(describing: reg))")
        check(json["roaming"] as? Bool == false, "networkJSON: roaming false")
        check(json["operator"] as? String == "CHINA MOBILE", "networkJSON: operator")
        check(json["networkName"] as? String == "中国移动", "networkJSON: networkName")
        check(json["plmn"] as? String == "46000", "networkJSON: plmn")
        check(json["technology"] as? String == "5G SA", "networkJSON: technology")
        check(json["state"] as? String == "NOCONN", "networkJSON: state")
        check(json["carriers"] as? [String] == ["n41", "n28"], "networkJSON: carriers")
        check(json["mode"] as? String == "AUTO", "networkJSON: mode")
        check(json["nr5gDisableMode"] as? Int == 0, "networkJSON: nr5gDisableMode")
        let cells = json["cells"] as? [[String: Any]] ?? []
        check(cells.count == 1, "networkJSON: one cell", "\(String(describing: json["cells"]))")
        let c = cells.first ?? [:]
        check(Set(c.keys) == cellKeys, "networkJSON: exactly the cell keys", "\(c.keys.sorted())")
        check(c["rat"] as? String == "NR5G-SA" && c["duplex"] as? String == "TDD" && c["mcc"] as? String == "460"
                && c["mnc"] as? String == "00" && c["cellId"] as? String == "123456789" && c["pci"] as? Int == 32
                && c["tac"] as? String == "1A2B3C" && c["channel"] as? Int == 504990 && c["band"] as? String == "n41"
                && c["bandwidthMHz"] as? Double == 100 && c["rsrp"] as? Int == -95 && c["rsrq"] as? Int == -10
                && c["sinr"] as? Double == 8,
              "networkJSON: the cell's values", "\(c)")

        let plmnFallback = roundTrip(networkJSON(combined(qspn: [])), "without AT+QSPN")
        check(plmnFallback["plmn"] as? String == "46000" && plmnFallback["networkName"] is NSNull,
              "networkJSON: the PLMN from the first leg (R1), networkName null", "\(plmnFallback)")

        let empty = roundTrip(networkJSON(NetworkInfo()), "nothing read")
        check(Set(empty.keys) == jsonKeys, "networkJSON: nothing read keeps every key", "\(empty.keys.sorted())")
        for key in ["radio", "registration", "roaming", "operator", "networkName", "plmn", "state", "cells", "mode", "nr5gDisableMode"] {
            check(empty[key] is NSNull, "networkJSON: nothing read gives null for \(key)", "\(String(describing: empty[key]))")
        }
        check(empty["technology"] as? String == "unknown" && empty["carriers"] as? [String] == [],
              "networkJSON: nothing read: technology unknown, carriers empty", "\(empty)")

        let cutJSON = roundTrip(networkJSON(cut), "a cut-off line")
        let cutCell = (cutJSON["cells"] as? [[String: Any]])?.first ?? [:]
        check(Set(cutCell.keys) == cellKeys, "networkJSON: a cut-off leg keeps every key", "\(cutCell.keys.sorted())")
        for key in ["tac", "channel", "band", "bandwidthMHz", "scsKHz", "rsrp", "rsrq", "sinr"] {
            check(cutCell[key] is NSNull, "networkJSON: a cut-off leg gives null for \(key)", "\(String(describing: cutCell[key]))")
        }
        let searching = roundTrip(networkJSON(combined(qeng: ["+QENG: \"servingcell\",\"SEARCH\""])), "searching")
        check(searching["state"] as? String == "SEARCH" && (searching["cells"] as? [Any])?.isEmpty == true,
              "networkJSON: searching gives an empty cell list", "\(searching)")
        let noStateLine = roundTrip(networkJSON(combined(qeng: Array(endc.dropFirst()))), "no servingcell line")
        check(noStateLine["state"] is NSNull && (noStateLine["cells"] as? [Any])?.count == 2,
              "networkJSON: no \"servingcell\" line gives state null, the legs kept", "\(noStateLine)")
        let dashState = roundTrip(networkJSON(combined(qeng: ["+QENG: \"servingcell\",\"-\""])), "state -")
        check(dashState["state"] is NSNull && (dashState["cells"] as? [Any])?.isEmpty == true,
              "networkJSON: state - gives null", "\(dashState)")
        let lteJSON = roundTrip(networkJSON(combined(qeng: endc)), "EN-DC")
        let lteCell = (lteJSON["cells"] as? [[String: Any]])?.first ?? [:]
        check(lteCell["bandwidthMHz"] as? Double == 10 && lteCell["sinr"] as? Double == 8 && (lteJSON["cells"] as? [Any])?.count == 2,
              "networkJSON: EN-DC has two cells", "\(lteJSON)")
        let narrowJSON = roundTrip(networkJSON(combined(qeng: ["+QENG: \"servingcell\",\"CONNECT\",\"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,0,0,2B3C,-98,-11,-68,0,8,230,52"])), "1.4 MHz")
        check(((narrowJSON["cells"] as? [[String: Any]])?.first?["bandwidthMHz"] as? Double) == 1.4,
              "networkJSON: 1.4 MHz survives", "\(narrowJSON)")

        for (answer, word) in [("+CFUN: 4", "airplane"), ("+CFUN: 0", "minimum"), ("+CFUN: 7", "cfun 7")] {
            let got = roundTrip(networkJSON(combined(radio: [answer])), answer)["radio"] as? String
            check(got == word, "networkJSON: radio for \(answer)", "\(String(describing: got))")
        }
        let statuses: [(RegistrationStatus, String, Bool)] = [
            (.home, "home", false), (.roaming, "roaming", true), (.searching, "searching", false), (.denied, "denied", false),
            (.emergencyOnly, "emergency", false), (.notRegistered, "not registered", false), (.unknown, "unknown", false)]
        for (status, word, roaming) in statuses {
            var info = NetworkInfo()
            info.registration = Registration(status: status, domain: "EPS")
            let got = roundTrip(networkJSON(info), word)
            check((got["registration"] as? [String: Any])?["status"] as? String == word && got["roaming"] as? Bool == roaming,
                  "networkJSON: registration status \(word)", "\(got)")
        }

        // --- SCS codes & parseCarrierComponents -------------------------------------------------
        for (code, khz) in [(0, 15), (1, 30), (2, 60), (3, 120), (4, 240)] {
            let line = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",310,260,00A1B2C3D,683,001A2B,396250,25,3,-92,-11,20,\(code),-"
            check(parseServingCell([line])?.cells.first?.scsKHz == khz, "parseServingCell: scs code \(code) is \(khz) kHz")
        }

        let liveQca = [
            "+QCAINFO: \"PCC\",396250,3,\"NR5G BAND 25\",683",
            "+QCAINFO: \"SCC\",520110,12,\"NR5G BAND 41\",2,147,0,-,-",
        ]
        check(parseCarrierComponents(liveQca) == [
            CarrierComponent(role: "PCC", rat: "NR5G", band: "n25", channel: 396250, bandwidthMHz: 20, pci: 683),
            CarrierComponent(role: "SCC", rat: "NR5G", band: "n41", channel: 520110, bandwidthMHz: 100, pci: 147),
        ], "parseCarrierComponents: 5G SA PCC + 9-field SCC with PCI and bandwidth", "\(parseCarrierComponents(liveQca))")

        let lteQca = [
            "+QCAINFO: \"SCC\",100,50,\"LTE BAND 1\",1,12,0,-,-",
            "+QCAINFO: \"PCC\",1300,75,\"LTE BAND 3\",1,128,-98,-11,-68,14",
        ]
        check(parseCarrierComponents(lteQca) == [
            CarrierComponent(role: "PCC", rat: "LTE", band: "B3", channel: 1300, bandwidthMHz: 15, pci: 128),
            CarrierComponent(role: "SCC", rat: "LTE", band: "B1", channel: 100, bandwidthMHz: 10, pci: 12),
        ], "parseCarrierComponents: LTE PCC before SCC, RB bandwidths and PCIs")

        // --- per-antenna signals (AT+QRSRP / AT+QRSRQ / AT+QSINR) ------------------------------
        let antSets = parseAntennaSignals(
            rsrp: ["+QRSRP: -93,-110,-32768,-140,NR5G"],
            rsrq: ["+QRSRQ: -11,-16,-32768,-32768,NR5G"],
            sinr: ["+QSINR: 20,10,-32768,-20,NR5G"]
        )
        check(antSets == [
            AntennaSignalSet(rat: "NR5G", ports: [
                AntennaPort(index: 0, name: "PRX", rsrp: -93, rsrq: -11, sinr: 20),
                AntennaPort(index: 1, name: "DRX", rsrp: -110, rsrq: -16, sinr: 10),
                AntennaPort(index: 2, name: "RX2", rsrp: nil, rsrq: nil, sinr: nil),
                AntennaPort(index: 3, name: "RX3", rsrp: nil, rsrq: nil, sinr: nil),
            ])
        ], "parseAntennaSignals: -32768 and correlated -140/-20 floor sentinels become inactive", "\(antSets)")
        let antEndc = parseAntennaSignals(
            rsrp: ["+QRSRP: -93,-110,-110,-103,NR5G", "+QRSRP: -98,-99,-32768,-32768,LTE"],
            rsrq: ["+QRSRQ: -11,-16,-11,-11,NR5G", "+QRSRQ: -12,-13,-32768,-32768,LTE"],
            sinr: ["+QSINR: 20,10,11,11,NR5G", "+QSINR: 14,12,-32768,-32768,LTE"]
        )
        check(antEndc.map { $0.rat } == ["LTE", "NR5G"], "parseAntennaSignals: LTE ordered before NR5G in EN-DC")
        check(rowsText(antennaRows(antSets))
              == "PRX: RSRP -93 dBm, RSRQ -11 dB, SINR 20 dB | DRX: RSRP -110 dBm, RSRQ -16 dB, SINR 10 dB | RX2: inactive | RX3: inactive",
              "antennaRows", rowsText(antennaRows(antSets)))
        check(JSONSerialization.isValidJSONObject(antennasJSON(antEndc)), "antennasJSON: valid JSON")

        // --- neighbour cells -------------------------------------------------------------------
        let nbs = parseNeighbourCells([
            "+QENG: \"neighbourcell intra\",\"LTE\",1300,128,-11,-98,-68,14,0",
            "+QENG: \"neighbourcell inter\",\"LTE\",100,45,-14,-105,-75,6,0",
        ])
        // The SINR raw, as the serving cell's: dB = raw x 2 - 20 (14 is 8 dB, 6 is -8 dB).
        check(nbs == [
            NeighbourCell(rat: "LTE", kind: "intra", channel: 1300, pci: 128, rsrp: -98, rsrq: -11, sinr: 8),
            NeighbourCell(rat: "LTE", kind: "inter", channel: 100, pci: 45, rsrp: -105, rsrq: -14, sinr: -8),
        ], "parseNeighbourCells: LTE intra and inter", "\(nbs)")
        // The manual's example (LTE mode): an intra cell, and inter cells whose PCI and values are `-` (not valid now).
        let manual = parseNeighbourCells([
            "+QENG: \"neighbourcell intra\",\"LTE\",38950,276,-3,-88,-65,0,37,7,16,6,44",
            "+QENG: \"neighbourcell inter\",\"LTE\",39148,-,-,-,-,-,37,0,30,7,-,-,-,-",
        ])
        check(manual == [
            NeighbourCell(rat: "LTE", kind: "intra", channel: 38950, pci: 276, rsrp: -88, rsrq: -3, sinr: -20),
            NeighbourCell(rat: "LTE", kind: "inter", channel: 39148, pci: nil, rsrp: nil, rsrq: nil, sinr: nil),
        ], "parseNeighbourCells: the manual's LTE-mode example", "\(manual)")
        // WCDMA mode: LTE cells without intra/inter, RSRP before RSRQ, no SINR; WCDMA cells as before.
        let fromWcdma = parseNeighbourCells([
            "+QENG: \"neighbourcell\",\"WCDMA\",10713,12,371,-95,-8,1,2,20",
            "+QENG: \"neighbourcell\",\"LTE\",66786,301,-101,-13,22",
        ])
        check(fromWcdma == [
            NeighbourCell(rat: "WCDMA", kind: nil, channel: 10713, pci: 371, rsrp: -95, rsrq: nil, sinr: nil),
            NeighbourCell(rat: "LTE", kind: nil, channel: 66786, pci: 301, rsrp: -101, rsrq: -13, sinr: nil),
        ], "parseNeighbourCells: WCDMA mode's LTE cells, RSRP before RSRQ", "\(fromWcdma)")
        // LTE mode's WCDMA cells: <uarfcn>,<cell_resel_priority>,<thresh_Xhigh>,<thresh_Xlow>,<PSC>,<RSCP>,<ecno>,
        // <srxlev>: the PSC and the RSCP after the thresholds, not the thresholds.
        let lteModeWcdma = parseNeighbourCells([
            "+QENG: \"neighbourcell intra\",\"LTE\",1300,128,-11,-98,-68,14,0",
            "+QENG: \"neighbourcell\",\"WCDMA\",10713,3,20,12,371,-95,-8,20",
        ])
        check(lteModeWcdma.last == NeighbourCell(rat: "WCDMA", kind: nil, channel: 10713, pci: 371, rsrp: -95, rsrq: nil,
                                                 sinr: nil),
              "parseNeighbourCells: LTE mode's WCDMA cells, PSC and RSCP after the thresholds", "\(lteModeWcdma)")
        // WCDMA lines alone: each told by its values (a threshold of 0 or more where WCDMA mode has the RSCP).
        let wcdmaOnly = parseNeighbourCells([
            "+QENG: \"neighbourcell\",\"WCDMA\",10713,3,20,12,371,-95,-8,20",
            "+QENG: \"neighbourcell\",\"WCDMA\",10737,12,402,-101,-11,1,2,18",
        ])
        check(wcdmaOnly == [
            NeighbourCell(rat: "WCDMA", kind: nil, channel: 10713, pci: 371, rsrp: -95, rsrq: nil, sinr: nil),
            NeighbourCell(rat: "WCDMA", kind: nil, channel: 10737, pci: 402, rsrp: -101, rsrq: nil, sinr: nil),
        ], "parseNeighbourCells: WCDMA lines alone, each layout told by its values", "\(wcdmaOnly)")
        // An LTE line without intra or inter: the answer is WCDMA mode's, its WCDMA lines read so.
        let wcdmaModeBoth = parseNeighbourCells([
            "+QENG: \"neighbourcell\",\"WCDMA\",10713,0,371,-95,-8,1,2,20",
            "+QENG: \"neighbourcell\",\"LTE\",66786,301,-101,-13,22",
        ])
        check(wcdmaModeBoth.first == NeighbourCell(rat: "WCDMA", kind: nil, channel: 10713, pci: 371, rsrp: -95, rsrq: nil,
                                                   sinr: nil), "parseNeighbourCells: WCDMA mode told by its LTE line")
        // A SINR that is `-`: none.
        check(parseNeighbourCells(["+QENG: \"neighbourcell intra\",\"LTE\",1300,128,-11,-98,-68,-,0"]).first?.sinr == nil,
              "parseNeighbourCells: a SINR of `-` is none")

        print("modem network: \(checks) checks passed")
    }
}
