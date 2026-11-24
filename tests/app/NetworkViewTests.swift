// Tests for what the Network screen's cards show (app/NetworkView.swift's NetworkCards): the Connection card's rows
// ("—" for what was not read, the operator and network names, the PLMN's fallback, the mode with a 5G kind disabled),
// the technology's words without a badge, the legs' order and names, the metrics a RAT reports, why there is no leg
// to show, the Cell card's rows (one or two legs, WCDMA, none), the carrier chips (bandwidth, once a serving leg;
// primary) and their widths, the radio switch (none while the radio is not known), and the bands' chips, count and
// collapse. Built with swiftc by `make app-test` from NetworkView.swift and
// the files it needs; its views are compiled, not drawn (no window is made, no modem opened).
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

func rows(_ r: [(label: String, value: String)]) -> [String] {
    r.map { "\($0.label): \($0.value)" }
}

func leg(_ rat: String, duplex: String? = nil, mcc: String? = "001", mnc: String? = "01", cellID: String? = nil,
         pci: Int? = nil, tac: String? = nil, channel: Int? = nil, band: String? = nil, bandwidth: Double? = nil,
         rsrp: Int? = nil, rsrq: Int? = nil, sinr: Double? = nil) -> CellLeg {
    CellLeg(rat: rat, duplex: duplex, mcc: mcc, mnc: mnc, cellID: cellID, pci: pci, tac: tac, channel: channel,
            band: band, bandwidthMHz: bandwidth, rsrp: rsrp, rsrq: rsrq, sinr: sinr)
}

let sa = leg("NR5G-SA", duplex: "TDD", cellID: "1A2B3C4D5", pci: 245, tac: "3F2A", channel: 520110, band: "n41",
             bandwidth: 100, rsrp: -86, rsrq: -11, sinr: 14.5)
let lte = leg("LTE", duplex: "FDD", cellID: "2C4E01", pci: 101, tac: "2B1E", channel: 1300, band: "B3", bandwidth: 20,
              rsrp: -97, rsrq: -12, sinr: 9)
let nsaNr = leg("NR5G-NSA", pci: 388, channel: 627264, band: "n78", bandwidth: 100, rsrp: -89, rsrq: -11, sinr: 16)
let wcdma = leg("WCDMA", cellID: "0A1B2C", pci: 77, tac: "1F00", channel: 10700, rsrp: -80)

func info(_ legs: [CellLeg]?, carriers: [String] = [], radio: RadioState? = .on, state: String = "NOCONN",
          registration: Registration? = Registration(status: .home, domain: "5GS"), operatorName: String? = "Example Mobile",
          networkName: String? = "Example Mobile", plmn: String? = "00101", act: Int? = nil, mode: String? = "AUTO",
          nr5gDisable: Int? = 0) -> NetworkInfo {
    NetworkInfo(radio: radio, registration: registration, operatorName: operatorName, networkName: networkName,
                plmn: plmn, accessTechnology: act, serving: legs.map { ServingCell(state: state, cells: $0) },
                carriers: carriers, mode: mode, nr5gDisable: nr5gDisable)
}

func set(_ rat: BandRat, allowed: [Int], supported: [Int]) -> BandSet {
    BandSet(rat: rat, allowed: allowed, supported: supported)
}

@main
struct NetworkViewTests {
    static func main() {
        words()
        connection()
        technology()
        legs()
        noLeg()
        cell()
        carriers()
        radioSwitch()
        chipWidths()
        bands()
        print("network view: \(checks) checks passed")
    }

    static func words() {
        equal(NetworkCards.capitalizedFirst("registered, home network (5GS)"), "Registered, home network (5GS)",
              "capitalized: first letter")
        equal(NetworkCards.capitalizedFirst("5G only"), "5G only", "capitalized: a digit first")
        equal(NetworkCards.capitalizedFirst(""), "", "capitalized: empty")
        equal(NetworkCards.bandwidthText(100), "100 MHz", "bandwidth: whole")
        equal(NetworkCards.bandwidthText(1.4), "1.4 MHz", "bandwidth: decimal")
        equal(NetworkCards.notReported, "—", "not reported: a dash")
    }

    // The operator, registration, PLMN and network mode, each "—" when not read.
    static func connection() {
        equal(rows(NetworkCards.connectionRows(nil)),
              ["Operator: —", "Registration: —", "PLMN: —", "Network mode: —"], "connection: nothing read")
        equal(rows(NetworkCards.connectionRows(info([sa]))),
              ["Operator: Example Mobile", "Registration: Registered, home network (5GS)", "PLMN: 00101",
               "Network mode: Automatic (5G, LTE and WCDMA)"], "connection: 5G SA")
        equal(rows(NetworkCards.connectionRows(NetworkInfo())),
              ["Operator: —", "Registration: —", "PLMN: —", "Network mode: —"], "connection: a read with nothing in it")
        // The operator's name and the network's, as the network rows give them.
        equal(NetworkCards.operatorText(info(nil, operatorName: "EXAMPLE MOBILE", networkName: "Example Mobile")),
              "EXAMPLE MOBILE", "operator: the same name in other case")
        equal(NetworkCards.operatorText(info(nil, operatorName: "Example", networkName: "Example Mobile")),
              "Example (Example Mobile)", "operator: two names")
        equal(NetworkCards.operatorText(info(nil, operatorName: nil, networkName: "Example Mobile")), "Example Mobile",
              "operator: the network's name only")
        equal(NetworkCards.operatorText(info(nil, operatorName: "Example", networkName: nil)), "Example",
              "operator: AT+COPS? only")
        equal(NetworkCards.operatorText(info(nil, operatorName: nil, networkName: nil)), nil, "operator: none")
        // The PLMN: AT+QSPN's, else the first leg's MCC and MNC, else none.
        equal(NetworkCards.plmnText(info([sa], plmn: "310260")), "310260", "PLMN: AT+QSPN's")
        equal(NetworkCards.plmnText(info([leg("LTE", mcc: "460", mnc: "00")], plmn: nil)), "46000",
              "PLMN: the first leg's MCC and MNC")
        equal(NetworkCards.plmnText(info([leg("LTE", mcc: "460", mnc: nil)], plmn: nil)), nil, "PLMN: no MNC")
        equal(NetworkCards.plmnText(info(nil, plmn: nil)), nil, "PLMN: no leg")
        // The mode, in modeWords' words, with a 5G kind disabled; the registration's words.
        let disabled = NetworkCards.connectionRows(info([sa], mode: "LTE:NR5G", nr5gDisable: 1))
        equal(disabled[3].value, "5G and LTE; 5G SA is disabled", "connection: mode with 5G SA disabled")
        equal(NetworkCards.connectionRows(info([sa], mode: nil, nr5gDisable: 2))[3].value, "5G NSA is disabled",
              "connection: mode not read, 5G NSA disabled")
        equal(NetworkCards.connectionRows(info([sa], mode: nil, nr5gDisable: nil))[3].value, "—",
              "connection: mode not read")
        equal(NetworkCards.connectionRows(info([sa], registration: Registration(status: .roaming, domain: "EPS")))[1].value,
              "Registered, roaming (EPS)", "connection: roaming")
        equal(NetworkCards.connectionRows(info([], registration: Registration(status: .searching, domain: "5GS")))[1].value,
              "Searching", "connection: searching")
    }

    // The technology in words where the badge shows none.
    static func technology() {
        equal(NetworkCards.technologyWithoutBadge(info([sa])), nil, "technology: the badge shows 5G SA")
        equal(NetworkCards.technologyWithoutBadge(info([lte, nsaNr])), nil, "technology: the badge shows 5G NSA")
        equal(NetworkCards.technologyWithoutBadge(info([], state: "SEARCH")), "Searching", "technology: searching")
        equal(NetworkCards.technologyWithoutBadge(info([], state: "LIMSRV")), "Limited service",
              "technology: limited service")
        equal(NetworkCards.technologyWithoutBadge(info([], radio: .airplane)), "None (radio off)",
              "technology: radio off")
        equal(NetworkCards.technologyWithoutBadge(info(nil)), nil, "technology: unknown")
        equal(NetworkCards.technologyWithoutBadge(info([leg("GSM")])), "GSM", "technology: a RAT the badge does not name")
    }

    // LTE first (EN-DC's columns), names and the metrics a RAT reports.
    static func legs() {
        equal(NetworkCards.shownLegs(nil), [], "legs: nothing read")
        equal(NetworkCards.shownLegs(info(nil)), [], "legs: serving cell not read")
        equal(NetworkCards.shownLegs(info([sa])), [sa], "legs: 5G SA")
        equal(NetworkCards.shownLegs(info([lte, nsaNr])), [lte, nsaNr], "legs: EN-DC in the modem's order")
        equal(NetworkCards.shownLegs(info([nsaNr, lte])), [lte, nsaNr], "legs: EN-DC with NR first, LTE shown first")
        equal(NetworkCards.legTitle(sa), "NR", "leg title: 5G SA")
        equal(NetworkCards.legTitle(nsaNr), "NR", "leg title: 5G NSA")
        equal(NetworkCards.legTitle(lte), "LTE", "leg title: LTE")
        equal(NetworkCards.legTitle(wcdma), "WCDMA", "leg title: WCDMA")
        equal(NetworkCards.legMetrics("NR5G-SA"), [.rsrp, .rsrq, .sinr], "metrics: NR")
        equal(NetworkCards.legMetrics("LTE"), [.rsrp, .rsrq, .sinr], "metrics: LTE")
        equal(NetworkCards.legMetrics("WCDMA"), [.rsrp], "metrics: WCDMA (RSCP only)")
        equal(NetworkCards.legValue(sa, .rsrp), -86, "value: RSRP")
        equal(NetworkCards.legValue(sa, .rsrq), -11, "value: RSRQ")
        equal(NetworkCards.legValue(sa, .sinr), 14.5, "value: SINR")
        equal(NetworkCards.legValue(leg("LTE"), .rsrp), nil, "value: RSRP not reported")
        equal(NetworkCards.legValue(leg("LTE"), .sinr), nil, "value: SINR not reported")
    }

    // Why the Signal and Cell cards show no leg; nil when they show one, or "—".
    static func noLeg() {
        equal(NetworkCards.noLegReason(nil), nil, "no leg: nothing read")
        equal(NetworkCards.noLegReason(info([sa])), nil, "no leg: a leg")
        equal(NetworkCards.noLegReason(info(nil)), nil, "no leg: serving cell not read")
        equal(NetworkCards.noLegReason(info([], state: "SEARCH")), "No serving cell.", "no leg: searching")
        equal(NetworkCards.noLegReason(info([], state: "LIMSRV")), "No serving cell.", "no leg: limited service")
        equal(NetworkCards.noLegReason(info([], radio: .airplane, state: "SEARCH")), "The radio is off.",
              "no leg: airplane mode")
        equal(NetworkCards.noLegReason(info(nil, radio: .minimum)), "The radio is off.", "no leg: minimum functionality")
        equal(NetworkCards.noLegReason(info([sa], radio: .airplane)), "The radio is off.",
              "no leg: radio off with a leg still read")
        equal(NetworkCards.noLegReason(info([], radio: nil, state: "SEARCH")), "No serving cell.",
              "no leg: radio not read, searching")
    }

    // The Cell card's rows: a value a leg, "—" for what a leg did not report.
    static func cell() {
        equal(NetworkCards.cellRows([sa]), [
            NetworkCards.CellRow(label: "Band", values: ["n41 (TDD)"]),
            NetworkCards.CellRow(label: "Bandwidth", values: ["100 MHz"]),
            NetworkCards.CellRow(label: "Channel", values: ["520110"]),
            NetworkCards.CellRow(label: "PCI", values: ["245"]),
            NetworkCards.CellRow(label: "Cell ID", values: ["1A2B3C4D5"]),
            NetworkCards.CellRow(label: "TAC", values: ["3F2A"]),
        ], "cell: 5G SA")
        equal(NetworkCards.cellRows([lte, nsaNr]), [
            NetworkCards.CellRow(label: "Band", values: ["B3 (FDD)", "n78"]),
            NetworkCards.CellRow(label: "Bandwidth", values: ["20 MHz", "100 MHz"]),
            NetworkCards.CellRow(label: "Channel", values: ["1300", "627264"]),
            NetworkCards.CellRow(label: "PCI", values: ["101", "388"]),
            NetworkCards.CellRow(label: "Cell ID", values: ["2C4E01", "—"]),
            NetworkCards.CellRow(label: "TAC", values: ["2B1E", "—"]),
        ], "cell: EN-DC, NR without cell ID and TAC")
        equal(NetworkCards.cellRows([wcdma]), [
            NetworkCards.CellRow(label: "Band", values: ["—"]),
            NetworkCards.CellRow(label: "Bandwidth", values: ["—"]),
            NetworkCards.CellRow(label: "Channel", values: ["10700"]),
            NetworkCards.CellRow(label: "PSC", values: ["77"]),
            NetworkCards.CellRow(label: "Cell ID", values: ["0A1B2C"]),
            NetworkCards.CellRow(label: "LAC", values: ["1F00"]),
        ], "cell: WCDMA, its own labels")
        equal(NetworkCards.cellRows([]).map { $0.label }, ["Band", "Bandwidth", "Channel", "PCI", "Cell ID", "TAC"],
              "cell: no leg, labels")
        equal(NetworkCards.cellRows([]).map { $0.values }, Array(repeating: ["—"], count: 6), "cell: no leg, one dash each")
        equal(NetworkCards.cellRows([leg("LTE", band: "B7")])[0].values, ["B7"], "cell: band without duplex")
        equal(NetworkCards.cellRows([leg("LTE", duplex: "FDD")])[0].values, ["—"], "cell: duplex without band")
        equal(NetworkCards.cellRows([leg("LTE", bandwidth: 1.4)])[1].values, ["1.4 MHz"], "cell: 1.4 MHz")
    }

    // The carriers: AT+QCAINFO's first, then legs' bands not listed; bandwidth from the leg on that band.
    static func carriers() {
        equal(NetworkCards.carrierChips(info([sa], carriers: ["n41", "n25"])), [
            NetworkCards.CarrierChip(band: "n41", bandwidthMHz: 100, primary: true),
            NetworkCards.CarrierChip(band: "n25", bandwidthMHz: nil, primary: false),
        ], "carriers: primary with its leg's bandwidth, a secondary without")
        equal(NetworkCards.carrierChips(info([lte, nsaNr], carriers: ["B3"])), [
            NetworkCards.CarrierChip(band: "B3", bandwidthMHz: 20, primary: true),
            NetworkCards.CarrierChip(band: "n78", bandwidthMHz: 100, primary: false),
        ], "carriers: EN-DC's NR leg added after the listed carrier")
        equal(NetworkCards.carrierChips(info([lte, nsaNr])), [
            NetworkCards.CarrierChip(band: "B3", bandwidthMHz: 20, primary: false),
            NetworkCards.CarrierChip(band: "n78", bandwidthMHz: 100, primary: false),
        ], "carriers: none listed, the legs' bands, none marked primary")
        equal(NetworkCards.carrierChips(info([lte], carriers: ["B3", "B7", "B20"])).map { $0.bandwidthMHz },
              [20, nil, nil], "carriers: aggregation, only the serving leg's bandwidth known")
        equal(NetworkCards.carrierChips(info([leg("LTE", band: "B3")], carriers: ["B3"])),
              [NetworkCards.CarrierChip(band: "B3", bandwidthMHz: nil, primary: true)], "carriers: leg without bandwidth")
        equal(NetworkCards.carrierChips(info(nil, carriers: ["LTE BAND X"])),
              [NetworkCards.CarrierChip(band: "LTE BAND X", bandwidthMHz: nil, primary: true)],
              "carriers: a carrier text kept as given")
        equal(NetworkCards.carrierChips(info([])), [], "carriers: none")
        equal(NetworkCards.carrierChips(info([leg("WCDMA")])), [], "carriers: a leg with no band")
        // Intra-band aggregation: the serving leg's bandwidth goes to one chip only, the first on its band.
        equal(NetworkCards.carrierChips(info([sa], carriers: ["n41", "n41"])), [
            NetworkCards.CarrierChip(band: "n41", bandwidthMHz: 100, primary: true),
            NetworkCards.CarrierChip(band: "n41", bandwidthMHz: nil, primary: false),
        ], "carriers: n41 + n41, the leg's 100 MHz on the primary only")
        equal(NetworkCards.carrierChips(info([lte], carriers: ["B3", "B7", "B3"])).map { $0.bandwidthMHz }, [20, nil, nil],
              "carriers: B3 + B7 + B3, the leg's 20 MHz on the first B3 only")
        equal(NetworkCards.carrierChips(info([lte, nsaNr], carriers: ["B3", "B3", "n78"])).map { $0.bandwidthMHz },
              [20, nil, 100], "carriers: each serving leg's bandwidth once, on its own band")
    }

    // The radio switch: shown only once the radio has been read, on only while the modem says it is on.
    static func radioSwitch() {
        equal(NetworkCards.radioSwitchOn(nil), nil, "radio switch: not read, no switch")
        equal(NetworkCards.radioSwitchOn(.on), true, "radio switch: on")
        equal(NetworkCards.radioSwitchOn(.airplane), false, "radio switch: airplane mode, off")
        equal(NetworkCards.radioSwitchOn(.minimum), false, "radio switch: minimum functionality, off")
        equal(NetworkCards.radioSwitchOn(.other(5)), false, "radio switch: another AT+CFUN value, off")
    }

    // Wider with more bandwidth, between 56 and 220 pt; 56 when not known.
    static func chipWidths() {
        equal(NetworkCards.carrierChipWidth(nil), 56, "chip width: not known")
        equal(NetworkCards.carrierChipWidth(0), 56, "chip width: zero")
        equal(NetworkCards.carrierChipWidth(1.4), 56, "chip width: 1.4 MHz at the minimum")
        equal(NetworkCards.carrierChipWidth(20), 64, "chip width: 20 MHz")
        equal(NetworkCards.carrierChipWidth(100), 160, "chip width: 100 MHz")
        equal(NetworkCards.carrierChipWidth(400), 220, "chip width: 400 MHz at the maximum")
        let widths = [5.0, 10, 15, 20, 40, 60, 80, 100, 150].map { NetworkCards.carrierChipWidth($0) }
        check(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 }, "chip width: never narrower with more bandwidth",
              "\(widths)")
        check(NetworkCards.carrierChipWidth(100) > NetworkCards.carrierChipWidth(20) * 2,
              "chip width: 100 MHz well over twice 20 MHz")
    }

    // A RAT's chips (allowed or not), its count and when its row collapses.
    static func bands() {
        let all = [1, 3, 41, 78]
        let open = set(.sa, allowed: [78, 41, 3, 1], supported: all)
        equal(NetworkCards.bandsAllAllowed(open), true, "bands: every band allowed (another order)")
        equal(NetworkCards.bandsCount(open), "All 4 allowed", "bands: count, all allowed")
        let locked = set(.sa, allowed: [41], supported: all)
        equal(NetworkCards.bandsAllAllowed(locked), false, "bands: locked")
        equal(NetworkCards.bandsCount(locked), "1 of 4 allowed", "bands: count, locked")
        equal(NetworkCards.bandChips(locked), [
            NetworkCards.BandChip(band: 1, label: "n1", allowed: false),
            NetworkCards.BandChip(band: 3, label: "n3", allowed: false),
            NetworkCards.BandChip(band: 41, label: "n41", allowed: true),
            NetworkCards.BandChip(band: 78, label: "n78", allowed: false),
        ], "bands: chips, ascending, n41 allowed")
        equal(NetworkCards.bandChips(set(.lte, allowed: [3, 7], supported: [7, 3, 1])).map { $0.label }, ["B1", "B3", "B7"],
              "bands: LTE labels")
        equal(NetworkCards.bandChips(set(.nsa, allowed: [78], supported: [41, 78])).map { $0.label }, ["n41", "n78"],
              "bands: 5G NSA labels")
        // A band allowed that the modem does not list as supported is still shown, allowed.
        let odd = set(.lte, allowed: [3, 99], supported: [1, 3])
        equal(NetworkCards.bandChips(odd).map { "\($0.label) \($0.allowed)" }, ["B1 false", "B3 true", "B99 true"],
              "bands: an allowed band not listed as supported")
        equal(NetworkCards.bandsAllAllowed(odd), false, "bands: not collapsed with an unsupported band allowed")
        equal(NetworkCards.bandsCount(odd), "2 of 2 allowed", "bands: count as bandsSummary counts it")
        // Nothing allowed, or nothing at all.
        let none = set(.sa, allowed: [], supported: all)
        equal(NetworkCards.bandsAllAllowed(none), false, "bands: none allowed")
        equal(NetworkCards.bandsCount(none), "0 of 4 allowed", "bands: count, none allowed")
        let empty = set(.sa, allowed: [], supported: [])
        equal(NetworkCards.bandsAllAllowed(empty), false, "bands: nothing supported is not all allowed")
        equal(NetworkCards.bandsCount(empty), "0 of 0 allowed", "bands: count, nothing supported")
        equal(NetworkCards.bandChips(empty), [], "bands: no chips")
        // Duplicates count once.
        equal(NetworkCards.bandsCount(set(.lte, allowed: [3, 3], supported: [3, 7, 7])), "1 of 2 allowed",
              "bands: count as sets")

        // --- SCS row, carrierComponents chips, antenna tiles & quick lock targets --------------
        let scsLeg = CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "310", mnc: "260", cellID: "123", pci: 683, tac: "1F",
                             channel: 396250, band: "n25", bandwidthMHz: 20, rsrp: -92, rsrq: -11, sinr: 20, scsKHz: 15)
        check(NetworkCards.cellRows([scsLeg]).contains(NetworkCards.CellRow(label: "SCS", values: ["15 kHz"])),
              "cellRows: includes SCS when reported")

        var richInfo = info([scsLeg], carriers: ["n25", "n41"])
        richInfo.carrierComponents = [
            CarrierComponent(role: "PCC", rat: "NR5G", band: "n25", channel: 396250, bandwidthMHz: 20, pci: 683),
            CarrierComponent(role: "SCC", rat: "NR5G", band: "n41", channel: 520110, bandwidthMHz: 100, pci: 147),
        ]
        equal(NetworkCards.carrierChips(richInfo), [
            NetworkCards.CarrierChip(band: "n25", bandwidthMHz: 20, primary: true, channel: 396250, pci: 683),
            NetworkCards.CarrierChip(band: "n41", bandwidthMHz: 100, primary: false, channel: 520110, pci: 147),
        ], "carrierChips: carries SCC bandwidth, channel and PCI from carrierComponents")

        let tiles = NetworkCards.antennaTiles([
            AntennaSignalSet(rat: "NR5G", ports: [
                AntennaPort(index: 0, name: "PRX", rsrp: -93, rsrq: -11, sinr: 20),
                AntennaPort(index: 1, name: "DRX", rsrp: -110, rsrq: -16, sinr: 10),
                AntennaPort(index: 2, name: "RX2", rsrp: nil, rsrq: nil, sinr: nil),
                AntennaPort(index: 3, name: "RX3", rsrp: nil, rsrq: nil, sinr: nil),
            ])
        ])
        check(tiles.count == 4 && tiles[0].active && tiles[0].rsrpText == "-93" && tiles[0].title == "PRX"
                && tiles[0].detailText == "RSRQ -11 dB · SINR 20 dB" && tiles[0].help == "Receive path 1, primary (PRX)"
                && !tiles[2].active && tiles[2].detailText == "Not in use" && tiles[2].rsrpText == "—"
                && tiles[2].quality == nil,
              "antennaTiles: formats active and inactive paths", "\(tiles)")
        equal(tiles.map { $0.quality }, [2, 1, nil, nil], "antennaTiles: the RSRP's quality zone")
        equal(NetworkCards.antennaTiles([AntennaSignalSet(rat: "LTE", ports: [
            AntennaPort(index: 0, name: "PRX", rsrp: -90, rsrq: nil, sinr: nil)])])[0].detailText, "In use",
              "antennaTiles: an RSRP alone")
        equal(NetworkCards.ratName("NR5G"), "5G", "ratName: NR5G")
        equal(NetworkCards.ratName("LTE"), "LTE", "ratName: LTE")

        let targets = NetworkCards.lockTargets(richInfo)
        equal(targets, [
            NetworkCards.LockTarget(band: "n25", role: "Primary", detail: "20 MHz · PCI 683 · ARFCN 396250",
                                    kind: .nr(NetworkCards.NrCellTarget(pci: 683, arfcn: 396250, band: 25, scsKHz: 15))),
            NetworkCards.LockTarget(band: "n41", role: "Secondary", detail: "100 MHz · PCI 147 · ARFCN 520110",
                                    kind: .nr(NetworkCards.NrCellTarget(pci: 147, arfcn: 520110, band: 41, scsKHz: nil))),
        ], "lockTargets: builds quick-lock entries for PCC and SCC; the SCC's spacing not reported, not guessed")
        equal(targets[0].label, "n25 · 20 MHz · PCI 683 · ARFCN 396250", "lockTargets: label")
        // EN-DC: no 5G SA target (an NSA leg cannot be locked with common/5g); the LTE leg is one.
        let endcTargets = NetworkCards.lockTargets(info([lte, nsaNr]))
        equal(endcTargets.map { $0.band + " " + $0.role }, ["B3 Serving"], "lockTargets: EN-DC gives the LTE leg only")
        equal(endcTargets.first?.detail, "20 MHz · PCI 101 · EARFCN 1300", "lockTargets: LTE detail")
        equal(NetworkCards.lockTargets(nil), [], "lockTargets: nothing read")

        cellLock()
        neighbours()
    }

    static func cellLock() {
        let nr = NrCellLock(pci: 186, arfcn: 520110, scsKHz: 30, band: 41)
        let lockedNr = CellLockState(lte: [], nr: nr, persistLte: true, persistNr: true)
        let lteOne = CellLockState(lte: [LteLockedCell(earfcn: 66786, pci: 128)], nr: nil, persistLte: false, persistNr: false)
        let lteThree = CellLockState(lte: [LteLockedCell(earfcn: 66786, pci: 128), LteLockedCell(earfcn: 5110, pci: 301),
                                           LteLockedCell(earfcn: 1300, pci: 7)], nr: nil, persistLte: false, persistNr: false)
        let open = CellLockState(lte: [], nr: nil, persistLte: false, persistNr: false)

        equal(NetworkCards.nrLockText(nr), "n41 · PCI 186 · ARFCN 520110 · SCS 30 kHz", "nrLockText")
        equal(NetworkCards.lteLockText(lteOne.lte), "PCI 128 · EARFCN 66786", "lteLockText: one")
        equal(NetworkCards.lteLockText(lteThree.lte), "3 cells (PCI 128, 301, 7)", "lteLockText: three")

        let nrTarget = NetworkCards.LockTarget(band: "n41", role: "Primary", detail: "",
                                               kind: .nr(NetworkCards.NrCellTarget(pci: 186, arfcn: 520110, band: 41, scsKHz: 30)))
        let noScs = NetworkCards.LockTarget(band: "n41", role: "Secondary", detail: "",
                                            kind: .nr(NetworkCards.NrCellTarget(pci: 186, arfcn: 520110, band: 41, scsKHz: nil)))
        let lteTarget = NetworkCards.LockTarget(band: "B66", role: "Serving", detail: "",
                                                kind: .lte(LteLockedCell(earfcn: 66786, pci: 128)))
        check(NetworkCards.targetIsLocked(nrTarget, lockedNr), "targetIsLocked: the 5G SA lock")
        check(!NetworkCards.targetIsLocked(nrTarget, open) && !NetworkCards.targetIsLocked(nrTarget, nil),
              "targetIsLocked: not locked, or not read")
        check(NetworkCards.targetIsLocked(lteTarget, lteOne), "targetIsLocked: the one LTE cell")
        check(!NetworkCards.targetIsLocked(lteTarget, lteThree), "targetIsLocked: one of several is not the lock")
        check(NetworkCards.targetIsLocked(noScs, lockedNr), "targetIsLocked: a cell whose spacing is not reported, by its numbers")
        let other15 = CellLockState(lte: [], nr: NrCellLock(pci: 186, arfcn: 520110, scsKHz: 15, band: 41),
                                    persistLte: false, persistNr: false)
        check(!NetworkCards.targetIsLocked(nrTarget, other15), "targetIsLocked: a spacing reported must be the lock's")
        // The sheet's Lock: a cell in use is locked only while it still is (lockCellInUse); another as typed.
        check(NetworkCards.inUse(nr, among: [nrTarget, lteTarget]) && NetworkCards.inUse(nr, among: [noScs]),
              "inUse: a 5G SA cell in use")
        check(!NetworkCards.inUse(NrCellLock(pci: 187, arfcn: 520110, scsKHz: 30, band: 41), among: [nrTarget, noScs]),
              "inUse: another PCI is typed, not in use")
        check(!NetworkCards.inUse(NrCellLock(pci: 186, arfcn: 520110, scsKHz: 15, band: 41), among: [nrTarget]),
              "inUse: a spacing other than the one reported is not that cell")
        check(NetworkCards.inUse(LteLockedCell(earfcn: 66786, pci: 128), among: [lteTarget])
                && !NetworkCards.inUse(LteLockedCell(earfcn: 66786, pci: 129), among: [lteTarget]), "inUse: an LTE cell")

        let allNr = [25, 41, 71, 77, 78]
        let openBands = [set(.lte, allowed: [3, 66], supported: [3, 66]), set(.nsa, allowed: allNr, supported: allNr),
                         set(.sa, allowed: allNr, supported: allNr)]
        check(NetworkCards.lockSummary(cellLock: open, bands: openBands) == nil, "lockSummary: nothing locked")
        check(NetworkCards.lockSummary(cellLock: nil, bands: nil) == nil, "lockSummary: nothing read")
        equal(NetworkCards.lockSummary(cellLock: lockedNr, bands: nil), "5G SA cell n41 · PCI 186", "lockSummary: 5G SA cell")
        equal(NetworkCards.lockSummary(cellLock: lteOne, bands: nil), "LTE cell PCI 128", "lockSummary: LTE cell")
        equal(NetworkCards.lockSummary(cellLock: lteThree, bands: nil), "3 LTE cells", "lockSummary: LTE cells")
        let saLocked = [set(.lte, allowed: [3, 66], supported: [3, 66]), set(.nsa, allowed: [78], supported: allNr),
                        set(.sa, allowed: [71, 41, 25], supported: allNr)]
        equal(NetworkCards.lockSummary(cellLock: lockedNr, bands: saLocked),
              "5G SA cell n41 · PCI 186; 5G NSA band n78; 5G SA bands n25, n41, n71", "lockSummary: cell and bands")
        let many = Array(1...30)
        equal(NetworkCards.lockSummary(cellLock: nil, bands: [set(.lte, allowed: Array(1...12), supported: many)]),
              "LTE: 12 of 30 bands", "lockSummary: many bands counted")
    }

    static func neighbours() {
        let cells = [
            NeighbourCell(rat: "NR5G", kind: "inter", channel: 396250, pci: 412, rsrp: -101, rsrq: -14, sinr: 1),
            NeighbourCell(rat: "WCDMA", kind: nil, channel: 10700, pci: 77, rsrp: nil, rsrq: nil, sinr: nil),
            NeighbourCell(rat: "NR5G", kind: "intra", channel: 520110, pci: 147, rsrp: -97, rsrq: -13, sinr: 4),
            NeighbourCell(rat: "LTE", kind: "inter", channel: 5110, pci: 301, rsrp: -118, rsrq: -16, sinr: nil),
        ]
        let rows = NetworkCards.neighbourRows(cells)
        equal(rows.map { $0.pci }, ["147", "412", "301", "77"], "neighbours: strongest first, no RSRP last")
        equal(rows[0], NetworkCards.NeighbourRow(rat: "5G", frequency: "Same", pci: "147", channel: "520110",
                                                 rsrp: "-97 dBm", rsrq: "-13 dB", sinr: "4 dB", quality: 2),
              "neighbours: a 5G cell on the serving channel")
        equal(rows[1].frequency, "Other", "neighbours: another channel")
        equal(rows[2].quality, 1, "neighbours: a poor LTE RSRP")
        equal(rows[3], NetworkCards.NeighbourRow(rat: "WCDMA", frequency: "—", pci: "77", channel: "10700",
                                                 rsrp: "—", rsrq: "—", sinr: "—", quality: nil),
              "neighbours: nothing known but its numbers")
        equal(NetworkCards.neighbourRows([]), [], "neighbours: none")
    }
}
