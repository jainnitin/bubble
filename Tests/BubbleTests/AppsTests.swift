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
                path: "/Applications/Claude.app", bytes: 0, version: version, lastUsed: nil, added: nil, menuBarOnly: false)
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
}

// MARK: - Native uninstall

/// A fake Mac under a temp folder: Applications, a home with ~/Library, /Library and a
/// Caskroom. Nothing here touches the real system.
final class FakeMac {
    let base: String
    let roots: AppRoots
    let fm = FileManager.default

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-apps-\(UUID().uuidString)").path
        base = tmp
        let home = tmp + "/home"
        roots = AppRoots(home: home, appFolders: [tmp + "/Applications", home + "/Applications"],
                         systemLibrary: tmp + "/Library", caskrooms: [tmp + "/Caskroom"])
        for d in roots.appFolders + roots.userFolders + roots.systemFolders + [roots.trash, tmp + "/Caskroom"] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }

    deinit { try? fm.removeItem(atPath: base) }

    @discardableResult
    func app(_ name: String, id: String, in folder: String? = nil, bytes: Int = 1000) throws -> String {
        let path = (folder ?? roots.appFolders[0]) + "/" + name + ".app"
        try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        (["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"] as NSDictionary)
            .write(toFile: path + "/Contents/Info.plist", atomically: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/" + name))
        return path
    }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> String {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func lib(_ rel: String) -> String { roots.library + "/" + rel }
    func sys(_ rel: String) -> String { roots.systemLibrary + "/" + rel }

    func trashContents() -> [String] { ((try? fm.contentsOfDirectory(atPath: roots.trash)) ?? []).sorted() }

    /// A trash function that moves into the fake ~/.Trash instead of the real one.
    var fakeTrash: @Sendable (String) throws -> String {
        let trash = roots.trash
        return { path in
            var dest = trash + "/" + (path as NSString).lastPathComponent
            var n = 2
            while AppLeftovers.exists(dest) { dest = trash + "/" + (path as NSString).lastPathComponent + " \(n)"; n += 1 }
            try FileManager.default.moveItem(atPath: path, toPath: dest)
            return dest
        }
    }

    /// Runs the admin script as the current user with /bin/sh (launchctl stubbed out),
    /// which is enough to exercise the moves, name clashes and quoting.
    static let runAdminLocally: @Sendable (String, String) async throws -> String = { script, _ in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script.replacingOccurrences(of: "/bin/launchctl", with: ":")]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Admin.Failure.failed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return output
    }

    func remover(admin: (@Sendable (String, String) async throws -> String)? = nil,
                 quit: AppRemover.QuitOutcome = .notRunning,
                 tool: (@Sendable (String, [String], [String: String]) async -> AppRemover.ToolResult)? = nil) -> AppRemover {
        var r = AppRemover(roots: roots)
        r.trash = fakeTrash
        r.admin = admin ?? Self.runAdminLocally
        r.quit = { _ in quit }
        r.tool = tool ?? { _, _, _ in AppRemover.ToolResult(status: 0, output: "") }
        return r
    }

    func scan() -> AppScanner.Result { AppScanner.scan(roots) }

    func discover(_ path: String, fullDiskAccess: Bool = true) -> [Leftover] {
        let s = scan()
        let me = s.identities.first { $0.path == path }!
        return AppLeftovers.discover(me, others: s.identities, index: LeftoverIndex.read(roots, fullDiskAccess: fullDiskAccess), roots: roots)
    }

    func items(_ app: AppInfo) -> [RemovalItem] {
        [RemovalItem(path: app.path, bytes: 1, isApp: true)]
            + discover(app.path).map { RemovalItem(path: $0.path, bytes: 1, isSystem: $0.isSystem) }
    }
}

final class AppScanTests: XCTestCase {
    func testListsAppsSkipsAppleAndProtectedAndSymlinks() throws {
        let mac = try FakeMac()
        try mac.app("Foo", id: "com.example.foo")
        try mac.app("Mine", id: "com.example.mine", in: mac.roots.appFolders[1])
        try mac.app("Disk Tool", id: "com.example.disktool", in: mac.roots.appFolders[0] + "/Utilities")
        try mac.app("Safari", id: "com.apple.Safari")
        try mac.app("Bubble", id: "com.jainnitin.Bubble")
        try mac.app("Falcon", id: "com.crowdstrike.falcon.App")
        try mac.app("Deep", id: "com.example.deep", in: mac.roots.appFolders[0] + "/A/B")   // two levels: not listed
        try FileManager.default.createSymbolicLink(atPath: mac.roots.appFolders[0] + "/Link.app",
                                                   withDestinationPath: mac.roots.appFolders[0] + "/Foo.app")
        let s = mac.scan()
        XCTAssertEqual(Set(s.apps.map(\.bundleId)), ["com.example.foo", "com.example.mine", "com.example.disktool"])
        // Protected apps still count as installed for leftover matching.
        XCTAssertTrue(s.identities.contains { $0.bundleId == "com.apple.Safari" })
        let foo = try XCTUnwrap(s.apps.first { $0.bundleId == "com.example.foo" })
        XCTAssertEqual(foo.version, "1.0")
        XCTAssertEqual(foo.source, "App")
        XCTAssertFalse(foo.sized)
        XCTAssertGreaterThanOrEqual(AppLeftovers.allocatedSize(foo.path), 1000)
    }

    func testCaskroomSymlinksAndAppStoreReceipt() throws {
        let mac = try FakeMac()
        let claude = try mac.app("Claude", id: "com.anthropic.claudefordesktop")
        let mas = try mac.app("Things", id: "com.culturedcode.ThingsMac")
        try mac.file(mas + "/Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(atPath: mac.base + "/Caskroom/claude/2.0", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: mac.base + "/Caskroom/claude/2.0/Claude.app", withDestinationPath: claude)
        try FileManager.default.createDirectory(atPath: mac.base + "/Caskroom/some-font/1.0", withIntermediateDirectories: true)
        let s = mac.scan()
        let c = try XCTUnwrap(s.apps.first { $0.path == claude })
        XCTAssertTrue(c.isBrew)
        XCTAssertEqual(c.uninstallName, "claude")
        XCTAssertEqual(s.apps.first { $0.path == mas }?.source, "App Store")
        XCTAssertEqual(s.unresolvedCasks, ["some-font"])
    }

    func testMacOSAppsOnlyBlockNameMatches() throws {
        let mac = try FakeMac()
        var roots = mac.roots
        roots.systemAppFolders = [mac.base + "/System/Applications"]
        try mac.app("Chessboard", id: "com.example.chessboard.sys", in: roots.systemAppFolders[0] + "/Utilities")
        let mine = try mac.app("Chessboard", id: "com.example.chessboard")
        try mac.file(mac.lib("Application Support/Chessboard"))
        let s = AppScanner.scan(roots)
        XCTAssertEqual(s.apps.map(\.path), [mine])
        XCTAssertTrue(s.identities.contains { $0.bundleId == "com.example.chessboard.sys" })
        let me = try XCTUnwrap(s.identities.first { $0.path == mine })
        XCTAssertEqual(AppLeftovers.discover(me, others: s.identities, index: LeftoverIndex.read(roots, fullDiskAccess: true), roots: roots), [])
    }

    func testBrewInfoParsing() {
        let json = """
        {"formulae": [], "casks": [
          {"token": "claude", "artifacts": [{"uninstall": []}, {"app": ["Claude.app"], "target": "/Applications/Claude.app"}]},
          {"token": "foo", "artifacts": [{"app": ["Foo Installer.app", {"target": "Foo.app"}]}]},
          {"token": "bar", "artifacts": [{"app": ["sub/Bar.app"]}]},
          {"token": "font", "artifacts": [{"font": ["x.ttf"]}]}
        ]}
        """
        XCTAssertEqual(AppLeftovers.parseBrewInfoApps(Data(json.utf8)), [
            "/Applications/Claude.app": "claude", "/Applications/Foo.app": "foo", "/Applications/Bar.app": "bar",
        ])
    }
}

final class LeftoverDiscoveryTests: XCTestCase {
    func testFindsByBundleIdAndExactName() throws {
        let mac = try FakeMac()
        let foo = try mac.app("Foozle", id: "com.example.Foozle")
        try mac.app("Foozle Canary", id: "com.example.Foozle.canary")
        let expected = [
            mac.lib("Application Support/com.example.Foozle"),
            mac.lib("Application Support/Foozle"),                         // exact name
            mac.lib("Caches/com.example.Foozle"),
            mac.lib("Caches/com.example.Foozle.ShipIt"),
            mac.lib("Preferences/com.example.Foozle.plist"),
            mac.lib("Preferences/ByHost/com.example.Foozle.0000-1111.plist"),
            mac.lib("Containers/com.example.Foozle"),
            mac.lib("Group Containers/ABCDE12345.com.example.Foozle"),
            mac.lib("Group Containers/group.com.example.Foozle.shared"),
            mac.lib("Saved Application State/com.example.Foozle.savedState"),
            mac.lib("HTTPStorages/com.example.Foozle"),
            mac.lib("WebKit/com.example.Foozle"),
            mac.lib("Logs/Foozle"),
            mac.lib("Cookies/com.example.Foozle.binarycookies"),
            mac.lib("LaunchAgents/com.example.Foozle.helper.plist"),
            mac.lib("Application Scripts/com.example.Foozle"),
            mac.sys("LaunchDaemons/com.example.Foozle.helper.plist"),
            mac.sys("PrivilegedHelperTools/com.example.Foozle.helper"),
            mac.sys("Application Support/com.example.Foozle"),
        ]
        let decoys = [
            mac.lib("Application Support/com.example.FoozlePro"),          // not a "." boundary
            mac.lib("Caches/com.example.Foozle.canary"),                    // the Canary app's
            mac.lib("Preferences/com.example.Foozle.canary.plist"),
            mac.lib("Group Containers/group.com.example.Foozle.canary"),
            mac.lib("Application Support/Foozle Helper"),                   // name prefix only
            mac.lib("Application Support/com.example"),                     // vendor
            mac.lib("Preferences/com.apple.Foozle.plist"),
            mac.lib("Caches/Sub/com.example.Foozle"),                       // not a direct child
            mac.lib("LaunchAgents/com.example.Foozle.txt"),                 // not a plist
            mac.sys("Application Support/Foozle"),                          // system level: ids only
            mac.lib("Mail/com.example.Foozle"),                             // not a leftover folder
        ]
        for p in expected + decoys { try mac.file(p) }
        let found = mac.discover(foo)
        XCTAssertEqual(Set(found.map(\.path)), Set(expected))
        XCTAssertEqual(Set(found.filter(\.isSystem).map(\.path)), Set(expected.filter { $0.hasPrefix(mac.roots.systemLibrary) }))
        XCTAssertEqual(found.first { $0.path.hasSuffix("LaunchDaemons/com.example.Foozle.helper.plist") }?.kind, "Launch Daemon")
    }

    func testWithoutFullDiskAccessContainersAreProbedNeverListed() throws {
        let mac = try FakeMac()
        let foo = try mac.app("Foozle", id: "com.example.Foozle")
        try mac.app("Foozle Canary", id: "com.example.Foozle.canary")
        let main = try mac.file(mac.lib("Containers/com.example.Foozle/Data/x"))
        let ext = try mac.file(mac.lib("Containers/com.example.Foozle.Share/Data/x"))
        try mac.file(mac.lib("Application Scripts/com.example.Foozle.Share/x"))   // names the extension
        let hidden = try mac.file(mac.lib("Containers/com.example.Foozle.Hidden/Data/x"))  // no Application Scripts entry
        try mac.file(mac.lib("Containers/com.example.Foozle.canary/Data/x"))
        try mac.file(mac.lib("Application Scripts/com.example.Foozle.canary/x"))
        let group = try mac.file(mac.lib("Group Containers/group.com.example.Foozle/x"))
        let dir = { (p: String) in (p as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Data", with: "") }

        let withFDA = Set(mac.discover(foo, fullDiskAccess: true).map(\.path).filter { $0.contains("Containers/") })
        XCTAssertEqual(withFDA, [dir(main), dir(ext), dir(hidden), (group as NSString).deletingLastPathComponent])

        // Make the container folders unlistable (but traversable): probe mode still finds
        // the exact paths, which proves it never lists them.
        for f in ["Containers", "Group Containers"] { chmod(mac.lib(f), 0o100) }
        defer { for f in ["Containers", "Group Containers"] { chmod(mac.lib(f), 0o755) } }
        let probed = Set(mac.discover(foo, fullDiskAccess: false).map(\.path).filter { $0.contains("Containers/") })
        XCTAssertEqual(probed, [dir(main), dir(ext), (group as NSString).deletingLastPathComponent])
        XCTAssertEqual(AppLeftovers.existence(dir(main)), .present)
        XCTAssertEqual(AppLeftovers.existence(mac.lib("Containers/com.example.none")), .missing)
    }

    func testProtectedIsNotMissing() throws {
        let mac = try FakeMac()
        try mac.file(mac.lib("Containers/com.example.x/y"))
        chmod(mac.lib("Containers"), 0o000)
        defer { chmod(mac.lib("Containers"), 0o755) }
        XCTAssertEqual(AppLeftovers.existence(mac.lib("Containers/com.example.x")), .protected)
        XCTAssertTrue(AppLeftovers.exists(mac.lib("Containers/com.example.x")))
    }

    func testGenericAndSharedNamesAreNotNameMatched() throws {
        let mac = try FakeMac()
        let notes = try mac.app("Notes", id: "com.example.notes")
        let a = try mac.app("Twin", id: "com.example.twin.a")
        try mac.app("Twin", id: "com.example.twin.b", in: mac.roots.appFolders[1])
        try mac.file(mac.lib("Application Support/Notes"))
        try mac.file(mac.lib("Application Support/Twin"))
        XCTAssertEqual(mac.discover(notes).map(\.path), [])
        XCTAssertEqual(mac.discover(a).map(\.path), [])
    }

    func testTwoCopiesOfOneAppShareTheirData() throws {
        let mac = try FakeMac()
        let one = try mac.app("Dup", id: "com.example.dup.app")
        try mac.app("Dup Copy", id: "com.example.dup.app", in: mac.roots.appFolders[1])
        try mac.file(mac.lib("Caches/com.example.dup.app"))
        XCTAssertEqual(mac.discover(one).map(\.path), [])
    }

    func testTwoPartIdsMatchOnlyExactly() throws {
        let mac = try FakeMac()
        let app = try mac.app("Shorty", id: "com.shorty")
        try mac.file(mac.lib("Caches/com.shorty"))
        try mac.file(mac.lib("Preferences/com.shorty.plist"))
        try mac.file(mac.lib("Caches/com.shorty.other"))
        try mac.file(mac.lib("Group Containers/group.com.shorty"))
        XCTAssertEqual(Set(mac.discover(app).map(\.path)), [mac.lib("Caches/com.shorty"), mac.lib("Preferences/com.shorty.plist")])
    }
}

final class AppRemovalTests: XCTestCase {
    private func info(_ mac: FakeMac, _ path: String) -> AppInfo {
        mac.scan().apps.first { $0.path == path }!
    }

    func testMovesAppAndLeftoversToTrashAndSystemFilesThroughOneAdminCall() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Crisp", id: "com.example.crisp")
        try mac.file(mac.lib("Caches/com.example.crisp"))
        try mac.file(mac.lib("Preferences/com.example.crisp.plist"))
        try mac.file(mac.roots.trash + "/com.example.crisp.helper.plist")   // name clash in the Trash for the admin move
        let agent = mac.lib("LaunchAgents/com.example.crisp.agent.plist")
        (["Label": "com.example.crisp.agent"] as NSDictionary).write(toFile: agent, atomically: true)
        let daemon = mac.sys("LaunchDaemons/com.example.crisp.helper.plist")
        try mac.file(daemon)
        let keep = try mac.file(mac.lib("Caches/com.example.crispy"))

        let calls = Recorder()
        let r = mac.remover(admin: { script, prompt in
            await calls.add("admin: " + prompt)
            XCTAssertTrue(script.contains("bootout 'system/com.example.crisp.helper'"))
            return try await FakeMac.runAdminLocally(script, prompt)
        }, tool: { exe, args, _ in
            await calls.add(([exe] + args).joined(separator: " "))
            return .init(status: 0, output: "")
        })
        let app = info(mac, path)
        let (result, pending) = await r.remove(app, items: mac.items(app), owner: 0)
        XCTAssertEqual(result.leftBehind, [])
        XCTAssertTrue(result.removed)
        XCTAssertEqual(pending.map(\.item.path), [daemon])
        let outcome = await r.removeWithAdmin(pending, prompt: "Bubble needs permission to remove “Crisp” and its system files.")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.removed, [daemon])
        XCTAssertEqual(outcome.moved, [daemon: mac.roots.trash + "/com.example.crisp.helper 2.plist"])
        XCTAssertFalse(result.trashed.contains { $0.original == daemon })

        XCTAssertEqual(mac.trashContents(), ["Crisp.app", "com.example.crisp", "com.example.crisp.agent.plist",
                                             "com.example.crisp.helper 2.plist", "com.example.crisp.helper.plist", "com.example.crisp.plist"].sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep))
        let log = await calls.all
        XCTAssertTrue(log.contains("/bin/launchctl bootout gui/\(getuid())/com.example.crisp.agent"), "\(log)")
        XCTAssertEqual(log.filter { $0.hasPrefix("admin:") }.count, 1)
    }

    func testSymlinkLeftoverIsTrashedNotItsTarget() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Linky", id: "com.example.linky")
        let target = try mac.file(mac.base + "/elsewhere/precious.txt")
        try FileManager.default.createSymbolicLink(atPath: mac.lib("Caches/com.example.linky"), withDestinationPath: mac.base + "/elsewhere")
        let app = info(mac, path)
        let (result, _) = await mac.remover().remove(app, items: mac.items(app), owner: 0)
        XCTAssertEqual(result.leftBehind, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: mac.roots.trash + "/com.example.linky"), mac.base + "/elsewhere")
    }

    func testRunningAppIsSkipped() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Busy", id: "com.example.busy")
        let app = info(mac, path)
        let (result, pending) = await mac.remover(quit: .stillRunning).remove(app, items: mac.items(app), owner: 0)
        XCTAssertFalse(result.removed)
        XCTAssertEqual(pending, [])
        XCTAssertEqual(result.leftBehind.map(\.path), [path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHelpersInsideTheBundleCountAsTheApp() {
        let zoom = "/Applications/zoom.us.app"
        XCTAssertTrue(AppRemover.isInside(zoom, bundle: zoom))
        XCTAssertTrue(AppRemover.isInside(zoom + "/Contents/Frameworks/cpthost.app/Contents/MacOS/CptHost", bundle: zoom))
        XCTAssertFalse(AppRemover.isInside("/Applications/zoom.us.app.old/Contents/MacOS/zoom.us", bundle: zoom))
        XCTAssertFalse(AppRemover.isInside("/Applications", bundle: zoom))
    }

    func testQuittingFindsOwnProcessesOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-quit-\(UUID().uuidString).app")
        let exe = dir.appendingPathComponent("Contents/MacOS/sleeper")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe.path)
        // A copied platform binary is killed at launch until it's re-signed.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", exe.path]
        let signed = sign.exitSignal()
        try sign.run()
        signed.wait()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = AppRemover.realPath(dir.path)
        XCTAssertEqual(AppRemover.processes(inside: bundle), [])
        let p = Process()
        p.executableURL = exe
        p.arguments = ["30"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        for _ in 0..<20 where AppRemover.processes(inside: bundle).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(AppRemover.processes(inside: bundle), [p.processIdentifier])
        let outcome = await AppRemover.quitApp(path: dir.path, grace: .milliseconds(200))
        XCTAssertEqual(outcome, .quit, "a helper that ignores quitting is force-quit")
        XCTAssertFalse(p.isRunning)
    }

    func testProtectedOrReplacedAppIsRefused() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Busy", id: "com.example.busy")
        var app = info(mac, path)
        app.bundleId = "com.apple.Safari"
        var (result, _) = await mac.remover().remove(app, items: mac.items(app), owner: 0)
        XCTAssertFalse(result.leftBehind.isEmpty)
        app = info(mac, path)
        app.bundleId = "com.example.other"      // a different app now sits at this path
        (result, _) = await mac.remover().remove(app, items: [RemovalItem(path: path, bytes: 0, isApp: true)], owner: 0)
        XCTAssertFalse(result.leftBehind.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testItemsOutsideTheRootsAreSkipped() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Crisp", id: "com.example.crisp")
        let outside = try mac.file(mac.base + "/home/Documents/com.example.crisp")
        let app = info(mac, path)
        let (result, _) = await mac.remover().remove(app, items: [RemovalItem(path: path, bytes: 0, isApp: true),
                                                                  RemovalItem(path: outside, bytes: 0)], owner: 0)
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.leftBehind.map(\.path), [outside])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }

    func testPrivacyBlockedItemsAreLeftBehindAndTheRestContinues() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Boxed", id: "com.example.boxed")
        let container = try mac.file(mac.lib("Containers/com.example.boxed/Data/x"))
        let owned = try mac.file(mac.lib("Caches/com.example.boxed"))
        try mac.file(mac.lib("Preferences/com.example.boxed.plist"))
        let app = info(mac, path)
        var r = mac.remover()
        let fake = mac.fakeTrash
        let containerDir = (container as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Data", with: "")
        r.trash = { p in
            let posix = { (code: Int32) in NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                                   userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))]) }
            if p == containerDir { throw posix(EPERM) }   // TCC: "Operation not permitted"
            if p == owned { throw posix(EACCES) }          // root-owned: admin can fix
            return try fake(p)
        }
        let me = r.uid
        r.ownerUID = { $0 == owned ? 0 : me }
        let (result, pending) = await r.remove(app, items: mac.items(app), owner: 0)
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.leftBehind, [LeftBehind(path: containerDir, reason: AppRemover.protectedReason)])
        XCTAssertEqual(pending.map(\.item.path), [owned])
        XCTAssertEqual(mac.trashContents(), ["Boxed.app", "com.example.boxed.plist"])
    }

    /// A bare "no permission" error on your own container (what macOS returned for a real
    /// app's container) is privacy protection: admin rights can't move it, so don't ask.
    func testOwnItemBlockedWithoutPOSIXCodeIsNotSentToAdmin() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Boxed", id: "com.example.boxed")
        try mac.file(mac.lib("Containers/com.example.boxed/Data/x"))
        let containerDir = mac.lib("Containers/com.example.boxed")
        let app = info(mac, path)
        var r = mac.remover()
        let fake = mac.fakeTrash
        r.trash = { p in
            if p == containerDir { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            return try fake(p)
        }
        let (result, pending) = await r.remove(app, items: mac.items(app), owner: 0)
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.leftBehind.map(\.path), [containerDir])
        XCTAssertEqual(pending, [])
    }

    func testBlockedKind() {
        func wrap(_ code: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
        XCTAssertEqual(AppRemover.blockedKind(wrap(EPERM)), .privacy)
        XCTAssertEqual(AppRemover.blockedKind(wrap(EACCES)), .ownership)
        XCTAssertEqual(AppRemover.blockedKind(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)), .ownership)
        XCTAssertNil(AppRemover.blockedKind(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    @MainActor func testWithoutFullDiskAccessContainersAreProtectedUncountedAndNeverTrashed() async throws {
        let mac = try FakeMac()
        let path = try mac.app("Boxed", id: "com.example.boxed")
        let container = mac.lib("Containers/com.example.boxed")
        let group = mac.lib("Group Containers/group.com.example.boxed")
        try mac.file(container + "/Data/big", String(repeating: "x", count: 50_000))
        try mac.file(group + "/big", String(repeating: "x", count: 50_000))
        try mac.file(mac.lib("Caches/com.example.boxed"))
        let attempted = Recorder()
        var r = mac.remover()
        let fake = mac.fakeTrash
        r.trash = { p in
            Task { await attempted.add(p) }
            return try fake(p)
        }
        let m = UninstallModel(roots: mac.roots, remover: r, checkFullDiskAccess: { false })
        await m.load()
        let app = try XCTUnwrap(m.apps.first { $0.path == path })
        await m.sizeLeftovers(app, userInitiated: true)
        let items = try XCTUnwrap(m.leftovers[app.id])
        XCTAssertEqual(Set(items.filter(\.isProtected).map(\.path)), [container, group])
        XCTAssertTrue(items.filter(\.isProtected).allSatisfy { $0.bytes == nil })
        XCTAssertLessThan(try XCTUnwrap(m.leftoverBytes(app)), 50_000)

        m.selected = [app.id]
        await m.removeSelected()
        try await Task.sleep(for: .milliseconds(50))
        let tried = await attempted.all
        XCTAssertFalse(tried.contains(container) || tried.contains(group), "\(tried)")
        XCTAssertTrue(AppLeftovers.exists(container))
        XCTAssertTrue(AppLeftovers.exists(group))
        XCTAssertEqual(m.toast?.leftBehind, [])
        XCTAssertEqual(mac.trashContents(), ["Boxed.app", "com.example.boxed"])
    }

    func testAdminCancelledLeavesItemsAndReportsThem() async throws {
        let mac = try FakeMac()
        let daemon = try mac.file(mac.sys("LaunchDaemons/com.example.x.plist"))
        let r = mac.remover(admin: { _, _ in throw Admin.Failure.cancelled })
        let outcome = await r.removeWithAdmin([PendingAdmin(owner: 0, item: RemovalItem(path: daemon, bytes: 1, isSystem: true))], prompt: "p")
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(outcome.moved, [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: daemon))
    }

    func testAdminScriptReportsWhereEachItemLanded() async throws {
        let mac = try FakeMac()
        let odd = try mac.file(mac.sys("Application Support/Foo Bar's \"x\" $HOME `id`"))
        let daemon = try mac.file(mac.sys("LaunchDaemons/com.example.x.plist"))
        let helper = try mac.file(mac.sys("PrivilegedHelperTools/com.example.x.helper"))
        try mac.file(mac.roots.trash + "/Foo Bar's \"x\" $HOME `id`")
        try mac.file(mac.roots.trash + "/com.example.x.plist")
        try mac.file(mac.roots.trash + "/com.example.x 2.plist")
        let r = mac.remover()
        let script = r.adminScript([RemovalItem(path: daemon, bytes: 1, isSystem: true)])
        XCTAssertFalse(script.contains("chown -R") || script.contains("chown -hR") || script.contains("-R "), script)

        let pending = [odd, daemon, helper].map { PendingAdmin(owner: 0, item: RemovalItem(path: $0, bytes: 1, isSystem: true)) }
        let outcome = await r.removeWithAdmin(pending, prompt: "p")
        let t = mac.roots.trash
        XCTAssertEqual(outcome.moved, [
            odd: t + "/Foo Bar's \"x\" $HOME `id` 2",
            daemon: t + "/com.example.x 3.plist",
            helper: t + "/com.example.x.helper",
        ])
        for dest in outcome.moved.values { XCTAssertTrue(AppLeftovers.exists(dest), dest) }

        // Output through osascript may end lines in "\r"; sudo trims and may add noise.
        let items = [RemovalItem(path: "/L/a b.plist", bytes: 0), RemovalItem(path: "/L/c", bytes: 0)]
        XCTAssertEqual(AppRemover.parseAdminMoves("moved 0 1\r\nPassword:\nmoved 1 4\nmoved 7 1\nmoved 1 0\n", items: items, trash: "/T"),
                       ["/L/a b.plist": "/T/a b.plist", "/L/c": "/T/c 4"])
    }

    func testRestoreNeverOverwritesAndChecksRoots() throws {
        let mac = try FakeMac()
        let original = mac.lib("Caches/com.example.r")
        let trashed = try mac.file(mac.roots.trash + "/com.example.r", "old")
        let outside = try mac.file(mac.roots.trash + "/notes", "mine")
        try mac.file(original, "new")
        let failed = AppRemover.restore([
            TrashedItem(original: original, trashed: trashed, kind: .leftover, appName: "R"),
            TrashedItem(original: mac.base + "/home/Documents/notes", trashed: outside, kind: .leftover, appName: "R"),
        ], roots: mac.roots)
        XCTAssertEqual(failed.map(\.path), [trashed, outside])
        XCTAssertEqual(try String(contentsOfFile: original, encoding: .utf8), "new")
        XCTAssertTrue(AppLeftovers.exists(trashed))
        XCTAssertFalse(AppLeftovers.exists(mac.base + "/home/Documents/notes"))
    }

    @MainActor func testModelRemovesRowsAndShowsAToast() async throws {
        let mac = try FakeMac()
        try mac.app("Alpha", id: "com.example.alpha", bytes: 4096)
        try mac.app("Beta", id: "com.example.beta", bytes: 4096)
        try mac.file(mac.lib("Caches/com.example.alpha"))
        let daemon = try mac.file(mac.sys("LaunchDaemons/com.example.beta.plist"))
        let defaults = UserDefaults(suiteName: "BubbleTests.\(UUID().uuidString)")!
        let m = UninstallModel(roots: mac.roots, remover: mac.remover(admin: { _, _ in throw Admin.Failure.cancelled }),
                               checkFullDiskAccess: { true }, historyDefaults: defaults)
        await m.load()
        XCTAssertEqual(Set(m.apps.map(\.name)), ["Alpha", "Beta"])
        XCTAssertTrue(m.apps.allSatisfy(\.sized))
        XCTAssertEqual(m.leftovers[m.apps.first { $0.name == "Alpha" }!.id]?.count, 1)
        m.selected = Set(m.apps.map(\.id))
        await m.removeSelected()
        // Beta's app went to the Trash, but its daemon needed admin rights, which were cancelled.
        XCTAssertEqual(m.apps.map(\.name), [])
        XCTAssertEqual(HistoryTotals.uninstallCount(defaults: defaults), 2)
        let toast = try XCTUnwrap(m.toast)
        XCTAssertTrue(toast.message.hasPrefix("Moved 2 apps to the Trash · "), toast.message)
        XCTAssertEqual(toast.leftBehind.map(\.path), [daemon])
        XCTAssertEqual(toast.leftBehindClause, "1 item left behind")
        XCTAssertFalse(toast.leftBehindDetails.isEmpty)
        XCTAssertEqual(toast.restorable.count, 3)
        XCTAssertFalse(m.removing)
        XCTAssertFalse(m.loading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: daemon))
    }

    @MainActor func testUndoPutsBackWhatWasTrashedButNeverOverwrites() async throws {
        let mac = try FakeMac()
        let alpha = try mac.app("Alpha", id: "com.example.alpha", bytes: 4096)
        let cache = try mac.file(mac.lib("Caches/com.example.alpha"), "old")
        let prefs = try mac.file(mac.lib("Preferences/com.example.alpha.plist"))
        let daemon = try mac.file(mac.sys("LaunchDaemons/com.example.alpha.plist"))
        let m = UninstallModel(roots: mac.roots, remover: mac.remover(), checkFullDiskAccess: { true },
                               historyDefaults: UserDefaults(suiteName: "BubbleTests.\(UUID().uuidString)")!)
        await m.load()
        m.selected = Set(m.apps.map(\.id))
        await m.removeSelected()
        let removed = try XCTUnwrap(m.toast)
        XCTAssertEqual(removed.adminMoved, 1)
        XCTAssertEqual(Set(removed.restorable.map(\.original)), [alpha, cache, prefs])
        XCTAssertFalse(AppLeftovers.exists(daemon))

        try mac.file(cache, "new")   // the app made a fresh cache in the meantime
        await m.undo()
        XCTAssertTrue(AppLeftovers.exists(alpha))
        XCTAssertTrue(AppLeftovers.exists(prefs))
        XCTAssertEqual(try String(contentsOfFile: cache, encoding: .utf8), "new")
        XCTAssertFalse(AppLeftovers.exists(daemon))
        // The cache that wasn't overwritten, and the daemon moved with admin rights.
        XCTAssertEqual(mac.trashContents(), ["com.example.alpha", "com.example.alpha 2.plist"])
        let restored = try XCTUnwrap(m.toast)
        XCTAssertEqual(restored.message, "Restored Alpha · Some system files stay in the Trash")
        XCTAssertEqual(restored.leftBehindClause, "1 item still in the Trash")
        XCTAssertTrue(restored.restorable.isEmpty)
        XCTAssertEqual(m.apps.map(\.path), [alpha])
    }

    /// Homebrew apps go to the Trash like any other; Homebrew's record of the cask (and its
    /// command-line links) follow, so Homebrew stops tracking it. Nothing calls brew.
    @MainActor func testHomebrewAppGoesToTheTrashAndHomebrewForgetsIt() async throws {
        let mac = try FakeMac()
        let fm = FileManager.default
        let path = try mac.app("Brewed", id: "com.example.brewed")
        let cache = try mac.file(mac.lib("Caches/com.example.brewed"))
        let record = mac.base + "/Caskroom/brewed"
        try mac.file(record + "/1.0/brewed-cli")
        try fm.createSymbolicLink(atPath: record + "/1.0/Brewed.app", withDestinationPath: path)
        try fm.createDirectory(atPath: mac.base + "/bin", withIntermediateDirectories: true)
        let link = mac.base + "/bin/brewed"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "../Caskroom/brewed/1.0/brewed-cli")
        try mac.file(mac.base + "/Caskroom/brewedpro/1.0/x")
        try fm.createSymbolicLink(atPath: mac.base + "/bin/brewedpro", withDestinationPath: mac.base + "/Caskroom/brewedpro/1.0/x")

        let calls = Recorder()
        let r = mac.remover(tool: { exe, args, _ in
            await calls.add(([exe] + args).joined(separator: " "))
            return .init(status: 0, output: "")
        })
        let m = UninstallModel(roots: mac.roots, remover: r, checkFullDiskAccess: { true },
                               historyDefaults: UserDefaults(suiteName: "BubbleTests.\(UUID().uuidString)")!)
        await m.load()
        let app = try XCTUnwrap(m.apps.first { $0.path == path })
        XCTAssertTrue(app.isBrew)
        m.selected = [app.id]
        await m.removeSelected()
        let log = await calls.all
        XCTAssertEqual(log, [])
        XCTAssertEqual(mac.trashContents(), ["Brewed.app", "brewed", "brewed 2", "com.example.brewed"])
        XCTAssertTrue(AppLeftovers.exists(mac.base + "/bin/brewedpro"))
        XCTAssertTrue(AppLeftovers.exists(mac.base + "/Caskroom/brewedpro"))
        let toast = try XCTUnwrap(m.toast)
        XCTAssertTrue(toast.message.hasPrefix("Moved Brewed to the Trash"), toast.message)
        XCTAssertTrue(toast.message.hasSuffix("Homebrew no longer tracks it"), toast.message)
        XCTAssertEqual(Set(toast.restorable.map(\.original)), [path, cache, record, link])

        await m.undo()
        for p in [path, cache, record, link] { XCTAssertTrue(AppLeftovers.exists(p), p) }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), "../Caskroom/brewed/1.0/brewed-cli")
        XCTAssertEqual(m.toast?.message, "Restored Brewed")
        XCTAssertEqual(m.apps.first { $0.path == path }?.isBrew, true)
    }

    func testCaskTokensCantLeaveTheCaskroom() {
        XCTAssertTrue(AppRemover.isSafeCaskToken("visual-studio-code@insiders"))
        for bad in ["", ".", "..", "-rf", "a/b", "A", "a b"] { XCTAssertFalse(AppRemover.isSafeCaskToken(bad), bad) }
    }
}

actor Recorder {
    var all: [String] = []
    func add(_ s: String) { all.append(s) }
}

/// Read-only timing against this Mac's real apps: `BUBBLE_LIVE_APPS=1 swift test --filter LiveAppScanTests`.
final class LiveAppScanTests: XCTestCase {
    func testScanAndDiscoveryTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUBBLE_LIVE_APPS"] == "1")
        let roots = AppRoots.live
        print("LIVE: Full Disk Access: \(SystemSettings.hasFullDiskAccess)")
        var t = Date()
        let scan = AppScanner.scan(roots)
        let scanTime = Date().timeIntervalSince(t)
        t = Date()
        let index = LeftoverIndex.read(roots, fullDiskAccess: true)
        let indexTime = Date().timeIntervalSince(t)
        t = Date()
        var all: [String: [Leftover]] = [:]
        for app in scan.apps { all[app.id] = AppLeftovers.discover(app.identity, others: scan.identities, index: index, roots: roots) }
        let discoverTime = Date().timeIntervalSince(t)
        // The same discovery as Bubble does it without Full Disk Access (exact-path probes).
        t = Date()
        let probeIndex = LeftoverIndex.read(roots, fullDiskAccess: false)
        var probed: [String: [Leftover]] = [:]
        for app in scan.apps { probed[app.id] = AppLeftovers.discover(app.identity, others: scan.identities, index: probeIndex, roots: roots) }
        print(String(format: "LIVE: probe-mode discovery (no FDA) for all apps %.4fs", Date().timeIntervalSince(t)))
        for app in scan.apps {
            let a = Set((all[app.id] ?? []).map(\.path)), b = Set((probed[app.id] ?? []).map(\.path))
            if a != b { print("LIVE: probe mode differs for \(app.name): only with listing \(a.subtracting(b).sorted()), only with probe \(b.subtracting(a).sorted())") }
        }
        t = Date()
        var leftoverBytes = 0.0
        for items in all.values { for l in items where !l.path.contains("Containers/") { leftoverBytes += AppLeftovers.allocatedSize(l.path) } }
        let leftoverSizeTime = Date().timeIntervalSince(t)
        t = Date()
        var appBytes = 0.0
        for app in scan.apps { appBytes += AppLeftovers.allocatedSize(app.path) }
        let sizeTime = Date().timeIntervalSince(t)
        print(String(format: "LIVE: %d apps listed in %.3fs; index %.3fs; discovery for all %.4fs (%.2f ms/app); leftover sizes (no containers) %.2fs (%.0f MB); app sizes %.2fs serial (%.0f MB)",
                     scan.apps.count, scanTime, indexTime, discoverTime, discoverTime * 1000 / Double(max(1, scan.apps.count)),
                     leftoverSizeTime, leftoverBytes / 1e6, sizeTime, appBytes / 1e6))
        for app in scan.apps.sorted(by: { $0.name < $1.name }) {
            print("LIVE: \(app.name) [\(app.bundleId)] \(app.source)\(app.uninstallName.isEmpty ? "" : ":" + app.uninstallName)")
            for l in all[app.id] ?? [] { print("LIVE:     \(l.kind): \(l.path)\(l.isSystem ? " (system)" : "")") }
        }
    }
}
