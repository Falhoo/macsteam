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
    /// Set when a fix may not work and the player has to confirm before it starts.
    @Published var fixCompatibilityPrompt: FixCompatibilityPrompt?

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
        prepareWineForInstalledFixes()
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

    /// The OnlineFix Photon chain for a game: complete, or the piece that never
    /// loads. A game with no fix, or one whose online play is not Photon, has
    /// nothing to report.
    func photonStatus(_ appID: Int) -> PhotonFix.Status {
        let name = games.first { $0.id == appID }?.name ?? ""
        return PhotonFix.status(gameFolder: Store.gameFolder(for: appID, name: name),
                                fixInstalled: fixIsInstalled(appID), appID: appID,
                                fixFiles: fixes.first { $0.id == appID }?.files ?? [])
    }

    /// The native Mac build a game folder holds right now, if any.
    func macAppStatus(_ appID: Int) -> MacAppFix.Status? {
        let name = games.first { $0.id == appID }?.name ?? ""
        return MacAppFix.status(gameFolder: Store.gameFolder(for: appID, name: name))
    }

    /// Anything wrong with a game's installed fix, in words: a fix that cannot run
    /// here at all, a Photon chain that is missing a piece, or a fix whose game has
    /// since become the native Mac build that loads none of it.
    func fixIssue(_ appID: Int) -> String? {
        if let fix = fixes.first(where: { $0.id == appID }),
           let issue = FixInstaller.gdkIssue(for: fix) {
            return issue
        }
        if fixes.contains(where: { $0.id == appID }), let mac = macAppStatus(appID) {
            return mac.message
        }
        return photonStatus(appID).message
    }

    /// The list and toggles macSteam's dylib applies at each game's launch.
    ///
    /// A game whose recorded fix is no longer on disk is left out: Steam put the
    /// game's own files back (a verify, an update, a repair), so launching it as
    /// Spacewar would land it in Spacewar's identity without the fix that goes with
    /// it, which is how a game that "worked yesterday" stops starting. Until the
    /// fix is reinstalled it starts as itself, which at least works.
    var routingEntries: [RoutingEntry] {
        games.compactMap { game in
            if fixes.contains(where: { $0.id == game.id }), !fixIsInstalled(game.id) {
                return nil
            }
            return RoutingEntry(appID: game.id, name: game.name,
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
        status = "Added \(game.name) (App \(id)). Install its OnlineFix to launch it as AppID 480."
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

    // MARK: - Fix compatibility

    /// What the game's own files say about an OnlineFix before it is installed.
    func compatibilityCheck(appID: Int, name: String) -> FixCompatibilityCheck {
        let resolved = name.isEmpty
            ? (games.first { $0.id == appID }?.name ?? "")
            : name
        return FixCompatibility.check(appID: appID, name: resolved,
                                      folder: Store.gameFolder(for: appID, name: resolved))
    }

    /// Runs the check and, when the fix may not work, asks first. Returns true when
    /// the caller may go ahead now.
    private func allowFixInstall(appID: Int, name: String,
                                 proceed: @escaping @MainActor () -> Void) -> Bool {
        let check = compatibilityCheck(appID: appID, name: name)
        guard check.needsConfirmation else { return true }
        fixCompatibilityPrompt = FixCompatibilityPrompt(
            title: check.title, reason: check.reason) {
            proceed()
        }
        return false
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
        guard archiveURL != nil else {
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
        guard allowFixInstall(appID: game.id, name: game.name,
                              proceed: { [weak self] in self?.performArchiveImport() }) else {
            fixMessage = ""
            return
        }
        performArchiveImport()
    }

    /// Installs the picked archive, which the compatibility check has cleared.
    private func performArchiveImport() {
        guard let archiveURL else { return }
        guard let game = games.first(where: { $0.id == fixGameID }) else { return }
        guard Store.gameFolder(for: game.id, name: game.name) != nil else { return }
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
        guard allowFixInstall(appID: game.id, name: game.name,
                              proceed: { [weak self] in self?.startFetchFix() }) else {
            fixMessage = ""
            return
        }
        startFetchFix()
    }

    /// Contacts online-fix.me and installs, which the compatibility check has cleared.
    private func startFetchFix() {
        guard let game = games.first(where: { $0.id == fixGameID }) else { return }
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
                + "\(game.name) stays in My Games and starts as itself until its fix "
                + "is installed. You can install one later with “Choose archive…”."
        }
        busy = false
    }

    func recordFix(_ result: FixInstaller.ImportResult, for game: ManagedGame) {
        fixes.removeAll { $0.id == game.id }
        fixes.append(FixRecord(id: game.id, gameName: game.name, files: result.files,
                               sizes: FixInstaller.sizes(of: result.files)))
        removedFixes.remove(game.id)
        prepareWine(for: game)
        // Photon games whose fix stops at the Steam API DLL get OnlineFix's Photon
        // patch here, so the chain is part of the fix's own record.
        if let folder = Store.gameFolder(for: game.id, name: game.name) {
            // Stored Photon app IDs are applied with the fix, so the player never has
            // to press Apply.
            if !game.repoPhoton.realtime.isEmpty || !game.repoPhoton.voice.isEmpty {
                _ = try? PhotonIDs.apply(gameFolder: folder,
                                         realtime: game.repoPhoton.realtime,
                                         voice: game.repoPhoton.voice)
            }
            let added = PhotonSupport.install(appID: game.id, gameFolder: folder,
                                              fixFiles: result.files)
            let existing = Set(fixes.first(where: { $0.id == game.id })?.files ?? [])
            let fresh = added.filter { !existing.contains($0) }
            if !fresh.isEmpty, let index = fixes.firstIndex(where: { $0.id == game.id }) {
                fixes[index].files.append(contentsOf: fresh)
                fixes[index].sizes.merge(FixInstaller.sizes(of: fresh)) { first, _ in first }
            }
        }
        // Every fix gets the same repair, whatever shape its archive had.
        _ = applyUniversalFix(appID: game.id, name: game.name)
        persist()
    }

    /// Repairs the things that stop an installed fix from loading: the payload
    /// beside the executable, the Steam API DLL the game actually loads, and an
    /// ini that names this game. New copies join the fix's record, so uninstall
    /// takes them away again. Safe to call on every refresh.
    @discardableResult
    func applyUniversalFix(appID: Int, name: String) -> UniversalFix.Report? {
        guard let index = fixes.firstIndex(where: { $0.id == appID }),
              let folder = Store.gameFolder(for: appID, name: name) else { return nil }
        let report = UniversalFix.apply(appID: appID, gameFolder: folder,
                                        fixFiles: fixes[index].files)
        let known = Set(fixes[index].files)
        let fresh = report.additions.filter { !known.contains($0) }
        if !fresh.isEmpty {
            fixes[index].files.append(contentsOf: fresh)
            fixes[index].sizes.merge(FixInstaller.sizes(of: fresh)) { first, _ in first }
        }
        return report
    }

    /// Makes the game's Wine prefix run the fix that was just installed.
    ///
    /// Two things hold a fix back on macOS, and they are not Photon-specific:
    /// Wine prefers its own built-in copy of a proxy DLL over the one the fix put
    /// beside the game, and OnlineFix's `dlllist.txt` starts with the Steam overlay,
    /// whose loader cannot find its renderer in a managed prefix and stops the rest
    /// of the list with error 126. Every fix needs both handled, so every fix gets it.
    private func prepareWine(for game: ManagedGame, fix: FixRecord? = nil) {
        guard let record = fix ?? fixes.first(where: { $0.id == game.id }) else { return }
        let folder = Store.gameFolder(for: game.id, name: game.name)

        // The overlay is the in-game Steam UI. Its failure is not cosmetic: it
        // aborts the loader before the fix's own files are touched. Look at the
        // game folder too, since a fix installed by an older build may have a list
        // the record does not name.
        var lists = Set(record.files.filter {
            ($0 as NSString).lastPathComponent == "dlllist.txt"
        })
        if let folder {
            lists.insert(folder.appendingPathComponent("dlllist.txt").path)
        }
        for file in lists {
            FixInstaller.removingOverlayFromDLLList(at: file)
        }
        // An imported overlay stub (steam_api64.dll -> SteamOverlay64.dll) cannot be
        // taken out of a list, so it is made to do nothing instead.
        for path in record.files where (path as NSString).lastPathComponent == "SteamOverlay64.dll" {
            OverlayStub.disable(at: URL(fileURLWithPath: path))
        }

        // Steam creates the prefix on the game's first launch.
        guard WineOverride.prefix(appID: game.id) != nil else { return }
        // Every DLL the fix brought gets its native copy, and the loader proxies
        // keep a builtin fallback. The emulator's own DLLs are the ones Wine can
        // otherwise answer for: a loader that is handed another copy stops with
        // "Failed to get OnlineFix interface" before the game starts.
        var names = Set<String>()
        for path in record.files where path.lowercased().hasSuffix(".dll") {
            names.insert((path as NSString).lastPathComponent.lowercased())
        }
        if let folder {
            for dll in WineOverride.fixDLLs
            where Paths.fm.fileExists(atPath: folder.appendingPathComponent(dll).path) {
                names.insert(dll)
            }
        }
        for dll in names {
            WineOverride.ensure(appID: game.id, dll: dll, native: WineOverride.needsNative(dll))
        }
    }

    /// Every recorded fix, applied again on refresh: a fix installed before this
    /// existed, or a game whose prefix Steam made after its install, is caught here.
    private func prepareWineForInstalledFixes() {
        var repaired = false
        for fix in fixes {
            guard let folder = Store.gameFolder(for: fix.id, name: fix.gameName) else { continue }
            // First, put the fix's own files where the loader looks, so the rest of
            // this pass (and the game) sees a complete fix.
            if applyUniversalFix(appID: fix.id, name: fix.gameName)?.changed == true {
                repaired = true
            }
            FixInstaller.ensureOverlayRenderer(appID: fix.id, gameFolder: folder, fixFiles: fix.files)
            prepareWine(for: ManagedGame(id: fix.id, name: fix.gameName), fix: fix)
            // A Photon game whose fix stops at the Steam API DLL still needs the
            // patch; the app carries it and adds it here.
            PhotonSupport.install(appID: fix.id, gameFolder: folder, fixFiles: fix.files)
            // A Steam verify puts the stock asset back. Reapply the stored Photon app
            // IDs, so custom ones survive without the player pressing anything.
            if let game = games.first(where: { $0.id == fix.id }),
               !game.repoPhoton.realtime.isEmpty || !game.repoPhoton.voice.isEmpty,
               PhotonFix.isPhotonGame(in: folder) {
                _ = try? PhotonIDs.apply(gameFolder: folder,
                                         realtime: game.repoPhoton.realtime,
                                         voice: game.repoPhoton.voice)
            }
        }
        if repaired { persist() }
    }

    func openFixSite() {
        Steam.open(FixSource.siteURL)
    }

    func removeFix(id: Int) {
        uninstallFix(appID: id)
    }

    /// Patch-sheet action: run the same universal repair the app runs after an
    /// install and on every refresh, so a game that crashes with its fix can be put
    /// right without reinstalling anything.
    func repairFix(appID: Int) {
        guard let game = games.first(where: { $0.id == appID }) else { return }
        guard let report = applyUniversalFix(appID: appID, name: game.name) else { return }
        persist()
        fixMessage = report.changed
            ? "Repaired the fix: " + report.notes.joined(separator: " ")
            : "The fix's files are already where the game loads them. Nothing to repair."
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
        let nativeMac = folder.map { FixInstaller.nativeMacBundle(in: $0) != nil } ?? false
        return OnlineFixStoreStatus(
            inList: alreadyAdded(appID),
            fixInstalled: fixIsInstalled(appID),
            gameInstalled: folder != nil,
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            keepRealAppID: games.first { $0.id == appID }?.keepRealAppID ?? false,
            photonIssue: fixIssue(appID),
            gdkRestricted: FixCompatibility.isGDK(folder: folder),
            nativeMacBuild: nativeMac,
            compatTool: Steam.notProtonTool(),
            windowsBuildInstalled: folder.map { FixInstaller.hasWindowsBuild(in: $0) } ?? false,
            overlayStub: fixes.first { $0.id == appID }?.files.contains {
                ($0 as NSString).lastPathComponent == "SteamOverlay64.dll"
            } ?? false)
    }

    /// "still route my game through spacewar", from the store page: puts the game in
    /// My Games if it is not there and sets the identity Steam starts it with. It
    /// writes no game files, which is all a native build can use.
    @discardableResult
    func storeRouteAsSpacewar(_ on: Bool, appID: Int, name: String) -> OnlineFixStoreStatus {
        addGameIfNeeded(id: appID, name: name)
        if let index = games.firstIndex(where: { $0.id == appID }) {
            games[index].keepRealAppID = !on
            persist()
        }
        return storeStatus(appID: appID)
    }

    /// R.E.P.O.'s Photon app IDs, written into the game files the way the original
    /// OnlineFix Manager does, with the untouched file kept as a backup.
    func applyRepoPhotonIDs(_ game: ManagedGame) {
        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            fixMessage = "Install R.E.P.O. in Steam first."
            return
        }
        do {
            let changed = try PhotonIDs.apply(gameFolder: folder,
                                              realtime: game.repoPhoton.realtime,
                                              voice: game.repoPhoton.voice)
            persist()
            fixMessage = changed.isEmpty
                ? "Those are the IDs the game already carries."
                : "Patched the game files with the new Photon app IDs."
        } catch {
            fixMessage = error.localizedDescription
        }
    }

    /// Puts R.E.P.O.'s Photon app IDs back to OnlineFix's defaults.
    func clearRepoPhotonIDs(_ game: ManagedGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].repoPhoton = RepoPhoton()
        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            persist()
            return
        }
        do {
            _ = try PhotonIDs.apply(gameFolder: folder, realtime: "", voice: "")
            fixMessage = "R.E.P.O.'s Photon app IDs are back to the defaults."
        } catch {
            fixMessage = error.localizedDescription
        }
        persist()
    }

    /// "Use real AppID" from the Steam store page: a game whose online play runs on
    /// Steam's relay network has to start as itself, since the relay only exists
    /// for the game's own AppID. A game that is not in My Games yet is put there
    /// first, so the choice works from a store page nobody has installed from.
    @discardableResult
    func storeSetKeepRealAppID(_ keep: Bool, appID: Int, name: String = "") -> Bool {
        guard appID > 0, appID != 480 else { return false }
        if !games.contains(where: { $0.id == appID }) {
            addGameIfNeeded(id: appID, name: name.isEmpty ? "App \(appID)" : name)
        }
        guard let index = games.firstIndex(where: { $0.id == appID }) else { return false }
        games[index].keepRealAppID = keep
        persist()
        return true
    }

    /// Adds the game to My Games, finds its fix on online-fix.me, downloads and
    /// installs it. Used by the "Use OnlineFix" button on Steam's store pages.
    func installFromStore(appID: Int, name: String, imageURL: String? = nil,
                          folderName: String? = nil, confirmed: Bool = false,
                          progress: @escaping @Sendable (String) -> Void = { _ in })
        async -> OnlineFixStoreOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "App \(appID)" : trimmed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            return OnlineFixStoreOutcome(message: nil,
                                         error: "Install the game in Steam first, OnlineFix needs its game folder.",
                                         needsGame: true, installed: false)
        }
        // OnlineFix is Windows PE files that hook Windows Steam's API. A native build
        // runs as a Mach-O process and loads `libsteam_api.dylib`, so its files can
        // never load there. The way in is to switch the game to NotProton and let
        // Steam download the Windows build, which is what the store page does with
        // this reply; "just give me the files" asks for the copy instead.
        let nativeBuild = FixInstaller.nativeMacBundle(in: folder)
        if let bundle = nativeBuild, !confirmed {
            // Nothing is installed yet: the page switches Steam to NotProton first, so
            // the Windows build is what gets downloaded, and the fix has a folder it
            // can work in.
            addGameIfNeeded(id: appID, name: display, imageURL: imageURL)
            return OnlineFixStoreOutcome(
                message: "\(display) is the native macOS build (\(bundle.lastPathComponent)). "
                    + "Switching it to NotProton makes Steam download the Windows build; the "
                    + "fix installs there and can work. No OnlineFix file was written yet.",
                error: nil, needsGame: false, installed: false,
                windowsBuild: true, compatTool: Steam.notProtonTool())
        }
        // A fix can install and still never connect. Ask before downloading it when
        // the game's own files say it may not work.
        let compatibility = FixCompatibility.check(appID: appID, name: display, folder: folder)
        if compatibility.needsConfirmation, !confirmed {
            return OnlineFixStoreOutcome(
                message: nil, error: nil, needsGame: false, installed: false,
                confirmation: compatibility.title + ". " + compatibility.reason)
        }
        addGameIfNeeded(id: appID, name: display, imageURL: imageURL)
        guard let game = games.first(where: { $0.id == appID }) else {
            return OnlineFixStoreOutcome(message: nil,
                                         error: "The game could not be added to My Games.",
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
            let result = try await FixInstaller.install(
                archive: entry, game: game, password: FixSource.defaultPassword,
                allowGDK: confirmed, allowNative: confirmed && nativeBuild != nil) { progress($0) }
            recordFix(result, for: game)
            let photon = PhotonFix.status(
                gameFolder: Store.gameFolder(for: appID, name: display),
                fixInstalled: true,
                fixFiles: result.files)
            let gdk = FixInstaller.gdkIssue(
                for: FixRecord(id: appID, gameName: display, files: result.files))
            var message = "OnlineFix installed: \(result.files.count) file(s) written into "
                + "the game folder. Launch \(display) from Steam. It runs as AppID 480."
            if let repair = applyUniversalFix(appID: appID, name: display) {
                if !repair.notes.isEmpty {
                    message += " " + repair.notes.joined(separator: " ")
                }
                persist()
            }
            if let gdk {
                message += " " + gdk
            } else if let issue = photon.message {
                message += " " + issue
            } else if photon.isComplete {
                message += " Its Photon patch (BepInEx doorstop, preloader and Custom.dll) "
                    + "is in place too."
            }
            return OnlineFixStoreOutcome(message: message, error: nil,
                                         needsGame: false, installed: true)
        } catch {
            // A game with no OnlineFix stays in My Games and starts as itself; only
            // its fix files are missing, which can be installed later from the patch
            // sheet or the store page.
            addGameIfNeeded(id: appID, name: display, imageURL: imageURL)
            return OnlineFixStoreOutcome(
                message: "\(display) is in My Games. It starts as itself until an "
                    + "OnlineFix fix is installed: \(error.localizedDescription)",
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

/// Asked before a fix that may not work is downloaded and installed.
struct FixCompatibilityPrompt: Identifiable {
    let id = UUID()
    let title: String
    let reason: String
    let proceed: @MainActor () -> Void
}
