import AppKit
import IOKit.pwr_mgt
import Observation
import ServiceManagement
import SwiftUI

// MARK: - Keep Screen On

/// Holds a power assertion so the display (and optionally the Mac) stays awake.
@Observable
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    enum Mode: String, CaseIterable, Identifiable {
        case screenAndWork = "Screen and work"
        case workOnly = "Work only"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .screenAndWork: "The display stays on and nothing sleeps."
            case .workOnly: "The display can sleep, but downloads and builds keep running."
            }
        }
    }

    private(set) var isOn = false
    private var assertion: IOPMAssertionID = 0

    var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "keepAwakeMode") ?? "") ?? .screenAndWork
    }

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        let type = mode == .screenAndWork ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Bubble Keep Screen On" as CFString, &assertion)
        isOn = ok == kIOReturnSuccess
    }

    func stop() {
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isOn = false
    }
}

// MARK: - Clean Screen

/// Covers every display with black so you can wipe the screen. Any click or key
/// ends it, and it exits on its own after the configured duration.
@MainActor
final class CleanScreen {
    static let shared = CleanScreen()
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var timer: Timer?

    var isActive: Bool { !windows.isEmpty }

    func start() {
        guard !isActive else { return }
        let minutes = max(UserDefaults.standard.integer(forKey: "cleanScreenMinutes"), 1)
        let endsAt = Date().addingTimeInterval(Double(minutes) * 60)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: CleanScreenHint(endsAt: endsAt, isMain: screen == NSScreen.main))
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        // Swallow input while active; any click or key ends it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.stop()
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { _ in
            MainActor.assumeIsolated { CleanScreen.shared.stop() }
        }
    }

    func stop() {
        guard isActive else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        NSCursor.unhide()
    }
}

private struct CleanScreenHint: View {
    let endsAt: Date
    let isMain: Bool
    @State private var visible = true

    var body: some View {
        ZStack {
            Color.black
            if isMain && visible {
                VStack(spacing: Space.s) {
                    Text("Wipe away").font(.ui(.title, .semibold))
                    Text("Click or press any key to finish. Ends on its own \(endsAt, style: .relative).")
                        .font(.ui(.body))
                }
                .foregroundStyle(.white.opacity(0.45))
                .transition(.opacity)
            }
        }
        .task {
            // The hint fades so it doesn't hide smudges.
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.8)) { visible = false }
        }
    }
}

// MARK: - System Settings, Finder, Terminal, clipboard

enum SystemSettings {
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    /// Files and folders only Full Disk Access can open. None of them makes macOS show a
    /// prompt: without access, opening them just fails. The system TCC database exists on
    /// every Mac, so the probe works even without Safari, Mail or a Trash.
    static let fullDiskAccessProbes: [String] = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        Shell.home + "/Library/Safari/Bookmarks.plist",
        Shell.home + "/.Trash",
        Shell.home + "/Library/Mail",
    ]

    /// Full Disk Access can't be queried directly; opening a protected file is the standard
    /// probe. Also true when a fresh child process could (see `childProcessHasFullDiskAccess`).
    /// Every Full Disk Access check in Bubble goes through here, including the
    /// `-simulateNoFullDiskAccess YES` dev switch.
    static var hasFullDiskAccess: Bool {
        #if BUBBLE_DEV
        if UserDefaults.standard.bool(forKey: "simulateNoFullDiskAccess") { return false }
        #endif
        if probeLock.withLock({ childProbe }) == true { return true }
        return fullDiskAccessProbes.contains { path in
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 { close(fd); return true }
            return false
        }
    }

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var childProbe: Bool?

    static func noteChildProbe(_ on: Bool) { probeLock.withLock { childProbe = on } }

    /// Asks a new process to read the system TCC database. macOS applies a Full Disk Access
    /// grant to processes started after it, so this sees a grant made while Bubble was
    /// running, which is what every `mo` Bubble starts from then on will get.
    static func childProcessHasFullDiskAccess() async -> Bool {
        let data = await Shell.output("/usr/bin/head", ["-c", "1", fullDiskAccessProbes[0]], timeout: 5)
        return !data.isEmpty
    }
}

enum Finder {
    /// Opens a Finder window with `path` selected.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

enum Terminal {
    static func open() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Used and total space on the startup disk.
enum VolumeInfo {
    static var root: (used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Double(v?.volumeTotalCapacity ?? 0)
        let free = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)
        return (max(total - free, 0), total)
    }
}

enum LaunchAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
