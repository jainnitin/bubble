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

final class AppLeftoverSafetyTests: XCTestCase {
    func testBundleIdBoundary() {
        let chrome = "com.google.Chrome"
        XCTAssertTrue(AppLeftovers.entryMatches("com.google.Chrome", bundleId: chrome))
        XCTAssertTrue(AppLeftovers.entryMatches("com.google.Chrome.plist", bundleId: chrome))
        XCTAssertTrue(AppLeftovers.entryMatches("com.google.Chrome.helper", bundleId: chrome))
        XCTAssertFalse(AppLeftovers.entryMatches("com.google.ChromeBeta", bundleId: chrome))
        XCTAssertFalse(AppLeftovers.entryMatches("com.google", bundleId: chrome))
        XCTAssertFalse(AppLeftovers.entryMatches("xcom.google.Chrome", bundleId: chrome))
        // Canary's files are claimed by Canary when it's installed.
        XCTAssertTrue(AppLeftovers.claimedByOther("com.google.Chrome.canary.plist", bundleId: chrome,
                                                  others: ["com.google.Chrome.canary"], group: false))
        XCTAssertFalse(AppLeftovers.claimedByOther("com.google.Chrome.plist", bundleId: chrome,
                                                   others: ["com.google.Chrome.canary"], group: false))
        // Uninstalling Canary doesn't defer to Chrome's shorter id.
        XCTAssertFalse(AppLeftovers.claimedByOther("com.google.Chrome.canary", bundleId: "com.google.Chrome.canary",
                                                   others: [chrome], group: false))
        // Group containers.
        XCTAssertTrue(AppLeftovers.groupContainerMatches("EQHXZ8M8AV.com.google.Chrome", bundleId: chrome))
        XCTAssertTrue(AppLeftovers.groupContainerMatches("group.com.google.Chrome.shared", bundleId: chrome))
        XCTAssertFalse(AppLeftovers.groupContainerMatches("group.com.google.ChromeX", bundleId: chrome))
        XCTAssertFalse(AppLeftovers.groupContainerMatches("EQHXZ8M8AV.group.com.google", bundleId: chrome))
        // Two-part ids only match exactly.
        XCTAssertTrue(AppLeftovers.entryMatches("com.foo.plist", bundleId: "com.foo"))
        XCTAssertFalse(AppLeftovers.entryMatches("com.foo.bar", bundleId: "com.foo"))
    }

    func testMalformedBundleIdsNeverMatch() {
        for bad in ["", "foo", "com..foo", ".com.foo", "com.foo.", "com.foo/../x", "com.*", "com.foo bar", "com.f?o", "../..", "-com.foo"] {
            XCTAssertFalse(AppLeftovers.isValidBundleId(bad), bad)
            XCTAssertFalse(AppLeftovers.entryMatches(bad, bundleId: bad), bad)
        }
        XCTAssertTrue(AppLeftovers.isValidBundleId("com.example-1.App2"))
    }

    func testProtectedApps() {
        for (id, path) in [("com.apple.Safari", "/Applications/Safari.app"), ("com.apple.dt.Xcode", "/Applications/Xcode.app"),
                           ("com.jainnitin.Bubble", "/Applications/Bubble.app"), ("com.crowdstrike.falcon.App", "/Applications/Falcon.app"),
                           ("com.example.x", "/System/Applications/X.app"), ("COM.APPLE.finder", "/Applications/F.app")] {
            XCTAssertTrue(AppLeftovers.isProtected(bundleId: id, path: path), id)
        }
        XCTAssertFalse(AppLeftovers.isProtected(bundleId: "com.google.Chrome", path: "/Applications/Google Chrome.app"))
    }

    func testGenericNames() {
        for n in ["Notes", "Code", "App", "abc", "Helper", "..", ".hidden", "a/b", "1.0", "Google"] {
            XCTAssertFalse(AppLeftovers.isSpecificAppName(n), n)
        }
        XCTAssertTrue(AppLeftovers.isSpecificAppName("WhatsApp"))
    }

    func testLeftoverPathValidation() throws {
        let mac = try FakeMac()
        XCTAssertEqual(AppLeftovers.validateLeftover(mac.lib("Caches/com.x.y"), roots: mac.roots), .user)
        XCTAssertEqual(AppLeftovers.validateLeftover(mac.sys("LaunchDaemons/com.x.y.plist"), roots: mac.roots), .system)
        let refused = [
            mac.lib("Caches"), mac.lib("Preferences/ByHost"), mac.roots.library, mac.roots.home, "/", "/System/Library/x",
            "/usr/bin/x", mac.lib("Caches/a/b"), mac.lib("Caches/../Documents"), mac.lib("Caches/./x"), mac.lib("Caches/.."),
            mac.lib("Mail/com.x.y"), mac.base + "/home/Documents/x", "Caches/x", mac.lib("Caches//x"), mac.lib("Caches/x/"),
            "/Library/Caches/com.x.y", NSHomeDirectory() + "/Library/Caches/com.x.y",
        ]
        for p in refused { XCTAssertNil(AppLeftovers.validateLeftover(p, roots: mac.roots), p) }
    }

    func testSymlinkedLeftoverFolderIsRefused() throws {
        let mac = try FakeMac()
        // ~/Library/Logs pointing somewhere else: nothing under it is removable.
        try FileManager.default.removeItem(atPath: mac.lib("Logs"))
        try FileManager.default.createDirectory(atPath: mac.base + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: mac.lib("Logs"), withDestinationPath: mac.base + "/elsewhere")
        try mac.file(mac.base + "/elsewhere/com.x.y")
        XCTAssertNil(AppLeftovers.validateLeftover(mac.lib("Logs/com.x.y"), roots: mac.roots))
        // A symlinked entry inside a real folder is fine: it's trashed as a link.
        try FileManager.default.createSymbolicLink(atPath: mac.lib("Caches/com.x.y"), withDestinationPath: "/System")
        XCTAssertEqual(AppLeftovers.validateLeftover(mac.lib("Caches/com.x.y"), roots: mac.roots), .user)
    }

    func testAppBundleValidation() throws {
        let mac = try FakeMac()
        let apps = mac.roots.appFolders[0]
        try FileManager.default.createDirectory(atPath: apps + "/Utilities", withIntermediateDirectories: true)
        XCTAssertTrue(AppLeftovers.validateAppBundle(apps + "/Foo.app", roots: mac.roots))
        XCTAssertTrue(AppLeftovers.validateAppBundle(apps + "/Utilities/Foo.app", roots: mac.roots))
        XCTAssertTrue(AppLeftovers.validateAppBundle(mac.roots.appFolders[1] + "/Foo.app", roots: mac.roots))
        for bad in [apps, apps + "/Foo", apps + "/.app", apps + "/A/B/Foo.app", apps + "/Bar.app/Foo.app",
                    apps + "/../Foo.app", "/System/Applications/Foo.app", mac.lib("Caches/Foo.app")] {
            XCTAssertFalse(AppLeftovers.validateAppBundle(bad, roots: mac.roots), bad)
        }
        // A symlinked subfolder of Applications is refused.
        try FileManager.default.createSymbolicLink(atPath: apps + "/Linked", withDestinationPath: mac.base + "/home")
        XCTAssertFalse(AppLeftovers.validateAppBundle(apps + "/Linked/Foo.app", roots: mac.roots))
    }
}
