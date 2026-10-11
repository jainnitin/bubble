import Foundation
import Observation

/// Whether Mole is installed, which version, and installing or updating it.
///
/// Detection is re-checked at runtime (`refresh()`), so Mole installed while Bubble
/// is open is picked up without a relaunch: once it's found, live status starts.
///
/// Nothing is ever installed without an explicit click, and no route here uses
/// `sudo`: Homebrew installs into its own prefix, and Mole's install script is run
/// with `--prefix ~/.local/bin` so it never needs an administrator password. The
/// script is a pinned release whose SHA-256 is baked into Bubble (`pinnedInstaller`).
///
/// Debug launch arguments, compiled only into `BUBBLE_DEV=1 scripts/bundle.sh` builds
/// (see also `DetectionOverrides` in Shell.swift):
/// - `-simulateNoMole YES`            Mole reported missing (welcome screen)
/// - `-simulateNoBrew YES`            Homebrew reported missing (install-script route)
/// - `-simulateMoleVersion 1.40.0`    report this version (update screen)
/// - `-simulateInstallFailure YES`    the dry-run install fails (error screen)
/// - `-simulateNoFullDiskAccess YES`  Full Disk Access reported off (access step)
/// While any of them is set, install and update are dry runs: canned output, nothing runs.
@Observable
@MainActor
final class MoleInstall {
    static let shared = MoleInstall()

    /// The oldest Mole that Bubble's parsing and flags are tested against.
    static let minimumVersion = "1.59.0"
    nonisolated static let repo = URL(string: "https://github.com/tw93/Mole")!

    /// Mole's official install script, pinned to one release and checked against a SHA-256
    /// baked into Bubble, instead of whatever is on Mole's `main` branch today. Passing the
    /// tag to the script also makes it install that release (it otherwise asks GitHub for
    /// the latest), and the script verifies each downloaded binary against the release's
    /// own checksums.
    ///
    /// To move to a newer Mole release:
    ///   1. gh api repos/tw93/Mole/releases/latest --jq .tag_name            (e.g. V1.60.0)
    ///   2. curl -fsSL https://raw.githubusercontent.com/tw93/Mole/<tag>/install.sh -o /tmp/i.sh
    ///   3. Read the diff against the previous tag's install.sh.
    ///   4. shasum -a 256 /tmp/i.sh   and put the tag and hash below.
    /// MoleInstallTests checks the hash format; `minimumVersion` may need raising too.
    nonisolated static let pinnedInstaller = PinnedInstaller(
        tag: "V1.59.1",
        sha256: "5fae246355a1ff237beaf945e9d9778c49b743293095eb54d8cb7b7a5327f727")

    struct PinnedInstaller: Equatable, Sendable {
        let tag: String
        let sha256: String
        var url: URL { URL(string: "https://raw.githubusercontent.com/tw93/Mole/\(tag)/install.sh")! }
    }

    /// Mole's non-Homebrew install (README, "Other install options"), with the documented
    /// `--prefix` so it installs into the home folder without admin rights. Downloads the
    /// pinned script to a private temp file, stops unless its SHA-256 matches, then runs it
    /// with bash. This exact text is shown before it runs, is what "Copy command" copies
    /// (it's safe to paste into Terminal), and is what Bubble runs.
    nonisolated static let scriptCommand = installCommand(pinnedInstaller)

    nonisolated static func installCommand(_ pin: PinnedInstaller, url: URL? = nil, prefix: String = #""$HOME/.local/bin""#) -> String {
        """
        (
          set -e
          f="$(mktemp -t mole-install)"; trap 'rm -f "$f"' EXIT
          curl -fsSL -o "$f" \((url ?? pin.url).absoluteString)
          echo "\(pin.sha256)  $f" | shasum -a 256 -c -
          bash "$f" --prefix \(prefix) \(pin.tag)
        )
        """
    }

    enum State: Equatable {
        case missing
        case outdated(String)
        /// `mo` (or Mole's library) could be changed by someone other than you, root or
        /// an admin, so Bubble won't run it. The text says which file and how to fix it.
        case untrusted(String)
        case ready
    }

    enum Method: Equatable {
        case brewInstall, brewUpgrade, script, moUpdate

        /// Exactly what runs, as shown to the user before they agree.
        var command: String {
            switch self {
            case .brewInstall: "brew install mole"
            case .brewUpgrade: "brew upgrade mole"
            case .script: MoleInstall.scriptCommand
            case .moUpdate: "mo update"
            }
        }

        var isUpdate: Bool { self == .brewUpgrade || self == .moUpdate }
    }

    enum Job: Equatable {
        case idle
        case running(Method)
        case succeeded(Method)
        case failed(Method, String)
    }

    private(set) var state: State
    private(set) var version: String?
    private(set) var path: String?
    /// How Mole says it was installed ("Homebrew", "Script", …), from `mo --version`.
    private(set) var installKind: String?
    private(set) var job: Job = .idle
    private(set) var log: [String] = []

    /// True while the main window shows setup instead of the app. Set when Mole is
    /// missing or too old; cleared when the user finishes or skips setup. An update
    /// started from Settings doesn't take over the window.
    private(set) var setupActive: Bool
    /// The setup flow has moved on to the Full Disk Access step.
    private(set) var askingForAccess = false

    private var task: Task<Void, Never>?
    #if BUBBLE_DEV
    private var simulatedUpgradeDone = false
    #endif

    var hasHomebrew: Bool { Shell.brew != nil }
    var installedWithHomebrew: Bool {
        if let installKind { return installKind.localizedCaseInsensitiveContains("homebrew") }
        return path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.contains("/Cellar/") } ?? false
    }

    /// How to update the installed Mole.
    var updateMethod: Method { installedWithHomebrew && hasHomebrew ? .brewUpgrade : .moUpdate }

    var isRunning: Bool { if case .running = job { true } else { false } }

    /// True only in BUBBLE_DEV builds launched with a `-simulate…` argument.
    static var isSimulating: Bool {
        #if BUBBLE_DEV
        let d = UserDefaults.standard
        return ["simulateNoMole", "simulateNoBrew", "simulateInstallFailure", "simulateNoFullDiskAccess"].contains { d.bool(forKey: $0) }
            || d.string(forKey: "simulateMoleVersion") != nil
        #else
        return false
        #endif
    }

    static var hasFullDiskAccess: Bool {
        #if BUBBLE_DEV
        if UserDefaults.standard.bool(forKey: "simulateNoFullDiskAccess") { return false }
        #endif
        return SystemSettings.hasFullDiskAccess
    }

    private init() {
        // Synchronous first guess so the window doesn't flash setup when Mole is there;
        // the version check follows.
        let found = Shell.mo != nil
        state = found ? .ready : .missing
        setupActive = !found
        path = Shell.mo
        Task { await refresh() }
    }

    // MARK: Detection

    /// Looks for `mo` again and reads its version. Shows setup when Mole is missing, too
    /// old or untrusted; otherwise starts live status.
    func refresh() async {
        await detect()
        if state == .ready {
            StatusModel.shared.start()
        } else {
            setupActive = true
        }
    }

    /// Looks for `mo` again and reads its version, without changing what the window shows.
    func detect() async {
        guard let mo = Shell.mo else {
            path = nil; version = nil; installKind = nil
            state = .missing
            return
        }
        path = mo
        if let why = Shell.trustProblem(executable: mo) {
            version = nil; installKind = nil
            state = .untrusted(why)
            return
        }
        let text = Shell.clean(String(decoding: await Shell.output(mo, ["--version"], timeout: 15), as: UTF8.self))
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        version = lines.first { $0.hasPrefix("Mole version") }.map { String($0.dropFirst("Mole version".count)).trimmingCharacters(in: .whitespaces) }
        installKind = lines.first { $0.hasPrefix("Install:") }.map { String($0.dropFirst("Install:".count)).trimmingCharacters(in: .whitespaces) }
        #if BUBBLE_DEV
        if !simulatedUpgradeDone, let fake = UserDefaults.standard.string(forKey: "simulateMoleVersion") { version = fake }
        #endif
        // An unreadable version doesn't block: Bubble tries, and errors say why.
        if let version, VersionCompare.isNewer(Self.minimumVersion, than: version) {
            state = .outdated(version)
        } else {
            state = .ready
        }
    }

    /// The newer Mole that Homebrew offers, or nil when it has none (or isn't there).
    /// Only asks; installs nothing.
    static func homebrewLatest() async -> String? {
        guard let brew = Shell.brew else { return nil }
        return parseBrewOutdated(await Shell.output(brew, ["outdated", "--json=v2", "mole"], timeout: 60))
    }

    /// `brew outdated --json=v2 mole`: {"formulae": [{"name": "mole", "current_version": "1.60.0", …}]}.
    nonisolated static func parseBrewOutdated(_ data: Data) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["formulae"] as? [[String: Any]])?.first?["current_version"] as? String
    }

    // MARK: Setup flow

    /// The install route for a missing Mole: Homebrew when it's there, else Mole's script.
    var installMethod: Method { hasHomebrew ? .brewInstall : .script }

    /// Runs `method`. Only ever called from a button the user clicked.
    func start(_ method: Method) {
        guard !isRunning else { return }
        log = []
        job = .running(method)
        task = Task { await run(method) }
    }

    /// Runs `method` and returns when it ends (for the Checkup sheet).
    func runToEnd(_ method: Method) async {
        start(method)
        await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        job = .failed(currentMethod ?? installMethod, "You stopped the install. Nothing else was changed; run it again when you're ready.")
    }

    private var currentMethod: Method? {
        if case .running(let m) = job { return m }
        return nil
    }

    /// Back to the welcome or update screen after a failure.
    func dismissFailure() { job = .idle }

    /// Leaves an outdated Mole in place and opens the app anyway.
    func continueWithoutUpdating() {
        state = .ready
        setupActive = false
        StatusModel.shared.start()
    }

    /// After success: ask for Full Disk Access if it's off, else open the app.
    func finishInstall() {
        job = .idle
        if !Self.hasFullDiskAccess && !UserDefaults.standard.bool(forKey: "setupAccessSkipped") {
            askingForAccess = true
        } else {
            setupActive = false
        }
    }

    /// Ends setup from the Full Disk Access step ("Later", or access is on).
    func finishAccess(skipped: Bool) {
        if skipped { UserDefaults.standard.set(true, forKey: "setupAccessSkipped") }
        askingForAccess = false
        setupActive = false
    }

    // MARK: Running

    private func run(_ method: Method) async {
        let status: Int32
        #if BUBBLE_DEV
        if Self.isSimulating {
            status = await simulate(method)
        } else {
            status = await runForReal(method)
        }
        #else
        status = await runForReal(method)
        #endif
        guard status != Self.notStarted else { return }
        await finish(method, status: status)
    }

    /// Exit status used when the command couldn't be found (the job already says why).
    private static let notStarted: Int32 = .min

    private func runForReal(_ method: Method) async -> Int32 {
        guard let (exe, args) = invocation(method) else {
            job = .failed(method, method == .brewInstall || method == .brewUpgrade
                ? "Homebrew isn't on this Mac any more. Install Mole with the script instead, or reinstall Homebrew from brew.sh."
                : "Bubble can't find mo to update it. Check again, or reinstall Mole.")
            return Self.notStarted
        }
        var last: Int32 = -1
        for await event in InstallRunner.run(exe, args) {
            switch event {
            case .line(let l): append(l)
            case .exit(let code): last = code
            }
        }
        return last
    }

    private func finish(_ method: Method, status: Int32) async {
        guard !Task.isCancelled, case .running = job else { return }
        if status == 0 {
            await refresh()
            switch state {
            case .ready:
                job = .succeeded(method)
            case .missing:
                job = .failed(method, "The installer finished, but Bubble can't find mo in /opt/homebrew/bin, /usr/local/bin or ~/.local/bin. Check the output below, then try again.")
            case .outdated(let v):
                job = .failed(method, "Mole is still at \(v), and Bubble needs \(Self.minimumVersion) or later. Check the output below, then try again.")
            case .untrusted(let why):
                job = .failed(method, why)
            }
        } else {
            job = .failed(method, Self.explain(status: status, method: method, log: log))
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    private func invocation(_ method: Method) -> (String, [String])? {
        switch method {
        case .brewInstall: Shell.brew.map { ($0, ["install", "mole"]) }
        case .brewUpgrade: Shell.brew.map { ($0, ["upgrade", "mole"]) }
        case .script: ("/bin/bash", ["-c", Self.scriptCommand])
        case .moUpdate: Shell.mo.map { ($0, ["update"]) }
        }
    }

    /// What went wrong, in one or two sentences, from the exit code and output.
    nonisolated static func explain(status: Int32, method: Method, log: [String]) -> String {
        let text = log.joined(separator: "\n").lowercased()
        if method == .script, text.contains("checksum did not match") || text.contains(": failed") {
            return "The downloaded installer didn't match the checksum built into Bubble, so it wasn't run. Try again later; if it keeps happening, update Bubble."
        }
        if text.contains("could not resolve host") || text.contains("failed to connect") || text.contains("network is unreachable")
            || text.contains("operation timed out") {
            return "Bubble couldn't reach the internet to download Mole. Check your connection, then try again."
        }
        if text.contains("permission denied") || text.contains("not writable") {
            return "The installer couldn't write to its folder (permission denied). The output below names the folder; fix its permissions in Terminal, then try again."
        }
        if text.contains("xcode-select") || text.contains("command line tools") {
            return "Homebrew needs Apple's Command Line Tools first. Run xcode-select --install in Terminal, then try again."
        }
        let who = switch method {
        case .brewInstall, .brewUpgrade: "Homebrew"
        case .script: "Mole's installer"
        case .moUpdate: "Mole's updater"
        }
        return "\(who) stopped with an error (exit code \(status)). The last lines of its output below say why."
    }

    // MARK: Dry run

    #if BUBBLE_DEV
    /// Canned output for testing the flow; runs nothing.
    private func simulate(_ method: Method) async -> Int32 {
        let lines: [String] = switch method {
        case .brewInstall:
            ["==> Fetching downloads for: mole", "==> Fetching mole", "==> Downloading https://ghcr.io/v2/homebrew/core/mole/manifests/1.59.1",
             "==> Pouring mole--1.59.1.arm64_sequoia.bottle.tar.gz", "🍺  /opt/homebrew/Cellar/mole/1.59.1: 212 files, 18.4MB"]
        case .brewUpgrade:
            ["==> Upgrading 1 outdated package:", "mole 1.40.0 -> 1.59.1", "==> Fetching mole", "==> Pouring mole--1.59.1.arm64_sequoia.bottle.tar.gz",
             "🍺  /opt/homebrew/Cellar/mole/1.59.1: 212 files, 18.4MB"]
        case .script, .moUpdate:
            ["Installing Mole...", "Downloading release V1.59.1", "Verified status-darwin-arm64 · sha256", "Verified analyze-darwin-arm64 · sha256",
             "Installed to ~/.local/bin", "Mole 1.59.1 installed"]
        }
        let fail = UserDefaults.standard.bool(forKey: "simulateInstallFailure")
        for (i, line) in lines.enumerated() {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return -1 }
            if fail && i == 2 {
                append("curl: (6) Could not resolve host: github.com")
                append("Error: Failed to download mole (simulated)")
                return 1
            }
            append(line)
        }
        DetectionOverrides.revealMole()
        simulatedUpgradeDone = true
        return 0
    }
    #endif
}

/// Runs an installer, streaming its output lines and then its exit status. It gets
/// `Shell.childEnvironment` (system folders first on PATH) and is refused if
/// `Shell.trustProblem` objects to the executable. Standard input is empty, so a prompt
/// (including sudo's) fails instead of hanging.
enum InstallRunner {
    enum Event { case line(String), exit(Int32) }

    private final class Box: @unchecked Sendable { var status: Int32 = -1 }

    static func run(_ exe: String, _ args: [String]) -> AsyncStream<Event> {
        AsyncStream { cont in
            if let why = Shell.refusal(exe) {
                cont.yield(.line(why))
                cont.yield(.exit(-1))
                cont.finish()
                return
            }
            var env = Shell.childEnvironment(["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
            env["HOMEBREW_COLOR"] = nil
            let p = Shell.makeProcess(exe, args, environment: env)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            let box = Box()
            // The exit status is reported once both the output and the process have ended.
            let done = DispatchGroup()
            done.enter(); done.enter()
            Shell.readLines(from: pipe, onLines: { lines in
                for l in lines { cont.yield(.line(l)) }
            }, onEnd: { rest in
                for l in rest { cont.yield(.line(l)) }
                done.leave()
            })
            p.terminationHandler = { proc in
                box.status = proc.terminationStatus
                done.leave()
            }
            cont.onTermination = { _ in if p.isRunning { p.terminate() } }
            do {
                try p.run()
                done.notify(queue: .global()) {
                    cont.yield(.exit(box.status))
                    cont.finish()
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.yield(.line("Couldn't start \(exe): \(error.localizedDescription)"))
                cont.yield(.exit(-1))
                cont.finish()
            }
        }
    }
}
