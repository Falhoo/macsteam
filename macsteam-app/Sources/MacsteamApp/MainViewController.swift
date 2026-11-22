// Main window content: the Liquid Glass shell (UI/GlassShell.swift) hosting macSteam's pages.
import AppKit
import SwiftUI
import NotProtonApp
import OnlineFixApp

final class MainViewController: NSHostingController<GlassShell> {
    let store: ConfigStore
    let model: ShellModel
    private var pages: PageControllers { model.pages }

    init(store: ConfigStore) {
        self.store = store
        let model = ShellModel(pages: PageControllers(store: store))
        self.model = model
        super.init(rootView: GlassShell(model: model))
        // Let the SwiftUI shell own the window's title and toolbar.
        sceneBridgingOptions = [.title, .toolbars]
        sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func viewWillAppear() {
        super.viewWillAppear()
        NSApp.appearance = AppAppearance.stored.nsAppearance
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
    }

    /// Show the Fixes pane for one game. The Steam store page hands a game over this way.
    func openFixes(appID: Int) {
        model.select(.fixes)
        pages.fixesModel.focus(appID: appID)
    }

    /// Show a game's settings on the merged OnlineFix page. The Apps pane's
    /// OnlineFix dialog hands the game over this way.
    func openOnlineFix(appID: Int) {
        model.select(.myGames)
        OnlineFixEmbed.openPatch(appID: appID)
    }

    // MARK: - Menu actions (routed via first responder / nil target)

    @objc func importZip() {
        model.select(.importApps)
        pages.importModel.pickZip()
    }
}

// MARK: - Window

extension MainViewController: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.selection == .importApps ? pages.importModel.reviewUndoManager : nil
    }
}

// MARK: - Pages

/// Every page's model, created once and reused. macSteam's own pages live in UI/Pages;
/// NotProton's and OnlineFix's pages come from their packages' Embed APIs.
@MainActor
final class PageControllers {
    let storeModel: StoreModel
    let fixesModel: FixesModel
    let importModel: ImportModel
    let appsModel: AppsModel
    let installModel = InstallModel()
    let repairModel = RepairModel()
    let settingsModel: SettingsModel
    let cloudSavesModel = CloudSavesModel()

    init(store: ConfigStore) {
        let appsModel = AppsModel(store: store)
        let settingsModel = SettingsModel(store: store)
        self.appsModel = appsModel
        self.settingsModel = settingsModel

        // Pages that show config.yaml re-read it when another page changes it.
        let reloadConfig: @MainActor () -> Void = {
            appsModel.reloadFromStore()
            settingsModel.reload()
        }

        var storeRef: StoreModel?
        var fixesRef: FixesModel?
        importModel = ImportModel(store: store, onConfigChanged: reloadConfig)
        let storeModel = StoreModel(store: store, onConfigChanged: {
            reloadConfig()
            storeRef?.reloadFromStore()
        })
        let fixesModel = FixesModel(store: store, onConfigChanged: {
            reloadConfig()
            fixesRef?.refreshAfterInstall()
        })
        self.storeModel = storeModel
        self.fixesModel = fixesModel
        storeRef = storeModel
        fixesRef = fixesModel
    }

    func content(for page: Page) -> PageContent {
        switch page {
        case .store: .native(AnyView(StorePage(model: storeModel)))
        case .fixes: .native(AnyView(FixesPage(model: fixesModel)))
        case .importApps: .native(AnyView(ImportPage(model: importModel)))
        case .apps: .native(AnyView(AppsPage(model: appsModel)))
        case .myGames: .native(OnlineFixEmbed.view(for: .myGames))
        case .addGames: .native(OnlineFixEmbed.view(for: .addGames))
        case .install: .native(AnyView(InstallPage(model: installModel)))
        case .repairSteam: .native(AnyView(RepairPage(model: repairModel)))
        case .settings: .native(AnyView(SettingsPage(model: settingsModel)))
        case .cloudSaves: .native(AnyView(CloudSavesPage(model: cloudSavesModel)))
        case .status: .native(NotProtonEmbed.view(for: .status))
        case .prefixes: .native(NotProtonEmbed.view(for: .prefixes))
        case .prefixBackups: .native(NotProtonEmbed.view(for: .backups))
        }
    }

    /// Bookkeeping the old sidebar did when the selection moved.
    func willShow(_ page: Page, leaving previous: Page?) {
        if let previous, let left = Self.notProtonScreen(previous), previous != page {
            NotProtonEmbed.didLeave(left)
        }
        if page == .myGames || page == .addGames {
            OnlineFixEmbed.refresh()
        }
    }

    private static func notProtonScreen(_ page: Page) -> NotProtonEmbed.Screen? {
        switch page {
        case .status: .status
        case .prefixes: .prefixes
        case .prefixBackups: .backups
        default: nil
        }
    }
}
