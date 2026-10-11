import AppKit
import Foundation
import Observation

struct DiskEntry: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var size: Double
    var isDir: Bool?
    var insight: Bool?
    var scanStatus: String?
    var id: String { path }

    /// `mo analyze`'s quick overview stops early on big folders and marks them partial;
    /// show those as a lower bound instead of an exact size.
    var isPartial: Bool { scanStatus == "partial" }
    var sizeLabel: String { (isPartial ? "≥ " : "") + Fmt.bytes(size) }
}

private struct AnalyzeResult: Decodable {
    var entries: [DiskEntry]?
}

struct DiskLevel: Equatable {
    var path: String?          // nil = whole-disk overview
    var title: String
    var entries: [DiskEntry]
    var insights: [DiskEntry]
    var total: Double { entries.reduce(0) { $0 + $1.size } }
}

/// One scan's result, cached by path. The title isn't cached: the same folder can be
/// reached under different names ("Downloads", or an insight like "Old Downloads (90d+)").
struct CachedScan: Equatable {
    var entries: [DiskEntry]
    var insights: [DiskEntry]
}

/// Navigation state for Analyze, kept free of I/O so it can be unit tested.
/// Every navigation bumps `token`; a scan that finishes after a newer navigation
/// started is dropped, so quick clicks can't stack impossible levels and the
/// "scanning" label always belongs to the newest scan.
struct AnalyzeNavigator {
    struct Request: Equatable {
        var token: Int
        var path: String?
        var title: String
        var push: Bool
    }

    private(set) var stack: [DiskLevel] = []
    private(set) var cache: [String: CachedScan] = [:]
    /// Title of the folder being scanned, nil when idle.
    private(set) var scanning: String?
    private(set) var token = 0

    static func key(_ path: String?) -> String { path ?? "/" }

    /// Starts showing `path` under `title`. Returns the scan to run, or nil when the
    /// level came from the cache (any scan still in flight is abandoned either way).
    mutating func open(_ path: String?, title: String, push: Bool, force: Bool = false) -> Request? {
        token += 1
        if !force, let hit = cache[Self.key(path)] {
            scanning = nil
            place(DiskLevel(path: path, title: title, entries: hit.entries, insights: hit.insights), push: push)
            return nil
        }
        scanning = title
        return Request(token: token, path: path, title: title, push: push)
    }

    /// Applies a finished scan. Returns false, changing nothing, when it is stale.
    @discardableResult
    mutating func complete(_ request: Request, entries: [DiskEntry], insights: [DiskEntry]) -> Bool {
        guard request.token == token else { return false }
        scanning = nil
        cache[Self.key(request.path)] = CachedScan(entries: entries, insights: insights)
        place(DiskLevel(path: request.path, title: request.title, entries: entries, insights: insights), push: request.push)
        return true
    }

    /// Goes back to the breadcrumb at `index`. Returns a rescan when that level's
    /// sizes were invalidated by a trash further down.
    mutating func pop(to index: Int) -> Request? {
        guard stack.indices.contains(index) else { return nil }
        token += 1
        scanning = nil
        stack = Array(stack.prefix(index + 1))
        if let cur = stack.last, cache[Self.key(cur.path)] == nil {
            return open(cur.path, title: cur.title, push: false, force: true)
        }
        return nil
    }

    /// Drops cached levels whose sizes include `path` (its ancestors) or lie inside it.
    mutating func invalidate(trashed path: String) {
        cache = cache.filter { key, _ in
            key != "/" && !path.hasPrefix(key + "/") && key != path && !key.hasPrefix(path + "/")
        }
    }

    private mutating func place(_ level: DiskLevel, push: Bool) {
        if push, stack.last?.path != level.path {
            stack.append(level)
        } else if let i = stack.firstIndex(where: { $0.path == level.path }) {
            stack[i] = level
            stack = Array(stack.prefix(i + 1))
        } else {
            stack = [level]
        }
    }

    /// Turns `mo analyze --json` output into the map's entries and the overview's insights.
    static func parse(_ data: Data, overview: Bool) -> (entries: [DiskEntry], insights: [DiskEntry]) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = (try? decoder.decode(AnalyzeResult.self, from: data))
        var entries = (result?.entries ?? []).filter { $0.size > 0 }
        var insights: [DiskEntry] = []
        if overview {
            // The overview mixes top-level areas with "insights" and nested areas
            // (User Library inside Home); keep only non-overlapping areas in the map.
            insights = entries.filter { $0.insight == true }
            let areas = entries.filter { $0.insight != true }
            entries = areas.filter { e in !areas.contains { $0.path != e.path && e.path.hasPrefix($0.path + "/") } }
        }
        return (entries.sorted { $0.size > $1.size }, insights)
    }
}

@Observable
@MainActor
final class AnalyzeModel {
    private(set) var nav = AnalyzeNavigator()
    /// The one scan in flight; replaced on every navigation.
    private var job: Task<Void, Never>?

    var stack: [DiskLevel] { nav.stack }
    var scanning: String? { nav.scanning }
    var current: DiskLevel? { nav.stack.last }

    func open(_ path: String?, title: String, push: Bool, force: Bool = false) {
        run(nav.open(path, title: title, push: push, force: force))
    }

    func pop(to index: Int) {
        run(nav.pop(to: index))
    }

    func rescan() {
        if let cur = current { open(cur.path, title: cur.title, push: false, force: true) }
    }

    private func run(_ request: AnalyzeNavigator.Request?) {
        job?.cancel()
        job = nil
        guard let request else { return }
        job = Task {
            let data = await Shell.moJSON(request.path.map { ["analyze", "--json", $0] } ?? ["analyze", "--json"])
            guard !Task.isCancelled else { return }
            let parsed = AnalyzeNavigator.parse(data, overview: request.path == nil)
            nav.complete(request, entries: parsed.entries, insights: parsed.insights)
        }
    }

    func trash(_ entry: DiskEntry) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
        } catch {
            _ = Dialogs.run(NSAlert(error: error))
            return
        }
        // Sizes of every ancestor changed; drop cached levels and rescan the current one.
        nav.invalidate(trashed: entry.path)
        rescan()
    }
}
