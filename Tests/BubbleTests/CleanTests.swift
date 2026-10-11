import XCTest
@testable import Bubble

final class WhitelistTests: XCTestCase {
    func testRejectsWhatMolesLoaderDrops() {
        let bad = ["", "relative/path", "/a/../b", "/a//b", "/a/b\n", " /a/b", "/a/b ", "/a/\u{07}b",
                   "/", "/System", "/System/Library/Caches", "/bin", "/usr/bin/foo", "/usr/sbin", "/etc/hosts", "/var/db/x",
                   "$HOME/x", "/x/${HOME}", "/a/*", "/a/b?", "/a/[b]", "~/Library/Caches/x"]
        for p in bad { XCTAssertNotNil(Whitelist.rejectionReason(p), p.debugDescription) }
    }

    func testAcceptsNormalPaths() {
        let good = ["/Users/x/Library/Caches/com.foo", "/Users/x/.npm", "/nix/store", "/usr/local/var/cache",
                    "/Users/x/Library/Application Support/Foo Bar", "/private/var/folders/ab/cd", "/Users/x/a.b/c"]
        for p in good { XCTAssertNil(Whitelist.rejectionReason(p), p) }
        XCTAssertEqual(Whitelist.rejectedPaths(good + ["/a//b"]), ["/a//b"])
    }

    func testFailureNamesPaths() {
        let msg = Whitelist.Failure.rejectedPaths(["/a//b", "/c/[d]"]).errorDescription ?? ""
        XCTAssertTrue(msg.contains("/a//b") && msg.contains("/c/[d]"))
    }

    private func v2(original: String?, written: String) -> Data {
        var obj: [String: Any] = ["version": 2, "written": written]
        if let original { obj["original"] = original }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testRestoreOnlyWhenUnchanged() {
        let written = "a\n" + Whitelist.marker + "/x\n"
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: "a\n", written: written), current: written), .restore("a\n"))
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: nil, written: written), current: written), .restore(nil))
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: "a\n", written: written), current: written + "/user-added\n"), .leaveAlone)
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: "a\n", written: written), current: "user rewrote it\n"), .leaveAlone)
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: "a\n", written: written), current: nil), .leaveAlone)
        XCTAssertEqual(Whitelist.restoreAction(backupData: v2(original: nil, written: written), current: nil), .restore(nil))
    }

    func testUnreadableBackupIsSetAside() {
        XCTAssertEqual(Whitelist.restoreAction(backupData: Data("/mine\n".utf8), current: "/mine\n"), .leaveAlone)
        XCTAssertEqual(Whitelist.restoreAction(backupData: Data([0xFF, 0xFE]), current: nil), .leaveAlone)
    }
}

final class CleanParsingTests: XCTestCase {
    let list = """
    # Mole Cleanup Preview
    === User essentials ===
    /Users/x/Library/Caches/com.foo  # 52.6MB, 3 items
    /Users/x/Library/Logs  # 1MB

    === Developer tools ===
    /Users/x/Library/Caches/com.foo/sub  # 2MB, counted under /Users/x/Library/Caches/com.foo
    /Users/x/.npm/_logs/a.log  # 1KB

    === Large files ===
    /Users/x/Library/Caches/com.foo/sub/deep  # 1MB, 2 items, counted under /Users/x/Library/Caches/com.foo/sub
    """

    func testCoveredRowsKeptWithParent() {
        let cats = CleanModel.parsePreview(text: list)
        XCTAssertEqual(cats.map(\.name), ["User essentials", "Developer tools", "Large files"])
        let sub = cats[1].items[0]
        XCTAssertEqual(sub.coveredBy, "/Users/x/Library/Caches/com.foo")
        XCTAssertEqual(sub.bytes, 0)
        XCTAssertEqual(sub.sizeText, "2MB")
        let deep = cats[2].items[0]
        XCTAssertEqual(deep.count, 2)
        XCTAssertEqual(deep.coveredBy, "/Users/x/Library/Caches/com.foo/sub")
        // Total isn't double counted.
        XCTAssertEqual(cats[2].bytes, 0)
    }

    @MainActor
    func testParentGovernsCoveredRows() {
        let model = CleanModel()
        model.categories = CleanModel.parsePreview(text: list)
        model.applyRecommended()
        let parent = model.categories[0].items[0]
        let sub = model.categories[1].items[0]
        let deep = model.categories[2].items[0]
        // "Large files" is not recommended, but its only row is governed by a recommended parent.
        XCTAssertTrue(model.isSelected(deep))
        XCTAssertEqual(model.governingKey(deep), parent.id)
        XCTAssertEqual(model.governingItem(deep)?.id, parent.id)
        XCTAssertEqual(model.coveredItems(under: parent).count, 2)

        // Unchecking the parent unchecks the covered rows in other categories, and
        // all their paths go into the whitelist.
        model.toggle(parent)
        XCTAssertFalse(model.isSelected(sub))
        XCTAssertFalse(model.isSelected(deep))
        XCTAssertEqual(model.selectedCount(model.categories[2]), 0)
        XCTAssertEqual(Set(model.excludedPaths), [parent.path, sub.path, deep.path])

        // Toggling a covered row flips its parent.
        model.toggle(deep)
        XCTAssertTrue(model.isSelected(parent))
        XCTAssertEqual(model.excludedPaths, [])

        // Toggling a category made only of covered rows flips their parent.
        model.toggle(model.categories[2])
        XCTAssertFalse(model.isSelected(parent))
    }

    func testToolLineParsing() {
        XCTAssertEqual(CleanModel.parseToolLine("  → npm cache · would clean")?.name, "npm cache")
        XCTAssertEqual(CleanModel.parseToolLine("→ Nix garbage collection · would clean")?.name, "Nix garbage collection")
        XCTAssertEqual(CleanModel.parseToolLine("  → Homebrew · would cleanup")?.name, "Homebrew")
        let brew = CleanModel.parseToolLine("  → Homebrew cleanup · would free 1.2GB")
        XCTAssertEqual(brew?.name, "Homebrew cleanup")
        XCTAssertEqual(brew?.sizeText, "1.2GB")
        XCTAssertEqual(CleanModel.parseToolLine("  → Homebrew cleanup · 12 items")?.name, "Homebrew cleanup")
        XCTAssertNil(CleanModel.parseToolLine("  → npm logs · 2 items, 2KB dry"))
        XCTAssertNil(CleanModel.parseToolLine("  → npm cache · would skip (whitelist)"))
        XCTAssertNil(CleanModel.parseToolLine("  ✓ npm cache"))
        XCTAssertNil(CleanModel.parseToolLine("  → Xcode unavailable simulators · would clean 3, 1GB"))
    }

    @MainActor
    func testToolItemsAndAlwaysRuns() async {
        let hits = [
            CleanModel.ToolHit(section: "Developer tools", name: "Nix garbage collection", sizeText: ""),
            CleanModel.ToolHit(section: "Developer tools", name: "conda index/tarball/log caches", sizeText: ""),
            CleanModel.ToolHit(section: "Developer tools", name: "Some future tool cache", sizeText: ""),
            CleanModel.ToolHit(section: "Developer tools", name: "Nix garbage collection", sizeText: ""),
        ]
        let items = await CleanModel.toolItems(hits).map(\.item)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].protectPaths, ["/nix/store"])
        XCTAssertFalse(items[0].alwaysRuns)
        XCTAssertEqual(items[1].protectPaths, [NSHomeDirectory() + "/.conda/pkgs"])
        XCTAssertTrue(items[2].alwaysRuns)

        let model = CleanModel()
        model.categories = [CleanCategory(name: "Developer tools", items: items)]
        model.selectNone()
        XCTAssertTrue(model.isSelected(items[2]))
        model.toggle(items[2])
        XCTAssertTrue(model.isSelected(items[2]))
        XCTAssertEqual(Set(model.excludedPaths), ["/nix/store", NSHomeDirectory() + "/.conda/pkgs"])
        XCTAssertEqual(model.alwaysRunItems.map(\.title), ["Some future tool cache"])
    }
}
