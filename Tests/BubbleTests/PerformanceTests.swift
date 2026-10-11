import XCTest
@testable import Bubble

/// The rules that keep Bubble from doing work nobody sees: sampling pace, cached
/// history and lists, and checks moved off the main thread.
final class StatusPaceTests: XCTestCase {
    private func pace(main: Bool = false, status: Bool = false, panel: Bool = false,
                      any: Bool = false, numbers: Bool = false) -> StatusModel.Pace {
        StatusModel.pace(mainWindowOnScreen: main, statusTabSelected: status, panelOpen: panel,
                         anyWindowOnScreen: any, menuBarShowsNumbers: numbers)
    }

    func testLiveOnlyWhileStatusOrThePanelShows() {
        XCTAssertEqual(pace(main: true, status: true, any: true), .live)
        XCTAssertEqual(pace(panel: true, any: true), .live)
        XCTAssertEqual(pace(main: true, panel: true, any: true), .live)
        // Another section on screen: Mole every 5 seconds (Checkup reads the health score).
        XCTAssertEqual(pace(main: true, status: false, any: true), .background)
        // Status selected but the window is hidden or covered.
        XCTAssertEqual(pace(main: false, status: true), .off)
        XCTAssertEqual(pace(main: false, status: true, numbers: true), .background)
        // Only Settings is open.
        XCTAssertEqual(pace(status: true, any: true), .background)
    }

    func testNothingRunsWithNoWindowAndAnIconOnlyMenuBar() {
        XCTAssertEqual(pace(), .off)
        XCTAssertEqual(pace(numbers: true), .background)
    }
}

final class HistoryCacheTests: XCTestCase {
    func testStaleness() {
        let now = Date()
        XCTAssertTrue(HistoryTotals.isStale(readAt: nil, now: now, ttl: 60))
        XCTAssertFalse(HistoryTotals.isStale(readAt: now, now: now, ttl: 60))
        XCTAssertFalse(HistoryTotals.isStale(readAt: now.addingTimeInterval(-59), now: now, ttl: 60))
        XCTAssertTrue(HistoryTotals.isStale(readAt: now.addingTimeInterval(-60), now: now, ttl: 60))
        // A clock that moved backwards never keeps a read alive.
        XCTAssertTrue(HistoryTotals.isStale(readAt: now.addingTimeInterval(5), now: now, ttl: 60))
    }

    func testCachedMoleTotalsPlusLiveCountersMatchAFreshRead() {
        let data = Data(HistoryTotalsTests.fixture.utf8)
        let cached = HistoryTotals(json: data, optimizeRuns: 0, uninstalls: 0)
        XCTAssertEqual(cached.adding(optimizeRuns: 4, uninstalls: 2), HistoryTotals(json: data, optimizeRuns: 4, uninstalls: 2))
    }
}

@MainActor
final class UninstallVisibleCacheTests: XCTestCase {
    private func app(_ name: String, bytes: Double) -> AppInfo {
        AppInfo(name: name, bundleId: "com.example.\(name)", source: "App", uninstallName: "", path: "/Applications/\(name).app",
                bytes: bytes, version: "1", lastUsed: nil, added: nil, menuBarOnly: false)
    }

    func testRecomputesWhenAnyInputChanges() {
        let m = UninstallModel(checkFullDiskAccess: { false })
        m.apps = [app("Alpha", bytes: 1), app("Beta", bytes: 3), app("Gamma", bytes: 2)]
        XCTAssertEqual(m.visible.map(\.name), ["Beta", "Gamma", "Alpha"])
        XCTAssertEqual(m.visible.map(\.name), ["Beta", "Gamma", "Alpha"])
        // A size batch arrives.
        m.apps[0].bytes = 9
        XCTAssertEqual(m.visible.map(\.name), ["Alpha", "Beta", "Gamma"])
        m.setSort(.name)
        XCTAssertEqual(m.visible.map(\.name), ["Alpha", "Beta", "Gamma"])
        m.setSort(.name)
        XCTAssertEqual(m.visible.map(\.name), ["Gamma", "Beta", "Alpha"])
        m.search = "a"
        XCTAssertEqual(m.visible.map(\.name), ["Gamma", "Beta", "Alpha"])
        m.search = "mm"
        XCTAssertEqual(m.visible.map(\.name), ["Gamma"])
    }
}

final class ScanTimeInfoTests: XCTestCase {
    func testSparkleFeedIsReadAtScanTime() throws {
        let mac = try FakeMac()
        let path = try mac.app("Feedy", id: "com.example.feedy")
        let none = try mac.app("Plain", id: "com.example.plain")
        let empty = try mac.app("Blank", id: "com.example.blank")
        for (p, feed) in [(path, "https://example.com/appcast.xml"), (empty, "")] {
            (["CFBundleIdentifier": "x", "CFBundleShortVersionString": "1.0", "SUFeedURL": feed] as NSDictionary)
                .write(toFile: p + "/Contents/Info.plist", atomically: true)
        }
        let apps = mac.scan().apps
        let feedy = try XCTUnwrap(apps.first { $0.path == path })
        XCTAssertEqual(feedy.sparkleFeed, "https://example.com/appcast.xml")
        XCTAssertEqual(feedy.updateChannel, "Sparkle")
        XCTAssertNil(apps.first { $0.path == none }?.sparkleFeed)
        XCTAssertNil(apps.first { $0.path == empty }?.sparkleFeed)
        XCTAssertEqual(apps.first { $0.path == empty }?.updateChannel, "Website")
    }

    func testProtectedRowsOnlyShowWhatExistsAndIsntLocked() {
        let items = ["/a/file", "/a/missing", "/locked/thing", "/a/*.log", "FINDER_METADATA"]
        let found = ProtectedItemsModel.existingItems(items, isLocked: { $0.hasPrefix("/locked") },
                                                      fileExists: { ["/a/file", "/locked/thing", "/a/*.log"].contains($0) })
        XCTAssertEqual(found, ["/a/file"])
    }
}

final class LaunchOffMainTests: XCTestCase {
    func testShellLinesStillStreamsAndRefusesUntrusted() async {
        var out: [String] = []
        for await line in Shell.lines("/bin/echo", ["hello"]) { out.append(line) }
        XCTAssertEqual(out, ["hello"])
        var refused: [String] = []
        for await line in Shell.lines("relative/tool", []) { refused.append(line) }
        XCTAssertEqual(refused.count, 1)
        XCTAssertTrue(refused[0].hasPrefix("Bubble didn't run"), "\(refused)")
    }

    func testStoppedLaunchNeverStarts() throws {
        let launch = Shell.Launch()
        launch.stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertFalse(try launch.run(p))
        XCTAssertFalse(p.isRunning)
    }

    func testPTYExitStatusWaitsForTheLaunch() async {
        let session = PTYSession("/bin/bash", ["-c", "exit 3"])
        // Asked straight away, before the worker has necessarily started the process.
        let status = await session.exitStatus()
        XCTAssertEqual(status, 3)
        for await _ in session.lines {}
    }

    func testPTYRefusalHasNoExitStatus() async {
        let session = PTYSession("relative/tool", [])
        var lines: [String] = []
        for await line in session.lines { lines.append(line) }
        XCTAssertEqual(lines.count, 1)
        let status = await session.exitStatus()
        XCTAssertNil(status)
    }

    func testPTYTerminatedBeforeLaunchNeverStarts() async {
        let session = PTYSession("/bin/bash", ["-c", "sleep 5"])
        session.terminate()
        var lines: [String] = []
        for await line in session.lines { lines.append(line) }
        let status = await session.exitStatus()
        // Either the worker saw the stop first (never started) or the process was killed.
        XCTAssertTrue(status == nil || status != 0, "\(String(describing: status))")
    }
}
