import Foundation
import Security

/// Identifies the prompt a reply is meant for: how many output chunks the process had
/// written when the prompt was detected. If anything arrives after that, the prompt is
/// no longer the thing waiting for input.
struct PromptTicket: Equatable {
    let chunks: Int
}

/// Runs a command inside a pseudo-terminal (via /usr/bin/script) so that it behaves
/// exactly as in Terminal: Mole's own confirmations work, and a `sudo` prompt shows up
/// as a prompt the caller can recognize and decline. The caller replies with `send`;
/// Bubble never types a password.
///
/// Output is split at "\n" and "\r" into trimmed, non-blank lines. Text that ends
/// without a newline and then sits idle for `promptIdle` seconds is yielded as a
/// *pending prompt*. `isPendingPrompt(_:)` tells whether the line the consumer just
/// received arrived that way, so a complete output line that merely ends in
/// "password:" is never mistaken for sudo asking.
///
/// sudo's prompt is a per-session random string (`SUDO_PROMPT`, which sudo uses
/// unless it's called with `-p`), so a look-alike prompt can't pass for sudo's.
final class PTYSession: @unchecked Sendable {
    let lines: AsyncStream<String>
    /// The exact prompt sudo prints in this session.
    let sudoPrompt: String
    private let process: Process
    private let input = Pipe()
    private let state = State()
    private let exit = Exit()
    static let promptIdle: TimeInterval = 0.15
    /// Ctrl-D. Typed at sudo's password prompt it ends input, so sudo gives up at once
    /// ("no password was provided") instead of counting an empty password as a failed
    /// attempt and asking twice more.
    static let endOfInput = "\u{4}"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var chunks = 0
        var finished = false
        var launched = false
        var lastDelivered: (line: String, prompt: Bool, chunks: Int)?

        func isLaunched() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return launched
        }

        func deliver(_ line: String, prompt: Bool, chunks: Int) {
            lock.lock(); defer { lock.unlock() }
            lastDelivered = (line, prompt, chunks)
        }
    }

    /// The exit status, filled in by the process's termination handler. `waitUntilExit` on
    /// a worker thread can miss the exit and wait forever, so waiters park here instead.
    private final class Exit: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []

        func finish(_ s: Int32) {
            lock.lock()
            status = s
            let ready = waiters
            waiters = []
            lock.unlock()
            ready.forEach { $0.resume(returning: s) }
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { cont in
                lock.lock()
                if let status {
                    lock.unlock()
                    cont.resume(returning: status)
                } else {
                    waiters.append(cont)
                    lock.unlock()
                }
            }
        }
    }

    /// Lets the unfolding stream below share one iterator.
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<(String, Bool, Int)>.Iterator
        init(_ it: AsyncStream<(String, Bool, Int)>.Iterator) { iterator = it }
    }

    static func makeSudoPrompt() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "Bubble sudo password " + bytes.map { String(format: "%02x", $0) }.joined() + ":"
    }

    /// - Parameters:
    ///   - environment: extra variables for the child, on top of `Shell.childEnvironment`.
    ///   - filterSpinners: drop lines that start with a spinner frame (a braille dot
    ///     pattern, "|", "/" or "\"), as Mole redraws them constantly. Pass false for
    ///     output that isn't Mole's, where such lines are real (e.g. "/bin/sh: …").
    init(_ exe: String, _ args: [String], environment: [String: String] = [:], filterSpinners: Bool = true) {
        let sudoPrompt = Self.makeSudoPrompt()
        self.sudoPrompt = sudoPrompt
        let input = self.input
        let state = self.state
        let refusal = Shell.refusal(exe)
        let process = Shell.makeProcess("/usr/bin/script", ["-q", "/dev/null", exe] + args,
                                        environment: Shell.childEnvironment(environment.merging(["COLUMNS": "160", "SUDO_PROMPT": sudoPrompt]) { _, own in own }))
        self.process = process
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = input
        let exit = self.exit
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        let tagged = AsyncStream<(String, Bool, Int)> { cont in
            if let refusal {
                cont.yield((refusal, false, 0))
                cont.finish()
                return
            }
            // Every read, its lines and the counters move together under the state lock,
            // so the idle check below never sees a half-processed chunk.
            let buffer = Shell.LineBuffer()
            Shell.readLines(from: out, into: buffer, lock: state.lock, onLines: { lines in
                state.generation += 1
                state.chunks += 1
                for line in lines where !(filterSpinners && Self.isSpinner(line)) { cont.yield((line, false, state.chunks)) }
                // Only treat unterminated text as a prompt once output has gone quiet,
                // so a line split across two reads isn't mistaken for one.
                let gen = state.generation
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.promptIdle) {
                    state.lock.lock()
                    defer { state.lock.unlock() }
                    guard state.generation == gen, let prompt = buffer.pendingPrompt() else { return }
                    cont.yield((prompt, true, state.chunks))
                }
            }, onEnd: { rest in
                state.generation += 1
                state.chunks += 1
                state.finished = true
                for line in rest { cont.yield((line, false, state.chunks)) }
                try? input.fileHandleForWriting.close()
                cont.finish()
            })
            cont.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
                state.lock.lock(); state.launched = true; state.lock.unlock()
            } catch {
                cont.yield(("Failed to launch: \(error.localizedDescription)", false, 0))
                cont.finish()
            }
        }
        let box = IteratorBox(tagged.makeAsyncIterator())
        lines = AsyncStream(unfolding: {
            guard let (line, prompt, chunks) = await box.iterator.next() else { return nil }
            state.deliver(line, prompt: prompt, chunks: chunks)
            return line
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })
    }

    /// True when `line` is the line most recently delivered by `lines` and it
    /// arrived as an unterminated prompt (no newline, then output went idle).
    func isPendingPrompt(_ line: String) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard let last = state.lastDelivered else { return false }
        return last.prompt && last.line == line
    }

    /// A ticket for `line` when it's the pending prompt just delivered.
    func ticket(for line: String) -> PromptTicket? {
        state.lock.lock(); defer { state.lock.unlock() }
        guard let last = state.lastDelivered, last.prompt, last.line == line else { return nil }
        return PromptTicket(chunks: last.chunks)
    }

    /// Increases whenever the process writes anything.
    var outputCounter: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.chunks
    }

    /// A reply may be typed only while the process is running and has written nothing
    /// since the prompt was detected.
    static func isPromptCurrent(_ ticket: PromptTicket, currentChunks: Int, finished: Bool) -> Bool {
        !finished && currentChunks == ticket.chunks
    }

    func send(_ text: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    /// Types `text` only if the prompt `ticket` names is still the one waiting.
    /// Returns false (and types nothing) when any output arrived since, or the process ended.
    @discardableResult
    func send(_ text: String, ifCurrent ticket: PromptTicket) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard Self.isPromptCurrent(ticket, currentChunks: state.chunks, finished: state.finished), process.isRunning else { return false }
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        return true
    }

    /// Waits for the command to exit and returns its exit status (`script` passes the
    /// command's own status through); nil when it never started.
    func exitStatus() async -> Int32? {
        guard state.isLaunched() else { return nil }
        return await exit.wait()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Drops spinner frames ("⠋ Scanning…", "| Working") that a TTY run redraws constantly.
    private static func isSpinner(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first else { return true }
        return (0x2800...0x28FF).contains(first.value) || "|/\\".unicodeScalars.contains(first)
    }
}

/// What a pending prompt is asking for.
enum PromptKind: Equatable {
    /// sudo's own password prompt ("Password:" or "[sudo] password for nitin:").
    case sudoPassword
    /// Looks like a password prompt but isn't this session's sudo prompt (another
    /// program, or a fake). Only ever gets an empty line.
    case otherPassword
    /// Any other yes/no question; answered "n".
    case yesNo
    /// A single-key `read_key`/`read -n1` choice; answered with the cancel key.
    case keyChoice(cancel: String)
    /// Anything else.
    case unknown
}

/// What to type in response to a prompt.
enum PromptReply: Equatable {
    /// Decline sudo's prompt without asking anyone: type Ctrl-D so sudo gives up after one
    /// prompt. Expected, so it isn't listed in `skippedPrompts`.
    case skipAdmin
    /// A declined prompt: type this safe default.
    case decline(String)
    /// An unrecognised prompt: type "n", then Return only if Mole is still waiting
    /// (so a single-key read doesn't get a stray Return that confirms the next prompt).
    case declineUnknown
}

/// Declines Mole's interactive prompts during a PTY run (`mo optimize`), which runs without
/// admin rights. Bubble never types a password: sudo's own prompt is ended with Ctrl-D
/// straight away (no dialog), so Mole skips its admin tasks and Bubble runs its own versions
/// afterwards through `Admin.run`. Every other prompt gets a safe default and is recorded
/// in `skippedPrompts` so the UI can show "Skipped: <prompt>".
@MainActor
final class PromptResponder {
    /// Prompts that were declined with a safe default, in order.
    private(set) var skippedPrompts: [String] = []
    /// True once sudo's prompt was declined because this run doesn't use admin rights.
    private(set) var adminSkipped = false

    /// Returns true when `line` was a prompt and has been declined.
    ///
    /// Every reply is typed only if nothing was written since the prompt appeared
    /// (`PTYSession.send(_:ifCurrent:)`), so an answer meant for one prompt can never
    /// land in the next one.
    func handle(_ line: String, _ session: PTYSession) -> Bool {
        guard session.isPendingPrompt(line), let ticket = session.ticket(for: line) else { return false }
        let kind = Self.classify(line, sudoPrompt: session.sudoPrompt)
        switch Self.decide(kind: kind) {
        case .skipAdmin:
            adminSkipped = true
            session.send(PTYSession.endOfInput, ifCurrent: ticket)
        case .decline(let text):
            skippedPrompts.append(line)
            session.send(text, ifCurrent: ticket)
        case .declineUnknown:
            skippedPrompts.append(line)
            guard session.send("n", ifCurrent: ticket) else { return true }
            let next = PromptTicket(chunks: session.outputCounter)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                session.send("\n", ifCurrent: next)
            }
        }
        return true
    }

    // MARK: Policy

    nonisolated static func decide(kind: PromptKind) -> PromptReply {
        switch kind {
        case .sudoPassword: .skipAdmin
        case .otherPassword: .decline("\n")
        case .yesNo: .decline("n\n")
        case .keyChoice(let cancel): .decline(cancel)
        case .unknown: .declineUnknown
        }
    }

    nonisolated private static let sudoPatterns = [
        try! NSRegularExpression(pattern: #"^Password:$"#),
        try! NSRegularExpression(pattern: #"^\[sudo\] password for [^\s:]+:$"#),
    ]

    /// - Parameter sudoPrompt: the session's own `SUDO_PROMPT`. When given, only that
    ///   exact text counts as sudo asking; a look-alike "Password:" is `.otherPassword`.
    nonisolated static func classify(_ prompt: String, sudoPrompt: String? = nil) -> PromptKind {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        let range = NSRange(p.startIndex..., in: p)
        if let sudoPrompt {
            if p == sudoPrompt.trimmingCharacters(in: .whitespaces) { return .sudoPassword }
            if sudoPatterns.contains(where: { $0.firstMatch(in: p, range: range) != nil }) { return .otherPassword }
        } else if sudoPatterns.contains(where: { $0.firstMatch(in: p, range: range) != nil }) {
            return .sudoPassword
        }
        let lower = p.lowercased()
        // Mole's read_key prompts: Space cancels, Return confirms. Never send Return.
        if lower.contains("space cancel") { return .keyChoice(cancel: " ") }
        if lower.contains("esc cancel") || lower.contains("enter confirm") || lower.contains("press enter")
            || lower.contains("any key") {
            return .keyChoice(cancel: "q")
        }
        if lower.contains("[y/n]") || lower.contains("(y/n)") || lower.contains("y/n") { return .yesNo }
        return .unknown
    }
}
