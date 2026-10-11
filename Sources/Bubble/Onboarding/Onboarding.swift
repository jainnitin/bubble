import AppKit
import SwiftUI

/// First-run setup, shown in place of the app until Mole is installed (or updated)
/// and, optionally, Full Disk Access is on. Words and the one action on the left,
/// the bubble on the right, like every other idle screen in Bubble.
struct SetupView: View {
    @State private var install = MoleInstall.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable {
        case checking, welcome, update(String), untrusted(String), working(MoleInstall.Method), failed(MoleInstall.Method, String),
             success(MoleInstall.Method), access
    }

    private var phase: Phase {
        switch install.job {
        case .running(let m): return .working(m)
        case .failed(let m, let why): return .failed(m, why)
        case .succeeded(let m): return .success(m)
        case .idle: break
        }
        if install.askingForAccess { return .access }
        switch install.state {
        case .ready: return .checking
        case .missing: return .welcome
        case .outdated(let v): return .update(v)
        case .untrusted(let why): return .untrusted(why)
        }
    }

    var body: some View {
        HeroView(recede: isWorking) {
            VStack(alignment: .leading, spacing: Space.l) {
                switch phase {
                case .checking: ProgressView().controlSize(.small)
                case .welcome: WelcomeStep(install: install)
                case .update(let v): UpdateStep(install: install, version: v)
                case .untrusted(let why): UntrustedStep(install: install, reason: why)
                case .working(let m): WorkingStep(install: install, method: m)
                case .failed(let m, let why): FailedStep(install: install, method: m, reason: why)
                case .success(let m): SuccessStep(install: install, method: m)
                case .access: AccessStep(install: install)
                }
            }
            .transition(.phase(reduceMotion: reduceMotion))
            .id(phaseKey)
        }
        .motion(phaseKey)
        .onChange(of: phaseKey) { _, _ in announce() }
    }

    private var isWorking: Bool { if case .working = phase { true } else { false } }

    /// Changes only when the step changes, not on every log line.
    private var phaseKey: String {
        switch phase {
        case .checking: "checking"
        case .welcome: "welcome"
        case .update: "update"
        case .untrusted: "untrusted"
        case .working: "working"
        case .failed: "failed"
        case .success: "success"
        case .access: "access"
        }
    }

    private func announce() {
        let text: String? = switch phase {
        case .working(let m): m.isUpdate ? "Updating Mole" : "Installing Mole"
        case .failed(_, let why): why
        case .untrusted(let why): why
        case .success: "Mole is ready"
        case .access: "Allow Full Disk Access"
        default: nil
        }
        if let text { AccessibilityNotification.Announcement(text).post() }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let install: MoleInstall

    var body: some View {
        Headline(text: "Welcome to Bubble")
        Lede(text: "Bubble cleans, tidies and watches over your Mac. The cleaning is done by Mole, a free, open-source tool by tw93, so Bubble installs that first.")
        Link(destination: MoleInstall.repo) {
            Label("Mole on GitHub", systemImage: "arrow.up.right.square")
        }
        .font(.ui(.secondary, .medium))
        .foregroundStyle(Palette.accent)
        .help(MoleInstall.repo.absoluteString)

        if install.hasHomebrew {
            CommandBox(command: MoleInstall.Method.brewInstall.command,
                       caption: "Runs with Homebrew, which is already on this Mac.")
            PillButton(title: "Install Mole") { install.start(.brewInstall) }
                .keyboardShortcut(.defaultAction)
            Hint(icon: "lock", text: "No password needed. It usually takes under a minute.")
        } else {
            Text("Homebrew isn't on this Mac, so Bubble will run Mole's official installer. This is exactly what runs:")
                .font(.ui(.body)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: MoleInstall.scriptCommand,
                       caption: "It downloads the installer from Mole \(MoleInstall.pinnedInstaller.tag) on GitHub, stops unless it matches the SHA-256 built into Bubble, then installs that release in ~/.local/bin inside your home folder. No administrator password needed.")
            PillButton(title: "Run installer") { install.start(.script) }
                .keyboardShortcut(.defaultAction)
            HStack(spacing: Space.l) {
                LinkButton(title: "Open Terminal") { Terminal.open() }
                LinkButton(title: "Check again") { Task { await install.refresh() } }
            }
            .font(.ui(.secondary, .medium))
            Hint(icon: "info.circle", text: "Prefer Homebrew? Install it from brew.sh, then click Check again.")
        }
    }
}

private struct UpdateStep: View {
    let install: MoleInstall
    let version: String

    var body: some View {
        Headline(text: "Mole needs an update")
        Lede(text: "Bubble needs Mole \(MoleInstall.minimumVersion) or later, and this Mac has \(version). Updating keeps your settings and protected items.")
        CommandBox(command: install.updateMethod.command,
                   caption: install.updateMethod == .brewUpgrade ? "Runs with Homebrew." : "Runs Mole's own updater.")
        PillButton(title: "Update Mole") { install.start(install.updateMethod) }
            .keyboardShortcut(.defaultAction)
        LinkButton(title: "Continue without updating") { install.continueWithoutUpdating() }
            .font(.ui(.secondary, .medium))
            .help("Some screens may show errors with an older Mole.")
    }
}

/// `mo` was found, but someone other than you, root or an admin could change it
/// (see `Shell.trustProblem`), so Bubble won't run it or type a password into it.
private struct UntrustedStep: View {
    let install: MoleInstall
    let reason: String

    var body: some View {
        Headline(text: "Bubble won't run this copy of Mole")
        Lede(text: "Mole runs with your password when it needs admin rights, so Bubble only runs it when nobody else can change it. \(reason)")
        PillButton(title: "Check again") { Task { await install.refresh() } }
            .keyboardShortcut(.defaultAction)
        HStack(spacing: Space.l) {
            LinkButton(title: "Copy details") { Clipboard.copy(reason) }
            LinkButton(title: "Open Terminal") { Terminal.open() }
        }
        .font(.ui(.secondary, .medium))
    }
}

private struct WorkingStep: View {
    let install: MoleInstall
    let method: MoleInstall.Method

    var body: some View {
        Headline(text: method.isUpdate ? "Updating Mole" : "Installing Mole")
        Lede(text: method == .script
             ? "Mole's installer is downloading and checking Mole \(MoleInstall.pinnedInstaller.tag)."
             : "Homebrew is downloading Mole. This usually takes under a minute.")
        ProgressView()
            .progressViewStyle(.linear)
            .tint(Palette.accent)
            .frame(maxWidth: 460)
            .accessibilityLabel(method.isUpdate ? "Updating Mole" : "Installing Mole")
        LogBox(lines: install.log, tail: 6, placeholder: "Starting…", minHeight: 110)
            .frame(maxWidth: 460, alignment: .leading)
            .installerOutputAccessibility(install.log)
        LinkButton(title: "Stop") { install.cancel() }
            .font(.ui(.secondary, .medium))
            .keyboardShortcut(.cancelAction)
    }
}

private struct FailedStep: View {
    let install: MoleInstall
    let method: MoleInstall.Method
    let reason: String

    var body: some View {
        Headline(text: method.isUpdate ? "Mole didn't update" : "Mole didn't install")
        Lede(text: reason)
        if !install.log.isEmpty {
            LogBox(lines: install.log)
                .frame(maxWidth: 460, alignment: .leading)
                .frame(height: min(150, CGFloat(max(install.log.count, 2)) * 17 + 4) + 2 * Space.m)
                .installerOutputAccessibility(install.log)
        }
        PillButton(title: "Try again") { install.start(method) }
            .keyboardShortcut(.defaultAction)
        HStack(spacing: Space.l) {
            if !install.log.isEmpty {
                LinkButton(title: "Copy output") { Clipboard.copy(install.log.joined(separator: "\n")) }
            }
            LinkButton(title: "Copy command") { Clipboard.copy(method.command) }
            LinkButton(title: "Open Terminal") { Terminal.open() }
            LinkButton(title: "Back") { install.dismissFailure() }
        }
        .font(.ui(.secondary, .medium))
        Hint(icon: "terminal", text: "You can also paste the command into Terminal, then come back and click Try again.")
    }
}

private struct SuccessStep: View {
    let install: MoleInstall
    let method: MoleInstall.Method

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(Palette.green)
            .accessibilityHidden(true)
        Headline(text: "Mole is ready")
        Lede(text: "Mole \(install.version ?? "") is \(method.isUpdate ? "up to date" : "installed"). Bubble can clean now.")
        if method == .script {
            Hint(icon: "terminal", text: "To use mo in Terminal too, add ~/.local/bin to your PATH.")
        }
        PillButton(title: "Continue") { install.finishInstall() }
            .keyboardShortcut(.defaultAction)
            .task {
                // Move straight on; the button is there for keyboard and VoiceOver users.
                try? await Task.sleep(for: .seconds(2.5))
                if case .succeeded = install.job { install.finishInstall() }
            }
    }
}

private struct AccessStep: View {
    let install: MoleInstall
    @State private var checkedAndOff = false

    var body: some View {
        Label("Mole \(install.version ?? "") is installed.", systemImage: "checkmark.circle.fill")
            .font(.ui(.secondary, .medium))
            .foregroundStyle(Palette.green)
        Headline(text: "Allow Full Disk Access")
        Lede(text: "macOS keeps Trash, Mail and some app data private. With Full Disk Access, Bubble can find and clean what's there. Without it, scans skip those folders.")
        VStack(alignment: .leading, spacing: Space.s) {
            step(1, "Click Open System Settings.")
            step(2, "Turn on Bubble in the list. Use + to add it if it isn't there.")
            step(3, "Come back here. Bubble checks on its own.")
        }
        PillButton(title: "Open System Settings") { SystemSettings.openFullDiskAccess() }
            .keyboardShortcut(.defaultAction)
        HStack(spacing: Space.l) {
            LinkButton(title: "Check again") { check() }
            LinkButton(title: "Later") { install.finishAccess(skipped: true) }
        }
        .font(.ui(.secondary, .medium))
        if checkedAndOff {
            Hint(icon: "exclamationmark.circle", text: "Still off. If you just turned it on, quit and reopen Bubble.")
        }
        Color.clear.frame(height: 0)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check(quiet: true) }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(n)")
                .font(.num(.caption, .semibold))
                .foregroundStyle(Palette.abyss)
                .frame(width: 18, height: 18)
                .background(Palette.accent, in: Circle())
            Text(text).font(.ui(.body)).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func check(quiet: Bool = false) {
        if MoleInstall.hasFullDiskAccess {
            install.finishAccess(skipped: false)
        } else if !quiet {
            checkedAndOff = true
        }
    }
}

// MARK: - Pieces

/// A command shown before it runs, with a copy button.
struct CommandBox: View {
    let command: String
    var caption: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Text(command)
                    .font(.path(.body))
                    .foregroundStyle(Palette.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Clipboard.copy(command)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 24, height: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.quiet)
                .foregroundStyle(copied ? Palette.green : Palette.secondary)
                .help("Copy command")
                .accessibilityLabel(copied ? "Copied" : "Copy command")
            }
            if let caption {
                Text(caption)
                    .font(.ui(.secondary))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: 460, alignment: .leading)
        .panel(radius: Radius.row, fill: Color.black.opacity(0.25), style: .continuous)
    }
}

private extension View {
    func installerOutputAccessibility(_ lines: [String]) -> some View {
        accessibilityLabel("Installer output").accessibilityValue(lines.suffix(3).joined(separator: ". "))
    }
}
