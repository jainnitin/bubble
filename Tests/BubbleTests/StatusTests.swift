import XCTest
@testable import Bubble

/// Fixtures are trimmed real output of `mo history --json --limit 50` (Mole 1.x).
final class HistoryTotalsTests: XCTestCase {
    static let fixture = """
    {
      "logs": {"operations": "/Users/x/Library/Logs/mole/operations.log", "deletions": "/Users/x/Library/Logs/mole/deletions.log"},
      "limit": 50,
      "sessions": [
        {
          "command": "uninstall", "run_id": "20261010183347-45234-8411-354", "attribution": "run",
          "started_at": "2026-10-10 18:33:47", "ended_at": "2026-10-10 18:33:57", "items": 1, "size": "14.2MB",
          "operation_count": 0, "failed_tasks": 0,
          "actions": {"removed": 0, "trashed": 0, "skipped": 0, "failed": 0, "rebuilt": 0, "other": 0}
        },
        {
          "command": "optimize", "run_id": "20261010183131-43557-20338-6099", "attribution": "run",
          "started_at": "2026-10-10 18:31:31", "ended_at": "2026-10-10 18:31:34", "items": 2, "size": "0B",
          "operation_count": 0, "failed_tasks": 0,
          "actions": {"removed": 0, "trashed": 0, "skipped": 0, "failed": 0, "rebuilt": 0, "other": 0}
        },
        {
          "command": "uninstall", "run_id": "20261010183125-42638-9704-21067", "attribution": "run",
          "started_at": "2026-10-10 18:31:25", "ended_at": "2026-10-10 18:31:26", "items": 0, "size": "0B",
          "operation_count": 0, "failed_tasks": 0,
          "actions": {"removed": 0, "trashed": 0, "skipped": 0, "failed": 0, "rebuilt": 0, "other": 0}
        },
        {
          "command": "clean", "run_id": "20261010182955-39949-8755-30504", "attribution": "run",
          "started_at": "2026-10-10 18:29:55", "ended_at": "2026-10-10 18:29:59", "items": 24, "size": "109.7MB",
          "operation_count": 74, "failed_tasks": 0,
          "actions": {"removed": 0, "trashed": 0, "skipped": 74, "failed": 0, "rebuilt": 0, "other": 0}
        },
        {
          "command": "clean", "run_id": "20261010170953-47430-12971-2084", "attribution": "run",
          "started_at": "2026-10-10 17:09:53", "ended_at": "2026-10-10 17:09:59", "items": 25, "size": "177.4MB",
          "operation_count": 99, "failed_tasks": 0,
          "actions": {"removed": 25, "trashed": 0, "skipped": 73, "failed": 1, "rebuilt": 0, "other": 0}
        }
      ]
    }
    """

    func testDryRunsAndListingsAreNotCounted() {
        let t = HistoryTotals(json: Data(Self.fixture.utf8), optimizeRuns: 0)
        XCTAssertEqual(t.uninstalled, 0)
        XCTAssertEqual(t.optimized, 0)
        XCTAssertEqual(t.cleanedBytes, 177.4e6, accuracy: 1)
    }

    func testRealUninstallCountsWhenTrashed() {
        let json = """
        {"sessions": [
          {"command": "uninstall", "attribution": "run", "items": 3, "size": "52.6MB",
           "actions": {"removed": 1, "trashed": 2, "skipped": 0, "failed": 0, "rebuilt": 0, "other": 0}},
          {"command": "purge", "attribution": "run", "items": 1, "size": "1GB",
           "actions": {"removed": 0, "trashed": 1, "skipped": 0, "failed": 0, "rebuilt": 0, "other": 0}},
          {"command": "uninstall", "attribution": "command", "items": 0, "size": "0B"}
        ]}
        """
        let t = HistoryTotals(json: Data(json.utf8), optimizeRuns: 0)
        XCTAssertEqual(t.uninstalled, 1)
        XCTAssertEqual(t.cleanedBytes, 52.6e6 + 1e9, accuracy: 1)
    }

    func testOptimizeComesFromBubblesOwnCounter() {
        let defaults = UserDefaults(suiteName: "BubbleTests.\(UUID().uuidString)")!
        XCTAssertEqual(HistoryTotals.optimizeRunCount(defaults: defaults), 0)
        HistoryTotals.recordOptimizeRun(defaults: defaults)
        HistoryTotals.recordOptimizeRun(defaults: defaults)
        XCTAssertEqual(HistoryTotals.optimizeRunCount(defaults: defaults), 2)
        let t = HistoryTotals(json: Data(Self.fixture.utf8), optimizeRuns: HistoryTotals.optimizeRunCount(defaults: defaults))
        XCTAssertEqual(t.optimized, 2)
    }

    func testGarbageJSON() {
        let t = HistoryTotals(json: Data("not json".utf8), optimizeRuns: 3)
        XCTAssertEqual(t.uninstalled, 0)
        XCTAssertEqual(t.cleanedBytes, 0)
        XCTAssertEqual(t.optimized, 3)
    }
}

final class ProcessControlTests: XCTestCase {
    func testMismatch() {
        XCTAssertNil(ProcessControl.mismatch(sampledPath: "/bin/a", sampledStart: 5, currentPath: "/bin/a", currentStart: 5))
        XCTAssertNil(ProcessControl.mismatch(sampledPath: "/bin/a", sampledStart: nil, currentPath: "/bin/a", currentStart: 9))
        XCTAssertNotNil(ProcessControl.mismatch(sampledPath: "/bin/a", sampledStart: 5, currentPath: "/bin/b", currentStart: 5))
        XCTAssertNotNil(ProcessControl.mismatch(sampledPath: "/bin/a", sampledStart: 5, currentPath: "/bin/a", currentStart: 6))
        XCTAssertNotNil(ProcessControl.mismatch(sampledPath: "/bin/a", sampledStart: 5, currentPath: nil, currentStart: nil))
    }

    func testOwnProcessIsReadable() {
        let pid = Int(getpid())
        XCTAssertNotNil(ProcessControl.executablePath(pid: pid))
        XCTAssertNotNil(ProcessControl.startTime(pid: pid))
        XCTAssertNil(ProcessControl.executablePath(pid: 0))
    }

    @MainActor func testRefusesWhenPathChanged() {
        let me = ProcessSampler.Process(pid: Int(getpid()), name: "x", path: "/not/the/real/path", cpu: 0, memoryBytes: 0)
        // Must refuse without signalling the test process.
        XCTAssertNotNil(ProcessControl.terminate(me, force: false))
    }

    @MainActor func testIconCacheIsPruned() {
        let pid = Int(getpid())
        let path = ProcessControl.executablePath(pid: pid) ?? "/x"
        _ = ProcessIcons.name(pid: pid, path: path)
        _ = ProcessIcons.name(pid: 999_999, path: "/gone")
        XCTAssertGreaterThanOrEqual(ProcessIcons.cacheCount, 2)
        ProcessIcons.prune(keeping: [])
        XCTAssertEqual(ProcessIcons.cacheCount, 0)
    }

    func testMemoryIsBinaryAndDiskIsDecimal() {
        XCTAssertEqual(Fmt.memory(Double(1_073_741_824)), "1.0 GB")
        XCTAssertEqual(Fmt.bytes(Double(1_000_000_000)), "1.0 GB")
    }
}
