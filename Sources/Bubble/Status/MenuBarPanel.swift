import SwiftUI

/// Compact status panel shown from the menu bar icon.
struct MenuBarPanel: View {
    @Environment(StatusModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sun.max").foregroundStyle(Palette.green).font(.ui(.section))
                Text("\(s?.healthScore ?? 0)").font(.ui(.title, .bold))
                Text(s?.healthScoreMsg ?? "").font(.ui(.body, .medium)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.quiet).foregroundStyle(Palette.secondary).help("Open Bubble")
            }
            HStack(spacing: 6) {
                if let cpu = s?.hardware?.cpuModel { Tag(text: cpu.replacingOccurrences(of: "Apple ", with: "")) }
                if let ram = s?.hardware?.totalRam { Tag(text: ram.replacingOccurrences(of: ".0 ", with: " ")) }
                Tag(text: "up \(s?.uptime ?? "—")")
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    mini("cpu", "CPU", "\(Int((s?.cpu?.usage ?? 0).rounded()))", "%") {
                        BarSpark(values: model.cpuHistory, color: Palette.green)
                    }
                    mini("display", "GPU", model.gpuUsage.map { "\(Int($0.rounded()))" } ?? "—", "%") {
                        LineSpark(values: model.gpuHistory, color: Palette.amber, maxValue: 100)
                    }
                }
                GridRow {
                    mini("memorychip", "Mem", "\(Int((s?.memory?.usedPercent ?? 0).rounded()))", "%") {
                        LineSpark(values: model.memHistory, color: Palette.amber, maxValue: 100)
                    }
                    let d = model.rootDisk
                    mini("internaldrive", "Disk", "\(Int(d?.usedPercent ?? 0))", "% used") {
                        Meter(fraction: (d?.usedPercent ?? 0) / 100, color: Palette.blue).scaleEffect(y: 0.7)
                    }
                }
            }

            Card(padding: 14) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Top Processes", systemImage: "chart.bar").foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text("Memory").frame(width: 80, alignment: .trailing)
                        Text("% CPU").frame(width: 56, alignment: .trailing)
                    }
                    .font(.ui(.caption, .medium)).foregroundStyle(Palette.secondary)
                    ForEach((s?.topProcesses ?? []).sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }.prefix(5)) { p in
                        HStack {
                            Text(p.name ?? "?").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.memory(p.memoryBytes ?? 0)).frame(width: 80, alignment: .trailing)
                            Text(String(format: "%.1f", p.cpu ?? 0)).frame(width: 56, alignment: .trailing)
                        }
                        .font(.ui(.secondary)).monospacedDigit()
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Clean History", systemImage: "sparkles").font(.ui(.caption, .medium)).foregroundStyle(Palette.green)
                    HStack {
                        stat(Fmt.bytes(model.history.cleanedBytes), "Cleaned")
                        stat("\(model.history.uninstalled)", "Uninstalled")
                        stat("\(model.history.optimized)", "Optimized")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Quit Bubble") { NSApp.terminate(nil) }
                    .buttonStyle(.quiet).font(.ui(.caption)).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(Space.l)
        .frame(width: 380)
        // System material tinted with the app's ink, so the panel reads as Bubble.
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(colors: [Palette.depth.opacity(0.55), Palette.abyss.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .task { await model.refreshHistory() }
    }

    private func mini<S: View>(_ icon: String, _ title: String, _ value: String, _ unit: String, @ViewBuilder spark: () -> S) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.ui(.caption, .medium)).foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.ui(.title, .bold)).monospacedDigit()
                    Text(unit).font(.ui(.caption)).foregroundStyle(Palette.secondary)
                }
                spark().frame(height: 18)
            }
        }
        .frame(height: 104)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(.section, .semibold))
            Text(label).font(.ui(.caption)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
