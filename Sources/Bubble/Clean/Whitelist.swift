import Foundation

/// Mole has no "clean only these" flag, but it never touches whitelisted paths.
/// To skip items the user unchecked, Bubble appends them to
/// ~/.config/mole/whitelist for one run and then restores the original file.
///
/// Caveat from Mole's loader: once the whitelist file exists it *replaces* the
/// optional default patterns, so when there is no file yet we seed it with
/// Mole's own DEFAULT_WHITELIST_PATTERNS to keep that protection.
///
/// Safety rules (the file handling is `TemporaryWhitelist`'s, shared with Optimize):
/// - A whitelist that exists but can't be read as UTF-8, or is a symlink or a folder,
///   aborts the clean (it is never treated as "no whitelist" and overwritten).
/// - The backup records both the user's original and exactly what Bubble wrote.
///   On restore the original is put back only if the file still holds exactly
///   Bubble's text; if anyone changed it meanwhile, their version is kept and
///   the backup is set aside as `whitelist.bubble-discarded`.
/// - Paths Mole's loader would silently reject are refused up front, so an
///   unchecked item is never deleted because its whitelist line was ignored.
enum Whitelist {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole")
    static let file = dir.appendingPathComponent("whitelist")
    static let backup = dir.appendingPathComponent("whitelist.bubble-backup")
    /// Where a backup goes when the whitelist changed during a clean and was left alone.
    static let discarded = dir.appendingPathComponent("whitelist.bubble-discarded")
    static let marker = "# bubble: kept for this clean only\n"
    static let temporary = TemporaryWhitelist(file: file, backup: backup, discarded: discarded, version: 2)

    /// True while a temporary whitelist is in place (a clean is running, or Bubble
    /// quit mid-clean and hasn't restored yet). Read live; the settings editor
    /// should refuse to save while this is true.
    static var isBusy: Bool { FileManager.default.fileExists(atPath: backup.path) }

    /// True from just before a clean writes the temporary whitelist until it has been
    /// restored. A backup on disk while this is false was left by an interrupted clean.
    @MainActor static var cleanInProgress = false

    /// A leftover backup from a clean that didn't finish (none is running now).
    @MainActor static var hasStaleBackup: Bool { isBusy && !cleanInProgress }

    /// What the whitelist file holds, as the protected-items editor sees it.
    enum FileState: Equatable {
        case missing
        case text(String)
        case unreadable(String)
    }

    /// The whitelist file as it is now.
    static func currentState() -> FileState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil
            return isLink ? .unreadable("it's a symlink to a missing file") : .missing
        }
        guard let data = try? Data(contentsOf: file) else { return .unreadable("it couldn't be opened") }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable("it isn't valid UTF-8 text") }
        return .text(text)
    }

    /// The user's own whitelist, saved in the backup while a temporary one is in place:
    /// `.missing` when there was none, nil when there is no readable backup.
    static func originalInBackup() -> FileState? {
        (try? Data(contentsOf: backup)).flatMap(originalState)
    }

    static func originalState(backupData: Data) -> FileState? {
        temporary.decodeBackup(backupData).map { $0.original.map(FileState.text) ?? .missing }
    }

    enum Failure: LocalizedError, Equatable {
        case noDefaults
        case unreadable(String)
        case rejectedPaths([String])

        var errorDescription: String? {
            switch self {
            case .noDefaults:
                return "Couldn't read Mole's default protected paths, so unchecking items isn't safe right now. Select everything, or use mo clean --whitelist in Terminal."
            case .unreadable(let why):
                return "Couldn't read your Mole whitelist (\(why)), so Bubble won't change it. Nothing was cleaned. Fix ~/.config/mole/whitelist or select everything."
            case .rejectedPaths(let paths):
                return "Mole can't protect these unchecked items, so they would be deleted anyway. Nothing was cleaned. Select them, or move them first:\n"
                    + paths.joined(separator: "\n")
            }
        }
    }

    static func protect(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let rejected = rejectedPaths(paths)
        guard rejected.isEmpty else { throw Failure.rejectedPaths(rejected) }
        restoreIfNeeded()
        let original: String?
        do { original = try temporary.readOriginal() } catch let e as TemporaryWhitelist.Unreadable { throw Failure.unreadable(e.reason) }
        var base: String
        if let original {
            base = original
        } else {
            let defaults = defaultPatterns()
            guard !defaults.isEmpty else { throw Failure.noDefaults }
            base = defaults.joined(separator: "\n")
        }
        if !base.isEmpty, !base.hasSuffix("\n") { base += "\n" }
        let written = base + marker + paths.joined(separator: "\n") + "\n"
        try temporary.write(written, original: original)
    }

    /// Puts the user's whitelist back. Safe to call any time; also runs at launch
    /// in case Bubble quit mid-clean. Only restores when the file still holds
    /// exactly what Bubble wrote; otherwise keeps the user's current file.
    static func restoreIfNeeded() { temporary.restoreIfNeeded() }

    typealias RestoreAction = TemporaryWhitelist.RestoreAction

    static func restoreAction(backupData: Data, current: String?) -> RestoreAction {
        temporary.restoreAction(backupData: backupData, current: current)
    }

    // MARK: Validation (mirrors load_mole_whitelist in Mole's lib/core/base.sh)

    /// Paths Mole would not protect if written to the whitelist: its loader drops
    /// lines containing "..", control characters, "//", non-absolute paths and
    /// protected system paths; it trims whitespace and expands $HOME/~. Wildcards
    /// are refused too: a pattern containing * ? [ turns off Mole's "inside this
    /// folder" matching, so a folder's contents would not be protected.
    static func rejectedPaths(_ paths: [String]) -> [String] {
        paths.filter { rejectionReason($0) != nil }
    }

    static func rejectionReason(_ path: String) -> String? {
        if path.isEmpty { return "empty" }
        if path != path.trimmingCharacters(in: .whitespaces) { return "leading or trailing spaces" }
        if path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "control characters" }
        if path.contains("..") { return "contains .." }
        if !path.hasPrefix("/") { return "not an absolute path" }
        if path.contains("//") { return "consecutive slashes" }
        if path.contains("$HOME") || path.contains("${HOME}") { return "contains $HOME" }
        if path.contains(where: { "*?[".contains($0) }) { return "contains wildcard characters" }
        if path.hasPrefix("#") { return "comment" }
        let protectedRoots = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/etc", "/var/db"]
        if path == "/" || protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "protected system path"
        }
        return nil
    }

    /// Reads DEFAULT_WHITELIST_PATTERNS from Mole's installed lib/core/base.sh.
    static func defaultPatterns() -> [String] {
        guard let libexec = Shell.moleLibexec,
              let src = try? String(contentsOf: libexec.appendingPathComponent("lib/core/base.sh"), encoding: .utf8),
              let start = src.range(of: "declare -a DEFAULT_WHITELIST_PATTERNS=(")
        else { return [] }
        let body = src[start.upperBound...]
        guard let end = body.range(of: "\n)") else { return [] }
        var patterns: [String] = []
        for raw in body[..<end.lowerBound].split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 2, line.hasPrefix("\""), line.hasSuffix("\"") else { continue }
            let value = String(line.dropFirst().dropLast())
            patterns.append(value == "$FINDER_METADATA_SENTINEL" ? "FINDER_METADATA" : value)
        }
        return patterns
    }
}

/// A Mole whitelist file that Bubble changes for one run and then puts back exactly as it
/// was: Clean's `whitelist` and Optimize's `whitelist_optimize`.
///
/// - The file is never rewritten when it's a symlink (even a dangling one), a folder, or
///   not readable as UTF-8 text.
/// - The backup (JSON: version, the original or nil for no file, and exactly what Bubble
///   wrote) is saved before the file is written; if that write fails the file is put back.
/// - Restore puts the original back only if the file still holds Bubble's text; otherwise
///   the user's newer file is kept and the backup set aside at `discarded`.
struct TemporaryWhitelist {
    let file: URL
    let backup: URL
    let discarded: URL
    /// The backup format's version. Each list keeps the one it always wrote (Clean 2,
    /// Optimize 1), so a backup left by an interrupted run of an older Bubble still restores.
    let version: Int

    struct Unreadable: Error, Equatable { let reason: String }

    struct Backup: Codable {
        var version: Int
        var original: String?
        var written: String
    }

    enum RestoreAction: Equatable {
        /// Put this back (nil = delete the file, there was none before).
        case restore(String?)
        /// The file changed since Bubble wrote it; keep it.
        case leaveAlone
    }

    /// The backup, or nil when it isn't one this list wrote.
    func decodeBackup(_ data: Data) -> Backup? {
        guard let b = try? JSONDecoder().decode(Backup.self, from: data), b.version == version else { return nil }
        return b
    }

    /// The file's text now; nil when there's none.
    func readOriginal() throws -> String? { try Self.read(file) }

    /// nil when there's no file; throws `Unreadable` for anything Bubble shouldn't rewrite.
    static func read(_ url: URL) throws -> String? {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw Unreadable(reason: "it's a symlink") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { throw Unreadable(reason: "it's a folder") }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Unreadable(reason: error.localizedDescription) }
        guard let text = String(data: data, encoding: .utf8) else { throw Unreadable(reason: "it isn't valid UTF-8 text") }
        return text
    }

    /// Saves the backup, then writes `written` over the file.
    func write(_ written: String, original: String?) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Backup first: if writing the file then fails, restore sees it doesn't hold
        // `written` and leaves it alone.
        try JSONEncoder().encode(Backup(version: version, original: original, written: written)).write(to: backup, options: .atomic)
        do {
            try written.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            restoreIfNeeded()
            throw error
        }
    }

    /// What `restoreIfNeeded` should do with this backup, given the file's current text.
    /// A backup Bubble can't read is set aside rather than trusted.
    func restoreAction(backupData: Data, current: String?) -> RestoreAction {
        guard let b = decodeBackup(backupData) else { return .leaveAlone }
        if current == b.written { return .restore(b.original) }
        // Nothing there now and nothing there before: same state either way.
        if current == nil, b.original == nil { return .restore(nil) }
        return .leaveAlone
    }

    /// Puts the user's file back when a backup exists. Safe to call any time.
    func restoreIfNeeded() {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: backup) else { return }
        // Through a symlink, as older Bubbles wrote Clean's list through one.
        let target = file.resolvingSymlinksInPath()
        let current = (try? Data(contentsOf: target)).flatMap { String(data: $0, encoding: .utf8) }
        switch restoreAction(backupData: data, current: current) {
        case .restore(let original):
            if let original {
                try? original.write(to: target, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(at: target)
            }
            try? fm.removeItem(at: backup)
        case .leaveAlone:
            try? fm.removeItem(at: discarded)
            try? fm.moveItem(at: backup, to: discarded)
            if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
        }
    }
}
