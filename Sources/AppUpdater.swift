#if ACOUPLET_SPARKLE
import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var hasPendingUpdate = false

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        hasPendingUpdate = !state.userInitiated
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasPendingUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasPendingUpdate = false
    }
}
#endif
