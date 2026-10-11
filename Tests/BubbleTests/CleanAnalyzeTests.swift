import XCTest
@testable import Bubble

final class AnalyzeNavigatorTests: XCTestCase {
    private func entry(_ path: String, _ size: Double = 100) -> DiskEntry {
        DiskEntry(name: (path as NSString).lastPathComponent, path: path, size: size, isDir: true)
    }

    func testStaleScanIsDropped() {
        var nav = AnalyzeNavigator()
        let root = nav.open(nil, title: "Whole Disk", push: false)!
        XCTAssertTrue(nav.complete(root, entries: [entry("/Users")], insights: []))

        // Two quick clicks: only the second scan may land, and only one level is pushed.
        let first = nav.open("/Users", title: "Users", push: true)!
        let second = nav.open("/Applications", title: "Applications", push: true)!
        XCTAssertEqual(nav.scanning, "Applications")
        XCTAssertFalse(nav.complete(first, entries: [entry("/Users/a")], insights: []))
        XCTAssertEqual(nav.scanning, "Applications", "a stale scan must not clear the newer scan's label")
        XCTAssertEqual(nav.stack.count, 1)
        XCTAssertTrue(nav.complete(second, entries: [entry("/Applications/X.app")], insights: []))
        XCTAssertNil(nav.scanning)
        XCTAssertEqual(nav.stack.map(\.title), ["Whole Disk", "Applications"])
    }

    func testPopAbandonsScanInFlight() {
        var nav = AnalyzeNavigator()
        nav.complete(nav.open(nil, title: "Whole Disk", push: false)!, entries: [entry("/Users")], insights: [])
        let deeper = nav.open("/Users", title: "Users", push: true)!
        XCTAssertNil(nav.pop(to: 0), "the overview is cached, so no rescan")
        XCTAssertNil(nav.scanning)
        XCTAssertFalse(nav.complete(deeper, entries: [], insights: []))
        XCTAssertEqual(nav.stack.map(\.title), ["Whole Disk"])
    }

    func testCacheUsesCallersTitle() {
        var nav = AnalyzeNavigator()
        nav.complete(nav.open(nil, title: "Whole Disk", push: false)!, entries: [entry("/Users/me/Downloads")], insights: [])
        // Reached first through an insight with its own label…
        let viaInsight = nav.open("/Users/me/Downloads", title: "Old Downloads (90d+)", push: true)!
        nav.complete(viaInsight, entries: [entry("/Users/me/Downloads/a.zip")], insights: [])
        XCTAssertNil(nav.pop(to: 0))
        // …then as the folder itself: served from cache, under the folder's own name.
        XCTAssertNil(nav.open("/Users/me/Downloads", title: "Downloads", push: true))
        XCTAssertEqual(nav.stack.last?.title, "Downloads")
        XCTAssertEqual(nav.stack.last?.entries.map(\.path), ["/Users/me/Downloads/a.zip"])
    }

    func testDoublePushOfSameFolderDoesNotDuplicate() {
        var nav = AnalyzeNavigator()
        nav.complete(nav.open(nil, title: "Whole Disk", push: false)!, entries: [entry("/Users")], insights: [])
        nav.complete(nav.open("/Users", title: "Users", push: true)!, entries: [], insights: [])
        XCTAssertNil(nav.open("/Users", title: "Users", push: true))
        XCTAssertEqual(nav.stack.map(\.title), ["Whole Disk", "Users"])
    }

    func testTrashInvalidatesAncestorsAndDescendants() {
        var nav = AnalyzeNavigator()
        nav.complete(nav.open(nil, title: "Whole Disk", push: false)!, entries: [], insights: [])
        for p in ["/Users/me", "/Users/me/a", "/Users/me/a/b", "/Users/me/ab"] {
            nav.complete(nav.open(p, title: p, push: false)!, entries: [], insights: [])
        }
        nav.invalidate(trashed: "/Users/me/a")
        XCTAssertEqual(Set(nav.cache.keys), ["/Users/me/ab"])
    }

    func testOverviewParsingSeparatesInsights() {
        let json = """
        {"entries":[{"name":"Home","path":"/Users/me","size":10},
                    {"name":"Library","path":"/Users/me/Library","size":4},
                    {"name":"Old Downloads (90d+)","path":"/Users/me/Downloads","size":2,"insight":true},
                    {"name":"Empty","path":"/e","size":0}]}
        """
        let parsed = AnalyzeNavigator.parse(Data(json.utf8), overview: true)
        XCTAssertEqual(parsed.entries.map(\.path), ["/Users/me"])
        XCTAssertEqual(parsed.insights.map(\.name), ["Old Downloads (90d+)"])
    }
}

final class FreedHeadlineTests: XCTestCase {
    func testExactTotal() {
        XCTAssertEqual(CleanModel.freedHeadline(tracked: "5.1MB", diskDelta: 0), "Freed 5.1 MB")
    }

    func testAtLeastTotal() {
        XCTAssertEqual(CleanModel.freedHeadline(tracked: "At least 5.1MB", diskDelta: 0), "Freed at least 5.1 MB")
        XCTAssertEqual(CleanModel.freedHeadline(tracked: "at least 1.20GB", diskDelta: 0), "Freed at least 1.2 GB")
    }

    func testPartiallyMeasuredFallsBack() {
        XCTAssertEqual(CleanModel.freedHeadline(tracked: "Partially measured", diskDelta: 2_000_000), "Freed about 2.0 MB")
        XCTAssertEqual(CleanModel.freedHeadline(tracked: "Partially measured", diskDelta: -10), "Done")
    }

    func testNoTrackedLine() {
        XCTAssertEqual(CleanModel.freedHeadline(tracked: nil, diskDelta: 3_000_000), "Freed 3.0 MB")
        XCTAssertEqual(CleanModel.freedHeadline(tracked: nil, diskDelta: 0), "Done")
    }
}

final class ProtectedItemsGuardTests: XCTestCase {
    private func v2(original: String?, written: String) -> Data {
        var obj: [String: Any] = ["version": 2, "written": written]
        if let original { obj["original"] = original }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testBackupOriginal() {
        XCTAssertEqual(Whitelist.originalState(backupData: v2(original: "/a\n", written: "/a\n# bubble…\n/b\n")), .text("/a\n"))
        XCTAssertEqual(Whitelist.originalState(backupData: v2(original: nil, written: "x")), .missing)
        XCTAssertNil(Whitelist.originalState(backupData: Data("/not a backup\n".utf8)))
        XCTAssertNil(Whitelist.originalState(backupData: Data([0xFF, 0xFE])))
    }

    func testDuringCleanLoadsUsersListNotTemporaryOne() {
        let temporary = Whitelist.FileState.text("/mine\n" + Whitelist.marker + "/unchecked/this/run\n")
        let d = ProtectedItemsModel.loadDecision(busy: true, current: temporary, backupOriginal: .text("/mine\n"))
        XCTAssertEqual(d, .use(.text("/mine\n"), duringClean: true))
        if case .use(.text(let t), _) = d { XCTAssertEqual(ProtectedItemsModel.items(from: t), ["/mine"]) }
    }

    func testDuringCleanWithoutReadableBackupRefuses() {
        let d = ProtectedItemsModel.loadDecision(busy: true, current: .text("/x\n"), backupOriginal: nil)
        guard case .refuse = d else { return XCTFail("expected refusal, got \(d)") }
    }

    func testNotBusyUsesFileAndRefusesUnreadable() {
        XCTAssertEqual(ProtectedItemsModel.loadDecision(busy: false, current: .missing, backupOriginal: nil),
                       .use(.missing, duringClean: false))
        guard case .refuse = ProtectedItemsModel.loadDecision(busy: false, current: .unreadable("bad"), backupOriginal: nil)
        else { return XCTFail("expected refusal") }
    }

    func testSaveGuards() {
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: true, loadedFrom: .text("a"), current: .text("a")), .busy)
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: false, loadedFrom: .text("a"), current: .text("b")), .changedOnDisk)
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: false, loadedFrom: .missing, current: .text("b")), .changedOnDisk)
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: false, loadedFrom: nil, current: .missing), .changedOnDisk)
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: false, loadedFrom: .text("a"), current: .text("a")), .ok)
        XCTAssertEqual(ProtectedItemsModel.saveCheck(busy: false, loadedFrom: .missing, current: .missing), .ok)
    }

    func testItemsSkipCommentsIncludingBubbleMarker() {
        XCTAssertEqual(ProtectedItemsModel.items(from: "# Edited in Bubble\n /a \n\n" + Whitelist.marker + "/b\n"), ["/a", "/b"])
    }
}
