import AppKit
import SwiftUI

struct AppsView: View {
    enum Sub: String, CaseIterable { case uninstall = "Uninstall", updates = "Updates", startup = "Startup" }

    @AppStorage("appsSub") private var sub: Sub = .uninstall
    @State private var uninstall = UninstallModel()
    @State private var updates = UpdatesModel()
    @State private var startup = StartupModel()
    @State private var searching = false
    @State private var loaded = false
    @FocusState private var searchFocused: Bool
    @Environment(\.screenVisible) private var visible

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.horizontal, Space.gutter).padding(.bottom, Space.m)
            switch sub {
            case .uninstall:
                if uninstall.apps.isEmpty {
                    // Shown only until the first (fast, native) listing arrives.
                    HeroView {
                        Headline(text: "Your apps")
                        Lede(text: "Remove apps along with the settings, caches and helpers they leave behind.")
                        if uninstall.loading { ProgressLine(text: "Reading your apps") }
                    }
                } else {
                    UninstallList(model: uninstall)
                }
            case .updates: UpdatesList(model: updates, apps: uninstall.apps)
            case .startup: StartupList(model: startup)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await uninstall.load()
            // Every screen stays alive, so this runs at launch even when Apps isn't
            // shown. Update checks contact Apple, vendors and Homebrew: only start
            // them once the Updates tab is actually on screen.
            checkUpdatesIfShown()
            if sub == .startup { await startup.load() }
        }
        .onChange(of: visible) { _, _ in checkUpdatesIfShown() }
        .onChange(of: uninstall.apps.isEmpty) { _, _ in checkUpdatesIfShown() }
        .onReceive(NotificationCenter.default.publisher(for: .bubbleRefresh)) { note in
            if note.object as? Tab == .apps { refresh() }
        }
        .onChange(of: sub) { _, new in
            if new == .updates { checkUpdatesIfShown() }
            if new == .startup, startup.items.isEmpty { Task { await startup.load() } }
        }
    }

    private func checkUpdatesIfShown() {
        guard visible, sub == .updates, !updates.hasChecked, !updates.checking, !uninstall.apps.isEmpty else { return }
        Task { await updates.check(uninstall.apps) }
    }

    private func refresh() {
        Task {
            switch sub {
            case .uninstall: await uninstall.load()
            case .updates: await updates.check(uninstall.apps)
            case .startup: await startup.load()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Space.l) {
            HStack(spacing: 2) {
                ForEach(Sub.allCases, id: \.self) { s in
                    Button { sub = s } label: {
                        Text(s.rawValue)
                            .font(.ui(.body, .semibold))
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(sub == s ? .white : Palette.secondary)
                            .padding(.horizontal, Space.l).frame(height: 32)
                            .background(sub == s ? Palette.accent.opacity(0.18) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.quiet)
                    .accessibilityAddTraits(sub == s ? .isSelected : [])
                }
            }
            .padding(Space.xs)
            .background(Color.white.opacity(0.05), in: Capsule())
            .motion(sub)

            IconButton(systemName: "arrow.clockwise", label: "Refresh (⌘R)", action: refresh)

            Spacer()

            if sub == .uninstall {
                ForEach(UninstallModel.Sort.allCases, id: \.self) { s in
                    Button { uninstall.setSort(s) } label: {
                        HStack(spacing: 3) {
                            Text(s.rawValue).lineLimit(1).fixedSize()
                            if uninstall.sort == s { Image(systemName: uninstall.ascending ? "arrow.up" : "arrow.down").font(.ui(.caption, .bold)) }
                        }
                        .foregroundStyle(uninstall.sort == s ? .white : Palette.secondary)
                    }
                    .buttonStyle(.quiet)
                    .accessibilityLabel("Sort by \(s.rawValue)")
                    .accessibilityValue(uninstall.sort == s ? (uninstall.ascending ? "Ascending" : "Descending") : "")
                }
                .font(.ui(.body, .medium))
                if searching {
                    TextField("Search apps", text: $uninstall.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .frame(width: 180)
                        .padding(.horizontal, Space.m).padding(.vertical, 6)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .onExitCommand { searching = false; uninstall.search = "" }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                IconButton(systemName: searching ? "xmark" : "magnifyingglass", label: searching ? "Close search" : "Search apps") {
                    searching.toggle()
                    if searching { searchFocused = true } else { uninstall.search = "" }
                }
            }
        }
        .motion(searching)
    }
}

// MARK: - Shared pieces

struct AppIcon: View {
    let path: String
    var size: CGFloat = 38
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The live output of an uninstall or a Homebrew update, with notes on anything Bubble declined.
struct RunLogSheet: View {
    let title: String
    let lines: [String]
    let finished: Bool
    var notes: [String] = []
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.ui(.section, .semibold))
                if !finished { ProgressView().controlSize(.small) }
                Spacer()
            }
            LogBox(lines: lines)
            ForEach(notes, id: \.self) { n in
                Label(n, systemImage: "hand.raised").font(.ui(.secondary)).foregroundStyle(Palette.amber)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction).disabled(!finished)
            }
        }
        .padding(Space.xl)
        .frame(width: 720, height: 460)
    }
}
