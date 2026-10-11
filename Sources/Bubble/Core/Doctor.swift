import SwiftUI

/// A quick checkup of everything Bubble depends on, with a fix for each problem.
@Observable
@MainActor
final class DoctorModel {
    struct Check: Identifiable {
        enum State { case ok, warn, fail }
        var id: String { title }
        var title: String
        var detail: String
        var state: State
        var fix: Fix?
    }

    enum Fix {
        case updateMole, setUpMole, openFullDiskAccess, restoreWhitelist, openAnalyze, runInTerminal(String), enableTouchID
        var title: String {
            switch self {
            case .enableTouchID: "Turn On"
            case .updateMole: "Update Mole"
            case .setUpMole: "Set up Mole"
            case .openFullDiskAccess: "Open Settings"
            case .restoreWhitelist: "Restore"
            case .openAnalyze: "Open Analyze"
            case .runInTerminal: "Copy command"
            }
        }
    }

    var checks: [Check] = []
    var running = false
    var log: [String] = []

    func run() async {
        running = true
        defer { running = false }
        var out: [Check] = []

        // Mole itself
        let install = MoleInstall.shared
        await install.detect()
        if let mo = install.path {
            let version = install.version ?? "unknown"
            if case .untrusted(let problem) = install.state {
                out.append(Check(title: "Bubble won't run this copy of Mole",
                                 detail: problem, state: .fail))
            } else {
                out.append(Check(title: "Mole is installed", detail: "Version \(version) at \(mo)", state: .ok))
            }
            if install.hasHomebrew {
                if let latest = await MoleInstall.homebrewLatest() {
                    out.append(Check(title: "Mole has an update", detail: "\(version) → \(latest). Updates bring new cleanup rules and fixes.",
                                     state: .warn, fix: .updateMole))
                } else {
                    out.append(Check(title: "Mole is up to date", detail: "Homebrew has nothing newer.", state: .ok))
                }
            }
        } else {
            out.append(Check(title: "Mole isn't installed", detail: "Bubble uses Mole, a free command-line cleaner, to do the work. Setup installs it for you.",
                             state: .fail, fix: .setUpMole))
        }

        // Permissions
        out.append(SystemSettings.hasFullDiskAccess
            ? Check(title: "Full Disk Access is on", detail: "Mole can scan Trash, Mail and other protected folders.", state: .ok)
            : Check(title: "Full Disk Access is off", detail: "Scans skip protected folders until you allow Bubble in System Settings.",
                    state: .warn, fix: .openFullDiskAccess))

        out.append(Admin.touchIDForSudo()
            ? Check(title: "Touch ID works for admin tasks", detail: "Bubble's admin tasks and sudo in Terminal can use Touch ID.", state: .ok)
            : Check(title: "Admin tasks ask for your password",
                    detail: "Turn on Touch ID for sudo so Bubble's admin tasks (and sudo in Terminal) can use your fingerprint.",
                    state: .warn, fix: .enableTouchID))

        // Leftover state from an interrupted clean. A clean that is running right now
        // has a backup too; that's expected.
        if Whitelist.hasStaleBackup {
            out.append(Check(title: "A protected-items change wasn't undone",
                             detail: "A clean was interrupted before Bubble restored your protected items.",
                             state: .fail, fix: .restoreWhitelist))
        }

        // Disk
        let vol = VolumeInfo.root
        let freeFraction = vol.total > 0 ? 1 - vol.used / vol.total : 1
        out.append(freeFraction < 0.1
            ? Check(title: "Your disk is nearly full", detail: "\(Fmt.bytes(vol.total - vol.used)) free. macOS slows down below about 10%.",
                    state: .warn, fix: .openAnalyze)
            : Check(title: "Plenty of disk space", detail: "\(Fmt.bytes(vol.total - vol.used)) free of \(Fmt.bytes(vol.total)).", state: .ok))

        // Live health from mo status
        if let score = StatusModel.shared.snap?.healthScore {
            out.append(Check(title: "System health \(score)", detail: StatusModel.shared.snap?.healthScoreMsg ?? "",
                             state: score >= 80 ? .ok : score >= 50 ? .warn : .fail))
        }
        checks = out
    }

    // MARK: Touch ID for sudo

    /// Root script that turns on pam_tid in /etc/pam.d/sudo_local (which survives macOS
    /// updates): uncomments it if it's there, adds it first otherwise, or starts from Apple's
    /// template. Writes a temporary file beside it and moves it into place.
    nonisolated static let touchIDScript = """
    set -e
    f=/etc/pam.d/sudo_local
    t=/etc/pam.d/sudo_local.template
    line='auth       sufficient     pam_tid.so'
    if [ -f "$f" ]; then
      if grep -Eq '^[[:space:]]*#[[:space:]]*auth[[:space:]].*pam_tid\\.so' "$f"; then
        sed -E 's/^[[:space:]]*#[[:space:]]*(auth[[:space:]].*pam_tid\\.so.*)$/\\1/' "$f" > "$f.bubble"
      else
        { printf '%s\\n' "$line"; cat "$f"; } > "$f.bubble"
      fi
    elif [ -f "$t" ]; then
      sed 's/^#auth/auth/' "$t" > "$f.bubble"
    else
      printf '%s\\n' "$line" > "$f.bubble"
    fi
    chown root:wheel "$f.bubble"
    chmod 444 "$f.bubble"
    mv -f "$f.bubble" "$f"

    """

    /// What to paste in Terminal when Bubble can't write the file itself.
    nonisolated static var touchIDTerminalCommand: String {
        FileManager.default.fileExists(atPath: "/etc/pam.d/sudo_local")
            ? "mo touchid enable"
            : "sed 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local"
    }

    nonisolated static func touchIDFailureMessage(_ error: Error) -> [String] {
        let reason: String = if case Admin.Failure.failed(let why) = error { why } else { error.localizedDescription }
        if reason.localizedCaseInsensitiveContains("Operation not permitted") {
            return ["macOS blocked Bubble from changing /etc/pam.d. That needs Full Disk Access for Bubble.",
                    "The command is on your clipboard instead: paste it into Terminal and press Return."]
        }
        return ["Couldn't turn on Touch ID for sudo: \(reason)",
                "The command is on your clipboard: paste it into Terminal and press Return."]
    }

    func apply(_ fix: Fix, openTab: (Tab) -> Void) async {
        switch fix {
        case .openFullDiskAccess: SystemSettings.openFullDiskAccess()
        case .restoreWhitelist:
            // Never pull the temporary list out from under a running clean.
            if !Whitelist.cleanInProgress { Whitelist.restoreIfNeeded() }
        case .openAnalyze: openTab(.analyze)
        case .setUpMole:
            // The main window shows setup whenever Mole is missing.
            await MoleInstall.shared.refresh()
            openTab(.clean)
            return
        case .runInTerminal(let cmd):
            Clipboard.copy(cmd)
        case .enableTouchID:
            log = []
            do {
                _ = try await Admin.run(Self.touchIDScript, prompt: "Bubble wants to turn on Touch ID for sudo.")
            } catch Admin.Failure.cancelled {
                // Nothing changed; the check stays as it was.
            } catch {
                log = Self.touchIDFailureMessage(error)
                Clipboard.copy(Self.touchIDTerminalCommand)
                Terminal.open()
            }
        case .updateMole:
            // Same runner as setup and Settings: Homebrew or Mole's updater, dry run when simulating.
            let install = MoleInstall.shared
            log = []
            await install.runToEnd(install.updateMethod)
            log = install.log
        }
        await run()
    }
}

struct DoctorSheet: View {
    @State private var model = DoctorModel()
    @AppStorage("lastTab") private var tab: Tab = .clean
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Checkup").font(.ui(.title, .bold))
                if model.running { ProgressView().controlSize(.small) }
                Spacer()
                IconButton(systemName: "arrow.clockwise", label: "Check again") { Task { await model.run() } }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.checks.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().overlay(Palette.cardStroke).padding(.leading, 40) }
                    row(c)
                }
            }
            .panel()
            .motion(model.checks.map(\.id))
            if !model.log.isEmpty {
                LogBox(lines: model.log, tail: 4)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 600)
        .task { await model.run() }
    }

    private func row(_ c: DoctorModel.Check) -> some View {
        let (icon, color): (String, Color) = switch c.state {
        case .ok: ("checkmark.circle.fill", Palette.green)
        case .warn: ("exclamationmark.circle.fill", Palette.amber)
        case .fail: ("xmark.circle.fill", Palette.red)
        }
        return HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.ui(.body, .semibold))
                Text(c.detail).font(.ui(.secondary)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if let fix = c.fix {
                Button(fix.title) {
                    Task { await model.apply(fix) { t in tab = t; dismiss() } }
                }
                .disabled(model.running)
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .accessibilityElement(children: .combine)
    }
}
