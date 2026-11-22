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

    // The same page `viewController(for:)` shows, for hosting it directly in SwiftUI.
    // Both routes share the one model, so they stay in step.
    @MainActor
    public static func view(for screen: Screen) -> AnyView {
        AnyView(OnlineFixRoot(model: model, screen: screen))
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
                                    confirmed: Bool = false,
                                    progress: @escaping @Sendable (String) -> Void)
        async -> OnlineFixStoreOutcome {
        await model.installFromStore(appID: appID, name: name,
                                     folderName: folderName, confirmed: confirmed,
                                     progress: progress)
    }

    @MainActor
    public static func storeUninstall(appID: Int) -> OnlineFixStoreOutcome {
        model.uninstallFromStore(appID: appID)
    }

    /// What online-fix.me has for a game, for the store card before anything is
    /// installed: a fix at all, and whether it is the GDK build.
    public static func probeFix(name: String) async -> (available: Bool, gdk: Bool, folder: String?) {
        let probe = await FixSource.probe(name: name)
        return (probe.available, probe.gdk, probe.folder)
    }

    /// The newest NotProton compatibility tool Steam has installed, so the store
    /// page can name it when it switches a native game to the Windows build.
    public static func notProtonTool() -> String? { Steam.notProtonTool() }

    /// Puts the game in My Games and makes Steam start it as Spacewar (480), the
    /// identity OnlineFix gives a Windows build. No files are written.
    @MainActor
    @discardableResult
    public static func storeRouteAsSpacewar(appID: Int, name: String, on: Bool)
        -> OnlineFixStoreStatus {
        model.storeRouteAsSpacewar(on, appID: appID, name: name)
    }

    /// Starts the game as its own AppID instead of Spacewar (480), which is what a
    /// game without an OnlineFix needs when its own code uses Steam's relay. A game
    /// with an OnlineFix matches players as Spacewar, so it does not need this.
    /// A game that is not in My Games yet is added first, so the store page can
    /// offer the choice for any game. Returns false only for an invalid AppID.
    @MainActor
    @discardableResult
    public static func storeKeepRealAppID(appID: Int, name: String = "", keep: Bool) -> Bool {
        model.storeSetKeepRealAppID(keep, appID: appID, name: name)
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
