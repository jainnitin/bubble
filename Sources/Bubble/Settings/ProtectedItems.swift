import AppKit
import SwiftUI

/// Edits ~/.config/mole/whitelist, the list Mole's clean never touches. When the file
/// doesn't exist yet, Mole uses built-in defaults, so the editor starts from those
/// to avoid dropping them on save.
///
/// While a clean runs, the file holds Bubble's temporary list (the user's list plus
/// that run's unchecked items). The editor then shows the user's own list from the
/// backup and won't save, so one-run exclusions never become permanent. Save also
/// re-reads the file and refuses if it changed since it was loaded.
@Observable
@MainActor
final class ProtectedItemsModel {
    var items: [String] = []
    private var saved: [String] = []
    private(set) var loaded = false
    /// The file exists but couldn't be read; editing is off so it's never overwritten.
    private(set) var loadError: String?
    /// The list was loaded from the backup because a clean had its temporary list in place.
    private(set) var loadedDuringClean = false
    /// The user's file the items came from (what the file holds once any clean is over).
    private var source: Whitelist.FileState?
    var message: (text: String, isError: Bool)?

    var isDirty: Bool { loaded && items != saved }

    enum LoadDecision: Equatable {
        case use(Whitelist.FileState, duringClean: Bool)
        case refuse(String)
    }

    /// Which file contents the editor should show.
    nonisolated static func loadDecision(busy: Bool, current: Whitelist.FileState,
                                         backupOriginal: Whitelist.FileState?) -> LoadDecision {
        if busy {
            // The file is Bubble's temporary list; show the user's own list instead.
            guard let original = backupOriginal else {
                return .refuse("A clean is using ~/.config/mole/whitelist right now. Reopen this pane when it finishes.")
            }
            if case .unreadable = original {
                return .refuse("A clean is using ~/.config/mole/whitelist right now. Reopen this pane when it finishes.")
            }
            return .use(original, duringClean: true)
        }
        if case .unreadable = current {
            return .refuse("Bubble couldn't read ~/.config/mole/whitelist, so it won't change it. Fix or remove the file, then reopen Settings.")
        }
        return .use(current, duringClean: false)
    }

    enum SaveCheck: Equatable { case ok, busy, changedOnDisk }

    /// Whether it's safe to overwrite the file: never while a temporary list is in place,
    /// and never over changes made since the editor loaded it.
    nonisolated static func saveCheck(busy: Bool, loadedFrom: Whitelist.FileState?, current: Whitelist.FileState) -> SaveCheck {
        if busy { return .busy }
        guard let loadedFrom, loadedFrom == current else { return .changedOnDisk }
        return .ok
    }

    /// Lines Mole reads from the file (comments and blanks dropped).
    nonisolated static func items(from text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func decide() -> LoadDecision {
        let busy = Whitelist.isBusy
        return Self.loadDecision(busy: busy, current: Whitelist.currentState(),
                                 backupOriginal: busy ? Whitelist.originalInBackup() : nil)
    }

    func load() {
        loaded = true
        loadError = nil
        message = nil
        switch decide() {
        case .refuse(let why):
            loadError = why
            loadedDuringClean = false
            source = nil
            items = []; saved = []
        case .use(let state, let duringClean):
            loadedDuringClean = duringClean
            source = state
            switch state {
            case .text(let text): items = Self.items(from: text)
            default: items = Whitelist.defaultPatterns()
            }
            saved = items
        }
    }

    /// Called when the pane appears: picks up changes made elsewhere (Terminal, a clean
    /// that started or finished). Unsaved edits are kept, with a note.
    func reloadIfChanged() {
        guard loaded else { return load() }
        switch decide() {
        case .refuse(let why):
            if loadError != why, !isDirty { load() }
        case .use(let state, let duringClean):
            if loadError == nil, state == source {
                loadedDuringClean = duringClean
                return
            }
            if isDirty {
                message = ("The list changed outside Bubble. Revert to load it; saving now would overwrite it.", true)
                return
            }
            load()
        }
    }

    /// Adds paths not already listed; returns how many were new.
    @discardableResult
    func add(_ paths: [String]) -> Int {
        var added = 0
        for p in paths where !items.contains(p) {
            items.append(p)
            added += 1
        }
        message = nil
        return added
    }

    func remove(_ set: Set<String>) {
        items.removeAll { set.contains($0) }
        message = nil
    }

    /// Throws away edits and reads the file again.
    func revert() {
        load()
    }

    func restoreDefaults() {
        let defaults = Whitelist.defaultPatterns()
        guard !defaults.isEmpty else {
            message = ("Bubble couldn't read Mole's defaults. Check that Mole is installed.", true)
            return
        }
        items = defaults + items.filter { !defaults.contains($0) }
        message = nil
    }

    /// Why Mole would ignore this line, or nil. Mole expands ~ and $HOME and matches
    /// wildcards in this file, so those are fine here; everything else goes through
    /// `Whitelist.rejectedPaths`, which mirrors Mole's loader.
    nonisolated static func problem(_ item: String) -> String? {
        if item == "FINDER_METADATA" { return nil }
        let literal = String(Paths.expandingHome(item).map { "*?[]".contains($0) ? "x" : $0 })
        guard !Whitelist.rejectedPaths([literal]).isEmpty else { return nil }
        return Whitelist.rejectionReason(literal).map { "Mole would ignore this: \($0)." }
    }

    var problems: [String] { items.filter { Self.problem($0) != nil } }

    nonisolated static func isPattern(_ item: String) -> Bool { item.contains { "*?[".contains($0) } }

    /// The items that name an existing file or folder Bubble may look at (for row icons and
    /// Show in Finder). Touches the disk, so the pane calls it off the main thread.
    nonisolated static func existingItems(_ items: [String]) -> Set<String> {
        let guarding = PrivacyGuard.isGuarding
        let denied = guarding ? PrivacyGuard.deniedRoots() : []
        return existingItems(items, isLocked: { guarding && PrivacyGuard.isLocked($0) && !denied.contains($0) },
                             fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    nonisolated static func existingItems(_ items: [String], isLocked: (String) -> Bool,
                                          fileExists: (String) -> Bool) -> Set<String> {
        Set(items.filter { item in
            guard !isPattern(item) else { return false }
            let path = Paths.expandingHome(item)
            // Looking inside Desktop, Documents, another app's container… without Full Disk
            // Access makes macOS ask; a generic icon is fine there.
            return !isLocked(path) && fileExists(path)
        })
    }

    /// Writes the list. Refuses while a clean is running (Bubble's temporary list is in
    /// place then) and while any line would be ignored by Mole.
    func save() {
        guard loadError == nil else { return }
        switch Self.saveCheck(busy: Whitelist.isBusy, loadedFrom: source, current: Whitelist.currentState()) {
        case .ok: break
        case .busy:
            message = ("A clean is running and using this list. Save again when it finishes.", true)
            return
        case .changedOnDisk:
            message = ("The list changed outside Bubble since you opened it. Revert to load the new version, then make your changes again.", true)
            return
        }
        guard problems.isEmpty else {
            message = ("Mole would ignore \(problems.count == 1 ? "1 item" : "\(problems.count) items") marked below. Fix or remove \(problems.count == 1 ? "it" : "them"), then save.", true)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Whitelist.dir, withIntermediateDirectories: true)
            let body = "# Edited in Bubble\n" + items.joined(separator: "\n") + "\n"
            // Write through a symlinked whitelist rather than replacing the link.
            try body.write(to: Whitelist.file.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            saved = items
            source = .text(body)
            loadedDuringClean = false
            message = ("Saved. Clean will skip these from now on.", false)
        } catch {
            message = ("Couldn't save: \(error.localizedDescription) Check that ~/.config/mole is writable.", true)
        }
    }
}

struct ProtectedItemsPane: View {
    @Bindable var model: ProtectedItemsModel
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool
    /// Items that name something on disk Bubble may look at (see `existingItems`).
    @State private var onDisk: Set<String> = []
    @State private var probeGeneration = 0

    private var shown: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.items }
        return model.items.filter { $0.localizedCaseInsensitiveContains(q) || display($0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Clean never touches these files and folders. Drag them in from Finder, or click Add. Mole keeps this list in ~/.config/mole/whitelist.")
                .font(.ui(.body)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.loadError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(.secondary)).foregroundStyle(Palette.red)
            } else {
                if model.loadedDuringClean {
                    Label("A clean is running, so this shows your list without that run's unchecked items. You can save once it finishes.",
                          systemImage: "hourglass")
                        .font(.ui(.secondary)).foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                toolbar
                list
                footer
            }
        }
        .onAppear { model.reloadIfChanged(); probeGeneration += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.reloadIfChanged()
            probeGeneration += 1
        }
        // Rows look at the disk (existence, privacy) once per list change or reappearance,
        // off the main thread, rather than on every render.
        .task(id: ProbeKey(items: model.items, generation: probeGeneration)) {
            let items = model.items
            onDisk = await Task.detached(priority: .userInitiated) { ProtectedItemsModel.existingItems(items) }.value
        }
    }

    private struct ProbeKey: Equatable { var items: [String]; var generation: Int }

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.quiet).foregroundStyle(Palette.tertiary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .panel(radius: Radius.control + 1, fill: Color.white.opacity(0.06),
                   stroke: searchFocused ? Palette.accent.opacity(0.6) : Palette.cardStroke)
            .frame(maxWidth: 260)

            Spacer()
            Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")
                .font(.num(.secondary)).foregroundStyle(Palette.tertiary)
            Button("Add…", action: add)
            Button("Remove") {
                model.remove(selection)
                selection = []
            }
            .disabled(selection.isEmpty)
            Menu {
                Button("Restore Mole's Defaults") { model.restoreDefaults() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private var list: some View {
        ZStack {
            List(selection: $selection) {
                ForEach(shown, id: \.self) { item in
                    row(item).tag(item)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                model.remove(selection)
                selection = []
            }
            .opacity(shown.isEmpty ? 0 : 1)

            if shown.isEmpty { emptyState }
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous)
                .strokeBorder(dropTargeted ? Palette.accent : Palette.cardStroke,
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [6, 4] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let paths = urls.filter(\.isFileURL).map(\.path)
            guard !paths.isEmpty else { return false }
            let added = model.add(paths)
            AccessibilityNotification.Announcement(added == 1 ? "Added 1 item" : "Added \(added) items").post()
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Space.s) {
            Image(systemName: query.isEmpty ? "tray.and.arrow.down" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.tertiary)
            if query.isEmpty {
                Text("Nothing is protected").font(.ui(.body, .semibold)).foregroundStyle(Palette.primary)
                Text("Drop files or folders here, or click Add.\nClean will leave them alone.")
                    .multilineTextAlignment(.center)
                    .font(.ui(.secondary)).foregroundStyle(Palette.secondary)
            } else {
                Text("No protected items match \u{201C}\(query)\u{201D}").font(.ui(.body)).foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: String) -> some View {
        let problem = ProtectedItemsModel.problem(item)
        let (name, parent) = split(item)
        return HStack(spacing: Space.s) {
            icon(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.ui(.body, .medium)).foregroundStyle(Palette.primary).lineLimit(1)
                if let problem {
                    Text(problem).font(.ui(.caption)).foregroundStyle(Palette.red)
                } else if !parent.isEmpty {
                    Text(parent).font(.path(.caption)).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.s)
            if item.hasSuffix("/*") {
                Tag(text: "Contents only")
            } else if isPattern(item) {
                Tag(text: "Pattern")
            }
            if problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .help(item)
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(Paths.expandingHome(item)) }.disabled(!exists(item))
            Button("Copy Path") { Clipboard.copy(item) }
            Divider()
            Button("Remove") { model.remove([item]); selection.remove(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display(item) + (problem.map { ". \($0)" } ?? ""))
    }

    // MARK: Helpers

    private func display(_ item: String) -> String {
        item == "FINDER_METADATA" ? "Finder metadata (.DS_Store files)" : Fmt.abbreviate(Paths.expandingHome(item))
    }

    private func split(_ item: String) -> (String, String) {
        if item == "FINDER_METADATA" { return ("Finder metadata", ".DS_Store files") }
        var d = display(item)
        // "folder/*" protects what's inside a folder; name it by the folder.
        if d.hasSuffix("/*") { d.removeLast(2) }
        guard let slash = d.lastIndex(of: "/"), slash != d.startIndex else { return (d, "") }
        return (String(d[d.index(after: slash)...]), String(d[..<slash]))
    }

    private func isPattern(_ item: String) -> Bool { ProtectedItemsModel.isPattern(item) }

    private func exists(_ item: String) -> Bool { onDisk.contains(item) }

    @ViewBuilder private func icon(_ item: String) -> some View {
        if exists(item) {
            Image(nsImage: FileIcons.icon(forFile: Paths.expandingHome(item)))
                .resizable().frame(width: 22, height: 22).accessibilityHidden(true)
        } else {
            Image(systemName: item == "FINDER_METADATA" ? "doc.badge.gearshape" : isPattern(item) ? "asterisk" : "questionmark.folder")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Protect"
        panel.message = "Choose files or folders for Clean to leave alone."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls.map(\.path))
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            if let m = model.message {
                Label(m.text, systemImage: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.ui(.secondary))
                    .foregroundStyle(m.isError ? Palette.red : Palette.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.isDirty {
                Text("Unsaved changes").font(.ui(.secondary)).foregroundStyle(Palette.amber)
            } else {
                Text("* in a path matches anything.").font(.ui(.secondary)).foregroundStyle(Palette.tertiary)
            }
            Spacer()
            Button("Revert") { model.revert(); selection = [] }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
        }
    }
}
