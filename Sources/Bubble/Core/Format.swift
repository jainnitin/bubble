import Foundation

enum Fmt {
    /// Disk and file sizes in decimal units (1 GB = 1,000,000,000 bytes), the same as
    /// Finder, Mole and `mo`'s own output.
    static func bytes(_ value: Double) -> String { format(value, base: 1000) }

    /// Memory in binary units (1 GB = 1,073,741,824 bytes), the same as Activity Monitor.
    static func memory(_ value: Double) -> String { format(value, base: 1024) }

    private static func format(_ value: Double, base: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(value, 0)
        var i = 0
        while v >= base, i < units.count - 1 { v /= base; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return v >= 100 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }

    /// Parses Mole's human sizes: "52.6MB", "12KB", "0B", "3.96GB", "45.5 MB" (decimal units).
    static func parseSize(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)) { return n * mult }
        }
        return nil
    }

    static func rate(_ mbPerSec: Double) -> (String, String) {
        let kb = mbPerSec * 1024
        if kb < 1 { return ("<1", "KB/s") }
        if kb < 1024 { return (String(format: "%.0f", kb), "KB/s") }
        return (String(format: "%.1f", mbPerSec), "MB/s")
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        let secs = Date().timeIntervalSince(date)
        if secs < 3600 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum Paths {
    /// Expands a leading "~" and every "$HOME" or "${HOME}", the way Mole reads paths in
    /// its whitelist.
    static func expandingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        var p = path.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
        return p
    }
}
