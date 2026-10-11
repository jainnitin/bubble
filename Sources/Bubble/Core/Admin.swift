import Foundation

/// Runs a shell script as root behind a system authorization UI, so Bubble never sees or
/// types a password.
///
/// Two routes, tried in order:
///
/// 1. **Touch ID for sudo.** When `/etc/pam.d/sudo_local` (or `/etc/pam.d/sudo`) has an
///    active `auth … pam_tid.so` line, the script runs as `/usr/bin/sudo /bin/sh -c <script>`
///    in a pseudo-terminal and pam_tid shows the system Touch ID sheet. If sudo falls back to
///    its password prompt instead (Touch ID cancelled or unavailable, e.g. the lid is closed),
///    Bubble stops sudo without typing anything and moves on to route 2. A recent sudo
///    timestamp for the terminal may let it through with no sheet at all.
/// 2. **The macOS authorization dialog.** AppleScript's `do shell script … with administrator
///    privileges` via `osascript`, with the script passed through argv so it is never spliced
///    into AppleScript source. On the machines we checked this dialog offers only a password,
///    not Touch ID.
///
/// Stopping a run (cancelling the calling task, or the timeout) terminates sudo or osascript;
/// for osascript, authd then dismisses the dialog. A script already running as root may not
/// stop with it, so keep scripts short.
enum Admin {
    enum Failure: Error, Equatable {
        /// Nothing was authorized: the user cancelled, the calling task was cancelled, or
        /// nobody answered before the timeout.
        case cancelled
        /// The script ran but exited non-zero, or sudo/osascript failed or was killed;
        /// carries a readable reason (never empty).
        case failed(String)
    }

    /// - Parameters:
    ///   - script: a `/bin/sh` script, run as root. Quote every path with `Admin.quote`.
    ///   - prompt: the reason shown in the macOS dialog, e.g. "Bubble needs to flush the DNS
    ///     cache." The Touch ID sheet shows its own text.
    /// - Returns: the script's output. Through osascript that's stdout with line endings
    ///   unchanged; through sudo it's stdout and stderr together, one trimmed line per
    ///   non-blank line, each ending in "\n".
    static func run(_ script: String, prompt: String) async throws -> String {
        try await run(script, prompt: prompt, timeout: nil)
    }

    /// Like `run(_:prompt:)`, but gives up with `.cancelled` after `timeout` seconds,
    /// which in practice is an authorization nobody answered.
    static func run(_ script: String, prompt: String, timeout: TimeInterval?) async throws -> String {
        if touchIDForSudo() {
            if let out = try await runWithSudo(script, timeout: timeout) { return out }
            // sudo wanted a password: use the system dialog instead.
        }
        try Task.checkCancellation()
        return try await runWithDialog(script, prompt: prompt, timeout: timeout)
    }

    // MARK: Touch ID for sudo

    static let pamFiles = ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"]

    /// Whether sudo will offer Touch ID on this Mac.
    static func touchIDForSudo(files: [String] = pamFiles) -> Bool {
        files.contains { (try? String(contentsOfFile: $0, encoding: .utf8)).map(pamEnablesTouchID) ?? false }
    }

    /// True when a PAM config has an uncommented `auth` line using pam_tid.so.
    static func pamEnablesTouchID(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.first == "auth" else { return false }
            return fields.dropFirst().contains { ($0 as NSString).lastPathComponent.hasPrefix("pam_tid.so") }
        }
    }

    /// Runs the script through sudo in a pseudo-terminal. Nil means sudo asked for a password,
    /// so the caller should use the dialog instead.
    /// - Parameter sudo: the sudo to run; replaceable in tests.
    static func runWithSudo(_ script: String, timeout: TimeInterval?, sudo: String = "/usr/bin/sudo") async throws -> String? {
        // PTYSession sets SUDO_PROMPT to a per-session random marker, so sudo's password
        // prompt is recognizable and nothing else can fake it.
        let session = PTYSession(sudo, ["--", "/bin/sh", "-c", script])
        let flags = Flags()
        let timer = timeout.map { t in
            Task {
                try? await Task.sleep(for: .seconds(t))
                guard !Task.isCancelled else { return }
                flags.set(\.timedOut)
                session.terminate()
            }
        }
        defer { timer?.cancel() }
        var lines: [String] = []
        await withTaskCancellationHandler {
            for await line in session.lines {
                if session.isPendingPrompt(line) {
                    switch PromptResponder.classify(line, sudoPrompt: session.sudoPrompt) {
                    case .sudoPassword, .otherPassword:
                        flags.set(\.wantsPassword)
                        session.terminate()
                        return
                    default:
                        // Root scripts aren't interactive; end their input.
                        session.send(PTYSession.endOfInput)
                    }
                }
                lines.append(line)
            }
        } onCancel: {
            session.terminate()
        }
        let status = await session.exitStatus()
        if Task.isCancelled || flags.get(\.timedOut) { throw Failure.cancelled }
        if flags.get(\.wantsPassword) { return nil }
        return try sudoOutcome(status: status, lines: lines)
    }

    static func sudoOutcome(status: Int32?, lines: [String]) throws -> String {
        guard let status else { throw Failure.failed(lines.last ?? "Couldn't start sudo.") }
        if status == 0 { return lines.map { $0 + "\n" }.joined() }
        let message = lines.last { $0.hasPrefix("sudo:") } ?? lines.last
        throw Failure.failed(message ?? "sudo exited with status \(status) and no message.")
    }

    // MARK: The macOS authorization dialog

    static func runWithDialog(_ script: String, prompt: String, timeout: TimeInterval?) async throws -> String {
        let job = Job()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result { try job.run(arguments(script: script, prompt: prompt), timeout: timeout) })
                }
            }
        } onCancel: {
            job.stop()
        }
    }

    /// osascript's arguments: a fixed AppleScript, then the script and prompt as data.
    static func arguments(script: String, prompt: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
            "-e", "end run",
            "--", script, prompt,
        ]
    }

    /// Maps how osascript ended to a result. `stopped` means Bubble terminated it
    /// (cancellation or timeout); `signaled` that it died from a signal.
    static func outcome(status: Int32, signaled: Bool, stopped: Bool, stdout: String, stderr: String) throws -> String {
        if status == 0 && !signaled { return stdout }
        if stopped { throw Failure.cancelled }
        // AppleScript error -128 is "User canceled."
        if stderr.contains("(-128)") { throw Failure.cancelled }
        if signaled {
            throw Failure.failed("The authorization helper (osascript) was stopped before it finished.")
        }
        throw Failure.failed(readableError(stderr) ?? "osascript exited with status \(status) and no message.")
    }

    /// "0:118: execution error: mdutil: … (1)" → "mdutil: …". Nil when there's nothing to say.
    static func readableError(_ stderr: String) -> String? {
        var s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "execution error: ") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: #"\s*\(-?\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Single-quotes `s` for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Thread-safe booleans for the sudo run.
    private final class Flags: @unchecked Sendable {
        struct Values { var timedOut = false; var wantsPassword = false }
        private let lock = NSLock()
        private var values = Values()
        func set(_ key: WritableKeyPath<Values, Bool>) { lock.lock(); values[keyPath: key] = true; lock.unlock() }
        func get(_ key: KeyPath<Values, Bool>) -> Bool { lock.lock(); defer { lock.unlock() }; return values[keyPath: key] }
    }

    /// One osascript run that can be stopped from another thread.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            if let p = process, p.isRunning { p.terminate() }
        }

        func run(_ args: [String], timeout: TimeInterval?) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = args
            p.environment = Shell.childEnvironment()
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            lock.lock()
            if stopped { lock.unlock(); throw Failure.cancelled }
            do { try p.run() } catch {
                lock.unlock()
                throw Failure.failed("Couldn't start osascript: \(error.localizedDescription)")
            }
            process = p
            lock.unlock()

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop() }
            }
            // Read both pipes at once so a chatty script can't fill one and stall.
            let errBox = DataBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            p.waitUntilExit()

            lock.lock()
            let wasStopped = stopped
            lock.unlock()
            return try Admin.outcome(status: p.terminationStatus,
                                     signaled: p.terminationReason == .uncaughtSignal,
                                     stopped: wasStopped,
                                     stdout: String(decoding: outData, as: UTF8.self),
                                     stderr: String(decoding: errBox.data, as: UTF8.self))
        }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
