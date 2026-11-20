// macSteam + OnlineFix: the small public surface the combined app uses to host
// OnlineFix Manager's pages.
//
// Everything else in this module stays internal and unchanged. The combined app shows
// My Games and Add Games as pages in its sidebar.

import AppKit
import SwiftUI

public enum OnlineFixEmbed {

    public enum Screen: String, CaseIterable, Hashable, Sendable {
        case myGames
        case addGames

        public var title: String {
            switch self {
            case .myGames: return "My Games"
            case .addGames: return "Add Games"
            }
        }

        public var symbol: String {
            switch self {
            case .myGames: return "gamecontroller"
            case .addGames: return "plus.square.on.square"
            }
        }
    }

    @MainActor private static let model = AppModel()
    @MainActor private static var controllers: [Screen: NSViewController] = [:]

    // One view controller per page, created on first use and then reused.
    @MainActor
    public static func viewController(for screen: Screen) -> NSViewController {
        if let existing = controllers[screen] { return existing }
        let controller = NSHostingController(rootView: OnlineFixRoot(model: model, screen: screen))
        // The hosting controller must not drive the window's size or toolbar.
        controller.sizingOptions = []
        controllers[screen] = controller
        return controller
    }

    // Re-reads games.json, the Steam library and the fix's install state.
    @MainActor
    public static func refresh() {
        model.refresh()
    }

    // Opens the patch sheet for a game, the same as the sliders button on its row.
    @MainActor
    public static func openPatch(appID: Int) {
        model.openPatch(appID)
    }

    // Puts a game in the manager's list if it is not there yet, so a game handed
    // over from the Apps pane can open its settings straight away.
    @MainActor
    public static func prepareGame(appID: Int, name: String) {
        model.addGameIfNeeded(id: appID, name: name)
    }

    // Re-sends the list and toggles to whoever is writing config.yaml.
    @MainActor
    public static func pushRouting() {
        model.emitRouting()
    }

    @MainActor
    public static func routingEntries() -> [RoutingEntry] {
        model.routingEntries
    }

    // The Steam store page's "Use OnlineFix" card.
    @MainActor
    public static func storeStatus(appID: Int) -> OnlineFixStoreStatus {
        model.storeStatus(appID: appID)
    }

    @MainActor
    public static func storeInstall(appID: Int, name: String,
                                    folderName: String? = nil,
                                    progress: @escaping @Sendable (String) -> Void)
        async -> OnlineFixStoreOutcome {
        await model.installFromStore(appID: appID, name: name,
                                     folderName: folderName, progress: progress)
    }

    @MainActor
    public static func storeUninstall(appID: Int) -> OnlineFixStoreOutcome {
        model.uninstallFromStore(appID: appID)
    }

    /// Starts the game as its own AppID instead of Spacewar (480), which is what
    /// games on Steam's relay network (SDR) need. Returns false when the game is
    /// not in My Games, so there is nothing to change.
    @MainActor
    @discardableResult
    public static func storeKeepRealAppID(appID: Int, keep: Bool) -> Bool {
        model.storeSetKeepRealAppID(keep, appID: appID)
    }

}

// The page itself. It observes the model, so the patch sheet appears and closes
// when model.patchTarget changes; a sheet attached to a view that does not
// observe the model never re-reads its binding and never presents.
private struct OnlineFixRoot: View {
    @ObservedObject var model: AppModel
    let screen: OnlineFixEmbed.Screen

    var body: some View {
        Group {
            switch screen {
            case .myGames: MyGamesView()
            case .addGames: AddGamesView()
            }
        }
        .environmentObject(model)
        .sheet(item: $model.patchTarget) { target in
            PatchSheetView(gameID: target.id)
                .environmentObject(model)
        }
        .onAppear { model.refresh() }
    }
}
