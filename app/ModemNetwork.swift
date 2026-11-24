// The modem's network as its AT answers give it: the radio, registration, operator, serving cell,
// carriers and network mode, and what the window and `RMNet network` say about them. Foundation only:
// pure functions over the answer lines (AtPort's lines between the echo and OK), so `make app-test`
// builds this file alone. A missing field, `-` in place of a number, a short or long line all read as
// "not known" (nil); nothing here crashes on an odd answer or invents a value.
import Foundation

// MARK: - What was read

enum RadioState: Equatable { case on, airplane, minimum, other(Int) }        // AT+CFUN 1, 4, 0, other
enum RegistrationStatus: Equatable { case home, roaming, searching, denied, emergencyOnly, notRegistered, unknown }
struct Registration: Equatable { let status: RegistrationStatus; let domain: String }   // domain "5GS", "EPS", "PS", "CS"

// One leg of the serving cell (EN-DC has two: LTE and NR5G-NSA).
struct CellLeg: Equatable {
    let rat: String                 // "NR5G-SA", "NR5G-NSA", "LTE", "WCDMA"
    let duplex: String?             // "TDD"/"FDD"
    let mcc: String?; let mnc: String?          // as the modem gave them ("00" stays "00")
    let cellID: String?; let pci: Int?; let tac: String?   // WCDMA: tac = LAC, pci = PSC
    let channel: Int?               // ARFCN, EARFCN or UARFCN
    let band: String?               // "n41", "B3"; nil for WCDMA
    let bandwidthMHz: Double?       // downlink
    let rsrp: Int?; let rsrq: Int?; let sinr: Double?    // dBm, dB, dB (LTE SINR converted); WCDMA: rsrp = RSCP
    let scsKHz: Int?                // NR subcarrier spacing in kHz (15, 30, 60, 120, 240); nil outside NR or when unread

    init(rat: String, duplex: String?, mcc: String?, mnc: String?, cellID: String?, pci: Int?, tac: String?,
         channel: Int?, band: String?, bandwidthMHz: Double?, rsrp: Int?, rsrq: Int?, sinr: Double?, scsKHz: Int? = nil) {
        self.rat = rat
        self.duplex = duplex
        self.mcc = mcc
        self.mnc = mnc
        self.cellID = cellID
        self.pci = pci
        self.tac = tac
        self.channel = channel
        self.band = band
        self.bandwidthMHz = bandwidthMHz
        self.rsrp = rsrp
        self.rsrq = rsrq
        self.sinr = sinr
        self.scsKHz = scsKHz
    }
}

struct ServingCell: Equatable { let state: String; let cells: [CellLeg] }   // state as given: "NOCONN", …

/// One component carrier from AT+QCAINFO (`"PCC"` or `"SCC"`).
struct CarrierComponent: Equatable {
    let role: String                // "PCC" or "SCC"
    let rat: String                 // "LTE", "NR5G", or ""
    let band: String                // "n41", "B3", or raw band text (display-safe)
    let channel: Int?               // ARFCN or EARFCN
    let bandwidthMHz: Double?
    let pci: Int?
}

/// Physical receive paths reported by AT+QRSRP / AT+QRSRQ / AT+QSINR.
let antennaPortNames = ["PRX", "DRX", "RX2", "RX3"]

/// Signal measurements for one antenna path (0...3). All three values are nil when the path is inactive or
/// filtered as a sentinel.
struct AntennaPort: Equatable {
    let index: Int                  // 0...3
    let name: String                // "PRX", "DRX", "RX2", "RX3"
    let rsrp: Int?                  // dBm
    let rsrq: Int?                  // dB
    let sinr: Int?                  // dB

    var isActive: Bool { rsrp != nil || rsrq != nil || sinr != nil }
}

/// Four-antenna signal set for one RAT (`"LTE"` or `"NR5G"`).
struct AntennaSignalSet: Equatable {
    let rat: String                 // "LTE" or "NR5G"
    let ports: [AntennaPort]        // always 4 ports (PRX, DRX, RX2, RX3)
}

/// One neighbour cell returned by AT+QENG="neighbourcell".
struct NeighbourCell: Equatable {
    let rat: String                 // "LTE", "NR5G", "WCDMA", …
    let kind: String?               // "intra", "inter", or nil
    let channel: Int?
    let pci: Int?
    let rsrp: Int?
    let rsrq: Int?
    let sinr: Int?
}

struct NetworkInfo: Equatable {
    var radio: RadioState? = nil
    var registration: Registration? = nil
    var operatorName: String? = nil      // AT+COPS? <oper>, display-safe
    var networkName: String? = nil       // AT+QSPN <FNN>, decoded, display-safe
    var plmn: String? = nil              // AT+QSPN <RPLMN> only; rows and JSON fall back to the first leg's MCC+MNC
    var accessTechnology: Int? = nil     // AT+COPS? <AcT>
    var serving: ServingCell? = nil
    var carriers: [String] = []          // AT+QCAINFO bands, primary first
    var carrierComponents: [CarrierComponent] = []
    var mode: String? = nil              // mode_pref exactly as the modem gave it ("AUTO", "LTE:NR5G")
    var nr5gDisable: Int? = nil
}

// MARK: - Answer lines

/// The fields after "<prefix>:", split on commas outside quotes, each trimmed, then its quotes removed
/// (so spaces inside quotes are kept: `" a "` reads ` a `). Empty fields stay "". nil when the line does
/// not start with "<prefix>:". Works by Unicode scalar, not by Character: a quote or a comma that a
/// combining mark, a ZWJ or a Prepend character joins into one Character is still found.
func atFields(_ line: String, prefix: String) -> [String]? {
    let text = trimmedScalars(Array(line.unicodeScalars)[...], .whitespacesAndNewlines)
    let head = Array((prefix + ":").unicodeScalars)
    guard text.starts(with: head) else { return nil }
    var fields: [String] = []
    var current: [Unicode.Scalar] = []
    var quoted = false
    for c in text.dropFirst(head.count) {
        if c == "\"" { quoted.toggle() }
        if c == "," && !quoted {
            fields.append(unquotedField(current))
            current = []
        } else {
            current.append(c)
        }
    }
    fields.append(unquotedField(current))
    return fields
}

private func trimmedScalars(_ s: ArraySlice<Unicode.Scalar>, _ set: CharacterSet) -> ArraySlice<Unicode.Scalar> {
    var t = s.drop(while: { set.contains($0) })
    while let last = t.last, set.contains(last) { t = t.dropLast() }
    return t
}

/// A raw field (quotes still in it) trimmed of spaces, then its quote scalars removed.
private func unquotedField(_ raw: [Unicode.Scalar]) -> String {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: trimmedScalars(raw[...], .whitespaces).filter { $0 != "\"" })
    return String(out)
}

/// The fields of the first line with the prefix; nil when no line has it.
private func firstFields(_ lines: [String], _ prefix: String) -> [String]? {
    for line in lines {
        if let f = atFields(line, prefix: prefix) { return f }
    }
    return nil
}

private func field(_ f: [String], _ i: Int) -> String? {
    i >= 0 && i < f.count ? f[i] : nil
}

/// A whole number; nil when the field is missing, empty, `-` or not a number.
private func intField(_ f: [String], _ i: Int) -> Int? {
    field(f, i).flatMap { Int($0) }
}

/// A decimal number such as `8`, `-10` or `8.5`; nil for anything else, including `nan`, `inf` and hex,
/// which Double(_:) would take (and JSONSerialization cannot write).
private func decimalField(_ f: [String], _ i: Int) -> Double? {
    guard let s = field(f, i), !s.isEmpty, s.allSatisfy({ "+-.0123456789".contains($0) }),
          let d = Double(s), d.isFinite else { return nil }
    return d
}

/// The value when finite (a conversion can overflow a finite raw value to inf); else nil.
private func finite(_ d: Double) -> Double? {
    d.isFinite ? d : nil
}

/// A text field the modem formats itself (a state, a RAT, a hex cell ID): nil when missing, empty or
/// `-`; otherwise display-safe.
private func textField(_ f: [String], _ i: Int) -> String? {
    guard let s = field(f, i), !s.isEmpty, s != "-" else { return nil }
    return modemTextSafe(s)
}

/// A name from the network (an operator's): nil when missing or empty; otherwise display-safe.
private func nameField(_ f: [String], _ i: Int) -> String? {
    guard let s = field(f, i), !s.isEmpty else { return nil }
    return modemTextSafe(s)
}

// MARK: - Text from the modem or the network, safe to show

/// Characters that move the cursor, erase or forge lines, or reorder what is shown: the C0 controls,
/// DEL, the C1 controls, the bidirectional marks, embeddings, overrides and isolates (U+061C, U+200E,
/// U+200F, U+202A–U+202E, U+2066–U+2069), and the line and paragraph separators (U+2028, U+2029).
private func isUnsafeModemTextScalar(_ v: UInt32) -> Bool {
    v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x061C || v == 0x200E || v == 0x200F
        || (0x2028...0x202E).contains(v) || (0x2066...0x2069).contains(v)
}

/// Text from the modem or the network (a name, an APN, a SIM state), each unsafe character made U+FFFD.
/// The one rule for this file and ModemSettings.swift. It is the rule of `displaySafe` in SmsModel.swift
/// for a sender, with the bidirectional marks added; the modem models are built without SmsModel.swift,
/// so they keep their own.
func modemTextSafe(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
        out.append(isUnsafeModemTextScalar(c.value) ? "\u{FFFD}" : c)
    }
    return String(out)
}

// MARK: - Parsing the answers

/// AT+CFUN?: `+CFUN: <fun>`.
func parseRadio(_ lines: [String]) -> RadioState? {
    guard let f = firstFields(lines, "+CFUN"), let n = intField(f, 0) else { return nil }
    switch n {
    case 1: return .on
    case 4: return .airplane
    case 0: return .minimum
    default: return .other(n)
    }
}

/// The <stat> of a registration read answer (`<prefix>: <n>,<stat>[,…]`); prefix "+C5GREG", "+CEREG",
/// "+CGREG" or "+CREG".
func parseRegistrationStat(_ lines: [String], prefix: String) -> Int? {
    guard let f = firstFields(lines, prefix) else { return nil }
    return intField(f, 1)
}

/// The registration over the four domains, in the order 5GS, EPS, PS, CS: the first registered (stat 1
/// home, 5 roaming) wins; else the first searching (2); else denied (3) if any, emergency only (8) if
/// any; else not registered (domain "") when anything was read, nil when nothing was.
func summarizeRegistration(fiveG: Int?, eps: Int?, ps: Int?, cs: Int?) -> Registration? {
    let reads: [(domain: String, stat: Int?)] = [("5GS", fiveG), ("EPS", eps), ("PS", ps), ("CS", cs)]
    for r in reads {
        if r.stat == 1 { return Registration(status: .home, domain: r.domain) }
        if r.stat == 5 { return Registration(status: .roaming, domain: r.domain) }
    }
    for (stat, status) in [(2, RegistrationStatus.searching), (3, .denied), (8, .emergencyOnly)] {
        if let r = reads.first(where: { $0.stat == stat }) { return Registration(status: status, domain: r.domain) }
    }
    return reads.contains(where: { $0.stat != nil }) ? Registration(status: .notRegistered, domain: "") : nil
}

/// AT+COPS?: `+COPS: <mode>[,<format>,<oper>[,<AcT>]]`; the name is display-safe.
func parseOperator(_ lines: [String]) -> (name: String?, accessTechnology: Int?) {
    guard let f = firstFields(lines, "+COPS") else { return (nil, nil) }
    return (nameField(f, 2), intField(f, 3))
}

/// AT+QSPN: `+QSPN: <FNN>,<SNN>,<SPN>,<alphabet>,<RPLMN>`. With alphabet 1 the full name is UCS-2 in
/// hex; hex that is not valid UCS-2 is kept as given. A bare OK (not registered) gives (nil, nil).
func parseServiceProvider(_ lines: [String]) -> (fullName: String?, plmn: String?) {
    guard let f = firstFields(lines, "+QSPN") else { return (nil, nil) }
    var name = field(f, 0) ?? ""
    if intField(f, 3) == 1, let decoded = decodeUCS2(name) { name = decoded }
    return (name.isEmpty ? nil : modemTextSafe(name), textField(f, 4))
}

/// UCS-2 big-endian in hex (4 hex digits a character; a surrogate pair is taken as UTF-16); nil when
/// the length is not a multiple of 4, a digit is not hex, or a surrogate is alone.
private func decodeUCS2(_ hex: String) -> String? {
    let digits = Array(hex.utf8)
    guard digits.count % 4 == 0 else { return nil }
    var units: [UInt16] = []
    var unit: UInt16 = 0
    for (i, d) in digits.enumerated() {
        guard let v = hexDigitValue(d) else { return nil }
        unit = unit << 4 | UInt16(v)
        if i % 4 == 3 {
            units.append(unit)
            unit = 0
        }
    }
    var scalars = String.UnicodeScalarView()
    var decoder = UTF16()
    var input = units.makeIterator()
    while true {
        switch decoder.decode(&input) {
        case .scalarValue(let s): scalars.append(s)
        case .emptyInput: return String(scalars)
        case .error: return nil
        }
    }
}

private func hexDigitValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}

// NR <NR_DL_bandwidth> codes 0…16 and LTE <DL_bandwidth> codes 0…5, in MHz (Quectel's manual, 5.20).
private let nrBandwidthsMHz: [Double] = [5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100, 200, 400, 35, 45]
private let lteBandwidthsMHz: [Double] = [1.4, 3, 5, 10, 15, 20]
private let lteCaBandwidthByRb: [Int: Double] = [6: 1.4, 15: 3, 25: 5, 50: 10, 75: 15, 100: 20]
private let nrScsKHzTable: [Int] = [15, 30, 60, 120, 240]

private func bandwidth(_ table: [Double], _ code: Int?) -> Double? {
    guard let c = code, c >= 0, c < table.count else { return nil }
    return table[c]
}

private func intCodeValue(_ fields: [String], _ index: Int, in table: [Int]) -> Int? {
    guard let c = intField(fields, index), c >= 0, c < table.count else { return nil }
    return table[c]
}

/// A band number with its RAT's mark: NR 41 → "n41", LTE 3 → "B3"; nil unless a positive number.
private func band(_ mark: String, _ number: Int?) -> String? {
    guard let n = number, n > 0 else { return nil }
    return mark + String(n)
}

/// A leg whose RAT is not one of the four formats known here: its name, and no field guessed.
private func legWithoutFields(_ rat: String) -> CellLeg {
    CellLeg(rat: rat, duplex: nil, mcc: nil, mnc: nil, cellID: nil, pci: nil, tac: nil, channel: nil, band: nil,
            bandwidthMHz: nil, rsrp: nil, rsrq: nil, sinr: nil, scsKHz: nil)
}

/// The leg whose RAT is field `r`; its other fields are taken by position after it (manual, 5.20).
private func cellLeg(_ f: [String], rat r: Int) -> CellLeg? {
    guard let rat = textField(f, r) else { return nil }
    switch rat {
    case "NR5G-SA":
        // <duplex>,<MCC>,<MNC>,<cellID>,<PCID>,<TAC>,<ARFCN>,<band>,<NR_DL_bandwidth>,<RSRP>,<RSRQ>,<SINR>,<scs>,…
        return CellLeg(rat: rat, duplex: textField(f, r + 1), mcc: textField(f, r + 2), mnc: textField(f, r + 3),
                       cellID: textField(f, r + 4), pci: intField(f, r + 5), tac: textField(f, r + 6),
                       channel: intField(f, r + 7), band: band("n", intField(f, r + 8)),
                       bandwidthMHz: bandwidth(nrBandwidthsMHz, intField(f, r + 9)),
                       rsrp: intField(f, r + 10), rsrq: intField(f, r + 11), sinr: decimalField(f, r + 12),
                       scsKHz: intCodeValue(f, r + 13, in: nrScsKHzTable))
    case "LTE":
        // <is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<freq_band_ind>,<UL_bandwidth>,<DL_bandwidth>,<TAC>,
        // <RSRP>,<RSRQ>,<RSSI>,<SINR>,… ; the SINR is raw: dB = raw × 2 − 20 (nil unless finite).
        return CellLeg(rat: rat, duplex: textField(f, r + 1), mcc: textField(f, r + 2), mnc: textField(f, r + 3),
                       cellID: textField(f, r + 4), pci: intField(f, r + 5), tac: textField(f, r + 10),
                       channel: intField(f, r + 6), band: band("B", intField(f, r + 7)),
                       bandwidthMHz: bandwidth(lteBandwidthsMHz, intField(f, r + 9)),
                       rsrp: intField(f, r + 11), rsrq: intField(f, r + 12),
                       sinr: decimalField(f, r + 14).flatMap { finite($0 * 2 - 20) })
    case "NR5G-NSA":
        // <MCC>,<MNC>,<PCID>,<RSRP>,<SINR>,<RSRQ>,<ARFCN>,<band>,<NR_DL_bandwidth>,<scs>,… (SINR before RSRQ)
        return CellLeg(rat: rat, duplex: nil, mcc: textField(f, r + 1), mnc: textField(f, r + 2), cellID: nil,
                       pci: intField(f, r + 3), tac: nil, channel: intField(f, r + 7), band: band("n", intField(f, r + 8)),
                       bandwidthMHz: bandwidth(nrBandwidthsMHz, intField(f, r + 9)),
                       rsrp: intField(f, r + 4), rsrq: intField(f, r + 6), sinr: decimalField(f, r + 5),
                       scsKHz: intCodeValue(f, r + 10, in: nrScsKHzTable))
    case "WCDMA":
        // <MCC>,<MNC>,<LAC>,<cellID>,<uarfcn>,<PSC>,<RAC>,<RSCP>,<ecio>,…
        return CellLeg(rat: rat, duplex: nil, mcc: textField(f, r + 1), mnc: textField(f, r + 2),
                       cellID: textField(f, r + 4), pci: intField(f, r + 6), tac: textField(f, r + 3),
                       channel: intField(f, r + 5), band: nil, bandwidthMHz: nil,
                       rsrp: intField(f, r + 8), rsrq: nil, sinr: nil)
    default:
        return legWithoutFields(rat)
    }
}

/// AT+QENG="servingcell": `"servingcell",<state>[,<RAT>,…]` on one line, or (EN-DC) the state line
/// followed by one line a leg, each starting with its RAT. nil when no +QENG line was given.
func parseServingCell(_ lines: [String]) -> ServingCell? {
    var state: String? = nil
    var cells: [CellLeg] = []
    var answered = false
    for line in lines {
        guard let f = atFields(line, prefix: "+QENG") else { continue }
        answered = true
        if field(f, 0) == "servingcell" {
            if state == nil { state = textField(f, 1) }
            if let leg = cellLeg(f, rat: 2) { cells.append(leg) }
        } else if let leg = cellLeg(f, rat: 0) {
            cells.append(leg)
        }
    }
    return answered ? ServingCell(state: state ?? "", cells: cells) : nil
}

/// AT+QCAINFO: full component carrier details (role, RAT, band, ARFCN/EARFCN, bandwidth in MHz, PCI),
/// `"PCC"` lines first, then `"SCC"` lines in order.
func parseCarrierComponents(_ lines: [String]) -> [CarrierComponent] {
    var primary: [CarrierComponent] = []
    var secondary: [CarrierComponent] = []
    for line in lines {
        guard let f = atFields(line, prefix: "+QCAINFO"), let role = field(f, 0),
              role == "PCC" || role == "SCC", let rawBand = textField(f, 3) else { continue }
        let channel = intField(f, 1).flatMap { $0 >= 0 ? $0 : nil }
        let component: CarrierComponent
        if rawBand.hasPrefix("LTE BAND "), let b = band("B", Int(rawBand.dropFirst("LTE BAND ".count))) {
            let bw = intField(f, 2).flatMap { lteCaBandwidthByRb[$0] }
            let rawPci = f.count >= 6 ? intField(f, 5) : nil
            let pci = rawPci.flatMap { (0...503).contains($0) ? $0 : nil }
            component = CarrierComponent(role: role, rat: "LTE", band: b, channel: channel, bandwidthMHz: bw, pci: pci)
        } else if let nrBand = nrCarrierBand(rawBand) {
            let bw = bandwidth(nrBandwidthsMHz, intField(f, 2))
            // Short NR lines (PCC or EN-DC SCC, 5–8 fields) carry PCI at field 4; longer SCC lines (9+ fields)
            // carry state at field 4 and PCI at field 5.
            let rawPci = f.count >= 9 ? intField(f, 5) : intField(f, 4)
            let pci = rawPci.flatMap { (0...1007).contains($0) ? $0 : nil }
            component = CarrierComponent(role: role, rat: "NR5G", band: nrBand, channel: channel, bandwidthMHz: bw, pci: pci)
        } else {
            component = CarrierComponent(role: role, rat: "", band: rawBand, channel: channel, bandwidthMHz: nil, pci: nil)
        }
        if role == "PCC" { primary.append(component) } else { secondary.append(component) }
    }
    return primary + secondary
}

private func nrCarrierBand(_ text: String) -> String? {
    for head in ["NR5G BAND ", "NRDC BAND "] where text.hasPrefix(head) {
        if let b = band("n", Int(text.dropFirst(head.count))) { return b }
    }
    return nil
}

/// AT+QCAINFO: the band of each carrier, `"PCC"` lines first, then `"SCC"` lines in order.
/// "NR5G BAND 41" → "n41", "LTE BAND 3" → "B3"; another text is kept as given (display-safe).
func parseCarriers(_ lines: [String]) -> [String] {
    parseCarrierComponents(lines).map { $0.band }
}

/// AT+QRSRP, AT+QRSRQ, AT+QSINR: `<p0>,<p1>,<p2>,<p3>,<sysmode>`.
/// Filters `-32768`, empty/`-`, out-of-range metrics, and correlated inactive floor sentinels (`RSRP == -140`
/// when RSRQ is absent, SINR is absent, or SINR == -20).
func parseAntennaSignals(rsrp rsrpLines: [String], rsrq rsrqLines: [String],
                        sinr sinrLines: [String]) -> [AntennaSignalSet] {
    func mapByRat(_ lines: [String], prefix: String, range: ClosedRange<Int>) -> (order: [String], values: [String: [Int?]]) {
        var order: [String] = []
        var values: [String: [Int?]] = [:]
        for line in lines {
            guard let f = atFields(line, prefix: prefix), f.count >= 5,
                  let rat = textField(f, 4), values[rat] == nil else { continue }
            order.append(rat)
            values[rat] = (0..<4).map { i in
                guard let v = intField(f, i), v != -32768, range.contains(v) else { return nil }
                return v
            }
        }
        return (order, values)
    }

    let rsrpMap = mapByRat(rsrpLines, prefix: "+QRSRP", range: -150 ... -30)
    let rsrqMap = mapByRat(rsrqLines, prefix: "+QRSRQ", range: -30 ... 0)
    let sinrMap = mapByRat(sinrLines, prefix: "+QSINR", range: -30 ... 50)

    var allRats: [String] = []
    for rat in rsrpMap.order + rsrqMap.order + sinrMap.order where !allRats.contains(rat) {
        allRats.append(rat)
    }
    let preferred = ["LTE", "NR5G"]
    let orderedRats = preferred.filter { allRats.contains($0) } + allRats.filter { !preferred.contains($0) }

    return orderedRats.map { rat in
        let rsrps = rsrpMap.values[rat] ?? [nil, nil, nil, nil]
        let rsrqs = rsrqMap.values[rat] ?? [nil, nil, nil, nil]
        let sinrs = sinrMap.values[rat] ?? [nil, nil, nil, nil]
        let ports = (0..<4).map { i -> AntennaPort in
            var p = rsrps[i]
            var q = rsrqs[i]
            var s = sinrs[i]
            if p == -140 && (q == nil || s == nil || s == -20) {
                p = nil; q = nil; s = nil
            } else if s == -20 && p == nil && q == nil {
                s = nil
            }
            return AntennaPort(index: i, name: antennaPortNames[i], rsrp: p, rsrq: q, sinr: s)
        }
        return AntennaSignalSet(rat: rat, ports: ports)
    }
}

/// AT+QENG="neighbourcell" (Quectel's AT manual for the RM520N series, 5.20). A line's layout depends on the mode the
/// modem is in:
/// - LTE mode: `+QENG: "neighbourcell intra","LTE",<earfcn>,<PCID>,<RSRQ>,<RSRP>,<RSSI>,<SINR>,<srxlev>,…` (and
///   `"neighbourcell inter"`, the same fields): RSRQ before RSRP, and the SINR raw, as the serving cell's: dB = raw × 2
///   − 20 (the manual's Y = 1/5 × X × 10 − 20; a raw 14 is 8 dB). WCDMA cells:
///   `"neighbourcell","WCDMA",<uarfcn>,<cell_resel_priority>,<thresh_Xhigh>,<thresh_Xlow>,<PSC>,<RSCP>,<ecno>,<srxlev>`.
/// - WCDMA mode: `"neighbourcell","WCDMA",<uarfcn>,<srxqual>,<PSC>,<RSCP>,<ecno>,<set>,<rank>,<srxlev>`, and LTE cells
///   `"neighbourcell","LTE",<earfcn>,<PCID>,<RSRP>,<RSRQ>,<s_rxlev>`: RSRP before RSRQ, no SINR.
/// The mode is the answer's: LTE with an intra or inter line, WCDMA with an LTE line without either; an answer of WCDMA
/// lines only is told by each line, as the values allow: in LTE mode the sixth value is a threshold (0 or more) and the
/// eighth the RSCP (below 0); in WCDMA mode the sixth is the RSCP. Also `"neighbourcell…","NR5G",…`. A WCDMA cell's PCI
/// is its PSC and its RSRP its RSCP. A field that is `-` (not valid now) is nil.
func parseNeighbourCells(_ lines: [String]) -> [NeighbourCell] {
    var rows: [(fields: [String], rat: String, kind: String?)] = []
    for line in lines {
        guard let f = atFields(line, prefix: "+QENG"), let tag = textField(f, 0),
              tag.hasPrefix("neighbourcell"), let rat = textField(f, 1) else { continue }
        let suffix = tag.dropFirst("neighbourcell".count).trimmingCharacters(in: .whitespaces)
        rows.append((f, rat, suffix.isEmpty ? nil : suffix))
    }
    let lteMode: Bool? = rows.contains { $0.kind == "intra" || $0.kind == "inter" } ? true
        : rows.contains { $0.rat == "LTE" && $0.kind == nil } ? false : nil
    return rows.map { row in
        let f = row.fields
        switch row.rat {
        case "LTE":
            if row.kind == "intra" || row.kind == "inter" {
                return NeighbourCell(rat: row.rat, kind: row.kind, channel: intField(f, 2), pci: intField(f, 3),
                                     rsrp: intField(f, 5), rsrq: intField(f, 4), sinr: intField(f, 7).map { $0 * 2 - 20 })
            }
            return NeighbourCell(rat: row.rat, kind: row.kind, channel: intField(f, 2), pci: intField(f, 3),
                                 rsrp: intField(f, 4), rsrq: intField(f, 5), sinr: nil)
        case "NR5G", "NR5G-SA", "NR5G-NSA":
            return NeighbourCell(rat: "NR5G", kind: row.kind, channel: intField(f, 2), pci: intField(f, 3),
                                 rsrp: intField(f, 4), rsrq: intField(f, 5), sinr: intField(f, 6))
        case "WCDMA":
            let inLte = lteMode ?? wcdmaLineInLteMode(f)
            return NeighbourCell(rat: row.rat, kind: row.kind, channel: intField(f, 2), pci: intField(f, inLte ? 6 : 4),
                                 rsrp: intField(f, inLte ? 7 : 5), rsrq: nil, sinr: nil)
        default:
            return NeighbourCell(rat: row.rat, kind: row.kind, channel: intField(f, 2), pci: intField(f, 3),
                                 rsrp: nil, rsrq: nil, sinr: nil)
        }
    }
}

/// A WCDMA neighbour line on its own: in LTE mode its sixth value (thresh_Xlow) is 0 or more and its eighth (RSCP) is
/// below 0; in WCDMA mode its sixth is the RSCP, below 0.
private func wcdmaLineInLteMode(_ f: [String]) -> Bool {
    if let sixth = intField(f, 5) { return sixth >= 0 }
    if let eighth = intField(f, 7) { return eighth < 0 }
    return false
}

/// The value of one AT+QNWPREFCFG setting: `+QNWPREFCFG: "<name>",<value>`.
private func preference(_ lines: [String], _ name: String) -> [String]? {
    for line in lines {
        if let f = atFields(line, prefix: "+QNWPREFCFG"), field(f, 0) == name { return f }
    }
    return nil
}

/// AT+QNWPREFCFG="mode_pref": the mode as given ("AUTO", "LTE:NR5G").
func parseModePreference(_ lines: [String]) -> String? {
    preference(lines, "mode_pref").flatMap { textField($0, 1) }
}

/// AT+QNWPREFCFG="nr5g_disable_mode": 0 none, 1 SA disabled, 2 NSA disabled.
func parseNr5gDisable(_ lines: [String]) -> Int? {
    preference(lines, "nr5g_disable_mode").flatMap { intField($0, 1) }
}

// MARK: - In words

/// The technology in use: from the serving cell's legs, else its state (searching, limited service),
/// else the AcT of AT+COPS?; "none (radio off)" in airplane mode whatever else was read.
func technologyLabel(_ info: NetworkInfo) -> String {
    if info.radio == .airplane { return "none (radio off)" }
    if let serving = info.serving {
        let rats = serving.cells.map { $0.rat }
        if rats.contains("NR5G-SA") { return "5G SA" }
        if rats.contains("NR5G-NSA") { return "5G NSA" }
        if let first = rats.first { return first }   // "LTE", "WCDMA", or another RAT as the modem named it
        if serving.state == "SEARCH" { return "searching" }
        if serving.state == "LIMSRV" { return "limited service" }
    }
    switch info.accessTechnology {
    case 11, 12: return "5G SA"
    case 13: return "5G NSA"
    case 7: return "LTE"
    case 10: return "LTE (5G core)"
    case 2, 4, 5, 6: return "WCDMA"
    default: return "unknown"
    }
}

func registrationWords(_ r: Registration?) -> String {
    guard let r else { return "unknown" }
    let domain = r.domain.isEmpty ? "" : " (\(r.domain))"
    switch r.status {
    case .home: return "registered, home network" + domain
    case .roaming: return "registered, roaming" + domain
    case .searching: return "searching"
    case .denied: return "registration denied"
    case .emergencyOnly: return "emergency services only"
    case .notRegistered: return "not registered"
    case .unknown: return "unknown"
    }
}

private let modeRATs = ["WCDMA", "LTE", "NR5G"]

/// The mode_pref value for what the owner typed, ignoring case: `auto` alone, or RATs from `wcdma`,
/// `lte` and `nr5g` joined by `:`, each at most once, returned in the order WCDMA, LTE, NR5G
/// (`nr5g:lte` → `LTE:NR5G`). nil for anything else: empty, an unknown name, a repeat, `auto` with
/// others, an empty piece.
func canonicalMode(_ argument: String) -> String? {
    if argument.lowercased() == "auto" { return "AUTO" }
    var picked = Set<String>()
    for piece in argument.lowercased().split(separator: ":", omittingEmptySubsequences: false) {
        guard let rat = modeRATs.first(where: { $0.lowercased() == piece }), !picked.contains(rat) else { return nil }
        picked.insert(rat)
    }
    return picked.isEmpty ? nil : modeRATs.filter { picked.contains($0) }.joined(separator: ":")
}

/// The same mode: the same value, or the same RATs in another order (`NR5G:LTE` and `LTE:NR5G`), compared
/// by canonicalMode; a value it does not accept is only the same as itself.
func sameMode(_ a: String, _ b: String) -> Bool {
    a == b || (canonicalMode(a).map { $0 == canonicalMode(b) } ?? false)
}

/// A mode_pref value in words, the same for any order of the same RATs (`NR5G:LTE` reads as `LTE:NR5G`
/// does); a mode not named here reads as its RATs joined with " and ", in canonicalMode's order when it
/// accepts the value.
func modeWords(_ mode: String) -> String {
    let named = canonicalMode(mode) ?? mode
    switch named {
    case "AUTO": return "automatic (5G, LTE and WCDMA)"
    case "NR5G": return "5G only"
    case "LTE": return "LTE only"
    case "LTE:NR5G": return "5G and LTE"
    case "WCDMA": return "WCDMA only"
    default: return named.split(separator: ":").joined(separator: " and ")
    }
}

/// The PLMN shown: AT+QSPN's, else the first leg's MCC and MNC together ("460" + "00").
private func shownPLMN(_ info: NetworkInfo) -> String? {
    if let plmn = info.plmn { return plmn }
    guard let leg = info.serving?.cells.first, let mcc = leg.mcc, let mnc = leg.mnc else { return nil }
    return mcc + mnc
}

private func operatorWords(_ info: NetworkInfo) -> String {
    var name = info.operatorName ?? info.networkName
    if let op = info.operatorName, let network = info.networkName, op.caseInsensitiveCompare(network) != .orderedSame {
        name = "\(op) (\(network))"
    }
    return [name, shownPLMN(info).map { "PLMN \($0)" }].compactMap { $0 }.joined(separator: ", ")
}

/// A leg's short name in rows: "5G" for either NR leg, else its RAT.
private func legName(_ leg: CellLeg) -> String {
    leg.rat.hasPrefix("NR5G") ? "5G" : leg.rat
}

/// The technology with its legs: "5G SA (TDD)", "LTE (FDD)", "5G NSA (LTE FDD + 5G)".
private func technologyWords(_ info: NetworkInfo) -> String {
    let label = technologyLabel(info)
    guard info.radio != .airplane, let legs = info.serving?.cells, let first = legs.first else { return label }
    let detail = legs.count == 1
        ? first.duplex ?? ""
        : legs.map { [legName($0), $0.duplex].compactMap { $0 }.joined(separator: " ") }.joined(separator: " + ")
    return detail.isEmpty ? label : "\(label) (\(detail))"
}

/// "n41", "B3": the RAT of a band label made by `band`; nil for a carrier text kept as given.
private func bandRAT(_ label: String) -> Character? {
    guard let mark = label.first, mark == "n" || mark == "B", Int(label.dropFirst()) != nil else { return nil }
    return mark
}

/// The carriers, then any leg's band they do not list. Carrier aggregation when the carriers include two
/// of the same RAT; EN-DC's LTE + NR pair is dual connectivity, not aggregation.
private func bandWords(_ info: NetworkInfo) -> String {
    var bands = info.carriers
    for leg in info.serving?.cells ?? [] {
        if let b = leg.band, !bands.contains(b) { bands.append(b) }
    }
    let rats = info.carriers.compactMap(bandRAT)
    let aggregated = rats.count != Set(rats).count
    return bands.joined(separator: " + ") + (aggregated ? " (carrier aggregation)" : "")
}

/// 8 → "8", 1.4 → "1.4".
private func decimalWords(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
}

private func signalWords(_ leg: CellLeg) -> String {
    var parts: [String] = []
    if let v = leg.rsrp { parts.append("\(leg.rat == "WCDMA" ? "RSCP" : "RSRP") \(v) dBm") }
    if let v = leg.rsrq { parts.append("RSRQ \(v) dB") }
    if let v = leg.sinr { parts.append("SINR \(decimalWords(v)) dB") }
    return parts.joined(separator: ", ")
}

private func cellWords(_ leg: CellLeg) -> String {
    let wcdma = leg.rat == "WCDMA"
    var parts: [String] = []
    if let v = leg.pci { parts.append("\(wcdma ? "PSC" : "PCI") \(v)") }
    if let v = leg.cellID { parts.append("cell ID \(v)") }
    if let v = leg.tac { parts.append("\(wcdma ? "LAC" : "TAC") \(v)") }
    return parts.joined(separator: ", ")
}

private func channelWords(_ leg: CellLeg) -> String {
    var parts: [String] = []
    if let v = leg.channel {
        let name: String
        switch leg.rat {
        case "LTE": name = "EARFCN"
        case "WCDMA": name = "UARFCN"
        case "NR5G-SA", "NR5G-NSA": name = "ARFCN"
        default: name = "channel"
        }
        parts.append("\(name) \(v)")
    }
    if let v = leg.bandwidthMHz { parts.append("\(decimalWords(v)) MHz") }
    if let scs = leg.scsKHz { parts.append("SCS \(scs) kHz") }
    return parts.joined(separator: ", ")
}

/// Rows for `RMNet antennas`: one line per receive antenna path (`PRX`, `DRX`, `RX2`, `RX3`) for each RAT.
func antennaRows(_ sets: [AntennaSignalSet]) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = []
    for set in sets {
        let ratPrefix = sets.count > 1 ? "\(set.rat) " : ""
        for port in set.ports {
            let label = "\(ratPrefix)\(port.name)"
            if !port.isActive {
                rows.append((label: label, value: "inactive"))
                continue
            }
            var parts: [String] = []
            if let v = port.rsrp { parts.append("RSRP \(v) dBm") }
            if let v = port.rsrq { parts.append("RSRQ \(v) dB") }
            if let v = port.sinr { parts.append("SINR \(v) dB") }
            rows.append((label: label, value: parts.joined(separator: ", ")))
        }
    }
    return rows
}

private func connectionWords(_ state: String) -> String {
    switch state {
    case "NOCONN": return "idle"
    case "CONNECT": return "connected"
    case "SEARCH": return "searching"
    case "LIMSRV": return "limited service"
    default: return state
    }
}

private func radioWords(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "on"
    case .airplane: return "off (airplane mode)"
    case .minimum: return "minimum functionality"
    case .other(let n): return "AT+CFUN \(n)"
    }
}

private func modeRowWords(_ info: NetworkInfo) -> String {
    var parts: [String] = []
    if let mode = info.mode { parts.append(modeWords(mode)) }
    switch info.nr5gDisable {
    case 1: parts.append("5G SA is disabled")
    case 2: parts.append("5G NSA is disabled")
    default: break
    }
    return parts.joined(separator: "; ")
}

/// The window's rows and the CLI's lines. A value that is nil is left out of its row, and a row with no
/// value is left out. With more than one leg, the Signal, Cell and Channel rows come once a leg, named
/// "(LTE)", "(5G)", all Signal rows first.
func networkRows(_ info: NetworkInfo) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = []
    func add(_ label: String, _ value: String?) {
        if let value, !value.isEmpty { rows.append((label: label, value: value)) }
    }
    add("Registration", registrationWords(info.registration))
    add("Operator", operatorWords(info))
    add("Technology", technologyWords(info))
    add("Band", bandWords(info))
    let legs = info.serving?.cells ?? []
    func label(_ name: String, _ leg: CellLeg) -> String {
        legs.count > 1 ? "\(name) (\(legName(leg)))" : name
    }
    for leg in legs { add(label("Signal", leg), signalWords(leg)) }
    for leg in legs { add(label("Cell", leg), cellWords(leg)) }
    for leg in legs { add(label("Channel", leg), channelWords(leg)) }
    add("Connection", info.serving.map { connectionWords($0.state) })
    add("Radio", info.radio.map(radioWords))
    add("Network mode", modeRowWords(info))
    return rows
}

// MARK: - JSON

private func orNull<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

private func radioKey(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "on"
    case .airplane: return "airplane"
    case .minimum: return "minimum"
    case .other(let n): return "cfun \(n)"
    }
}

private func statusKey(_ status: RegistrationStatus) -> String {
    switch status {
    case .home: return "home"
    case .roaming: return "roaming"
    case .searching: return "searching"
    case .denied: return "denied"
    case .emergencyOnly: return "emergency"
    case .notRegistered: return "not registered"
    case .unknown: return "unknown"
    }
}

private func legJSON(_ leg: CellLeg) -> [String: Any] {
    ["rat": leg.rat, "duplex": orNull(leg.duplex), "mcc": orNull(leg.mcc), "mnc": orNull(leg.mnc),
     "cellId": orNull(leg.cellID), "pci": orNull(leg.pci), "tac": orNull(leg.tac), "channel": orNull(leg.channel),
     "band": orNull(leg.band), "bandwidthMHz": orNull(leg.bandwidthMHz), "scsKHz": orNull(leg.scsKHz),
     "rsrp": orNull(leg.rsrp), "rsrq": orNull(leg.rsrq), "sinr": orNull(leg.sinr)]
}

private func carrierComponentJSON(_ c: CarrierComponent) -> [String: Any] {
    ["role": c.role, "rat": c.rat, "band": c.band, "channel": orNull(c.channel),
     "bandwidthMHz": orNull(c.bandwidthMHz), "pci": orNull(c.pci)]
}

/// `RMNet antennas --json`.
func antennasJSON(_ sets: [AntennaSignalSet]) -> [String: Any] {
    let rats: [[String: Any]] = sets.map { set in
        let ports: [[String: Any]] = set.ports.map { p in
            ["index": p.index, "name": p.name, "active": p.isActive,
             "rsrp": orNull(p.rsrp), "rsrq": orNull(p.rsrq), "sinr": orNull(p.sinr)]
        }
        return ["rat": set.rat, "ports": ports]
    }
    return ["rats": rats]
}

/// `RMNet network --json`: every key is always there; a value not read is null (also `state` when the
/// answer gave none: no "servingcell" line, or `-`). `cells` is null when the serving cell was not
/// read, [] when it has no leg (searching).
func networkJSON(_ info: NetworkInfo) -> [String: Any] {
    [
        "radio": orNull(info.radio.map(radioKey)),
        "registration": orNull(info.registration.map { ["status": statusKey($0.status), "domain": $0.domain] }),
        "roaming": orNull(info.registration.map { $0.status == .roaming }),
        "operator": orNull(info.operatorName),
        "networkName": orNull(info.networkName),
        "plmn": orNull(shownPLMN(info)),
        "technology": technologyLabel(info),
        "state": orNull(info.serving.flatMap { $0.state.isEmpty ? nil : $0.state }),
        "cells": orNull(info.serving.map { $0.cells.map(legJSON) }),
        "carriers": info.carriers,
        "carrierComponents": info.carrierComponents.map(carrierComponentJSON),
        "mode": orNull(info.mode),
        "nr5gDisableMode": orNull(info.nr5gDisable),
    ]
}
