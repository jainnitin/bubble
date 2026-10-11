import AppKit
import Foundation
import Observation
import SwiftUI

struct AppUpdate: Identifiable {
    var app: AppInfo
    var latest: String?
    var link: URL?
    /// Homebrew only: `installed_versions` from `brew outdated --json=v2`.
    var installedVersions: [String] = []
    var id: String { app.id }
    /// Newer than both the app's own version and every version Homebrew installed.
    /// Apps that update themselves are newer than Homebrew's record, so with
    /// `--greedy` they'd otherwise show as outdated forever.
    var hasUpdate: Bool {
        guard let latest else { return false }
        let known = ([app.version] + installedVersions).filter { !VersionCompare.parts($0).isEmpty }
        return !known.isEmpty && known.allSatisfy { VersionCompare.isNewer(latest, than: $0) }
    }
}

@Observable
@MainActor
final class UpdatesModel {
    var updates: [AppUpdate] = []
    var checking = false
    var log: [String] = []
    var upgrading: String?
    /// Shown in the update log when Bubble refused to run an upgrade.
    var upgradeError: String?
    /// True once a check has run this session (checks only start when the
    /// Updates tab is visible, or from Refresh).
    var hasChecked = false
    var ignored: [String: String] = (UserDefaults.standard.dictionary(forKey: "ignoredUpdates") as? [String: String]) ?? [:]

    func check(_ apps: [AppInfo]) async {
        guard !checking else { return }
        checking = true
        hasChecked = true
        defer { checking = false }
        let brewLatest = await brewOutdated()
        var result: [AppUpdate] = []
        await withTaskGroup(of: AppUpdate.self) { group in
            for app in apps {
                group.addTask {
                    if app.isBrew {
                        guard let cask = brewLatest[app.uninstallName.lowercased()] else {
                            return AppUpdate(app: app, latest: app.version, link: nil)
                        }
                        return AppUpdate(app: app, latest: VersionCompare.display(cask.current), link: nil,
                                         installedVersions: cask.installed)
                    }
                    if app.isAppStore { return await Self.appStore(app) }
                    if let feed = app.sparkleFeed { return await Self.sparkle(app, feed: feed) }
                    return AppUpdate(app: app, latest: nil, link: nil)
                }
            }
            for await u in group { result.append(u) }
        }
        updates = result.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func isIgnored(_ u: AppUpdate) -> Bool { u.latest != nil && ignored[u.app.bundleId] == u.latest }

    func ignore(_ u: AppUpdate) {
        ignored[u.app.bundleId] = u.latest
        UserDefaults.standard.set(ignored, forKey: "ignoredUpdates")
    }

    func upgradeBrew(_ u: AppUpdate) async {
        guard let brew = Shell.brew else { return }
        log = []
        upgradeError = nil
        let token = u.app.uninstallName
        guard Safety.isSafeCommandArgument(token) else {
            upgradeError = "The Homebrew name \"\(token)\" starts with \"-\" or is empty, so brew would read it as an option. Nothing was updated."
            return
        }
        upgrading = u.app.id
        for await line in Shell.lines(brew, ["upgrade", "--cask", u.app.uninstallName]) { log.append(line) }
        upgrading = nil
    }

    struct BrewCask: Equatable { var current: String; var installed: [String] }

    private func brewOutdated() async -> [String: BrewCask] {
        guard let brew = Shell.brew else { return [:] }
        let data = await Shell.output(brew, ["outdated", "--cask", "--greedy", "--json=v2"])
        return Self.parseBrewOutdated(data)
    }

    /// `brew outdated --cask --json=v2`: {"casks": [{"name", "installed_versions", "current_version"}]}.
    nonisolated static func parseBrewOutdated(_ data: Data) -> [String: BrewCask] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]] else { return [:] }
        var out: [String: BrewCask] = [:]
        for c in casks {
            guard let name = c["name"] as? String, let v = c["current_version"] as? String else { continue }
            let installed = (c["installed_versions"] as? [String]) ?? []
            out[name.lowercased()] = BrewCask(current: v, installed: installed)
        }
        return out
    }

    nonisolated private static func appStore(_ app: AppInfo) async -> AppUpdate {
        guard let url = appStoreLookupURL(bundleId: app.bundleId),
              let (data, _) = try? await UpdateNetwork.session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (obj["results"] as? [[String: Any]])?.first
        else { return AppUpdate(app: app, latest: nil, link: nil) }
        let link = (r["trackViewUrl"] as? String)
            .flatMap { URL(string: $0.replacingOccurrences(of: "https://", with: "macappstore://")) }
            .flatMap { Safety.isAllowedExternalURL($0) ? $0 : nil }
        return AppUpdate(app: app, latest: r["version"] as? String, link: link)
    }

    nonisolated private static func sparkle(_ app: AppInfo, feed: String) async -> AppUpdate {
        // https only: a plain-http feed could be tampered with in transit.
        guard let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host != nil,
              let (data, _) = try? await UpdateNetwork.session.data(from: url) else {
            return AppUpdate(app: app, latest: nil, link: nil)
        }
        let parser = AppcastParser(data: data)
        let best = parser.items.max { VersionCompare.isNewer($1.version, than: $0.version) }
        let link = best?.url.flatMap { Safety.isAllowedExternalURL($0) ? $0 : nil }
        return AppUpdate(app: app, latest: best?.version, link: link)
    }

    /// iTunes lookup URL with the bundle ID percent-encoded as a query value.
    nonisolated static func appStoreLookupURL(bundleId: String) -> URL? {
        guard !bundleId.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "itunes.apple.com"
        c.path = "/lookup"
        c.queryItems = [URLQueryItem(name: "bundleId", value: bundleId), URLQueryItem(name: "entity", value: "macSoftware")]
        // URLQueryItem leaves "&", "=" and "+" alone; encode them so a bundle ID can't add parameters.
        c.percentEncodedQueryItems = c.queryItems?.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: UpdateNetwork.queryValueAllowed))
        }
        return c.url
    }
}

/// Minimal Sparkle appcast reader: enclosure url + sparkle:shortVersionString / sparkle:version.
final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item { var version: String; var url: URL? }
    private(set) var items: [Item] = []
    private var shortVersion: String?
    private var version: String?
    private var enclosureURL: URL?
    private var text = ""

    init(data: Data) {
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { shortVersion = nil; version = nil; enclosureURL = nil }
        if name == "enclosure" {
            enclosureURL = attributes["url"].flatMap(URL.init(string:))
            shortVersion = attributes["sparkle:shortVersionString"] ?? shortVersion
            version = attributes["sparkle:version"] ?? version
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:shortVersionString": shortVersion = t
        case "sparkle:version": version = t
        case "item":
            if let v = shortVersion ?? version { items.append(Item(version: v, url: enclosureURL)) }
        default: break
        }
    }
}

/// Compares version strings numerically ("1.10" is newer than "1.9"). Used for app
/// updates and for Mole's minimum version.
enum VersionCompare {
    /// True only when both versions have numeric parts and `a` is strictly newer.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        guard !pa.isEmpty, !pb.isEmpty else { return false }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Numeric components of a version. Everything after "," is dropped (Homebrew
    /// cask versions carry build ids: "2.31226.1,8576520051…"), as is everything from
    /// the first component that doesn't start with a digit ("1.2-beta3", "1.0 (45)").
    /// A component like "3b4" keeps only its leading digits.
    static func parts(_ v: String) -> [Int] {
        var s = Substring(v.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        var out: [Int] = []
        for comp in s.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " || $0 == "+" }) {
            let digits = comp.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { break }
            out.append(n)
            if digits.count != comp.count { break }
        }
        return out
    }

    /// The version as shown to the user: without a cask build suffix.
    static func display(_ v: String) -> String {
        String(v.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// Network access for update checks: no cookies, no URL cache, a generic
/// User-Agent, https-only redirects.
enum UpdateNetwork {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }()

    static let userAgent = "Mozilla/5.0 (Macintosh)"

    /// `urlQueryAllowed` minus the characters that would end or split a query value.
    static let queryValueAllowed: CharacterSet = {
        var c = CharacterSet.urlQueryAllowed
        c.remove(charactersIn: "&=+?#")
        return c
    }()

    final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }
}

// MARK: - View

struct UpdatesList: View {
    @Bindable var model: UpdatesModel
    let apps: [AppInfo]
    @State private var showLog = false

    var body: some View {
        let pending = model.updates.filter { $0.hasUpdate && !model.isIgnored($0) }
        let inApp = pending.filter { $0.app.isBrew }
        let outside = pending.filter { !$0.app.isBrew }
        let pendingIds = Set(pending.map(\.id))
        let rest = model.updates.filter { !pendingIds.contains($0.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Label("Checking contacts Apple (itunes.apple.com, with App Store apps' bundle IDs), each Sparkle app's update feed, and Homebrew.",
                      systemImage: "network")
                    .font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                if model.checking {
                    ProgressLine(text: "Checking Homebrew, the App Store and Sparkle feeds").padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                } else if !model.hasChecked {
                    LinkButton(title: "Check for updates", color: Palette.accent) { Task { await model.check(apps) } }
                        .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                }
                section("Update in Bubble", inApp)
                section("Finish outside Bubble", outside)
                section("Up to date", rest)
            }
            .padding(.bottom, Space.l)
        }
        .sheet(isPresented: $showLog) {
            RunLogSheet(title: model.upgrading != nil ? "Updating…" : model.upgradeError == nil ? "Done" : "Stopped: nothing was updated",
                        lines: model.log, finished: model.upgrading == nil, notes: model.upgradeError.map { [$0] } ?? []) {
                showLog = false
                Task { await model.check(apps) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AppUpdate]) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title, count: items.count)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ u: AppUpdate) -> some View {
        HStack(spacing: 18) {
            AppIcon(path: u.app.path)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(u.app.name).font(.ui(.body, .semibold))
                    Tag(text: u.app.updateChannel)
                }
                HStack(spacing: 6) {
                    Text(u.app.version.isEmpty ? "?" : u.app.version).foregroundStyle(Palette.secondary)
                    if u.hasUpdate, let latest = u.latest {
                        Image(systemName: "arrow.right").font(.ui(.caption)).foregroundStyle(Palette.accent)
                        Text(latest).foregroundStyle(Palette.accent)
                    } else if u.latest == nil && !u.app.isBrew {
                        Text("· can't check automatically").foregroundStyle(Palette.tertiary)
                    }
                }
                .font(.num(.secondary))
            }
            Spacer()
            if u.hasUpdate && !model.isIgnored(u) {
                LinkButton(title: "Ignore this version") { model.ignore(u) }.font(.ui(.secondary))
                if u.app.isBrew {
                    actionButton(model.upgrading == u.app.id ? "Updating…" : "Update") {
                        showLog = true
                        Task { await model.upgradeBrew(u) }
                    }
                    .disabled(model.upgrading != nil)
                } else if let link = u.link, Safety.isAllowedExternalURL(link) {
                    actionButton(u.app.isAppStore ? "App Store" : "Download") { NSWorkspace.shared.open(link) }
                } else {
                    actionButton("Open app") { NSWorkspace.shared.open(URL(fileURLWithPath: u.app.path)) }
                }
            }
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.s)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(.body, .semibold)).foregroundStyle(Palette.accent)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, Space.l).frame(height: 32)
                .background(Palette.accent.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.quiet)
    }
}
