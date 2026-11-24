// The menu bar item (a MenuBarExtra in RMNetApp, StatusView.swift): its icon (MenuBarLabel: the antenna, or the
// signal bars drawn by menuBarSignalImage, as chosen in Settings), and the panel it opens, the connection at a glance
// as the Overview shows it: the state's pill from the Driver screen's headline, the technology's badge, the bars with
// their word, the operator and the band from the network read over the AT port when the panel opens (with its time,
// or why it failed), the IPv4 address while the link is up, how many messages are unread (a click opens Messages), the
// window's quit lines while a quit waits, `Open RMNet`,
// a gear that opens Settings, and `Quit RMNet`. MenuBarStatus (MenuBarStatus.swift) holds the state and decides when
// the port is read; this file only shows it, with DesignKit's pieces.
import AppKit
import SwiftUI

extension MenuBarStatus {
    /// The app's one, on the registry, the system's listing (asked with a 10 s limit) and the network read with
    /// ModemService on `queue`, the queue the window's screens share for the AT port. The app delegate starts its
    /// polls at launch (`start`).
    /// The signal bars' reads are the app's background turn's (ModemPulse.swift, which the app delegate gives the
    /// bars' part to); they take the window's network read instead while it is fresh (`freshInfo`).
    static func forApp(queue: DispatchQueue,
                       freshInfo: @escaping () -> (info: NetworkInfo, at: Date)? = { nil }) -> MenuBarStatus {
        let manager = ExtensionManager()
        let service = ModemService()
        let status = MenuBarStatus(
            properties: { readDriverProperties() },
            modem: { readModemModel() },
            listing: { answer in
                manager.properties(timeout: 10) { reply in
                    if case .listed(let found) = reply { answer(found.map(ExtensionEntry.init)) } else { answer(nil) }
                }
            },
            network: { service.networkInfo() },
            queue: queue,
            freshInfo: freshInfo,
            preference: MenuBarIconPreference(defaults: .standard))
        return status
    }
}

/// The item's icon in the menu bar, in the style chosen in Settings: the antenna, struck through unless the link is
/// up; or the signal bars (menuBarSignalImage). Its title, the accessibility label, is not drawn. The only view of the
/// item that observes the model besides the panel.
struct MenuBarLabel: View {
    @ObservedObject var status: MenuBarStatus

    var body: some View {
        switch status.iconStyle {
        case .antenna:
            Label(status.icon.accessibilityLabel, systemImage: status.icon.symbolName)
                .labelStyle(.iconOnly)
        case .signal:
            let icon = status.signalIcon
            Image(nsImage: menuBarSignalImage(icon))
                .accessibilityLabel(Text(verbatim: icon.accessibilityLabel))
        }
    }
}

/// The signal bars as a template image for the menu bar (the system colours it), 16 pt high: four bars rising, those
/// up to the level filled and the others faint (or every bar outlined when the level is not known), then the
/// technology ("5G", "LTE") or a mark ("!" waiting for approval, "…" searching) in small bold type; a slash through
/// the bars when there is no connection or no driver; an airplane alone with the radio off. Dimmed while the level is
/// old.
func menuBarSignalImage(_ icon: MenuBarSignalIcon) -> NSImage {
    let alpha: CGFloat = icon.dimmed ? 0.45 : 1
    if icon.airplane, let plane = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
        let size = plane.size
        let image = NSImage(size: size, flipped: false) { rect in
            plane.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
    let barWidth: CGFloat = 3, gap: CGFloat = 1.5, height: CGFloat = 12, bottom: CGFloat = 2
    let barsWidth = 4 * barWidth + 3 * gap
    let word: String?
    switch icon.mark {
    case .exclamation: word = "!"
    case .ellipsis: word = "…"
    default: word = icon.text
    }
    let font = NSFont.systemFont(ofSize: 10, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)]
    let wordSize = word.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
    let width = ceil(barsWidth + (word == nil ? 0 : 2.5 + wordSize.width)) + 1
    let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        for i in 0..<4 {
            let barHeight = height * CGFloat(i + 1) / 4
            let rect = NSRect(x: 0.5 + CGFloat(i) * (barWidth + gap), y: bottom, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
            switch icon.bars {
            case .filled(let level):
                NSColor.black.withAlphaComponent(alpha * (i < level ? 1 : 0.25)).setFill()
                path.fill()
            case .outlined:
                NSColor.black.withAlphaComponent(alpha * 0.6).setStroke()
                let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 0.6, yRadius: 0.6)
                inset.lineWidth = 1
                inset.stroke()
            }
        }
        if icon.mark == .slash {
            // A gap cleared along the slash first, so it reads over filled bars.
            let from = NSPoint(x: 0, y: bottom - 0.5), to = NSPoint(x: barsWidth + 1, y: bottom + height + 0.5)
            context.saveGState()
            context.setBlendMode(.clear)
            let gapLine = NSBezierPath()
            gapLine.move(to: from)
            gapLine.line(to: to)
            gapLine.lineWidth = 3.5
            gapLine.stroke()
            context.restoreGState()
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let line = NSBezierPath()
            line.move(to: from)
            line.line(to: to)
            line.lineWidth = 1.5
            line.lineCapStyle = .round
            line.stroke()
        }
        if let word {
            (word as NSString).draw(at: NSPoint(x: barsWidth + 2.5, y: bottom - 1.5), withAttributes: attributes)
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// The panel, 290 pt wide: a compact version of the Overview's hero. The pill says Connected only while the
/// driver's link is up (connectionPill of the model's headline). The badge, the bars, the operator and the band come
/// from the last network read that succeeded (`info`), with its time; a value not known is "—". The word beside the
/// bars is signalCaption's: the radio off, searching or limited service when the modem says so, "Signal not known"
/// (outlined bars) when the signal is not known, never "No signal", else the bars' word. Without that read, its lines
/// if there are any. The IPv4 address (copyable) only while the link is up.
struct MenuBarPanel: View {
    @ObservedObject var status: MenuBarStatus
    // The controllers' quit lines (quitNoticeLines), shown above the buttons while a quit waits: `Quit RMNet`
    // pressed while a send or a change runs says why RMNet has not quit yet.
    @ObservedObject var quitNotice: SmsQuitNotice
    @ObservedObject var modemQuitNotice: ModemQuitNotice
    // How many messages are unread (the window's marks, kept up to date by the background check for new messages).
    @ObservedObject var unread: SmsUnreadNotice
    /// Shows the RMNet window, given the panel's own way of opening it (for when it is not open). The app
    /// passes AppDelegate.showStatusWindow, which brings an open window forward first.
    var showWindow: (_ open: @escaping () -> Void) -> Void = { open in
        open()
        NSApp.activate()
    }
    /// Asks the window for the Messages screen (WindowRouter), before showWindow opens it.
    var showMessages: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private static let width: CGFloat = 290
    private static let inset: CGFloat = 14

    var body: some View {
        let pill = connectionPill(status.headline)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .center, spacing: Spacing.s) {
                StatusPill(state: pill.state, text: pill.text)
                Spacer(minLength: Spacing.s)
                if let tech = status.info.flatMap(techBadgeText) {
                    TechBadge(text: tech)
                }
            }
            network
            readLine
            if let ipv4 {
                KeyValueRow(label: "IPv4", value: ipv4, copyable: true)
            }
            if unread.count > 0 || unread.onModem > 0 {
                Button {
                    showMessages()
                    let open = openWindow
                    showWindow { open(id: "status") }
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "envelope.badge.fill")
                            .foregroundStyle(.blue)
                        Text(verbatim: unreadLine(unread.count, onModem: unread.onModem))
                            .foregroundStyle(.primary)
                        Spacer(minLength: Spacing.s)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Messages")
            }
            let quitLines = quitNoticeLines(messages: quitNotice.line, modem: modemQuitNotice.line)
            if quitLines.isEmpty {
                Divider()
            } else {
                // The window's notice, from edge to edge of the panel, in place of the divider above the buttons.
                QuitNotice(lines: quitLines)
                    .padding(.horizontal, -MenuBarPanel.inset)
            }
            HStack {
                Button("Open RMNet") {
                    let open = openWindow
                    showWindow { open(id: "status") }
                }
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel(Text("Settings…"))
                // Through applicationShouldTerminate, so the quit gate still waits for a running send or change.
                Button("Quit RMNet") { NSApp.terminate(nil) }
            }
        }
        .padding(MenuBarPanel.inset)
        .frame(width: MenuBarPanel.width, alignment: .leading)
        .background(PanelShownObserver(shown: { status.panelOpened() }, hidden: { status.panelClosed() }))
    }

    /// The last network read: the bars and their word with the read's time, the operator and the band; or, with no
    /// NetworkInfo, the read's lines and time.
    @ViewBuilder private var network: some View {
        if let info = status.info {
            VStack(alignment: .leading, spacing: Spacing.s) {
                // The read's time beside the bars and their word, or under them when a long word leaves no room
                // ("Radio off (airplane mode)").
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Spacing.s) {
                        signal(info)
                        Spacer(minLength: Spacing.s)
                        asOf
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        signal(info)
                        asOf
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    KeyValueRow(label: "Operator", value: info.networkName ?? info.operatorName ?? "—")
                    KeyValueRow(label: "Band", value: bandText(info) ?? "—")
                }
            }
        } else if !status.networkLines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Lines(status.networkLines)
                asOf
            }
        }
    }

    /// The bars (outlined when the level is not known) and the word beside them (signalCaption).
    private func signal(_ info: NetworkInfo) -> some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            SignalBars(level: signalLevel(info), height: 16)
            Text(verbatim: signalCaption(info))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
    }

    /// "as of HH:mm:ss": when the read shown finished.
    @ViewBuilder private var asOf: some View {
        if let at = status.networkAt {
            Text(verbatim: asOfText(at))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// "Reading the modem…" while a read runs; else why the last one failed: a busy port in secondary colour (not a
    /// failure: the connection may well be up), any other failure in orange.
    @ViewBuilder private var readLine: some View {
        if status.reading {
            HStack(spacing: Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: menuBarReadingLine)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if let note = status.networkNote {
            let busy = note == menuBarBusyNote
            Label {
                Text(verbatim: note)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: busy ? "clock" : "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(busy ? Color.secondary : Color.orange)
        }
    }

    /// The address of the model's IPv4 line ("IPv4 10.62.238.140/29"), which it gives only while the link is up.
    private var ipv4: String? {
        let prefix = "IPv4 "
        return status.addressLines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
}

/// Lines of text one under the other, wrapped when long.
private struct Lines: View {
    let lines: [String]
    init(_ lines: [String]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Calls `shown` each time the panel's window comes on screen: when it becomes key (the menu bar panel does
/// when it opens) or becomes visible. Several calls for one opening are harmless: the model reads the port
/// at most once in 10 s. Nothing is called while the panel is not on screen, so the port is not read at
/// launch, and resigning key never calls it (menuBarPanelSignal), so no read starts as the panel closes.
/// Calls `hidden` when it is no longer on screen or the view leaves it, so that the model stops asking for
/// the listing. Whether the panel is on screen is read when the event comes; the call is made on a later turn
/// of the main queue, in order, since the first comes while SwiftUI inserts the view (viewDidMoveToWindow), when
/// the model's published values must not change.
private struct PanelShownObserver: NSViewRepresentable {
    let shown: () -> Void
    let hidden: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(shown: shown, hidden: hidden) }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onShown = shown
        view.onHidden = hidden
    }

    final class ObserverView: NSView {
        var onShown: () -> Void
        var onHidden: () -> Void   // not `hidden`: NSView has one
        private var tokens: [NSObjectProtocol] = []

        init(shown: @escaping () -> Void, hidden: @escaping () -> Void) {
            onShown = shown
            onHidden = hidden
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { stopObserving() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                signal(.detached)
                return
            }
            let center = NotificationCenter.default
            let events: [(Notification.Name, MenuBarPanelEvent)] = [
                (NSWindow.didBecomeKeyNotification, .becameKey),
                (NSWindow.didResignKeyNotification, .resignedKey),
                (NSWindow.didChangeOcclusionStateNotification, .occlusionChanged),
            ]
            for (name, event) in events {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.signal(event)
                })
            }
            signal(.attached)
        }

        private func signal(_ event: MenuBarPanelEvent) {
            let onScreen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            let call: () -> Void
            switch menuBarPanelSignal(event, onScreen: onScreen) {
            case .shown: call = onShown
            case .hidden: call = onHidden
            case nil: return
            }
            DispatchQueue.main.async { call() }
        }

        private func stopObserving() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
        }
    }
}
