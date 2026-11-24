// The window's visual language, shared by every screen: cards (and the headings of their parts), the status pill,
// the state badge, the technology badge, the signal bars, the metric gauge, key and value rows, the result banner
// (and the slot at the bottom of a screen it shows in), the quit notice, empty states, the sheets' header, the warning
// and problem lines, and the spacing scale. The charts are in Charts.swift. The values drawn come
// from the pure models (SignalQuality.swift, ShellModel.swift); nothing here reads anything.
import AppKit
import SwiftUI

/// The spacing scale: 4, 8, 12, 16, 24 pt.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

// MARK: - Colours

extension ConnectionState {
    /// Green connected, yellow connecting, gray down, orange something to do, red error.
    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .down: return .gray
        case .attention: return .orange
        case .error: return .red
        }
    }
}

/// The bars' colour by level: 4 and 3 green, 2 yellow, 1 orange, 0 gray.
func signalTint(_ level: Int) -> Color {
    switch level {
    case 3...: return .green
    case 2: return .yellow
    case 1: return .orange
    default: return .gray
    }
}

/// A quality word's colour by level (the gauge's word, the Overview's Signal card word): signalTint's, except Fair (2),
/// whose yellow is about 1.4:1 as text on a light card. There it is a dark amber, #7A5C00, about 5.9:1 on the light
/// card (#F8F8F8); in dark appearance the system yellow (about 11:1 on the dark card, #242424). The bars and the zone
/// fills keep signalTint's and zoneFill's yellow.
func signalTextTint(_ level: Int) -> Color {
    level == 2 ? fairTextTint : signalTint(level)
}

private let fairTextTint = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? .systemYellow : NSColor(srgbRed: 0x7A / 255.0, green: 0x5C / 255.0, blue: 0, alpha: 1)
})

/// A quality zone's fill behind a chart or a gauge (1 poor … 4 excellent): excellent and good green (good fainter),
/// fair yellow, poor orange.
func zoneFill(_ level: Int) -> Color {
    switch level {
    case 4: return .green.opacity(0.16)
    case 3: return .green.opacity(0.07)
    case 2: return .yellow.opacity(0.13)
    default: return .orange.opacity(0.12)
    }
}

/// A technology's colour: 5G blue, LTE teal, anything else (3G) gray.
func techTint(_ text: String) -> Color {
    if text.hasPrefix("5G") { return .blue }
    if text.hasPrefix("LTE") { return .teal }
    return .gray
}

// MARK: - Card

/// A rounded panel (corner radius 12, 16 pt inside) on the window's secondary background, with an optional title
/// row: an SF Symbol, the title in `.title3`, and a trailing accessory (a button, a badge).
struct Card<Accessory: View, Content: View>: View {
    let title: String?
    let symbol: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if title != nil || symbol != nil {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if let title {
                        Text(verbatim: title)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: Spacing.s)
                    accessory
                }
            }
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// The card's shape and fill, with a hairline edge so it holds in light and dark.
struct CardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(.background.secondary)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The heading of one part of a card ("Carriers", "Antennas", "Neighbour cells"), with an optional note at the
/// trailing edge ("Primary first"): every part of every card is headed the same way.
struct CardSectionHeading: View {
    let title: String
    var note: String? = nil

    init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(verbatim: title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.s)
            if let note {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Status pill, state badge, technology badge, signal bars

/// A dot and words in a capsule: the connection's state (ConnectionState.tint), pulsing while connecting.
/// `prominent`: the Overview's version, the words in `.largeTitle` weight and no capsule.
struct StatusPill: View {
    let state: ConnectionState
    let text: String
    var prominent = false

    var body: some View {
        HStack(spacing: prominent ? Spacing.s + 2 : 6) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .font(prominent ? .title2 : .caption)
                .foregroundStyle(state.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: state == .connecting)
            Text(verbatim: text)
                .font(prominent ? .largeTitle.weight(.semibold) : .callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, prominent ? 0 : 10)
        .padding(.vertical, prominent ? 0 : 4)
        .background {
            if !prominent { Capsule().fill(state.tint.opacity(0.15)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Status: \(text)"))
    }
}

/// A state that is not the connection's (a lock, a result) as a symbol and words in a tinted capsule: "Locked" orange
/// with a closed lock, "Not locked" gray with an open one, "Succeeded" green. Not the status pill, whose dot and
/// colours mean the connection's state.
struct StateBadge: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol)
                .imageScale(.small)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// The technology in a tinted capsule ("5G SA", "5G NSA", "LTE", "3G"): 5G blue, LTE teal, 3G gray.
struct TechBadge: View {
    let text: String

    var body: some View {
        let tint = techTint(text)
        Text(verbatim: text)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Technology: \(text)"))
    }
}

/// Four ascending bars, as many filled as the level (0…4), tinted by it (signalTint); nil: unknown, every bar an
/// outline (0, no signal, is four empty bars). VoiceOver reads "3 of 4 bars, good" (or "unknown").
struct SignalBars: View {
    let level: Int?
    var height: CGFloat = 14

    var body: some View {
        let filled = max(0, min(4, level ?? 0))
        let width = max(3, height / 4)
        HStack(alignment: .bottom, spacing: max(1.5, width / 2.5)) {
            ForEach(0..<4, id: \.self) { i in
                let bar = RoundedRectangle(cornerRadius: width / 3, style: .continuous)
                Group {
                    if level == nil {
                        bar.strokeBorder(.tertiary, lineWidth: 1)
                    } else {
                        bar.fill(i < filled ? AnyShapeStyle(signalTint(filled)) : AnyShapeStyle(.quaternary))
                    }
                }
                .frame(width: width, height: height * CGFloat(i + 1) / 4)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Signal"))
        .accessibilityValue(Text(verbatim: level.map {
            "\(max(0, min(4, $0))) of 4 bars, \(signalWord($0).lowercased())"
        } ?? "unknown"))
    }
}

// MARK: - Metric gauge

/// One metric (RSRP, RSRQ, SINR) on a linear gauge over its range, the track shaded by its quality zones, with the
/// number, its unit and the quality word (signalWord of the zone it falls in). No value: "—".
struct MetricGauge: View {
    let title: String
    let value: Double?
    let unit: String
    let range: ClosedRange<Double>
    var zones: [QualityZone] = []

    init(title: String, value: Double?, unit: String, range: ClosedRange<Double>, zones: [QualityZone] = []) {
        self.title = title
        self.value = value
        self.unit = unit
        self.range = range
        self.zones = zones
    }

    /// A leg's metric with its own name, unit, range and zones (SignalQuality.swift).
    init(_ metric: SignalMetric, value: Double?, rat: String) {
        self.init(title: metric.title(rat: rat), value: value, unit: metric.unit, range: metric.range(rat: rat),
                  zones: qualityZones(metric, rat: rat))
    }

    /// The zone the value falls in (a value outside the range counts at its edge).
    private var quality: Int? {
        guard let value, !zones.isEmpty else { return nil }
        let v = min(max(value, range.lowerBound), range.upperBound)
        return zones.last(where: { v >= $0.lower })?.level ?? zones.first?.level
    }

    private var valueText: String {
        guard let value else { return "—" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs + 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s)
                Text(verbatim: valueText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if value != nil {
                    Text(verbatim: unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ZoneTrack(range: range, zones: zones, value: value)
                .frame(height: 8)
            Text(verbatim: quality.map { signalWord($0) } ?? (value == nil ? "Not known" : " "))
                .font(.caption)
                .foregroundStyle(quality.map { signalTextTint($0) } ?? .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: value == nil ? "not known"
                                 : "\(valueText) \(unit)" + (quality.map { ", \(signalWord($0).lowercased())" } ?? "")))
    }
}

/// The gauge's track: the range in its zones' colours (a plain track without zones), and a marker at the value.
private struct ZoneTrack: View {
    let range: ClosedRange<Double>
    let zones: [QualityZone]
    let value: Double?

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) -> CGFloat in
                CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) * geo.size.width
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                ForEach(zones, id: \.level) { z in
                    Rectangle()
                        .fill(zoneFill(z.level).opacity(3))
                        .frame(width: max(0, x(z.upper) - x(z.lower)))
                        .offset(x: x(z.lower))
                }
                if let value {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: geo.size.height + 6)
                        .offset(x: min(max(0, x(value) - 1.5), geo.size.width - 3), y: 0)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .clipShape(Capsule().inset(by: -3))
        }
    }
}

// MARK: - Rows, banners, notices, empty states

/// A label (secondary) and its value (primary, monospaced digits, selectable), the value at the trailing edge; with
/// `copyable`, a copy button before the value shows while the pointer is over the row (always there for VoiceOver).
struct KeyValueRow: View {
    let label: String
    let value: String
    var copyable = false
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .opacity(hovering || copied ? 1 : 0)
                .accessibilityLabel(Text(verbatim: "Copy \(label)"))
            }
            Text(verbatim: value)
                .monospacedDigit()
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A result line as a banner: a spinner while its request runs, a green check after a change that succeeded, an orange
/// triangle after one that succeeded with something to read, a red exclamation after one that did not; the
/// controller's words unchanged (selectable), and a dismiss button.
struct Banner: View {
    let text: String
    let kind: ResultKind
    let onDismiss: () -> Void

    init(text: String, kind: ResultKind, onDismiss: @escaping () -> Void) {
        self.text = text
        self.kind = kind
        self.onDismiss = onDismiss
    }

    var body: some View {
        let tint: Color = switch kind {
        case .progress: .accentColor
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Group {
                switch kind {
                case .progress:
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                        .accessibilityLabel(Text("Done"))
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(tint)
                        .accessibilityLabel(Text("Warning"))
                case .failure:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(tint)
                        .accessibilityLabel(Text("Failed"))
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            // Not fixedSize: a text fixed at its height for any width makes the window's minimum height (measured
            // at a width near 0) enormous. The slot gives the banner its height for the screen's width.
            Text(verbatim: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s + 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape.fill(.regularMaterial)
                .overlay(shape.fill(tint.opacity(0.08)))
                .overlay(shape.strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        }
    }
}

extension View {
    /// The screen's banner slot: its controller's result line (`text`; "" for none) as a Banner at the bottom of the
    /// screen, over its content's inset. Its X calls `dismiss`, which clears the line in the controller (so it stays
    /// away on every screen and in a new window); `hover` tells the controller where the pointer is, so that a success
    /// does not go by itself while it is being read (ResultLine.swift). Attach it to the screen's root.
    func resultBanner(_ text: String, kind: ResultKind, dismiss: @escaping () -> Void,
                      hover: @escaping (Bool) -> Void) -> some View {
        modifier(ResultBannerSlot(text: text, kind: kind, dismiss: dismiss, hover: hover))
    }
}

private struct ResultBannerSlot: ViewModifier {
    let text: String
    let kind: ResultKind
    let dismiss: () -> Void
    let hover: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !text.isEmpty {
                    Banner(text: text, kind: kind, onDismiss: dismiss)
                        .onHover(perform: hover)
                        .onDisappear { hover(false) }
                        .padding(.horizontal, Spacing.l)
                        .padding(.bottom, Spacing.m)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: text)
    }
}

/// A line above the screen while a quit waits for a call to the modem (quitNoticeLines), its words unchanged. It
/// takes its height before the screen does (layout priority); its text is not fixedSize, which would make the
/// window's minimum height enormous.
struct QuitNotice: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s + 2)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .layoutPriority(1)
        }
    }
}

/// A screen (or a card) with nothing to show yet: a symbol, a title, a line of explanation, and an action.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var action: (title: String, perform: () -> Void)? = nil

    init(symbol: String, title: String, message: String? = nil, action: (title: String, perform: () -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(verbatim: message) }
        } actions: {
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A chart's place while it has nothing to draw: "Collecting…" for the first samples, "No signal data" when the
/// values are unknown; the chart's own height, so the layout does not jump.
struct ChartPlaceholder: View {
    let text: String
    var height: CGFloat = 120

    var body: some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Sheets

/// A sheet's header: its symbol (secondary, or orange for a sheet that asks for care), its title in `.title3` and a
/// line under it. Every sheet of the window starts with one.
struct SheetHeader: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A caution (what a change does to the connection, above a sheet's buttons; what not to do, under a screen's
/// buttons): an orange triangle and the words in secondary.
struct WarningNote: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// A rule that what is typed breaks, or a request that failed: a red exclamation and the words.
struct ProblemNote: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
    }
}
