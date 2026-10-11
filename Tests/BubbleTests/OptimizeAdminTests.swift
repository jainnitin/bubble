import XCTest
@testable import Bubble

/// Optimize runs Mole without admin rights and never shows a password dialog.
@MainActor
final class OptimizeNoAdminTests: XCTestCase {
    func testSudoPromptIsEndedWithoutAskingAnyone() async {
        let script = #"echo start; stty -echo; printf '%s' "$SUDO_PROMPT"; IFS= read -r p; echo "rc=$? len=${#p}"; echo after"#
        let session = PTYSession("/bin/bash", ["-c", script])
        let responder = PromptResponder(reason: "", policy: .optimize)
        responder.askPassword = { _ in XCTFail("Optimize must never ask for a password"); return nil }
        var lines: [String] = []
        for await line in session.lines {
            if !responder.handle(line, session) { lines.append(line) }
        }
        XCTAssertTrue(lines.contains("rc=1 len=0"), "\(lines)")
        XCTAssertTrue(lines.contains("after"), "\(lines)")
        XCTAssertTrue(responder.adminSkipped)
        XCTAssertEqual(responder.skippedPrompts, [])
        XCTAssertEqual(responder.stalePasswordsDiscarded, 0)
    }

    func testShimMakesSudoUnavailable() async throws {
        let dir = try XCTUnwrap(MoleNoSudo.make())
        defer { MoleNoSudo.remove(dir) }
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let env = MoleNoSudo.environment(shimDir: dir)
        XCTAssertEqual(env["PATH"], dir.path + ":" + Shell.childPath)
        XCTAssertEqual(env["MOLE_PAM_SUDO_FILE"], "/dev/null")
        let script = #"echo "which=$(command -v sudo)"; sudo -k; echo k=$?; sudo -v; echo v=$?; sudo -n true; echo n=$?"#
        let session = PTYSession("/bin/bash", ["-c", script], environment: env)
        let responder = PromptResponder(reason: "", policy: .optimize)
        var lines: [String] = []
        for await line in session.lines {
            if !responder.handle(line, session) { lines.append(line) }
        }
        XCTAssertTrue(lines.contains("which=\(dir.path)/sudo"), "\(lines)")
        XCTAssertTrue(lines.contains("k=0"), "\(lines)")
        XCTAssertTrue(lines.contains("v=1"), "\(lines)")
        XCTAssertTrue(lines.contains("n=1"), "\(lines)")
        XCTAssertFalse(responder.adminSkipped, "no prompt should have appeared")
    }

    func testShimRemovalIsScoped() {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("not-ours-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        MoleNoSudo.remove(other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try? FileManager.default.removeItem(at: other)
        XCTAssertNil(MoleNoSudo.environment(shimDir: nil)["PATH"])
    }
}

final class OptimizeAdminScriptTests: XCTestCase {
    func testScriptIsDeterministicAndQuoted() {
        let both = OptimizeAdmin.script(for: [.spotlight, .dns])
        XCTAssertEqual(both, OptimizeAdmin.script(for: [.dns, .spotlight]))
        XCTAssertEqual(both, """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        if { /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder; } >/dev/null 2>&1; then echo 'bubble-result dns ok'; else echo 'bubble-result dns failed'; fi
        if { /usr/bin/mdutil -E '/'; } >/dev/null 2>&1; then echo 'bubble-result spotlight ok'; else echo 'bubble-result spotlight failed'; fi

        """)
        XCTAssertFalse(OptimizeAdmin.script(for: [.dns]).contains("mdutil"))
        XCTAssertEqual(OptimizeAdmin.script(for: []), "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH\n")
    }

    func testScriptRunsInSh() throws {
        // Swap the root commands for harmless ones to check the shell syntax and output.
        let script = OptimizeAdmin.script(for: [.dns, .spotlight])
            .replacingOccurrences(of: "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder", with: "true")
            .replacingOccurrences(of: "/usr/bin/mdutil -E '/'", with: "false")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(OptimizeAdmin.parse(String(decoding: data, as: UTF8.self)), [.dns: true, .spotlight: false])
    }

    func testParse() {
        XCTAssertEqual(OptimizeAdmin.parse("bubble-result dns ok\rbubble-result spotlight failed\r"), [.dns: true, .spotlight: false])
        XCTAssertEqual(OptimizeAdmin.parse("noise\nbubble-result dns ok\nbubble-result bogus ok\nbubble-result dns\n"), [.dns: true])
        XCTAssertEqual(OptimizeAdmin.parse(""), [:])
    }

    func testPromptAndResultLines() {
        XCTAssertEqual(OptimizeAdmin.prompt(for: [.dns]), "Bubble wants to flush the DNS cache to finish maintenance.")
        XCTAssertEqual(OptimizeAdmin.prompt(for: [.spotlight, .dns]),
                       "Bubble wants to flush the DNS cache and rebuild the Spotlight index to finish maintenance.")
        XCTAssertEqual(OptimizeTask(name: "x", results: [OptimizeAdmin.Job.dns.resultLine(ok: true)]).symbol.0, "checkmark")
        XCTAssertEqual(OptimizeTask(name: "x", results: [OptimizeAdmin.Job.spotlight.resultLine(ok: false)]).symbol.0, "exclamationmark.circle")
    }

    func testVPNState() {
        let base = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1

        """
        XCTAssertEqual(OptimizeAdmin.vpnState(routeOutput: base + "  interface: en0\n      flags: <UP,GATEWAY,DONE>\n"), .none)
        XCTAssertEqual(OptimizeAdmin.vpnState(routeOutput: base + "  interface: utun4\n"), .active)
        XCTAssertEqual(OptimizeAdmin.vpnState(routeOutput: base + "  interface: utunx\n"), .none)
        XCTAssertEqual(OptimizeAdmin.vpnState(routeOutput: ""), .unknown)
        XCTAssertNil(OptimizeAdmin.vpnSkipLine(.none))
        XCTAssertEqual(OptimizeAdmin.vpnSkipLine(.active)?.first, "-")
        XCTAssertEqual(OptimizeAdmin.vpnSkipLine(.unknown)?.first, "-")
    }
}

/// `mo optimize` output (as Mole 1.59 prints it without admin rights) folded into tasks.
final class OptimizeLogTests: XCTestCase {
    private let output = """
    Optimize
    ➤ System optimization requires admin access
    ➤ Enter your credentials:
    sudo: no password was provided
    ✓ Skipping sudo-required optimizations: admin access not granted
    ➤ DNS & Spotlight Check
    ✓ DNS & Spotlight check skipped (admin access required)
    ➤ Finder Cache Refresh
    ✓ QuickLook thumbnails refreshed
    ➤ Network Cache Refresh
    ✓ Network cache refresh skipped (admin access required)
    ➤ Network Stack Refresh
    ◎ Network stack refresh · skipped (admin access required)
    ➤ Spotlight Optimization
    ◎ Spotlight index rebuild · skipped (admin access required)
    ➤ Periodic Maintenance
    ✓ Periodic maintenance skipped (requires sudo)
    """

    private func fold(_ adminOn: Bool) -> OptimizeLog {
        var log = OptimizeLog(adminTasksOn: adminOn)
        for line in output.split(separator: "\n") { log.consume(String(line)) }
        return log
    }

    func testTasksAndDeferredJobs() {
        let log = fold(true)
        XCTAssertEqual(log.tasks.map(\.name), ["DNS & Spotlight Check", "Finder Cache Refresh", "Network Cache Refresh",
                                               "Network Stack Refresh", "Spotlight Optimization", "Periodic Maintenance"])
        XCTAssertTrue(log.moleSkippedAdmin)
        XCTAssertEqual(log.deferred, [.dns, .spotlight])
    }

    func testSkipsReadAsSkippedWhenBubbleTakesOver() {
        let t = Dictionary(uniqueKeysWithValues: fold(true).tasks.map { ($0.name, $0) })
        XCTAssertEqual(t["DNS & Spotlight Check"]?.results, ["- DNS & Spotlight check skipped (admin access required), Bubble does this at the end"])
        XCTAssertEqual(t["DNS & Spotlight Check"]?.symbol.0, "minus.circle")
        XCTAssertEqual(t["Spotlight Optimization"]?.symbol.0, "minus.circle")
        XCTAssertEqual(t["Finder Cache Refresh"]?.symbol.0, "checkmark")
        // Real problems Bubble won't fix keep Mole's attention mark.
        XCTAssertEqual(t["Network Stack Refresh"]?.symbol.0, "exclamationmark.circle")
        XCTAssertEqual(t["Periodic Maintenance"]?.results, ["- Periodic maintenance skipped (requires sudo)"])
    }

    func testAdminOffKeepsSpotlightFlagged() {
        let t = Dictionary(uniqueKeysWithValues: fold(false).tasks.map { ($0.name, $0) })
        XCTAssertEqual(t["Spotlight Optimization"]?.symbol.0, "exclamationmark.circle")
        XCTAssertEqual(t["Network Cache Refresh"]?.results, ["- Network cache refresh skipped (admin access required)"])
    }

    func testMoleWithAdminDefersNothing() {
        var log = OptimizeLog(adminTasksOn: true)
        for line in ["➤ DNS & Spotlight Check", "✓ DNS cache flushed", "✓ Spotlight index verified"] { log.consume(line) }
        XCTAssertFalse(log.moleSkippedAdmin)
        XCTAssertEqual(log.deferred, [])
        XCTAssertEqual(log.tasks.first?.results.count, 2)
    }

    @MainActor
    func testSummary() {
        XCTAssertEqual(OptimizeModel.summary(taskCount: 21, issues: 0, stopped: false, admin: .ran), "21 tasks ran.")
        XCTAssertEqual(OptimizeModel.summary(taskCount: 21, issues: 2, stopped: false, admin: .cancelled),
                       "21 tasks ran, 2 need a look. Admin tasks were skipped because they weren't authorized.")
        XCTAssertEqual(OptimizeModel.summary(taskCount: 5, issues: 0, stopped: true, admin: .notNeeded), "Stopped after 5 tasks.")
        XCTAssertTrue(OptimizeModel.summary(taskCount: 20, issues: 0, stopped: false, admin: .off).contains("Admin tasks are off"))
    }
}

final class AdminTests: XCTestCase {
    func testPamDetection() {
        XCTAssertTrue(Admin.pamEnablesTouchID("auth       sufficient     pam_tid.so\n"))
        XCTAssertTrue(Admin.pamEnablesTouchID("# comment\n\tauth\tsufficient\t/usr/lib/pam/pam_tid.so.2\n"))
        XCTAssertFalse(Admin.pamEnablesTouchID("#auth       sufficient     pam_tid.so\n"))
        XCTAssertFalse(Admin.pamEnablesTouchID("  # auth sufficient pam_tid.so"))
        XCTAssertFalse(Admin.pamEnablesTouchID("account    required       pam_tid.so"))
        XCTAssertFalse(Admin.pamEnablesTouchID("auth       include        sudo_local\nauth       required       pam_opendirectory.so"))
        XCTAssertFalse(Admin.pamEnablesTouchID("auth sufficient pam_tidy.so"))
        XCTAssertFalse(Admin.pamEnablesTouchID(""))
        // Apple's template ships the line commented out.
        XCTAssertFalse(Admin.pamEnablesTouchID("""
        # sudo_local: local config file which survives system update and is included for sudo
        # uncomment following line to enable Touch ID for sudo
        #auth       sufficient     pam_tid.so
        """))
    }

    func testTouchIDForSudoReadsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-pam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let off = dir.appendingPathComponent("off"), on = dir.appendingPathComponent("on")
        try "#auth sufficient pam_tid.so\n".write(to: off, atomically: true, encoding: .utf8)
        try "auth sufficient pam_tid.so\n".write(to: on, atomically: true, encoding: .utf8)
        XCTAssertFalse(Admin.touchIDForSudo(files: [off.path, dir.appendingPathComponent("missing").path]))
        XCTAssertTrue(Admin.touchIDForSudo(files: [off.path, on.path]))
    }

    func testDialogOutcomes() throws {
        XCTAssertEqual(try Admin.outcome(status: 0, signaled: false, stopped: true, stdout: "out\n", stderr: ""), "out\n")
        XCTAssertThrowsError(try Admin.outcome(status: 1, signaled: false, stopped: false, stdout: "",
                                               stderr: "0:142: execution error: User canceled. (-128)\n")) {
            XCTAssertEqual($0 as? Admin.Failure, .cancelled)
        }
        XCTAssertThrowsError(try Admin.outcome(status: 15, signaled: true, stopped: true, stdout: "", stderr: "")) {
            XCTAssertEqual($0 as? Admin.Failure, .cancelled)
        }
        XCTAssertThrowsError(try Admin.outcome(status: 9, signaled: true, stopped: false, stdout: "", stderr: "")) {
            guard case .failed(let why)? = $0 as? Admin.Failure else { return XCTFail() }
            XCTAssertTrue(why.contains("stopped"))
        }
        XCTAssertThrowsError(try Admin.outcome(status: 1, signaled: false, stopped: false, stdout: "", stderr: "  \n")) {
            XCTAssertEqual($0 as? Admin.Failure, .failed("osascript exited with status 1 and no message."))
        }
        XCTAssertThrowsError(try Admin.outcome(status: 1, signaled: false, stopped: false, stdout: "",
                                               stderr: "0:118: execution error: mdutil: Operation not permitted (1)\n")) {
            XCTAssertEqual($0 as? Admin.Failure, .failed("mdutil: Operation not permitted"))
        }
    }

    func testArgumentsKeepScriptOutOfAppleScriptSource() {
        let args = Admin.arguments(script: "echo \"hi\" & rm -rf /nope", prompt: "Why")
        XCTAssertEqual(Array(args.suffix(3)), ["--", "echo \"hi\" & rm -rf /nope", "Why"])
        XCTAssertFalse(args.dropLast(2).contains { $0.contains("rm -rf") })
        XCTAssertEqual(Admin.quote("it's"), #"'it'\''s'"#)
    }

    func testSudoOutcome() throws {
        XCTAssertEqual(try Admin.sudoOutcome(status: 0, lines: ["a", "b"]), "a\nb\n")
        XCTAssertThrowsError(try Admin.sudoOutcome(status: 1, lines: ["x", "sudo: a password is required", "y"])) {
            XCTAssertEqual($0 as? Admin.Failure, .failed("sudo: a password is required"))
        }
        XCTAssertThrowsError(try Admin.sudoOutcome(status: 2, lines: [])) {
            XCTAssertEqual($0 as? Admin.Failure, .failed("sudo exited with status 2 and no message."))
        }
        XCTAssertThrowsError(try Admin.sudoOutcome(status: nil, lines: []))
    }

    /// A stand-in sudo (a bash script) in a real pseudo-terminal.
    private func fakeSudo(_ body: String) throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-sudo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("sudo")
        try ("#!/bin/bash\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return (dir, file.path)
    }

    func testSudoRouteReturnsOutput() async throws {
        // Like sudo after Touch ID: runs `/bin/sh -c <script>` (argv after "--").
        let (dir, sudo) = try fakeSudo(#"shift; exec "$@""#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Admin.runWithSudo("echo 'bubble-result dns ok'", timeout: 10, sudo: sudo)
        XCTAssertEqual(out, "bubble-result dns ok\n")
    }

    func testSudoPasswordPromptMeansFallBack() async throws {
        // Touch ID cancelled: sudo asks for the password. Bubble types nothing and stops it.
        let (dir, sudo) = try fakeSudo(#"printf '%s' "$SUDO_PROMPT"; IFS= read -r p; echo "typed=${#p}" > "$(dirname "$0")/typed"; exit 1"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await Admin.runWithSudo("true", timeout: 10, sudo: sudo)
        XCTAssertNil(out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("typed").path))
    }

    func testSudoFailureIsReported() async throws {
        let (dir, sudo) = try fakeSudo(#"echo "sudo: something broke"; exit 1"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await Admin.runWithSudo("true", timeout: 10, sudo: sudo)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? Admin.Failure, .failed("sudo: something broke"))
        }
    }

    func testSudoTimeoutIsCancelled() async throws {
        let (dir, sudo) = try fakeSudo("sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await Admin.runWithSudo("true", timeout: 0.5, sudo: sudo)
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? Admin.Failure, .cancelled)
        }
    }
}

/// The Checkup fix that turns on Touch ID for sudo, run against temporary files.
final class TouchIDFixTests: XCTestCase {
    private func run(local: String?, template: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-pamfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let local { try local.write(to: dir.appendingPathComponent("sudo_local"), atomically: true, encoding: .utf8) }
        if let template { try template.write(to: dir.appendingPathComponent("sudo_local.template"), atomically: true, encoding: .utf8) }
        let script = DoctorModel.touchIDScript
            .replacingOccurrences(of: "/etc/pam.d/", with: dir.path + "/")
            .replacingOccurrences(of: "chown root:wheel \"$f.bubble\"\n", with: "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return try String(contentsOf: dir.appendingPathComponent("sudo_local"), encoding: .utf8)
    }

    private let template = """
    # sudo_local: local config file which survives system update and is included for sudo
    # uncomment following line to enable Touch ID for sudo
    #auth       sufficient     pam_tid.so

    """

    func testFromTemplate() throws {
        let out = try run(local: nil, template: template)
        XCTAssertTrue(Admin.pamEnablesTouchID(out))
        XCTAssertTrue(out.hasPrefix("# sudo_local"))
    }

    func testUncommentsExisting() throws {
        let out = try run(local: "auth optional /opt/homebrew/lib/pam/pam_reattach.so\n#auth sufficient pam_tid.so\n", template: template)
        XCTAssertEqual(out, "auth optional /opt/homebrew/lib/pam/pam_reattach.so\nauth sufficient pam_tid.so\n")
    }

    func testPrependsWhenMissing() throws {
        let out = try run(local: "auth optional pam_other.so\n", template: nil)
        XCTAssertEqual(out, "auth       sufficient     pam_tid.so\nauth optional pam_other.so\n")
    }

    func testFailureMessage() {
        let msg = DoctorModel.touchIDFailureMessage(Admin.Failure.failed("sh: /etc/pam.d/sudo_local.bubble: Operation not permitted"))
        XCTAssertTrue(msg.first?.contains("Full Disk Access") == true)
    }
}
