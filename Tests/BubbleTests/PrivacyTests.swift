import XCTest
@testable import Bubble

final class SkipLineTests: XCTestCase {
    func testTrashNeedsFullDiskAccess() throws {
        let s = try XCTUnwrap(CleanModel.parseSkipLine("  ◎ Trash · skipped, grant Full Disk Access to your terminal"))
        XCTAssertEqual(s.name, "Trash")
        XCTAssertTrue(s.needsFullDiskAccess)
        XCTAssertEqual(s.reason, "Protected by macOS")
    }

    func testOtherReasons() throws {
        let a = try XCTUnwrap(CleanModel.parseSkipLine("◎ Xcode DerivedData · skipped (process state unknown)"))
        XCTAssertEqual(a.name, "Xcode DerivedData")
        XCTAssertEqual(a.reason, "Process state unknown")
        XCTAssertFalse(a.needsFullDiskAccess)

        let b = try XCTUnwrap(CleanModel.parseSkipLine("! Time Machine cleanup · skipped (backup in progress)"))
        XCTAssertEqual(b.name, "Time Machine cleanup")

        let c = try XCTUnwrap(CleanModel.parseSkipLine("◎ Project caches · skipped 2 slow/incomplete roots"))
        XCTAssertEqual(c.name, "Project caches")
        XCTAssertEqual(c.reason, "2 slow/incomplete roots")

        let d = try XCTUnwrap(CleanModel.parseSkipLine("◎ Mail Downloads · skipped (sizing unavailable)"))
        XCTAssertEqual(d.name, "Mail Downloads")
    }

    func testIgnoresWhitelistAndOtherLines() {
        XCTAssertNil(CleanModel.parseSkipLine("✓ Homebrew · skipped (whitelist)"))
        XCTAssertNil(CleanModel.parseSkipLine("→ User app cache · 4 items, 102.6MB dry"))
        XCTAssertNil(CleanModel.parseSkipLine("⊙ Build artifacts · 3 dirs, 1.47GB · mo purge"))
        XCTAssertNil(CleanModel.parseSkipLine("➤ User essentials"))
        XCTAssertNil(CleanModel.parseSkipLine(""))
        // "scan skipped" is a hint, not a "Name · skipped" line.
        XCTAssertNil(CleanModel.parseSkipLine("⚠ Build artifacts · scan skipped · mo purge"))
    }

    func testSummary() {
        let p = { (n: String) in SkippedPlace(name: n, reason: "", needsFullDiskAccess: true) }
        XCTAssertEqual(CleanView.skippedSummary([p("Trash")]), "Trash")
        XCTAssertEqual(CleanView.skippedSummary([p("Trash"), p("Mail")]), "Trash and Mail")
        XCTAssertEqual(CleanView.skippedSummary([p("Trash"), p("Mail"), p("A"), p("B")]), "Trash, Mail and 2 more")
    }
}

final class PrivacyGuardTests: XCTestCase {
    let home = "/Users/x"

    func testProfileDeniesProtectedPlaces() throws {
        let p = try XCTUnwrap(PrivacyGuard.profile(home: home))
        for sub in ["Desktop", "Documents", "Downloads", ".Trash", "Library/Mail", "Library/Messages", "Library/Safari",
                    "Library/Mobile Documents", "Library/CloudStorage", "Music"] {
            XCTAssertTrue(p.contains("(subpath \"/Users/x/\(sub)\")"), sub)
        }
        XCTAssertTrue(p.contains("(subpath \"/Volumes\")"))
        XCTAssertTrue(p.contains("(deny appleevent-send)"))
        XCTAssertTrue(p.contains("Containers|Group Containers"))
        XCTAssertTrue(p.contains("\\.photoslibrary"))
    }

    func testAllowedFoldersAreLeftOut() throws {
        let p = try XCTUnwrap(PrivacyGuard.profile(home: home, allowing: [.downloads]))
        XCTAssertFalse(p.contains("/Users/x/Downloads"))
        XCTAssertTrue(p.contains("/Users/x/Desktop"))
    }

    func testUnsafeHomeGivesNoProfile() {
        XCTAssertNil(PrivacyGuard.profile(home: "relative"))
        XCTAssertNil(PrivacyGuard.profile(home: "/Users/a\"b"))
        XCTAssertNil(PrivacyGuard.profile(home: "/Users/a\\b"))
    }

    func testRegexEscape() {
        XCTAssertEqual(PrivacyGuard.regexEscape("/Users/j.doe+1"), "/Users/j\\.doe\\+1")
    }

    func testCommandWrapping() {
        XCTAssertEqual(PrivacyGuard.command("/opt/homebrew/bin/mo", ["clean"], profile: nil).exe, "/opt/homebrew/bin/mo")
        let w = PrivacyGuard.command("/opt/homebrew/bin/mo", ["clean", "--dry-run"], profile: "(version 1)")
        XCTAssertEqual(w.exe, "/usr/bin/sandbox-exec")
        XCTAssertEqual(w.args, ["-p", "(version 1)", "/opt/homebrew/bin/mo", "clean", "--dry-run"])
    }

    func testIsLocked() {
        XCTAssertTrue(PrivacyGuard.isLocked("/Users/x/Desktop", home: home, allowing: []))
        XCTAssertTrue(PrivacyGuard.isLocked("/Users/x/Desktop/a", home: home, allowing: []))
        XCTAssertFalse(PrivacyGuard.isLocked("/Users/x/Desktop", home: home, allowing: [.desktop]))
        XCTAssertFalse(PrivacyGuard.isLocked("/Users/x/DesktopStuff", home: home, allowing: []))
        XCTAssertTrue(PrivacyGuard.isLocked("/Users/x/Library/Containers", home: home, allowing: []))
        XCTAssertTrue(PrivacyGuard.isLocked("/Users/x/Pictures/Photos Library.photoslibrary", home: home, allowing: []))
        XCTAssertFalse(PrivacyGuard.isLocked("/Users/x/Library/Caches", home: home, allowing: []))
        XCTAssertFalse(PrivacyGuard.isLocked("/Users/x/Pictures", home: home, allowing: []))
    }

    func testAnalyzeLockedLists() {
        let all: (String) -> Bool = { _ in true }
        let atHome = PrivacyGuard.analyzeLocked(in: home, home: home, allowing: [.documents], exists: all).map(\.name)
        XCTAssertEqual(atHome, ["Desktop", "Downloads", "Music", "Trash"])
        let lib = PrivacyGuard.analyzeLocked(in: home + "/Library", home: home, allowing: [], exists: { $0.hasSuffix("/Mail") })
        XCTAssertEqual(lib.map(\.name), ["Mail"])
        XCTAssertEqual(PrivacyGuard.analyzeLocked(in: nil, home: home, exists: all).count, 1)
        XCTAssertTrue(PrivacyGuard.analyzeLocked(in: "/Applications", home: home, exists: all).isEmpty)
    }

    func testCleanSkippedNamesUserFolders() {
        let names = PrivacyGuard.cleanSkipped(allowing: []).map(\.name)
        XCTAssertTrue(names.contains("Trash"))
        XCTAssertTrue(names.contains("Desktop, Documents, and Downloads") || names.contains("Desktop, Documents and Downloads"))
        let none = PrivacyGuard.cleanSkipped(allowing: Set(PrivacyGuard.Folder.allCases)).map(\.name)
        XCTAssertFalse(none.contains { $0.contains("Desktop") })
    }

    /// The generated profile is valid SBPL and does what it says: run a real
    /// `sandbox-exec` against a fake home folder.
    func testProfileWorksWithSandboxExec() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: PrivacyGuard.sandboxExec))
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bubble-privacy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        for d in ["Desktop", "Library/Caches", "Library/Containers/com.example.app/Data", "Pictures/P.photoslibrary"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        // The sandbox matches real paths (/private/var/…); URL.resolvingSymlinksInPath drops /private.
        let real = try XCTUnwrap(realpath(tmp.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        let profile = try XCTUnwrap(PrivacyGuard.profile(home: root.path))

        func canList(_ sub: String) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: PrivacyGuard.sandboxExec)
            p.arguments = ["-p", profile, "/bin/ls", root.appendingPathComponent(sub).path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        XCTAssertTrue(canList("Library/Caches"))
        XCTAssertTrue(canList("Library/Containers"), "the list of containers stays visible")
        XCTAssertTrue(canList("Pictures"))
        XCTAssertFalse(canList("Desktop"))
        XCTAssertFalse(canList("Library/Containers/com.example.app"))
        XCTAssertFalse(canList("Library/Containers/com.example.app/Data"))
        XCTAssertFalse(canList("Pictures/P.photoslibrary"))
    }
}
