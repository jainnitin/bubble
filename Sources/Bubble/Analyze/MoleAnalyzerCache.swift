import Foundation

/// Targeted invalidation of the on-disk cache `mo analyze` keeps in ~/.cache/mole/analyzer.
///
/// Mole caches a folder's total in `<xxh64(path) in hex>.cache` and trusts it while the
/// folder's own modification time is unchanged. Deleting a file only touches the folder
/// that held it, so every folder above keeps passing that check, and a rescan reports the
/// deleted bytes for up to a week. `mo analyze --json` has no switch to bypass the cache,
/// so before an authoritative scan Bubble removes the entries Mole would wrongly reuse,
/// the same ones Mole's own TUI drops when you refresh or delete there.
///
/// The overview's area sizes live in `overview_sizes.json`, keyed by path, with the same
/// week-long lifetime.
enum MoleAnalyzerCache {
    static let overviewFile = "overview_sizes.json"

    static func directory(home: String = Shell.home) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".cache/mole/analyzer")
    }

    /// The cache file name Mole uses for `path` (xxHash64, seed 0, unpadded hex).
    static func fileName(for path: String) -> String {
        String(xxh64(Array(path.utf8)), radix: 16) + ".cache"
    }

    /// Before refreshing `path`: drops the entries for `path`, every folder above it (their
    /// totals include it) and every folder inside it (any of them may hide a change), plus
    /// the overview sizes that cover it. Refreshing the overview (nil) drops the whole cache.
    /// Folders `skip` returns true for aren't walked (Bubble's privacy guard: listing them
    /// would set off a macOS prompt, and a guarded scan can't see them anyway).
    static func invalidate(refreshing path: String?, home: String = Shell.home, skip: (String) -> Bool = { _ in false }) {
        let dir = directory(home: home)
        guard let path = path.map(clean) else {
            try? FileManager.default.removeItem(at: dir)
            return
        }
        var stale = Set(ancestry(of: path))
        let cached = cacheFiles(in: dir)
        if !cached.isEmpty {
            walkFolders(under: path, skip: skip) { folder in
                if cached.contains(fileName(for: folder)) { stale.insert(folder) }
            }
        }
        remove(stale, in: dir)
        dropOverviewSizes(covering: path, in: dir)
    }

    /// After moving `path` to the Trash: only the folders above it changed. Its own subtree
    /// is gone, and Mole discards entries for folders that no longer exist.
    static func invalidate(trashed path: String, home: String = Shell.home) {
        let dir = directory(home: home)
        remove(Set(ancestry(of: path)), in: dir)
        dropOverviewSizes(covering: clean(path), in: dir)
    }

    /// `path` and each folder above it, up to "/".
    static func ancestry(of path: String) -> [String] {
        var out: [String] = []
        var p = clean(path)
        while true {
            out.append(p)
            if p == "/" || p.isEmpty { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return out
    }

    /// Drops a trailing slash. Not `standardizingPath`: that rewrites /private/tmp to
    /// /tmp, and Mole keys entries by the path exactly as it scanned it.
    static func clean(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True when an overview size keyed by `key` includes `path` or lies inside it.
    static func covers(_ key: String, _ path: String) -> Bool {
        key == path || key == "/" || path.hasPrefix(key + "/") || key.hasPrefix(path + "/")
    }

    private static func cacheFiles(in dir: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".cache") })
    }

    private static func remove(_ paths: Set<String>, in dir: URL) {
        for p in paths {
            unlink(dir.appendingPathComponent(fileName(for: p)).path)
        }
    }

    private static func dropOverviewSizes(covering path: String, in dir: URL) {
        let file = dir.appendingPathComponent(overviewFile)
        guard let data = try? Data(contentsOf: file),
              let sizes = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let kept = sizes.filter { key, _ in !covers(key, path) }
        guard kept.count != sizes.count else { return }
        guard let out = try? JSONSerialization.data(withJSONObject: kept) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // Atomic, like Mole's own writes, so a scan never reads half a file.
        if (try? out.write(to: file, options: .atomic)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Calls `visit` for `root` and every folder below it, building paths the way Mole does
    /// (parent + "/" + name) and never following symlinks.
    static func walkFolders(under root: String, skip: (String) -> Bool, _ visit: (String) -> Void) {
        var pending = [clean(root)]
        while let folder = pending.popLast() {
            if skip(folder) { continue }
            visit(folder)
            guard let d = opendir(folder) else { continue }
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafePointer(to: e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let child = folder == "/" ? "/" + name : folder + "/" + name
                var isDir = e.pointee.d_type == DT_DIR
                if e.pointee.d_type == DT_UNKNOWN {
                    var st = stat()
                    isDir = lstat(child, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
                }
                if isDir { pending.append(child) }
            }
        }
    }

    // MARK: xxHash64

    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    /// xxHash64 with seed 0, as Mole's Go analyzer (cespare/xxhash) computes it.
    static func xxh64(_ bytes: [UInt8]) -> UInt64 {
        func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
        func round(_ acc: UInt64, _ input: UInt64) -> UInt64 { rotl(acc &+ input &* p2, 31) &* p1 }
        func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 { (acc ^ round(0, val)) &* p1 &+ p4 }
        func u64(_ i: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[i + $1]) << (8 * UInt64($1)) } }
        func u32(_ i: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(bytes[i + $1]) << (8 * UInt64($1)) } }

        let n = bytes.count
        var i = 0
        var h: UInt64
        if n >= 32 {
            var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
            while i + 32 <= n {
                v1 = round(v1, u64(i)); v2 = round(v2, u64(i + 8))
                v3 = round(v3, u64(i + 16)); v4 = round(v4, u64(i + 24))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(merge(merge(merge(h, v1), v2), v3), v4)
        } else {
            h = p5
        }
        h = h &+ UInt64(n)
        while i + 8 <= n {
            h = rotl(h ^ round(0, u64(i)), 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= n {
            h = rotl(h ^ (u32(i) &* p1), 23) &* p2 &+ p3
            i += 4
        }
        while i < n {
            h = rotl(h ^ (UInt64(bytes[i]) &* p5), 11) &* p1
            i += 1
        }
        h ^= h >> 33; h = h &* p2
        h ^= h >> 29; h = h &* p3
        h ^= h >> 32
        return h
    }
}
