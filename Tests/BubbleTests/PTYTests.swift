import XCTest
@testable import Bubble

/// Runs small bash scripts in a real pseudo-terminal to check that only
/// unterminated prompts are answered, and with what.
@MainActor
final class PTYResponderTests: XCTestCase {
    private func run(_ script: String, args: [String] = ["-c"]) async -> (lines: [String], responder: PromptResponder) {
        let session = PTYSession("/bin/bash", args + [script])
        let responder = PromptResponder()
        var lines: [String] = []
        for await line in session.lines {
            if !responder.handle(line, session) { lines.append(line) }
        }
        return (lines, responder)
    }

    func testCompleteLineEndingInPasswordIsNotAPrompt() async {
        // A full output line that ends in "password:" must not be answered.
        let (lines, r) = await run(#"echo "Enter the admin password:"; echo done"#)
        XCTAssertTrue(lines.contains("Enter the admin password:"))
        XCTAssertTrue(lines.contains("done"))
        XCTAssertEqual(r.skippedPrompts, [])
    }

    func testSpaceCancelGetsSpace() async {
        let script = #"printf "◎ Detach now? Enter confirm / Space cancel: "; IFS= read -r -s -n1 k; printf '\n[%s]\n' "$k""#
        let (lines, r) = await run(script)
        XCTAssertEqual(r.skippedPrompts, ["◎ Detach now? Enter confirm / Space cancel:"])
        XCTAssertTrue(lines.contains("[ ]"), "\(lines)")
    }

    func testYesNoDeclined() async {
        let script = #"printf "Really? [y/N] "; read -r a; echo "answer=$a""#
        let (lines, r) = await run(script)
        XCTAssertEqual(r.skippedPrompts.count, 1)
        XCTAssertTrue(lines.contains("answer=n"), "\(lines)")
    }

    func testUnknownPromptIsDeclined() async {
        let script = #"printf "Name:"; read -r -n1 a; echo; echo "answer=$a""#
        let (lines, r) = await run(script)
        XCTAssertEqual(r.skippedPrompts, ["Name:"])
        XCTAssertTrue(lines.contains("answer=n"), "\(lines)")
    }

    func testLookalikePasswordPromptIsDeclinedWithEmptyLine() async {
        let script = #"printf "Password:"; read -r p; echo "len=${#p}""#
        let (lines, r) = await run(script)
        XCTAssertTrue(lines.contains("len=0"), "\(lines)")
        XCTAssertEqual(r.skippedPrompts, ["Password:"])
    }
}
