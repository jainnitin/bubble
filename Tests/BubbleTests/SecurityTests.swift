import CryptoKit
import XCTest
@testable import Bubble

/// Child PATH and environment, the executable ownership check, and the small guards in Safety.
final class ShellSecurityTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        chmod(tmp.path, 0o755)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ text: String, mode: mode_t = 0o755) throws -> String {
        let path = tmp.appendingPathComponent(name).path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, mode)
        return path
    }

    // MARK: PATH

    func testChildPathPutsSystemFoldersFirst() {
        let parts = Shell.makeChildPath(home: "/Users/x").split(separator: ":").map(String.init)
        XCTAssertEqual(Array(parts.prefix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertEqual(parts.last, "/Users/x/.local/bin")
        XCTAssertEqual(Shell.childPath, Shell.makeChildPath(home: Shell.home))
    }

    /// A `sudo` planted in ~/.local/bin (or Homebrew's bin) must never be the one that runs.
    func testPlantedSudoIsNotResolved() throws {
        let fakeHome = tmp.path
        try FileManager.default.createDirectory(atPath: fakeHome + "/.local/bin", withIntermediateDirectories: true)
        _ = try write(".local/bin/sudo", "#!/bin/sh\necho fake\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "command -v sudo"]
        p.environment = ["PATH": Shell.makeChildPath(home: fakeHome)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(found.trimmingCharacters(in: .whitespacesAndNewlines), "/usr/bin/sudo")
    }

    func testEnvironmentDropsShellInjection() {
        let env = Shell.sanitizedEnvironment([
            "HOME": "/Users/x", "PATH": "/evil:/usr/bin", "BASH_ENV": "/tmp/x", "ENV": "/tmp/y",
            "BASH_FUNC_sudo%%": "() { echo gotcha; }", "SUDO_ASKPASS": "/tmp/a", "DYLD_INSERT_LIBRARIES": "/tmp/l",
        ], extra: ["SUDO_PROMPT": "tok:"])
        XCTAssertEqual(env["PATH"], Shell.childPath)
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["SUDO_PROMPT"], "tok:")
        for k in ["BASH_ENV", "ENV", "BASH_FUNC_sudo%%", "SUDO_ASKPASS", "DYLD_INSERT_LIBRARIES"] { XCTAssertNil(env[k], k) }
    }

    /// End to end: even with an exported `sudo` function and BASH_ENV in Bubble's own
    /// environment, a child bash resolves `sudo` to /usr/bin/sudo.
    func testChildBashSeesRealSudo() async throws {
        let rc = try write("rc.sh", "sudo() { echo hijacked; }\n", mode: 0o644)
        setenv("BASH_FUNC_sudo%%", "() { echo hijacked; }", 1)
        setenv("BASH_ENV", rc, 1)
        defer { unsetenv("BASH_FUNC_sudo%%"); unsetenv("BASH_ENV") }
        let data = await Shell.output("/bin/bash", ["-c", "type -t sudo; command -v sudo"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "file\n/usr/bin/sudo\n")
    }

    func testMoAndBrewOnlyFromFixedLocations() {
        XCTAssertEqual(Shell.moleCandidates, ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", Shell.home + "/.local/bin/mo"])
        XCTAssertEqual(Shell.brewCandidates, ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        if let mo = Shell.mo { XCTAssertTrue(Shell.moleCandidates.contains(mo)) }
        XCTAssertNil(Shell.which("../bin/sh"))
        XCTAssertNil(Shell.which(""))
    }

    // MARK: Ownership rule

    private let me: uid_t = 501
    private func info(_ owner: uid_t, _ group: gid_t, _ mode: mode_t, dir: Bool = true) -> Shell.FileInfo {
        Shell.FileInfo(owner: owner, group: group, mode: (dir ? S_IFDIR : S_IFREG) | mode, isDirectory: dir)
    }
    private func problem(_ i: Shell.FileInfo) -> String? {
        Shell.ownershipProblem(i, path: "/x", me: me, isAdmin: { $0 == 502 })
    }

    func testOwnershipRule() {
        XCTAssertNil(problem(info(0, 0, 0o755)), "root")
        XCTAssertNil(problem(info(me, 20, 0o755)), "mine")
        XCTAssertNil(problem(info(me, 80, 0o775)), "Homebrew: admin group-writable")
        XCTAssertNil(problem(info(502, 80, 0o755)), "another admin's Homebrew")
        XCTAssertNil(problem(info(0, 0, 0o1777)), "sticky /tmp")
        XCTAssertNotNil(problem(info(503, 20, 0o755)), "another non-admin user")
        XCTAssertNotNil(problem(info(me, 20, 0o775)), "staff-writable (every user)")
        XCTAssertNotNil(problem(info(me, 80, 0o757)), "world-writable")
        XCTAssertNotNil(problem(info(me, 20, 0o757, dir: false)), "world-writable file")
        XCTAssertNotNil(problem(info(me, 20, 0o1777, dir: false)), "sticky bit means nothing on a file")
    }

    func testCheckerFollowsLinksIntoBadFolder() {
        let table: [String: Shell.FileInfo] = [
            "/": info(0, 0, 0o755), "/opt": info(0, 0, 0o755), "/opt/hb": info(me, 80, 0o775),
            "/opt/hb/bin": info(me, 80, 0o775), "/opt/hb/bin/mo": Shell.FileInfo(owner: me, group: 80, mode: S_IFLNK | 0o755, isDirectory: false),
            "/srv": info(0, 0, 0o755), "/srv/shared": info(0, 20, 0o775), "/srv/shared/mo": info(me, 20, 0o755, dir: false),
        ]
        // Symlink following is covered with real files below; here, the folder rule.
        var checker = Shell.TrustChecker(me: me, isAdmin: { _ in false }, info: { p, _ in table[p] })
        XCTAssertNotNil(checker.check(executable: "/srv/shared/mo"), "staff-writable parent folder")
        var hb = Shell.TrustChecker(me: me, isAdmin: { _ in false }, info: { p, _ in
            p == "/opt/hb/bin/tool" ? Shell.FileInfo(owner: 501, group: 80, mode: S_IFREG | 0o755, isDirectory: false) : table[p]
        })
        XCTAssertNil(hb.check(executable: "/opt/hb/bin/tool"), "Homebrew layout")
        var missing = Shell.TrustChecker(me: me, isAdmin: { _ in false }, info: { p, _ in table[p] })
        XCTAssertNotNil(missing.check(executable: "/nope/mo"))
        XCTAssertNotNil(missing.check(executable: "relative/mo"))
    }

    // MARK: Real files

    func testTempScriptTrust() throws {
        let path = try write("tool", "#!/bin/sh\necho hi\n")
        XCTAssertNil(Shell.trustProblem(executable: path))
        chmod(path, 0o775)  // group staff
        XCTAssertNotNil(Shell.trustProblem(executable: path))
        chmod(path, 0o757)
        XCTAssertNotNil(Shell.trustProblem(executable: path))
        chmod(path, 0o755)
        chmod(tmp.path, 0o777)  // the folder, not sticky
        XCTAssertNotNil(Shell.trustProblem(executable: path))
        chmod(tmp.path, 0o755)
    }

    func testSymlinkToGroupWritableFileIsRefused() throws {
        let target = try write("real", "#!/bin/sh\n", mode: 0o775)
        let link = tmp.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real")
        XCTAssertNotNil(Shell.trustProblem(executable: link))
        chmod(target, 0o755)
        XCTAssertNil(Shell.trustProblem(executable: link))
    }

    func testRefusedExecutableNeverRuns() async throws {
        let marker = tmp.appendingPathComponent("ran").path
        let path = try write("bad", "#!/bin/sh\ntouch '\(marker)'\n", mode: 0o757)
        var lines: [String] = []
        for await l in Shell.lines(path, []) { lines.append(l) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("Bubble didn't run bad:"), lines[0])
        let data = await Shell.output(path, [])
        XCTAssertTrue(data.isEmpty)
        var events: [String] = []
        for await e in InstallRunner.run(path, []) {
            if case .line(let l) = e { events.append(l) }
            if case .exit(let c) = e { XCTAssertEqual(c, -1) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    /// The Mole on this Mac (Homebrew or script install), if any, passes the check.
    func testInstalledMolePasses() throws {
        guard let mo = Shell.mo else { throw XCTSkip("Mole isn't installed") }
        XCTAssertNil(Shell.trustProblem(executable: mo))
    }

    func testSystemToolsPass() {
        for exe in ["/usr/bin/script", "/bin/bash", "/bin/ps", "/usr/bin/sudo"] {
            XCTAssertNil(Shell.trustProblem(executable: exe), exe)
        }
    }

    // MARK: Safety guards

    func testCommandArgumentGuard() {
        for ok in ["Xcode", "Claude Code URL Handler", "visual-studio-code", "Café", "‎WhatsApp", "a-b"] {
            XCTAssertTrue(Safety.isSafeCommandArgument(ok), ok)
        }
        for bad in ["", " ", "-rf", "--help", "-", "a\nb", "a\rb", "x\u{0}", "\u{1B}[2J", "tab\there", "a\u{2028}b", "y\n"] {
            XCTAssertFalse(Safety.isSafeCommandArgument(bad), bad.debugDescription)
        }
    }

    func testAdminQuotingSurvivesQuotesAndSpaces() throws {
        let path = tmp.appendingPathComponent("it's a \"test\" $(touch pwned) `x` dir").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + Admin.quote(path)]
        p.currentDirectoryURL = tmp
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("pwned").path))
    }

    func testAdminScriptMovesQuotedPathIntoTrash() async throws {
        let mac = try FakeMac()
        let odd = try mac.file(mac.sys("Application Support/com.example.odd 'quoted' \"name\" $HOME"))
        let r = mac.remover()
        let script = r.adminScript([RemovalItem(path: odd, bytes: 0, isSystem: true)])
        XCTAssertTrue(script.contains(Admin.quote(odd)))
        let outcome = await r.removeWithAdmin([PendingAdmin(owner: 0, item: RemovalItem(path: odd, bytes: 0, isSystem: true))], prompt: "p")
        XCTAssertEqual(outcome.removed, [odd])
        XCTAssertEqual(mac.trashContents(), [(odd as NSString).lastPathComponent])
    }

    func testExternalURLGuard() {
        for ok in ["https://github.com/tw93/Mole", "HTTPS://brew.sh", "macappstore://apps.apple.com/app/id497799835"] {
            XCTAssertTrue(Safety.isAllowedExternalURL(URL(string: ok)!), ok)
        }
        for bad in ["http://example.com", "file:///Applications/Calculator.app", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference",
                    "ssh://host", "https:///nohost", "smb://server/share", "tel:123"] {
            if let u = URL(string: bad) { XCTAssertFalse(Safety.isAllowedExternalURL(u), bad) }
        }
    }
}

/// sudo's prompt: Bubble never types a password into it. Only this session's own sudo prompt
/// counts as sudo, a look-alike gets nothing but an empty line, and no reply lands after
/// the process moved on.
@MainActor
final class SudoPromptTests: XCTestCase {
    func testStalenessRule() {
        let t = PromptTicket(chunks: 7)
        XCTAssertTrue(PTYSession.isPromptCurrent(t, currentChunks: 7, finished: false))
        XCTAssertFalse(PTYSession.isPromptCurrent(t, currentChunks: 8, finished: false))
        XCTAssertFalse(PTYSession.isPromptCurrent(t, currentChunks: 7, finished: true))
    }

    func testClassifyWithSessionPrompt() {
        let tok = "Bubble sudo password 0a1b2c3d4e5f:"
        XCTAssertEqual(PromptResponder.classify(tok, sudoPrompt: tok), .sudoPassword)
        XCTAssertEqual(PromptResponder.classify("Password:", sudoPrompt: tok), .otherPassword)
        XCTAssertEqual(PromptResponder.classify("[sudo] password for nitin:", sudoPrompt: tok), .otherPassword)
        XCTAssertEqual(PromptResponder.decide(kind: .otherPassword, policy: .optimize), .decline("\n"))
        XCTAssertNotEqual(PTYSession.makeSudoPrompt(), PTYSession.makeSudoPrompt())
        XCTAssertTrue(PTYSession.makeSudoPrompt().hasSuffix(":"))
        XCTAssertFalse(PTYSession.makeSudoPrompt().contains("%"))
    }

    private func run(_ script: String, policy: PromptPolicy) async -> (lines: [String], responder: PromptResponder) {
        let session = PTYSession("/bin/bash", ["-c", script])
        let responder = PromptResponder(policy: policy)
        var lines: [String] = []
        for await line in session.lines {
            if !responder.handle(line, session) { lines.append(line) }
        }
        return (lines, responder)
    }

    func testLookalikePasswordPromptGetsNothing() async {
        let script = #"printf 'Password:'; IFS= read -r p; echo "len=${#p}""#
        let (lines, r) = await run(script, policy: .optimize)
        XCTAssertTrue(lines.contains("len=0"), "\(lines)")
        XCTAssertEqual(r.skippedPrompts, ["Password:"])
        XCTAssertFalse(r.adminSkipped)
    }

    func testRealSudoPromptGetsNothingInStrictPolicy() async {
        let script = #"printf '%s' "$SUDO_PROMPT"; IFS= read -r p; echo "rc=$? len=${#p}""#
        let (lines, r) = await run(script, policy: .strict)
        XCTAssertTrue(lines.contains("rc=0 len=0"), "\(lines)")
        XCTAssertEqual(r.skippedPrompts.count, 1)
    }
}

/// The pinned Mole installer: right URL and hash, and the command refuses a mismatch.
final class PinnedInstallerTests: XCTestCase {
    func testPinIsWellFormed() {
        let pin = MoleInstall.pinnedInstaller
        XCTAssertNotNil(pin.tag.range(of: #"^V\d+\.\d+\.\d+$"#, options: .regularExpression))
        XCTAssertNotNil(pin.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
        XCTAssertEqual(pin.url.absoluteString, "https://raw.githubusercontent.com/tw93/Mole/\(pin.tag)/install.sh")
        let cmd = MoleInstall.scriptCommand
        XCTAssertTrue(cmd.contains(pin.url.absoluteString))
        XCTAssertTrue(cmd.contains(pin.sha256))
        XCTAssertFalse(cmd.contains("/main/"))
        XCTAssertFalse(cmd.contains("| bash"))
        XCTAssertEqual(MoleInstall.Method.script.command, cmd)
    }

    private func runCommand(_ command: String) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        p.environment = Shell.childEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testCommandVerifiesBeforeRunning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("install.sh")
        try #"echo "ran with: $*""#.write(to: script, atomically: true, encoding: .utf8)
        let hash = SHA256.hash(data: try Data(contentsOf: script)).map { String(format: "%02x", $0) }.joined()

        let good = MoleInstall.PinnedInstaller(tag: "V9.9.9", sha256: hash)
        let (rc, out) = try runCommand(MoleInstall.installCommand(good, url: script, prefix: "/tmp/x"))
        XCTAssertEqual(rc, 0, out)
        XCTAssertTrue(out.contains("ran with: --prefix /tmp/x V9.9.9"), out)

        let bad = MoleInstall.PinnedInstaller(tag: "V9.9.9", sha256: String(repeating: "0", count: 64))
        let (rc2, out2) = try runCommand(MoleInstall.installCommand(bad, url: script, prefix: "/tmp/x"))
        XCTAssertNotEqual(rc2, 0)
        XCTAssertFalse(out2.contains("ran with"), out2)
        XCTAssertTrue(MoleInstall.explain(status: rc2, method: .script, log: out2.components(separatedBy: "\n")).contains("checksum"), out2)
    }
}
