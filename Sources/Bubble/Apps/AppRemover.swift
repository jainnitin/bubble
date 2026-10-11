import AppKit
import Foundation

/// One file or folder to move to the Trash.
struct RemovalItem: Sendable, Hashable {
    var path: String
    var bytes: Double
    var isApp = false
    /// In /Library: always removed through the admin dialog.
    var isSystem = false
}

/// What happened to one app.
struct AppRemovalResult: Sendable {
    var app: AppInfo
    /// The app bundle is gone.
    var removed = false
    var freed: Double = 0
    var problems: [String] = []
    var viaHomebrew = false
    /// Items macOS privacy protection refused to move (e.g. another app's container):
    /// they need Full Disk Access, not admin rights.
    var blockedByPrivacy: [String] = []
}

/// An item that needs admin rights, remembered until the single admin prompt at the end.
struct PendingAdmin: Sendable, Hashable {
    var owner: Int
    var item: RemovalItem
}

/// Removes apps without Mole: quits them, runs `brew uninstall --zap` for casks, moves
/// everything else to the Trash, and batches what the user can't move into one admin
/// prompt. Never deletes anything outright; every path is re-validated right before it's touched.
struct AppRemover: Sendable {
    enum QuitOutcome: Sendable { case notRunning, quit, stillRunning }
    struct ToolResult: Sendable { var status: Int32; var output: String }

    var roots: AppRoots = .live
    var brewPath: String? = Shell.brew
    var uid: uid_t = getuid()
    var gid: gid_t = getgid()
    var trash: @Sendable (String) throws -> Void = { path in
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
    var admin: @Sendable (_ script: String, _ prompt: String) async throws -> String = { try await Admin.run($0, prompt: $1) }
    var tool: @Sendable (_ exe: String, _ args: [String], _ env: [String: String]) async -> ToolResult = { await AppRemover.runTool($0, $1, env: $2) }
    var quit: @Sendable (_ path: String) async -> QuitOutcome = { await AppRemover.quitApp(path: $0) }

    // MARK: Per app

    /// Removes one app and the given items (its bundle and leftovers). Items that need
    /// admin rights are returned for `removeWithAdmin`, tagged with `owner`.
    func remove(_ app: AppInfo, items: [RemovalItem], owner: Int) async -> (AppRemovalResult, [PendingAdmin]) {
        var result = AppRemovalResult(app: app)
        guard !AppLeftovers.isProtected(bundleId: app.bundleId, path: app.path) else {
            result.problems.append("\(app.name) is protected and was not removed.")
            return (result, [])
        }
        guard AppLeftovers.validateAppBundle(app.path, roots: roots) else {
            result.problems.append("\(app.name) isn't in an Applications folder, so Bubble left it alone.")
            return (result, [])
        }
        // The list may be stale: refuse if a different app now sits at this path.
        let current = AppScanner.info(app.path)?["CFBundleIdentifier"] as? String ?? ""
        guard current == app.bundleId else {
            result.problems.append("\(app.name) changed since the list was read. Refresh and try again.")
            return (result, [])
        }
        switch await quit(app.path) {
        case .stillRunning:
            result.problems.append("\(app.name) is still open and was skipped. Quit it and try again.")
            return (result, [])
        case .notRunning, .quit: break
        }

        if app.isBrew, let brew = brewPath, isSafeCaskToken(app.uninstallName) {
            let r = await tool(brew, ["uninstall", "--cask", "--zap", app.uninstallName],
                               ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"])
            if r.status == 0 {
                result.viaHomebrew = true
            } else if !Self.needsAdmin(r.output) {
                let last = r.output.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                result.problems.append("Homebrew couldn't remove \(app.name)" + (last.map { ": \($0.trimmingCharacters(in: .whitespaces))" } ?? "."))
                return (result, [])
            }
            // Needs sudo, which Homebrew can't ask for here: fall through to the native path.
        }

        var pending: [PendingAdmin] = []
        for item in items {
            guard AppLeftovers.exists(item.path) else {
                // Already gone (Homebrew's zap, or the app's own cleanup).
                if result.viaHomebrew { result.freed += item.bytes }
                continue
            }
            let valid = item.isApp ? (item.path == app.path && AppLeftovers.validateAppBundle(item.path, roots: roots))
                                   : AppLeftovers.validateLeftover(item.path, roots: roots) != nil
            guard valid else {
                result.problems.append("Skipped \(Fmt.abbreviate(item.path)): outside the folders Bubble cleans.")
                continue
            }
            if item.isSystem || AppLeftovers.validateLeftover(item.path, roots: roots) == .system {
                pending.append(PendingAdmin(owner: owner, item: RemovalItem(path: item.path, bytes: item.bytes, isApp: item.isApp, isSystem: true)))
                continue
            }
            if isUserLaunchAgent(item.path), let label = Self.launchLabel(item.path) {
                _ = await tool("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], [:])
            }
            do {
                try trash(item.path)
                result.freed += item.bytes
            } catch {
                switch Self.blockedKind(error) {
                case .privacy? where !item.isApp:
                    // macOS privacy protection (TCC): admin rights don't get past it either,
                    // so don't ask for them. Report it and keep going with the rest.
                    result.blockedByPrivacy.append(item.path)
                case .privacy?, .ownership?:
                    pending.append(PendingAdmin(owner: owner, item: item))
                case nil:
                    result.problems.append("Couldn't move \(Fmt.abbreviate(item.path)) to the Trash: \(error.localizedDescription)")
                }
            }
        }
        result.removed = !AppLeftovers.exists(app.path)
        return (result, pending)
    }

    private func isUserLaunchAgent(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent == roots.library + "/LaunchAgents" && path.hasSuffix(".plist")
    }

    private func isSafeCaskToken(_ token: String) -> Bool {
        Safety.isSafeCommandArgument(token)
            && token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.@+").contains($0) }
    }

    // MARK: Admin batch

    struct AdminOutcome: Sendable {
        var removed: Set<String> = []
        var cancelled = false
        var error: String?
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
        let script = adminScript(items)
        do {
            _ = try await admin(script, prompt)
        } catch Admin.Failure.cancelled {
            out.cancelled = true
        } catch Admin.Failure.failed(let msg) {
            out.error = msg
        } catch {
            out.error = error.localizedDescription
        }
        out.removed = Set(items.map(\.path).filter { !AppLeftovers.exists($0) })
        return out
    }

    /// The root script: stop launchd jobs, then `mv` each item into ~/.Trash (with a
    /// Finder-style " 2" on name clashes) and give it back to the user.
    func adminScript(_ items: [RemovalItem]) -> String {
        let q = Admin.quote
        var lines = [
            "T=\(q(roots.trash))",
            "U=\(uid):\(gid)",
            "fail=0",
            "[ -d \"$T\" ] || { mkdir -p \"$T\" && chown \"$U\" \"$T\" && chmod 700 \"$T\"; }",
            "mvtrash() {",
            "  dest=\"$T/$2$3\"; n=2",
            "  while [ -e \"$dest\" ] || [ -L \"$dest\" ]; do dest=\"$T/$2 $n$3\"; n=$((n+1)); done",
            "  if /bin/mv -n -- \"$1\" \"$dest\"; then /usr/sbin/chown -hR \"$U\" \"$dest\"; else fail=1; fi",
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
        for item in items {
            let (stem, ext) = Self.trashName(item.path)
            lines.append("mvtrash \(q(item.path)) \(q(stem)) \(q(ext))")
        }
        lines.append("exit $fail")
        return lines.joined(separator: "\n")
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

    /// Homebrew output that means it needed sudo (no terminal here to ask for a password)
    /// or hit root-owned files.
    static func needsAdmin(_ output: String) -> Bool {
        let o = output.lowercased()
        if o.contains("sudo") && (o.contains("password") || o.contains("terminal") || o.contains("tty")) { return true }
        return o.contains("permission denied") || o.contains("operation not permitted")
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
                do { try p.run() } catch {
                    cont.resume(returning: ToolResult(status: -1, output: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ToolResult(status: p.terminationStatus, output: Shell.clean(String(decoding: data, as: UTF8.self))))
            }
        }
    }

    /// Asks every running copy of the app at `path` to quit, and waits up to ~6 seconds.
    /// Never force-quits.
    @MainActor static func quitApp(path: String) async -> QuitOutcome {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target
        }
        guard !running.isEmpty else { return .notRunning }
        for app in running { app.terminate() }
        for _ in 0..<30 {
            if running.allSatisfy(\.isTerminated) { return .quit }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return running.allSatisfy(\.isTerminated) ? .quit : .stillRunning
    }
}
