import Foundation

/// Runs the `mo` CLI (and a few other tools) as child processes.
/// Bubble never deletes anything itself except via Move to Trash; every
/// cleanup goes through Mole so its safety rules and whitelist apply.
///
/// Security notes:
/// - Child processes get `childPath`, which puts the system folders first, so a
///   `sudo` (or `rm`, `osascript`, …) planted in a user-writable folder such as
///   ~/.local/bin or /opt/homebrew/bin can never shadow the system one. Mole calls
///   plain `sudo`, and Bubble types the admin password into it.
/// - `mo` and `brew` are only looked up in fixed locations and run by absolute path.
/// - Every executable is checked with `Shell.trustProblem` before it runs (and Mole's
///   library folder too), so a file someone else could have swapped is refused.
/// - Inherited variables that make bash run code or redefine commands (BASH_ENV,
///   exported `BASH_FUNC_sudo%%` functions, …) are removed from the child environment.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// PATH for every child process: the system folders first (so `sudo` is always
    /// /usr/bin/sudo), then Homebrew's two prefixes, then ~/.local/bin, where Mole's
    /// own install script puts `mo` when it runs without admin rights (see Onboarding).
    static let childPath = makeChildPath(home: home)

    static func makeChildPath(home: String) -> String {
        "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
    }

    /// Where `which` looks for optional developer tools (npm, pip3, uv, …). Homebrew comes
    /// first so its python3/pip3 win over Apple's /usr/bin stubs (which offer to install
    /// the Command Line Tools). Lookups return absolute paths; this is never used as PATH.
    static let toolSearchPath = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The only places Bubble runs `mo` and `brew` from.
    static let moleCandidates = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", "\(home)/.local/bin/mo"]
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Looked up on every use, so Mole installed while Bubble is running is picked up
    /// without a relaunch. A lookup is a few `stat` calls.
    static var mo: String? {
        #if BUBBLE_DEV
        if DetectionOverrides.hideMole { return nil }
        #endif
        return moleCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var brew: String? {
        #if BUBBLE_DEV
        if DetectionOverrides.hideBrew { return nil }
        #endif
        return brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Finds an optional tool by name; returns an absolute path.
    static func which(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in toolSearchPath {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// The environment for a child process: Bubble's own, minus variables that make a
    /// shell run code or redefine commands, with PATH set to `childPath`.
    static func childEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        sanitizedEnvironment(ProcessInfo.processInfo.environment, extra: extra)
    }

    static let strippedVariables: Set<String> = [
        "BASH_ENV", "ENV", "CDPATH", "GLOBIGNORE", "SHELLOPTS", "BASHOPTS", "PS4", "IFS", "PROMPT_COMMAND",
        "SUDO_ASKPASS", "SUDO_PROMPT", "SUDO_EDITOR", "PERL5OPT", "PYTHONSTARTUP", "RUBYOPT", "NODE_OPTIONS",
    ]

    static func sanitizedEnvironment(_ base: [String: String], extra: [String: String] = [:]) -> [String: String] {
        var env = base.filter { key, _ in
            !strippedVariables.contains(key) && !key.hasPrefix("BASH_FUNC_") && !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_")
        }
        env["PATH"] = childPath
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (k, v) in extra { env[k] = v }
        return env
    }

    // MARK: Executable trust check

    /// Nil when `executable` (following every symlink) and each folder above it can only
    /// be changed by you, root, or an administrator; otherwise a user-facing reason.
    /// For `mo`, Mole's library folder (the bash it sources) is checked too.
    ///
    /// The rule, per file and folder:
    /// - Owner is root, you, or a member of the admin group.
    /// - Not writable by "other", except a sticky folder such as /tmp (where only an
    ///   entry's owner can replace it, and that entry is checked on its own).
    /// - Writable by its group only when the group is admin (80) or wheel (0). Homebrew
    ///   makes /opt/homebrew/bin admin-writable; admins can already become root with
    ///   sudo, so that gives them nothing new. "staff" (every user) is not accepted.
    ///
    /// ~/.local/bin/mo (Mole's script install) passes: it's yours and not group- or
    /// world-writable. That is a deliberate trade-off: anything already running as you
    /// can change it, just as it can change a Homebrew install you own. The check stops
    /// other users and misconfigured permissions; the system-first PATH is what keeps a
    /// planted `sudo` from ever being run.
    static func trustProblem(executable: String) -> String? {
        var checker = TrustChecker()
        if let problem = checker.check(executable: executable) { return problem }
        if executable.hasSuffix("/mo") || executable.hasSuffix("/mole"), let libexec = moleLibexec(for: executable) {
            return checker.checkTree(libexec.path, limit: 2000)
        }
        return nil
    }

    /// One file's or folder's owner, group and mode, as `stat` reports them.
    struct FileInfo: Equatable {
        var owner: uid_t
        var group: gid_t
        var mode: mode_t
        var isDirectory: Bool
    }

    /// The ownership rule for one file or folder. `isAdmin` says whether a uid is in the admin group.
    static func ownershipProblem(_ info: FileInfo, path: String, me: uid_t = getuid(), isAdmin: (uid_t) -> Bool = Shell.isAdminUser) -> String? {
        let what = info.isDirectory ? "folder" : "file"
        if info.owner != 0 && info.owner != me && !isAdmin(info.owner) {
            return "\(path) is owned by another user (uid \(info.owner)), so Bubble won't run it. Reinstall Mole, or fix the \(what)'s owner in Terminal."
        }
        let sticky = info.mode & S_ISVTX != 0
        if info.mode & S_IWOTH != 0 && !(info.isDirectory && sticky) {
            return "\(path) can be changed by any user on this Mac, so Bubble won't run it. Fix it in Terminal with: chmod o-w \"\(path)\""
        }
        if info.mode & S_IWGRP != 0 && info.group != 80 && info.group != 0 {
            return "\(path) can be changed by members of group \(info.group), so Bubble won't run it. Fix it in Terminal with: chmod g-w \"\(path)\""
        }
        return nil
    }

    static func isAdminUser(_ uid: uid_t) -> Bool {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return false }
        var groups = [Int32](repeating: 0, count: 64)
        var count = Int32(groups.count)
        guard getgrouplist(name, Int32(pw.pointee.pw_gid), &groups, &count) != -1 || count > 0 else { return false }
        return groups.prefix(Int(count)).contains(80)
    }

    static func fileInfo(_ path: String, followLinks: Bool) -> FileInfo? {
        var st = stat()
        let rc = followLinks ? stat(path, &st) : lstat(path, &st)
        guard rc == 0 else { return nil }
        return FileInfo(owner: st.st_uid, group: st.st_gid, mode: st.st_mode, isDirectory: st.st_mode & S_IFMT == S_IFDIR)
    }

    /// Walks a path the way the kernel does: each folder above it, then each symlink
    /// in the chain, then the file it finally names.
    struct TrustChecker {
        var me: uid_t = getuid()
        var isAdmin: (uid_t) -> Bool = Shell.isAdminUser
        var info: (String, Bool) -> FileInfo? = Shell.fileInfo
        private var checked: Set<String> = []

        init() {}
        init(me: uid_t, isAdmin: @escaping (uid_t) -> Bool, info: @escaping (String, Bool) -> FileInfo?) {
            self.me = me; self.isAdmin = isAdmin; self.info = info
        }

        mutating func check(executable: String) -> String? {
            var path = Safety.normalize(executable)
            guard executable.hasPrefix("/") else { return "\(executable) isn't an absolute path." }
            for _ in 0..<32 {
                if let p = checkAncestors(of: path) { return p }
                guard let lst = info(path, false) else { return "\(path) doesn't exist." }
                if let p = Shell.ownershipProblem(lst, path: path, me: me, isAdmin: isAdmin), lst.mode & S_IFMT != S_IFLNK { return p }
                guard lst.mode & S_IFMT == S_IFLNK else { return nil }
                // A symlink: its own mode means nothing, but its owner and folder do.
                if lst.owner != 0 && lst.owner != me && !isAdmin(lst.owner) {
                    return "\(path) is a link owned by another user (uid \(lst.owner)), so Bubble won't run it."
                }
                guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return "Couldn't read the link \(path)." }
                path = dest.hasPrefix("/") ? Safety.normalize(dest) : Safety.normalize((path as NSString).deletingLastPathComponent + "/" + dest)
            }
            return "\(executable) has too many links."
        }

        /// Checks `root` and everything under it (Mole's bash library), up to `limit` entries.
        mutating func checkTree(_ root: String, limit: Int) -> String? {
            let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            if let p = checkAncestors(of: real) { return p }
            if let i = info(real, true), let p = Shell.ownershipProblem(i, path: real, me: me, isAdmin: isAdmin) { return p }
            guard let e = FileManager.default.enumerator(atPath: real) else { return nil }
            var n = 0
            while let rel = e.nextObject() as? String, n < limit {
                n += 1
                let path = real + "/" + rel
                guard let i = info(path, false), i.mode & S_IFMT != S_IFLNK else { continue }
                if let p = Shell.ownershipProblem(i, path: path, me: me, isAdmin: isAdmin) { return p }
            }
            return nil
        }

        private mutating func checkAncestors(of path: String) -> String? {
            var dir = (path as NSString).deletingLastPathComponent
            var chain: [String] = []
            while !dir.isEmpty {
                chain.append(dir)
                if dir == "/" { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            for d in chain.reversed() where !checked.contains(d) {
                guard let i = info(d, true) else { return "\(d) doesn't exist." }
                if let p = Shell.ownershipProblem(i, path: d, me: me, isAdmin: isAdmin) { return p }
                // A folder that is itself a link (/tmp, /var) is checked where it points.
                let real = URL(fileURLWithPath: d).resolvingSymlinksInPath().path
                if real != d, let p = checkAncestors(of: real + "/x") { return p }
                checked.insert(d)
            }
            return nil
        }
    }

    /// The message shown instead of running `exe` when it fails `trustProblem`; nil when it passes.
    static func refusal(_ exe: String) -> String? {
        trustProblem(executable: exe).map { "Bubble didn't run \((exe as NSString).lastPathComponent): \($0)" }
    }

    /// Mole's libexec directory (where its bash sources live), resolved through the Homebrew symlink.
    /// A script install (no Homebrew) keeps them in ~/.config/mole instead.
    static var moleLibexec: URL? {
        guard let mo else { return nil }
        return moleLibexec(for: mo)
    }

    static func moleLibexec(for mo: String) -> URL? {
        let real = URL(fileURLWithPath: mo).resolvingSymlinksInPath()
        let prefix = real.deletingLastPathComponent().deletingLastPathComponent()
        let libexec = prefix.appendingPathComponent("libexec")
        if FileManager.default.fileExists(atPath: libexec.path) { return libexec }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole")
        return FileManager.default.fileExists(atPath: config.appendingPathComponent("lib/core/base.sh").path) ? config : nil
    }

    /// Every child process Bubble starts is built here: the scrubbed `childEnvironment`
    /// (or one derived from it) and the home folder as its working directory. Callers
    /// check `refusal(_:)` first.
    static func makeProcess(_ exe: String, _ args: [String], environment: [String: String] = childEnvironment()) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        return p
    }

    /// Reads `pipe` until end of file through `buffer`, handing complete lines to `onLines`
    /// as they arrive and whatever is left to `onEnd`. With `lock`, both callbacks run while
    /// holding it, together with the read that produced their lines.
    static func readLines(from pipe: Pipe, into buffer: LineBuffer = LineBuffer(), lock: NSLock? = nil,
                          onLines: @escaping @Sendable ([String]) -> Void, onEnd: @escaping @Sendable ([String]) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            lock?.lock()
            defer { lock?.unlock() }
            if data.isEmpty {
                h.readabilityHandler = nil
                onEnd(buffer.flush())
            } else {
                onLines(buffer.append(data))
            }
        }
    }

    /// Runs a command to completion and returns stdout (stderr discarded).
    /// `timeout` (seconds) terminates a command that runs too long; its output so far is returned.
    /// `sandbox`: a `PrivacyGuard` profile to run it under (see Core/Privacy.swift).
    static func output(_ exe: String, _ args: [String], input: String? = nil, timeout: TimeInterval? = nil, sandbox: String? = nil) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                if let why = refusal(exe) {
                    NSLog("%@", why)
                    cont.resume(returning: Data())
                    return
                }
                let run = PrivacyGuard.command(exe, args, profile: sandbox)
                let p = makeProcess(run.exe, run.args)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = inputHandle(input)
                do { try p.run() } catch {
                    cont.resume(returning: Data())
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if p.isRunning { p.terminate() }
                    }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: data)
            }
        }
    }

    static func moJSON(_ args: [String], sandbox: String? = nil) async -> Data {
        guard let mo else { return Data() }
        return await output(mo, args, sandbox: sandbox)
    }

    static func moText(_ args: [String], input: String? = nil) async -> String {
        guard let mo else { return "" }
        let data = await output(mo, args, input: input)
        return clean(String(decoding: data, as: UTF8.self))
    }

    /// Streams stdout+stderr line by line, with ANSI codes removed.
    /// Cancelling the consuming task terminates the process.
    static func lines(_ exe: String, _ args: [String], input: String? = nil, sandbox: String? = nil) -> AsyncStream<String> {
        AsyncStream { cont in
            if let why = refusal(exe) {
                cont.yield(why)
                cont.finish()
                return
            }
            let run = PrivacyGuard.command(exe, args, profile: sandbox)
            let p = makeProcess(run.exe, run.args)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = inputHandle(input)
            readLines(from: pipe, onLines: { lines in
                for line in lines { cont.yield(line) }
            }, onEnd: { rest in
                for line in rest { cont.yield(line) }
                cont.finish()
            })
            cont.onTermination = { _ in
                if p.isRunning { p.terminate() }
            }
            do { try p.run() } catch {
                cont.yield("Failed to launch \(exe): \(error.localizedDescription)")
                cont.finish()
            }
        }
    }

    static func moLines(_ args: [String], input: String? = nil, sandbox: String? = nil) -> AsyncStream<String> {
        guard let mo else {
            return AsyncStream { $0.yield("Mole isn't installed. Open Bubble to set it up."); $0.finish() }
        }
        return lines(mo, args, input: input, sandbox: sandbox)
    }

    private static func inputHandle(_ input: String?) -> Any {
        guard let input else { return FileHandle.nullDevice }
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try? pipe.fileHandleForWriting.close()
        return pipe
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[()][A-Z0-9]")

    static func clean(_ s: String) -> String {
        ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()

        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            var out: [String] = []
            while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let chunk = pending[pending.startIndex..<idx]
                pending.removeSubrange(pending.startIndex...idx)
                if let line = Self.tidy(chunk) { out.append(line) }
            }
            return out
        }

        /// Interactive prompts ("Password:", "[y/N] ") arrive without a newline.
        func pendingPrompt() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let text = Self.tidy(pending[...]) else { return nil }
            let promptLike = text.hasSuffix(":") || text.hasSuffix("]") || text.hasSuffix("?") || text.lowercased().hasSuffix("cancel:")
            guard promptLike else { return nil }
            pending.removeAll()
            return text
        }

        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let rest = Self.tidy(pending[...])
            pending.removeAll()
            return rest.map { [$0] } ?? []
        }

        private static func tidy(_ chunk: Data.SubSequence) -> String? {
            let s = Shell.clean(String(decoding: chunk, as: UTF8.self))
                .trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }
}

#if BUBBLE_DEV
/// Debug-only switches for testing first-run setup on a Mac that already has Mole.
/// Set with launch arguments, e.g. `open build/Bubble.app --args -simulateNoMole YES`.
/// While any of them is on, every install or update is a dry run (see MoleInstall).
/// Compiled only with `BUBBLE_DEV=1 scripts/bundle.sh` (-DBUBBLE_DEV), never in releases.
enum DetectionOverrides {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var moleRevealed = false

    /// `-simulateNoMole YES`: report Mole as missing until a simulated install finishes.
    static var hideMole: Bool {
        lock.lock(); defer { lock.unlock() }
        return !moleRevealed && UserDefaults.standard.bool(forKey: "simulateNoMole")
    }

    /// `-simulateNoBrew YES`: report Homebrew as missing (tests the install-script route).
    static var hideBrew: Bool { UserDefaults.standard.bool(forKey: "simulateNoBrew") }

    /// Called when a simulated install "finishes", so detection finds the real `mo`.
    static func revealMole() {
        lock.lock(); defer { lock.unlock() }
        moleRevealed = true
    }
}
#endif
