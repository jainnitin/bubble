import AppKit
import SwiftUI

/// The Settings window (⌘,): a sidebar of panes, like System Settings. Only settings
/// that map to something Bubble or Mole actually does.
///
/// Naming: Bubble is the app. Mole is the open-source command-line cleaner Bubble
/// runs to do the work, so "Mole" appears only where it's literally about Mole
/// (its version, its updates, its protected-items file).
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, protected, screen, menuBar, mole
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .protected: "Protected Items"
            case .screen: "Screen Tools"
            case .menuBar: "Menu Bar"
            case .mole: "Mole"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .protected: "lock.shield.fill"
            case .screen: "display"
            case .menuBar: "menubar.rectangle"
            case .mole: "terminal.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: Color(hex: 0x8B93B8)
            case .protected: Color(hex: 0x34B98A)
            case .screen: Color(hex: 0x5B7CFA)
            case .menuBar: Color(hex: 0x9B6DF2)
            case .mole: Color(hex: 0xD9873E)
            }
        }
    }

    @AppStorage("settingsPane") private var pane: Pane = .general
    @State private var protected = ProtectedItemsModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.cardStroke).frame(width: 1)
            Group {
                // The protected-items list scrolls itself and fills the pane.
                if pane == .protected {
                    paneBody.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { paneBody }
                }
            }
            .background(Palette.abyss)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 800, height: 580)
        .background(Palette.abyss)
        .background(InkTitlebar())
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .navigationTitle("Bubble Settings")
        .toolbarBackground(Palette.abyss, for: .windowToolbar)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(pane.title)
                .font(.ui(.title, .bold))
                .foregroundStyle(Palette.primary)
                .accessibilityAddTraits(.isHeader)
            detail
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, 44)
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) {
            ForEach(Pane.allCases) { p in
                HStack(spacing: Space.s) {
                    IconTile(symbol: p.symbol, tint: p.tint, size: 22)
                    Text(p.title).font(.ui(.body, .medium))
                    Spacer(minLength: 0)
                    if p == .protected, protected.isDirty {
                        Circle().fill(Palette.amber).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                .padding(.vertical, 2)
                .tag(p)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 40) }
        .background(Palette.sidebar)
        .frame(width: 210)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralPane()
        case .protected: ProtectedItemsPane(model: protected)
        case .screen: ScreenToolsPane()
        case .menuBar: MenuBarPane()
        case .mole: MolePane()
        }
    }
}

// MARK: - Building blocks

/// Lets the ink background run under a transparent title bar, so the Settings window
/// doesn't wear a grey system strip above the dark panes. Also centres the window over
/// Bubble's main window each time it opens, like every other dialog.
private struct InkTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { style(v.window, context.coordinator) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { style(v.window, context.coordinator) } }

    func makeCoordinator() -> Centering { Centering() }

    private func style(_ w: NSWindow?, _ centering: Centering) {
        guard let w else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.backgroundColor = NSColor(Palette.abyss)
        centering.attach(to: w)
    }

    /// SwiftUI reuses the Settings window across opens, so centre on every open, not once.
    @MainActor
    final class Centering {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var needsCentering = true

        func attach(to w: NSWindow) {
            if window !== w {
                window = w
                observers.forEach(NotificationCenter.default.removeObserver)
                let nc = NotificationCenter.default
                observers = [
                    nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.needsCentering = true }
                    },
                    // A reopened Settings window becomes key without SwiftUI updating this view.
                    nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.centerIfNeeded() }
                    },
                ]
                needsCentering = true
            }
            centerIfNeeded()
        }

        private func centerIfNeeded() {
            guard needsCentering, let w = window else { return }
            needsCentering = false
            center(w)
        }

        private func center(_ w: NSWindow) {
            let main = NSApp.windows.first { $0 !== w && $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue == "main" }
                ?? NSApp.windows.first { $0 !== w && $0.isVisible && $0.canBecomeMain }
            guard let main, let screen = main.screen ?? w.screen else { w.center(); return }
            let size = w.frame.size
            var origin = NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.midY - size.height / 2)
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
            w.setFrameOrigin(origin)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// A rounded, filled square holding an SF Symbol, as in System Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// On/Off and similar states, shown as a small coloured capsule with a dot.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.ui(.secondary, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A group of rows on one card, separated by hairlines.
struct SettingsGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(spacing: 0) {
                if #available(macOS 15, *) {
                    // Public subview API: a hairline between rows, none after the last.
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            row
                            if i < rows.count - 1 {
                                Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.leading, 56)
                            }
                        }
                    }
                } else {
                    content
                }
            }
            .panel(radius: Radius.row + 2, style: .continuous)
            if let footer {
                Text(footer)
                    .font(.ui(.secondary))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

/// Icon tile, title and one line of detail on the left; the control on the right.
struct SettingRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.body, .medium)).foregroundStyle(Palette.primary)
                if let detail {
                    Text(detail).font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.m)
            trailing
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }
}

/// A row whose control is a switch; the whole row reads as one toggle to VoiceOver.
struct ToggleRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
