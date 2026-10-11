import AppKit
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage("skipIntro") private var skipIntro = false
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var fullDiskAccess = SystemSettings.hasFullDiskAccess
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            SettingsGroup(footer: (fullDiskAccess ? ""
                          : "Turn on Bubble in Privacy & Security, then come back. If it still shows Off, quit and reopen Bubble. ")
                          + "macOS extends this access to the tools Bubble runs: mo, brew, and developer tools such as npm, pip and go when Clean clears their caches.") {
                SettingRow(symbol: "externaldrive.fill.badge.checkmark", tint: Color(hex: 0x4F8CF0), title: "Full Disk Access",
                           detail: "Lets Bubble and Mole look inside Trash, Mail and other private folders.") {
                    HStack(spacing: Space.s) {
                        StatusPill(text: fullDiskAccess ? "On" : "Off", color: fullDiskAccess ? Palette.green : Palette.amber)
                            .accessibilityLabel("Full Disk Access is \(fullDiskAccess ? "on" : "off")")
                        if !fullDiskAccess {
                            Button("Open Settings") { SystemSettings.openFullDiskAccess() }
                        }
                        IconButton(systemName: "arrow.clockwise", label: "Check again") { fullDiskAccess = SystemSettings.hasFullDiskAccess }
                    }
                }
            }

            SettingsGroup {
                ToggleRow(symbol: "power", tint: Color(hex: 0x34B98A), title: "Open at login",
                          detail: "Start Bubble when you log in to your Mac.", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        guard on != LaunchAtLogin.isOn else { return }
                        do {
                            try LaunchAtLogin.set(on)
                            error = nil
                        } catch {
                            self.error = "macOS didn't allow it: \(error.localizedDescription) Move Bubble to Applications and try again."
                            launchAtLogin = LaunchAtLogin.isOn
                        }
                    }
                ToggleRow(symbol: "dock.rectangle", tint: Color(hex: 0x9B6DF2), title: "Menu bar only",
                          detail: "Hide Bubble's Dock icon. Open the window from the menu bar.", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, on in NSApp.setActivationPolicy(on ? .accessory : .regular) }
                ToggleRow(symbol: "bolt.fill", tint: Color(hex: 0xD9873E), title: "Open straight to results",
                          detail: "Clean scans and Analyze maps your disk as soon as you open them.", isOn: $skipIntro)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(.secondary)).foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = SystemSettings.hasFullDiskAccess
            launchAtLogin = LaunchAtLogin.isOn
        }
    }
}

// MARK: - Screen tools

struct ScreenToolsPane: View {
    @AppStorage("keepAwakeMode") private var keepAwakeMode = KeepAwake.Mode.screenAndWork.rawValue
    @AppStorage("cleanScreenMinutes") private var cleanScreenMinutes = 2

    var body: some View {
        SettingsGroup(footer: "Both are in the menu under the Bubble logo at the left of the tab bar.") {
            SettingRow(symbol: "cup.and.saucer.fill", tint: Color(hex: 0xD9873E), title: "Keep Screen On",
                       detail: (KeepAwake.Mode(rawValue: keepAwakeMode) ?? .screenAndWork).detail) {
                Picker("Keep Screen On", selection: $keepAwakeMode) {
                    ForEach(KeepAwake.Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            SettingRow(symbol: "sparkles", tint: Color(hex: 0x5B7CFA), title: "Clean Screen",
                       detail: "Blacks out the screen so you can wipe it. A click or any key ends it early.") {
                Picker("Clean Screen ends after", selection: $cleanScreenMinutes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("Ends after \($0) min").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarPane: View {
    @AppStorage("showMenuBarIcon") private var showIcon = true
    @AppStorage("menuBarDisplay") private var display = "icon"

    var body: some View {
        SettingsGroup {
            ToggleRow(symbol: "menubar.rectangle", tint: Color(hex: 0x9B6DF2), title: "Show in menu bar",
                      detail: "Click it for live status and quick actions.", isOn: $showIcon)
            SettingRow(symbol: "eye.fill", tint: Color(hex: 0x4F8CF0), title: "Menu bar shows", detail: nil) {
                HStack(spacing: Space.m) {
                    preview
                    Picker("Menu bar shows", selection: $display) {
                        Text("Icon").tag("icon")
                        Text("CPU").tag("cpu")
                        Text("Both").tag("both")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            .disabled(!showIcon)
            .opacity(showIcon ? 1 : 0.5)
        }
    }

    /// What the menu bar item will look like.
    private var preview: some View {
        HStack(spacing: 4) {
            if display != "cpu" { Image(systemName: "bubbles.and.sparkles") }
            if display != "icon" { Text("12%").monospacedDigit() }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.primary)
        .padding(.horizontal, 8).frame(height: 22)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}

// MARK: - Mole

struct MolePane: View {
    @State private var install = MoleInstall.shared
    @State private var latest: String?
    @State private var checking = false
    @State private var checked = false
    @State private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    private var bubbleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Bubble does its cleaning with Mole, a free, open-source command-line tool by tw93. Bubble shows what Mole finds and asks before anything is removed.")
                .font(.ui(.body)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if install.path == nil {
                SettingsGroup {
                    SettingRow(symbol: "exclamationmark.triangle.fill", tint: Palette.amber.opacity(0.9), title: "Mole isn't installed",
                               detail: "Bubble can't clean until it is. Setup installs it for you.") {
                        Button("Set Up Mole") {
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            } else {
                SettingsGroup {
                    SettingRow(symbol: "terminal.fill", tint: Color(hex: 0xD9873E), title: "Mole \(install.version ?? "")",
                               detail: install.installKind.map { "Installed with \($0)" }) {
                        statusPill
                    }
                    SettingRow(symbol: "folder.fill", tint: Color(hex: 0x4F8CF0), title: "Location",
                               detail: install.path.map(Fmt.abbreviate)) {
                        Button("Show in Finder") {
                            if let p = install.path { Finder.reveal(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) }
                        }
                    }
                    updateRow
                }
            }

            SettingsGroup {
                SettingRow(symbol: "chevron.left.forwardslash.chevron.right", tint: Color(hex: 0x8B93B8), title: "Mole on GitHub",
                           detail: "Source, release notes and issues. GPL-3.0.") {
                    Link("Open", destination: MoleInstall.repo)
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                Text("About Bubble").font(.ui(.section, .semibold)).foregroundStyle(Palette.primary)
                    .accessibilityAddTraits(.isHeader)
                SettingsGroup(footer: "Bubble is a separate project. It isn't Mole for Mac, the native app from Mole's author.") {
                    SettingRow(symbol: "bubbles.and.sparkles.fill", tint: Color(hex: 0x7C8CF8), title: "Bubble \(bubbleVersion)",
                               detail: "A free, open-source Mac app.") {
                        if Updater.isConfigured {
                            Button("Check for Updates") { updater.checkForUpdates() }
                                .disabled(!updater.canCheckForUpdates)
                        }
                    }
                    ToggleRow(symbol: "arrow.triangle.2.circlepath", tint: Color(hex: 0x34B98A),
                              title: "Automatically check for updates",
                              detail: Updater.isConfigured
                                  ? "Bubble checks GitHub once a day for a newer version."
                                  : "Not available in this build: it has no update feed configured.",
                              isOn: $updater.automaticallyChecksForUpdates)
                        .disabled(!Updater.isConfigured)
                        .opacity(Updater.isConfigured ? 1 : 0.5)
                }
            }
        }
        .task { await install.refresh() }
    }

    @ViewBuilder private var statusPill: some View {
        if case .outdated = install.state {
            StatusPill(text: "Needs update", color: Palette.amber)
        } else if let latest {
            StatusPill(text: "\(latest) available", color: Palette.amber)
        } else if checked {
            StatusPill(text: "Up to date", color: Palette.green)
        } else {
            StatusPill(text: "Installed", color: Palette.green)
        }
    }

    @ViewBuilder private var updateRow: some View {
        let method = install.updateMethod
        SettingRow(symbol: "arrow.down.circle.fill", tint: Color(hex: 0x34B98A), title: "Updates", detail: updateDetail(method)) {
            switch install.job {
            case .running:
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Button("Stop") { install.cancel() }
                }
            default:
                HStack(spacing: Space.s) {
                    if method == .brewUpgrade, latest == nil {
                        Button(checking ? "Checking…" : "Check") { Task { await checkForUpdate() } }
                            .disabled(checking)
                    }
                    Button("Update Mole") { install.start(method) }
                        .disabled(method == .brewUpgrade && checked && latest == nil)
                }
            }
        }
    }

    private func updateDetail(_ method: MoleInstall.Method) -> String {
        switch install.job {
        case .running: return install.log.last ?? "Starting…"
        case .failed(_, let why): return why
        case .succeeded: return "Updated to \(install.version ?? "the latest version")."
        case .idle:
            return method == .brewUpgrade ? "Runs brew upgrade mole." : "Runs mo update, Mole's own updater."
        }
    }

    private func checkForUpdate() async {
        guard !MoleInstall.isSimulating else { checked = true; return }
        checking = true
        defer { checking = false; checked = true }
        latest = await MoleInstall.homebrewLatest()
    }
}
