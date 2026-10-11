import Foundation
import Observation

struct CleanItem: Identifiable, Hashable {
    var path: String
    var sizeText: String
    var bytes: Double
    var count: Int
    /// Cleared by running the tool itself (`npm cache clean --force`, `pip3 cache purge`,
    /// `uv cache prune`, `nix-collect-garbage`…) rather than by deleting listed files.
    /// These only show up as "→ npm cache · would clean" lines in the dry run.
    var toolRun = false
    /// Mole's label for a tool-run cleanup ("npm cache").
    var toolName: String? = nil
    /// What goes into the temporary whitelist to skip this item. nil = `[path]`.
    /// For tool-run items this is the cache path Mole's `clean_tool_cache` checks.
    var whitelistPaths: [String]? = nil
    /// Mole can't be told to skip this cleanup (Bubble couldn't determine the path
    /// Mole checks); it runs whenever a clean runs. The UI should show it as not deselectable.
    var alwaysRuns = false
    /// "counted under <parent>" in clean-list.txt: this row lies inside another
    /// candidate, its bytes are already in that row (so `bytes` is 0 here), and it
    /// is deleted exactly when the parent is. Its selection is the parent's.
    var coveredBy: String? = nil

    var id: String { toolRun ? "tool:" + (toolName ?? path) : path }
    /// What to show in the row: the tool label for tool-run items, else the path.
    var title: String { toolName ?? path }
    var protectPaths: [String] { whitelistPaths ?? [path] }
}

/// A place a scan or clean didn't look at, and why.
struct SkippedPlace: Identifiable, Hashable {
    var name: String
    var reason: String
    /// Full Disk Access would let Bubble include it.
    var needsFullDiskAccess: Bool
    var id: String { name }
}

struct CleanCategory: Identifiable {
    var name: String
    var items: [CleanItem]
    var id: String { name }
    var bytes: Double { items.reduce(0) { $0 + $1.bytes } }

    var blurb: String {
        Self.blurbs[name] ?? "Items Mole considers safe to remove."
    }

    static let blurbs: [String: String] = [
        "User essentials": "Your caches, logs and temp files. Rebuilt when needed.",
        "App caches": "App temporary files. Regenerated next launch.",
        "Browsers": "Browser caches. Cookies, history and sessions stay.",
        "Cloud & Office": "Cloud sync and Office caches. Re-synced when accessed.",
        "Developer tools": "Xcode, package manager and build caches. First build will be slower.",
        "Apps & utilities": "Caches from shells and small utilities.",
        "App leftovers": "Data left behind by apps that are no longer on this Mac.",
        "Application Support": "Stale support data from apps.",
        "Apple Silicon updates": "Downloaded macOS update files.",
        "Device backups & firmware": "Old iPhone/iPad backups and firmware downloads.",
        "Large files": "Large, old files worth a look.",
        "Project artifacts": "Build output like node_modules and target folders.",
        "System": "System-wide caches and logs. Needs admin.",
        "Time Machine": "Local Time Machine snapshots.",
        "Virtualization": "Virtual machine and container caches.",
    ]

    /// Unchecked by default: things people may want to keep.
    static let notRecommended: Set<String> = [
        "App leftovers", "Large files", "Device backups & firmware", "Time Machine", "Virtualization", "Project artifacts",
    ]
}

/// Selection rules (what actually gets skipped):
/// - Unchecking an item adds its `protectPaths` to Mole's whitelist for one run.
///   Mole's whitelist also protects everything *inside* a protected folder and every
///   *ancestor* candidate of a protected path, so unchecking can protect a little more
///   than the row itself (never less).
/// - "counted under <parent>" rows are kept as items with `coveredBy` set. They are
///   deleted exactly when their parent is, wherever the parent's category is, so
///   `isSelected` / `toggle` on them read and flip the parent's state. A category
///   therefore can't look unchecked while its files are still deleted under a parent
///   from another category. When the parent is unchecked, the covered rows' own paths
///   are written to the whitelist too.
/// - Tool-run items (`toolRun`) are skipped by whitelisting the cache path Mole checks
///   in `clean_tool_cache` (lib/clean/dev.sh). When Bubble can't work out that path the
///   item is `alwaysRuns`: always selected, `toggle` does nothing.
@Observable
@MainActor
final class CleanModel {
    enum Phase: Equatable { case idle, scanning, found, cleaning, done }

    var phase: Phase = .idle
    var reviewing = false
    var categories: [CleanCategory] = []
    /// Governing keys (`governingKey(_:)`) of unchecked items.
    var deselected: Set<String> = []
    var currentStep = ""
    var log: [String] = []
    var needsFullDiskAccess = false
    var needsAdmin = false
    /// Places the last scan or clean didn't look at: macOS-protected places a guarded run
    /// skipped on purpose (see `PrivacyGuard`), plus anything Mole itself reported as
    /// skipped ("Trash · skipped, grant Full Disk Access…").
    var skipped: [SkippedPlace] = []
    /// The last scan ran under the privacy guard (no Full Disk Access).
    var guarded = false
    var freedText = ""
    var error: String?

    private var job: Task<Void, Never>?
    private var toolHits: [ToolHit] = []
    private var sectionOrder: [String] = []

    var allItems: [CleanItem] { categories.flatMap(\.items) }
    var totalBytes: Double { categories.reduce(0) { $0 + $1.bytes } }
    var selectedItems: [CleanItem] { allItems.filter(isSelected) }
    var selectedBytes: Double { selectedItems.reduce(0) { $0 + $1.bytes } }
    var itemCount: Int { allItems.filter { $0.coveredBy == nil }.reduce(0) { $0 + $1.count } }
    /// Cleanups that will run even if unchecked (show them as locked).
    var alwaysRunItems: [CleanItem] { allItems.filter(\.alwaysRuns) }

    func scan() {
        job?.cancel()
        phase = .scanning
        reviewing = false
        // Notices describe this scan only; a rescan after granting access clears them.
        needsFullDiskAccess = false
        needsAdmin = false
        let profile = PrivacyGuard.currentProfile(quietAppleEvents: true)
        guarded = profile != nil && profile != PrivacyGuard.appleEventsOnlyProfile
        skipped = guarded ? PrivacyGuard.cleanSkipped().map { SkippedPlace(name: $0.name, reason: $0.detail, needsFullDiskAccess: true) } : []
        error = nil
        log = []
        toolHits = []
        sectionOrder = []
        currentStep = "Starting"
        job = Task {
            for await line in Shell.moLines(["clean", "--dry-run"], sandbox: profile) {
                ingest(line)
                if let hit = Self.parseToolLine(line) {
                    toolHits.append(ToolHit(section: currentStep, name: hit.name, sizeText: hit.sizeText))
                }
            }
            guard !Task.isCancelled else { return }
            var cats = Self.parsePreview()
            let tools = await Self.toolItems(toolHits)
            guard !Task.isCancelled else { return }
            for (section, item) in tools {
                if let i = cats.firstIndex(where: { $0.name == section }) {
                    cats[i].items.append(item)
                } else {
                    cats.append(CleanCategory(name: section, items: [item]))
                }
            }
            let order = sectionOrder
            categories = cats.enumerated().sorted { a, b in
                let ia = order.firstIndex(of: a.element.name) ?? Int.max
                let ib = order.firstIndex(of: b.element.name) ?? Int.max
                return ia != ib ? ia < ib : a.offset < b.offset
            }.map(\.element)
            applyRecommended()
            phase = categories.isEmpty ? .done : .found
            if categories.isEmpty { freedText = "Nothing to clean" }
        }
    }

    func cancel() {
        job?.cancel()
        phase = .idle
    }

    /// Every path that must go into the temporary whitelist for the current selection.
    var excludedPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in allItems where !item.alwaysRuns && !isSelected(item) {
            for p in item.protectPaths where seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    func clean() {
        error = nil
        // Set before the temporary whitelist exists, so Checkup and the protected-items
        // editor never mistake this clean's backup for one left by an interrupted clean.
        Whitelist.cleanInProgress = true
        do {
            try Whitelist.protect(excludedPaths)
        } catch {
            Whitelist.cleanInProgress = false
            self.error = error.localizedDescription
            return
        }
        phase = .cleaning
        needsFullDiskAccess = false
        needsAdmin = false
        // Guarded the same way as the scan, so a clean never reaches what the review didn't show.
        let profile = PrivacyGuard.currentProfile(quietAppleEvents: true)
        reviewing = false
        log = []
        currentStep = "Starting"
        let before = VolumeInfo.root.used
        job = Task {
            var tracked: String?
            for await line in Shell.moLines(["clean"], sandbox: profile) {
                ingest(line)
                if let r = line.range(of: "Tracked cleanup:") {
                    // "Tracked cleanup: 5.1MB | Items cleaned: 1" -> "5.1MB"
                    let rest = line[r.upperBound...].split(separator: "|").first ?? ""
                    tracked = rest.trimmingCharacters(in: .whitespaces)
                }
            }
            Whitelist.restoreIfNeeded()
            Whitelist.cleanInProgress = false
            freedText = Self.freedHeadline(tracked: tracked, diskDelta: before - VolumeInfo.root.used)
            phase = .done
            await StatusModel.shared.refreshHistory()
        }
    }

    /// The "Freed …" headline from Mole's "Tracked cleanup: X" figure, which can be
    /// "5.1MB", "At least 5.1MB" (some sizes timed out) or "Partially measured".
    /// Falls back to the change in used disk space when Mole gives no number.
    nonisolated static func freedHeadline(tracked: String?, diskDelta: Double) -> String {
        let fallback = diskDelta > 0 ? "Freed about \(Fmt.bytes(diskDelta))" : "Done"
        guard var text = tracked?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return diskDelta > 0 ? "Freed \(Fmt.bytes(diskDelta))" : "Done"
        }
        var atLeast = false
        if text.lowercased().hasPrefix("at least ") {
            atLeast = true
            text = String(text.dropFirst("at least ".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let bytes = Fmt.parseSize(text) else {
            // "Partially measured" or anything else without a size.
            return fallback
        }
        return atLeast ? "Freed at least \(Fmt.bytes(bytes))" : "Freed \(Fmt.bytes(bytes))"
    }

    private func ingest(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        if line.hasPrefix("➤") {
            currentStep = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if !sectionOrder.contains(currentStep) { sectionOrder.append(currentStep) }
        }
        if line.contains("Full Disk Access") { needsFullDiskAccess = true }
        if let s = Self.parseSkipLine(line), !skipped.contains(where: { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
            skipped.append(s)
        }
        if line.contains("need sudo") || line.contains("requires sudo") { needsAdmin = true }
    }

    // MARK: Skipped places

    /// Mole's own "skipped" lines, e.g.
    ///   "◎ Trash · skipped, grant Full Disk Access to your terminal"
    ///   "◎ Xcode DerivedData · skipped (process state unknown)"
    ///   "! Time Machine cleanup · skipped (backup in progress)"
    ///   "◎ Project caches · skipped 2 slow/incomplete roots"
    /// Whitelist skips ("Homebrew · skipped (whitelist)") are the user's own choice and
    /// aren't reported.
    nonisolated static func parseSkipLine(_ raw: String) -> SkippedPlace? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        // Drop a leading status glyph ("◎", "!", "⚠"…).
        if let first = line.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
           let space = line.firstIndex(of: " ") {
            line = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        }
        guard let sep = line.range(of: " · skipped") else { return nil }
        let name = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
        var reason = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("·") else { return nil }
        if reason.hasPrefix(",") { reason = reason.dropFirst().trimmingCharacters(in: .whitespaces) }
        if reason.hasPrefix("("), reason.hasSuffix(")") { reason = String(reason.dropFirst().dropLast()) }
        if reason == "whitelist" { return nil }
        let fda = reason.localizedCaseInsensitiveContains("Full Disk Access")
        // Mole speaks to Terminal users ("grant Full Disk Access to your terminal").
        let shown = fda ? "Protected by macOS" : (reason.isEmpty ? "Skipped" : reason.prefix(1).uppercased() + reason.dropFirst())
        return SkippedPlace(name: name, reason: shown, needsFullDiskAccess: fda)
    }

    // MARK: Selection

    /// The key whose presence in `deselected` decides this item: its own id, or for
    /// a "counted under" row, the id of the top-most listed parent containing it.
    func governingKey(_ item: CleanItem) -> String {
        Self.governingKey(item, itemsByPath: itemsByPath)
    }

    /// The listed item whose checkbox decides a "counted under" row (nil for normal rows).
    func governingItem(_ item: CleanItem) -> CleanItem? {
        guard item.coveredBy != nil else { return nil }
        let key = governingKey(item)
        return allItems.first { $0.id == key }
    }

    /// Rows counted under `parent` (from any category), with their category names.
    func coveredItems(under parent: CleanItem) -> [(category: String, item: CleanItem)] {
        categories.flatMap { c in
            c.items.filter { $0.coveredBy != nil && governingKey($0) == parent.id }.map { (c.name, $0) }
        }
    }

    func isSelected(_ item: CleanItem) -> Bool {
        item.alwaysRuns || !deselected.contains(governingKey(item))
    }

    func toggle(_ item: CleanItem) {
        guard !item.alwaysRuns else { return }
        let key = governingKey(item)
        if deselected.contains(key) { deselected.remove(key) } else { deselected.insert(key) }
    }

    func selectedCount(_ c: CleanCategory) -> Int { c.items.filter(isSelected).count }

    func toggle(_ c: CleanCategory) {
        let keys = c.items.filter { !$0.alwaysRuns }.map(governingKey)
        if selectedCount(c) == c.items.count { deselected.formUnion(keys) } else { deselected.subtract(keys) }
    }

    func selectAll() { deselected = [] }
    func selectNone() { deselected = Set(allItems.filter { !$0.alwaysRuns && $0.coveredBy == nil }.map(\.id)) }
    func applyRecommended() {
        // Covered rows follow their parent, so only the parents' own categories decide.
        deselected = Set(categories.filter { CleanCategory.notRecommended.contains($0.name) }
            .flatMap(\.items).filter { !$0.alwaysRuns && $0.coveredBy == nil }.map(\.id))
    }

    private var itemsByPath: [String: CleanItem] {
        var map: [String: CleanItem] = [:]
        for item in allItems where !item.toolRun { map[item.path] = item }
        return map
    }

    nonisolated static func governingKey(_ item: CleanItem, itemsByPath: [String: CleanItem]) -> String {
        guard var parent = item.coveredBy else { return item.id }
        var seen: Set<String> = [item.path]
        while let p = itemsByPath[parent], let next = p.coveredBy, seen.insert(parent).inserted {
            parent = next
        }
        return itemsByPath[parent]?.id ?? parent
    }

    // MARK: Preview parsing

    /// `mo clean --dry-run` writes every candidate to ~/.config/mole/clean-list.txt:
    ///   === Section ===
    ///   /path  # 52.6MB, 3 items, counted under /parent
    /// Rows "counted under" another row are kept with `coveredBy` and zero bytes
    /// (their size is already in the parent's row).
    nonisolated static func parsePreview() -> [CleanCategory] {
        let url = Whitelist.dir.appendingPathComponent("clean-list.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parsePreview(text: text)
    }

    nonisolated static func parsePreview(text: String) -> [CleanCategory] {
        var cats: [CleanCategory] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                cats.append(CleanCategory(name: String(line.dropFirst(4).dropLast(4)), items: []))
                continue
            }
            guard line.hasPrefix("/"), !cats.isEmpty, let hash = line.range(of: "  # ") else { continue }
            let path = String(line[..<hash.lowerBound])
            let notesText = String(line[hash.upperBound...])
            var coveredBy: String?
            var notesPart = notesText
            if let r = notesText.range(of: ", counted under ") {
                coveredBy = String(notesText[r.upperBound...])
                notesPart = String(notesText[..<r.lowerBound])
            } else if notesText.hasPrefix("counted under ") {
                coveredBy = String(notesText.dropFirst("counted under ".count))
                notesPart = ""
            }
            let notes = notesPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let sizeText = notes.first ?? ""
            let count = notes.compactMap { n -> Int? in
                n.hasSuffix(" items") ? Int(n.dropLast(6)) : nil
            }.first ?? 1
            cats[cats.count - 1].items.append(
                CleanItem(path: path, sizeText: sizeText == "size unknown" ? "?" : sizeText,
                          bytes: coveredBy == nil ? (Fmt.parseSize(sizeText) ?? 0) : 0, count: count,
                          coveredBy: coveredBy))
        }
        // Mole can repeat a section header; merge duplicates.
        var merged: [CleanCategory] = []
        for c in cats where !c.items.isEmpty {
            if let i = merged.firstIndex(where: { $0.name == c.name }) { merged[i].items += c.items } else { merged.append(c) }
        }
        return merged
    }

    // MARK: Tool-run cleanups

    struct ToolHit: Equatable {
        var section: String
        var name: String
        var sizeText: String
    }

    /// "  → npm cache · would clean"            -> ("npm cache", "")
    /// "  → Homebrew cleanup · would free 1.2GB" -> ("Homebrew cleanup", "1.2GB")
    /// "  → Homebrew cleanup · 12 items"         -> ("Homebrew cleanup", "")
    /// "  → Homebrew · would cleanup"            -> ("Homebrew", "")
    nonisolated static func parseToolLine(_ raw: String) -> (name: String, sizeText: String)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("→") else { return nil }
        line = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let sep = line.range(of: " · ", options: .backwards) else { return nil }
        let name = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if tail == "would clean" || tail == "would cleanup" { return (name, "") }
        if name == "Homebrew cleanup" {
            if tail.hasPrefix("would free ") { return (name, String(tail.dropFirst("would free ".count))) }
            if tail.hasSuffix(" items"), Int(tail.dropLast(6)) != nil { return (name, "") }
        }
        return nil
    }

    /// Builds one item per distinct (section, tool) and works out the whitelist
    /// path(s) Mole checks before running it.
    static func toolItems(_ hits: [ToolHit]) async -> [(section: String, item: CleanItem)] {
        var out: [(String, CleanItem)] = []
        var seen = Set<String>()
        for hit in hits where seen.insert(hit.section + "\u{0}" + hit.name).inserted {
            let paths = await ToolCaches.whitelistPaths(for: hit.name)
            let usable = paths.flatMap { $0.isEmpty || !Whitelist.rejectedPaths($0).isEmpty ? nil : $0 }
            let item = CleanItem(
                path: usable?.first ?? hit.name,
                sizeText: hit.sizeText,
                bytes: Fmt.parseSize(hit.sizeText) ?? 0,
                count: 1,
                toolRun: true,
                toolName: hit.name,
                whitelistPaths: usable,
                alwaysRuns: usable == nil)
            out.append((hit.section, item))
        }
        return out
    }
}

/// The cache path each tool-run cleanup checks against the whitelist, resolved the
/// same way Mole does (lib/clean/dev.sh, lib/clean/brew.sh, lib/core/base.sh), with
/// the same PATH and environment Mole gets from Bubble.
enum ToolCaches {
    static var home: String { NSHomeDirectory() }
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// nil when unknown: the cleanup can't be skipped from Bubble.
    static func whitelistPaths(for name: String) async -> [String]? {
        switch name {
        case "npm cache":
            // clean_dev_npm: `npm config get cache`, else ~/.npm
            guard let npm = Shell.which("npm") else { return nil }
            return [await absoluteOutput(npm, ["config", "get", "cache"]) ?? home + "/.npm"]
        case "pip cache":
            // clean_dev_python: `pip3 cache dir`, else ~/Library/Caches/pip
            guard let pip = Shell.which("pip3") else { return nil }
            return [await absoluteOutput(pip, ["cache", "dir"]) ?? home + "/Library/Caches/pip"]
        case "uv cache":
            // clean_uv_cache: `uv cache dir`, else ~/.cache/uv
            guard let uv = Shell.which("uv") else { return nil }
            return [await absoluteOutput(uv, ["cache", "dir"]) ?? home + "/.cache/uv"]
        case "Corepack cache":
            // clean_corepack_cache: $COREPACK_HOME, else ~/.cache/node/corepack
            let p = env["COREPACK_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.cache/node/corepack"
            return p.hasPrefix("/") ? [p] : nil
        case "pnpm cache":
            // clean_pnpm_stores: `pnpm store path` for every installed pnpm binary.
            var bins: [String] = []
            if let p = Shell.which("pnpm") { bins.append(p) }
            let miseRoot = home + "/.local/share/mise/installs/pnpm"
            for v in (try? FileManager.default.contentsOfDirectory(atPath: miseRoot))?.sorted() ?? [] {
                let b = miseRoot + "/" + v + "/pnpm"
                if FileManager.default.isExecutableFile(atPath: b) { bins.append(b) }
            }
            var stores: [String] = []
            for b in bins {
                if let s = await absoluteOutput("/usr/bin/env", ["COREPACK_ENABLE_DOWNLOAD_PROMPT=0", b, "store", "path"]),
                   !stores.contains(s) { stores.append(s) }
            }
            return stores.isEmpty ? nil : stores
        case "conda index/tarball/log caches":
            // clean_conda_metadata_caches: hint path ~/.conda/pkgs
            return [home + "/.conda/pkgs"]
        case "mise cache":
            // get_mise_cache_path: `mise cache path`, else ~/Library/Caches/mise
            guard let mise = Shell.which("mise") else { return nil }
            return [await absoluteOutput(mise, ["cache", "path"]) ?? home + "/Library/Caches/mise"]
        case "Nix garbage collection":
            return ["/nix/store"]
        case "bun cache":
            // clean_dev_npm: `bun pm cache`, else ~/.bun/install/cache
            guard let bun = Shell.which("bun") else { return nil }
            return [await absoluteOutput(bun, ["pm", "cache"]) ?? home + "/.bun/install/cache"]
        case "Go module cache", "Go build cache":
            // mole_go_cache_root: `go env GOMODCACHE|GOCACHE`, trailing "/" dropped.
            guard let go = Shell.which("go"),
                  let p = await absoluteOutput(go, ["env", name == "Go module cache" ? "GOMODCACHE" : "GOCACHE"])
            else { return nil }
            return [p]
        case "GitHub CLI cache":
            // mole_github_cli_cache_root + "/gh"
            var root = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.cache"
            while root.count > 1, root.hasSuffix("/") { root.removeLast() }
            return root.hasPrefix("/") ? [root + "/gh"] : nil
        case "Homebrew cleanup", "Homebrew":
            // clean_homebrew: skipped when ~/Library/Caches/Homebrew is whitelisted.
            return [home + "/Library/Caches/Homebrew"]
        default:
            return nil
        }
    }

    /// First line of a command's stdout if it is an absolute path (trailing "/" dropped).
    private static func absoluteOutput(_ exe: String, _ args: [String]) async -> String? {
        let data = await Shell.output(exe, args, timeout: 10)
        guard var line = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }
        while line.count > 1, line.hasSuffix("/") { line.removeLast() }
        return line.hasPrefix("/") ? line : nil
    }
}
