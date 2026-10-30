import Combine
import Sparkle

/// Owns Sparkle's updater for the lifetime of the application and exposes only
/// the user-facing controls islo needs.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticUpdatesEnabled = false

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = updaterController.updater

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .combineLatest(
                updater.publisher(for: \.automaticallyDownloadsUpdates)
            )
            .map { checks, downloads in checks && downloads }
            .assign(to: &$automaticUpdatesEnabled)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
        automaticUpdatesEnabled = enabled
    }
}
