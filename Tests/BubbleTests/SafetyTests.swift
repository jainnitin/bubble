import XCTest
@testable import Bubble

final class TrashGuardTests: XCTestCase {
    let home = "/Users/tester"

    func protected(_ p: String) -> Bool { Safety.isProtectedFromTrash(path: p, home: home) }

    func testRootAndSystemFolders() {
        for p in ["/", "/Applications", "/Library", "/System", "/Users", "/usr", "/bin", "/sbin", "/opt",
                  "/private", "/Volumes", "/applications", "/Library/", "//System", "/usr/local", "/opt/homebrew",
                  "/Volumes/External", "/private/var", "/Users/someoneelse", "/Applications/Xcode.app"] {
            XCTAssertTrue(protected(p), p)
        }
    }

    func testHomeAndTopLevelHomeFolders() {
        for p in ["~", "~/", home, home + "/", "~/Library", "~/Documents", "~/Desktop", "~/Downloads",
                  home + "/Downloads", home + "/downloads", "~/Documents/..", "~/Library/./"] {
            XCTAssertTrue(protected(p), p)
        }
    }

    func testContentsAreAllowed() {
        for p in ["~/Downloads/big.dmg", "~/Library/Caches/com.foo", "~/Documents/old", "~/Desktop/x.png",
                  home + "/Movies", home + "/Projects/node_modules", "/Library/Caches/com.foo", "/usr/local/Cellar/x"] {
            XCTAssertFalse(protected(p), p)
        }
    }

    func testTraversalAndRelative() {
        XCTAssertTrue(protected("~/Downloads/../Library"))
        XCTAssertTrue(protected("relative/path"))
        XCTAssertTrue(protected(""))
        XCTAssertTrue(protected("/Library/Caches/.."))
    }

    func testShallowHomeAllowsChildren() {
        // "depth ≤ 2 under / except inside ~": with a shallow home its children are fine.
        XCTAssertFalse(Safety.isProtectedFromTrash(path: "/h/stuff", home: "/h"))
        XCTAssertTrue(Safety.isProtectedFromTrash(path: "/h", home: "/h"))
        XCTAssertTrue(Safety.isProtectedFromTrash(path: "/other/stuff", home: "/h"))
    }

    func testRealHomeSymlinkResolution() {
        // /tmp is a symlink to /private/tmp; both are top-level.
        XCTAssertTrue(Safety.isProtectedFromTrash(path: "/tmp"))
    }
}

final class UninstallMatchTests: XCTestCase {
    let ode = [
        "\u{1B}[2J\u{1B}[H◎ Matched 2 app(s):",
        "1. Xcode  3.96GB  |  Last: 5d ago",
        "2. Claude Code URL Handler  4KB  |  Last: Today",
        "",
        "Proceed with uninstallation? [y/N]",
    ].map(Shell.clean)

    func testParsesMatchedList() {
        XCTAssertEqual(Safety.parseMatchedApps(ode), ["Xcode", "Claude Code URL Handler"])
    }

    func testMismatchWhenSubstringMatchedExtraApps() {
        let err = Safety.matchMismatch(matched: Safety.parseMatchedApps(ode), expected: ["Xcode"])
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("Mole matched different apps than you selected"))
        XCTAssertTrue(err!.contains("Claude Code URL Handler"))
    }

    func testExactSetMatchesInAnyOrder() {
        XCTAssertNil(Safety.matchMismatch(matched: Safety.parseMatchedApps(ode), expected: ["Claude Code URL Handler", "Xcode"]))
    }

    func testFormatCharactersIgnored() {
        let lines = ["◎ Matched 1 app(s):", "1. \u{200E}WhatsApp  710.0MB  |  Last: 6d ago"]
        XCTAssertNil(Safety.matchMismatch(matched: Safety.parseMatchedApps(lines), expected: ["WhatsApp"]))
    }

    func testDuplicatesAreAMultiset() {
        let lines = ["◎ Matched 2 app(s):", "1. Foo  1MB  |  Last: Today", "2. Foo  2MB  |  Last: Today"]
        XCTAssertNotNil(Safety.matchMismatch(matched: Safety.parseMatchedApps(lines), expected: ["Foo"]))
        XCTAssertNil(Safety.matchMismatch(matched: Safety.parseMatchedApps(lines), expected: ["Foo", "Foo"]))
    }

    func testMissingOrTruncatedListIsAnError() {
        XCTAssertNil(Safety.parseMatchedApps(["Proceed with uninstallation? [y/N]"]))
        XCTAssertNil(Safety.parseMatchedApps(["◎ Matched 2 app(s):", "1. Xcode  3.96GB  |  Last: 5d ago"]))
        XCTAssertNotNil(Safety.matchMismatch(matched: nil, expected: ["Xcode"]))
    }

    func testLaterHeaderReplacesEarlier() {
        let lines = ["◎ Matched 1 app(s):", "1. A  1MB  |  Last: Today", "◎ Matched 1 app(s):", "1. B  1MB  |  Last: Today"]
        XCTAssertEqual(Safety.parseMatchedApps(lines), ["B"])
    }

    func testNameWithDoubleSpaceAndPipe() {
        XCTAssertEqual(Safety.matchedRowName("1. My | App  12KB  |  Last: Never", index: 1), "My | App")
    }

    func testMoleTerm() {
        XCTAssertEqual(Safety.moleUninstallTerm(forAppPath: "/Applications/Claude.app"), "Claude")
        XCTAssertEqual(Safety.moleUninstallTerm(forAppPath: "/Users/x/Applications/Claude Code URL Handler.app"), "Claude Code URL Handler")
        XCTAssertEqual(Safety.moleUninstallTerm(forAppPath: "/Applications/Foo.APP"), "Foo")
    }

    func testAmbiguousTerms() {
        let installed = [("Claude", "/Applications/Claude.app"), ("Claude Code URL Handler", "/Users/x/Applications/Claude Code URL Handler.app"),
                         ("Foo", "/Applications/Foo.app"), ("Foo", "/Users/x/Applications/Foo.app"), ("Bar Pro", "/Applications/bar.app")]
        XCTAssertEqual(Safety.ambiguousTerms(selected: [("Claude", "/Applications/Claude.app")], installed: installed), [])
        XCTAssertEqual(Safety.ambiguousTerms(selected: [("Foo", "/Applications/Foo.app")], installed: installed), ["Foo"])
        XCTAssertEqual(Safety.ambiguousTerms(selected: [("", "/Applications/.app")], installed: installed), [""])
        // Another app's display name equal to our folder name.
        let more = installed + [("bar", "/Applications/Other.app")]
        XCTAssertEqual(Safety.ambiguousTerms(selected: [("bar", "/Applications/bar.app")], installed: more), ["bar"])
    }
}

final class PromptPolicyTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(PromptResponder.classify("Password:"), .sudoPassword)
        XCTAssertEqual(PromptResponder.classify("[sudo] password for nitin:"), .sudoPassword)
        XCTAssertEqual(PromptResponder.classify("Enter your keychain password:"), .unknown)
        XCTAssertEqual(PromptResponder.classify("Old password:"), .unknown)
        XCTAssertEqual(PromptResponder.classify("Proceed with uninstallation? [y/N]"), .uninstallProceed)
        XCTAssertEqual(PromptResponder.classify("➤ Remove 2 apps, 1.20GB  Enter confirm, ESC cancel:"), .uninstallRemoveConfirm)
        XCTAssertEqual(PromptResponder.classify("➤ Remove 1 app, 4KB [Running]  Enter confirm, ESC cancel:"), .uninstallRemoveConfirm)
        XCTAssertEqual(PromptResponder.classify("➤ Remove 1 app  Enter confirm, ESC cancel:"), .uninstallRemoveConfirm)
        XCTAssertEqual(PromptResponder.classify("◎ Detach now? Enter confirm / Space cancel:"), .keyChoice(cancel: " "))
        XCTAssertEqual(PromptResponder.classify("Something else? Enter confirm, ESC cancel:"), .keyChoice(cancel: "q"))
        XCTAssertEqual(PromptResponder.classify("Delete everything? [y/N]"), .yesNo)
        XCTAssertEqual(PromptResponder.classify("Continue? [Y/n]"), .yesNo)
        XCTAssertEqual(PromptResponder.classify("Name:"), .unknown)
    }

    func testOptimizeOnlyAnswersSudo() {
        let d = { (k: PromptKind) in PromptResponder.decide(kind: k, policy: .optimize, matchOK: true, proceedConfirmed: true) }
        XCTAssertEqual(d(.sudoPassword), .skipAdmin)
        XCTAssertEqual(d(PromptResponder.classify("◎ Detach now? Enter confirm / Space cancel:")), .decline(" "))
        XCTAssertEqual(d(.uninstallProceed), .decline("n\n"))
        XCTAssertEqual(d(.uninstallRemoveConfirm), .decline("q"))
        XCTAssertEqual(d(.yesNo), .decline("n\n"))
        XCTAssertEqual(d(.unknown), .declineUnknown)
    }

    func testUninstallNeedsMatchBeforeConfirming() {
        let policy = PromptPolicy.uninstall(expectedApps: ["Xcode"])
        XCTAssertEqual(PromptResponder.decide(kind: .uninstallProceed, policy: policy, matchOK: false, proceedConfirmed: false), .decline("n\n"))
        XCTAssertEqual(PromptResponder.decide(kind: .uninstallProceed, policy: policy, matchOK: true, proceedConfirmed: false), .answer("y\n"))
        XCTAssertEqual(PromptResponder.decide(kind: .uninstallRemoveConfirm, policy: policy, matchOK: false, proceedConfirmed: false), .decline("q"))
        XCTAssertEqual(PromptResponder.decide(kind: .uninstallRemoveConfirm, policy: policy, matchOK: false, proceedConfirmed: true), .answer("\r"))
        XCTAssertEqual(PromptResponder.decide(kind: .sudoPassword, policy: policy, matchOK: false, proceedConfirmed: false), .decline("\n"))
        XCTAssertEqual(PromptResponder.decide(kind: .sudoPassword, policy: policy, matchOK: false, proceedConfirmed: true), .password)
        XCTAssertEqual(PromptResponder.decide(kind: .keyChoice(cancel: " "), policy: policy, matchOK: true, proceedConfirmed: true), .decline(" "))
    }

    func testStrictAndDetection() {
        XCTAssertEqual(PromptPolicy.detect(arguments: ["optimize"]), .optimize)
        XCTAssertEqual(PromptPolicy.detect(arguments: ["uninstall", "Xcode"]), .uninstall(expectedApps: nil))
        XCTAssertEqual(PromptPolicy.detect(arguments: ["clean"]), .strict)
        XCTAssertEqual(PromptResponder.decide(kind: .sudoPassword, policy: .strict, matchOK: true, proceedConfirmed: true), .decline("\n"))
    }
}
