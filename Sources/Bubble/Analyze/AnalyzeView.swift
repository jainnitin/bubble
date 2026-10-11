import AppKit
import SwiftUI

struct AnalyzeView: View {
    @State private var model = AnalyzeModel()
    @State private var pendingTrash: DiskEntry?
    /// A protected folder the user asked to scan; confirmed first because macOS will ask too.
    @State private var pendingScan: PrivacyGuard.LockedPlace?
    @State private var access = FullDiskAccess.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let level = model.current {
                browser(level).transition(.opacity)
            } else {
                HeroView {
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: Space.l) {
                            if let s = model.scanning {
                                Headline(text: "Mapping \(s)…")
                                ProgressView().controlSize(.small)
                            } else {
                                Headline(text: "See what's using your disk")
                                Lede(text: "A map of your folders sized by how much space they take. Click a block to look inside.")
                                PillButton(title: "Map my disk") { model.open(nil, title: "Whole Disk", push: false) }
                                    .padding(.top, Space.s)
                                Hint(icon: "eye", text: "Read-only. Nothing moves unless you choose Move to Trash.")
                            }
                        }
                        .id(model.scanning == nil)
                        .transition(.phase(reduceMotion: reduceMotion))
                    }
                    .motion(model.scanning == nil)
                }
                .transition(.opacity)
            }
        }
        .motion(model.current == nil)
        .onReceive(NotificationCenter.default.publisher(for: .bubbleRefresh)) { note in
            guard note.object as? Tab == .analyze else { return }
            rescan()
        }
        .task {
            #if BUBBLE_DEV
            // Dev hook: `--args -autoStart YES` maps the disk on launch (read-only).
            let start = UserDefaults.standard.bool(forKey: "skipIntro") || UserDefaults.standard.bool(forKey: "autoStart")
            #else
            let start = UserDefaults.standard.bool(forKey: "skipIntro")
            #endif
            if start, model.current == nil, model.scanning == nil {
                model.open(nil, title: "Whole Disk", push: false)
            }
        }
        .onChange(of: access.isOn) { _, _ in
            // Access changed in System Settings: what a scan can see changed too.
            if model.current != nil { rescan() }
        }
        .alert("Scan \(pendingScan?.name ?? "")?", isPresented: Binding(get: { pendingScan != nil }, set: { if !$0 { pendingScan = nil } })) {
            Button("Scan") {
                if let p = pendingScan { model.scanAnyway(p) }
                pendingScan = nil
            }
            Button("Cancel", role: .cancel) { pendingScan = nil }
        } message: {
            Text("macOS will ask once whether Bubble may access your \(pendingScan?.name ?? "") folder. Whatever you choose, it won't ask again. Clean will look there for caches too.")
        }
        .alert("Move “\(pendingTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let e = pendingTrash { model.trash(e) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("\(Fmt.abbreviate(pendingTrash?.path ?? "")) · \(Fmt.bytes(pendingTrash?.size ?? 0)). You can restore it from the Trash.")
        }
    }

    private func browser(_ level: DiskLevel) -> some View {
        HStack(alignment: .top, spacing: Space.xl) {
            // One scan at a time: navigation waits until the current one finishes.
            sidebar(level).frame(width: 230)
                .disabled(model.scanning != nil)
            VStack(alignment: .leading, spacing: Space.m) {
                header.disabled(model.scanning != nil)
                Treemap(entries: level.entries, onOpen: drill, menu: contextMenu)
                    .disabled(model.scanning != nil)
                    // Each folder gets a fresh map that settles in, so drilling reads as moving inward.
                    .id(level.path ?? "/")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    .motion(level.path)
                    .overlay {
                        if let s = model.scanning {
                            ZStack {
                                Color.black.opacity(0.35)
                                VStack(spacing: Space.s) {
                                    ProgressView()
                                    Text("Scanning \(s)").font(.ui(.body)).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Radius.row))
                            .transition(.opacity)
                        }
                    }
            }
        }
        .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
        .motion(model.scanning)
    }

    private func rescan() { model.rescan() }

    private var header: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(model.stack.enumerated()), id: \.offset) { i, lvl in
                if i > 0 { Image(systemName: "chevron.right").font(.ui(.caption)).foregroundStyle(Palette.tertiary).accessibilityHidden(true) }
                Button { model.pop(to: i) } label: { Text(lvl.title).lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.quiet)
                    .foregroundStyle(i == model.stack.count - 1 ? .white : Palette.secondary)
                    .font(.ui(.body, .semibold))
            }
            Spacer()
            let vol = VolumeInfo.root
            Meter(fraction: vol.used / max(vol.total, 1), color: Palette.accent).frame(width: 150).scaleEffect(y: 0.4)
            Text("\(Fmt.bytes(vol.used)) of \(Fmt.bytes(vol.total)) used on this disk")
                .font(.num(.secondary)).foregroundStyle(Palette.secondary)
            IconButton(systemName: "arrow.clockwise", label: "Rescan (⌘R)", action: rescan)
        }
    }

    private func sidebar(_ level: DiskLevel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(level.entries.contains(where: \.isPartial) ? "≥ " : "")\(Fmt.bytes(level.total)) in \(level.entries.count) items")
                .font(.num(.section)).foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity).padding(.vertical, Space.l)
            Text("In this folder").font(.ui(.secondary, .semibold)).foregroundStyle(Palette.secondary)
                .padding(.bottom, Space.xs)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(level.entries) { e in folderRow(e, total: level.total) }
                    if !level.insights.isEmpty {
                        Text("Worth a look").font(.ui(.secondary, .semibold)).foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.l).padding(.bottom, Space.xs)
                        ForEach(level.insights) { e in folderRow(e, total: nil) }
                    }
                    let locked = model.guarded ? PrivacyGuard.analyzeLocked(in: level.path) : []
                    if !locked.isEmpty {
                        Text("Not scanned").font(.ui(.secondary, .semibold)).foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.l).padding(.bottom, Space.xs)
                        ForEach(locked) { p in lockedRow(p) }
                        Text("macOS keeps these private, so Bubble skips them instead of setting off permission dialogs.")
                            .font(.ui(.caption)).foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.xs)
                    }
                }
            }
            Text("Click a folder to open it. Right-click to reveal or move to the Trash.")
                .font(.ui(.caption)).foregroundStyle(Palette.tertiary).padding(.top, Space.s)
        }
    }

    private func folderRow(_ e: DiskEntry, total: Double?) -> some View {
        Button { drill(e) } label: {
            HStack(spacing: Space.m) {
                Image(systemName: e.isDir == false ? "doc" : "folder").foregroundStyle(Palette.secondary).frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.ui(.body, .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(total.map { "\(e.sizeLabel), \(Int((e.size / max($0, 1) * 100).rounded()))%" } ?? e.sizeLabel)
                        .font(.num(.secondary)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if e.isDir != false { Image(systemName: "chevron.right").foregroundStyle(Palette.tertiary).accessibilityHidden(true) }
            }
            .padding(.vertical, 5).padding(.horizontal, Space.s)
            .contentShape(Rectangle())
            .rowHover()
        }
        .buttonStyle(.quiet)
        .contextMenu { contextMenu(e) }
        .accessibilityHint(e.isDir == false ? "Shows it in Finder" : "Opens the folder")
    }

    /// A protected folder the scan skipped. Desktop, Documents and Downloads can be scanned
    /// on their own (macOS asks once); everything else needs Full Disk Access.
    private func lockedRow(_ p: PrivacyGuard.LockedPlace) -> some View {
        Menu {
            if p.path == Shell.home && model.current?.path == nil {
                Button("Open Home") { model.open(p.path, title: "Home", push: true) }
            }
            if let f = p.folder {
                Button("Scan \(f.rawValue)…") { pendingScan = p }
            }
            Button("Allow Full Disk Access…") { FullDiskAccess.shared.openSettings() }
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.ui(.body, .semibold)).foregroundStyle(Palette.secondary).lineLimit(1)
                    Text(p.folder != nil ? "macOS asks first" : "Needs Full Disk Access")
                        .font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, Space.s)
            .contentShape(Rectangle())
            .rowHover()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(p.name), not scanned")
    }

    private func drill(_ e: DiskEntry) {
        if e.isDir == false {
            Finder.reveal(e.path)
            return
        }
        guard model.scanning == nil else { return }
        model.open(e.path, title: e.name, push: true)
    }

    @ViewBuilder
    private func contextMenu(_ e: DiskEntry) -> some View {
        Button("Reveal in Finder") { Finder.reveal(e.path) }
        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
        Button("Copy Path") {
            Clipboard.copy(e.path)
        }
        // Home, ~/Library, /Applications and other top-level folders can't be trashed from here.
        if !Safety.isProtectedFromTrash(path: e.path) {
            Divider()
            Button("Move to Trash…", role: .destructive) { pendingTrash = e }
        }
    }
}
