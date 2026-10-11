import AppKit
import Foundation
import IOKit

/// Reads temperatures and fan speed straight from the System Management Controller.
/// `mo status` reports zeros for these without admin rights, but reading SMC keys is
/// allowed for any user. Key names differ between chips, so instead of hardcoding
/// them we enumerate every key once and keep the families we understand:
///   Tp…  CPU core temperatures      Tg…  GPU temperatures
///   F0Ac fan 0 actual RPM           F0Mx fan 0 maximum RPM
final class SMCReader: @unchecked Sendable {
    static let shared = SMCReader()

    struct Reading {
        var cpuTemp: Double?
        var gpuTemp: Double?
        var fans: [(rpm: Double, max: Double)]
    }

    private var connection: io_connect_t = 0
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []
    private var fanCount = 0
    private let lock = NSLock()
    private var discovered = false

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
    }

    func read() -> Reading {
        lock.lock(); defer { lock.unlock() }
        guard connection != 0 else { return Reading(fans: []) }
        if !discovered { discover() }
        let cpu = average(cpuKeys)
        let gpu = average(gpuKeys)
        var fans: [(Double, Double)] = []
        for i in 0..<fanCount {
            if let rpm = number(fourCC("F\(i)Ac")) {
                fans.append((rpm, number(fourCC("F\(i)Mx")) ?? 0))
            }
        }
        return Reading(cpuTemp: cpu, gpuTemp: gpu, fans: fans)
    }

    // MARK: Discovery

    private func discover() {
        discovered = true
        fanCount = Int(number(fourCC("FNum")) ?? 0)
        guard let raw = bytes(fourCC("#KEY"))?.1, raw.count >= 4 else { return }
        let total = Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
        for index in 0..<total {
            var input = KeyData()
            input.data8 = Command.keyAtIndex
            input.data32 = UInt32(index)
            guard let out = call(&input) else { continue }
            let name = string(out.key)
            guard name.hasPrefix("Tp") || name.hasPrefix("Tg") else { continue }
            // Keep only sensors that currently report a plausible temperature.
            guard let v = number(out.key), v > 5, v < 125 else { continue }
            if name.hasPrefix("Tp") { cpuKeys.append(out.key) } else { gpuKeys.append(out.key) }
        }
    }

    private func average(_ keys: [UInt32]) -> Double? {
        let values = keys.compactMap(number).filter { $0 > 5 && $0 < 125 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: SMC protocol (same struct layout as the C AppleSMC user client: 80 bytes)

    private enum Command {
        static let read: UInt8 = 5
        static let keyAtIndex: UInt8 = 8
        static let keyInfo: UInt8 = 9
    }

    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    // Swift doesn't pad the tail of a nested struct like C does, so pad explicitly.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &size)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func bytes(_ key: UInt32) -> (String, [UInt8])? {
        var infoIn = KeyData()
        infoIn.key = key
        infoIn.data8 = Command.keyInfo
        guard let info = call(&infoIn)?.keyInfo else { return nil }
        var readIn = KeyData()
        readIn.key = key
        readIn.keyInfo.dataSize = info.dataSize
        readIn.data8 = Command.read
        guard let out = call(&readIn) else { return nil }
        let raw = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) }
        return (string(info.dataType), raw)
    }

    private func number(_ key: UInt32) -> Double? {
        guard let (type, b) = bytes(key) else { return nil }
        switch type {
        case "flt ": return b.count >= 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case "sp78": return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "ui8 ": return b.first.map(Double.init)
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        default: return nil
        }
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }, encoding: .ascii) ?? "????"
    }
}

/// Every process, not just the handful `mo status` reports. `ps` can see CPU and
/// memory for root-owned processes too, which libproc can't without admin rights.
enum ProcessSampler {
    struct Process: Identifiable, Hashable {
        var pid: Int
        var name: String
        /// The executable path from `proc_pidpath` when readable, else ps's `comm`.
        var path: String
        var cpu: Double
        var memoryBytes: Double
        /// Process start time (µs since 1970) when readable, to tell a reused PID apart.
        var startTime: UInt64? = nil
        var id: Int { pid }
    }

    static func sample() async -> [Process] {
        let data = await Shell.output("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="])
        var out: [Process] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1]), let rssKB = Double(parts[2]) else { continue }
            let comm = String(parts[3])
            let path = ProcessControl.executablePath(pid: pid) ?? comm
            out.append(Process(pid: pid, name: (comm as NSString).lastPathComponent, path: path, cpu: cpu,
                               memoryBytes: rssKB * 1024, startTime: ProcessControl.startTime(pid: pid)))
        }
        return out
    }
}

/// Quit / Force Quit for the process table. The table shows a snapshot up to two
/// seconds old and the confirmation can stay open indefinitely, so right before
/// signalling we re-check that the PID still runs the same executable (and, when
/// readable, started at the same time). Otherwise the PID may have been reused.
enum ProcessControl {
    static func executablePath(pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid_t(pid), &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func startTime(pid: Int) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Nil when the live process still matches the sampled one; otherwise why not.
    static func mismatch(sampledPath: String, sampledStart: UInt64?, currentPath: String?, currentStart: UInt64?) -> String? {
        guard let currentPath else { return "The process has already quit." }
        if currentPath != sampledPath { return "This process ID now belongs to a different program, so nothing was sent." }
        if let a = sampledStart, let b = currentStart, a != b {
            return "This process ID now belongs to a new process, so nothing was sent."
        }
        return nil
    }

    /// Quits (SIGTERM / NSRunningApplication.terminate) or force quits the process.
    /// Returns nil on success, or a message explaining why nothing was done.
    @MainActor static func terminate(_ p: ProcessSampler.Process, force: Bool) -> String? {
        if let problem = mismatch(sampledPath: p.path, sampledStart: p.startTime,
                                  currentPath: executablePath(pid: p.pid), currentStart: startTime(pid: p.pid)) {
            return problem
        }
        if let app = NSRunningApplication(processIdentifier: pid_t(p.pid)) {
            let ok = force ? app.forceTerminate() : app.terminate()
            return ok ? nil : "macOS didn't accept the request to quit \(app.localizedName ?? p.name)."
        }
        if kill(pid_t(p.pid), force ? SIGKILL : SIGTERM) == 0 { return nil }
        switch errno {
        case EPERM: return "\(p.name) belongs to another user or to macOS, so Bubble can't quit it."
        case ESRCH: return "The process has already quit."
        default: return "Couldn't quit \(p.name): \(String(cString: strerror(errno)))."
        }
    }
}

enum GPUSampler {
    /// "Device Utilization %" from the IOAccelerator registry entry; no admin rights needed.
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let value = perf["Device Utilization %"] as? NSNumber {
                result = max(result ?? 0, value.doubleValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }
}

/// App names and icons for the process table, cached by (pid, executable path)
/// so a reused PID never shows the previous process's name or icon. Entries for
/// processes missing from the latest sample are pruned, so the cache stays bounded.
enum ProcessIcons {
    struct Key: Hashable { var pid: Int; var path: String }

    @MainActor private static var icons: [Key: NSImage?] = [:]
    @MainActor private static var names: [Key: String?] = [:]

    @MainActor static var cacheCount: Int { max(icons.count, names.count) }

    /// App display name ("Safari") instead of the executable name, when it's an app.
    @MainActor static func name(pid: Int, path: String) -> String? {
        let key = Key(pid: pid, path: path)
        if let hit = names[key] { return hit }
        let n = app(pid: pid, path: path)?.localizedName
        names[key] = n
        return n
    }

    @MainActor static func icon(pid: Int, path: String) -> NSImage? {
        let key = Key(pid: pid, path: path)
        if let hit = icons[key] { return hit }
        let img = app(pid: pid, path: path)?.icon
        icons[key] = img
        return img
    }

    /// Drops every entry whose (pid, path) isn't in `processes`.
    @MainActor static func prune(keeping processes: [ProcessSampler.Process]) {
        let live = Set(processes.map { Key(pid: $0.pid, path: $0.path) })
        icons = icons.filter { live.contains($0.key) }
        names = names.filter { live.contains($0.key) }
    }

    /// The running app at `pid`, only if its executable is still the one sampled.
    @MainActor private static func app(pid: Int, path: String) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return nil }
        if let exe = ProcessControl.executablePath(pid: pid), exe != path { return nil }
        return app
    }
}
