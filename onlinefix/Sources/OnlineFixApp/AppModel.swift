import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    // Steam
    @Published var steamPresent = false
    @Published var steamRunning = false
    @Published var steamBuild: String?
    @Published var manifestPath: URL?
    @Published var phase: InstallPhase = .notInstalled
    @Published var profile = ProfileStatus(detectedBuild: nil, bundledProfiles: [], runtimeProfile: false, note: "")

    // Games
    @Published var games: [ManagedGame] = []
    @Published var fixes: [FixRecord] = []
    @Published var library: [LibraryApp] = []

    // UI
    @Published var busy = false
    @Published var status = ""
    @Published var logText = ""

    // Add game sheet
    @Published var showAddGame = false
    @Published var newAppID = ""
    @Published var newName = ""
    @Published var searchQuery = ""
    @Published var searchResults: [StoreGame] = []
    @Published var searching = false
    @Published var searchMessage: String?

    /// Which sidebar page is showing.
    @Published var section: SidebarItem? = SidebarItem.initial
    /// The game whose patch sheet is open (nil = no sheet).
    @Published var patchTarget: PatchTarget?
    /// Remembers the last game added; the Fix screen preselects it.
    @Published var lastAddedID: Int?

    // Fix import
    @Published var archiveURL: URL?
    @Published var archivePassword = ""
    @Published var fixGameID: Int?
    @Published var fixMessage = ""
    /// Similar uploads folders offered when the game's own name has no folder.
    @Published var folderChoices: [FixSource.FolderMatch] = []
    @Published var pendingFolderGameID: Int?
    @Published var showFolderChoice = false

    init() {
        let file = Store.load()
        games = file.games
        fixes = file.fixes
        lastAddedID = file.lastAddedID
        fixGameID = file.lastAddedID ?? file.games.first?.id
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        // Another process (the store-page bridge) may have added a game or an
        // installed fix; pick that up without restarting.
        let file = Store.load()
        if file.games != games { games = file.games }
        if file.fixes != fixes { fixes = file.fixes }
        if file.lastAddedID != lastAddedID { lastAddedID = file.lastAddedID }
        steamPresent = Steam.steamAppExists()
        steamRunning = Steam.isRunning()
        let detected = Steam.detectBuild()
        steamBuild = detected.build
        manifestPath = detected.manifest
        phase = Steam.installPhase()
        profile = Steam.profileStatus()
        library = Store.scanLibrary()
        if fixGameID == nil { fixGameID = games.first?.id }
        refreshLog()
    }

    func refreshLog() {
        logText = (try? String(contentsOf: Paths.logFile, encoding: .utf8)) ?? "No log yet."
    }

    // MARK: - Install

    func install() {
        run { try Steam.install(progress: { self.status = $0 }) }
        status = "OnlineFix is installed. Launch Steam normally; games start from Steam."
    }

    func uninstall() {
        run { try Steam.uninstall(progress: { self.status = $0 }) }
        status = "OnlineFix was removed and Steam was restored."
    }

    func deployProfiles() {
        run { _ = try Steam.deployProfiles() }
        profile = Steam.profileStatus()
        status = "Profiles deployed to \(Paths.runtimeDir.path)"
    }

    private func run(_ work: () throws -> Void) {
        busy = true
        status = ""
        do {
            try work()
        } catch {
            status = error.localizedDescription
        }
        busy = false
        refresh()
    }

    // MARK: - Games

    /// Games and fixes removed in this session. The store-page bridge helper runs
    /// its own AppModel against the same games.json, so a removal has to survive the
    /// helper writing back its older copy of the file.
    private var removedGames: Set<Int> = []
    private var removedFixes: Set<Int> = []

    func persist() {
        // Merge with what is on disk: another process may have added a game or an
        // installed fix since this one last read it.
        var file = Store.load()
        let ourGames = Set(games.map(\.id))
        let ourFixes = Set(fixes.map(\.id))
        file.games = games + file.games.filter {
            !ourGames.contains($0.id) && !removedGames.contains($0.id)
        }
        file.fixes = fixes + file.fixes.filter {
            !ourFixes.contains($0.id) && !removedFixes.contains($0.id)
        }
        file.lastAddedID = lastAddedID
        games = file.games
        fixes = file.fixes
        removedGames = removedGames.subtracting(ourGames)
        removedFixes = removedFixes.subtracting(ourFixes)
        do {
            try Store.save(file)
            OnlineFixRouting.emit(routingEntries)
        } catch {
            status = "Could not save games.json: \(error.localizedDescription)"
        }
    }

    /// A game is only fixed when the fix's files are still in its folder. Steam
    /// re-downloads, verifies and repairs games by putting the game's own files
    /// back, which removes the fix while the record of it stays behind.
    func fixIsInstalled(_ appID: Int) -> Bool {
        guard let fix = fixes.first(where: { $0.id == appID }) else { return false }
        return FixInstaller.isInstalled(fix)
    }

    /// Recorded fixes whose files are no longer in the game folder.
    var missingFixFiles: [FixRecord] {
        fixes.filter {
            if case .missing = FixInstaller.state(of: $0) { return true }
            return false
        }
    }

    /// The state of a game's fix, or nil when it has none.
    func fixState(_ appID: Int) -> FixState? {
        fixes.first(where: { $0.id == appID }).map(FixInstaller.state(of:))
    }

    /// The list and toggles macSteam's dylib applies at each game's launch.
    ///
    /// Only a game with an OnlineFix actually installed is routed through AppID
    /// 480. A game that is only listed here, one the player owns or one waiting
    /// for a fix, must start as itself: as Spacewar its Steam identity is wrong,
    /// and online play that relies on it (Photon, Steam lobbies) fails.
    var routingEntries: [RoutingEntry] {
        games.map { game in
            RoutingEntry(appID: game.id, name: game.name,
                         hasFix: fixIsInstalled(game.id),
                         keepRealAppID: game.keepRealAppID,
                         startupAppID: game.patches.startupAppID,
                         overlayAppID: game.patches.overlayAppID,
                         inputAppID: game.patches.inputAppID,
                         statsAppID: game.patches.statsAppID)
        }
    }

    func emitRouting() {
        OnlineFixRouting.emit(routingEntries)
    }

    // MARK: - Adding games

    func alreadyAdded(_ id: Int) -> Bool { games.contains { $0.id == id } }

    @discardableResult
    private func insertGame(id: Int, name: String, imageURL: String? = nil) -> Bool {
        guard id > 0 else {
            status = "That doesn't look like a Steam AppID."
            return false
        }
        guard !alreadyAdded(id) else {
            status = "App \(id) is already in your list."
            return false
        }
        var game = ManagedGame(id: id, name: name, imageURL: imageURL)
        game.patches.startupAppID = true
        game.patches.overlayAppID = true
        game.patches.inputAppID = true
        game.patches.statsAppID = true
        games.append(game)
        lastAddedID = id
        fixGameID = id
        removedGames.remove(id)
        persist()
        status = "Added \(game.name) (App \(id)). Restart Steam so the routing config reloads."
        return true
    }

    /// Adds a game that another pane of the app handed over, without opening a
    /// sheet or reporting it as an add. The caller opens the game's settings.
    func addGameIfNeeded(id: Int, name: String, imageURL: String? = nil) {
        guard id > 0, !alreadyAdded(id) else { return }
        _ = insertGame(id: id, name: name, imageURL: imageURL)
    }

    /// Adds a store search result — its AppID came straight from Steam.
    func add(_ result: StoreGame) {
        if insertGame(id: result.id, name: result.name, imageURL: result.imageURL?.absoluteString) {
            showAddGame = false
            openPatch(result.id)
        }
    }

    func addLibraryGame(_ app: LibraryApp) {
        if insertGame(id: app.id, name: app.name) {
            showAddGame = false
            openPatch(app.id)
        }
    }

    /// Fallback for people who know the AppID; the name is looked up when omitted.
    func addManualGame() {
        guard let id = Int(newAppID.trimmingCharacters(in: .whitespaces)), id > 0 else {
            status = "Enter a numeric Steam AppID."
            return
        }
        let typed = newName.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            if insertGame(id: id, name: typed) { clearManualEntry() }
            return
        }
        if let known = library.first(where: { $0.id == id })?.name {
            if insertGame(id: id, name: known) { clearManualEntry() }
            return
        }
        searching = true
        Task { @MainActor in
            let details = try? await SteamCatalog.details(for: id)
            self.searching = false
            let name = details?.name ?? "App \(id)"
            if self.insertGame(id: id, name: name, imageURL: details?.imageURL?.absoluteString) {
                self.clearManualEntry()
            }
        }
    }

    private func clearManualEntry() {
        let id = fixGameID
        newAppID = ""
        newName = ""
        showAddGame = false
        if let id { openPatch(id) }
    }

    /// Opens the patch sheet for a game, remembering it as the current one.
    func openPatch(_ id: Int) {
        fixGameID = id
        patchTarget = PatchTarget(id: id)
    }

    // MARK: - Store search

    func searchStore() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchMessage = "Type at least two characters."
            return
        }
        searching = true
        searchMessage = nil
        Task { @MainActor in
            do {
                let results = try await SteamCatalog.search(query)
                self.searchResults = results
                self.searchMessage = results.isEmpty ? "No games matched “\(query)”." : nil
            } catch {
                self.searchResults = []
                self.searchMessage = "Search failed: \(error.localizedDescription)"
            }
            self.searching = false
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchMessage = nil
    }

    func removeGame(id: Int) {
        // A game with an installed fix is uninstalled properly, so its files are put
        // back instead of being left in the game folder.
        if fixes.contains(where: { $0.id == id }) {
            _ = uninstallFromStore(appID: id)
            return
        }
        games.removeAll { $0.id == id }
        removedGames.insert(id)
        persist()
    }

    // MARK: - Fixes

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the OnlineFix archive for this game (.zip, .rar, .7z)"
        if panel.runModal() == .OK, let url = panel.url {
            archiveURL = url
        }
    }

    func importFix() {
        guard let archiveURL else {
            fixMessage = "Choose a fix archive first."
            return
        }
        guard let game = games.first(where: { $0.id == fixGameID }) else {
            fixMessage = "Pick a game from your list."
            return
        }
        guard Store.gameFolder(for: game.id, name: game.name) != nil else {
            fixMessage = "Install the game in Steam first — OnlineFix needs its game folder."
            return
        }
        busy = true
        fixMessage = ""
        let password = archivePassword.isEmpty ? nil : archivePassword
        let note: @Sendable (String) -> Void = { [weak self] text in
            self?.showProgress(text)
        }
        Task { @MainActor in
            do {
                let result = try await FixInstaller.install(
                    archive: archiveURL,
                    game: game,
                    password: password,
                    progress: note
                )
                self.recordFix(result, for: game)
                self.showProgress("Installed \(result.files.count) file(s) into \(result.targetDirectory).")
            } catch {
                self.showProgress(error.localizedDescription)
            }
            self.busy = false
            self.refresh()
        }
    }

    /// Fetches the fix package for the selected game from online-fix.me and installs it.
    func fetchFix() {
        guard let game = games.first(where: { $0.id == fixGameID }) else {
            fixMessage = "Pick a game from your list."
            return
        }
        // Check the game folder before downloading anything.
        guard Store.gameFolder(for: game.id, name: game.name) != nil else {
            fixMessage = "Install the game in Steam first — OnlineFix needs its game folder."
            return
        }
        busy = true
        fixMessage = "Contacting online-fix.me…"

        Task { @MainActor in
            let note: @Sendable (String) -> Void = { [weak self] text in
                self?.showProgress(text)
            }
            let matches = await FixSource.findFolders(for: game.name, progress: note)
            guard let best = matches.first else {
                fixMessage = "No OnlineFix upload folder for “\(game.name)” on online-fix.me. "
                    + "Not every game has one (single-player games often do not). "
                    + "Download the fix from online-fix.me and install it with “Choose archive…”."
                busy = false
                return
            }
            // Ask unless the folder is the same name spelled differently: another
            // title, edition or sequel means installing somebody else's files.
            if best.isExact {
                await applyFix(game: game, folder: best, note: note)
            } else {
                folderChoices = matches
                pendingFolderGameID = game.id
                showFolderChoice = true
                fixMessage = matches.count == 1
                    ? "Found “\(best.name)” on online-fix.me — is that this game?"
                    : "Several games on online-fix.me look like “\(game.name)”. "
                        + "Pick the right one."
                busy = false
            }
        }
    }

    /// The user picked one of the similar uploads folders offered after a fetch.
    func chooseFolder(_ match: FixSource.FolderMatch) {
        showFolderChoice = false
        guard let id = pendingFolderGameID,
              let game = games.first(where: { $0.id == id }) else {
            pendingFolderGameID = nil
            folderChoices = []
            return
        }
        pendingFolderGameID = nil
        folderChoices = []
        busy = true

        Task { @MainActor in
            let note: @Sendable (String) -> Void = { [weak self] text in
                self?.showProgress(text)
            }
            await applyFix(game: game, folder: match, note: note)
        }
    }

    func cancelFolderChoice() {
        showFolderChoice = false
        pendingFolderGameID = nil
        folderChoices = []
        fixMessage = "No fix was installed. The game stays in My Games; "
            + "you can try again or use “Choose archive…”."
    }

    /// Downloads the fix from one uploads folder and installs it into the game.
    private func applyFix(game: ManagedGame, folder: FixSource.FolderMatch,
                          note: @escaping @Sendable (String) -> Void) async {
        var downloadDir: URL?
        defer {
            if let downloadDir { try? Paths.fm.removeItem(at: downloadDir) }
        }
        do {
            let archives = try await FixSource.fixArchives(inFolder: folder.url, progress: note)

            let dir = Paths.fm.temporaryDirectory
                .appendingPathComponent("onlinefix-dl-\(UUID().uuidString)", isDirectory: true)
            try Paths.ensureDir(dir)
            downloadDir = dir

            var downloaded: [URL] = []
            for url in archives {
                let destination = dir.appendingPathComponent(url.lastPathComponent)
                try await FixSource.download(url, to: destination, progress: note)
                downloaded.append(destination)
            }

            // Multi-part archives: 7-Zip resolves the rest from part1.
            let entry = downloaded.first {
                $0.lastPathComponent.lowercased().contains("part1")
            } ?? downloaded.first

            guard let entry else {
                throw ManagerError("The server returned no archives for \(game.name).")
            }

            let result = try await FixInstaller.install(
                archive: entry,
                game: game,
                password: FixSource.defaultPassword,
                progress: note
            )

            recordFix(result, for: game)
            let matched = folder.isExact ? "" : " (matched “\(folder.name)” on online-fix.me)"
            fixMessage = "Fetched from online-fix.me and installed \(result.files.count) file(s) "
                + "into \(result.targetDirectory)\(matched)."
        } catch {
            fixMessage = "Auto-fetch failed: \(error.localizedDescription)\n"
                + "\(game.name) stays in My Games and is still routed as AppID 480. "
                + "You can install a fix later with “Choose archive…”."
        }
        busy = false
    }

    func recordFix(_ result: FixInstaller.ImportResult, for game: ManagedGame) {
        fixes.removeAll { $0.id == game.id }
        fixes.append(FixRecord(id: game.id, gameName: game.name, files: result.files))
        removedFixes.remove(game.id)
        persist()
    }

    func openFixSite() {
        Steam.open(FixSource.siteURL)
    }

    func removeFix(id: Int) {
        uninstallFix(appID: id)
    }

    /// Progress callbacks arrive from FixSource's async tasks; hop to the main
    /// actor before touching published state.
    nonisolated func showProgress(_ text: String) {
        Task { @MainActor [weak self] in self?.fixMessage = text }
    }

    // MARK: - Steam store page

    func storeStatus(appID: Int) -> OnlineFixStoreStatus {
        let name = games.first { $0.id == appID }?.name ?? ""
        let folder = Store.gameFolder(for: appID, name: name)
        return OnlineFixStoreStatus(
            inList: alreadyAdded(appID),
            fixInstalled: fixIsInstalled(appID),
            gameInstalled: folder != nil,
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            keepRealAppID: games.first { $0.id == appID }?.keepRealAppID ?? false)
    }

    /// "Keep real AppID" from the Steam store page: a game whose online play runs
    /// on Steam's relay network has to start as itself, since the relay only
    /// exists for the game's own AppID.
    @discardableResult
    func storeSetKeepRealAppID(_ keep: Bool, appID: Int) -> Bool {
        guard let index = games.firstIndex(where: { $0.id == appID }) else { return false }
        games[index].keepRealAppID = keep
        persist()
        return true
    }

    /// Adds the game to My Games, finds its fix on online-fix.me, downloads and
    /// installs it. Used by the "Use OnlineFix" button on Steam's store pages.
    func installFromStore(appID: Int, name: String, imageURL: String? = nil,
                          folderName: String? = nil,
                          progress: @escaping @Sendable (String) -> Void = { _ in })
        async -> OnlineFixStoreOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "App \(appID)" : trimmed
        addGameIfNeeded(id: appID, name: display, imageURL: imageURL)
        guard let game = games.first(where: { $0.id == appID }) else {
            return OnlineFixStoreOutcome(message: nil,
                                         error: "The game could not be added to My Games.",
                                         needsGame: false, installed: false)
        }
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            return OnlineFixStoreOutcome(message: nil,
                                         error: "Install the game in Steam first, OnlineFix needs its game folder.",
                                         needsGame: true, installed: false)
        }
        if let bundle = FixInstaller.nativeMacBundle(in: folder) {
            return OnlineFixStoreOutcome(
                message: nil,
                error: "Steam installed the native macOS build of \(display) "
                    + "(\(bundle.lastPathComponent)), and OnlineFix only patches Windows game files, "
                    + "so there is nothing here for it to change. In Steam, open the game's Properties, "
                    + "Compatibility, force the Windows version, and try again.",
                needsGame: false, installed: false)
        }

        var downloadDir: URL?
        defer {
            if let downloadDir { try? Paths.fm.removeItem(at: downloadDir) }
        }
        do {
            let folder: FixSource.FolderMatch
            if let folderName = folderName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !folderName.isEmpty {
                // The player picked one of the similar folders on the store page.
                folder = FixSource.FolderMatch(name: folderName,
                                               url: FixSource.folderURL(named: folderName),
                                               score: 1, isExact: true)
                progress("Using “\(folderName)” on online-fix.me…")
            } else {
                progress("Looking for \(display) on online-fix.me…")
                let matches = await FixSource.findFolders(for: display) { progress($0) }
                guard let best = matches.first else {
                    throw ManagerError("No OnlineFix upload folder for “\(display)” on online-fix.me. "
                        + "Not every game has one (single-player games often do not).")
                }
                // A similar name is a guess, and a wrong guess installs another
                // game's files, so the store page asks which one it is.
                if !best.isExact {
                    return OnlineFixStoreOutcome(
                        message: "Several games on online-fix.me look like “\(display)”. "
                            + "Pick the right one below and it installs that fix.",
                        error: nil, needsGame: false, installed: false,
                        choices: matches.map {
                            OnlineFixStoreChoice(name: $0.name, percent: $0.percent)
                        })
                }
                folder = best
            }
            let archives = try await FixSource.fixArchives(inFolder: folder.url) { progress($0) }

            let dir = Paths.fm.temporaryDirectory
                .appendingPathComponent("onlinefix-store-\(UUID().uuidString)", isDirectory: true)
            try Paths.ensureDir(dir)
            downloadDir = dir

            var downloaded: [URL] = []
            for url in archives {
                let destination = dir.appendingPathComponent(url.lastPathComponent)
                try await FixSource.download(url, to: destination) { progress($0) }
                downloaded.append(destination)
            }

            let entry = downloaded.first {
                $0.lastPathComponent.lowercased().contains("part1")
            } ?? downloaded.first
            guard let entry else {
                throw ManagerError("The server returned no fix archives for \(display).")
            }

            progress("Installing \(entry.lastPathComponent)…")
            let result = try await FixInstaller.install(archive: entry, game: game,
                                                       password: FixSource.defaultPassword) { progress($0) }
            recordFix(result, for: game)
            return OnlineFixStoreOutcome(
                message: "OnlineFix installed: \(result.files.count) file(s) written into the game folder. "
                    + "Launch \(display) from Steam — it runs as AppID 480.",
                error: nil, needsGame: false, installed: true)
        } catch {
            // A game with no OnlineFix stays in My Games and is still routed as
            // AppID 480; only its fix files are missing, which can be installed
            // later from the patch sheet.
            addGameIfNeeded(id: appID, name: display, imageURL: imageURL)
            return OnlineFixStoreOutcome(
                message: "\(display) is in My Games and will start as AppID 480. "
                    + "No OnlineFix fix was installed: \(error.localizedDescription)",
                error: nil, needsGame: false, installed: false)
        }
    }

    /// Uninstall: put the game's files back, and take the game out of My Games, so it
    /// stops being routed as AppID 480 (Spacewar) and Steam starts it normally again.
    /// Used by the manager's patch sheet, the store card and the game's Properties window.
    func uninstallFromStore(appID: Int) -> OnlineFixStoreOutcome {
        let name = games.first { $0.id == appID }?.name ?? "App \(appID)"
        let record = fixes.first { $0.id == appID }
        var restored = 0
        if let record {
            do {
                restored = try FixInstaller.uninstall(record)
            } catch {
                return OnlineFixStoreOutcome(message: nil,
                                             error: error.localizedDescription,
                                             needsGame: false, installed: true)
            }
        }
        fixes.removeAll { $0.id == appID }
        removedFixes.insert(appID)
        let listed = games.contains { $0.id == appID }
        games.removeAll { $0.id == appID }
        removedGames.insert(appID)
        persist()

        var message = record != nil
            ? "OnlineFix removed: \(restored) file(s) restored or deleted."
            : "No OnlineFix files were recorded for \(name)."
        message += listed
            ? " \(name) is out of My Games, so it no longer starts as AppID 480."
            : " It was not in My Games."
        return OnlineFixStoreOutcome(message: message, error: nil,
                                     needsGame: false, installed: false)
    }

    /// Patch-sheet action: uninstall and show the result in the sheet's status line.
    func uninstallFix(appID: Int) {
        let outcome = uninstallFromStore(appID: appID)
        fixMessage = outcome.message ?? outcome.error ?? ""
    }

    // MARK: - Misc

    func openSteam() {
        Steam.open(Paths.steamApp)
    }

    func openSupportFolder() {
        try? Paths.ensureDir(Paths.appSupport)
        Steam.open(Paths.appSupport)
    }

    func openLog() {
        if Paths.fm.fileExists(atPath: Paths.logFile.path) {
            Steam.open(Paths.logFile)
        }
    }
}
