// macSteam + NotProton: the small public surface the combined app uses to host NotProton.
//
// Everything else in this module stays internal and unchanged. The combined app shows these
// screens as pages in its sidebar and calls installIntoSteam() from its own Install button.

import AppKit
import SwiftUI

public enum NotProtonEmbed {

    public enum Screen: String, CaseIterable, Hashable, Sendable {
        case status
        case prefixes
        case backups

        public var title: String { Pane(rawValue: rawValue)?.label ?? rawValue }
        public var symbol: String { Pane(rawValue: rawValue)?.symbol ?? "questionmark" }
    }

    public struct InstallResult: Sendable {
        public let succeeded: Bool
        public let message: String
    }

    @MainActor private static let status = SystemStatus()
    @MainActor private static let prefixes = PrefixesModel()
    @MainActor private static var controllers: [Screen: NSViewController] = [:]
    @MainActor private static var started = false

    // Call once when the app launches.
    @MainActor
    public static func start() {
        guard !started else { return }
        started = true
        AppLog.start()
    }

    // The page itself, for hosts that show it directly in SwiftUI. Every page shares the same
    // SystemStatus and PrefixesModel, so their state survives switching between pages.
    // Its Refresh / Tools / Reveal / Delete buttons are SwiftUI toolbar items, which the host's
    // NavigationSplitView puts in the window toolbar.
    @MainActor
    public static func view(for screen: Screen) -> AnyView {
        start()
        switch screen {
        case .status: return wrap(StatusView())
        case .prefixes: return wrap(PrefixesView())
        case .backups: return wrap(BackupsView())
        }
    }

    // One view controller per screen, created on first use and then reused. It hosts
    // view(for:), with the toolbar buttons shown in a glass bar at the top of the page,
    // because the hosting controller does not bridge toolbar items into the window.
    @MainActor
    public static func viewController(for screen: Screen) -> NSViewController {
        if let existing = controllers[screen] { return existing }
        let controller = NSHostingController(
            rootView: AnyView(view(for: screen).environment(\.notProtonInlineToolbar, true))
        )
        // The hosting controller must not drive the window's size or toolbar.
        controller.sizingOptions = []
        controller.sceneBridgingOptions = []
        controllers[screen] = controller
        return controller
    }

    // Same bookkeeping NotProton's own window did when its sidebar selection moved away from a page.
    @MainActor
    public static func didLeave(_ screen: Screen) {
        if screen != .status { prefixes.forgetOutcome() }
    }

    // Runs NotProton's normal Install: stages the components, installs notproton.dylib into
    // Steam next to any macSteam dylib, and sets up the CrossOver compatibility tool when
    // CrossOver is installed and activated. Progress also shows on NotProton's Status page.
    @MainActor
    public static func installIntoSteam() async -> InstallResult {
        start()
        if status.isBusy {
            return InstallResult(
                succeeded: false,
                message: "NotProton is busy with another task. Wait for it to finish, then try again."
            )
        }
        // The install reads which CrossOver copies exist from the latest status snapshot.
        await status.refresh()
        await status.installIntoSteam()
        if let failure = status.failure {
            return InstallResult(succeeded: false, message: failure)
        }
        return InstallResult(succeeded: true, message: status.outcome ?? "")
    }

    @MainActor
    private static func wrap<V: View>(_ view: V) -> AnyView {
        AnyView(
            view
                .environment(status)
                .environment(prefixes)
                // Mirrors NotProton's own window: keep the prefix list in step with the runners.
                .onChange(of: status.snapshot?.installedRunners.map(\.id)) {
                    if prefixes.hasLoaded { Task { await prefixes.load() } }
                }
        )
    }
}
