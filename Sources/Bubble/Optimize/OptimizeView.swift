import SwiftUI

struct OptimizeTask: Identifiable {
    var name: String
    var results: [String] = []
    var id: String { name }

    /// Mole prefixes outcome lines with → (done), ◎ (needs attention), - (skipped), ✓ (fine).
    var symbol: (String, Color) {
        if results.contains(where: { $0.hasPrefix("◎") || $0.hasPrefix("✗") }) { return ("exclamationmark.circle", Palette.amber) }
        if results.allSatisfy({ $0.hasPrefix("-") }) && !results.isEmpty { return ("minus.circle", Palette.tertiary) }
        return ("checkmark", Palette.green)
    }
}

@Observable
@MainActor
final class OptimizeModel {
    enum Phase { case idle, running, done }
    var phase: Phase = .idle
    var plannedCount = 0
    var tasks: [OptimizeTask] = []
    var skippedAdmin = false
    /// Prompts Mole showed that Bubble declined rather than confirm on your behalf.
    var skippedPrompts: [String] = []
    /// Passwords typed after sudo had moved on, which Bubble discarded unsent.
    var stalePasswordsDiscarded = 0
    /// The user pressed Stop during this run.
    var stopped = false
    private var job: Task<Void, Never>?

    /// The dry run's task count, kept for the whole session: every `mo optimize --dry-run`
    /// adds an entry to Mole's history, so it runs once, when Optimize is first shown.
    private static var sessionPlan: Int?
    private var planning = false

    /// A dry run lists every task Mole will run, so progress can show "5 / 21".
    func plan() async {
        if let n = Self.sessionPlan {
            plannedCount = n
            return
        }
        guard !planning, Shell.mo != nil else { return }
        planning = true
        defer { planning = false }
        let text = await Shell.moText(["optimize", "--dry-run"])
        let n = text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("➤") }.count
        guard n > 0 else { return }
        Self.sessionPlan = n
        plannedCount = n
    }

    func run() {
        guard phase != .running, let mo = Shell.mo else { return }
        phase = .running
        tasks = []
        skippedPrompts = []
        skippedAdmin = false
        stopped = false
        stalePasswordsDiscarded = 0
        job = Task {
            // Run in a pseudo-terminal so Mole can ask for the admin password.
            let session = PTYSession(mo, ["optimize"])
            let responder = PromptResponder(reason: "Flushing DNS, rebuilding Spotlight and other system maintenance. Skip to run the rest without it.")
            for await line in session.lines {
                if responder.handle(line, session) { continue }
                if line.hasPrefix("➤") {
                    tasks.append(OptimizeTask(name: line.dropFirst().trimmingCharacters(in: .whitespaces)))
                } else if !tasks.isEmpty, let first = line.first, "→◎-✓✗".contains(first) {
                    tasks[tasks.count - 1].results.append(line)
                }
                if line.contains("admin access not granted") || line.contains("admin access required") { skippedAdmin = true }
            }
            skippedPrompts = responder.skippedPrompts
            stalePasswordsDiscarded = responder.stalePasswordsDiscarded
            phase = .done
            // Mole's history can't tell real optimize runs from dry runs, so Bubble counts
            // its own real runs (any that got as far as running a task, stopped or not).
            if !tasks.isEmpty { HistoryTotals.recordOptimizeRun() }
            await StatusModel.shared.refreshHistory()
        }
    }

    /// Stops Mole between steps (cancelling the task terminates the process).
    func stop() {
        guard phase == .running else { return }
        stopped = true
        job?.cancel()
    }
}

struct OptimizeView: View {
    @State private var model = OptimizeModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.screenVisible) private var visible

    var body: some View {
        ZStack {
            if model.phase == .done {
                results.transition(.opacity)
            } else {
                // One hero for idle and running, so the bubble stays put while the text changes.
                HeroView {
                    ZStack(alignment: .leading) {
                        heroContent
                            .id(model.phase == .running)
                            .transition(.phase(reduceMotion: reduceMotion))
                    }
                    .motion(model.phase == .running)
                }
                .transition(.opacity)
            }
        }
        .motion(model.phase == .done)
        .sensoryFeedback(.success, trigger: model.phase == .done)
        // Only once Optimize is actually opened (screens are built at launch).
        .task(id: visible) { if visible { await model.plan() } }
    }

    @ViewBuilder
    private var heroContent: some View {
        if model.phase == .running {
            let total = max(model.plannedCount, model.tasks.count, 1)
            VStack(alignment: .leading, spacing: Space.l) {
                Headline(text: "Running maintenance")
                VStack(alignment: .leading, spacing: Space.s) {
                    ProgressView(value: Double(model.tasks.count), total: Double(total))
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                        .frame(maxWidth: 360)
                        .motion(model.tasks.count)
                    Text("\(model.tasks.last?.name ?? "Checking your Mac"), \(model.tasks.count) of \(total)")
                        .font(.num(.body)).foregroundStyle(Palette.secondary)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
                TaskList(tasks: Array(model.tasks.suffix(5)), runningLast: true)
                LinkButton(title: model.stopped ? "Stopping…" : "Stop") { model.stop() }
                    .disabled(model.stopped)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.l) {
                Headline(text: "Keep things running smoothly")
                Lede(text: "Flush DNS, refresh Finder and Spotlight caches, repair preferences and tidy what slows your Mac down.")
                PillButton(title: "Run maintenance") { model.run() }.padding(.top, Space.s)
                Hint(icon: "lock", text: "Takes about a minute. Some tasks ask for your password.")
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xl) {
                BubbleView().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(model.stopped ? "Maintenance stopped" : "Maintenance complete").font(.ui(.title, .bold))
                    Text(summary).font(.ui(.body)).foregroundStyle(Palette.secondary)
                    ForEach(model.skippedPrompts, id: \.self) { p in
                        Label("Skipped: \(p)", systemImage: "hand.raised")
                            .font(.ui(.secondary)).foregroundStyle(Palette.amber)
                    }
                }
                Spacer()
                PillButton(title: "Run again", width: 180) { model.run() }
            }
            .padding(.bottom, Space.l)
            // One panel with dividers rather than a card per task.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.tasks.enumerated()), id: \.offset) { i, t in
                        if i > 0 { Divider().overlay(Palette.cardStroke).padding(.leading, 44) }
                        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                            Image(systemName: t.symbol.0).foregroundStyle(t.symbol.1).frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.ui(.body, .semibold))
                                ForEach(t.results, id: \.self) { r in
                                    Text(r.dropFirst().trimmingCharacters(in: .whitespaces))
                                        .font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .panel()
            }
        }
        .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
    }

    private var summary: String {
        let issues = model.tasks.filter { $0.symbol.0 == "exclamationmark.circle" }.count
        var s = model.stopped ? "Stopped after \(model.tasks.count) tasks" : "\(model.tasks.count) tasks ran"
        if issues > 0 { s += ", \(issues) need a look" }
        if model.skippedAdmin { s += ". Tasks that need admin rights were skipped." }
        if model.stalePasswordsDiscarded > 0 {
            s += (s.hasSuffix(".") ? " " : ". ") + "A password you typed arrived after Mole had moved on, so Bubble discarded it without sending it."
        }
        return s + (s.hasSuffix(".") ? "" : ".")
    }
}

struct TaskList: View {
    let tasks: [OptimizeTask]
    var runningLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(tasks.enumerated()), id: \.element.name) { i, t in
                HStack(spacing: Space.m) {
                    if runningLast && i == tasks.count - 1 {
                        ProgressView().controlSize(.mini).frame(width: 16)
                    } else {
                        Image(systemName: t.symbol.0).foregroundStyle(t.symbol.1).frame(width: 16)
                    }
                    Text(t.name)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .font(.ui(.body))
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: 460, alignment: .leading)
        .padding(Space.l)
        .panel(radius: Radius.row)
        .motion(tasks.map(\.name))
        .accessibilityElement(children: .combine)
    }
}
