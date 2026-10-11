import CoreServices
import Foundation
import Security

/// Where apps and their leftovers live. Everything that finds, validates or removes app
/// files takes one of these, so tests can point it at a temporary folder.
struct AppRoots: Sendable, Equatable {
    var home: String
    /// /Applications and ~/Applications. Apps are listed from these and from one level of
    /// subfolders (e.g. /Applications/Utilities).
    var appFolders: [String]
    /// /Library: system-level leftovers.
    var systemLibrary: String
    /// Homebrew's Caskroom folders, read to tell which apps a cask manages.
    var caskrooms: [String]
    /// macOS's own apps (and one level of subfolders, so Utilities too). Read only so their
    /// names are never matched as another app's leftovers; never listed or removed.
    var systemAppFolders: [String] = []

    static let live: AppRoots = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AppRoots(home: home, appFolders: ["/Applications", home + "/Applications"], systemLibrary: "/Library",
                        caskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"], systemAppFolders: ["/System/Applications"])
    }()

    var library: String { home + "/Library" }
    var trash: String { home + "/.Trash" }

    /// Folders in ~/Library whose direct children may be an app's leftovers.
    static let userFolderNames = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Cookies", "LaunchAgents", "Application Scripts",
    ]
    /// Folders in /Library whose direct children may be an app's leftovers (bundle-id matches only).
    static let systemFolderNames = ["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools", "Application Support"]
    /// Folders in ~/Library also searched by exact app name.
    static let nameFolderNames = ["Application Support", "Caches", "Logs"]

    var userFolders: [String] { Self.userFolderNames.map { library + "/" + $0 } }
    var systemFolders: [String] { Self.systemFolderNames.map { systemLibrary + "/" + $0 } }
}

/// An installed app as far as leftover matching cares. Protected and Apple apps are
/// included too, so their files are never claimed by another app.
struct AppIdentity: Sendable, Hashable {
    var name: String
    var path: String
    var bundleId: String
    /// The .app folder name without ".app".
    var folderName: String {
        let n = (path as NSString).lastPathComponent
        return n.lowercased().hasSuffix(".app") ? String(n.dropLast(4)) : n
    }
}

struct Leftover: Identifiable, Hashable, Sendable {
    var path: String
    /// Allocated size; nil until measured.
    var bytes: Double?
    /// In /Library: removing it needs admin rights.
    var isSystem = false
    /// Another app's container while Bubble lacks Full Disk Access: macOS won't let Bubble
    /// move or measure it, so it's shown but never removed or counted.
    var isProtected = false
    var id: String { path }

    var isContainer: Bool { path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") }

    var kind: String {
        let p = path
        if p.hasSuffix(".app") { return "Application" }
        let map: [(String, String)] = [
            ("/Caches/", "Cache"), ("/Preferences/", "Preferences"),
            ("/Containers/", "Container"), ("/Group Containers/", "Group Container"), ("/Application Support/", "App Support"),
            ("/Application Scripts/", "App Scripts"), ("/Logs/", "Logs"), ("/WebKit/", "WebKit Data"), ("/HTTPStorages/", "HTTP Storage"),
            ("/Saved Application State/", "Saved State"), ("/LaunchAgents/", "Launch Agent"), ("/LaunchDaemons/", "Launch Daemon"),
            ("/PrivilegedHelperTools/", "Helper Tool"), ("/Cookies/", "Cookies"),
        ]
        return map.first { p.contains($0.0) }?.1 ?? "Data"
    }
}

/// A snapshot of every leftover folder's entries, read once and matched in memory, so
/// finding one app's leftovers (or every app's) takes milliseconds.
struct LeftoverIndex: Sendable {
    var entries: [String: [String]] = [:]
    /// Without Full Disk Access, ~/Library/Containers and Group Containers are never listed
    /// (macOS may ask "access data from other apps" or refuse); discovery probes exact
    /// paths there instead.
    var fullDiskAccess = true

    static func isContainerFolder(_ folder: String) -> Bool {
        folder.hasSuffix("/Library/Containers") || folder.hasSuffix("/Library/Group Containers")
    }

    static func read(_ roots: AppRoots, fullDiskAccess: Bool) -> LeftoverIndex {
        var out = LeftoverIndex(fullDiskAccess: fullDiskAccess)
        for folder in roots.userFolders + roots.systemFolders {
            if !fullDiskAccess, isContainerFolder(folder) { continue }
            // Names only: nothing inside is opened or followed.
            out.entries[folder] = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        }
        return out
    }
}

/// Finding and validating an app's files. Pure apart from reading folder listings and
/// resolving symlinks, so it can be unit tested against a fake home folder.
enum AppLeftovers {
    // MARK: Protected apps

    /// Never listed or removed. Apple's own apps are covered by the "com.apple." prefix.
    static let protectedBundleIds: Set<String> = ["com.jainnitin.bubble", "com.apple.safari", "com.apple.finder"]
    /// Apple, plus security and device-management agents that must be removed with their
    /// vendor's uninstaller (Mole refuses these too).
    static let protectedPrefixes = [
        "com.apple.", "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.",
        "com.jamfsoftware.", "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient",
    ]

    static func isProtected(bundleId: String, path: String) -> Bool {
        let lower = bundleId.lowercased()
        let p = Safety.normalize(path).lowercased()
        if p == "/system" || p.hasPrefix("/system/") { return true }
        if protectedBundleIds.contains(lower) { return true }
        if let own = Bundle.main.bundleIdentifier?.lowercased(), own == lower { return true }
        return protectedPrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: Bundle-id matching

    /// Reverse-DNS only (Mole's rule), so an id from a malformed Info.plist can't carry
    /// "/", "..", spaces or glob characters into a match.
    static func isValidBundleId(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, isAlnum(first) else { return false }
            return part.unicodeScalars.allSatisfy { isAlnum($0) || $0 == "-" }
        }
    }

    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
    }

    static let fileSuffixes = [".plist", ".savedState", ".binarycookies"]

    /// True when a folder entry belongs to `bundleId`: the id itself, the id plus a known
    /// file suffix ("com.foo.App.plist"), or, for ids with at least three parts, the id
    /// followed by a "." ("com.foo.App.helper"). "com.foo.AppPro" never matches "com.foo.App".
    static func entryMatches(_ name: String, bundleId: String) -> Bool {
        guard isValidBundleId(bundleId) else { return false }
        if name == bundleId { return true }
        if fileSuffixes.contains(where: { name == bundleId + $0 }) { return true }
        return parts(bundleId) >= 3 && name.hasPrefix(bundleId + ".")
    }

    /// Group containers are named "group.<id>", "<TEAMID>.<id>" or "<TEAMID>.<id>.<suffix>".
    /// Only ids with at least three parts get the team- or group-prefixed forms.
    static func groupContainerMatches(_ name: String, bundleId: String) -> Bool {
        if entryMatches(name, bundleId: bundleId) { return true }
        guard isValidBundleId(bundleId), parts(bundleId) >= 3 else { return false }
        return name.hasSuffix("." + bundleId) || name.contains("." + bundleId + ".")
    }

    private static func parts(_ id: String) -> Int { id.split(separator: ".").count }

    /// True when another installed app with an equal or more specific bundle id also
    /// matches the entry: "com.google.Chrome.canary.plist" belongs to Canary, not Chrome,
    /// and two copies of the same app share their data.
    static func claimedByOther(_ name: String, bundleId: String, others: [String], group: Bool) -> Bool {
        others.contains { other in
            guard other.count >= bundleId.count else { return false }
            return group ? groupContainerMatches(name, bundleId: other) : entryMatches(name, bundleId: other)
        }
    }

    // MARK: Name matching

    /// Words that name many unrelated things (Mole's list for launch agents, plus vendor
    /// and folder names). An app called one of these is never matched by name.
    static let genericNames: Set<String> = Set([
        "music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts", "messages", "reminders",
        "clock", "weather", "stocks", "books", "news", "podcasts", "voice", "files", "store", "system", "helper",
        "agent", "daemon", "service", "update", "updater", "sync", "backup", "cloud", "manager", "monitor", "server",
        "client", "worker", "runner", "launcher", "driver", "plugin", "plugins", "extension", "widget", "utility",
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "electron", "python", "java", "node",
        "code", "data", "default", "shared", "common", "local", "temp", "tmp", "cache", "caches", "logs", "log",
        "library", "application", "applications", "app", "apps", "support", "preferences", "containers",
        "settings", "config", "home", "user", "users", "desktop", "documents", "downloads", "crashreporter",
        "crashpad", "sparkle", "squirrel", "installer", "uninstaller", "setup", "test", "demo",
    ])

    /// A name specific enough to match a folder by: four or more characters, not generic,
    /// no path characters, not hidden.
    static func isSpecificAppName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.count >= 4, !n.hasPrefix("."), !n.contains("/"), !n.contains(":") else { return false }
        if n.allSatisfy({ $0.isNumber || $0 == " " || $0 == "." || $0 == "-" }) { return false }
        return !genericNames.contains(n.lowercased())
    }

    /// The app's display and folder names (lowercased) usable for name matching: specific,
    /// and not also the name of another installed app.
    static func matchableNames(_ app: AppIdentity, others: [AppIdentity]) -> Set<String> {
        let taken = Set(others.flatMap { [$0.name.lowercased(), $0.folderName.lowercased()] })
        return Set([app.name, app.folderName].filter(isSpecificAppName).map { $0.lowercased() }).subtracting(taken)
    }

    // MARK: Discovery

    /// The app's leftovers found in `index` (sizes not measured). `others` is every other
    /// installed app, including protected and Apple ones.
    static func discover(_ app: AppIdentity, others allOthers: [AppIdentity], index: LeftoverIndex, roots: AppRoots) -> [Leftover] {
        let others = allOthers.filter { $0.path != app.path }
        let otherIds = others.map(\.bundleId).filter(isValidBundleId)
        let bid = app.bundleId
        let useId = isValidBundleId(bid) && !isProtected(bundleId: bid, path: app.path)
        var out: [Leftover] = []
        var seen = Set<String>()

        func add(_ folder: String, _ name: String) {
            let path = folder + "/" + name
            guard !seen.contains(path), let domain = validateLeftover(path, roots: roots) else { return }
            seen.insert(path)
            out.append(Leftover(path: path, bytes: nil, isSystem: domain == .system))
        }

        if useId {
            for folder in roots.userFolders + roots.systemFolders {
                let isGroup = folder.hasSuffix("/Group Containers")
                if !index.fullDiskAccess, LeftoverIndex.isContainerFolder(folder) {
                    // Exact-path probes only: never list or read these folders.
                    for name in containerCandidates(app, group: isGroup, index: index, roots: roots) {
                        let lower = name.lowercased()
                        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") { continue }
                        let match = isGroup ? groupContainerMatches(name, bundleId: bid) : entryMatches(name, bundleId: bid)
                        guard match, !claimedByOther(name, bundleId: bid, others: otherIds, group: isGroup),
                              existence(folder + "/" + name) != .missing else { continue }
                        add(folder, name)
                    }
                    continue
                }
                let plistOnly = folder.hasSuffix("/LaunchAgents") || folder.hasSuffix("/LaunchDaemons") || folder.hasSuffix("/ByHost")
                for name in index.entries[folder] ?? [] {
                    let lower = name.lowercased()
                    if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") { continue }
                    if plistOnly, !name.hasSuffix(".plist") { continue }
                    let match = isGroup ? groupContainerMatches(name, bundleId: bid) : entryMatches(name, bundleId: bid)
                    guard match, !claimedByOther(name, bundleId: bid, others: otherIds, group: isGroup) else { continue }
                    add(folder, name)
                }
            }
        }

        let names = matchableNames(app, others: others)
        if !names.isEmpty {
            for folderName in AppRoots.nameFolderNames {
                let folder = roots.library + "/" + folderName
                for name in index.entries[folder] ?? [] where names.contains(name.lowercased()) {
                    add(folder, name)
                }
            }
        }
        return out.sorted { ($0.isSystem ? 1 : 0, $0.kind, $0.path) < ($1.isSystem ? 1 : 0, $1.kind, $1.path) }
    }

    // MARK: Path validation

    enum Domain: Equatable, Sendable { case user, system }

    /// Where a leftover may be removed from, or nil to refuse it. The path must be a direct
    /// child of one of the leftover folders, with no "." or ".." components, and no folder
    /// on the way from the home folder (or /) to it may be a symlink. The entry itself may be
    /// a symlink: it is trashed as a link and never followed.
    static func validateLeftover(_ path: String, roots: AppRoots) -> Domain? {
        guard let (parent, name) = splitChecked(path), !name.isEmpty else { return nil }
        if roots.userFolders.contains(parent) {
            return resolvesLiterally(parent, anchor: roots.home) && !isForbidden(path, roots: roots) ? .user : nil
        }
        if roots.systemFolders.contains(parent) {
            let anchor = (roots.systemLibrary as NSString).deletingLastPathComponent
            return resolvesLiterally(parent, anchor: anchor) && !isForbidden(path, roots: roots) ? .system : nil
        }
        return nil
    }

    /// True for an .app directly inside an app folder or one subfolder down
    /// (/Applications/Utilities/Foo.app), reached without symlinked folders.
    static func validateAppBundle(_ path: String, roots: AppRoots) -> Bool {
        guard let (parent, name) = splitChecked(path), name.lowercased().hasSuffix(".app"), name.count > 4 else { return false }
        for folder in roots.appFolders {
            let grand = (parent as NSString).deletingLastPathComponent
            guard parent == folder || (grand == folder && !parent.lowercased().hasSuffix(".app")) else { continue }
            let anchor = (folder as NSString).deletingLastPathComponent
            return resolvesLiterally(parent, anchor: anchor) && !isForbidden(path, roots: roots)
        }
        return false
    }

    /// Splits an absolute path into parent and last component, refusing relative paths
    /// and any empty, "." or ".." component.
    static func splitChecked(_ path: String) -> (parent: String, name: String)? {
        guard path.hasPrefix("/") else { return nil }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard comps.count >= 2, !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return ("/" + comps.dropLast().joined(separator: "/"), String(comps.last!))
    }

    /// True when `folder`, below `anchor`, contains no symlinks: its real path is the
    /// anchor's real path plus the same components.
    static func resolvesLiterally(_ folder: String, anchor: String) -> Bool {
        guard folder.hasPrefix(anchor == "/" ? "/" : anchor + "/"),
              let real = realPath(folder), let realAnchor = realPath(anchor) else { return false }
        let rel = anchor == "/" ? folder : String(folder.dropFirst(anchor.count))
        return real == (realAnchor == "/" ? "" : realAnchor) + rel
    }

    /// Places Bubble never removes, whatever matched.
    static func isForbidden(_ path: String, roots: AppRoots) -> Bool {
        let p = Safety.normalize(path)
        let lower = p.lowercased()
        for sys in ["/system", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db"] where lower == sys || lower.hasPrefix(sys + "/") {
            return true
        }
        let exact = ["/", roots.home, roots.library, roots.systemLibrary, roots.trash] + roots.appFolders + roots.userFolders + roots.systemFolders
        return exact.contains { Safety.normalize($0).lowercased() == lower }
    }

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// True when something exists at `path`, without following a final symlink.
    static func exists(_ path: String) -> Bool { existence(path) != .missing }

    /// The owner of `path` itself (lstat), or nil if it can't be read.
    static func ownerUID(_ path: String) -> uid_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_uid : nil
    }

    enum Existence: Equatable { case present, missing, protected }

    /// lstat only (never reads contents or follows a final symlink). EPERM/EACCES mean the
    /// path is protected, not missing.
    static func existence(_ path: String) -> Existence {
        var st = stat()
        if lstat(path, &st) == 0 { return .present }
        return errno == EPERM || errno == EACCES ? .protected : .missing
    }

    // MARK: Containers without Full Disk Access

    /// Names to probe in Containers or Group Containers when they can't be listed: the
    /// bundle id, its extensions (named in the unprotected ~/Library/Application Scripts),
    /// and group containers from the app's signature (team id and declared app groups).
    static func containerCandidates(_ app: AppIdentity, group: Bool, index: LeftoverIndex, roots: AppRoots) -> [String] {
        let bid = app.bundleId
        let scripts = (index.entries[roots.library + "/Application Scripts"] ?? []).filter { entryMatches($0, bundleId: bid) }
        guard group else { return Array(Set([bid] + scripts)).sorted() }
        let signing = signingInfo(app.path)
        var names = ["group." + bid] + signing.groups
        if let team = signing.team { names.append(team + "." + bid) }
        names += scripts.filter { $0 != bid }.map { "group." + $0 }
        // Only names that pass the boundary rule against our id are kept by the caller.
        return Array(Set(names.filter { !$0.contains("/") && $0 != "." && $0 != ".." })).sorted()
    }

    /// The app's team id and declared application groups, from its code signature.
    static func signingInfo(_ path: String) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, []) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return (team, ents?["com.apple.security.application-groups"] as? [String] ?? [])
    }

    // MARK: Sizes

    /// Allocated size of a file or folder tree (like `du`): never follows symlinks or
    /// crosses volumes, and counts hard-linked files once.
    static func allocatedSize(_ path: String) -> Double {
        var total: Int64 = 0
        var seen = Set<UInt64>()
        guard let c = strdup(path) else { return 0 }
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }
            guard let st = ent.pointee.fts_statp?.pointee else { continue }
            if st.st_nlink > 1, (st.st_mode & S_IFMT) != S_IFDIR {
                guard seen.insert(UInt64(st.st_ino)).inserted else { continue }
            }
            total += Int64(st.st_blocks) * 512
        }
        return Double(total)
    }

    // MARK: Homebrew casks

    /// App paths managed by a cask, from the "<token>/<version>/Foo.app" symlinks Homebrew
    /// leaves in the Caskroom. Also returns tokens with no app symlink (fonts, CLIs, or casks
    /// installed some other way), for which Bubble asks `brew info` instead.
    static func caskroomApps(_ caskrooms: [String]) -> (apps: [String: String], unresolved: [String]) {
        let fm = FileManager.default
        var apps: [String: String] = [:]
        var unresolved: [String] = []
        for room in caskrooms {
            for token in (try? fm.contentsOfDirectory(atPath: room)) ?? [] where !token.hasPrefix(".") {
                var found = false
                let tokenDir = room + "/" + token
                for version in (try? fm.contentsOfDirectory(atPath: tokenDir)) ?? [] where !version.hasPrefix(".") {
                    let vdir = tokenDir + "/" + version
                    for entry in (try? fm.contentsOfDirectory(atPath: vdir)) ?? [] where entry.lowercased().hasSuffix(".app") {
                        guard let dest = try? fm.destinationOfSymbolicLink(atPath: vdir + "/" + entry) else { continue }
                        let abs = dest.hasPrefix("/") ? dest : vdir + "/" + dest
                        apps[Safety.normalize(abs)] = token
                        found = true
                    }
                }
                if !found { unresolved.append(token) }
            }
        }
        return (apps, unresolved)
    }

    /// `brew info --json=v2 --installed --cask`: {"casks": [{"token", "artifacts": [{"app": ["Foo.app", {"target": …}], "target": …}]}]}.
    /// Returns app path → cask token.
    static func parseBrewInfoApps(_ data: Data, appdir: String = "/Applications") -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in (cask["artifacts"] as? [[String: Any]]) ?? [] {
                guard let app = artifact["app"] as? [Any], let source = app.first as? String else { continue }
                var target = (artifact["target"] as? String)
                    ?? (app.dropFirst().first as? [String: Any])?["target"] as? String
                    ?? (source as NSString).lastPathComponent
                if !target.hasPrefix("/") { target = appdir + "/" + target }
                out[Safety.normalize(target)] = token
            }
        }
        return out
    }
}

/// Lists installed apps without Mole.
enum AppScanner {
    /// Every .app in the folders and one level of their subfolders. Symlinked apps and
    /// folders are skipped.
    static func bundlePaths(_ folders: [String]) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        func children(_ dir: String) -> [URL] {
            (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        var out: [String] = []
        for folder in folders {
            for url in children(folder) {
                let v = try? url.resourceValues(forKeys: Set(keys))
                guard v?.isSymbolicLink != true, v?.isDirectory == true else { continue }
                if url.pathExtension.lowercased() == "app" {
                    out.append(folder + "/" + url.lastPathComponent)
                } else {
                    for inner in children(url.path) where inner.pathExtension.lowercased() == "app" {
                        let iv = try? inner.resourceValues(forKeys: Set(keys))
                        guard iv?.isSymbolicLink != true, iv?.isDirectory == true else { continue }
                        out.append(folder + "/" + url.lastPathComponent + "/" + inner.lastPathComponent)
                    }
                }
            }
        }
        return out
    }

    static func info(_ path: String) -> [String: Any]? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]
    }

    static func displayName(_ path: String) -> String {
        var n = FileManager.default.displayName(atPath: path)
        if n.lowercased().hasSuffix(".app") { n = String(n.dropLast(4)) }
        n = Safety.normalizeAppName(n)
        return n.isEmpty ? AppIdentity(name: "", path: path, bundleId: "").folderName : n
    }

    /// Info.plist's modification time: changes when the app updates, so a cached size
    /// can be reused until then.
    static func stamp(_ path: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/Contents/Info.plist")
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    struct Result: Sendable {
        var apps: [AppInfo]
        /// Every bundle found, including protected, Apple and macOS's own apps.
        var identities: [AppIdentity]
        var unresolvedCasks: [String]
    }

    /// Reads names, ids, versions and dates (fast). Sizes come from `cache` when the app
    /// hasn't changed since; the rest are left unsized.
    static func scan(_ roots: AppRoots, cache: [String: [Double]] = [:]) -> Result {
        let casks = AppLeftovers.caskroomApps(roots.caskrooms)
        var apps: [AppInfo] = []
        var identities: [AppIdentity] = []
        for path in bundlePaths(roots.systemAppFolders) {
            let bid = info(path)?["CFBundleIdentifier"] as? String ?? ""
            identities.append(AppIdentity(name: displayName(path), path: path, bundleId: bid))
        }
        for path in bundlePaths(roots.appFolders) {
            let info = info(path)
            let bid = info?["CFBundleIdentifier"] as? String ?? ""
            let name = displayName(path)
            identities.append(AppIdentity(name: name, path: path, bundleId: bid))
            guard !AppLeftovers.isProtected(bundleId: bid, path: path) else { continue }
            let md = MDItemCreate(kCFAllocatorDefault, path as CFString)
            let token = casks.apps[Safety.normalize(path)]
            let isMAS = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
            let cached = cache[path]
            let sized = cached.map { $0.count == 2 && $0[1] == stamp(path) } ?? false
            apps.append(AppInfo(
                name: name,
                bundleId: bid,
                source: token != nil ? "Homebrew" : isMAS ? "App Store" : "App",
                uninstallName: token ?? "",
                path: path,
                bytes: sized ? cached![0] : 0,
                version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String ?? "",
                lastUsed: md.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date },
                added: md.flatMap { MDItemCopyAttribute($0, kMDItemDateAdded) as? Date },
                menuBarOnly: (info?["LSUIElement"] as? Bool) == true || (info?["LSUIElement"] as? String) == "1",
                sized: sized,
                sparkleFeed: (info?["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
        return Result(apps: apps, identities: identities, unresolvedCasks: casks.unresolved)
    }
}
