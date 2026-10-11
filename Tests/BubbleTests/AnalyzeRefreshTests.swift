import XCTest
@testable import Bubble

/// Refresh drops the Mole cache entries that would hand back sizes from before a change.
final class MoleAnalyzerCacheTests: XCTestCase {
    private var home: URL!
    private var dir: URL { MoleAnalyzerCache.directory(home: home.path) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-molecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func testHashMatchesXXH64() {
        // Reference values for xxHash64, seed 0 (covers the <4, <8, <32 and ≥32 byte paths).
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("".utf8)), 0xEF46_DB37_51D8_E999)
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("a".utf8)), 0xD24E_C4F1_A98C_6E5B)
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("abc".utf8)), 0x44BC_2CF5_AD77_0999)
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("message digest".utf8)), 0x066E_D728_FCEE_B3BE)
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("abcdefghijklmnopqrstuvwxyz".utf8)), 0xCFE1_F278_FA89_835C)
        XCTAssertEqual(MoleAnalyzerCache.xxh64(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8)),
                       0xE04A_477F_19EE_145D)
        // Mole writes the hash as unpadded hex.
        XCTAssertEqual(MoleAnalyzerCache.fileName(for: ""), "ef46db3751d8e999.cache")
    }

    func testAncestryKeepsPathsAsMoleSpellsThem() {
        XCTAssertEqual(MoleAnalyzerCache.ancestry(of: "/private/tmp/x/"), ["/private/tmp/x", "/private/tmp", "/private", "/"])
        XCTAssertEqual(MoleAnalyzerCache.ancestry(of: "/"), ["/"])
    }

    private func touchEntry(_ path: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(MoleAnalyzerCache.fileName(for: path)).path, contents: Data())
    }

    private func hasEntry(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(MoleAnalyzerCache.fileName(for: path)).path)
    }

    private func writeOverview(_ keys: [String]) throws {
        let obj = Dictionary(uniqueKeysWithValues: keys.map { ($0, ["size": 1, "schema_version": 7] as [String: Any]) })
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(MoleAnalyzerCache.overviewFile))
    }

    private func overviewKeys() throws -> Set<String> {
        let data = try Data(contentsOf: dir.appendingPathComponent(MoleAnalyzerCache.overviewFile))
        return Set(((try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys)
    }

    func testRefreshDropsFolderAncestorsAndEverythingInside() throws {
        let root = home.appendingPathComponent("tree").path
        for sub in ["a/deep/deeper", "a/skipped/x", "b"] {
            try FileManager.default.createDirectory(atPath: root + "/" + sub, withIntermediateDirectories: true)
        }
        let outside = home.appendingPathComponent("sibling").path
        let inside = [root + "/a", root + "/a/deep", root + "/a/deep/deeper", root + "/b"]
        for p in inside + [root, home.path, outside, root + "/a/skipped/x"] { touchEntry(p) }
        try writeOverview([home.path, root + "/a", outside, "/Applications"])

        MoleAnalyzerCache.invalidate(refreshing: root + "/", home: home.path, skip: { $0.hasSuffix("/skipped") })

        for p in inside + [root, home.path] { XCTAssertFalse(hasEntry(p), p) }
        XCTAssertTrue(hasEntry(outside), "a folder beside the refreshed one keeps its entry")
        XCTAssertTrue(hasEntry(root + "/a/skipped/x"), "skipped folders aren't listed")
        XCTAssertEqual(try overviewKeys(), [outside, "/Applications"])
    }

    func testTrashDropsOnlyAncestors() throws {
        let root = home.appendingPathComponent("tree").path
        for p in [root, root + "/a", root + "/a/gone", root + "/b", home.path] { touchEntry(p) }
        try writeOverview([root + "/a", root + "/b"])

        MoleAnalyzerCache.invalidate(trashed: root + "/a/gone", home: home.path)

        for p in [root, root + "/a", root + "/a/gone", home.path] { XCTAssertFalse(hasEntry(p), p) }
        XCTAssertTrue(hasEntry(root + "/b"), "untouched siblings stay cached")
        XCTAssertEqual(try overviewKeys(), [root + "/b"])
    }

    func testRefreshingTheOverviewDropsEverything() {
        touchEntry("/Users/me")
        MoleAnalyzerCache.invalidate(refreshing: nil, home: home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}

/// Opt-in: a real `mo analyze` scan through AnalyzeModel. Deletes a file deep inside a
/// folder Mole caches (≥ 10 MB), then checks Refresh reports the new size.
/// BUBBLE_LIVE_MOLE=1 swift test --filter LiveAnalyzeRefreshTests
@MainActor
final class LiveAnalyzeRefreshTests: XCTestCase {
    private func settle(_ model: AnalyzeModel) async throws {
        for _ in 0..<1200 where model.scanning != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.scanning, "scan didn't finish")
    }

    func testRefreshShowsFileDeletedOutsideBubble() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUBBLE_LIVE_MOLE"] == "1")
        // Resolved, as Mole reports it: /var is a symlink to /private/var.
        let tmp = URL(fileURLWithPath: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        let root = tmp.appendingPathComponent("bubble-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let big = deep.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 12_000_000).write(to: big)
        try Data(repeating: 7, count: 1000).write(to: root.appendingPathComponent("sub/small"))

        let model = AnalyzeModel()
        model.open(root.path, title: "Test", push: false)
        try await settle(model)
        XCTAssertGreaterThanOrEqual(model.current?.total ?? 0, 12_000_000)
        let subEntry = MoleAnalyzerCache.directory().appendingPathComponent(MoleAnalyzerCache.fileName(for: root.path + "/sub")).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: subEntry), "Mole's cache file name doesn't match ours")

        // Deleted outside Bubble: only sub/deep's modification time changes, so Mole's
        // entry for sub still looks current. A plain scan used to report the old size.
        try FileManager.default.removeItem(at: big)
        let plain = AnalyzeNavigator.parse(await Shell.moJSON(["analyze", "--json", root.path]), overview: false)
        print("mo analyze without invalidation reports \(plain.entries.reduce(0) { $0 + $1.size }) bytes")

        model.rescan()
        try await settle(model)
        XCTAssertEqual(model.current?.path, root.path)
        XCTAssertLessThan(model.current?.total ?? .infinity, 1_000_000, "Refresh still shows the deleted file")
    }
}
