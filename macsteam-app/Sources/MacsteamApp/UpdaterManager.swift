// Sparkle auto-update lifecycle
import AppKit
import Combine
import Sparkle

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    // Combined macSteam + NotProton build: automatic updates are switched off on purpose. The
    // stock macSteam update feed would replace this app with plain macSteam (no NotProton).
    func start() {}

    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Updates are turned off in this combined build"
        alert.informativeText = "macSteam and NotProton are built together, so the built-in updater "
            + "(which only knows about plain macSteam) is disabled. To update, rebuild from newer sources."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
