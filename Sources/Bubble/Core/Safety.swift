import Foundation

/// Pure safety checks shared by the models. Nothing in here touches the disk
/// except for resolving symlinks, so it can be unit tested.
enum Safety {
    // MARK: Move to Trash guard

    /// Folders that must never be offered for "Move to Trash" (Analyze).
    /// Returns true for the home folder, its top-level Library/Documents/Desktop/Downloads
    /// (the folders themselves, not their contents), the root and top-level system
    /// folders, and any path at depth ≤ 2 under / that is not inside the home folder.
    static func isProtectedFromTrash(path: String) -> Bool {
        isProtectedFromTrash(path: path, home: NSHomeDirectory())
    }

    static func isProtectedFromTrash(path: String, home: String) -> Bool {
        let homeNorm = normalize(home)
        guard let lexical = normalizeExpandingTilde(path, home: homeNorm) else { return true }
        if isProtectedLexically(lexical, home: homeNorm) { return true }
        // Also check where a symlink actually points (e.g. /tmp -> /private/tmp,
        // or a link inside ~ that points at /Applications).
        let resolved = normalize(URL(fileURLWithPath: lexical).resolvingSymlinksInPath().path)
        if resolved != lexical, isProtectedLexically(resolved, home: homeNorm) { return true }
        return false
    }

    private static let protectedHomeChildren = ["Library", "Documents", "Desktop", "Downloads"]
    private static let protectedSystem = [
        "/Applications", "/Library", "/System", "/Users", "/usr", "/bin", "/sbin", "/opt", "/private", "/Volumes",
        "/etc", "/var", "/tmp", "/cores", "/dev", "/nix",
    ]

    private static func isProtectedLexically(_ p: String, home: String) -> Bool {
        let lower = p.lowercased()
        let homeLower = home.lowercased()
        if lower == "/" { return true }
        if lower == homeLower { return true }
        if protectedHomeChildren.contains(where: { lower == homeLower + "/" + $0.lowercased() }) { return true }
        if protectedSystem.contains(where: { lower == $0.lowercased() }) { return true }
        let insideHome = lower.hasPrefix(homeLower + "/")
        let depth = p.split(separator: "/").count
        if depth <= 2, !insideHome { return true }
        return false
    }

    /// Expands a leading "~", then collapses "//", "." and ".." and drops a trailing "/".
    /// Returns nil for relative paths. Unlike `Paths.expandingHome`, "$HOME" is left alone:
    /// in a path to trash it can only be a literal folder name.
    static func normalizeExpandingTilde(_ path: String, home: String) -> String? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst() }
        guard p.hasPrefix("/") else { return nil }
        return normalize(p)
    }

    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    // MARK: Uninstall match check (used by PTY's `mo uninstall` prompt policy)

    /// Parses Mole's confirmation block:
    ///   ◎ Matched 2 app(s):
    ///   1. Xcode  3.96GB  |  Last: 5d ago
    ///   2. Claude Code URL Handler  4KB  |  Last: Today
    /// Returns the display names, or nil when no "Matched" header was seen or the
    /// number of rows doesn't equal the count in the header.
    static func parseMatchedApps(_ lines: [String]) -> [String]? {
        var expectedCount: Int?
        var names: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let n = matchedHeaderCount(line) {
                // A later header starts a new block.
                expectedCount = n
                names = []
                continue
            }
            guard let count = expectedCount, names.count < count else { continue }
            if let name = matchedRowName(line, index: names.count + 1) { names.append(name) }
        }
        guard let expectedCount, names.count == expectedCount else { return nil }
        return names
    }

    /// "◎ Matched 3 app(s):" -> 3
    static func matchedHeaderCount(_ line: String) -> Int? {
        guard let r = line.range(of: "Matched "), line.hasSuffix(" app(s):") else { return nil }
        let middle = line[r.upperBound...].dropLast(" app(s):".count)
        return Int(middle)
    }

    /// "2. Claude Code URL Handler  4KB  |  Last: Today" -> "Claude Code URL Handler"
    static func matchedRowName(_ line: String, index: Int) -> String? {
        let prefix = "\(index). "
        guard line.hasPrefix(prefix) else { return nil }
        var body = Substring(line.dropFirst(prefix.count))
        if let r = body.range(of: "  |  Last:", options: .backwards) { body = body[..<r.lowerBound] }
        // Drop the size column: "Name  3.96GB".
        if let r = body.range(of: "  ", options: .backwards) { body = body[..<r.lowerBound] }
        let name = normalizeAppName(String(body))
        return name.isEmpty ? nil : name
    }

    /// Trims whitespace and invisible format characters (Mole keeps e.g. the
    /// U+200E mark in "‎WhatsApp").
    static func normalizeAppName(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when Mole matched exactly the selected apps (as a multiset of display
    /// names); otherwise a user-facing error.
    static func matchMismatch(matched: [String]?, expected: [String]) -> String? {
        guard let matched else {
            return "Couldn't read which apps Mole matched, so nothing was removed."
        }
        let m = matched.map(normalizeAppName).sorted()
        let e = expected.map(normalizeAppName).sorted()
        if m == e { return nil }
        let list = matched.isEmpty ? "none" : matched.map(normalizeAppName).joined(separator: ", ")
        return "Mole matched different apps than you selected: \(list). Nothing was removed."
    }

    // MARK: Arguments and links

    /// True when `s` is safe to pass as a single positional argument to a command
    /// (an app name for `mo uninstall`, a cask token for `brew`): not empty, doesn't
    /// start with "-" (so it can't be read as an option), and has no control characters
    /// (newline, NUL, ESC, …) that could end a prompt answer or forge output.
    static func isSafeCommandArgument(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-") else { return false }
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        // General category Cc (C0/C1 controls: NUL, tab, newline, ESC, DEL, …) plus the Unicode
        // line and paragraph separators. Format characters (Cf) such as the U+200E mark Mole
        // keeps in "‎WhatsApp" are allowed; they can't end a line or start an escape sequence.
        return !s.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    /// Links Bubble may hand to `NSWorkspace.open`: https web pages and the Mac App Store
    /// (`macappstore:`). Anything else (file:, http:, custom app schemes, javascript:, …)
    /// is refused.
    static func isAllowedExternalURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host?.isEmpty == false
        case "macappstore": return true
        default: return false
        }
    }
}
