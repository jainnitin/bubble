import AppKit
import SwiftUI

struct StatusView: View {
    @Environment(StatusModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 16
            // The first card in each row is one and a half times as wide as the others.
            let unit = (geo.size.width - 48 - gap * 3) / 4.5
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    HealthCard().frame(width: unit * 1.5)
                    CPUCard()
                    GPUCard()
                    MemoryCard()
                }
                .frame(height: 164)
                HStack(spacing: gap) {
                    PowerOrBatteryCard().frame(width: unit * 1.5)
                    DiskCard()
                    NetworkCard()
                    FanOrSystemCard()
                }
                .frame(height: 164)
                ProcessTable()
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.l)
        }
        .overlay {
            if model.snap == nil {
                ProgressView("Reading sensors…").controlSize(.large)
            }
        }
    }
}

// MARK: - Card scaffolding

struct MetricCard<Body: View>: View {
    let icon: String
    let title: String
    var badge: String?
    var iconColor: Color = Palette.secondary
    var tags: [String] = []
    @ViewBuilder var content: Body

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label {
                        Text(title).font(.ui(.secondary, .semibold))
                    } icon: {
                        Image(systemName: icon).foregroundStyle(iconColor)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
                    Spacer(minLength: Space.s)
                    // In a narrow window, drop tags from the end rather than wrap the title.
                    ViewThatFits(in: .horizontal) {
                        ForEach((0...tags.count).reversed(), id: \.self) { n in
                            HStack(spacing: Space.s) {
                                if let badge { Tag(text: badge) }
                                ForEach(tags.prefix(n), id: \.self) { Tag(text: $0) }
                            }
                            .fixedSize()
                        }
                        if let badge { Tag(text: badge).lineLimit(1) }
                    }
                }
                content
            }
        }
        // VoiceOver reads each card as one sentence ("CPU, 5%, idle, load 1.6…").
        .accessibilityElement(children: .combine)
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Live metrics update every second; rolling digits here would mean
            // constant blur-animated redraws, so they change in place like Activity Monitor.
            Text(value).font(.num(.title, .bold))
            Text(unit).font(.ui(.secondary, .medium)).foregroundStyle(Palette.secondary)
        }
        .padding(.top, Space.s)
    }
}

struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(.caption)).foregroundStyle(Palette.secondary).lineLimit(1)
    }
}

/// Little vertical bars, newest on the right (CPU).
struct BarSpark: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let count = 16
            let recent = Array(values.suffix(count))
            let padded = Array(repeating: 0.0, count: max(0, count - recent.count)) + recent
            let w = (geo.size.width - CGFloat(count - 1) * 4) / CGFloat(count)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(padded.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.85))
                        .frame(width: w, height: max(2, geo.size.height * min(padded[i], 100) / 100))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Smooth line with a soft fill underneath (GPU, memory, network, power).
struct LineSpark: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let top = max(maxValue ?? (values.max() ?? 1) * 1.25, 0.0001)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height - 2 - (size.height - 4) * CGFloat(min(v / top, 1)))
        }
    }
}

struct Meter: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(14, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 14)
    }
}

private extension View {
    /// A card's chart fills the space between its number and its footnote.
    func sparkFrame() -> some View {
        frame(minHeight: 22, maxHeight: .infinity).padding(.vertical, Space.s).layoutPriority(1).accessibilityHidden(true)
    }
}

// MARK: - Cards

struct HealthCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let s = model.snap
        let score = s?.healthScore ?? 0
        let color = score >= 80 ? Palette.green : score >= 50 ? Palette.amber : Palette.red
        MetricCard(icon: "sun.max", title: "Health", iconColor: color, tags: hardwareTags(s)) {
            VStack(alignment: .leading, spacing: 0) {
                // The bubble sits beside the score, centred on it, clear of the tag row.
                HStack(alignment: .center, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(score)").font(.num(.title, .bold))
                            Text(s?.healthScoreMsg ?? "").font(.ui(.section, .medium)).foregroundStyle(.white.opacity(0.8))
                        }
                        Text(score >= 80 ? "All checks passed" : "Some checks need attention")
                            .font(.ui(.body)).foregroundStyle(Palette.secondary).padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                    BubbleView().frame(width: 60, height: 60).padding(.trailing, Space.xs)
                }
                .padding(.top, 14)
                Spacer(minLength: Space.s)
                Footnote(text: "Up \(s?.uptime ?? "—"), \(s?.procs ?? 0) processes")
            }
        }
    }

    private func hardwareTags(_ s: Snapshot?) -> [String] {
        [s?.hardware?.cpuModel?.replacingOccurrences(of: "Apple ", with: ""),
         s?.hardware?.totalRam?.replacingOccurrences(of: ".0 ", with: " "),
         s?.hardware?.osVersion].compactMap { $0 }
    }
}

struct CPUCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let cpu = model.snap?.cpu
        let temp = model.cpuTemp ?? model.snap?.thermal?.cpuTemp ?? 0
        MetricCard(icon: "cpu", title: "CPU", badge: temp > 0 ? "\(Int(temp.rounded()))°C" : nil) {
            BigNumber(value: "\(Int((cpu?.usage ?? 0).rounded()))", unit: "%")
            BarSpark(values: model.cpuHistory, color: Palette.green).sparkFrame()
            Spacer(minLength: 0)
            Footnote(text: "\(busy(cpu?.usage).capitalized), load \(String(format: "%.1f", cpu?.load1 ?? 0)) on \(cpu?.logicalCpu ?? cpu?.coreCount ?? 0) cores")
        }
    }

    private func busy(_ u: Double?) -> String {
        guard let u else { return "—" }
        return u < 15 ? "idle" : u < 60 ? "busy" : "under load"
    }
}

struct GPUCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let gpu = model.snap?.gpu?.first
        let temp = model.gpuTemp ?? model.snap?.thermal?.gpuTemp ?? 0
        let usage = model.gpuUsage
        MetricCard(icon: "display", title: "GPU", badge: temp > 0 ? "\(Int(temp.rounded()))°C" : nil) {
            BigNumber(value: usage.map { "\(Int($0.rounded()))" } ?? "—", unit: "%")
            LineSpark(values: model.gpuHistory, color: Palette.amber, maxValue: 100).sparkFrame()
            Spacer(minLength: 0)
            Footnote(text: "\((usage ?? 0) < 10 ? "Idle" : "Active"), \(gpu?.coreCount ?? 0) GPU cores")
        }
    }
}

struct MemoryCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let m = model.snap?.memory
        let pressure = (m?.pressure ?? "").isEmpty ? "normal" : m!.pressure!
        MetricCard(icon: "memorychip", title: "Memory", badge: "Pressure \(pressure)") {
            BigNumber(value: "\(Int((m?.usedPercent ?? 0).rounded()))", unit: "%")
            LineSpark(values: model.memHistory, color: Palette.amber, maxValue: 100).sparkFrame()
            Spacer(minLength: 0)
            Footnote(text: "\(Fmt.memory(m?.used ?? 0)) of \(Fmt.memory(m?.total ?? 0)), \(Fmt.memory(m?.swapUsed ?? 0)) swap")
        }
    }
}

struct PowerOrBatteryCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let t = model.snap?.thermal
        if let b = model.snap?.batteries?.first {
            MetricCard(icon: "battery.75percent", title: "Battery", badge: b.capacity.map { "\($0)% Health" }, iconColor: Palette.green) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BigNumber(value: "\(Int(b.percent ?? 0))", unit: "%")
                    Text(b.status?.capitalized ?? "").font(.ui(.section, .medium)).foregroundStyle(.white.opacity(0.8))
                }
                Meter(fraction: (b.percent ?? 0) / 100, color: Palette.green).padding(.vertical, 18)
                Spacer(minLength: 0)
                Footnote(text: [b.cycleCount.map { "\($0) cycles" }, b.timeLeft].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            }
        } else if let cpuTemp = model.cpuTemp {
            let (label, color) = cpuTemp < 70 ? ("Normal", Palette.green) : cpuTemp < 85 ? ("Warm", Palette.amber) : ("Hot", Palette.red)
            MetricCard(icon: "thermometer.medium", title: "Thermal", badge: label, iconColor: color) {
                HStack(spacing: Space.xl) {
                    temp("CPU", cpuTemp, color)
                    if let g = model.gpuTemp { temp("GPU", g, color) }
                }
                .padding(.top, Space.s)
                Meter(fraction: cpuTemp / 100, color: color).padding(.vertical, Space.m)
                Spacer(minLength: 0)
                Footnote(text: [model.snap?.hardware?.cpuModel?.replacingOccurrences(of: "Apple ", with: ""),
                                model.cpuTempPeak.map { "peak \(Int($0.rounded()))° in 5 min" },
                                t?.systemPower.map { String(format: "%.1f W draw", $0) }]
                    .compactMap { $0 }.joined(separator: ", "))
            }
        } else {
            MetricCard(icon: "bolt", title: "Power", badge: "Wall power", iconColor: Palette.amber) {
                BigNumber(value: String(format: "%.1f", t?.systemPower ?? 0), unit: "W")
                LineSpark(values: model.powerHistory, color: Palette.amber).sparkFrame()
                Spacer(minLength: 0)
                Footnote(text: "Whole \(model.snap?.hardware?.model ?? "Mac") draw")
            }
        }
    }

    private func temp(_ label: String, _ v: Double, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(Int(v.rounded()))°").font(.num(.title, .bold))
            Text(label).font(.ui(.secondary, .medium)).foregroundStyle(color)
        }
    }
}

struct DiskCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let d = model.rootDisk
        let free = max((d?.total ?? 0) - (d?.used ?? 0), 0)
        let parts = Fmt.bytes(free).split(separator: " ")
        MetricCard(icon: "internaldrive", title: "Free space", badge: d.map { Fmt.bytes($0.total ?? 0) }) {
            BigNumber(value: String(parts.first ?? "—"), unit: String(parts.last ?? ""))
            Meter(fraction: (d?.usedPercent ?? 0) / 100, color: Palette.blue).padding(.vertical, Space.l)
            Spacer(minLength: 0)
            Footnote(text: "\(Fmt.bytes(d?.used ?? 0)) used, \(Int(d?.usedPercent ?? 0))%")
        }
    }
}

struct NetworkCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        let n = model.primaryNet
        let down = Fmt.rate(n?.rxRateMbs ?? 0)
        let up = Fmt.rate(n?.txRateMbs ?? 0)
        let kind = (n?.name ?? "").hasPrefix("en0") ? "Wi‑Fi / Ethernet" : (n?.name ?? "—")
        MetricCard(icon: "globe", title: "Network", badge: n?.name) {
            BigNumber(value: down.0, unit: down.1)
            LineSpark(values: model.netHistory, color: Palette.blue).sparkFrame()
            Spacer(minLength: 0)
            Footnote(text: "Up \(up.0) \(up.1), \(n?.ip ?? kind)")
        }
    }
}

struct FanOrSystemCard: View {
    @Environment(StatusModel.self) private var model
    var body: some View {
        if let fan = model.fans.first {
            let speed = fan.max > 0 ? fan.rpm / fan.max : 0
            MetricCard(icon: "fanblades", title: "Fan", badge: "Speed \(Int((speed * 100).rounded()))%", iconColor: Palette.amber) {
                BigNumber(value: Int(fan.rpm.rounded()).formatted(), unit: "RPM")
                Meter(fraction: speed, color: Palette.amber).padding(.vertical, Space.m)
                Spacer(minLength: 0)
                Footnote(text: "Managed by macOS, up to \(Int(fan.max).formatted()) RPM")
            }
        } else {
            let trash = model.snap?.trashSize ?? 0
            let connected = model.snap?.bluetooth?.filter { $0.connected == true } ?? []
            MetricCard(icon: "dot.radiowaves.left.and.right", title: "Devices", badge: "\(connected.count) connected", iconColor: Palette.blue) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(connected.prefix(3).enumerated()), id: \.offset) { _, d in
                        HStack {
                            Text(d.name ?? "Device").lineLimit(1)
                            Spacer()
                            if let b = d.battery, !b.isEmpty { Text(b).foregroundStyle(Palette.green).monospacedDigit() }
                        }
                        .font(.ui(.secondary))
                    }
                    if connected.isEmpty {
                        Text("No Bluetooth devices connected").font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.top, Space.m)
                Spacer(minLength: 0)
                Footnote(text: "Trash \(trash > 0 ? Fmt.bytes(trash) : "empty")")
            }
        }
    }
}

// MARK: - Process table

struct ProcessTable: View {
    @Environment(StatusModel.self) private var model
    @State private var sort: Column = .mem
    @State private var pendingKill: ProcessSampler.Process?
    @State private var killError: String?

    enum Column { case name, mem, cpu, pid }

    var body: some View {
        // The full process list (ps), not just mo's top five. Show the top 120 for the chosen sort.
        let procs = Array(sorted(model.processes).prefix(120))
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    header("Process (\(model.processes.count))", .name).frame(maxWidth: .infinity, alignment: .leading)
                    header("Memory", .mem).frame(width: 110, alignment: .trailing)
                    header("CPU %", .cpu).frame(width: 190, alignment: .trailing)
                    header("PID", .pid).frame(width: 110, alignment: .trailing)
                    Spacer().frame(width: 40)
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                Divider().overlay(Palette.cardStroke)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(procs) { p in row(p) }
                    }
                }
            }
        }
        .alert("Force quit \(pendingKill?.name ?? "")?", isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } })) {
            Button("Force Quit", role: .destructive) {
                if let p = pendingKill { killError = ProcessControl.terminate(p, force: true) }
                pendingKill = nil
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: {
            Text("Unsaved work in this process will be lost.")
        }
        .alert("Nothing was quit", isPresented: Binding(get: { killError != nil }, set: { if !$0 { killError = nil } })) {
            Button("OK", role: .cancel) { killError = nil }
        } message: {
            Text(killError ?? "")
        }
    }

    private func header(_ title: String, _ col: Column) -> some View {
        Button { sort = col } label: {
            Text(title)
                .font(.ui(.secondary, .semibold))
                .lineLimit(1)
                .foregroundStyle(sort == col ? .white : Palette.tertiary)
        }
        .buttonStyle(.quiet)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityAddTraits(sort == col ? .isSelected : [])
    }

    private func sorted(_ p: [ProcessSampler.Process]) -> [ProcessSampler.Process] {
        switch sort {
        case .name: p.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mem: p.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu: p.sorted { $0.cpu > $1.cpu }
        case .pid: p.sorted { $0.pid < $1.pid }
        }
    }

    private func row(_ p: ProcessSampler.Process) -> some View {
        let cpu = p.cpu
        let heat = cpu >= 80 ? Palette.red : cpu >= 40 ? Palette.amber : Color.white.opacity(0.75)
        return HStack {
            Rectangle().fill(cpu >= 40 ? heat : .clear).frame(width: 3, height: 22).padding(.trailing, 8)
            Group {
                if let icon = ProcessIcons.icon(pid: p.pid, path: p.path) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").resizable().scaledToFit().padding(3).foregroundStyle(Palette.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            Text(ProcessIcons.name(pid: p.pid, path: p.path) ?? p.name).font(.ui(.body, .medium)).lineLimit(1).help(p.path)
            Spacer()
            Text(Fmt.memory(p.memoryBytes)).frame(width: 110, alignment: .trailing)
            HStack(spacing: 14) {
                Meter(fraction: cpu / 100, color: heat).frame(width: 72).scaleEffect(y: 0.6)
                Text(String(format: "%.1f", cpu)).foregroundStyle(heat).frame(width: 54, alignment: .trailing)
            }
            .frame(width: 190, alignment: .trailing)
            Text(verbatim: String(p.pid)).foregroundStyle(Palette.tertiary).frame(width: 110, alignment: .trailing)
            Menu {
                Button("Quit") { killError = ProcessControl.terminate(p, force: false) }
                Button("Force Quit…") { pendingKill = p }
                Divider()
                Button("Copy PID") {
                    Clipboard.copy("\(p.pid)")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Actions for \(p.name)")
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40)
        }
        .font(.ui(.body)).monospacedDigit()
        .padding(.leading, Space.s).padding(.trailing, Space.l).padding(.vertical, 6)
    }
}
