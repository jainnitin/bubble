import AppKit
import Observation

/// One line of `mo status --watch` (NDJSON). Every field is optional so a CLI change
/// degrades a card instead of breaking decoding.
struct Snapshot: Decodable {
    struct Hardware: Decodable { var model: String?; var cpuModel: String?; var totalRam: String?; var osVersion: String? }
    struct CPU: Decodable { var usage: Double?; var load1: Double?; var coreCount: Int?; var logicalCpu: Int? }
    struct GPU: Decodable { var usage: Double?; var coreCount: Int? }
    struct Memory: Decodable { var used: Double?; var total: Double?; var usedPercent: Double?; var swapUsed: Double?; var pressure: String? }
    struct Disk: Decodable { var mount: String?; var used: Double?; var total: Double?; var usedPercent: Double? }
    struct Net: Decodable { var name: String?; var rxRateMbs: Double?; var txRateMbs: Double?; var ip: String? }
    struct Battery: Decodable { var percent: Double?; var status: String?; var timeLeft: String?; var cycleCount: Int?; var capacity: Int? }
    struct Thermal: Decodable { var cpuTemp: Double?; var gpuTemp: Double?; var systemPower: Double? }
    struct BT: Decodable { var name: String?; var connected: Bool?; var battery: String? }
    struct Proc: Decodable, Identifiable { var pid: Int; var name: String?; var cpu: Double?; var memoryBytes: Double?; var id: Int { pid } }

    var uptime: String?
    var procs: Int?
    var hardware: Hardware?
    var healthScore: Int?
    var healthScoreMsg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var network: [Net]?
    var batteries: [Battery]?
    var thermal: Thermal?
    var bluetooth: [BT]?
    var topProcesses: [Proc]?
    var trashSize: Double?
}

@Observable
@MainActor
final class StatusModel {
    static let shared = StatusModel()

    var snap: Snapshot?
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netHistory: [Double] = []
    var powerHistory: [Double] = []
    var gpuUsage: Double?
    var history = HistoryTotals()

    // Read natively (see NativeSensors.swift): mo reports zeros without admin rights
    // and lists only its top few processes.
    var cpuTemp: Double?
    var gpuTemp: Double?
    var fans: [(rpm: Double, max: Double)] = []
    var processes: [ProcessSampler.Process] = []
    private var cpuTempPeaks: [(Date, Double)] = []

    /// Hottest CPU reading in the last five minutes.
    var cpuTempPeak: Double? { cpuTempPeaks.map(\.1).max() }

    private var watchTask: Task<Void, Never>?
    private var nativeTask: Task<Void, Never>?
    private let historyLength = 60

    /// How hard to sample. Nobody looking means no work: Bubble idles near zero CPU.
    enum Pace: Equatable {
        /// A Bubble window or the menu bar panel is on screen: Mole every second, plus
        /// temperatures, fans and the process list.
        case live
        /// No window, but the menu bar shows CPU: Mole every 5 seconds, nothing else.
        case background
        /// No window and an icon-only menu bar: nothing runs.
        case off
    }
    private(set) var pace: Pace?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        Task { await refreshHistory() }
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     UserDefaults.didChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose fires before the window is gone; look again on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updatePace() } }
            })
        }
        updatePace()
    }

    private func updatePace() {
        let onScreen = NSApp.windows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible) && !$0.className.contains("StatusBar")
        }
        let defaults = UserDefaults.standard
        let showsNumbers = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
            && (defaults.string(forKey: "menuBarDisplay") ?? "icon") != "icon"
        setPace(onScreen ? .live : showsNumbers ? .background : .off)
    }

    private func setPace(_ new: Pace) {
        guard new != pace, Shell.mo != nil else { return }
        let old = pace
        pace = new
        if new == .off || old == .off || old == nil || (new == .live) != (old == .live) {
            watchTask?.cancel()
            watchTask = nil
        }
        if new != .off, watchTask == nil {
            let interval = new == .live ? "1s" : "5s"
            watchTask = Task { [weak self] in
                while !Task.isCancelled {
                    for await line in Shell.moLines(["status", "--watch", "--interval", interval]) {
                        guard !Task.isCancelled else { break }
                        self?.ingest(line)
                    }
                    // The stream ended (e.g. mo was upgraded); restart after a pause.
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        nativeTask?.cancel()
        nativeTask = nil
        if new == .live {
            nativeTask = Task { [weak self] in
                while !Task.isCancelled {
                    let reading = await Task.detached { SMCReader.shared.read() }.value
                    let procs = await ProcessSampler.sample()
                    guard !Task.isCancelled else { break }
                    self?.ingestNative(reading, procs)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func ingestNative(_ r: SMCReader.Reading, _ procs: [ProcessSampler.Process]) {
        cpuTemp = r.cpuTemp
        gpuTemp = r.gpuTemp
        fans = r.fans
        processes = procs
        ProcessIcons.prune(keeping: procs)
        if let t = r.cpuTemp {
            let now = Date()
            cpuTempPeaks.append((now, t))
            cpuTempPeaks.removeAll { now.timeIntervalSince($0.0) > 300 }
        }
    }

    private func ingest(_ line: String) {
        guard line.first == "{", let data = line.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let s = try? decoder.decode(Snapshot.self, from: data) else { return }
        snap = s
        // Mole reports GPU usage as -1 without sudo; read the accelerator's own counter instead.
        let gpu = s.gpu?.first?.usage.flatMap { $0 >= 0 ? $0 : nil } ?? GPUSampler.utilization()
        gpuUsage = gpu
        push(&cpuHistory, s.cpu?.usage ?? 0)
        push(&gpuHistory, gpu ?? 0)
        push(&memHistory, s.memory?.usedPercent ?? 0)
        push(&netHistory, primaryNet.map { ($0.rxRateMbs ?? 0) + ($0.txRateMbs ?? 0) } ?? 0)
        push(&powerHistory, s.thermal?.systemPower ?? 0)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
    }

    var primaryNet: Snapshot.Net? {
        snap?.network?.max { (($0.rxRateMbs ?? 0) + ($0.txRateMbs ?? 0)) < (($1.rxRateMbs ?? 0) + ($1.txRateMbs ?? 0)) }
    }

    var rootDisk: Snapshot.Disk? {
        snap?.disks?.first { $0.mount == "/" } ?? snap?.disks?.first
    }

    func refreshHistory() async {
        let data = await Shell.moJSON(["history", "--json", "--limit", "200"])
        history = HistoryTotals(json: data)
    }
}

/// Totals from `mo history --json`, shown in the menu bar panel.
///
/// Mole writes a history session for every run, including dry runs and
/// `mo uninstall --list`, which Bubble calls constantly. So:
/// - clean/purge/installer/uninstall sessions count only when they actually
///   removed or trashed something (`actions.removed + actions.trashed > 0`);
/// - optimize sessions can't be told apart from dry runs, so the Optimized
///   figure is Bubble's own counter of real optimize runs (`recordOptimizeRun()`);
/// - Bubble removes apps natively, which Mole never records, so Uninstalled adds
///   Bubble's own count of removed apps (`recordUninstall(count:)`) to the old
///   `mo uninstall` sessions. The two never overlap.
struct HistoryTotals: Equatable {
    var cleanedBytes: Double = 0
    var uninstalled = 0
    var optimized = 0

    static let optimizeRunsKey = "bubbleOptimizeRuns"
    static let uninstallsKey = "bubbleUninstalledApps"

    init() {}

    init(json: Data, optimizeRuns: Int = HistoryTotals.optimizeRunCount(),
         uninstalls: Int = HistoryTotals.uninstallCount()) {
        optimized = optimizeRuns
        uninstalled = uninstalls
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return }
        for s in sessions {
            let cmd = s["command"] as? String ?? ""
            guard Self.didChangeDisk(s) else { continue }
            let size = (s["size"] as? String).flatMap(Fmt.parseSize) ?? 0
            switch cmd {
            case "clean", "purge", "installer": cleanedBytes += size
            case "uninstall": uninstalled += 1; cleanedBytes += size
            default: break
            }
        }
    }

    /// True when the session removed or trashed at least one item. Dry runs and
    /// `uninstall --list` only ever record skipped items (or none).
    static func didChangeDisk(_ session: [String: Any]) -> Bool {
        guard let actions = session["actions"] as? [String: Any] else { return false }
        func n(_ k: String) -> Int { (actions[k] as? NSNumber)?.intValue ?? 0 }
        return n("removed") + n("trashed") > 0
    }

    /// Call once after a real (not dry-run) `mo optimize` that Bubble ran.
    static func recordOptimizeRun(defaults: UserDefaults = .standard) {
        defaults.set(optimizeRunCount(defaults: defaults) + 1, forKey: optimizeRunsKey)
    }

    static func optimizeRunCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: optimizeRunsKey)
    }

    /// Call after Bubble's own app removal with the number of apps actually removed.
    static func recordUninstall(count: Int, defaults: UserDefaults = .standard) {
        guard count > 0 else { return }
        defaults.set(uninstallCount(defaults: defaults) + count, forKey: uninstallsKey)
    }

    static func uninstallCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: uninstallsKey)
    }
}
