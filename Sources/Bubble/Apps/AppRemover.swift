import AppKit
import Foundation

/// One file or folder to move to the Trash.
struct RemovalItem: Sendable, Hashable {
    var path: String
    var bytes: Double
    var isApp = false
    /// In /Library: always removed through the admin prompt.
    var isSystem = false
}

/// Something Bubble moved to the Trash itself, and where it went, so Undo can put it back.
struct TrashedItem: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case app, leftover, caskRecord }
    var original: String
    var trashed: String
    var kind: Kind
    var appName: String
}

/// An item left where it was, with a short reason for the tooltip.
struct LeftBehind: Sendable, Hashable {
    var path: String
    var reason: String
}

/// What happened to one app.
struct AppRemovalResult: Sendable {
    var app: AppInfo
    /// The app bundle is gone.
    var removed = false
    var freed: Double = 0
    var trashed: [TrashedItem] = []
    var leftBehind: [LeftBehind] = []
    /// The cask's Homebrew record went to the Trash too, so Homebrew no longer tracks the app.
    var untrackedCask = false
}

/// An item that needs admin rights, remembered until the single admin prompt at the end.
struct PendingAdmin: Sendable, Hashable {
    var owner: Int
    var item: RemovalItem
}

/// Removes apps without Mole: quits them, moves the app and its leftovers to the Trash,
/// batches what the user can't move into one admin prompt, and moves a Homebrew cask's
/// record to the Trash too. Never deletes anything outright; every path is re-validated
/// right before it's touched.
struct AppRemover: Sendable {
    enum QuitOutcome: Sendable { case notRunning, quit, stillRunning }
    struct ToolResult: Sendable { var status: Int32; var output: String }

    var roots: AppRoots = .live
    var uid: uid_t = getuid()
    var gid: gid_t = getgid()
    /// Moves an item to the Trash and returns where it ended up.
    var trash: @Sendable (String) throws -> String = { path in
        var out: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
        return out?.path ?? ""
    }
    var admin: @Sendable (_ script: String, _ prompt: String) async throws -> String = { try await Admin.run($0, prompt: $1) }
    var tool: @Sendable (_ exe: String, _ args: [String], _ env: [String: String]) async -> ToolResult = { await AppRemover.runTool($0, $1, env: $2) }
    var quit: @Sendable (_ path: String) async -> QuitOutcome = { await AppRemover.quitApp(path: $0) }
    var ownerUID: @Sendable (String) -> uid_t? = { AppLeftovers.ownerUID($0) }

    static let protectedReason = "Protected by macOS. Allow Full Disk Access, or remove it in Finder."

    // MARK: Per app

    /// Removes one app and the given items (its bundle and leftovers). Items that need
    /// admin rights are returned for `removeWithAdmin`, tagged with `owner`.
    func remove(_ app: AppInfo, items: [RemovalItem], owner: Int) async -> (AppRemovalResult, [PendingAdmin]) {
        var result = AppRemovalResult(app: app)
        func skipped(_ reason: String) -> (AppRemovalResult, [PendingAdmin]) {
            result.leftBehind.append(LeftBehind(path: app.path, reason: reason))
            return (result, [])
        }
        guard !AppLeftovers.isProtected(bundleId: app.bundleId, path: app.path) else {
            return skipped("\(app.name) is protected, so Bubble left it alone.")
        }
        guard AppLeftovers.validateAppBundle(app.path, roots: roots) else {
            return skipped("\(app.name) isn't in an Applications folder, so Bubble left it alone.")
        }
        // The list may be stale: refuse if a different app now sits at this path.
        let current = AppScanner.info(app.path)?["CFBundleIdentifier"] as? String ?? ""
        guard current == app.bundleId else {
            return skipped("\(app.name) changed since the list was read. Refresh and try again.")
        }
        if await quit(app.path) == .stillRunning {
            return skipped("\(app.name) wouldn't quit, so Bubble left it alone. Quit it and try again.")
        }

        var pending: [PendingAdmin] = []
        for item in items {
            guard AppLeftovers.exists(item.path) else { continue }
            let domain = item.isApp ? nil : AppLeftovers.validateLeftover(item.path, roots: roots)
            let valid = item.isApp ? item.path == app.path && AppLeftovers.validateAppBundle(item.path, roots: roots) : domain != nil
            guard valid else {
                result.leftBehind.append(LeftBehind(path: item.path, reason: "Outside the folders Bubble cleans."))
                continue
            }
            if item.isSystem || domain == .system {
                pending.append(PendingAdmin(owner: owner, item: RemovalItem(path: item.path, bytes: item.bytes, isApp: item.isApp, isSystem: true)))
                continue
            }
            if isUserLaunchAgent(item.path), let label = Self.launchLabel(item.path) {
                _ = await tool("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], [:])
            }
            do {
                try moveToTrash(item.path, kind: item.isApp ? .app : .leftover, into: &result)
                result.freed += item.bytes
            } catch {
                switch Self.blockedKind(error) {
                case .privacy? where !item.isApp, .ownership? where ownerUID(item.path) == uid:
                    // macOS privacy protection (TCC), or an item you already own: admin
                    // rights don't get past either, so don't ask for them.
                    result.leftBehind.append(LeftBehind(path: item.path, reason: Self.protectedReason))
                case .privacy?, .ownership?:
                    pending.append(PendingAdmin(owner: owner, item: item))
                case nil:
                    result.leftBehind.append(LeftBehind(path: item.path, reason: "Couldn't be moved to the Trash."))
                }
            }
        }
        result.removed = !AppLeftovers.exists(app.path)
        return (result, pending)
    }

    private func moveToTrash(_ path: String, kind: TrashedItem.Kind, into result: inout AppRemovalResult) throws {
        let dest = try trash(path)
        if !dest.isEmpty {
            result.trashed.append(TrashedItem(original: path, trashed: dest, kind: kind, appName: result.app.name))
        }
    }

    private func isUserLaunchAgent(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent == roots.library + "/LaunchAgents" && path.hasSuffix(".plist")
    }

    // MARK: Homebrew

    /// Once a cask's app is gone, moves its Caskroom folder (Homebrew's record of the cask)
    /// and the command-line links into it to the Trash, so Homebrew stops tracking it.
    /// `brew uninstall --cask` would instead run the cask's uninstall steps, whose `delete:`,
    /// `script:` and `pkgutil:` directives can remove files for good, including ones Bubble
    /// never showed. Undo puts the record back like any other item.
    func forgetCask(_ result: inout AppRemovalResult) {
        let token = result.app.uninstallName
        guard result.removed, result.app.isBrew, Self.isSafeCaskToken(token) else { return }
        for room in roots.caskrooms {
            let record = room + "/" + token
            guard AppLeftovers.exists(record), Self.validateCaskPath(record, roots: roots) else { continue }
            let bin = (room as NSString).deletingLastPathComponent + "/bin"
            for path in Self.caskLinks(in: bin, record: record) + [record] where Self.validateCaskPath(path, roots: roots) {
                do {
                    try moveToTrash(path, kind: .caskRecord, into: &result)
                } catch {
                    result.leftBehind.append(LeftBehind(path: path, reason: "Homebrew's record of the app couldn't be moved to the Trash."))
                }
            }
            result.untrackedCask = !AppLeftovers.exists(record)
        }
    }

    /// Symlinks in Homebrew's bin folder that point into the cask's Caskroom folder.
    static func caskLinks(in bin: String, record: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: bin)) ?? []).sorted().compactMap { name in
            let link = bin + "/" + name
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { return nil }
            let target = ((dest.hasPrefix("/") ? dest : bin + "/" + dest) as NSString).standardizingPath
            return target.hasPrefix(record + "/") ? link : nil
        }
    }

    /// A Caskroom entry, or a link in the bin folder next to a Caskroom, reached without
    /// symlinked folders.
    static func validateCaskPath(_ path: String, roots: AppRoots) -> Bool {
        guard let (parent, name) = AppLeftovers.splitChecked(path), !name.hasPrefix(".") else { return false }
        let allowed = roots.caskrooms + roots.caskrooms.map { ($0 as NSString).deletingLastPathComponent + "/bin" }
        guard allowed.contains(parent) else { return false }
        return AppLeftovers.resolvesLiterally(parent, anchor: (parent as NSString).deletingLastPathComponent)
    }

    /// A cask token is used as a folder name: no path characters, and never "." or "..".
    static func isSafeCaskToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix(".") && !token.hasPrefix("-")
            && token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.@+").contains($0) }
    }

    // MARK: Undo

    /// Moves each item back from the Trash. Never overwrites: an item whose original path
    /// is taken again, or no longer valid, stays in the Trash and is returned.
    static func restore(_ items: [TrashedItem], roots: AppRoots) -> [LeftBehind] {
        var failed: [LeftBehind] = []
        for item in items {
            let valid: Bool
            switch item.kind {
            case .app: valid = AppLeftovers.validateAppBundle(item.original, roots: roots)
            case .leftover: valid = AppLeftovers.validateLeftover(item.original, roots: roots) == .user
            case .caskRecord: valid = validateCaskPath(item.original, roots: roots)
            }
            let reason: String?
            if AppLeftovers.splitChecked(item.trashed)?.parent != roots.trash || !AppLeftovers.exists(item.trashed) {
                reason = "No longer in the Trash."
            } else if !valid {
                reason = "Its original folder changed."
            } else if AppLeftovers.exists(item.original) {
                reason = "Something new is at \(Fmt.abbreviate(item.original))."
            } else if (try? FileManager.default.moveItem(atPath: item.trashed, toPath: item.original)) == nil {
                reason = "Couldn't be put back."
            } else {
                reason = nil
            }
            if let reason { failed.append(LeftBehind(path: item.trashed, reason: reason)) }
        }
        return failed
    }

    // MARK: Admin batch

    struct AdminOutcome: Sendable {
        var removed: Set<String> = []
        /// Original path → where it landed in the Trash.
        var moved: [String: String] = [:]
        var cancelled = false
    }

    /// Moves every pending item to the user's Trash in one admin prompt. Each path is
    /// re-validated first; what's still there afterwards is reported as not removed.
    func removeWithAdmin(_ pending: [PendingAdmin], prompt: String) async -> AdminOutcome {
        var out = AdminOutcome()
        let items = pending.map(\.item).filter { item in
            item.isApp ? AppLeftovers.validateAppBundle(item.path, roots: roots)
                       : AppLeftovers.validateLeftover(item.path, roots: roots) != nil
        }
        guard !items.isEmpty else { return out }
        var output = ""
        do {
            output = try await admin(adminScript(items), prompt)
        } catch Admin.Failure.cancelled {
            out.cancelled = true
        } catch {}
        out.removed = Set(items.map(\.path).filter { !AppLeftovers.exists($0) })
        out.moved = Self.parseAdminMoves(output, items: items, trash: roots.trash)
            .filter { out.removed.contains($0.key) && AppLeftovers.exists($0.value) }
        return out
    }

    /// The root script: stop launchd jobs, then `mv` each item into ~/.Trash (with a
    /// Finder-style " 2" on name clashes). Moved items keep their owner: changing it as
    /// root could follow a hard link to a system file, and Finder asks for permission to
    /// empty them. Each move prints "moved <index> <n>", n being the clash number (1 for
    /// none), since paths don't survive the trip through sudo or osascript intact.
    func adminScript(_ items: [RemovalItem]) -> String {
        let q = Admin.quote
        var lines = [
            "T=\(q(roots.trash))",
            "fail=0",
            "[ -d \"$T\" ] || { mkdir -p \"$T\" && chown \(uid):\(gid) \"$T\" && chmod 700 \"$T\"; }",
            "mvtrash() {",
            "  dest=\"$T/$2$3\"; n=2; k=1",
            "  while [ -e \"$dest\" ] || [ -L \"$dest\" ]; do dest=\"$T/$2 $n$3\"; k=$n; n=$((n+1)); done",
            "  if /bin/mv -n -- \"$1\" \"$dest\"; then echo \"moved $4 $k\"; else fail=1; fi",
            "}",
        ]
        let sys = roots.systemLibrary
        for item in items {
            let parent = (item.path as NSString).deletingLastPathComponent
            if item.path.hasSuffix(".plist"), let label = Self.launchLabel(item.path) {
                if parent == sys + "/LaunchDaemons" {
                    lines.append("/bin/launchctl bootout \(q("system/" + label)) 2>/dev/null || true")
                } else if parent == sys + "/LaunchAgents" || parent == roots.library + "/LaunchAgents" {
                    lines.append("/bin/launchctl bootout \(q("gui/\(uid)/" + label)) 2>/dev/null || true")
                }
            }
        }
        for (i, item) in items.enumerated() {
            let (stem, ext) = Self.trashName(item.path)
            lines.append("mvtrash \(q(item.path)) \(q(stem)) \(q(ext)) \(i)")
        }
        lines.append("exit $fail")
        return lines.joined(separator: "\n")
    }

    /// Reads the script's "moved <index> <n>" lines back into original → Trash paths.
    static func parseAdminMoves(_ output: String, items: [RemovalItem], trash: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            guard f.count == 3, f[0] == "moved", let i = Int(f[1]), let n = Int(f[2]), items.indices.contains(i), n >= 1 else { continue }
            let (stem, ext) = trashName(items[i].path)
            out[items[i].path] = trash + "/" + stem + (n > 1 ? " \(n)" : "") + ext
        }
        return out
    }

    /// "Foo.app" → ("Foo", ".app"); other names keep their extension only when it's one
    /// Finder would keep apart from the number.
    static func trashName(_ path: String) -> (String, String) {
        let name = (path as NSString).lastPathComponent
        for ext in [".app", ".plist", ".savedState", ".binarycookies"] where name.hasSuffix(ext) && name.count > ext.count {
            return (String(name.dropLast(ext.count)), ext)
        }
        return (name, "")
    }

    // MARK: Helpers

    /// A launchd plist's Label (or its file name), if it's a plain reverse-DNS-like word.
    static func launchLabel(_ plist: String) -> String? {
        let fromFile = ((plist as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (NSDictionary(contentsOfFile: plist)?["Label"] as? String) ?? fromFile
        let ok = !label.isEmpty && !label.hasPrefix("-")
            && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
            && label.allSatisfy(\.isASCII)
        return ok ? label : nil
    }

    enum Blocked: Equatable { case privacy, ownership }

    /// Why a move failed for lack of rights: EPERM ("Operation not permitted") is macOS
    /// privacy protection (Full Disk Access, another app's container); EACCES or a bare
    /// no-permission error is file ownership, which admin rights fix. Nil for anything else.
    static func blockedKind(_ error: Error) -> Blocked? {
        var current: NSError? = error as NSError
        var cocoaPermission = false
        while let e = current {
            if e.domain == NSPOSIXErrorDomain {
                if e.code == Int(EPERM) { return .privacy }
                if e.code == Int(EACCES) { return .ownership }
            }
            if e.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code) {
                cocoaPermission = true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return cocoaPermission ? .ownership : nil
    }

    /// Runs a tool with stdin closed (so nothing can prompt), returning its exit status and
    /// combined output. Gives up after `timeout` seconds.
    static func runTool(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval = 300) async -> ToolResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                if let why = Shell.refusal(exe) {
                    cont.resume(returning: ToolResult(status: -1, output: why))
                    return
                }
                let p = Shell.makeProcess(exe, args, environment: Shell.childEnvironment(env))
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                let exited = p.exitSignal()
                do { try p.run() } catch {
                    cont.resume(returning: ToolResult(status: -1, output: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                exited.wait()
                cont.resume(returning: ToolResult(status: p.terminationStatus, output: Shell.clean(String(decoding: data, as: UTF8.self))))
            }
        }
    }

    /// Quits the app at `path` and everything running from inside its bundle (helpers such as
    /// Zoom's CptHost): asks nicely, then force-quits whatever is still open after a few
    /// seconds, so an app's own "Are you sure you want to quit?" can't stall the removal.
    /// Only the user's own processes are touched.
    @MainActor static func quitApp(path: String, grace: Duration = .seconds(3)) async -> QuitOutcome {
        let bundle = realPath(path)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL.map { isInside(realPath($0.path), bundle: bundle) } ?? false
        }
        let helpers = { processes(inside: bundle).subtracting(apps.map(\.processIdentifier)) }
        guard !apps.isEmpty || !helpers().isEmpty else { return .notRunning }

        func allGone() -> Bool { apps.allSatisfy(\.isTerminated) && helpers().isEmpty }
        func wait(_ limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if allGone() { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return allGone()
        }

        for app in apps { app.terminate() }
        if await wait(grace) { return .quit }
        for app in apps where !app.isTerminated { app.forceTerminate() }
        for pid in helpers() { kill(pid, SIGKILL) }
        return await wait(.seconds(2)) ? .quit : .stillRunning
    }

    /// The path as the kernel reports it (`proc_pidpath` keeps /private; Foundation drops it).
    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// True when `path` is `bundle` itself or inside it.
    static func isInside(_ path: String, bundle: String) -> Bool {
        path == bundle || path.hasPrefix(bundle.hasSuffix("/") ? bundle : bundle + "/")
    }

    /// The user's own processes whose executable lives inside `bundle`.
    static func processes(inside bundle: String) -> Set<pid_t> {
        let uid = getuid()
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var found: Set<pid_t> = []
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var info = proc_bsdshortinfo()
        for pid in pids.prefix(max(0, n)) where pid > 0 && pid != getpid() {
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                  info.pbsi_uid == uid,
                  proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            // proc_pidpath returns the real path; `bundle` must be one too (see `realPath`).
            if isInside(String(cString: buf), bundle: bundle) { found.insert(pid) }
        }
        return found
    }
}
