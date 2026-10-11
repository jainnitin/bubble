import Foundation

/// Without Full Disk Access, a few of Mole's optimize tasks open other apps' data (Mail,
/// Messages, Safari, Notification Center, usage data, Finder's shared file lists), and
/// macOS answers with a stream of privacy prompts. Mole can't be told to skip a task on
/// the command line, but it skips any task whose id is in ~/.config/mole/whitelist_optimize,
/// so Bubble adds those ids there for one run (the `--dry-run` plan or the real run) and
/// then puts the user's file back exactly as it was.
///
/// The file handling is Clean's (`TemporaryWhitelist`): the user's file is put back exactly,
/// a newer edit is kept, and a file Bubble can't safely rewrite is never touched (the run
/// then goes ahead without the skips). A backup left by a run that never finished (Bubble
/// quit) is restored before the next change and when Optimize starts up.
///
/// Mole matches whitelist lines against the task id exactly (`is_whitelisted "$action"`),
/// so the lines are ids from lib/optimize/catalog.sh, not display names.
/// Mole's optimize defaults (`DEFAULT_OPTIMIZE_WHITELIST_PATTERNS`) are empty, so creating
/// the file loses nothing; when only the legacy `whitelist_checks` exists, its patterns are
/// carried over because Mole stops reading it once the new file exists.
enum OptimizeWhitelist {
    /// Task id → Mole's task title, for the tasks that read protected data.
    static let needsFullDiskAccess: [(id: String, name: String)] = [
        ("sqlite_vacuum", "Database Optimization"),          // Mail, Messages, Safari databases
        ("shared_file_list_repair", "Shared File Lists"),    // ~/Library/Application Support/com.apple.sharedfilelist
        ("notification_cleanup", "Notifications"),          // Group Containers/group.com.apple.usernoted
        ("coreduet_cleanup", "Usage Data"),                  // knowledgeC.db
    ]

    static let marker = "# bubble: skipped for this run only (no Full Disk Access)\n"

    struct Paths {
        var dir: URL
        var file: URL { dir.appendingPathComponent("whitelist_optimize") }
        var legacy: URL { dir.appendingPathComponent("whitelist_checks") }
        var backup: URL { dir.appendingPathComponent("whitelist_optimize.bubble-backup") }
        var discarded: URL { dir.appendingPathComponent("whitelist_optimize.bubble-discarded") }

        var temporary: TemporaryWhitelist { TemporaryWhitelist(file: file, backup: backup, discarded: discarded, version: 1) }

        static let standard = Paths(dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole"))
    }

    // MARK: One holder at a time (the plan and a run can overlap)

    @MainActor private static var holders = 0
    /// Task ids the current temporary whitelist added (shown as "needs Full Disk Access").
    @MainActor private(set) static var added: [String] = []

    /// Adds the protected-data tasks for the caller's run. Returns the titles of the tasks
    /// that will be skipped; empty when nothing changed (Full Disk Access is on, or the file
    /// couldn't be changed). Always pair with `end()`.
    @MainActor
    static func begin(fullDiskAccess: Bool, paths: Paths = .standard) -> Set<String> {
        holders += 1
        if holders == 1 {
            added = []
            if !fullDiskAccess {
                added = (try? apply(needsFullDiskAccess.map(\.id), paths: paths)) ?? []
            }
        }
        let ids = Set(added)
        return Set(needsFullDiskAccess.filter { ids.contains($0.id) }.map(\.name))
    }

    @MainActor
    static func end(paths: Paths = .standard) {
        holders = max(0, holders - 1)
        if holders == 0 {
            restoreIfNeeded(paths: paths)
            added = []
        }
    }

    /// Restores a backup left by a run that never finished, unless one is running now.
    @MainActor
    static func restoreStale(paths: Paths = .standard) {
        if holders == 0 { restoreIfNeeded(paths: paths) }
    }

    // MARK: File work (no shared state; tested against temporary folders)

    /// Writes the temporary whitelist. Returns the ids Bubble added (ids already in the
    /// user's list are left as they are and not returned).
    static func apply(_ ids: [String], paths: Paths) throws -> [String] {
        let list = paths.temporary
        list.restoreIfNeeded()
        let original = try list.readOriginal()
        var base = original ?? ((try? TemporaryWhitelist.read(paths.legacy)) ?? nil) ?? ""
        let existing = Set(base.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = ids.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return [] }
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        let written = base + marker + missing.joined(separator: "\n") + "\n"
        try list.write(written, original: original)
        return missing
    }

    /// Puts the user's file back. Safe to call any time.
    static func restoreIfNeeded(paths: Paths) { paths.temporary.restoreIfNeeded() }
}
