import Foundation

/// The admin part of maintenance, done by Bubble instead of Mole.
///
/// Mole would read the admin password itself and pipe it into sudo, so Touch ID can't
/// work and Bubble would have to collect the password. Instead `mo optimize` runs with
/// sudo unavailable (see `MoleNoSudo`), Mole skips its admin tasks and says which ones it
/// skipped, and Bubble runs the worthwhile ones in one `Admin.run` call at the end, behind
/// Touch ID when sudo has it enabled, otherwise the macOS authorization dialog, which asks
/// for an administrator's name and password. The jobs mirror Mole's conditions:
///
/// - DNS cache flush: Mole flushes on every run unless a VPN is the default route
///   (flushing makes VPN clients reconnect, and an unknown VPN state also skips).
/// - Spotlight rebuild (`mdutil -E /`): only when Mole found Spotlight slow on AC power
///   and printed "Spotlight index rebuild · skipped (admin access required)".
///
/// Left out on purpose: `route -n flush` / `arp -a -d` (drops every route, including the
/// default one, cutting connections until the network reconfigures), `diskutil
/// resetUserPermissions` (rewrites ownership and ACLs across the home folder; Mole rates it
/// medium risk and runs it only when the home folder is already broken), and `periodic`
/// (gone on macOS 26 and a background job anyway). Mole still reports those as needing a look.
enum OptimizeAdmin {
    enum Job: String, CaseIterable, Sendable {
        case dns, spotlight

        /// The row shown in the task list, in Mole's title style.
        var taskName: String {
            switch self {
            case .dns: "DNS Cache Flush"
            case .spotlight: "Spotlight Index Rebuild"
            }
        }

        /// Result line, with Mole's prefixes (→ done, ◎ needs a look).
        func resultLine(ok: Bool) -> String {
            switch (self, ok) {
            case (.dns, true): "→ DNS cache flushed"
            case (.dns, false): "◎ Failed to flush the DNS cache"
            case (.spotlight, true): "→ Spotlight index rebuild started, indexing continues in the background"
            case (.spotlight, false): "◎ Failed to start the Spotlight index rebuild"
            }
        }

        /// Commands run as root. Absolute paths; arguments quoted.
        fileprivate var command: String {
            switch self {
            case .dns:
                "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
            case .spotlight:
                "/usr/bin/mdutil -E \(Admin.quote("/"))"
            }
        }
    }

    static let resultMarker = "bubble-result"

    /// One root script for every job, in `Job.allCases` order. Each job runs whatever
    /// happened to the one before and reports one "bubble-result <job> ok|failed" line.
    static func script(for jobs: Set<Job>) -> String {
        var lines = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH"]
        for job in Job.allCases where jobs.contains(job) {
            lines.append("if { \(job.command); } >/dev/null 2>&1; then echo \(Admin.quote("\(resultMarker) \(job.rawValue) ok")); "
                         + "else echo \(Admin.quote("\(resultMarker) \(job.rawValue) failed")); fi")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The sentence in the authorization dialog.
    static func prompt(for jobs: Set<Job>) -> String {
        let parts = Job.allCases.filter(jobs.contains).map { job in
            switch job {
            case .dns: "flush the DNS cache"
            case .spotlight: "rebuild the Spotlight index"
            }
        }
        return "Bubble wants to " + parts.joined(separator: " and ") + " to finish maintenance."
    }

    /// Reads the script's result lines (any line ending). Unknown lines are ignored.
    static func parse(_ output: String) -> [Job: Bool] {
        var out: [Job: Bool] = [:]
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == resultMarker, let job = Job(rawValue: String(parts[1])) else { continue }
            out[job] = parts[2] == "ok"
        }
        return out
    }

    // MARK: VPN, like Mole's has_active_vpn_interface

    enum VPN: Equatable { case none, active, unknown }

    /// `route -n get default` output → whether a VPN tunnel is the default route.
    /// No output means route failed: Mole treats "not in table" (offline) as no VPN, but
    /// Bubble only sees stdout, and flushing DNS offline is pointless, so that's `.unknown`.
    static func vpnState(routeOutput: String) -> VPN {
        for line in routeOutput.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let iface = parts[1].trimmingCharacters(in: .whitespaces)
            return iface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil ? .active : .none
        }
        return .unknown
    }

    static func detectVPN() async -> VPN {
        let data = await Shell.output("/sbin/route", ["-n", "get", "default"], timeout: 5)
        return vpnState(routeOutput: String(decoding: data, as: UTF8.self))
    }

    /// The row for a DNS flush that won't run because of the VPN check.
    static func vpnSkipLine(_ vpn: VPN) -> String? {
        switch vpn {
        case .none: nil
        case .active: "- DNS cache flush skipped, active VPN detected"
        case .unknown: "- DNS cache flush skipped, couldn't check for an active VPN"
        }
    }
}

/// Folds `mo optimize` output lines into tasks. Pure, so it's testable without Mole.
struct OptimizeLog {
    var tasks: [OptimizeTask] = []
    /// Mole ran without admin rights (it said so, or skipped an admin task).
    var moleSkippedAdmin = false
    /// Admin jobs Mole skipped that Bubble can do.
    var deferred: Set<OptimizeAdmin.Job> = []
    /// Whether Bubble will do the deferred jobs itself (changes how Mole's skips read).
    var adminTasksOn: Bool
    /// Task titles Bubble had Mole skip for lack of Full Disk Access (`OptimizeWhitelist`).
    var skippedForFullDiskAccess: Set<String>

    init(adminTasksOn: Bool, skippedForFullDiskAccess: Set<String> = []) {
        self.adminTasksOn = adminTasksOn
        self.skippedForFullDiskAccess = skippedForFullDiskAccess
    }

    static let fullDiskAccessSkip = "- Skipped: needs Full Disk Access"

    mutating func consume(_ line: String) {
        let text = Self.body(line)
        if line.hasPrefix("➤") {
            // Mole's sudo request ("➤ System optimization requires admin access",
            // "➤ Enter your credentials:") uses the same arrow as a task heading.
            if Self.isAuthChatter(text) { return }
            tasks.append(OptimizeTask(name: text))
            return
        }
        if line.contains("admin access not granted") { moleSkippedAdmin = true }
        guard !tasks.isEmpty, let first = line.first, "→◎-✓✗".contains(first) else { return }
        var result = line
        if text.hasPrefix("Skipped (whitelisted)"), let task = tasks.last, skippedForFullDiskAccess.contains(task.name) {
            result = Self.fullDiskAccessSkip
        } else if Self.isAdminSkip(text) {
            moleSkippedAdmin = true
            let job = Self.deferredJob(text)
            if let job { deferred.insert(job) }
            // A skip reads as skipped (Mole prints some with ✓). Keep ◎ on the ones nobody
            // will do, so a real problem Mole found still stands out.
            if !(first == "◎" && (job == nil || !adminTasksOn)) {
                result = "- " + text + (job != nil && adminTasksOn ? ", Bubble does this at the end" : "")
            }
        }
        tasks[tasks.count - 1].results.append(result)
    }

    /// The line without Mole's leading symbol.
    static func body(_ line: String) -> String {
        guard let first = line.first, "➤→◎-✓✗".contains(first) else { return line }
        return line.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    static func isAuthChatter(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("admin access") || t.contains("credentials") || t.contains("touch id")
    }

    static func isAdminSkip(_ text: String) -> Bool {
        text.contains("admin access required") || text.contains("(requires sudo)")
    }

    /// Mole's skip lines for work Bubble does instead.
    static func deferredJob(_ text: String) -> OptimizeAdmin.Job? {
        if text.hasPrefix("Spotlight index rebuild") { return .spotlight }
        if text.hasPrefix("DNS & Spotlight check") || text.hasPrefix("Network cache refresh") { return .dns }
        return nil
    }
}

/// Makes `sudo` unavailable to one `mo optimize` run, so Mole never asks for a password
/// (and, with Touch ID for sudo turned on, never shows sudo's own Touch ID sheet).
///
/// A private folder holding a `sudo` that always answers "not authorized" goes first on
/// PATH (Mole calls plain `sudo`). Mole then takes its normal no-admin path: every admin
/// task is gated by `optimize_sudo_available`, and its other uses are `sudo -n` probes that
/// fail the same way without cached credentials. `MOLE_PAM_SUDO_*` only tells Mole's
/// `check_touchid_support` that Touch ID isn't set up, which skips its 5-second Touch ID
/// attempt and the "Touch ID dialog may appear" note. If the folder can't be made, the
/// run still works: sudo's prompt is ended with Ctrl-D (`PromptResponder`).
enum MoleNoSudo {
    static let shim = """
    #!/bin/sh
    # Bubble: this mo optimize run has no admin rights; Bubble runs the admin tasks itself.
    case "$1" in -k|-K) exit 0 ;; esac
    exit 1

    """

    /// Creates the folder; nil if that fails.
    static func make() -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bubble-nosudo-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("sudo")
            guard fm.createFile(atPath: file.path, contents: Data(shim.utf8), attributes: [.posixPermissions: 0o700]) else {
                try? fm.removeItem(at: dir)
                return nil
            }
            return dir
        } catch {
            return nil
        }
    }

    static func environment(shimDir: URL?) -> [String: String] {
        var env = ["MOLE_PAM_SUDO_FILE": "/dev/null", "MOLE_PAM_SUDO_LOCAL_FILE": "/dev/null"]
        if let shimDir { env["PATH"] = shimDir.path + ":" + Shell.childPath }
        return env
    }

    static func remove(_ dir: URL?) {
        guard let dir, dir.lastPathComponent.hasPrefix("bubble-nosudo-") else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
