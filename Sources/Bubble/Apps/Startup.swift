import Foundation
import Observation
import SwiftUI

struct LaunchItem: Identifiable {
    enum Scope: String { case user = "Launch Agent", global = "Launch Agent (all users)", daemon = "Launch Daemon" }
    var label: String
    var plist: String
    var program: String?
    var scope: Scope
    var enabled: Bool
    var id: String { plist }
    var editable: Bool { scope != .daemon }

    var appPath: String? {
        guard let program, let r = program.range(of: ".app/") else { return nil }
        return String(program[..<r.lowerBound]) + ".app"
    }
}

@Observable
@MainActor
final class StartupModel {
    var items: [LaunchItem] = []
    var error: String?

    private var uid: String { String(getuid()) }

    func load() async {
        let userOverrides = await overrides("gui/\(uid)")
        let systemOverrides = await overrides("system")
        let home = NSHomeDirectory()
        var out: [LaunchItem] = []
        let dirs: [(String, LaunchItem.Scope)] = [
            (home + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .global), ("/Library/LaunchDaemons", .daemon),
        ]
        for (dir, scope) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for f in files where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? String(f.dropLast(6))
                let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
                // launchctl's override wins; otherwise fall back to the plist's own Disabled key.
                let override = (scope == .daemon ? systemOverrides : userOverrides)[label]
                let disabled = override ?? (dict["Disabled"] as? Bool ?? false)
                out.append(LaunchItem(label: label, plist: path, program: program, scope: scope, enabled: !disabled))
            }
        }
        items = out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Parses `launchctl print-disabled <domain>`: `"com.foo.bar" => disabled|enabled`.
    /// Returns label -> isDisabled.
    private func overrides(_ domain: String) async -> [String: Bool] {
        let data = await Shell.output("/bin/launchctl", ["print-disabled", domain])
        var map: [String: Bool] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            map[label] = state == "disabled" || state == "true"
        }
        return map
    }

    func setEnabled(_ item: LaunchItem, _ on: Bool) async {
        guard item.editable else { return }
        let target = "gui/\(uid)/\(item.label)"
        if on {
            _ = await Shell.output("/bin/launchctl", ["enable", target])
            _ = await Shell.output("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.plist])
        } else {
            _ = await Shell.output("/bin/launchctl", ["disable", target])
            _ = await Shell.output("/bin/launchctl", ["bootout", target])
        }
        await load()
    }
}

// MARK: - View

struct StartupList: View {
    @Bindable var model: StartupModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Login items added by apps are managed by macOS.").foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button(action: SystemSettings.openLoginItems) { Text("Open Login Items Settings").lineLimit(1).fixedSize() }
                        .buttonStyle(.quiet).foregroundStyle(Palette.accent)
                }
                .font(.ui(.secondary))
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                .panel(radius: Radius.row, fill: Palette.accent.opacity(0.08), stroke: Palette.accent.opacity(0.15))
                .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)

                group("Your launch agents", model.items.filter { $0.scope == .user })
                group("Launch agents for all users", model.items.filter { $0.scope == .global })
                group("Background daemons (need admin, view only)", model.items.filter { $0.scope == .daemon })
                if model.items.isEmpty {
                    Text("No launch agents or daemons found.").foregroundStyle(Palette.secondary).padding(Space.gutter)
                }
            }
            .padding(.bottom, Space.l)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [LaunchItem]) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title, count: items.count)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 18) {
            if let app = item.appPath {
                AppIcon(path: app)
            } else {
                Image(systemName: "gearshape").font(.ui(.body)).foregroundStyle(Palette.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label).font(.ui(.body, .semibold)).lineLimit(1)
                Text([item.scope.rawValue, item.program.map(Fmt.abbreviate)].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(.secondary)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle(item.label, isOn: Binding(get: { item.enabled }, set: { on in Task { await model.setEnabled(item, on) } }))
                .toggleStyle(.switch).tint(Palette.green).labelsHidden()
                .disabled(!item.editable)
        }
        .padding(.horizontal, Space.gutter).padding(.vertical, 6)
        .contextMenu {
            Button("Reveal plist in Finder") { Finder.reveal(item.plist) }
        }
    }
}
