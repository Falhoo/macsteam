// Fixes page: the public LuaTools Denuvo fix catalog, and a sheet per game to install a
// fix's Lua + manifests, copy its files into the game folder, or undo them.
// Logic ported from the old FixesViewController (catalog), LuaToolsFixDetailViewController
// (the per-game sheet) and LuaToolsFixCardView (one fix in that sheet).
import AppKit
import GlassUI
import SwiftUI

// MARK: - Catalog model

/// Ask the list to bring a game into view. The token makes a repeat request for the same
/// game scroll again.
struct FixesScrollRequest: Equatable {
    let gameID: String
    let token = UUID()
}

/// What the list area shows when there are no rows to show.
enum FixesEmptyState: Equatable {
    case loading
    case failed(String)
    case noFixes
    case noMatch
}

@MainActor
final class FixesModel: ObservableObject {
    let store: ConfigStore
    private let onConfigChanged: @MainActor () -> Void
    private let client = LuaToolsFixesClient.shared

    @Published private(set) var games: [LuaToolsFixGame] = []
    @Published private(set) var tags: [LuaToolsFixTag] = []
    @Published private(set) var statusText = ""
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var countText = ""
    @Published private(set) var emptyState: FixesEmptyState? = .loading
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDetail = false

    // Filters.
    @Published private(set) var query = ""
    @Published private(set) var selectedTag: String?
    @Published private(set) var myGamesOnly = false
    /// Games Steam also ships as a native macOS build: LuaTools' Windows fixes cannot patch
    /// those, so they are hidden unless the toggle shows them.
    @Published private(set) var showNativeMacGames = UserDefaults.standard.bool(forKey: "showNativeMacFixes")

    /// The per-game sheet; the page presents it while this is set.
    @Published var detail: FixesDetailModel?
    /// A game the list should scroll to (consumed by the page).
    @Published private(set) var scrollRequest: FixesScrollRequest?
    /// The game handed over by `focus(appID:)`, briefly highlighted in the list.
    @Published private(set) var highlightedGameID: String?

    private var allGames: [LuaToolsFixGame] = []
    private var nativeMacGames: Set<Int> = []
    private var loadTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    /// App id handed over from the Steam store page, opened once the catalog is in.
    private var pendingFocus: Int?

    var isBusy: Bool { isLoading || isLoadingDetail }

    init(store: ConfigStore, onConfigChanged: @escaping @MainActor () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        updateStatus()
    }

    /// The page came on screen (the old viewDidAppear).
    func pageAppeared() {
        store.load()
        if allGames.isEmpty, !isLoading {
            load(force: false)
        } else if myGamesOnly {
            applyFilter()
        }
    }

    // MARK: Loading

    func refresh() {
        load(force: true)
    }

    private func load(force: Bool) {
        guard !isLoading else { return }
        loadTask?.cancel()
        setBusy(true)
        emptyState = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listings = try await client.listings(force: force)
                guard !Task.isCancelled else { return }
                let native = await NativeMacGames.refresh(
                    appIDs: listings.games.compactMap(\.numericAppID))
                guard !Task.isCancelled else { return }
                self.nativeMacGames = native
                self.allGames = listings.games
                self.tags = listings.tags
                // Keep the chosen tag if the new catalog still has it.
                if let selected = self.selectedTag, !listings.tags.contains(where: { $0.id == selected }) {
                    self.selectedTag = nil
                }
                self.store.load()
                self.applyFilter()
                self.setBusy(false)
                self.applyPendingFocus()
            } catch {
                guard !Task.isCancelled else { return }
                self.setBusy(false)
                self.updateStatus(error: error.localizedDescription)
                self.emptyState = .failed(error.localizedDescription)
                self.applyPendingFocus()
            }
        }
    }

    private func applyFilter() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = allGames
        // Windows-only fixes: hidden for games Steam also ships a native macOS build
        // of, unless the toggle asks to see them.
        if !showNativeMacGames {
            shown = shown.filter { game in
                guard let appID = game.numericAppID else { return true }
                return !nativeMacGames.contains(appID)
            }
        }
        if let selectedTag {
            shown = shown.filter { game in
                game.tags.contains { $0.id == selectedTag }
            }
        }
        if myGamesOnly {
            let apps = Set(store.config.apps)
            shown = shown.filter { game in
                guard let appID = game.numericAppID else { return false }
                return apps.contains(appID)
            }
        }
        if !query.isEmpty {
            shown = shown.filter { game in
                game.name.localizedCaseInsensitiveContains(query)
                    || game.appID.contains(query)
            }
        }
        games = shown
        if games.isEmpty {
            emptyState = allGames.isEmpty ? .noFixes : .noMatch
        } else {
            emptyState = nil
        }
        updateCount()
        updateStatus()
    }

    private func updateCount() {
        let totalFixes = allGames.reduce(0) { $0 + $1.fixCount }
        if games.count == allGames.count {
            countText = "\(allGames.count) games · \(totalFixes) fixes"
        } else {
            countText = "\(games.count) of \(allGames.count) games"
        }
    }

    private func updateStatus(error: String? = nil) {
        if let error {
            setStatus(error, tone: .bad)
            return
        }
        if isLoading {
            setStatus("Loading LuaTools fixes…", tone: .neutral)
        } else if allGames.isEmpty {
            setStatus("LuaTools fixes unavailable.", tone: .warn)
        } else if games.count == allGames.count {
            let hidden = showNativeMacGames ? 0 : nativeMacGames.count
            var title = "LuaTools fix catalog"
            if hidden > 0 { title += " · \(hidden) native macOS hidden" }
            if showNativeMacGames, !nativeMacGames.isEmpty { title += " · showing native macOS" }
            setStatus(title, tone: .ok)
        } else {
            setStatus("Filtered LuaTools fixes", tone: .ok)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }

    private func setBusy(_ busy: Bool) {
        isLoading = busy
        updateStatus()
    }

    // MARK: Actions

    func openLuaTools() {
        NSWorkspace.shared.open(LuaToolsFixesClient.webURL)
    }

    func setQuery(_ text: String) {
        query = text
        applyFilter()
    }

    func setTag(_ tagID: String?) {
        selectedTag = tagID
        store.load()
        applyFilter()
    }

    func setMyGamesOnly(_ on: Bool) {
        myGamesOnly = on
        store.load()
        applyFilter()
    }

    func setShowNativeMacGames(_ on: Bool) {
        showNativeMacGames = on
        UserDefaults.standard.set(on, forKey: "showNativeMacFixes")
        applyFilter()
    }

    /// Re-reads config.yaml after another page (or a fix's Manifest) changed it.
    func refreshAfterInstall() {
        store.load()
        if myGamesOnly {
            applyFilter()
        }
    }

    /// The row's View button.
    func showFixes(for game: LuaToolsFixGame) {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        setStatus("Loading fixes for \(game.name)…", tone: .neutral)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingDetail = false }
            do {
                let id = game.numericAppID ?? 0
                guard !(await NativeMacGames.resolve(appID: id)) else {
                    self.updateStatus(error: "\(game.name) has a native macOS build, "
                                      + "so LuaTools' Windows fixes do not apply.")
                    return
                }
                let detail = try await client.fixes(appID: game.appID)
                let appID = game.numericAppID ?? 0
                let installDir = await Task.detached {
                    SteamLibrary.installDir(appID: appID)
                }.value
                self.detail = FixesDetailModel(game: game, detail: detail, installDir: installDir,
                                               store: self.store, onConfigChanged: self.onConfigChanged)
                self.updateStatus()
            } catch {
                self.updateStatus(error: error.localizedDescription)
                presentAlert("Couldn’t load fixes", error.localizedDescription, style: .warning)
            }
        }
    }

    // MARK: Hand-off from the Steam store page

    /// Open this game's fix list. The store page cannot install a fix itself: it runs in a
    /// windowless helper without the sign-in or the folder-permission prompts.
    func focus(appID: Int) {
        pendingFocus = appID
        if allGames.isEmpty && !isLoading {
            load(force: false)          // asks for the focus when it finishes
        } else if !isLoading {
            applyPendingFocus()
        }
    }

    private func applyPendingFocus() {
        guard let appID = pendingFocus else { return }
        pendingFocus = nil
        if let game = allGames.first(where: { $0.numericAppID == appID }) {
            if games.contains(where: { $0.numericAppID == appID }) {
                scrollRequest = FixesScrollRequest(gameID: game.id)
                highlight(game.id)
            }
            showFixes(for: game)
        } else {
            // Not in the public catalog: ask for the game's fixes by app id instead.
            showFixes(appID: appID)
        }
    }

    /// The page has scrolled to the requested game.
    func didScroll(to request: FixesScrollRequest) {
        if scrollRequest == request { scrollRequest = nil }
    }

    private func highlight(_ gameID: String) {
        highlightedGameID = gameID
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.highlightedGameID == gameID else { return }
            self.highlightedGameID = nil
        }
    }

    /// The sheet for a game the catalog does not list, built from the fix API's own reply.
    private func showFixes(appID: Int) {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        setStatus("Loading fixes…", tone: .neutral)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingDetail = false }
            do {
                guard !(await NativeMacGames.resolve(appID: appID)) else {
                    self.updateStatus(error: "App \(appID) has a native macOS build, "
                                      + "so LuaTools' Windows fixes do not apply.")
                    return
                }
                let detail = try await client.fixes(appID: String(appID))
                guard !detail.fixes.isEmpty else {
                    self.updateStatus(error: "LuaTools has no fixes for App \(appID).")
                    return
                }
                let game = LuaToolsFixGame(appID: detail.appID,
                                           name: detail.name,
                                           headerImage: detail.headerImage,
                                           fixCount: detail.fixes.count,
                                           tags: [])
                let installDir = await Task.detached {
                    SteamLibrary.installDir(appID: appID)
                }.value
                self.detail = FixesDetailModel(game: game, detail: detail, installDir: installDir,
                                               store: self.store, onConfigChanged: self.onConfigChanged)
                self.updateStatus()
            } catch {
                self.updateStatus(error: error.localizedDescription)
                presentAlert("Couldn’t load fixes", error.localizedDescription, style: .warning)
            }
        }
    }
}

// MARK: - Per-game sheet model

/// What a fix's card offers, from its backup record in the game folder.
enum FixesCardState {
    case notApplied, applied, drifted
}

@MainActor
final class FixesDetailModel: ObservableObject, Identifiable {
    let game: LuaToolsFixGame
    let detail: LuaToolsFixDetail
    private let store: ConfigStore
    private let onConfigChanged: @MainActor () -> Void

    @Published private(set) var installDir: URL?
    @Published private(set) var appliedFixes: [String: SteamAppliedFix] = [:]
    @Published private(set) var isInstalling = false
    @Published private(set) var statusText =
        "Click Manifest on a fix to sign in and download its Lua + manifests."

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    var isGameInstalled: Bool { installDir != nil }

    init(game: LuaToolsFixGame,
         detail: LuaToolsFixDetail,
         installDir: URL?,
         store: ConfigStore,
         onConfigChanged: @escaping @MainActor () -> Void) {
        self.game = game
        self.detail = detail
        self.installDir = installDir
        self.store = store
        self.onConfigChanged = onConfigChanged
        if let installDir {
            appliedFixes = Dictionary(uniqueKeysWithValues:
                SteamFixInstaller.appliedFixes(installDir: installDir)
                    .map { ($0.fixID, $0) })
        }
    }

    func state(for fix: LuaToolsFix) -> FixesCardState {
        guard let applied = appliedFixes[fix.id] else { return .notApplied }
        return applied.isDrifted ? .drifted : .applied
    }

    /// The game may be updated, uninstalled or wiped while the sheet is open; this re-reads
    /// the folder (on appear and whenever macSteam becomes active) so Undo/Install reflect
    /// the disk.
    func reloadFromDisk() {
        guard !isInstalling, let appID = Int(detail.appID) else { return }
        installDir = SteamLibrary.installDir(appID: appID)
        refreshAppliedFixes()
        AppLog.write("fixes: app \(appID) folder \(installDir?.path ?? "not found") "
                     + "buttons \(detail.fixes.map(diagnostic).joined(separator: ", "))",
                     category: "fixes")
    }

    /// What a fix's Install button would do if clicked, for the app log.
    private func diagnostic(_ fix: LuaToolsFix) -> String {
        let installed = isGameInstalled
        let enabled = fix.hasFix && installed && !isInstalling
        let hidden = !fix.hasFix || state(for: fix) == .applied
        return "\(fix.id): installed=\(installed) install=\(enabled)/\(hidden ? "hidden" : "shown")"
    }

    private func refreshAppliedFixes() {
        guard let installDir else {
            appliedFixes = [:]
            return
        }
        appliedFixes = Dictionary(uniqueKeysWithValues:
            SteamFixInstaller.appliedFixes(installDir: installDir)
                .map { ($0.fixID, $0) })
    }

    // MARK: Sheet buttons

    func openWebPage() {
        NSWorkspace.shared.open(LuaToolsFixesClient.webURL(appID: detail.appID))
    }

    func copyAppID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.appID, forType: .string)
    }

    // MARK: Card buttons

    func manifestPressed(_ fix: LuaToolsFix) {
        AppLog.write("fixes: Manifest pressed for \(fix.id)", category: "fixes")
        installManifest(fix: fix)
    }

    func installPressed(_ fix: LuaToolsFix) {
        AppLog.write("fixes: Install pressed for \(fix.id) (installed=\(isGameInstalled))",
                     category: "fixes")
        installFix(fix: fix)
    }

    func undoPressed(_ fix: LuaToolsFix) {
        AppLog.write("fixes: Undo pressed for \(fix.id) (state=\(state(for: fix)))", category: "fixes")
        undoFix(fix: fix)
    }

    private func installManifest(fix: LuaToolsFix) {
        guard !isInstalling else { return }
        guard let appID = Int(detail.appID) else { return }
        isInstalling = true
        statusText = "Preparing download…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isInstalling = false }
            do {
                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.statusText = "Complete Discord sign-in in your browser…"
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.statusText = "Downloading Lua + manifests…"
                let data = try await LuaToolsFixesClient.shared.downloadManifest(fixID: fix.id)
                self.statusText = "Installing Lua + manifests…"
                let result = try LuaToolsManifestInstaller.installManifest(
                    data: data, appID: appID, store: self.store)
                self.onConfigChanged()
                try? await SteamLibraryActivation.refresh(appID: appID)
                self.statusText = result.manifestCount == 0
                    ? "Installed \(result.title) · Lua only"
                    : "Installed \(result.title) · \(result.manifestCount) manifest"
                        + (result.manifestCount == 1 ? "" : "s")
                let manifestText = result.manifestCount == 0
                    ? "The force-locked Lua was installed. This fix did not include separate depot manifests."
                    : "The force-locked Lua and \(result.manifestCount) depot manifest"
                        + (result.manifestCount == 1 ? "" : "s") + " were installed."
                presentAlert(
                    "Added \(result.title)",
                    manifestText + " Open the game's Steam store page and click Install with Steam.",
                    style: .informational)
            } catch {
                self.statusText = error.localizedDescription
                presentAlert("Couldn’t install fix", error.localizedDescription, style: .warning)
            }
        }
    }

    private func installFix(fix: LuaToolsFix) {
        guard let installDir else {
            AppLog.write("fixes: \(fix.id) not attempted, no game folder", category: "fixes")
            presentAlert("Game not installed",
                         SteamFixInstallError.noInstallDir.localizedDescription,
                         style: .warning)
            return
        }
        guard !isInstalling else {
            statusText = "A fix is already being installed. Wait for it to finish."
            return
        }
        guard let appID = Int(detail.appID) else {
            presentAlert("Couldn’t install fix",
                         "LuaTools listed this game as \(detail.appID), which is not an app id.",
                         style: .warning)
            return
        }
        // Ask macOS for write access first: this surfaces its own prompt where one exists and
        // saves the download when it would be refused anyway.
        do {
            try SteamFixInstaller.ensureWritable(installDir: installDir)
        } catch {
            AppLog.write("fixes: \(fix.id) not writable: \(error.localizedDescription)",
                         category: "fixes")
            statusText = error.localizedDescription
            presentFixError("Couldn’t install fix", error)
            return
        }
        AppLog.write("fixes: installing \(fix.id) into \(installDir.path)", category: "fixes")
        isInstalling = true
        statusText = "Preparing fix download…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isInstalling = false }
            do {
                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.statusText = "Complete Discord sign-in in your browser…"
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.statusText = "Downloading fix files…"
                let data = try await LuaToolsFixesClient.shared.downloadFix(fixID: fix.id)
                AppLog.write("fixes: downloaded \(data.count) bytes for \(fix.id)",
                             category: "fixes")
                self.statusText = "Installing fix files into the game folder…"
                let target = installDir
                let fixID = fix.id
                let result = try await Task.detached {
                    try SteamFixInstaller.apply(
                        zipData: data, appID: appID, fixID: fixID, installDir: target)
                }.value
                self.refreshAppliedFixes()
                self.statusText =
                    "Installed fix · \(result.modified) replaced · \(result.added) added"
                AppLog.write("fixes: installed \(fixID): \(result.modified) replaced, "
                             + "\(result.added) added", category: "fixes")
                presentAlert(
                    "Fix installed",
                    "\(result.modified) file\(result.modified == 1 ? "" : "s") replaced and "
                    + "\(result.added) added. Originals are backed up in the game's "
                    + "`.macsteam-fix` folder. Use Undo on the fix to restore them.",
                    style: .informational)
            } catch {
                AppLog.write("fixes: \(fix.id) failed: \(error.localizedDescription)",
                             category: "fixes")
                self.statusText = error.localizedDescription
                self.presentFixError("Couldn’t install fix", error)
            }
        }
    }

    /// Permission problems get macOS-specific guidance; anything else is shown as is.
    private func presentFixError(_ title: String, _ error: Error) {
        if case SteamFixInstallError.permissionDenied(let path) = error {
            presentFileAccessAlert(path: path)
        } else {
            presentAlert(title, error.localizedDescription, style: .warning)
        }
    }

    private func undoFix(fix: LuaToolsFix) {
        guard let installDir, !isInstalling, let applied = appliedFixes[fix.id] else {
            return
        }
        let message: String
        let informative: String
        if case .drifted(let changed, let missing) = applied.health {
            message = "Remove \(fix.title)?"
            let touched = changed.count + missing.count
            informative = "\(touched) of this fix's files changed or are missing, "
                + "probably because the game was updated. macSteam will remove or restore only "
                + "the files that are still exactly what the fix installed and leave the rest "
                + "alone. Afterwards you can install the fix again."
        } else {
            message = "Undo \(fix.title)?"
            informative = "macSteam will restore \(applied.modified) replaced "
                + "file\(applied.modified == 1 ? "" : "s") and remove \(applied.added) added "
                + "file\(applied.added == 1 ? "" : "s") from the game folder."
        }
        guard confirm(message, informative,
                      confirmTitle: applied.isDrifted ? "Remove" : "Undo") else { return }

        isInstalling = true
        statusText = "Restoring original files…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isInstalling = false }
            do {
                let target = installDir
                let fixID = fix.id
                let safely = applied.isDrifted
                let result = try await Task.detached {
                    safely
                        ? try SteamFixInstaller.revertSafely(installDir: target, fixID: fixID)
                        : try SteamFixInstaller.revert(installDir: target, fixID: fixID)
                }.value
                self.refreshAppliedFixes()
                self.statusText =
                    "Undid fix · \(result.restored) restored · \(result.removed) removed"
                let left = result.skipped.isEmpty ? "" : " \(result.skipped.count) changed "
                    + "file\(result.skipped.count == 1 ? " was" : "s were") left as the game has them."
                presentAlert(
                    "Fix removed",
                    "\(result.restored) file\(result.restored == 1 ? "" : "s") restored and "
                    + "\(result.removed) added file\(result.removed == 1 ? "" : "s") removed." + left,
                    style: .informational)
            } catch SteamFixInstallError.modifiedSinceApply(let paths) {
                // Changed between the preflight and now (or the card was stale): offer the safe undo.
                self.statusText = SteamFixInstallError.modifiedSinceApply(paths).localizedDescription
                self.refreshAppliedFixes()
            } catch {
                self.statusText = error.localizedDescription
                self.presentFixError("Couldn’t undo fix", error)
            }
        }
    }

    func undoAllFixes() {
        guard let installDir, !isInstalling, !appliedFixes.isEmpty else { return }
        let fixes = appliedFixes.values.sorted {
            ($0.appliedAt ?? .distantPast) > ($1.appliedAt ?? .distantPast)
        }
        let files = fixes.reduce(0) { $0 + $1.fileCount }
        guard confirm("Undo all installed fixes?",
                      "macSteam will undo \(fixes.count) fix"
                          + (fixes.count == 1 ? "" : "es") + " and restore \(files) file"
                          + (files == 1 ? "" : "s") + ". Files that changed after a fix was installed "
                          + "(for example by a game update) are left as the game has them.",
                      confirmTitle: "Undo All") else { return }

        isInstalling = true
        statusText = "Restoring original files…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isInstalling = false }
            do {
                let target = installDir
                let result = try await Task.detached {
                    try SteamFixInstaller.revertAll(installDir: target)
                }.value
                self.refreshAppliedFixes()
                self.statusText =
                    "Undid \(result.fixes) fix\(result.fixes == 1 ? "" : "es") · "
                    + "\(result.restored) restored · \(result.removed) removed"
                presentAlert(
                    "Fixes removed",
                    "\(result.fixes) fix\(result.fixes == 1 ? "" : "es") undone. "
                    + "\(result.restored) file\(result.restored == 1 ? "" : "s") restored and "
                    + "\(result.removed) added file\(result.removed == 1 ? "" : "s") removed.",
                    style: .informational)
            } catch {
                self.statusText = error.localizedDescription
                self.presentFixError("Couldn’t undo fixes", error)
            }
        }
    }
}

// MARK: - Page

struct FixesPage: View {
    @ObservedObject var model: FixesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow

            GlassSearchField(prompt: "Search fixes by game name or App ID",
                             text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                .disabled(model.isLoading)

            filterRow

            if let empty = model.emptyState {
                emptyView(empty)
                    .transition(.opacity)
            } else {
                list
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.25), value: model.emptyState)
        .onAppear { model.pageAppeared() }
        .sheet(item: $model.detail) { detail in
            FixesDetailSheet(model: detail)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusDot(kind: model.statusTone.fixesStatusKind)
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.2), value: model.statusText)
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            Button("Open lua.tools", systemImage: "safari") { model.openLuaTools() }
                .buttonStyle(.glass)
                .disabled(model.isLoading)
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .buttonStyle(.glass)
                .disabled(model.isLoading)
        }
        .animation(.smooth(duration: 0.2), value: model.isBusy)
    }

    private var filterRow: some View {
        HStack(spacing: 14) {
            Picker("Tag", selection: Binding(get: { model.selectedTag }, set: { model.setTag($0) })) {
                Text("All tags").tag(String?.none)
                ForEach(model.tags, id: \.self) { tag in
                    Text(tag.name).tag(Optional(tag.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isLoading)

            Toggle("My games", isOn: Binding(get: { model.myGamesOnly },
                                             set: { model.setMyGamesOnly($0) }))
                .help("Only show games added to macSteam.")
                .disabled(model.isLoading)
            Toggle("Show native macOS", isOn: Binding(get: { model.showNativeMacGames },
                                                      set: { model.setShowNativeMacGames($0) }))
                .help("LuaTools fixes are Windows-only, so games Steam also ships a native macOS "
                      + "build of are hidden. Tick this to list them anyway.")
                .disabled(model.isLoading)

            Spacer(minLength: 12)

            Text(model.countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: model.countText)
        }
        .toggleStyle(.checkbox)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.games) { game in
                        FixesGameRow(game: game,
                                     isHighlighted: model.highlightedGameID == game.id) {
                            model.showFixes(for: game)
                        }
                        .id(game.id)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            // focus(appID:) asks for a game; this also runs when the page appears after the
            // request was made (the store page switches to Fixes first, then asks).
            .task(id: model.scrollRequest) {
                guard let request = model.scrollRequest else { return }
                await Task.yield()
                withAnimation(.smooth(duration: 0.4)) {
                    proxy.scrollTo(request.gameID, anchor: .center)
                }
                model.didScroll(to: request)
            }
        }
    }

    @ViewBuilder
    private func emptyView(_ state: FixesEmptyState) -> some View {
        switch state {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Loading LuaTools fixes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            GlassEmptyState(symbol: "exclamationmark.triangle", title: "Couldn’t Load Fixes",
                            message: message) {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .buttonStyle(.glass)
                    .disabled(model.isLoading)
            }
        case .noFixes:
            GlassEmptyState(symbol: "cross.case", title: "No Fixes",
                            message: "LuaTools returned no fixes.") {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .buttonStyle(.glass)
                    .disabled(model.isLoading)
            }
        case .noMatch:
            GlassEmptyState(symbol: "magnifyingglass", title: "No Matches",
                            message: "No LuaTools fixes matched this filter.")
        }
    }
}

// MARK: - Catalog row

private struct FixesGameRow: View {
    let game: LuaToolsFixGame
    var isHighlighted = false
    let onView: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            FixesArtwork(header: game.headerImage, width: 128, decodeWidth: 256)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(game.fixCount) fix\(game.fixCount == 1 ? "" : "es") · App \(game.appID)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !game.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(game.tags.prefix(3), id: \.self) { tag in
                            FixesTagChip(name: tag.name)
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            Button("View", action: onView)
                .buttonStyle(.glass)
                .accessibilityLabel("View fixes for \(game.name)")
        }
        .padding(12)
        .glassEffect(isHighlighted ? .regular.tint(Color.accentColor.opacity(0.22)) : .regular,
                     in: .rect(cornerRadius: 24))
        .animation(.smooth(duration: 0.4), value: isHighlighted)
        .hoverLift()
    }
}

private struct FixesTagChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.08), in: .capsule)
    }
}

// MARK: - Artwork

/// Steam header art through macSteam's own image cache (SteamStoreClient keeps it on disk
/// and only fetches from Steam's hosts), drawn like the shared `Artwork` view.
private struct FixesArtwork: View {
    let header: String?
    var width: CGFloat
    var cornerRadius: CGFloat = 14
    /// Pixel width the image is decoded to.
    var decodeWidth: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Artwork(url: nil, width: width, cornerRadius: cornerRadius)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: width * 215 / 460)
                        .clipShape(.rect(cornerRadius: cornerRadius))
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: image != nil)
            .accessibilityHidden(true)
            .task(id: header) { await load() }
    }

    private func load() async {
        guard let header else {
            image = nil
            return
        }
        let key = "\(Int(decodeWidth))|\(header)" as NSString
        if let cached = FixesArtCache.images.object(forKey: key) {
            image = cached
            return
        }
        image = nil
        let data = await SteamStoreClient.shared.imageData(for: header)
        guard !Task.isCancelled, let data,
              let decoded = StoreArtLoader.decode(data, targetWidth: decodeWidth) else { return }
        FixesArtCache.images.setObject(decoded, forKey: key)
        image = decoded
    }
}

/// Decoded header art, so scrolling the list back does not decode it again.
@MainActor
private enum FixesArtCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
}

// MARK: - Per-game sheet

private struct FixesDetailSheet: View {
    @ObservedObject var model: FixesDetailModel
    @Environment(\.dismiss) private var dismiss

    private static let note = "Manifest installs the force-locked Lua and depot manifests into macSteam. "
        + "Install Fix copies the fix's game files into the installed game folder, "
        + "backing up originals under .macsteam-fix. Use Undo to restore those "
        + "originals. Both actions need a lua.tools/Discord account and count toward "
        + "the lua.tools daily download limit."

    private var subtitle: String {
        "App \(model.detail.appID) · \(model.detail.fixes.count) LuaTools fix"
            + (model.detail.fixes.count == 1 ? "" : "es")
    }

    private var tagNames: String {
        Set(model.detail.fixes.flatMap { $0.tags.map(\.name) }).sorted().joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(Self.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 14)

            ScrollView {
                fixList
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .frame(width: 820, height: 640)
        .onAppear { model.reloadFromDisk() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadFromDisk()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            FixesArtwork(header: model.detail.headerImage ?? model.game.headerImage,
                         width: 200, cornerRadius: 16, decodeWidth: 480)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.detail.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !tagNames.isEmpty {
                    Text(tagNames)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if model.isInstalling {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
        }
        .animation(.smooth(duration: 0.2), value: model.isInstalling)
        .animation(.smooth(duration: 0.2), value: model.statusText)
    }

    @ViewBuilder
    private var fixList: some View {
        if model.detail.fixes.isEmpty {
            GlassSection(title: "Fixes") {
                GlassRow(title: "No fixes are listed for this game.")
            }
        } else {
            GlassSection(title: "Fixes") {
                ForEach(Array(model.detail.fixes.enumerated()), id: \.offset) { index, fix in
                    if index > 0 { RowDivider() }
                    FixesFixRow(fix: fix,
                                state: model.state(for: fix),
                                isGameInstalled: model.isGameInstalled,
                                isBusy: model.isInstalling,
                                onManifest: { model.manifestPressed(fix) },
                                onInstall: { model.installPressed(fix) },
                                onUndo: { model.undoPressed(fix) })
                }
            }
        }
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !model.appliedFixes.isEmpty {
                    Button("Undo All Fixes…", role: .destructive) { model.undoAllFixes() }
                        .disabled(model.isInstalling)
                        .transition(.opacity)
                }
                Spacer()
                Button("Copy App ID", systemImage: "doc.on.doc") { model.copyAppID() }
                Button("Open on lua.tools", systemImage: "safari") { model.openWebPage() }
                Button("Close") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .animation(.smooth(duration: 0.25), value: model.appliedFixes.isEmpty)
    }
}

private struct FixesFixRow: View {
    let fix: LuaToolsFix
    let state: FixesCardState
    let isGameInstalled: Bool
    let isBusy: Bool
    let onManifest: () -> Void
    let onInstall: () -> Void
    let onUndo: () -> Void

    private var meta: String {
        var parts = [fix.availability]
        if !fix.dateLabel.isEmpty { parts.append(fix.dateLabel) }
        if !fix.tags.isEmpty { parts.append(fix.tags.map(\.name).joined(separator: " · ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fix.title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(meta)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let description = fix.description, !description.isEmpty {
                Text(Self.plainDescription(description))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if state == .drifted {
                warning("Some of this fix's files changed since it was installed (a game update?). "
                        + "Reinstall it, or remove what is left.")
            }
            // Why Install is unavailable, rather than only in its tooltip.
            if fix.hasFix, !isGameInstalled {
                warning("This fix copies files into the game folder, so the game has to be installed "
                        + "in Steam first. Install it, then reopen this fix.")
            }
            if fix.hasManifest || fix.hasFix {
                actions.padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .animation(.smooth(duration: 0.25), value: state)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if fix.hasManifest {
                Button("Manifest", systemImage: "doc.badge.arrow.up", action: onManifest)
                    .help("Download and install this fix's Lua + depot manifests.")
                    .disabled(isBusy)
            }
            if fix.hasFix {
                // Drifted: Reinstall and Remove are both offered; applied: only Undo; otherwise Install.
                if state != .applied {
                    Button(state == .drifted ? "Reinstall" : "Install Fix",
                           systemImage: "square.and.arrow.down", action: onInstall)
                        .help(isGameInstalled
                              ? "Download this fix's game files and copy them into the installed game "
                                  + "folder. Originals are backed up under .macsteam-fix."
                              : "Install this game in Steam first, then reopen this fix.")
                        .disabled(isBusy || !isGameInstalled)
                }
                if state != .notApplied {
                    Button(state == .drifted ? "Remove" : "Undo",
                           systemImage: "arrow.uturn.backward", action: onUndo)
                        .help("Restore the files this fix replaced and remove the files it added.")
                        .disabled(isBusy)
                }
            }
        }
        .buttonStyle(.glass)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func plainDescription(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s
    }
}

// MARK: - Helpers

fileprivate extension StatusTone {
    var fixesStatusKind: StatusKind {
        switch self {
        case .ok: .ok
        case .warn: .warning
        case .bad: .error
        case .neutral: .inactive
        }
    }
}
