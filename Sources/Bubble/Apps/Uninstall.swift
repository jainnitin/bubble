import AppKit
import CoreServices
import Observation
import SwiftUI

struct AppInfo: Identifiable, Hashable {
    var name: String
    var bundleId: String
    var source: String          // Mole's label: "Homebrew", "App", …
    var uninstallName: String   // Mole's label (often the Homebrew cask token); NOT passed to `mo uninstall`
    var path: String
    var sizeText: String
    var bytes: Double
    var version: String
    var lastUsed: Date?
    var added: Date?
    var menuBarOnly: Bool
    var id: String { path }
    /// What Bubble passes to `mo uninstall`: the .app folder name without ".app".
    /// Mole matches it exactly (case-insensitive) against folder or display name;
    /// `uninstallName` (e.g. the cask token "claude") can substring-match other apps.
    var moleTerm: String { Safety.moleUninstallTerm(forAppPath: path) }

    var isAppStore: Bool { FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") }
    var sparkleFeed: String? { (Bundle(path: path)?.infoDictionary?["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var isBrew: Bool { source == "Homebrew" }

    var updateChannel: String {
        if isAppStore { return "App Store" }
        if isBrew { return "Homebrew" }
        if sparkleFeed != nil { return "Sparkle" }
        return "Website"
    }
}

struct Leftover: Identifiable, Hashable {
    var path: String
    var sizeText: String
    var id: String { path }

    var kind: String {
        let p = path
        if p.hasSuffix(".app") { return "Application" }
        let map: [(String, String)] = [
            ("/Caches/", "Cache"), ("/var/folders/", "Temporary Cache"), ("/Preferences/", "Preferences"),
            ("/Containers/", "Container"), ("/Group Containers/", "Group Container"), ("/Application Support/", "App Support"),
            ("/Logs/", "Logs"), ("/WebKit/", "WebKit Data"), ("/HTTPStorages/", "HTTP Storage"),
            ("/Saved Application State/", "Saved State"), ("/LaunchAgents/", "Launch Agent"), ("/LaunchDaemons/", "Launch Daemon"),
            ("/Cookies/", "Cookies"), ("/receipts/", "Receipt"),
        ]
        return map.first { p.contains($0.0) }?.1 ?? "Data"
    }
}

@Observable
@MainActor
final class UninstallModel {
    enum Sort: String, CaseIterable { case name = "Name", size = "App size", lastUsed = "Last Used", installed = "Installed" }

    var apps: [AppInfo] = []
    var loading = false
    var sort: Sort = .size
    var ascending = false
    var search = ""
    var selected: Set<String> = []
    var expanded: String?
    var leftovers: [String: [Leftover]] = [:]
    var loadingLeftovers: Set<String> = []
    var running: Set<String> = []
    var removalLog: [String] = []
    var removing = false
    /// Set when an uninstall was refused or declined (e.g. Mole matched different
    /// apps than selected). Show it prominently; nothing was removed.
    var removalError: String?
    /// Prompts Bubble declined with a safe default during the last removal. Show "Skipped: <prompt>".
    var skippedPrompts: [String] = []
    /// Per-app error from the leftovers preview (e.g. Mole matched a different app).
    /// When set, `leftovers[app.id]` is empty.
    var leftoverErrors: [String: String] = [:]
    /// Each `mo uninstall --dry-run` takes ~10s; selecting many apps queues them.
    private let dryRunLimiter = ConcurrencyLimiter(limit: 2)

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

    func load() async {
        loading = true
        defer { loading = false }
        let data = await Shell.moJSON(["uninstall", "--list"])
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        refreshRunning()
        apps = rows.compactMap { r in
            guard let path = r["path"] as? String else { return nil }
            let info = Bundle(path: path)?.infoDictionary
            let md = MDItemCreate(kCFAllocatorDefault, path as CFString)
            let lastUsed = md.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
            let added = md.flatMap { MDItemCopyAttribute($0, kMDItemDateAdded) as? Date }
            let sizeText = r["size"] as? String ?? ""
            return AppInfo(
                name: (r["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{200E}"))),
                bundleId: r["bundle_id"] as? String ?? "",
                source: r["source"] as? String ?? "",
                uninstallName: r["uninstall_name"] as? String ?? "",
                path: path,
                sizeText: sizeText,
                bytes: Fmt.parseSize(sizeText) ?? 0,
                version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String ?? "",
                lastUsed: lastUsed,
                added: added,
                menuBarOnly: (info?["LSUIElement"] as? Bool) == true || (info?["LSUIElement"] as? String) == "1"
            )
        }
        selected = selected.filter { id in apps.contains { $0.id == id } }
    }

    func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func toggleExpanded(_ app: AppInfo) {
        expanded = expanded == app.id ? nil : app.id
        if expanded != nil, leftovers[app.id] == nil { Task { await loadLeftovers(app) } }
    }

    func toggleSelected(_ app: AppInfo) {
        if selected.contains(app.id) { selected.remove(app.id) } else {
            selected.insert(app.id)
            if leftovers[app.id] == nil { Task { await loadLeftovers(app) } }
        }
    }

    /// Reasons the selection can't be passed to `mo uninstall` safely by name
    /// (empty term, or another installed app with the same folder/display name).
    func uninstallBlockers(_ selection: [AppInfo]) -> String? {
        let unsafe = selection.filter { !Safety.isSafeCommandArgument($0.moleTerm) }
        if !unsafe.isEmpty {
            let list = unsafe.map { "\"\($0.moleTerm)\"" }.joined(separator: ", ")
            return "\(list) starts with \"-\" or contains control characters, so Mole would read it as an option. Nothing was removed. Rename the app or use mo uninstall in Terminal."
        }
        let ambiguous = Safety.ambiguousTerms(
            selected: selection.map { ($0.moleTerm, $0.path) },
            installed: apps.map { ($0.name, $0.path) })
        guard !ambiguous.isEmpty else { return nil }
        return "Another app has the same name as \(ambiguous.map { "\"\($0)\"" }.joined(separator: ", ")), so Mole can't tell them apart. Nothing was removed. Use mo uninstall in Terminal."
    }

    /// `mo uninstall --dry-run NAME` asks "[y/N]" even in dry-run mode, then lists
    /// "✓ ~/Library/... , 512KB" for each file it would remove. Being a dry run it
    /// removes nothing, but its list is only shown when Mole matched exactly this app.
    func loadLeftovers(_ app: AppInfo) async {
        guard !loadingLeftovers.contains(app.id) else { return }
        loadingLeftovers.insert(app.id)
        defer { loadingLeftovers.remove(app.id) }
        if let blocker = uninstallBlockers([app]) {
            leftoverErrors[app.id] = blocker
            leftovers[app.id] = []
            return
        }
        // At most two dry runs at a time. Skip queued ones the user no longer needs
        // (deselected and collapsed); they reload when shown again.
        let text: String? = await dryRunLimiter.run { [weak self] () -> String? in
            guard let self, self.selected.contains(app.id) || self.expanded == app.id else { return nil }
            return await Shell.moText(["uninstall", "--dry-run", app.moleTerm], input: "y\n")
        }
        guard let text else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let mismatch = Safety.matchMismatch(matched: Safety.parseMatchedApps(lines), expected: [app.name]) {
            leftoverErrors[app.id] = mismatch.replacingOccurrences(of: " Nothing was removed.", with: "")
            leftovers[app.id] = []
            return
        }
        leftoverErrors[app.id] = nil
        leftovers[app.id] = lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("✓ ") else { return nil }
            let body = line.dropFirst(2)
            let parts = body.components(separatedBy: " , ")
            let path = Paths.expandingHome(parts[0].trimmingCharacters(in: .whitespaces))
            guard path.hasPrefix("/") else { return nil }
            return Leftover(path: path, sizeText: parts.count > 1 ? parts[1] : "")
        }
    }

    func leftoverBytes(_ app: AppInfo) -> Double? {
        leftovers[app.id].map { $0.reduce(0) { $0 + (Fmt.parseSize($1.sizeText) ?? 0) } }
    }

    func removeSelected() async {
        let selection = selectedApps
        let names = selection.map(\.moleTerm)
        guard !names.isEmpty else { return }
        removalLog = []
        removalError = nil
        skippedPrompts = []
        if let blocker = uninstallBlockers(selection) {
            removalError = blocker
            return
        }
        guard let mo = Shell.mo else { return }
        removing = true
        // Mole confirms with "[y/N]" then "Enter confirm", and Homebrew casks or
        // system apps need sudo, so run it in a pseudo-terminal and answer prompts.
        // The responder answers "y" only if Mole's "Matched N app(s):" list is
        // exactly the selection, and declines everything else.
        let session = PTYSession(mo, ["uninstall"] + names)
        let responder = PromptResponder(reason: "Removing Homebrew or system apps needs admin rights.",
                                        policy: .uninstall(expectedApps: selection.map(\.name)))
        for await line in session.lines {
            _ = responder.handle(line, session)
            removalLog.append(line)
        }
        removalError = responder.matchError
        skippedPrompts = responder.skippedPrompts
        if removalError == nil { selected = [] }
        expanded = nil
        leftovers = [:]
        leftoverErrors = [:]
        await load()
        await StatusModel.shared.refreshHistory()
        removing = false
    }
}

/// Runs async work with at most `limit` bodies in flight; the rest wait in FIFO order.
@MainActor
final class ConcurrencyLimiter {
    let limit: Int
    private(set) var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    var waiting: Int { waiters.count }

    func run<T>(_ body: () async -> T) async -> T {
        if active < limit {
            active += 1
        } else {
            // The slot is handed over by release(), so `active` stays the same.
            await withCheckedContinuation { waiters.append($0) }
        }
        defer { release() }
        return await body()
    }

    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - View

struct UninstallList: View {
    @Bindable var model: UninstallModel
    @State private var confirm = false
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.removalError {
                // Shown when Bubble stopped an uninstall before anything was removed.
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing was removed").font(.ui(.body, .semibold))
                        Text(err).font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    IconButton(systemName: "xmark", label: "Dismiss") { model.removalError = nil }
                }
                .padding(Space.m)
                .panel(radius: Radius.row, fill: Palette.red.opacity(0.1), stroke: Palette.red.opacity(0.3))
                .padding(.horizontal, Space.gutter).padding(.bottom, Space.m)
                .transition(.opacity)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s) {
                        Text("\(model.apps.count) apps").font(.ui(.body, .semibold))
                        Text("\(Fmt.bytes(model.apps.reduce(0) { $0 + $1.bytes })) in total")
                            .font(.num(.secondary)).foregroundStyle(Palette.secondary)
                        if model.loading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                    ForEach(model.visible) { app in row(app) }
                }
                .padding(.bottom, Space.l)
            }
            if !model.selected.isEmpty {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(model.selected.isEmpty)
        .confirmationDialog("Remove \(model.selectedApps.count) app\(model.selectedApps.count == 1 ? "" : "s") and their data?", isPresented: $confirm) {
            Button("Remove", role: .destructive) {
                // The log opens only if Mole actually starts; blocked runs show the banner instead.
                Task { await model.removeSelected() }
            }
        } message: {
            Text(model.selectedApps.map(\.name).joined(separator: ", ") + "\n\nMole moves the apps and their leftovers to the Trash where possible. Homebrew apps are removed with brew --zap. Running apps are quit first.")
        }
        .onChange(of: model.removing) { _, running in if running { showLog = true } }
        .motion(model.removalError)
        .sheet(isPresented: $showLog) {
            RunLogSheet(title: model.removing ? "Removing…" : model.removalError == nil ? "Done" : "Stopped: nothing was removed",
                        lines: model.removalLog, finished: !model.removing,
                        notes: model.skippedPrompts.map { "Skipped: \($0)" } + (model.removalError.map { [$0] } ?? [])) { showLog = false }
        }
    }

    private func row(_ app: AppInfo) -> some View {
        let open = model.expanded == app.id
        let selected = model.selected.contains(app.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Button { model.toggleExpanded(app) } label: {
                    HStack(spacing: Space.m) {
                        AppIcon(path: app.path)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.ui(.body, .semibold))
                            HStack(spacing: Space.m) {
                                if !app.version.isEmpty { Text(app.version).foregroundStyle(Palette.secondary) }
                                Text(Fmt.bytes(app.bytes)).foregroundStyle(Palette.secondary)
                                activity(app)
                            }
                            .font(.num(.secondary))
                        }
                        Spacer()
                        if open || selected, let lb = model.leftoverBytes(app) {
                            Text("Removes \(Fmt.bytes(lb))").font(.num(.secondary)).lineLimit(1).fixedSize().foregroundStyle(.white.opacity(0.8))
                        } else if model.loadingLeftovers.contains(app.id) {
                            ProgressView().controlSize(.small)
                        }
                        if open {
                            Image(systemName: "chevron.up").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.quiet)
                .accessibilityLabel("\(app.name), \(Fmt.bytes(app.bytes))")
                .accessibilityHint(open ? "Hides the files that would be removed" : "Shows the files that would be removed")
                CheckBox(on: selected, tint: Palette.accent, label: "Remove \(app.name)") { model.toggleSelected(app) }
            }
            .padding(.horizontal, Space.l).padding(.vertical, 9)
            .rowHover()
            .contextMenu {
                Button("Reveal in Finder") { Finder.reveal(app.path) }
            }

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Will be removed").font(.ui(.secondary, .semibold)).foregroundStyle(Palette.secondary)
                    if let err = model.leftoverErrors[app.id] {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.ui(.secondary)).foregroundStyle(Palette.amber)
                    } else if let items = model.leftovers[app.id] {
                        ForEach(items) { l in
                            HStack(spacing: Space.l) {
                                Text(l.kind).font(.ui(.secondary, .semibold)).frame(width: 120, alignment: .leading)
                                Text(Fmt.abbreviate(l.path)).font(.path()).foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.parseSize(l.sizeText).map(Fmt.bytes) ?? l.sizeText).font(.num(.secondary)).foregroundStyle(Palette.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .contextMenu {
                                Button("Reveal in Finder") { Finder.reveal(l.path) }
                            }
                        }
                        if items.isEmpty { Text("Mole found nothing to remove for this app.").font(.ui(.secondary)).foregroundStyle(Palette.secondary) }
                    } else {
                        ProgressLine(text: "Finding leftovers")
                    }
                }
                .padding(.horizontal, Space.l).padding(.bottom, Space.m).padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .background(open ? Color.white.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
        .padding(.horizontal, Space.s)
        .motion(open)
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

    private var bottomBar: some View {
        let apps = model.selectedApps
        let total = apps.reduce(0) { $0 + (model.leftoverBytes($1) ?? $1.bytes) }
        return HStack(spacing: Space.m) {
            HStack(spacing: -6) {
                ForEach(apps.prefix(5)) { AppIcon(path: $0.path, size: 28) }
            }
            Text("\(apps.count) app\(apps.count == 1 ? "" : "s"), \(Fmt.bytes(total))").font(.num(.body))
                .contentTransition(.numericText())
            LinkButton(title: "Clear selection", color: Palette.accent) { model.selected = [] }
            Spacer()
            PillButton(title: "Remove \(apps.count) app\(apps.count == 1 ? "" : "s")", width: 240) { confirm = true }
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().overlay(Palette.cardStroke) }
    }
}
