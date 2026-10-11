import SwiftUI

struct CleanView: View {
    @State private var model = CleanModel()
    @State private var access = FullDiskAccess.shared
    /// The Full Disk Access notice is shown once per kind of result, then stays dismissed.
    @AppStorage("cleanAccessNoticeDismissed") private var noticeDismissed = false
    @State private var shownBytes: Double = 0
    @State private var showFoundAction = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The scan skipped places Full Disk Access would add, and the user hasn't waved the notice off.
    private var showAccessNotice: Bool {
        let missed = model.needsFullDiskAccess || model.skipped.contains(where: \.needsFullDiskAccess)
        guard missed, !model.reviewing, model.phase == .found || model.phase == .done else { return false }
        // Access arrived since the scan: say so whether or not the ask was dismissed.
        return access.isOn || !noticeDismissed
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.reviewing {
                CleanReview(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else {
                hero.transition(.opacity)
            }
            if showAccessNotice {
                accessNotice
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(model.reviewing)
        .motion(showAccessNotice)
        .sensoryFeedback(.success, trigger: model.phase == .done)
        .task {
            #if BUBBLE_DEV
            // Dev hook: `--args -autoStart YES` runs the (dry-run) scan on launch.
            let start = UserDefaults.standard.bool(forKey: "skipIntro") || UserDefaults.standard.bool(forKey: "autoStart")
            #else
            let start = UserDefaults.standard.bool(forKey: "skipIntro")
            #endif
            if start, model.phase == .idle { model.scan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bubbleRefresh)) { note in
            guard note.object as? Tab == .clean, model.phase != .cleaning else { return }
            model.scan()
        }
        .alert("Can't skip unchecked items", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    @ViewBuilder
    private var accessNotice: some View {
        if access.isOn {
            NoticeBar(icon: "lock.open", text: "Full Disk Access is on. Scan again to include Trash, Mail and the other places this scan skipped.",
                      actionTitle: "Scan again", action: { model.scan() })
        } else {
            NoticeBar(icon: "lock.shield",
                      text: "Skipped \(Self.skippedSummary(model.skipped)): macOS keeps them private. Everything else was scanned.",
                      actionTitle: "Allow Access…", action: { access.openSettings() }, onClose: { noticeDismissed = true })
        }
    }

    /// "Trash, Mail and 3 more places".
    static func skippedSummary(_ places: [SkippedPlace]) -> String {
        let names = places.filter(\.needsFullDiskAccess).map(\.name)
        switch names.count {
        case 0: return "protected places"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    private var hero: some View {
        HeroView(recede: model.phase == .found || model.phase == .done) {
            ZStack(alignment: .leading) {
                phaseContent
                    .id(model.phase)
                    .transition(.phase(reduceMotion: reduceMotion))
            }
            .motion(model.phase)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            switch model.phase {
            case .idle:
                Headline(text: "Clean up your Mac")
                Lede(text: "Find caches, logs and leftovers from deleted apps that are safe to remove.")
                PillButton(title: "Scan for clutter") { model.scan() }.padding(.top, Space.s)
                Hint(icon: "eye", text: "Scanning only looks. You choose what gets deleted.")
            case .scanning:
                Headline(text: "Scanning…")
                ProgressLine(text: model.currentStep)
                LinkButton(title: "Cancel") { model.cancel() }
            case .found:
                // The one orchestrated moment: the bubble eases back, the total counts up,
                // then the next step appears.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CountingBytes(value: shownBytes)
                    Text("to clean")
                        .font(.ui(.title, .semibold)).foregroundStyle(Palette.secondary)
                }
                .font(.num(.hero, .bold))
                .foregroundStyle(Palette.primary)
                HStack(spacing: Space.m) {
                    Text("\(model.itemCount) items in \(model.categories.count) categories").foregroundStyle(Palette.secondary)
                    LinkButton(title: "Scan again", color: Palette.accent) { model.scan() }
                }
                .font(.ui(.body))
                if model.guarded {
                    // Honest totals: say what wasn't counted, even after the notice is dismissed.
                    Hint(icon: "lock", text: "Not counted: \(Self.skippedSummary(model.skipped)), which macOS keeps private.")
                }
                PillButton(title: "Review and choose") { model.reviewing = true }
                    .padding(.top, Space.s)
                    .opacity(showFoundAction ? 1 : 0)
                    .offset(y: showFoundAction ? 0 : 6)
                    .onAppear(perform: revealFound)
            case .cleaning:
                Headline(text: "Cleaning…")
                ProgressLine(text: model.currentStep)
                LogBox(lines: model.log, tail: 5).frame(maxWidth: 460, alignment: .leading)
            case .done:
                Text(model.freedText).font(.num(.hero, .bold)).foregroundStyle(Palette.primary)
                Lede(text: "Apps rebuild their caches as they need them.")
                PillButton(title: "Scan again") { model.scan() }.padding(.top, Space.s)
            }
        }
    }

    private func revealFound() {
        shownBytes = reduceMotion ? model.totalBytes : 0
        showFoundAction = reduceMotion
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.9)) { shownBytes = model.totalBytes }
        withAnimation(.easeOut(duration: 0.3).delay(0.8)) { showFoundAction = true }
    }
}

struct CleanReview: View {
    @Bindable var model: CleanModel
    @State private var expanded: Set<String> = []
    /// How many rows an open category shows (`rowPage` until "Show more").
    @State private var shownRows: [String: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let rowPage = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Ready to clean").font(.ui(.title, .bold))
                    Text(subtitle).font(.ui(.body)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                IconButton(systemName: "arrow.clockwise", label: "Scan again") { model.scan() }
                IconButton(systemName: "xmark.circle.fill", label: "Close review", size: TypeStep.section.rawValue) { model.reviewing = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, Space.l)

            ScrollView {
                VStack(spacing: Space.s) {
                    ForEach(model.categories) { c in category(c) }
                    if !model.skipped.isEmpty { SkippedPanel(places: model.skipped) }
                }
                .padding(.bottom, Space.m)
            }

            Divider().overlay(Palette.cardStroke)
            let selected = model.selectedItems
            HStack(spacing: Space.m) {
                Text("\(selected.count) of \(model.allItems.count) selected").font(.num(.body, .semibold))
                    .lineLimit(1).fixedSize()
                    .contentTransition(.numericText())
                    .motion(selected.count)
                    .padding(.trailing, Space.s)
                Text("Select").foregroundStyle(Palette.tertiary)
                LinkButton(title: "All", color: Palette.accent) { model.selectAll() }
                LinkButton(title: "None", color: Palette.accent) { model.selectNone() }
                LinkButton(title: "Recommended", color: Palette.accent) { model.applyRecommended() }
                Spacer()
                // The review screen is the confirmation: no second dialog.
                VStack(alignment: .trailing, spacing: 6) {
                    PillButton(title: "Permanently clean \(Fmt.bytes(selected.reduce(0) { $0 + $1.bytes }))", width: 320,
                               disabled: selected.isEmpty) { model.clean() }
                    Text("Deleted, not moved to the Trash. Apps rebuild caches as needed.")
                        .font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).fixedSize()
                }
            }
            .font(.ui(.body))
            .padding(.top, Space.l)
        }
        .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
    }

    private var subtitle: String {
        var s = "\(Fmt.bytes(model.totalBytes)) in \(model.itemCount) items across \(model.categories.count) categories."
        if model.needsAdmin { s += " System caches need admin: run sudo mo clean in Terminal." }
        return s
    }

    private func category(_ c: CleanCategory) -> some View {
        let selItems = c.items.filter(model.isSelected)
        let sel = selItems.count
        let selBytes = selItems.reduce(0) { $0 + $1.bytes }
        let open = expanded.contains(c.name)
        let toggleOpen = {
            // One animation for the whole list, so the panels below move in step with
            // this one's height instead of jumping while its rows fade.
            withAnimation(reduceMotion ? Motion.reduced : Motion.spring) {
                if open { expanded.remove(c.name) } else { expanded.insert(c.name) }
            }
        }
        return VStack(spacing: 0) {
            HStack(spacing: Space.l) {
                CheckBox(on: sel == c.items.count, mixed: sel > 0 && sel < c.items.count, tint: Palette.accent,
                         label: c.name) { model.toggle(c) }
                Button(action: toggleOpen) {
                    HStack(spacing: Space.l) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.s) {
                                Text(c.name).font(.ui(.body, .semibold))
                                Text("\(sel) of \(c.items.count)").font(.num(.secondary)).foregroundStyle(Palette.tertiary)
                            }
                            Text(c.blurb).font(.ui(.secondary)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Text(sel == c.items.count ? Fmt.bytes(c.bytes) : "\(Fmt.bytes(selBytes)) of \(Fmt.bytes(c.bytes))")
                            .font(.num(.body, .semibold)).foregroundStyle(Palette.accent)
                            .lineLimit(1).fixedSize()
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(Palette.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.quiet)
                .accessibilityLabel("\(c.name), \(Fmt.bytes(c.bytes))")
                .accessibilityHint(open ? "Hides the items" : "Shows the items")
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)

            if open {
                let limit = shownRows[c.name] ?? Self.rowPage
                VStack(spacing: 0) {
                    // By position: a path Mole lists twice must not give two rows one identity.
                    ForEach(Array(c.items.prefix(limit).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: Space.m) {
                            if !item.alwaysRuns {
                                CheckBox(on: model.isSelected(item), tint: Palette.accent,
                                         label: Fmt.abbreviate(item.title)) { model.toggle(item) }
                            } else {
                                // Tools that clean their own caches (npm, pip…) can't be skipped from Bubble.
                                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                                    .frame(width: 18, height: 18)
                                    .help("Runs its own cleanup; can't be skipped")
                                    .accessibilityLabel("Always runs")
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.toolRun ? item.title : Fmt.abbreviate(item.title))
                                    .font(item.toolRun ? .ui(.body, .medium) : .path())
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(Palette.primary.opacity(0.85))
                                if item.alwaysRuns {
                                    Text("Runs its own cleanup; can't be skipped").font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                                } else if item.toolRun {
                                    Text("Cleaned by running the tool itself").font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                                } else if item.coveredBy != nil, let parent = model.governingItem(item) {
                                    Text("Included with \(Fmt.abbreviate(parent.title)); checking this checks that too")
                                        .font(.ui(.caption)).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: Space.s)
                            if item.count > 1 {
                                Text("\(item.count) items").font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                                    .lineLimit(1).fixedSize()
                            }
                            Text(Fmt.parseSize(item.sizeText).map(Fmt.bytes) ?? item.sizeText).font(.num(.secondary)).foregroundStyle(Palette.secondary)
                                .lineLimit(1).frame(minWidth: 80, alignment: .trailing).fixedSize()
                        }
                        .padding(.horizontal, Space.l).padding(.vertical, 5)
                        .contextMenu {
                            Button("Reveal in Finder") { Finder.reveal(item.path) }
                        }
                    }
                    // Rows come in pages: thousands at once would stall the window.
                    if c.items.count > limit {
                        HStack(spacing: Space.m) {
                            LinkButton(title: "Show \(min(Self.rowPage, c.items.count - limit)) more", color: Palette.accent) {
                                shownRows[c.name] = limit + Self.rowPage
                            }
                            if c.items.count - limit > Self.rowPage {
                                LinkButton(title: "Show all \(c.items.count)", color: Palette.accent) { shownRows[c.name] = c.items.count }
                            }
                            Spacer()
                        }
                        .font(.ui(.secondary, .medium))
                        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                    }
                }
                .padding(.leading, 34)
                .padding(.bottom, Space.s)
                .transition(.opacity)
            }
        }
        // Rows fading in or out stay inside the panel while its height animates.
        .clipped()
        .panel(radius: Radius.row)
        .motion(sel)
    }
}

/// "Not scanned" at the end of the review: what this scan left out and why, so a
/// smaller total without Full Disk Access reads as a choice, not a mystery.
struct SkippedPanel: View {
    let places: [SkippedPlace]
    @State private var access = FullDiskAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "lock").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                Text("Not scanned").font(.ui(.body, .semibold))
                Text("\(places.count)").font(.num(.secondary)).foregroundStyle(Palette.tertiary)
                Spacer()
                if places.contains(where: \.needsFullDiskAccess) && !access.isOn {
                    LinkButton(title: "Allow Full Disk Access…", color: Palette.accent) { access.openSettings() }
                        .font(.ui(.secondary, .medium))
                }
            }
            ForEach(places) { p in
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(p.name).font(.ui(.body, .medium)).foregroundStyle(Palette.primary.opacity(0.85))
                    Text(p.reason).font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                    Spacer()
                }
                .padding(.leading, 26)
                .accessibilityElement(children: .combine)
            }
            if places.contains(where: \.needsFullDiskAccess) {
                Text("macOS keeps these private. Bubble skips them so no permission dialogs pop up while it scans.")
                    .font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: Radius.row)
    }
}
