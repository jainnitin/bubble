import Observation
import Sparkle
import SwiftUI

/// Self-update via Sparkle 2. Feed URL and EdDSA public key come from Info.plist, which
/// scripts/bundle.sh fills from updates.conf. Updates are only installed when their archive's
/// EdDSA signature matches SUPublicEDKey (and the appcast itself is signed: SURequireSignedFeed).
///
/// Creating `shared` starts the updater, which schedules Sparkle's background checks.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Sparkle only runs from a bundled .app that has a real feed URL and public key, so
    /// `swift run` and builds with the placeholder repo don't nag with feed errors.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = info["SUFeedURL"] as? String, !feed.contains("/OWNER/"),
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty
        else { return false }
        return true
    }

    private init() {
        guard Self.isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        }
    }

    /// Sparkle's own setting (saved as SUEnableAutomaticChecks in Bubble's defaults), read
    /// live from Sparkle. Without SUEnableAutomaticChecks in Info.plist, Sparkle asks on the
    /// second launch before checking; this toggle answers that question from Settings.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            guard let controller else { return }
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Bubble ▸ Check for Updates…
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
    }
}

/// A view, so the menu item's enabled state follows `Updater.canCheckForUpdates`.
private struct CheckForUpdatesButton: View {
    @State private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
