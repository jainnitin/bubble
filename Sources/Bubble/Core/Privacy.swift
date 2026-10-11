import AppKit
import Observation

// MARK: - Full Disk Access state

/// Whether Bubble (and so every `mo` it starts) has Full Disk Access, kept current:
/// it is checked again each time Bubble comes to the front, so granting access in
/// System Settings and switching back updates every screen without a relaunch.
@Observable
@MainActor
final class FullDiskAccess {
    static let shared = FullDiskAccess()

    private(set) var isOn: Bool
    /// True after the user opened the Full Disk Access pane from Bubble and came back
    /// with it still off. That's when "Relaunch Bubble" is worth offering.
    private(set) var returnedWithoutGrant = false
    private var sentToSettings = false
    private var observer: NSObjectProtocol?

    private init() {
        isOn = SystemSettings.hasFullDiskAccess
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await FullDiskAccess.shared.refresh() }
        }
        Task { await refresh() }
    }

    /// Opens Privacy & Security ▸ Full Disk Access and remembers that we sent the user there.
    func openSettings() {
        sentToSettings = true
        SystemSettings.openFullDiskAccess()
    }

    /// Checks again. A grant applies to processes started after it, so a fresh child
    /// process is asked too: if it can read a protected file, new scans can as well,
    /// even when Bubble's own process still sees the old answer.
    func refresh() async {
        let child = await SystemSettings.childProcessHasFullDiskAccess()
        SystemSettings.noteChildProbe(child)
        let now = SystemSettings.hasFullDiskAccess
        if now != isOn { isOn = now }
        if sentToSettings {
            sentToSettings = false
            returnedWithoutGrant = !now
        } else if now {
            returnedWithoutGrant = false
        }
    }
}

// MARK: - Privacy guard (sandbox for scans)

/// Keeps Mole's scans from setting off macOS privacy prompts while Bubble has no Full
/// Disk Access.
///
/// Without Full Disk Access, macOS asks the user (once per kind, attributed to Bubble,
/// the responsible process of every `mo` it starts) the first time anything touches
/// Desktop, Documents, Downloads, another app's container ("would like to access data
/// from other apps"), the Photos library, the Music folder, cloud-storage folders or
/// removable volumes. `mo clean` and `mo analyze` walk most of these: Clean looks for
/// project caches in every top-level home folder, partial downloads in ~/Downloads and
/// caches inside sandboxed apps' containers; Analyze sizes the whole home folder. A first
/// scan could pop a dozen dialogs.
///
/// Mole has no option to skip those folders, so Bubble runs the scan under
/// `sandbox-exec` with a profile that refuses them. A refusal from the sandbox profile
/// comes before macOS's own privacy check, so no dialog appears; Mole just sees
/// "Operation not permitted" and moves on (verified with tccd's log: zero prompting
/// requests for a full `mo clean --dry-run` and a cold `mo analyze`). The skipped places
/// are listed in the UI instead of silently shrinking the totals.
///
/// Folders whose only gate is Full Disk Access (Trash, Mail, Messages, Safari) never
/// prompt; they're refused too so results are the same on every Mac. Desktop, Documents
/// and Downloads can each be allowed (Settings ▸ General, or "Scan anyway" in Analyze):
/// macOS then asks once, and never again whatever the answer.
enum PrivacyGuard {
    static let sandboxExec = "/usr/bin/sandbox-exec"
    static let allowedFoldersKey = "privacyAllowedFolders"

    /// The user folders macOS asks about one by one. Each can be allowed separately.
    enum Folder: String, CaseIterable, Identifiable {
        case desktop = "Desktop", documents = "Documents", downloads = "Downloads"
        var id: String { rawValue }
        var path: String { Shell.home + "/" + rawValue }
    }

    /// What a profile refuses, relative to the home folder (absolute when it starts with "/").
    /// Folders macOS prompts for or guards with Full Disk Access.
    static let deniedHomeSubpaths = [
        ".Trash",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Mobile Documents",   // iCloud Drive
        "Library/CloudStorage",       // Dropbox, Google Drive, OneDrive… (File Provider)
        "Music",                      // Media & Apple Music
        "/Volumes",                   // removable and network volumes
    ]
    /// Other apps' data: everything inside each app's folder in these is refused (their
    /// names can still be listed, which macOS allows).
    static let appDataFolders = ["Containers", "Group Containers", "Application Scripts", "Daemon Containers"]

    // MARK: Profile

    /// The sandbox profile for one scan. `allowing` lists the user folders the user chose to
    /// let macOS ask about. Nil when `home` can't be written into a profile safely.
    static func profile(home: String, allowing: Set<Folder> = []) -> String? {
        guard home.hasPrefix("/"), !home.contains("\""), !home.contains("\n"), !home.contains("\\") else { return nil }
        var subpaths = Folder.allCases.filter { !allowing.contains($0) }.map { home + "/" + $0.rawValue }
        subpaths += deniedHomeSubpaths.map { $0.hasPrefix("/") ? $0 : home + "/" + $0 }
        let h = regexEscape(home)
        let apps = appDataFolders.joined(separator: "|")
        var lines = [
            "(version 1)",
            "(allow default)",
            // Clean asks System Events which apps are running; that's an Automation prompt.
            // Mole falls back to lsappinfo when it's refused.
            "(deny appleevent-send)",
            "(deny file-read* file-write*",
        ]
        lines += subpaths.map { "  (subpath \"\($0)\")" }
        lines.append("  (regex #\"^\(h)/.*\\.photoslibrary(/|$)\")")
        lines.append("  (regex #\"^\(h)/Library/(\(apps))/[^/]+/\"))")
        lines.append("(deny file-read-data")
        lines.append("  (regex #\"^\(h)/Library/(\(apps))/[^/]+$\"))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Only refuses Apple events (Clean's System Events probe), for runs with Full Disk Access.
    static let appleEventsOnlyProfile = "(version 1)\n(allow default)\n(deny appleevent-send)\n"

    /// Escapes a literal path for an SBPL regex.
    static func regexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\.^$|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// `exe args` wrapped in `sandbox-exec -p profile`, or unchanged when `profile` is nil.
    static func command(_ exe: String, _ args: [String], profile: String?) -> (exe: String, args: [String]) {
        guard let profile else { return (exe, args) }
        return (sandboxExec, ["-p", profile, exe] + args)
    }

    // MARK: Current state

    static var allowedFolders: Set<Folder> {
        get { Set((UserDefaults.standard.stringArray(forKey: allowedFoldersKey) ?? []).compactMap(Folder.init(rawValue:))) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: allowedFoldersKey) }
    }

    /// True when scans run guarded: no Full Disk Access and `sandbox-exec` works here.
    static var isGuarding: Bool { !SystemSettings.hasFullDiskAccess && sandboxWorks }

    /// The profile for a Clean or Analyze run right now, or nil to run `mo` directly.
    /// `quietAppleEvents` also guards runs that have Full Disk Access against the
    /// System Events Automation prompt.
    static func currentProfile(quietAppleEvents: Bool = false) -> String? {
        guard sandboxWorks else { return nil }
        if !SystemSettings.hasFullDiskAccess, let p = profile(home: realHome, allowing: allowedFolders) { return p }
        return quietAppleEvents ? appleEventsOnlyProfile : nil
    }

    /// The home folder with every symlink resolved: the sandbox matches real paths.
    static let realHome: String = {
        guard let p = realpath(Shell.home, nil) else { return Shell.home }
        defer { free(p) }
        return String(cString: p)
    }()

    /// `sandbox-exec` is deprecated; check once that it's there and accepts our profile, so
    /// a future macOS without it falls back to running `mo` directly instead of failing.
    static let sandboxWorks: Bool = {
        guard FileManager.default.isExecutableFile(atPath: sandboxExec),
              let p = profile(home: realHome) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: sandboxExec)
        task.arguments = ["-p", p, "/usr/bin/true"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let exited = task.exitSignal()
        do { try task.run() } catch { return false }
        exited.wait()
        return task.terminationStatus == 0
    }()

    // MARK: What gets skipped (for the UI)

    struct Skipped: Identifiable, Hashable {
        var name: String
        var detail: String
        /// The user folder this is, when it can be allowed on its own.
        var folder: Folder?
        var id: String { name }
    }

    /// What a guarded Clean scan leaves out.
    static func cleanSkipped(allowing: Set<Folder> = allowedFolders) -> [Skipped] {
        var out = [
            Skipped(name: "Trash", detail: "Its size and contents"),
            Skipped(name: "Mail", detail: "Mail downloads and large attachments"),
            Skipped(name: "Other apps' data", detail: "Caches inside sandboxed apps such as Podcasts"),
        ]
        let user = Folder.allCases.filter { !allowing.contains($0) }
        if !user.isEmpty {
            let names = ListFormatter.localizedString(byJoining: user.map(\.rawValue))
            out.append(Skipped(name: names, detail: user == [.downloads]
                               ? "Unfinished browser downloads" : "Project caches, and unfinished downloads in Downloads"))
        }
        out.append(Skipped(name: "Cloud storage", detail: "Project caches in iCloud Drive, Dropbox and similar"))
        return out
    }

    /// Protected places directly inside `path` that a guarded Analyze scan didn't size,
    /// for the "Not scanned" list. Only places that exist are listed (a `stat` is allowed).
    static func analyzeLocked(in path: String?, home: String = Shell.home, allowing: Set<Folder> = allowedFolders,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [LockedPlace] {
        var out: [LockedPlace] = []
        func add(_ name: String, _ p: String, _ folder: Folder? = nil) {
            if exists(p) { out.append(LockedPlace(name: name, path: p, folder: folder)) }
        }
        switch path {
        case nil:
            // The overview: one pointer to the details inside Home.
            out.append(LockedPlace(name: "Some folders in Home", path: home, folder: nil))
        case home:
            for f in Folder.allCases where !allowing.contains(f) { add(f.rawValue, home + "/" + f.rawValue, f) }
            add("Music", home + "/Music")
            add("Trash", home + "/.Trash")
        case home + "/Library":
            add("Mail", home + "/Library/Mail")
            add("Messages", home + "/Library/Messages")
            add("Safari", home + "/Library/Safari")
            add("Other apps' data", home + "/Library/Containers")
            add("Shared app data", home + "/Library/Group Containers")
            add("iCloud Drive", home + "/Library/Mobile Documents")
            add("Cloud storage", home + "/Library/CloudStorage")
        case home + "/Pictures":
            let items = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Pictures")) ?? []
            for item in items.sorted() where item.hasSuffix(".photoslibrary") {
                add((item as NSString).deletingPathExtension, home + "/Pictures/" + item)
            }
        default:
            break
        }
        return out
    }

    struct LockedPlace: Identifiable, Hashable {
        var name: String
        var path: String
        /// Set for Desktop, Documents and Downloads: these can be scanned on their own after one macOS prompt.
        var folder: Folder?
        var id: String { path }
    }

    /// True when `path` is (inside) a place a guarded scan refuses. Used to hide the
    /// near-empty entries Mole reports for them.
    static func isLocked(_ path: String, home: String = Shell.home, allowing: Set<Folder> = allowedFolders) -> Bool {
        if path.hasSuffix(".photoslibrary") || path.contains(".photoslibrary/") { return true }
        return deniedRoots(home: home, allowing: allowing).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The top folders a guarded scan refuses (their own entries can still be looked up).
    static func deniedRoots(home: String = Shell.home, allowing: Set<Folder> = allowedFolders) -> [String] {
        var roots = Folder.allCases.filter { !allowing.contains($0) }.map { home + "/" + $0.rawValue }
        roots += deniedHomeSubpaths.map { $0.hasPrefix("/") ? $0 : home + "/" + $0 }
        roots += appDataFolders.map { home + "/Library/" + $0 }
        return roots
    }
}

// MARK: - Relaunch

enum AppRelaunch {
    /// Starts a fresh copy of Bubble, then quits this one. macOS applies a new Full Disk
    /// Access grant to a process when it starts.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }
}
