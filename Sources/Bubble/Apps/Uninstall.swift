import AppKit
import Observation
import SwiftUI

struct AppInfo: Identifiable, Hashable, Sendable {
    var name: String
    var bundleId: String
    var source: String          // "Homebrew", "App Store" or "App"
    var uninstallName: String   // the Homebrew cask token, or "" when no cask manages the app
    var path: String
    var sizeText: String
    var bytes: Double
    var version: String
    var lastUsed: Date?
    var added: Date?
    var menuBarOnly: Bool
    /// False until `bytes` has been measured.
    var sized = true
    var id: String { path }

    var isAppStore: Bool { FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") }
    var sparkleFeed: String? { (Bundle(path: path)?.infoDictionary?["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var isBrew: Bool { source == "Homebrew" && !uninstallName.isEmpty }
    var identity: AppIdentity { AppIdentity(name: name, path: path, bundleId: bundleId) }

    var updateChannel: String {
        if isAppStore { return "App Store" }
        if isBrew { return "Homebrew" }
        if sparkleFeed != nil { return "Sparkle" }
        return "Website"
    }
}

/// The outcome of the last removal, shown as a banner above the list.
struct RemovalSummary: Equatable {
    var removed: [String] = []
    var freed: Double = 0
    var failures: [String] = []
    var viaHomebrew: [String] = []
    var movedToTrash = false
    /// Some app data was left because Bubble lacks Full Disk Access.
    var needsFullDiskAccess = false
}

/// App sizes from earlier runs, reused while an app's Info.plist is unchanged so the list
/// opens sorted instead of reshuffling while sizes come in.
enum AppSizeCache {
    static let key = "appSizeCache"
    static func load() -> [String: [Double]] { (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]) ?? [:] }
    static func save(_ apps: [AppInfo]) async {
        let sized = apps.filter(\.sized).map { ($0.path, $0.bytes) }
        let dict = await Task.detached(priority: .utility) {
            Dictionary(sized.map { ($0.0, [$0.1, AppScanner.stamp($0.0)]) }, uniquingKeysWith: { a, _ in a })
        }.value
        UserDefaults.standard.set(dict, forKey: key)
    }
}

@Observable
@MainActor
final class UninstallModel {
    enum Sort: String, CaseIterable { case name = "Name", size = "App size", lastUsed = "Last Used", installed = "Installed" }
    struct Progress: Equatable { var name: String; var index: Int; var total: Int; var waitingForAdmin = false }

    var apps: [AppInfo] = []
    var loading = false
    var sizing = false
    var sort: Sort = .size
    var ascending = false
    var search = ""
    var selected: Set<String> = []
    var expanded: String?
    /// Every app's leftovers, found by bundle id and exact name. Sizes fill in later.
    var leftovers: [String: [Leftover]] = [:]
    /// Apps whose leftovers are being measured (shows a spinner in the row).
    var sizingLeftovers: Set<String> = []
    var running: Set<String> = []
    var removing = false
    var progress: Progress?
    /// Rows with a spinner while their app is removed.
    var removingIds: Set<String> = []
    var summary: RemovalSummary?

    @ObservationIgnored let roots: AppRoots
    @ObservationIgnored var remover: AppRemover
    /// Every bundle in the app folders, protected ones included, so their files are never
    /// claimed by another app.
    @ObservationIgnored private(set) var identities: [AppIdentity] = []
    @ObservationIgnored private var generation = 0
    /// Without Full Disk Access, Containers and Group Containers are only probed by exact
    /// path and never measured, so macOS never asks "access data from other apps".
    @ObservationIgnored private(set) var fullDiskAccess = false
    @ObservationIgnored let checkFullDiskAccess: @Sendable () -> Bool
    /// Where removed apps are counted for the menu bar's Uninstalled total.
    @ObservationIgnored let historyDefaults: UserDefaults

    init(roots: AppRoots = .live, remover: AppRemover? = nil,
         checkFullDiskAccess: @escaping @Sendable () -> Bool = { SystemSettings.hasFullDiskAccess },
         historyDefaults: UserDefaults = .standard) {
        self.roots = roots
        self.remover = remover ?? AppRemover(roots: roots)
        self.checkFullDiskAccess = checkFullDiskAccess
        self.historyDefaults = historyDefaults
    }

    var visible: [AppInfo] {
        let filtered = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let sorted: [AppInfo]
        switch sort {
        case .name: sorted = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: sorted = filtered.sorted { $0.bytes < $1.bytes }
        case .lastUsed: sorted = filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .installed: sorted = filtered.sorted { ($0.added ?? .distantPast) < ($1.added ?? .distantPast) }
        }
        return ascending ? sorted : sorted.reversed()
    }

    var selectedApps: [AppInfo] { apps.filter { selected.contains($0.id) } }

    func setSort(_ s: Sort) {
        if sort == s { ascending.toggle() } else { sort = s; ascending = s == .name }
    }

    // MARK: Listing

    /// Lists apps natively: names, ids and leftover paths right away, then sizes off the
    /// main actor, a few at a time.
    func load() async {
        guard !removing else { return }
        generation += 1
        let gen = generation
        loading = true
        let roots = roots
        let cache = AppSizeCache.load()
        let check = checkFullDiskAccess
        let (scan, found, fda) = await Task.detached(priority: .userInitiated) {
            let fda = check()
            let scan = AppScanner.scan(roots, cache: cache)
            let index = LeftoverIndex.read(roots, fullDiskAccess: fda)
            var found: [String: [Leftover]] = [:]
            for app in scan.apps {
                found[app.id] = AppLeftovers.discover(app.identity, others: scan.identities, index: index, roots: roots)
            }
            return (scan, found, fda)
        }.value
        guard gen == generation else { return }
        fullDiskAccess = fda

        // Keep sizes measured earlier this session.
        let old = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var fresh = scan.apps
        for i in fresh.indices where !fresh[i].sized {
            if let o = old[fresh[i].path], o.sized, o.version == fresh[i].version {
                fresh[i].bytes = o.bytes
                fresh[i].sized = true
            }
        }
        apps = fresh
        identities = scan.identities
        mergeLeftovers(found)
        selected = selected.filter { id in apps.contains { $0.id == id } }
        refreshRunning()
        loading = false

        if !scan.unresolvedCasks.isEmpty { await resolveCasksWithBrew() }
        await sizeApps(gen)
        guard gen == generation else { return }
        await AppSizeCache.save(apps)
        await prefetchLeftoverSizes()
    }

    /// Replaces the leftover lists, keeping sizes already measured for the same paths.
    private func mergeLeftovers(_ found: [String: [Leftover]]) {
        var merged: [String: [Leftover]] = [:]
        for (id, items) in found {
            let known = Dictionary((leftovers[id] ?? []).map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            merged[id] = items.map { item in
                var l = item
                l.bytes = known[l.path] ?? nil
                l.sizeUnknown = !fullDiskAccess && l.isContainer
                return l
            }
        }
        leftovers = merged
    }

    /// Casks without an app symlink in the Caskroom: ask Homebrew once which apps they own.
    private func resolveCasksWithBrew() async {
        guard let brew = Shell.brew else { return }
        let data = await AppRemover.runTool(brew, ["info", "--json=v2", "--installed", "--cask"],
                                            env: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 30).output
        let map = AppLeftovers.parseBrewInfoApps(Data(data.utf8))
        guard !map.isEmpty else { return }
        for i in apps.indices where apps[i].uninstallName.isEmpty {
            if let token = map[Safety.normalize(apps[i].path)] {
                apps[i].source = "Homebrew"
                apps[i].uninstallName = token
            }
        }
    }

    /// Measures unsized apps four at a time, publishing results in batches.
    private func sizeApps(_ gen: Int) async {
        let todo = apps.filter { !$0.sized }.map(\.path)
        guard !todo.isEmpty else { return }
        sizing = true
        defer { sizing = false }
        var buffer: [String: Double] = [:]
        var lastFlush = Date()
        await withTaskGroup(of: (String, Double).self) { group in
            var next = 0
            for _ in 0..<min(4, todo.count) {
                let p = todo[next]; next += 1
                group.addTask(priority: .utility) { (p, AppLeftovers.allocatedSize(p)) }
            }
            for await (path, bytes) in group {
                buffer[path] = bytes
                if next < todo.count {
                    let p = todo[next]; next += 1
                    group.addTask(priority: .utility) { (p, AppLeftovers.allocatedSize(p)) }
                }
                if Date().timeIntervalSince(lastFlush) > 0.3, gen == generation {
                    applySizes(buffer)
                    buffer = [:]
                    lastFlush = Date()
                }
            }
        }
        if gen == generation { applySizes(buffer) }
    }

    private func applySizes(_ sizes: [String: Double]) {
        guard !sizes.isEmpty else { return }
        for i in apps.indices {
            if let b = sizes[apps[i].path] { apps[i].bytes = b; apps[i].sized = true }
        }
    }

    /// Sizes the leftovers of the first rows in the background, at low priority.
    private func prefetchLeftoverSizes() async {
        for app in visible.prefix(12) {
            await sizeLeftovers(app, userInitiated: false)
        }
    }

    /// Measures the app's unsized leftovers. Containers are never read without Full Disk
    /// Access (they're marked "size unknown" instead).
    func sizeLeftovers(_ app: AppInfo, userInitiated: Bool) async {
        let todo = (leftovers[app.id] ?? []).filter { $0.bytes == nil && !$0.sizeUnknown }.map(\.path)
        guard !todo.isEmpty, !sizingLeftovers.contains(app.id) else { return }
        if userInitiated { sizingLeftovers.insert(app.id) }
        defer { if userInitiated { sizingLeftovers.remove(app.id) } }
        let sizes = await Task.detached(priority: userInitiated ? .userInitiated : .utility) {
            Dictionary(todo.map { ($0, AppLeftovers.allocatedSize($0)) }, uniquingKeysWith: { a, _ in a })
        }.value
        guard var items = leftovers[app.id] else { return }
        for i in items.indices { if let b = sizes[items[i].path] { items[i].bytes = b } }
        leftovers[app.id] = items
    }

    func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func toggleExpanded(_ app: AppInfo) {
        expanded = expanded == app.id ? nil : app.id
        if expanded != nil { Task { await sizeLeftovers(app, userInitiated: true) } }
    }

    func toggleSelected(_ app: AppInfo) {
        guard !removing else { return }
        if selected.contains(app.id) { selected.remove(app.id) } else {
            selected.insert(app.id)
            Task { await sizeLeftovers(app, userInitiated: true) }
        }
    }

    /// The app plus its leftovers, once everything measurable is measured.
    func leftoverBytes(_ app: AppInfo) -> Double? {
        guard app.sized, let items = leftovers[app.id] else { return nil }
        var total = app.bytes
        for l in items where !l.sizeUnknown {
            guard let b = l.bytes else { return nil }
            total += b
        }
        return total
    }

    // MARK: Removal

    func removeSelected() async {
        let selection = selectedApps
        guard !selection.isEmpty, !removing else { return }
        removing = true
        summary = nil
        generation += 1  // a load in flight must not overwrite the list mid-removal
        let roots = roots
        let identities = identities
        let known = leftovers
        let fda = fullDiskAccess
        let index = await Task.detached { LeftoverIndex.read(roots, fullDiskAccess: fda) }.value

        var results: [AppRemovalResult] = []
        var pending: [PendingAdmin] = []
        for (i, app) in selection.enumerated() {
            progress = Progress(name: app.name, index: i + 1, total: selection.count)
            removingIds.insert(app.id)
            // Fresh discovery right before removing, with sizes for the result banner.
            let items = await Task.detached(priority: .userInitiated) { () -> [RemovalItem] in
                let sizes = Dictionary((known[app.id] ?? []).compactMap { l in l.bytes.map { (l.path, $0) } }, uniquingKeysWith: { a, _ in a })
                let found = AppLeftovers.discover(app.identity, others: identities, index: index, roots: roots)
                let appItem = RemovalItem(path: app.path, bytes: app.sized ? app.bytes : AppLeftovers.allocatedSize(app.path), isApp: true)
                return [appItem] + found.map { l in
                    // Never read a container's contents without Full Disk Access.
                    let bytes = sizes[l.path] ?? (!fda && l.isContainer ? 0 : AppLeftovers.allocatedSize(l.path))
                    return RemovalItem(path: l.path, bytes: bytes, isSystem: l.isSystem)
                }
            }.value
            let (result, needAdmin) = await remover.remove(app, items: items, owner: i)
            results.append(result)
            pending += needAdmin
            if needAdmin.isEmpty { removingIds.remove(app.id) }
        }

        if !pending.isEmpty {
            let owners = Array(Set(pending.map(\.owner))).sorted()
            progress = Progress(name: owners.count == 1 ? selection[owners[0]].name : "\(owners.count) apps",
                                index: selection.count, total: selection.count, waitingForAdmin: true)
            let prompt = owners.count == 1
                ? "Bubble needs permission to remove “\(selection[owners[0]].name)” and its system files."
                : "Bubble needs permission to remove \(owners.count) apps and their system files."
            let outcome = await remover.removeWithAdmin(pending, prompt: prompt)
            var notRemoved: [Int: Int] = [:]
            for p in pending {
                if outcome.removed.contains(p.item.path) {
                    results[p.owner].freed += p.item.bytes
                } else {
                    notRemoved[p.owner, default: 0] += 1
                }
            }
            for (owner, count) in notRemoved.sorted(by: { $0.key < $1.key }) {
                let why = outcome.cancelled ? "permission was cancelled" : outcome.error.map { "the admin step failed: \($0)" } ?? "they couldn't be moved"
                results[owner].problems.append("\(selection[owner].name): \(count) item\(count == 1 ? "" : "s") needing admin rights \(count == 1 ? "was" : "were") not removed (\(why)).")
            }
        }
        for i in results.indices { results[i].removed = !AppLeftovers.exists(results[i].app.path) }

        var s = RemovalSummary()
        for r in results {
            if r.removed { s.removed.append(r.app.name) }
            if r.viaHomebrew { s.viaHomebrew.append(r.app.name) }
            if r.freed > 0, !r.viaHomebrew { s.movedToTrash = true }
            s.freed += r.freed
            s.failures += r.problems
            if !r.blockedByPrivacy.isEmpty {
                let n = r.blockedByPrivacy.count
                s.failures.append("\(r.app.name): \(n) item\(n == 1 ? "" : "s") of app data need\(n == 1 ? "s" : "") Full Disk Access to remove.")
                s.needsFullDiskAccess = true
            }
        }
        summary = s
        // Mole's history never sees native removals, so Bubble counts them itself.
        HistoryTotals.recordUninstall(count: s.removed.count, defaults: historyDefaults)

        let gone = Set(results.filter(\.removed).map(\.app.id))
        apps.removeAll { gone.contains($0.id) }
        self.identities.removeAll { gone.contains($0.path) }
        selected.subtract(gone)
        if let e = expanded, gone.contains(e) { expanded = nil }
        for id in gone { leftovers[id] = nil }
        removingIds = []
        progress = nil
        removing = false
        refreshRunning()
        // Re-find leftovers for what's left (some may have been partly removed).
        let remaining = apps
        let ids = self.identities
        let found = await Task.detached {
            let index = LeftoverIndex.read(roots, fullDiskAccess: fda)
            return Dictionary(remaining.map { ($0.id, AppLeftovers.discover($0.identity, others: ids, index: index, roots: roots)) },
                              uniquingKeysWith: { a, _ in a })
        }.value
        mergeLeftovers(found)
    }
}

// MARK: - View

struct UninstallList: View {
    @Bindable var model: UninstallModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            if let s = model.summary {
                summaryBanner(s)
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.m)
                    .transition(.opacity)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s) {
                        Text("\(model.apps.count) apps").font(.ui(.body, .semibold))
                        Text("\(Fmt.bytes(model.apps.reduce(0) { $0 + $1.bytes })) in total")
                            .font(.num(.secondary)).foregroundStyle(Palette.secondary)
                            .contentTransition(.numericText())
                        if model.loading || model.sizing { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                    ForEach(model.visible) { app in row(app) }
                }
                .padding(.bottom, Space.l)
            }
            if !model.selected.isEmpty || model.removing {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(model.selected.isEmpty && !model.removing)
        .motion(model.summary)
        .confirmationDialog("Remove \(model.selectedApps.count) app\(model.selectedApps.count == 1 ? "" : "s") and their data?", isPresented: $confirm) {
            Button("Remove", role: .destructive) {
                Task { await model.removeSelected() }
            }
        } message: {
            Text(model.selectedApps.map(\.name).joined(separator: ", ")
                 + "\n\nThe apps and their leftovers go to the Trash. Homebrew apps are removed with brew uninstall --zap. Open apps are asked to quit first. macOS asks for your password or Touch ID if system files are involved.")
        }
    }

    // MARK: Result banner

    private func summaryBanner(_ s: RemovalSummary) -> some View {
        let ok = !s.removed.isEmpty
        let title: String
        if ok {
            let what = s.removed.count == 1 ? s.removed[0] : "\(s.removed.count) apps"
            title = s.freed > 0 ? "Removed \(what), freed \(Fmt.bytes(s.freed))" : "Removed \(what)"
        } else {
            title = "Nothing was removed"
        }
        var detail: [String] = []
        if s.movedToTrash { detail.append("Moved to Trash.") }
        if !s.viaHomebrew.isEmpty { detail.append("Homebrew removed \(s.viaHomebrew.joined(separator: ", ")).") }
        return HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: ok ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(ok ? Palette.green : Palette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(.body, .semibold))
                if !detail.isEmpty {
                    Text(detail.joined(separator: " ")).font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                }
                ForEach(s.failures, id: \.self) { f in
                    Label(f, systemImage: "exclamationmark.triangle")
                        .font(.ui(.secondary)).foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if s.needsFullDiskAccess {
                LinkButton(title: "Open Settings", color: Palette.accent) { SystemSettings.openFullDiskAccess() }
                    .font(.ui(.secondary, .medium))
                    .help("Give Bubble Full Disk Access, then remove the app's leftover data")
            }
            if s.movedToTrash {
                LinkButton(title: "Show in Trash", color: Palette.accent) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.roots.trash, isDirectory: true))
                }
                .font(.ui(.secondary, .medium))
            }
            IconButton(systemName: "xmark", label: "Dismiss") { model.summary = nil }
        }
        .padding(Space.m)
        .panel(radius: Radius.row, fill: ok ? Palette.green.opacity(0.08) : Palette.card,
               stroke: ok ? Palette.green.opacity(0.25) : Palette.cardStroke)
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows

    private func row(_ app: AppInfo) -> some View {
        let open = model.expanded == app.id
        let selected = model.selected.contains(app.id)
        let busy = model.removingIds.contains(app.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Button { model.toggleExpanded(app) } label: {
                    HStack(spacing: Space.m) {
                        AppIcon(path: app.path)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.ui(.body, .semibold))
                            HStack(spacing: Space.m) {
                                if !app.version.isEmpty { Text(app.version).foregroundStyle(Palette.secondary) }
                                if app.sized {
                                    Text(Fmt.bytes(app.bytes)).foregroundStyle(Palette.secondary)
                                } else {
                                    Text("Sizing…").foregroundStyle(Palette.tertiary)
                                }
                                activity(app)
                            }
                            .font(.num(.secondary))
                        }
                        Spacer()
                        if busy {
                            Text("Removing…").font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                        } else if open || selected, let lb = model.leftoverBytes(app) {
                            Text("Removes \(Fmt.bytes(lb))").font(.num(.secondary)).lineLimit(1).fixedSize().foregroundStyle(.white.opacity(0.8))
                        } else if model.sizingLeftovers.contains(app.id) {
                            ProgressView().controlSize(.small)
                        }
                        if open {
                            Image(systemName: "chevron.up").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.quiet)
                .accessibilityLabel("\(app.name), \(app.sized ? Fmt.bytes(app.bytes) : "size not measured yet")")
                .accessibilityHint(open ? "Hides the files that would be removed" : "Shows the files that would be removed")
                if busy {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                        .accessibilityLabel("Removing \(app.name)")
                } else {
                    CheckBox(on: selected, tint: Palette.accent, label: "Remove \(app.name)") { model.toggleSelected(app) }
                        .disabled(model.removing)
                }
            }
            .padding(.horizontal, Space.l).padding(.vertical, 9)
            .rowHover()
            .contextMenu {
                Button("Reveal in Finder") { Finder.reveal(app.path) }
            }

            if open { details(app) }
        }
        .background(open ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
        .padding(.horizontal, Space.s)
        .opacity(busy ? 0.6 : 1)
        .motion(open)
    }

    private func details(_ app: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Will be removed").font(.ui(.secondary, .semibold)).foregroundStyle(Palette.secondary)
            if let items = model.leftovers[app.id] {
                fileRow(kind: "Application", path: app.path, bytes: app.sized ? app.bytes : nil)
                ForEach(items) { l in fileRow(kind: l.kind, path: l.path, bytes: l.bytes, system: l.isSystem, unknown: l.sizeUnknown) }
                if items.isEmpty {
                    Text("No settings or caches found for this app.").font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                }
                if app.isBrew {
                    Text("Homebrew also removes the files its cask lists (brew uninstall --zap).")
                        .font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                }
            } else {
                ProgressLine(text: "Finding leftovers")
            }
        }
        .padding(.horizontal, Space.l).padding(.bottom, Space.m).padding(.leading, 44)
        .transition(.opacity)
    }

    private func fileRow(kind: String, path: String, bytes: Double?, system: Bool = false, unknown: Bool = false) -> some View {
        HStack(spacing: Space.l) {
            Text(kind).font(.ui(.secondary, .semibold)).frame(width: 120, alignment: .leading)
            Text(Fmt.abbreviate(path)).font(.path()).foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
            if system {
                Image(systemName: "lock.fill").font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                    .help("System file: macOS asks for permission to remove it")
                    .accessibilityLabel("Needs admin rights")
            }
            Spacer()
            if unknown {
                Text("size unknown").font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                    .help("Measuring another app's data needs Full Disk Access")
            } else if let bytes {
                Text(Fmt.bytes(bytes)).font(.num(.secondary)).foregroundStyle(Palette.secondary)
            } else {
                Text("…").font(.num(.secondary)).foregroundStyle(Palette.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal(path) }
        }
    }

    @ViewBuilder
    private func activity(_ app: AppInfo) -> some View {
        if model.running.contains(app.bundleId) {
            Text("active now").foregroundStyle(Palette.green)
        } else if app.menuBarOnly {
            Text("Menu bar app").foregroundStyle(Palette.secondary)
        } else if let rel = Fmt.relative(app.lastUsed) {
            Text("opened \(rel)").foregroundStyle(Palette.secondary)
        } else {
            Text("never opened").foregroundStyle(Palette.tertiary)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        let apps = model.selectedApps
        let total = apps.reduce(0) { $0 + (model.leftoverBytes($1) ?? $1.bytes) }
        return HStack(spacing: Space.m) {
            HStack(spacing: -6) {
                ForEach(apps.prefix(5)) { AppIcon(path: $0.path, size: 28) }
            }
            if let p = model.progress {
                ProgressView().controlSize(.small)
                Text(p.waitingForAdmin ? "Waiting for permission to remove system files…"
                                       : "Removing \(p.name)… \(p.index) of \(p.total)")
                    .font(.num(.body)).lineLimit(1)
                    .contentTransition(.opacity)
                Spacer()
            } else {
                Text("\(apps.count) app\(apps.count == 1 ? "" : "s"), \(Fmt.bytes(total))").font(.num(.body))
                    .contentTransition(.numericText())
                LinkButton(title: "Clear selection", color: Palette.accent) { model.selected = [] }
                Spacer()
                PillButton(title: "Remove \(apps.count) app\(apps.count == 1 ? "" : "s")", width: 240) { confirm = true }
            }
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().overlay(Palette.cardStroke) }
        .motion(model.progress)
    }
}
