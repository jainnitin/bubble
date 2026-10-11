import XCTest
@testable import Bubble

final class HelperTests: XCTestCase {
    func testExpandingHome() {
        let home = "/Users/x"
        XCTAssertEqual(Paths.expandingHome("~", home: home), home)
        XCTAssertEqual(Paths.expandingHome("~/Library/Caches", home: home), "/Users/x/Library/Caches")
        XCTAssertEqual(Paths.expandingHome("$HOME/.npm", home: home), "/Users/x/.npm")
        XCTAssertEqual(Paths.expandingHome("${HOME}/a/$HOME", home: home), "/Users/x/a//Users/x")
        XCTAssertEqual(Paths.expandingHome("~other/x", home: home), "~other/x")
        XCTAssertEqual(Paths.expandingHome("/opt/~/x", home: home), "/opt/~/x")
    }

    /// Mole's minimum version uses the same comparer as app updates.
    func testMoleVersionsAgainstMinimum() {
        let min = MoleInstall.minimumVersion
        XCTAssertTrue(VersionCompare.isNewer(min, than: "1.58.9"))
        XCTAssertTrue(VersionCompare.isNewer(min, than: "1.9.0"))
        XCTAssertFalse(VersionCompare.isNewer(min, than: min))
        XCTAssertFalse(VersionCompare.isNewer(min, than: "1.59.1"))
        XCTAssertFalse(VersionCompare.isNewer(min, than: "V1.60.0"))
        // An unreadable version never counts as too old.
        XCTAssertFalse(VersionCompare.isNewer(min, than: "unknown"))
    }

    func testBrewOutdatedForMole() {
        let outdated = #"{"formulae": [{"name": "mole", "installed_versions": ["1.59.0"], "current_version": "1.60.0"}], "casks": []}"#
        XCTAssertEqual(MoleInstall.parseBrewOutdated(Data(outdated.utf8)), "1.60.0")
        XCTAssertNil(MoleInstall.parseBrewOutdated(Data(#"{"formulae": [], "casks": []}"#.utf8)))
        XCTAssertNil(MoleInstall.parseBrewOutdated(Data()))
    }

    func testLinesSplitOnNewlinesAndReturnsAndKeepTheUnterminatedRest() async {
        var lines: [String] = []
        for await l in Shell.lines("/bin/sh", ["-c", #"printf 'one\ntwo\r\n\n  three  \nlast'"#]) { lines.append(l) }
        XCTAssertEqual(lines, ["one", "two", "three", "last"])
    }
}
