import SwiftUI

struct CleanView: View {
    @State private var model = CleanModel()
    @State private var hideFDA = false
    @State private var shownBytes: Double = 0
    @State private var showFoundAction = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.reviewing {
                CleanReview(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else {
                hero.transition(.opacity)
            }
            if model.needsFullDiskAccess && !hideFDA && !model.reviewing {
                NoticeBar(icon: "lock.shield", text: "Give Bubble Full Disk Access to scan Trash, Mail and other protected caches.",
                          actionTitle: "Open Settings", action: SystemSettings.openFullDiskAccess, onClose: { hideFDA = true })
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(model.reviewing)
        .motion(model.needsFullDiskAccess && !hideFDA)
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
                }
                .padding(.bottom, Space.m)
            }

            Divider().overlay(Palette.cardStroke)
            HStack(spacing: Space.m) {
                Text("\(model.selectedItems.count) of \(model.allItems.count) selected").font(.num(.body, .semibold))
                    .lineLimit(1).fixedSize()
                    .contentTransition(.numericText())
                    .motion(model.selectedItems.count)
                    .padding(.trailing, Space.s)
                Text("Select").foregroundStyle(Palette.tertiary)
                LinkButton(title: "All", color: Palette.accent) { model.selectAll() }
                LinkButton(title: "None", color: Palette.accent) { model.selectNone() }
                LinkButton(title: "Recommended", color: Palette.accent) { model.applyRecommended() }
                Spacer()
                // The review screen is the confirmation: no second dialog.
                VStack(alignment: .trailing, spacing: 6) {
                    PillButton(title: "Permanently clean \(Fmt.bytes(model.selectedBytes))", width: 320,
                               disabled: model.selectedItems.isEmpty) { model.clean() }
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
        let sel = model.selectedCount(c)
        let selBytes = c.items.filter(model.isSelected).reduce(0) { $0 + $1.bytes }
        let open = expanded.contains(c.name)
        let toggleOpen = {
            if open { expanded.remove(c.name) } else { expanded.insert(c.name) }
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
                VStack(spacing: 0) {
                    ForEach(c.items) { item in
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
                            Spacer()
                            if item.count > 1 { Text("\(item.count) items").font(.ui(.secondary)).foregroundStyle(Palette.tertiary) }
                            Text(Fmt.parseSize(item.sizeText).map(Fmt.bytes) ?? item.sizeText).font(.num(.secondary)).foregroundStyle(Palette.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, Space.l).padding(.vertical, 5)
                        .contextMenu {
                            Button("Reveal in Finder") { Finder.reveal(item.path) }
                        }
                    }
                }
                .padding(.leading, 34)
                .padding(.bottom, Space.s)
                .transition(.opacity)
            }
        }
        .panel(radius: Radius.row)
        .motion(open)
        .motion(sel)
    }
}
