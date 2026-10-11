import XCTest
@testable import Bubble

final class VersionCompareTests: XCTestCase {
    func testCaskBuildSuffixIsIgnored() {
        let cask = "2.31226.1,8576520051724193e9f74fc538f9ce8125e9ddd2"
        XCTAssertEqual(VersionCompare.parts(cask), [2, 31226, 1])
        XCTAssertFalse(VersionCompare.isNewer(cask, than: "2.31226.1"))
        XCTAssertTrue(VersionCompare.isNewer(cask, than: "2.31225.9"))
        XCTAssertEqual(VersionCompare.display(cask), "2.31226.1")
    }

    func testLetterLedSuffixesAreDropped() {
        XCTAssertEqual(VersionCompare.parts("1.2.3-beta4"), [1, 2, 3])
        XCTAssertEqual(VersionCompare.parts("1.0 (45)"), [1, 0])
        XCTAssertEqual(VersionCompare.parts("3.1b2"), [3, 1])
        XCTAssertEqual(VersionCompare.parts("v4.5"), [4, 5])
        XCTAssertEqual(VersionCompare.parts("latest"), [])
        XCTAssertFalse(VersionCompare.isNewer("1.2.3-rc1", than: "1.2.3"))
        XCTAssertFalse(VersionCompare.isNewer("latest", than: "1.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(VersionCompare.isNewer("1.0.0", than: "1"))
    }

    private func app(_ version: String) -> AppInfo {
        AppInfo(name: "Claude", bundleId: "com.anthropic.claudefordesktop", source: "Homebrew", uninstallName: "claude",
                path: "/Applications/Claude.app", sizeText: "", bytes: 0, version: version, lastUsed: nil, added: nil, menuBarOnly: false)
    }

    func testBrewOutdatedParsingAndSelfUpdatedApps() {
        let json = """
        {"formulae": [], "casks": [
          {"name": "claude", "installed_versions": ["2.30000.1,aaaa"],
           "current_version": "2.31226.1,8576520051724193e9f74fc538f9ce8125e9ddd2"}
        ]}
        """
        let parsed = UpdatesModel.parseBrewOutdated(Data(json.utf8))
        let cask = try! XCTUnwrap(parsed["claude"])
        XCTAssertEqual(cask.installed, ["2.30000.1,aaaa"])

        // The app already updated itself to the cask's version: no phantom update.
        let selfUpdated = AppUpdate(app: app("2.31226.1"), latest: VersionCompare.display(cask.current), link: nil,
                                    installedVersions: cask.installed)
        XCTAssertFalse(selfUpdated.hasUpdate)

        // Genuinely behind.
        let behind = AppUpdate(app: app("2.30000.1"), latest: VersionCompare.display(cask.current), link: nil,
                               installedVersions: cask.installed)
        XCTAssertTrue(behind.hasUpdate)

        // Homebrew already installed the latest, even if the plist says otherwise.
        let brewCurrent = AppUpdate(app: app("2.30000.1"), latest: "2.31226.1", link: nil,
                                    installedVersions: [cask.current])
        XCTAssertFalse(brewCurrent.hasUpdate)
    }
}

final class AppsSafetyTests: XCTestCase {
    func testCommandArguments() {
        XCTAssertTrue(Safety.isSafeCommandArgument("Safari"))
        XCTAssertTrue(Safety.isSafeCommandArgument("Foo -bar"))
        XCTAssertFalse(Safety.isSafeCommandArgument(""))
        XCTAssertFalse(Safety.isSafeCommandArgument("-rf"))
        XCTAssertFalse(Safety.isSafeCommandArgument("--force"))
        XCTAssertFalse(Safety.isSafeCommandArgument("Bad\nName"))
        XCTAssertFalse(Safety.isSafeCommandArgument("Bad\u{1B}[0m"))
    }

    func testExternalURLs() {
        XCTAssertTrue(Safety.isAllowedExternalURL(URL(string: "https://example.com/app.dmg")!))
        XCTAssertTrue(Safety.isAllowedExternalURL(URL(string: "macappstore://apps.apple.com/app/id123")!))
        XCTAssertFalse(Safety.isAllowedExternalURL(URL(string: "http://example.com/app.dmg")!))
        XCTAssertFalse(Safety.isAllowedExternalURL(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertFalse(Safety.isAllowedExternalURL(URL(string: "x-apple.systempreferences:foo")!))
        XCTAssertFalse(Safety.isAllowedExternalURL(URL(string: "javascript:alert(1)")!))
    }

    func testAppStoreLookupEncodesBundleId() throws {
        let url = try XCTUnwrap(UpdatesModel.appStoreLookupURL(bundleId: "com.evil&entity=x#frag"))
        XCTAssertEqual(url.host, "itunes.apple.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "bundleId" }?.value, "com.evil&entity=x#frag")
        XCTAssertEqual(items.filter { $0.name == "entity" }.map(\.value), ["macSoftware"])
        XCTAssertNil(url.fragment)
        XCTAssertNil(UpdatesModel.appStoreLookupURL(bundleId: ""))
    }

    func testUpdateSessionKeepsNoState() {
        let c = UpdateNetwork.session.configuration
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertNil(c.urlCache)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertEqual(c.httpAdditionalHeaders?["User-Agent"] as? String, UpdateNetwork.userAgent)
    }

    @MainActor func testUninstallBlocksOptionLikeNames() {
        let m = UninstallModel()
        let bad = AppInfo(name: "-rf", bundleId: "x", source: "App", uninstallName: "x", path: "/Applications/-rf.app",
                          sizeText: "", bytes: 0, version: "", lastUsed: nil, added: nil, menuBarOnly: false)
        m.apps = [bad]
        XCTAssertNotNil(m.uninstallBlockers([bad]))
    }
}

final class ConcurrencyLimiterTests: XCTestCase {
    @MainActor func testAtMostTwoRunAtOnce() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        var current = 0
        var peak = 0
        var done = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    await limiter.run {
                        current += 1
                        peak = max(peak, current)
                        try? await Task.sleep(for: .milliseconds(20))
                        current -= 1
                        done += 1
                    }
                }
            }
        }
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(done, 8)
        XCTAssertEqual(limiter.active, 0)
        XCTAssertEqual(limiter.waiting, 0)
    }
}
