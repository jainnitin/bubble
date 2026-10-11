import AppKit
import CryptoKit
import Foundation
import Security

/// Identifies the prompt a reply is meant for: how many output chunks the process had
/// written when the prompt was detected. If anything arrives after that, the prompt is
/// no longer the thing waiting for input.
struct PromptTicket: Equatable {
    let chunks: Int
}

/// Runs a command inside a pseudo-terminal (via /usr/bin/script) so that Mole
/// behaves exactly as in Terminal: `sudo` can prompt for a password and Mole's
/// own confirmations work. The caller answers prompts with `send`.
///
/// Text that ends without a newline and then sits idle for `promptIdle` seconds
/// is yielded as a *pending prompt*. `isPendingPrompt(_:)` tells whether the line
/// the consumer just received arrived that way, so a complete output line that
/// merely ends in "password:" is never mistaken for sudo asking.
///
/// sudo's prompt is a per-session random string (`SUDO_PROMPT`; Mole runs `sudo -v`
/// without `-p`, so sudo uses it), so only sudo itself can ask for the password.
final class PTYSession: @unchecked Sendable {
    let lines: AsyncStream<String>
    /// The command-line arguments passed to the executable (e.g. ["optimize"]).
    let arguments: [String]
    /// The exact prompt sudo prints in this session.
    let sudoPrompt: String
    private let process: Process
    private let input = Pipe()
    private let state = State()
    static let promptIdle: TimeInterval = 0.15
    /// How long typed secrets are scrubbed from output in case the terminal echoes them.
    static let redactFor: TimeInterval = 30

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var chunks = 0
        var finished = false
        var lastDelivered: (line: String, prompt: Bool, chunks: Int)?
        var secrets: [(length: Int, digest: SHA256.Digest, until: Date)] = []

        func deliver(_ line: String, prompt: Bool, chunks: Int) {
            lock.lock(); defer { lock.unlock() }
            lastDelivered = (line, prompt, chunks)
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

    init(_ exe: String, _ args: [String]) {
        arguments = args
        let sudoPrompt = Self.makeSudoPrompt()
        self.sudoPrompt = sudoPrompt
        let input = self.input
        let state = self.state
        let refusal = Shell.refusal(exe)
        let process = Shell.makeProcess("/usr/bin/script", ["-q", "/dev/null", exe] + args,
                                        environment: Shell.childEnvironment(["COLUMNS": "160", "SUDO_PROMPT": sudoPrompt]))
        self.process = process
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = input

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
                for line in lines where !Self.isSpinner(line) { cont.yield((line, false, state.chunks)) }
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
            do { try process.run() } catch {
                cont.yield(("Failed to launch: \(error.localizedDescription)", false, 0))
                cont.finish()
            }
        }
        let box = IteratorBox(tagged.makeAsyncIterator())
        lines = AsyncStream(unfolding: {
            guard let (raw, prompt, chunks) = await box.iterator.next() else { return nil }
            let line = Self.redact(raw, state: state)
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

    /// Types a password (plus Return) into the prompt `ticket` names, if it's still waiting.
    /// For a while afterwards the password is scrubbed from every output line, so a
    /// terminal that echoes it can't put it in Bubble's logs. Bubble keeps only a hash.
    func sendSecret(_ secret: String, ifCurrent ticket: PromptTicket) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard Self.isPromptCurrent(ticket, currentChunks: state.chunks, finished: state.finished), process.isRunning else { return false }
        if !secret.isEmpty {
            state.secrets.append((secret.count, SHA256.hash(data: Data(secret.utf8)), Date().addingTimeInterval(Self.redactFor)))
        }
        try? input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
        return true
    }

    private static func redact(_ line: String, state: State) -> String {
        state.lock.lock()
        let now = Date()
        state.secrets.removeAll { $0.until < now }
        let secrets = state.secrets
        state.lock.unlock()
        var out = line
        for s in secrets { out = redact(out, length: s.length, digest: s.digest) }
        return out
    }

    /// Replaces every run of `length` characters whose SHA-256 is `digest` with "••••".
    static func redact(_ line: String, length: Int, digest: SHA256.Digest) -> String {
        let chars = Array(line)
        guard length > 0, chars.count >= length else { return line }
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            if i + length <= chars.count, SHA256.hash(data: Data(String(chars[i..<i + length]).utf8)) == digest {
                out.append(contentsOf: "••••")
                i += length
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
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

/// What the admin-password dialog says and how long it waits.
struct AdminRequest: Equatable {
    /// e.g. "mo optimize"
    var command: String
    /// What the password is for, from the caller.
    var reason: String
    var retry: Bool

    var title: String {
        retry ? "That password didn't work. Mole (\(command)) still needs your administrator password."
            : "Mole (\(command)) needs your administrator password"
    }

    var message: String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.isEmpty ? "" : r + "\n\n")
            + "Bubble types it into sudo once and doesn't save it. Skip to carry on without the tasks that need it."
    }
}

/// Asks for the admin password with a native secure field. The password is only
/// held long enough to type it into sudo's prompt.
@MainActor
enum AdminPrompt {
    /// The dialog gives up (as Skip) after this long, so a password can't be typed
    /// into a sudo that stopped waiting long ago.
    static let timeout: TimeInterval = 120

    static func ask(_ request: AdminRequest) -> String? {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Skip")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = Dialogs.run(alert)
        timer.invalidate()
        let pw = field.stringValue
        field.stringValue = ""
        guard response == .alertFirstButtonReturn else { return nil }
        return pw
    }
}

/// What a pending prompt is asking for.
enum PromptKind: Equatable {
    /// sudo's own password prompt ("Password:" or "[sudo] password for nitin:").
    case sudoPassword
    /// Looks like a password prompt but isn't this session's sudo prompt (another
    /// program, or a fake). Never gets the password; declined with an empty line.
    case otherPassword
    /// `mo uninstall NAME…`: "Proceed with uninstallation? [y/N]"
    case uninstallProceed
    /// Mole's batch confirm: "➤ Remove 2 apps, 1.2GB  Enter confirm, ESC cancel:"
    case uninstallRemoveConfirm
    /// Any other yes/no question; answered "n".
    case yesNo
    /// A single-key `read_key`/`read -n1` choice; answered with the cancel key.
    case keyChoice(cancel: String)
    /// Anything else.
    case unknown
}

/// Which prompts a run may answer on the user's behalf.
enum PromptPolicy: Equatable {
    /// `mo optimize`: only sudo's password prompt. Everything else is declined.
    case optimize
    /// `mo uninstall`: the "[y/N]" confirmation (only when Mole's matched apps equal
    /// `expectedApps` exactly), then the "Enter confirm" step and sudo's password.
    /// With nil `expectedApps` nothing is ever confirmed.
    case uninstall(expectedApps: [String]?)
    /// Answer nothing; decline everything.
    case strict

    static func detect(arguments: [String]) -> PromptPolicy {
        switch arguments.first {
        case "optimize": return .optimize
        case "uninstall": return .uninstall(expectedApps: nil)
        default: return .strict
        }
    }
}

/// What to type in response to a prompt.
enum PromptReply: Equatable {
    /// Ask the user for their admin password and type it.
    case password
    /// An allowed answer.
    case answer(String)
    /// A declined prompt: type this safe default.
    case decline(String)
    /// An unrecognised prompt: type "n", then Return only if Mole is still waiting
    /// (so a single-key read doesn't get a stray Return that confirms the next prompt).
    case declineUnknown
}

/// Answers Mole's interactive prompts during a PTY run, but only an explicit
/// allow-list per command. Every other prompt gets a safe default and is recorded
/// in `skippedPrompts` so the UI can show "Skipped: <prompt>".
@MainActor
final class PromptResponder {
    private let reason: String
    private let policy: PromptPolicy?
    private var attempts = 0
    private var declined = false
    private var matchBlock: [String]?
    /// True once the "[y/N]" was answered "y" after a successful match check.
    private(set) var proceedConfirmed = false
    /// Prompts that were declined with a safe default, in order.
    private(set) var skippedPrompts: [String] = []
    /// Set when `mo uninstall` matched different apps than expected; the run was declined.
    private(set) var matchError: String?

    /// Times a password was typed in the dialog but thrown away because sudo had
    /// moved on (more output arrived, or the run ended) by the time it was entered.
    private(set) var stalePasswordsDiscarded = 0
    /// Shows the password dialog. Replaceable in tests; defaults to `AdminPrompt.ask`.
    var askPassword: @MainActor (AdminRequest) -> String? = { AdminPrompt.ask($0) }

    /// - Parameter policy: nil picks the policy from the session's command
    ///   (`optimize` → sudo only, `uninstall` → never confirms without expected apps).
    init(reason: String, policy: PromptPolicy? = nil) {
        self.reason = reason
        self.policy = policy
    }

    /// Returns true when `line` was a prompt and has been answered or declined.
    ///
    /// Every reply is typed only if nothing was written since the prompt appeared
    /// (`PTYSession.send(_:ifCurrent:)`), so an answer meant for one prompt can never
    /// land in the next one (a stray Return would confirm Mole's "Enter confirm").
    func handle(_ line: String, _ session: PTYSession) -> Bool {
        guard session.isPendingPrompt(line), let ticket = session.ticket(for: line) else {
            observe(line)
            return false
        }
        let policy = self.policy ?? PromptPolicy.detect(arguments: session.arguments)
        let kind = Self.classify(line, sudoPrompt: session.sudoPrompt)
        var matchOK = false
        if kind == .uninstallProceed, case .uninstall(let expected) = policy {
            let matched = Safety.parseMatchedApps(matchBlock ?? [])
            if let expected {
                matchError = Safety.matchMismatch(matched: matched, expected: expected)
                matchOK = matchError == nil
            } else {
                matchError = "Bubble didn't know which apps to expect, so nothing was removed."
            }
        }
        let reply = Self.decide(kind: kind, policy: policy, matchOK: matchOK, proceedConfirmed: proceedConfirmed)
        switch reply {
        case .password:
            // Empty input makes sudo give up, and Mole carries on without admin tasks.
            let command = (["mo"] + session.arguments.prefix(1)).joined(separator: " ")
            guard !declined, attempts < 3,
                  let pw = askPassword(AdminRequest(command: command, reason: reason, retry: attempts > 0)) else {
                declined = true
                session.send("\n", ifCurrent: ticket)
                return true
            }
            if session.sendSecret(pw, ifCurrent: ticket) {
                attempts += 1
            } else {
                // sudo stopped waiting (or asked again) while the dialog was open. The
                // password is dropped; if sudo asks again, the next prompt asks again.
                stalePasswordsDiscarded += 1
            }
        case .answer(let text):
            if session.send(text, ifCurrent: ticket), kind == .uninstallProceed { proceedConfirmed = true }
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

    /// Keeps the "Matched N app(s):" block that precedes the uninstall confirmation.
    private func observe(_ line: String) {
        if Safety.matchedHeaderCount(line.trimmingCharacters(in: .whitespaces)) != nil {
            matchBlock = [line]
        } else if matchBlock != nil, (matchBlock?.count ?? 0) < 1000 {
            matchBlock?.append(line)
        }
    }

    // MARK: Policy

    nonisolated static func decide(kind: PromptKind, policy: PromptPolicy, matchOK: Bool, proceedConfirmed: Bool) -> PromptReply {
        switch (kind, policy) {
        case (.sudoPassword, .optimize):
            return .password
        case (.sudoPassword, .uninstall):
            // Homebrew casks and system apps need admin rights, but only once the
            // user's exact selection was confirmed.
            return proceedConfirmed ? .password : .decline("\n")
        case (.sudoPassword, .strict):
            return .decline("\n")
        case (.otherPassword, _):
            return .decline("\n")
        case (.uninstallProceed, .uninstall):
            return matchOK ? .answer("y\n") : .decline("n\n")
        case (.uninstallRemoveConfirm, .uninstall):
            return proceedConfirmed ? .answer("\r") : .decline("q")
        case (.uninstallProceed, _):
            return .decline("n\n")
        case (.uninstallRemoveConfirm, _):
            return .decline("q")
        case (.yesNo, _):
            return .decline("n\n")
        case (.keyChoice(let cancel), _):
            return .decline(cancel)
        case (.unknown, _):
            return .declineUnknown
        }
    }

    nonisolated private static let sudoPatterns = [
        try! NSRegularExpression(pattern: #"^Password:$"#),
        try! NSRegularExpression(pattern: #"^\[sudo\] password for [^\s:]+:$"#),
    ]
    nonisolated private static let removeConfirm = try! NSRegularExpression(
        pattern: #"^(➤\s+)?Remove \d+ apps?(, \S+)?( \[Running\])?\s+Enter confirm, ESC cancel:$"#)

    /// - Parameter sudoPrompt: the session's own `SUDO_PROMPT`. When given, only that
    ///   exact text counts as sudo asking; a look-alike "Password:" is just unknown.
    nonisolated static func classify(_ prompt: String, sudoPrompt: String? = nil) -> PromptKind {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        let range = NSRange(p.startIndex..., in: p)
        if let sudoPrompt {
            if p == sudoPrompt.trimmingCharacters(in: .whitespaces) { return .sudoPassword }
            if sudoPatterns.contains(where: { $0.firstMatch(in: p, range: range) != nil }) { return .otherPassword }
        } else if sudoPatterns.contains(where: { $0.firstMatch(in: p, range: range) != nil }) {
            return .sudoPassword
        }
        if p == "Proceed with uninstallation? [y/N]" { return .uninstallProceed }
        if removeConfirm.firstMatch(in: p, range: range) != nil { return .uninstallRemoveConfirm }
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
