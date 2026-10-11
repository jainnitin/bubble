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
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process; make it a regular app,
        // unless the user chose to live in the menu bar only.
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: "menuBarOnly") ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
        // If a previous selective clean was interrupted, put the user's whitelist back.
        Whitelist.restoreIfNeeded()
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
        // A native sidebar instead of a row of tabs: keyboard navigation, VoiceOver
        // and the translucent sidebar material come from macOS.
        NavigationSplitView {
            Sidebar(selection: $tab)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ZStack {
                AppBackground()
                if mole.setupActive {
                    SetupView()
                } else {
                    content.padding(.top, Space.l)
                }
            }
            .animation(Motion.tab, value: mole.setupActive)
        }
        .toolbar(removing: .sidebarToggle)
        .tint(Palette.accent)
        .sheet(isPresented: $showDoctor) { DoctorSheet().preferredColorScheme(.dark) }
        .onReceive(NotificationCenter.default.publisher(for: .bubbleShowDoctor)) { _ in showDoctor = true }
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

struct Sidebar: View {
    @Binding var selection: Tab
    @Environment(StatusModel.self) private var status

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let t = $0 { selection = t } })) {
            ForEach(Tab.allCases) { t in
                Label(t.rawValue, systemImage: t.symbol)
                    .font(.ui(.body, .medium))
                    .tag(t)
            }
        }
        .listStyle(.sidebar)
        // A solid ink sidebar, a shade lighter than the window, instead of the grey system material.
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            LogoMenuButton()
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.s)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { vitals }
    }

    /// A glance at the machine from any section; click to open Status.
    private var vitals: some View {
        let s = status.snap
        let disk = status.rootDisk
        let free = max((disk?.total ?? 0) - (disk?.used ?? 0), 0)
        return Button { selection = .status } label: {
            VStack(alignment: .leading, spacing: 6) {
                vital("cpu", "CPU", s.map { "\(Int(($0.cpu?.usage ?? 0).rounded()))%" } ?? "—")
                vital("memorychip", "Memory", s.map { "\(Int(($0.memory?.usedPercent ?? 0).rounded()))%" } ?? "—")
                vital("internaldrive", "Free", disk == nil ? "—" : Fmt.bytes(free))
                if let t = status.cpuTemp { vital("thermometer.medium", "Temp", "\(Int(t.rounded()))°") }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(radius: Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .padding(Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Status")
    }

    private func vital(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(Palette.tertiary)
            Text(label).foregroundStyle(Palette.secondary)
            Spacer()
            Text(value).font(.num(.secondary, .medium)).foregroundStyle(Palette.primary)
        }
        .font(.ui(.secondary))
    }
}

/// The app name at the top of the sidebar opens a menu of app-level actions.
struct LogoMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: Space.s) {
                BubbleView().frame(width: 22, height: 22)
                Text("Bubble").font(.ui(.body, .semibold)).foregroundStyle(Palette.primary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .rowHover()
        }
        .buttonStyle(.quiet)
        .help("Bubble menu")
        .accessibilityLabel("Bubble menu")
    }

    private func showMenu() {
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
        menu.popUp(positioning: nil, at: NSPoint(x: NSEvent.mouseLocation.x - 20, y: NSEvent.mouseLocation.y - 26), in: nil)
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
