import XCTest
@testable import Bubble

/// Runs small bash scripts in a real pseudo-terminal to check that only
/// unterminated prompts are answered, and with what.
@MainActor
final class PTYResponderTests: XCTestCase {
    private func run(_ script: String, policy: PromptPolicy, args: [String] = ["-c"]) async -> (lines: [String], responder: PromptResponder) {
        let session = PTYSession("/bin/bash", args + [script])
        let responder = PromptResponder(reason: "test", policy: policy)
        var lines: [String] = []
        for await line in session.lines {
            if !responder.handle(line, session) { lines.append(line) }
        }
        return (lines, responder)
    }

    func testCompleteLineEndingInPasswordIsNotAPrompt() async {
        // A full output line that ends in "password:" must not be answered.
        let (lines, r) = await run(#"echo "Enter the admin password:"; echo done"#, policy: .optimize)
        XCTAssertTrue(lines.contains("Enter the admin password:"))
        XCTAssertTrue(lines.contains("done"))
        XCTAssertEqual(r.skippedPrompts, [])
    }

    func testSpaceCancelGetsSpace() async {
        let script = #"printf "◎ Detach now? Enter confirm / Space cancel: "; IFS= read -r -s -n1 k; printf '\n[%s]\n' "$k""#
        let (lines, r) = await run(script, policy: .optimize)
        XCTAssertEqual(r.skippedPrompts, ["◎ Detach now? Enter confirm / Space cancel:"])
        XCTAssertTrue(lines.contains("[ ]"), "\(lines)")
    }

    func testYesNoDeclined() async {
        let script = #"printf "Really? [y/N] "; read -r a; echo "answer=$a""#
        let (lines, r) = await run(script, policy: .optimize)
        XCTAssertEqual(r.skippedPrompts.count, 1)
        XCTAssertTrue(lines.contains("answer=n"), "\(lines)")
    }

    func testUninstallMismatchAnswersNo() async {
        let script = #"""
        echo "◎ Matched 2 app(s):"
        echo "1. Xcode  3.96GB  |  Last: 5d ago"
        echo "2. Claude Code URL Handler  4KB  |  Last: Today"
        echo
        printf "Proceed with uninstallation? [y/N] "; read -r a; echo "answer=$a"
        """#
        let (lines, r) = await run(script, policy: .uninstall(expectedApps: ["Xcode"]))
        XCTAssertTrue(lines.contains("answer=n"), "\(lines)")
        XCTAssertNotNil(r.matchError)
        XCTAssertFalse(r.proceedConfirmed)
    }

    func testUninstallExactMatchConfirms() async {
        let script = #"""
        echo "◎ Matched 1 app(s):"
        echo "1. Xcode  3.96GB  |  Last: 5d ago"
        echo
        printf "Proceed with uninstallation? [y/N] "; read -r a; echo "answer=$a"
        printf "➤ Remove 1 app, 3.96GB  Enter confirm, ESC cancel: "; IFS= read -r -s -n1 k; printf '\nkey=%q\n' "$k"
        """#
        let (lines, r) = await run(script, policy: .uninstall(expectedApps: ["Xcode"]))
        XCTAssertTrue(lines.contains("answer=y"), "\(lines)")
        // The tty turns CR into NL, which `read -n1` returns as "": Mole's Enter.
        XCTAssertTrue(lines.contains("key=''"), "\(lines)")
        XCTAssertNil(r.matchError)
        XCTAssertEqual(r.skippedPrompts, [])
    }

    func testPasswordOnlyFromPendingPromptInStrictPolicyIsDeclined() async {
        let script = #"printf "Password:"; read -r p; echo "len=${#p}""#
        let (lines, r) = await run(script, policy: .strict)
        XCTAssertTrue(lines.contains("len=0"), "\(lines)")
        XCTAssertEqual(r.skippedPrompts, ["Password:"])
    }
}

/// Opt-in: runs `mo uninstall --dry-run ode` (answered "n") through the PTY.
/// BUBBLE_LIVE_MOLE=1 swift test --filter LiveMoleTests
@MainActor
final class LiveMoleTests: XCTestCase {
    func testOdeSubstringMatchIsDeclined() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUBBLE_LIVE_MOLE"] == "1")
        let mo = try XCTUnwrap(Shell.mo)
        let session = PTYSession(mo, ["uninstall", "--dry-run", "ode"])
        let responder = PromptResponder(reason: "test", policy: .uninstall(expectedApps: ["Xcode"]))
        var lines: [String] = []
        for await line in session.lines {
            _ = responder.handle(line, session)
            lines.append(line)
        }
        XCTAssertNotNil(responder.matchError, "\(lines)")
        XCTAssertFalse(responder.proceedConfirmed)
        XCTAssertTrue(lines.contains { $0.contains("Aborted") }, "\(lines)")
    }
}
