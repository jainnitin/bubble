import XCTest
@testable import Bubble

/// The temporary optimize whitelist used when Bubble has no Full Disk Access.
final class OptimizeWhitelistTests: XCTestCase {
    private var paths: OptimizeWhitelist.Paths!
    private let ids = OptimizeWhitelist.needsFullDiskAccess.map(\.id)

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-optwl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = OptimizeWhitelist.Paths(dir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.dir)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testIdsMatchMoleCatalog() {
        XCTAssertEqual(ids, ["sqlite_vacuum", "shared_file_list_repair", "notification_cleanup", "coreduet_cleanup"])
    }

    func testNoFileIsCreatedThenRemoved() throws {
        let added = try OptimizeWhitelist.apply(ids, paths: paths)
        XCTAssertEqual(added, ids)
        XCTAssertEqual(read(paths.file), OptimizeWhitelist.marker + ids.joined(separator: "\n") + "\n")
        OptimizeWhitelist.restoreIfNeeded(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backup.path))
    }

    func testExistingFileRestoredByteForByte() throws {
        let original = "# Mole Optimization Whitelist\nlogin_items_audit\n  sqlite_vacuum  \ndisk_verify" // no final newline
        try original.write(to: paths.file, atomically: true, encoding: .utf8)
        let added = try OptimizeWhitelist.apply(ids, paths: paths)
        XCTAssertEqual(added, ["shared_file_list_repair", "notification_cleanup", "coreduet_cleanup"], "already listed ids stay as they are")
        XCTAssertTrue(read(paths.file)!.hasPrefix(original + "\n" + OptimizeWhitelist.marker))
        OptimizeWhitelist.restoreIfNeeded(paths: paths)
        XCTAssertEqual(try Data(contentsOf: paths.file), Data(original.utf8))
    }

    func testNothingToAddLeavesFileAlone() throws {
        let original = ids.joined(separator: "\n") + "\n"
        try original.write(to: paths.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try OptimizeWhitelist.apply(ids, paths: paths), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backup.path))
        XCTAssertEqual(read(paths.file), original)
    }

    func testLegacyPatternsCarriedOverAndLegacyUntouched() throws {
        try "disk_verify\n".write(to: paths.legacy, atomically: true, encoding: .utf8)
        _ = try OptimizeWhitelist.apply(ids, paths: paths)
        XCTAssertTrue(read(paths.file)!.hasPrefix("disk_verify\n" + OptimizeWhitelist.marker))
        OptimizeWhitelist.restoreIfNeeded(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.file.path))
        XCTAssertEqual(read(paths.legacy), "disk_verify\n")
    }

    func testUserEditDuringRunIsKept() throws {
        _ = try OptimizeWhitelist.apply(ids, paths: paths)
        try "user_changed\n".write(to: paths.file, atomically: true, encoding: .utf8)
        OptimizeWhitelist.restoreIfNeeded(paths: paths)
        XCTAssertEqual(read(paths.file), "user_changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.discarded.path))
    }

    func testStaleBackupRestoredBeforeNextApply() throws {
        try "mine\n".write(to: paths.file, atomically: true, encoding: .utf8)
        _ = try OptimizeWhitelist.apply(ids, paths: paths)
        // Bubble "quit" here; the next apply first restores, then writes afresh.
        _ = try OptimizeWhitelist.apply(ids, paths: paths)
        XCTAssertEqual(read(paths.file)!.components(separatedBy: OptimizeWhitelist.marker).count, 2, "marker written once")
        OptimizeWhitelist.restoreIfNeeded(paths: paths)
        XCTAssertEqual(read(paths.file), "mine\n")
    }

    func testUnreadableFileIsNeverRewritten() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: paths.file)
        XCTAssertThrowsError(try OptimizeWhitelist.apply(ids, paths: paths))
        XCTAssertEqual(try Data(contentsOf: paths.file), Data([0xFF, 0xFE, 0x00]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backup.path))
    }

    @MainActor
    func testBeginEndNestAndSkipWithFullDiskAccess() throws {
        XCTAssertEqual(OptimizeWhitelist.begin(fullDiskAccess: true, paths: paths), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.file.path))
        OptimizeWhitelist.end(paths: paths)

        let names = OptimizeWhitelist.begin(fullDiskAccess: false, paths: paths)
        XCTAssertEqual(names, ["Database Optimization", "Shared File Lists", "Notifications", "Usage Data"])
        // A dry-run plan overlapping the run shares the same temporary file.
        XCTAssertEqual(OptimizeWhitelist.begin(fullDiskAccess: false, paths: paths), names)
        OptimizeWhitelist.end(paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.file.path))
        OptimizeWhitelist.restoreStale(paths: paths)  // a run holds it: no-op
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.file.path))
        OptimizeWhitelist.end(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.file.path))
    }

    func testLogShowsFullDiskAccessSkips() {
        var log = OptimizeLog(adminTasksOn: true, skippedForFullDiskAccess: ["Database Optimization"])
        for line in ["➤ Database Optimization", "✓ Skipped (whitelisted): Database Optimization",
                     "➤ Disk Health", "✓ Skipped (whitelisted): Disk Health"] { log.consume(line) }
        XCTAssertEqual(log.tasks[0].results, [OptimizeLog.fullDiskAccessSkip])
        XCTAssertEqual(log.tasks[0].symbol.0, "minus.circle")
        XCTAssertEqual(log.tasks[1].results, ["✓ Skipped (whitelisted): Disk Health"], "the user's own whitelist reads as Mole says")
    }
}

/// Opt-in: a real `mo optimize --dry-run` with the temporary whitelist in ~/.config/mole.
/// BUBBLE_LIVE_MOLE=1 swift test --filter LiveOptimizeWhitelistTests
@MainActor
final class LiveOptimizeWhitelistTests: XCTestCase {
    func testDryRunSkipsProtectedTasks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUBBLE_LIVE_MOLE"] == "1")
        let before = try? Data(contentsOf: OptimizeWhitelist.Paths.standard.file)
        let names = OptimizeWhitelist.begin(fullDiskAccess: false)
        let text = await Shell.moText(["optimize", "--dry-run"])
        OptimizeWhitelist.end()
        XCTAssertEqual(try? Data(contentsOf: OptimizeWhitelist.Paths.standard.file), before)
        var log = OptimizeLog(adminTasksOn: true, skippedForFullDiskAccess: names)
        for line in text.split(separator: "\n") { log.consume(line.trimmingCharacters(in: .whitespaces)) }
        for name in names {
            XCTAssertEqual(log.tasks.first { $0.name == name }?.results, [OptimizeLog.fullDiskAccessSkip], text)
        }
    }
}

/// The file handling Clean's and Optimize's temporary whitelists share.
final class TemporaryWhitelistTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-tmpwl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func list(version: Int) -> TemporaryWhitelist {
        TemporaryWhitelist(file: dir.appendingPathComponent("whitelist"), backup: dir.appendingPathComponent("whitelist.bubble-backup"),
                           discarded: dir.appendingPathComponent("whitelist.bubble-discarded"), version: version)
    }

    /// A backup as the code before the shared helper wrote it.
    private func earlierBackup(version: Int, original: String?, written: String) throws -> Data {
        var obj: [String: Any] = ["version": version, "written": written]
        if let original { obj["original"] = original }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    func testStaleBackupsFromEarlierVersionsRestore() throws {
        // Clean wrote version 2, Optimize version 1; each list reads only its own.
        for version in [1, 2] {
            let l = list(version: version)
            try "/mine\n# bubble…\n/x\n".write(to: l.file, atomically: true, encoding: .utf8)
            try earlierBackup(version: version, original: "/mine\n", written: "/mine\n# bubble…\n/x\n").write(to: l.backup)
            l.restoreIfNeeded()
            XCTAssertEqual(try String(contentsOf: l.file, encoding: .utf8), "/mine\n", "version \(version)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: l.backup.path))
        }
        XCTAssertEqual(list(version: 2).restoreAction(backupData: try earlierBackup(version: 1, original: nil, written: "x"), current: "x"),
                       .leaveAlone, "another list's backup is never trusted")
        XCTAssertEqual(Whitelist.temporary.version, 2)
        XCTAssertEqual(OptimizeWhitelist.Paths(dir: dir).temporary.version, 1)
    }

    func testWriteThenRestoreRoundTrips() throws {
        let l = list(version: 2)
        try l.write("/a\n/b\n", original: nil)
        XCTAssertEqual(l.decodeBackup(try Data(contentsOf: l.backup))?.written, "/a\n/b\n")
        l.restoreIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.file.path))
    }

    func testRefusesWhatItShouldNotRewrite() throws {
        let l = list(version: 1)
        let real = dir.appendingPathComponent("real")
        try "x\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: l.file, withDestinationURL: real)
        XCTAssertThrowsError(try l.readOriginal()) { XCTAssertEqual($0 as? TemporaryWhitelist.Unreadable, .init(reason: "it's a symlink")) }
        try FileManager.default.removeItem(at: real)
        XCTAssertThrowsError(try l.readOriginal(), "a dangling symlink isn't 'no file'")
        try FileManager.default.removeItem(at: l.file)
        XCTAssertNil(try l.readOriginal())
        try FileManager.default.createDirectory(at: l.file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try l.readOriginal())
    }
}
