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
    /// What happened to the admin step this run.
    enum AdminOutcome: Equatable {
        /// Mole didn't skip anything that needs admin rights (or the run was stopped first).
        case notNeeded
        /// Admin tasks are switched off; Mole's admin tasks were skipped.
        case off
        /// Nothing to authorize (e.g. the DNS flush was skipped for a VPN).
        case nothingToDo
        case ran
        case cancelled
        case failed
    }

    static let adminTasksKey = "optimizeAdminTasks"
    /// The admin step gives up after this long with nobody answering.
    static let adminTimeout: TimeInterval = 300

    var phase: Phase = .idle
    var plannedCount = 0
    var tasks: [OptimizeTask] = []
    var adminOutcome: AdminOutcome = .notNeeded
    /// True while the authorization (Touch ID sheet or dialog) is up or the admin script runs.
    var authorizing = false
    /// Admin rows Bubble expects to add this run, for the progress total.
    var expectedAdminRows = 0
    /// Prompts Mole showed that Bubble declined rather than confirm on your behalf.
    var skippedPrompts: [String] = []
    /// Tasks Mole skipped because Bubble has no Full Disk Access.
    var skippedForFullDiskAccess: Set<String> = []
    /// The user pressed Stop during this run.
    var stopped = false
    private var job: Task<Void, Never>?

    /// The dry run's task count, kept for the whole session: every `mo optimize --dry-run`
    /// adds an entry to Mole's history, so it runs once, when Optimize is first shown.
    private static var sessionPlan: Int?
    private var planning = false

    /// Progress total: Mole's planned tasks plus Bubble's admin rows.
    var total: Int { max(plannedCount + expectedAdminRows, tasks.count, 1) }

    /// A dry run lists every task Mole will run, so progress can show "5 / 21".
    func plan() async {
        if let n = Self.sessionPlan {
            plannedCount = n
            return
        }
        guard !planning, Shell.mo != nil else { return }
        planning = true
        // The dry run runs every task's checks too, so it skips the same protected-data tasks.
        _ = OptimizeWhitelist.begin(fullDiskAccess: MoleInstall.hasFullDiskAccess)
        defer {
            OptimizeWhitelist.end()
            planning = false
        }
        let text = await Shell.moText(["optimize", "--dry-run"])
        let n = text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("➤") }.count
        guard n > 0 else { return }
        Self.sessionPlan = n
        plannedCount = n
    }

    /// - Parameter adminTasks: afterwards, run the admin tasks Mole skipped behind one
    ///   authorization. Off means nothing asks for anything.
    func run(adminTasks: Bool) {
        guard phase != .running, let mo = Shell.mo else { return }
        phase = .running
        tasks = []
        skippedPrompts = []
        adminOutcome = .notNeeded
        authorizing = false
        stopped = false
        expectedAdminRows = adminTasks ? 1 : 0
        skippedForFullDiskAccess = []
        job = Task {
            // Without Full Disk Access, tasks that read other apps' data would set off a
            // stream of privacy prompts; Mole skips them for this run.
            let fdaSkips = OptimizeWhitelist.begin(fullDiskAccess: MoleInstall.hasFullDiskAccess)
            defer { OptimizeWhitelist.end() }
            // Mole runs without admin rights: sudo is unavailable to it, and should its
            // password prompt appear anyway, the responder ends it at once (no dialog).
            let shim = MoleNoSudo.make()
            defer { MoleNoSudo.remove(shim) }
            let session = PTYSession(mo, ["optimize"], environment: MoleNoSudo.environment(shimDir: shim))
            let responder = PromptResponder(reason: "", policy: .optimize)
            var log = OptimizeLog(adminTasksOn: adminTasks, skippedForFullDiskAccess: fdaSkips)
            for await line in session.lines {
                if responder.handle(line, session) { continue }
                log.consume(line)
                tasks = log.tasks
                // Mole says up front when it has no admin rights; if it reached a task
                // without saying so, it had them and did the admin work itself.
                if !log.moleSkippedAdmin && !responder.adminSkipped && !tasks.isEmpty { expectedAdminRows = 0 }
            }
            skippedPrompts = responder.skippedPrompts
            skippedForFullDiskAccess = Set(tasks.filter { $0.results.contains(OptimizeLog.fullDiskAccessSkip) }.map(\.name))
            let moleSkippedAdmin = log.moleSkippedAdmin || responder.adminSkipped
            if !stopped && !Task.isCancelled && !tasks.isEmpty && moleSkippedAdmin {
                if adminTasks {
                    await runAdminTasks(spotlight: log.deferred.contains(.spotlight))
                } else {
                    adminOutcome = .off
                }
            }
            expectedAdminRows = 0
            phase = .done
            // Mole's history can't tell real optimize runs from dry runs, so Bubble counts
            // its own real runs (any that got as far as running a task, stopped or not).
            if !tasks.isEmpty { HistoryTotals.recordOptimizeRun() }
            await StatusModel.shared.refreshHistory()
        }
    }

    /// The admin tasks Mole skipped, as rows in the same list, under one authorization.
    private func runAdminTasks(spotlight: Bool) async {
        var jobs: Set<OptimizeAdmin.Job> = []
        let vpn = await OptimizeAdmin.detectVPN()
        tasks.append(OptimizeTask(name: OptimizeAdmin.Job.dns.taskName))
        if let skip = OptimizeAdmin.vpnSkipLine(vpn) {
            tasks[tasks.count - 1].results = [skip]
        } else {
            jobs.insert(.dns)
        }
        if spotlight {
            jobs.insert(.spotlight)
            tasks.append(OptimizeTask(name: OptimizeAdmin.Job.spotlight.taskName))
        }
        guard !jobs.isEmpty, !stopped else {
            adminOutcome = .nothingToDo
            return
        }
        authorizing = true
        defer { authorizing = false }
        let result: [OptimizeAdmin.Job: Bool]
        do {
            let out = try await Admin.run(OptimizeAdmin.script(for: jobs), prompt: OptimizeAdmin.prompt(for: jobs),
                                          timeout: Self.adminTimeout)
            result = OptimizeAdmin.parse(out)
            adminOutcome = .ran
        } catch Admin.Failure.cancelled {
            adminOutcome = .cancelled
            fill(jobs) { _ in "- Skipped, not authorized" }
            return
        } catch {
            adminOutcome = .failed
            let reason: String = if case Admin.Failure.failed(let why) = error { why } else { error.localizedDescription }
            fill(jobs) { _ in "◎ Couldn't run: \(reason)" }
            return
        }
        fill(jobs) { job in result[job].map { job.resultLine(ok: $0) } ?? "◎ No result reported" }
    }

    private func fill(_ jobs: Set<OptimizeAdmin.Job>, _ line: (OptimizeAdmin.Job) -> String) {
        for job in jobs {
            if let i = tasks.lastIndex(where: { $0.name == job.taskName }) { tasks[i].results = [line(job)] }
        }
    }

    /// Stops Mole between steps (cancelling the task terminates the process), or
    /// withdraws the authorization request if it's up.
    func stop() {
        guard phase == .running else { return }
        stopped = true
        job?.cancel()
    }

    /// The line under "Maintenance complete".
    static func summary(taskCount: Int, issues: Int, stopped: Bool, admin: AdminOutcome) -> String {
        var s = stopped ? "Stopped after \(taskCount) tasks" : "\(taskCount) tasks ran"
        if issues > 0 { s += ", \(issues) need a look" }
        s += "."
        switch admin {
        case .off: s += " Admin tasks are off, so the ones that need admin rights were skipped."
        case .cancelled: s += " Admin tasks were skipped because they weren't authorized."
        case .notNeeded, .nothingToDo, .ran, .failed: break
        }
        return s
    }
}

struct OptimizeView: View {
    @State private var model = OptimizeModel()
    @AppStorage(OptimizeModel.adminTasksKey) private var adminTasks = true
    /// Touch ID for sudo is set up, so the admin step can use it.
    @State private var touchID = false
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
        .task(id: visible) {
            guard visible else { return }
            touchID = Admin.touchIDForSudo()
            await model.plan()
        }
    }

    @ViewBuilder
    private var heroContent: some View {
        if model.phase == .running {
            let total = model.total
            VStack(alignment: .leading, spacing: Space.l) {
                Headline(text: model.authorizing ? "Finishing admin tasks" : "Running maintenance")
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
                PillButton(title: "Run maintenance") { model.run(adminTasks: adminTasks) }.padding(.top, Space.s)
                Toggle(touchID ? "Include admin tasks (Touch ID)" : "Include admin tasks", isOn: $adminTasks)
                    .toggleStyle(.checkbox)
                    .font(.ui(.secondary))
                    .foregroundStyle(Palette.secondary)
                    .help("Flush the DNS cache, and rebuild the Spotlight index if Mole finds it slow. These need admin rights, so you approve them once at the end.")
                Hint(icon: adminTasks ? "lock" : "lock.open", text: hint)
            }
        }
    }

    private var hint: String {
        guard adminTasks else { return "Takes about a minute. Nothing asks for a password." }
        return touchID
            ? "Takes about a minute. At the end, Touch ID approves the admin tasks once."
            : "Takes about a minute. At the end, macOS asks once for your password to approve the admin tasks."
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xl) {
                BubbleView().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(model.stopped ? "Maintenance stopped" : "Maintenance complete").font(.ui(.title, .bold))
                    Text(summary).font(.ui(.body)).foregroundStyle(Palette.secondary)
                    if !model.skippedForFullDiskAccess.isEmpty {
                        HStack(spacing: Space.xs) {
                            Text("\(model.skippedForFullDiskAccess.count) skipped to avoid privacy prompts.")
                            LinkButton(title: "Allow Full Disk Access", color: Palette.accent) { SystemSettings.openFullDiskAccess() }
                            Text("to include them next time.")
                        }
                        .font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                    }
                    ForEach(model.skippedPrompts, id: \.self) { p in
                        Label("Skipped: \(p)", systemImage: "hand.raised")
                            .font(.ui(.secondary)).foregroundStyle(Palette.amber)
                    }
                }
                Spacer()
                PillButton(title: "Run again", width: 180) { model.run(adminTasks: adminTasks) }
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
        return OptimizeModel.summary(taskCount: model.tasks.count, issues: issues, stopped: model.stopped, admin: model.adminOutcome)
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
