import AppKit
import Observation
import Sparkle

@Observable
@MainActor
final class UpdateController {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let driverDelegate = UpdateDriverDelegate()

    // Builds without an embedded public key (local development) keep the updater off.
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return !key.isEmpty && !feed.isEmpty
    }

    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isConfigured, updaterDelegate: nil, userDriverDelegate: driverDelegate)
        automaticallyChecks = Self.isConfigured && controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard Self.isConfigured else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// A menu-bar app's scheduled update prompt would otherwise hide behind other windows.
final class UpdateDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate()
    }
}
