import SwiftUI

@main
struct BubbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var status = StatusModel.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    init() {
        // Launch arguments like `-lastTab Status` land in the argument domain, which
        // overrides saved settings for the whole session, so tab clicks would be ignored.
        // Dev builds (BUBBLE_DEV, used by scripts/shot.sh) persist them once; release
        // builds never write them. Either way the override is dropped.
        let defaults = UserDefaults.standard
        let args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let keys = ["lastTab", "appsSub"]
        guard keys.contains(where: { args[$0] != nil }) else { return }
        #if BUBBLE_DEV
        for key in keys {
            if let value = args[key] { defaults.set(value, forKey: key) }
        }
        #endif
        var rest = args
        for key in keys { rest[key] = nil }
        defaults.setVolatileDomain(rest, forName: UserDefaults.argumentDomain)
    }

    var body: some Scene {
        Window("Bubble", id: "main") {
            RootView()
                .environment(status)
                .frame(minWidth: 900, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .initialWindowSize()
        .commands {
            NavigationCommands()
            UpdateCommands()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarPanel()
                .environment(status)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel().environment(status)
        }
        .menuBarExtraStyle(.window)
    }
}

/// First-launch window size: about 80% of the screen, within a range where every
/// section lays out well. After that SwiftUI restores the user's own frame.
enum InitialWindow {
    static let minimum = CGSize(width: 1100, height: 760)
    static let maximum = CGSize(width: 1600, height: 1040)

    static func size(in visible: CGSize?) -> CGSize {
        guard let visible, visible.width > 0, visible.height > 0 else { return CGSize(width: 1280, height: 820) }
        func fit(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            // Never larger than the screen, even when that's below the minimum.
            min(min(max(v * 0.8, lo), hi), v).rounded()
        }
        return CGSize(width: fit(visible.width, minimum.width, maximum.width),
                      height: fit(visible.height, minimum.height, maximum.height))
    }
}

private extension Scene {
    // macOS 15's defaultWindowPlacement would read the display from its context, but
    // SceneBuilder can't branch on availability (no buildLimitedAvailability), so the
    // size comes from the main screen on every version.
    func initialWindowSize() -> some Scene {
        let screen = NSScreen.main ?? NSScreen.screens.first
        return defaultSize(InitialWindow.size(in: screen?.visibleFrame.size))
            .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process; make it a regular app,
        // unless the user chose to live in the menu bar only.
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: "menuBarOnly") ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
        // If a previous selective clean was interrupted, put the user's whitelist back.
        Whitelist.restoreIfNeeded()
        OptimizeWhitelist.restoreStale()
        StatusModel.shared.start()
        // Creating the updater starts Sparkle's scheduled background checks.
        _ = Updater.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    /// Posted by View ▸ Refresh (⌘R); `object` is the Tab to refresh.
    static let bubbleRefresh = Notification.Name("bubbleRefresh")
    static let bubbleShowDoctor = Notification.Name("bubbleShowDoctor")
}

/// View menu: ⌘1–⌘5 switch tabs, ⌘R refreshes the current one. Shares the
/// "lastTab" default with RootView, so the menu and the tab bar stay in sync.
struct NavigationCommands: Commands {
    @AppStorage("lastTab") private var tab: Tab = .clean

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.offset) { i, t in
                Button(t.rawValue) { tab = t }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button("Refresh") { NotificationCenter.default.post(name: .bubbleRefresh, object: tab) }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
        }
    }
}

/// Menu bar item: the bubbles symbol, live CPU, or both (Settings ▸ Menu Bar).
struct MenuBarLabel: View {
    @Environment(StatusModel.self) private var model
    @AppStorage("menuBarDisplay") private var display = "icon"
    @State private var awake = KeepAwake.shared

    var body: some View {
        let cpu = "\(Int((model.snap?.cpu?.usage ?? 0).rounded()))%"
        HStack(spacing: 4) {
            if display != "cpu" { Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "bubbles.and.sparkles") }
            if display != "icon" { Text(cpu).monospacedDigit() }
        }
    }
}

struct RootView: View {
    @AppStorage("lastTab") private var tab: Tab = .clean
    @State private var showDoctor = false
    @State private var mole = MoleInstall.shared

    var body: some View {
        VStack(spacing: 0) {
            // The section bar sits in the title bar strip, level with the traffic lights.
            // Hidden during setup: no section works until Mole is installed.
            ZStack {
                WindowDragArea()
                if !mole.setupActive {
                    SectionBar(selection: $tab).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: TopBar.height)

            ZStack {
                if mole.setupActive {
                    SetupView()
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(AppBackground())
        .animation(Motion.tab, value: mole.setupActive)
        .tint(Palette.accent)
        .background(CenteredSheets())
        .sheet(isPresented: $showDoctor) { DoctorSheet().preferredColorScheme(.dark) }
        .onReceive(NotificationCenter.default.publisher(for: .bubbleShowDoctor)) { _ in showDoctor = true }
        #if BUBBLE_DEV
        // Dev hook: `--args -showCheckup YES` opens Checkup on launch (for screenshots).
        .task { if UserDefaults.standard.bool(forKey: "showCheckup") { showDoctor = true } }
        #endif
    }

    // Keep each screen alive so scans and running jobs survive switching sections.
    private var content: some View {
        ZStack {
            screen(.clean) { CleanView() }
            screen(.apps) { AppsView() }
            screen(.optimize) { OptimizeView() }
            screen(.analyze) { AnalyzeView() }
            screen(.status) { StatusView() }
        }
        .animation(Motion.tab, value: tab)
    }

    private func screen<V: View>(_ t: Tab, @ViewBuilder _ view: () -> V) -> some View {
        let visible = tab == t
        return view()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .environment(\.screenVisible, visible)
    }
}

/// The strip at the top of the window that holds the section bar. It spans the title
/// bar, so the bar sits level with the traffic lights.
enum TopBar {
    static let height: CGFloat = 52
    static let barHeight: CGFloat = 36
}

/// The sections as one capsule at the top of the window: the Bubble logo (app menu),
/// then Clean, Apps, Optimize, Analyze and Status. The selected one is a solid white
/// capsule that slides between items.
struct SectionBar: View {
    @Binding var selection: Tab
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            LogoButton()
                .padding(.trailing, 4)
            ForEach(Tab.allCases) { t in
                SectionBarItem(tab: t, selected: selection == t, namespace: ns, slide: !reduceMotion) {
                    selection = t
                }
            }
        }
        .padding(3)
        .frame(height: TopBar.barHeight)
        .background(Capsule().fill(Color(hex: 0x05081A, opacity: 0.55)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        // ⌘1–⌘5 change the selection without a transaction, so animate on the value.
        .animation(reduceMotion ? Motion.reduced : Motion.spring, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct SectionBarItem: View {
    let tab: Tab
    let selected: Bool
    let namespace: Namespace.ID
    /// False under Reduce Motion: the highlight cross-fades instead of sliding.
    let slide: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // The bold label reserves the width, so items don't shift when the weight changes.
            ZStack {
                Text(tab.rawValue).font(.ui(.body, .bold)).hidden()
                Text(tab.rawValue)
                    .font(.ui(.body, selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Palette.abyss : hovering ? Palette.primary : Palette.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    if slide {
                        Capsule().fill(.white).matchedGeometryEffect(id: "selection", in: namespace)
                    } else {
                        Capsule().fill(.white)
                    }
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Bubble logo at the left of the section bar opens a menu of app-level actions.
struct LogoButton: View {
    @Environment(\.openSettings) private var openSettings
    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Button(action: showMenu) {
            BubbleView()
                .frame(width: 22, height: 22)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
                .background(MenuAnchorView(anchor: anchor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Bubble menu")
        .accessibilityLabel("Bubble menu")
    }

    /// The app menu: Settings, Checkup, Keep Screen On, Clean Screen, About, Updates.
    /// Opens just under the logo.
    private func showMenu() {
        guard let view = anchor.view, view.window != nil else { return }
        let openSettings = self.openSettings
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Settings…", symbol: "gearshape") { openSettings() })
        menu.addItem(ClosureMenuItem("Run Checkup", symbol: "stethoscope") {
            NotificationCenter.default.post(name: .bubbleShowDoctor, object: nil)
        })
        menu.addItem(.separator())
        let awake = ClosureMenuItem("Keep Screen On", symbol: "cup.and.saucer") { KeepAwake.shared.toggle() }
        awake.state = KeepAwake.shared.isOn ? .on : .off
        menu.addItem(awake)
        menu.addItem(ClosureMenuItem("Clean Screen", symbol: "paintbrush") { CleanScreen.shared.start() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("About Bubble", symbol: "info.circle") {
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(string: "Bubble is free and open source.\nCleaning is done by Mole by tw93 (GPL-3.0)."),
            ])
            NSApp.activate(ignoringOtherApps: true)
        })
        let update = ClosureMenuItem("Check for Updates…", symbol: "arrow.triangle.2.circlepath") { Updater.shared.checkForUpdates() }
        update.isEnabled = Updater.shared.canCheckForUpdates
        menu.autoenablesItems = false
        menu.addItem(update)
        // The menu's top-left corner goes 6pt below the view's bottom-left corner.
        let y = view.isFlipped ? view.bounds.maxY + 6 : view.bounds.minY - 6
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }
}

/// Holds the AppKit view behind a button so a menu can open right under it.
final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Empty space around the section bar drags the window, as a title bar would; a
/// double-click zooms or minimizes, following System Settings ▸ Desktop & Dock.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // An empty unified toolbar makes the title bar as tall as the strip, which
            // centres the traffic lights on the section bar. It has no items, so nothing shows.
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "BubbleMain")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                window?.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        }
    }
}

/// NSMenuItem that runs a Swift closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
