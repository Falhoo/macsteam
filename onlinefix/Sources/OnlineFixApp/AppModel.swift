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
    /// Whether a foreground install starts the game once afterwards.
    @Published var testAfterInstall: Bool
    /// True while the install test is the part that is running, so the UI can offer
    /// Cancel without offering it for a download or an unpack.
    @Published var launchTestRunning = false
    private var launchTestControl: LaunchTest.Control?

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

    // Photon app ids, read out of a game's own files
    /// What the scanner found in each game's files, by AppID.
    @Published var photonScans: [Int: [PhotonPatch.Candidate]] = [:]
    /// Games whose files are being read right now.
    @Published var photonScanning: Set<Int> = []
    /// The folder each scan read, so the same one is not read twice.
    private var photonScanFolders: [Int: String] = [:]

    init() {
        testAfterInstall = UserDefaults.standard.object(forKey: "onlinefix.testAfterInstall") as? Bool ?? true
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
        guard !OnlineFixAvailability.isBroken else {
            status = OnlineFixAvailability.message
            fixMessage = OnlineFixAvailability.message
            return
        }
        run { try Steam.install(progress: { self.status = $0 }) }
        status = "OnlineFix is installed. Launch Steam normally; games start from Steam."
    }

    /// Takes OnlineFix out and leaves macSteam and NotProton exactly as they are:
    /// the manager's own folder, its section in macSteam's config, its dylib and
    /// environment keys in Steam.app, and the files and Photon patches it put in the
    /// games' folders.
    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Remove OnlineFix?"
        alert.informativeText = "OnlineFix's game list, its routing settings, the files it "
            + "placed in each game folder and the Photon patches it applied are taken out. "
            + "macSteam, NotProton, the runners and the Wine prefixes stay as they are, so "
            + "Steam works just as it does now. Steam quits for the change and starts again."
        alert.addButton(withTitle: "Remove OnlineFix")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        status = "Taking OnlineFix out…"
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                OnlineFixRemoval.run()
            }.value
            guard let self else { return }
            self.busy = false
            self.status = report.summary
            self.refresh()
        }
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
    /// The Mac build patch's state for a game, or nil when it has no Mac build.
    func macBuildPatch(appID: Int) -> MacBundlePatch.State? {
        let name = games.first { $0.id == appID }?.name ?? ""
        return MacBundlePatch.state(in: Store.gameFolder(for: appID, name: name))
    }

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
        // A Mac build the patch can reach is fixed where it stands, so the Windows
        // files the fix left behind are not a problem there.
        if fixes.contains(where: { $0.id == appID }), let mac = macAppStatus(appID),
           macBuildPatch(appID: appID) == nil {
            return mac.message
        }
        if let photon = photonStatus(appID).message { return photon }
        return photonConnectionIssue(appID)
    }

    /// The route this game's Photon files and log point at: its own Steam-auth app,
    /// OnlineFix's shared app, or neither. Read-only; the scan is only run when a
    /// caller already asked for it, so opening a game does not read every asset.
    func photonProfile(_ appID: Int) -> PhotonProfile.Profile? {
        guard let game = games.first(where: { $0.id == appID }),
              let folder = Store.gameFolder(for: appID, name: game.name) else { return nil }
        let status = photonStatus(appID)
        let candidates = photonScans[appID] ?? []
        let log = PhotonLog.read(gameFolder: folder,
                                 prefix: WineOverride.prefix(appID: appID))
        let isPhoton = status.isPhoton || !candidates.isEmpty
            || PhotonFix.isPhotonGame(in: folder)
        return PhotonProfile.read(isPhoton: isPhoton, status: status,
                                  candidates: candidates, log: log)
    }

    /// What the game's own log says Photon made of the last connection it tried.
    /// "Failed to connect to Photon Network" is the game's text for every reason
    /// Photon can refuse, so the log is the only thing that says which one it was.
    func photonConnectionIssue(_ appID: Int) -> String? {
        guard let game = games.first(where: { $0.id == appID }),
              let folder = Store.gameFolder(for: appID, name: game.name) else { return nil }
        let evidence = PhotonLog.read(gameFolder: folder,
                                      prefix: WineOverride.prefix(appID: appID))
        if let profile = photonProfile(appID), profile.needsAttention {
            return "\(profile.title). \(profile.detail) \(profile.remedy)"
        }
        guard let evidence, evidence.isFailure else { return nil }
        return "\(evidence.title). \(evidence.detail) \(evidence.remedy)"
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
            // A Mac build loads none of the fix's files, so Spacewar (480) adds nothing
            // it can use, and PICO PARK 2's Mac build closes itself a second after
            // starting when Steam calls it Spacewar. Such a game starts as itself: what
            // it needs is the patch in its own files, not a different AppID.
            let macBuild = Store.gameFolder(for: game.id, name: game.name)
                .map { FixInstaller.nativeMacBundle(in: $0) != nil } ?? false
            return RoutingEntry(appID: game.id, name: game.name,
                                hasFix: fixIsInstalled(game.id),
                                keepRealAppID: game.keepRealAppID || macBuild,
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
        guard !OnlineFixAvailability.isBroken else {
            fixMessage = OnlineFixAvailability.message
            return
        }
        guard archiveURL != nil else {
            fixMessage = "Choose a fix archive first."
            return
        }
        guard let game = games.first(where: { $0.id == fixGameID }) else {
            fixMessage = "Pick a game from your list."
            return
        }
        guard Store.isInstalled(appID: game.id,
                                folder: Store.gameFolder(for: game.id, name: game.name)) else {
            fixMessage = Store.notInstalledMessage
            return
        }
        guard allowFixInstall(appID: game.id, name: game.name,
                              proceed: { [weak self] in self?.performArchiveImport() }) else {
            fixMessage = ""
            return
        }
        performArchiveImport()
    }

    func setTestAfterInstall(_ value: Bool) {
        testAfterInstall = value
        UserDefaults.standard.set(value, forKey: "onlinefix.testAfterInstall")
    }

    func cancelLaunchTest() {
        launchTestControl?.cancel()
        showProgress("Cancelling the test…")
    }

    /// Tests an installed fix without reinstalling it. The control is kept on the
    /// model so the manager's Cancel button stops this test too.
    func testInstalledFix(appID: Int, name: String,
                          progress: @escaping @Sendable (String) -> Void) async -> String {
        guard !launchTestRunning else { return "A test is already running." }
        guard let folder = Store.gameFolder(for: appID, name: name),
              FixPack.hasPack(in: folder) else {
            return "Install the fix first."
        }
        let control = LaunchTest.Control()
        launchTestControl = control
        launchTestRunning = true
        defer {
            launchTestRunning = false
            if launchTestControl === control { launchTestControl = nil }
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        let result = await LaunchTest.run(appID: appID, name: name, exe: scan.exe,
                                          cancel: { control.isCancelled() },
                                          progress: progress)
        if var recipe = FixPack.read(in: folder) {
            recipe.launchTest = result
            // The same one-button rule as an install: Photon's answer re-patches the
            // game and it is started again, so Test is enough to settle the auth type.
            var learned = FixService.Outcome()
            if FixService.learnPhotonAuth(appID: appID, folder: folder, recipe: &recipe,
                                          outcome: &learned) {
                try? FixPack.writeRecipe(recipe, in: folder)
                guard !control.isCancelled() else { return learned.notes.joined(separator: " ") }
                _ = await LaunchTest.waitUntilStopped(
                    exe: scan.exe,
                    stem: scan.exe?.deletingPathExtension().lastPathComponent.lowercased() ?? "",
                    timeout: 10)
                progress(learned.notes.joined(separator: " ") + " Testing it again…")
                let again = await LaunchTest.run(appID: appID, name: name, exe: scan.exe,
                                                 cancel: { control.isCancelled() },
                                                 progress: progress)
                recipe.launchTest = again
                try? FixPack.writeRecipe(recipe, in: folder)
                launchTestRunning = false
                return (learned.notes + [again.online.note]).joined(separator: " ")
            }
            try? FixPack.writeRecipe(recipe, in: folder)
        }
        return result.message
    }

    /// Tests an installed fix without reinstalling it.
    func testFixNow(appID: Int, name: String) {
        guard !busy else { return }
        guard let folder = Store.gameFolder(for: appID, name: name),
              FixPack.hasPack(in: folder) else {
            fixMessage = "Install the fix first."
            return
        }
        busy = true
        fixMessage = "Testing \(name)…"
        Task { @MainActor in
            let note: @Sendable (String) -> Void = { [weak self] text in
                self?.showProgress(text)
            }
            let message = await self.testInstalledFix(appID: appID, name: name, progress: note)
            self.busy = false
            self.fixMessage = message
            self.refresh()
        }
    }

    /// Installs the picked archive, which the compatibility check has cleared.
    private func performArchiveImport() {
        guard let archiveURL else { return }
        guard let game = games.first(where: { $0.id == fixGameID }) else { return }
        guard let folder = Store.gameFolder(for: game.id, name: game.name),
              Store.isInstalled(appID: game.id, folder: folder) else {
            fixMessage = Store.notInstalledMessage
            return
        }
        busy = true
        fixMessage = ""
        let password = archivePassword.isEmpty ? nil : archivePassword
        let note: @Sendable (String) -> Void = { [weak self] text in
            self?.showProgress(text)
        }
        let control = LaunchTest.Control()
        if testAfterInstall {
            launchTestControl = control
            launchTestRunning = true
        }
        Task { @MainActor in
            defer {
                self.launchTestRunning = false
                self.launchTestControl = nil
            }
            do {
                let photon = self.photonTargets(appID: game.id)
                let outcome = try await FixService.installAndTest(
                    appID: game.id, name: game.name,
                    archive: archiveURL, password: password,
                    photonRealtime: photon.0, photonVoice: photon.1,
                    test: self.testAfterInstall, control: control,
                    progress: note)
                self.recordFix(outcome, for: game)
                self.showProgress(outcome.message)
            } catch {
                self.showProgress(error.localizedDescription)
            }
            self.busy = false
            self.refresh()
        }
    }

    /// Fetches the fix package for the selected game from online-fix.me and installs it.
    func fetchFix() {
        guard !OnlineFixAvailability.isBroken else {
            fixMessage = OnlineFixAvailability.message
            return
        }
        guard let game = games.first(where: { $0.id == fixGameID }) else {
            fixMessage = "Pick a game from your list."
            return
        }
        // Check the game is really there before downloading anything: the fix is built
        // from its files, so a folder with nothing in it cannot be scanned.
        guard Store.isInstalled(appID: game.id,
                                folder: Store.gameFolder(for: game.id, name: game.name)) else {
            fixMessage = Store.notInstalledMessage
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
        let control = LaunchTest.Control()
        if testAfterInstall {
            launchTestControl = control
            launchTestRunning = true
        }
        defer {
            if let downloadDir { try? Paths.fm.removeItem(at: downloadDir) }
            launchTestRunning = false
            launchTestControl = nil
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

            let photon = photonTargets(appID: game.id)
            let outcome = try await FixService.installAndTest(
                appID: game.id, name: game.name,
                archive: entry, password: FixSource.defaultPassword,
                photonRealtime: photon.0, photonVoice: photon.1,
                test: testAfterInstall, control: control,
                progress: note)
            recordFix(outcome, for: game)
            let matched = folder.isExact ? "" : " (matched “\(folder.name)” on online-fix.me)"
            fixMessage = "Fetched from online-fix.me. " + outcome.message + matched
        } catch {
            fixMessage = "Auto-fetch failed: \(error.localizedDescription)\n"
                + "\(game.name) stays in My Games and starts as itself until its fix "
                + "is installed. You can install one later with “Choose archive…”."
        }
        busy = false
    }

    func recordFix(_ outcome: FixService.Outcome, for game: ManagedGame) {
        fixes.removeAll { $0.id == game.id }
        fixes.append(FixRecord(id: game.id, gameName: game.name, files: outcome.files,
                               sizes: FixInstaller.sizes(of: outcome.files)))
        removedFixes.remove(game.id)
        prepareWine(for: game)
        // The plan knows whether Steam's relay needs the game's own AppID. The
        // recipe carries that answer; routing reads it from the game's entry.
        if let folder = Store.gameFolder(for: game.id, name: game.name),
           let recipe = FixPack.read(in: folder),
           let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].keepRealAppID = recipe.keepRealAppID
        }
        // Stored Photon app IDs are applied with the fix, so the player never has to
        // press Apply. The install already got them; this is for a package whose
        // automatic patch skipped the game, where the older direct replace still can.
        if let folder = Store.gameFolder(for: game.id, name: game.name),
           !game.repoPhoton.realtime.isEmpty || !game.repoPhoton.voice.isEmpty {
            let wanted = photonTargets(appID: game.id)
            let applied = outcome.photonTargets.first == wanted.0
                && (outcome.photonTargets.count < 2 || outcome.photonTargets[1] == wanted.1)
            if !applied {
                _ = try? PhotonIDs.apply(gameFolder: folder,
                                         realtime: game.repoPhoton.realtime,
                                         voice: game.repoPhoton.voice)
                FixPack.syncPhotonTargets(in: folder, targets: [wanted.0, wanted.1])
            }
        }
        // The fix may have brought the Photon assemblies: drop the cached "not a
        // Photon game" answer before anything reads it again.
        if let folder = Store.gameFolder(for: game.id, name: game.name) {
            PhotonFix.forget(folder: folder)
        }
        // The fix's own files are in place now, so read the game for the Photon app id
        // it connects to. A game whose online play runs on Photon needs that id swapped
        // for the one everyone plays on, and the patch for it is made from the game's
        // own files here rather than kept per game.
        scanPhotonIDs(appID: game.id, name: game.name, force: true)
        persist()
    }

    /// Makes the game's Wine prefix run the fix that was just installed.
    ///
    /// Two things hold a fix back on macOS, and they are not Photon-specific:
    /// Wine prefers its own built-in copy of a proxy DLL over the one the fix put
    /// beside the game, and OnlineFix64 refuses a `dlllist.txt` that does not name
    /// the Steam overlay first. The overlay line stays; its DllMain is made inert
    /// instead, because a missing renderer would otherwise stop the rest of the
    /// list with error 126.
    private func prepareWine(for game: ManagedGame, fix: FixRecord? = nil) {
        guard let record = fix ?? fixes.first(where: { $0.id == game.id }) else { return }
        let folder = Store.gameFolder(for: game.id, name: game.name)
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

    /// Every recorded fix is checked against its pack on refresh, so a Steam verify or
    /// an update is put right before the game is next started. A game whose prefix
    /// Steam made after its install gets its DLL overrides here too.
    private func prepareWineForInstalledFixes() {
        let repaired = FixService.verifyAll(games: games, fixes: fixes)
        var changed = false
        for fix in fixes {
            guard let folder = Store.gameFolder(for: fix.id, name: fix.gameName) else { continue }
            prepareWine(for: ManagedGame(id: fix.id, name: fix.gameName), fix: fix)
            FixService.refreshLaunchOverrides(appID: fix.id, name: fix.gameName)
            if let game = games.first(where: { $0.id == fix.id }),
               !game.repoPhoton.realtime.isEmpty || !game.repoPhoton.voice.isEmpty,
               PhotonFix.isPhotonGame(in: folder) {
                _ = try? PhotonIDs.apply(gameFolder: folder,
                                         realtime: game.repoPhoton.realtime,
                                         voice: game.repoPhoton.voice)
                let wanted = photonTargets(appID: game.id)
                FixPack.syncPhotonTargets(in: folder, targets: [wanted.0, wanted.1])
            }
            changed = changed || repaired[fix.id] != nil
        }
        if changed, let first = repaired.values.first {
            fixMessage = first.message
            persist()
        }
    }

    func openFixSite() {
        Steam.open(FixSource.siteURL)
    }

    func removeFix(id: Int) {
        uninstallFix(appID: id)
    }

    /// Patch-sheet action: put back anything the pack says has changed since the fix
    /// was built, and say what it did.
    func repairFix(appID: Int) {
        guard let game = games.first(where: { $0.id == appID }) else { return }
        let outcome = FixService.repair(appID: appID, name: game.name)
        if !outcome.repaired.isEmpty { persist() }
        fixMessage = outcome.message
    }

    /// Puts the game's own Steam API back and leaves the fix's loader out, for a game
    /// the loader never opens: it starts as Spacewar and no window ever appears, which
    /// is what a 32-bit .NET game such as Terraria does. The routing still gives it
    /// the Spacewar identity, so online play meets the other copies.
    func routingOnlyFix(appID: Int) {
        guard let game = games.first(where: { $0.id == appID }) else { return }
        let outcome = FixService.routingOnly(appID: appID, name: game.name)
        fixMessage = outcome.message
        guard !outcome.repaired.isEmpty else { return }
        if let index = games.firstIndex(where: { $0.id == appID }) {
            games[index].keepRealAppID = false
        }

        // The file is the game's own again, so its size no longer says anything about
        // whether the fix is still in place: leaving it in the record would show the
        // fix as broken on the next app start.
        if let index = fixes.firstIndex(where: { $0.id == appID }) {
            let restored = Set(outcome.repaired.map {
                ($0 as NSString).lastPathComponent.lowercased()
            })
            var record = fixes[index]
            record.files.removeAll {
                restored.contains(($0 as NSString).lastPathComponent.lowercased())
            }
            fixes[index] = record
        }
        persist()
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
        let macPatchable = folder.flatMap { FixInstaller.nativeMacBundle(in: $0) }
            .map { MacBundlePatch.canPatch($0) } ?? false
        let windowsBuild = folder.map { FixInstaller.hasWindowsBuild(in: $0) } ?? false
        // A folder that keeps both builds cannot say which one runs; the fix's record
        // can, so the card follows that and only falls back to the folder.
        let buildInUse = GameBuildInUse.resolve(appID: appID, folder: folder)
        let installed = fixIsInstalled(appID)
        return OnlineFixStoreStatus(
            inList: alreadyAdded(appID),
            fixInstalled: installed,
            gameInstalled: Store.isInstalled(appID: appID, folder: folder),
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            keepRealAppID: games.first { $0.id == appID }?.keepRealAppID ?? false,
            photonIssue: fixIssue(appID),
            gdkRestricted: FixCompatibility.isGDK(folder: folder),
            nativeMacBuild: nativeMac,
            macPatchable: macPatchable && buildInUse != .windows,
            compatTool: Steam.notProtonTool(),
            windowsBuildInstalled: buildInUse == .windows,
            buildInUse: buildInUse,
            macBuildInstalled: nativeMac,
            overlayStub: fixes.first { $0.id == appID }?.files.contains {
                ($0 as NSString).lastPathComponent == "SteamOverlay64.dll"
            } ?? false,
            lastOnlineCheck: installed ? LaunchTest.savedResult(appID: appID)?.online.note : nil)
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
            let wanted = photonTargets(appID: game.id)
            FixPack.syncPhotonTargets(in: folder, targets: [wanted.0, wanted.1])
            persist()
            fixMessage = changed.isEmpty
                ? "Those are the IDs the game already carries."
                : "Patched the game files with the new Photon app IDs."
        } catch {
            fixMessage = error.localizedDescription
        }
    }

    /// The Mac build's own patch: the Photon app id the game connects to, and any code
    /// change its profile names. A Windows build cannot take it, and its fix does the
    /// same thing from inside the game instead.
    func setMacBuildPatch(_ on: Bool, game: ManagedGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let folder = Store.gameFolder(for: game.id, name: game.name)
        guard let app = folder.flatMap({ FixInstaller.nativeMacBundle(in: $0) }) else {
            fixMessage = "The Mac patch is for the Mac build. In Steam, open the game's "
                + "Properties, Compatibility, turn off the forced Windows version, and let "
                + "Steam install the Mac build first."
            return
        }
        do {
            let written = try MacBundlePatch.setEnabled(on, app: app)
            games[index].picoPark2Photon = on
            persist()
            if !on {
                fixMessage = "The Mac patch is off, and the game's own files are back."
            } else if written.isEmpty {
                fixMessage = "The Mac patch was already in place."
            } else {
                fixMessage = "Patched the game's files for OnlineFix's Photon app, and "
                    + "signed it again. Launch it from Steam."
            }
        } catch {
            fixMessage = error.localizedDescription
        }
    }

    // MARK: - Photon app id

    /// Reads the game's files for the Photon app id they carry, off the main thread,
    /// and keeps what it finds for the patch sheet. Runs when a fix is installed and
    /// when the sheet opens; a folder already read is not read again unless forced.
    func scanPhotonIDs(appID: Int, name: String, force: Bool = false) {
        guard let folder = Store.gameFolder(for: appID, name: name) else { return }
        if !force, photonScans[appID] != nil, photonScanFolders[appID] == folder.path { return }
        guard !photonScanning.contains(appID) else { return }
        photonScanning.insert(appID)
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                PhotonPatch.scan(in: folder)
            }.value
            guard let self else { return }
            self.photonScans[appID] = found
            self.photonScanFolders[appID] = folder.path
            self.photonScanning.remove(appID)
            self.autoPatchPhoton(appID: appID, name: name, found: found)
        }
    }

    /// Runs the Photon pass and waits for it, where `scanPhotonIDs` leaves it running in
    /// the background. A script installs and launches in one go, so the game's files
    /// have to be patched before it starts rather than a moment after.
    @discardableResult
    func finishPhotonPatch(appID: Int, name: String) async -> PhotonPatch.AutoPatch? {
        guard let folder = Store.gameFolder(for: appID, name: name) else { return nil }
        let found = await Task.detached(priority: .userInitiated) {
            PhotonPatch.scan(in: folder)
        }.value
        photonScans[appID] = found
        photonScanFolders[appID] = folder.path
        guard fixIsInstalled(appID), found.contains(where: { !$0.isOnlineFixShared }) else {
            return nil
        }
        // A ticket in the game's own log makes this a Steam-auth route even when
        // the package also carries Custom.dll. Steam networking alone does not:
        // a custom-auth game can use Steam's relay for voice or achievements.
        let log = PhotonLog.read(gameFolder: folder,
                                 prefix: WineOverride.prefix(appID: appID))
        let route = PhotonRoute.decide(
            isPhoton: true,
            packagePresent: true,
            installedChain: PhotonFix.status(gameFolder: folder,
                                             fixInstalled: true).isPhoton,
            vendorLoader: PhotonChain.hasVendorLoader(in: folder, exe: nil),
            candidates: found,
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            ownsApp: log?.ownsApp ?? PhotonLog.ownsApp(appID: appID, folder: folder,
                                                       prefix: WineOverride.prefix(appID: appID)),
            log: log)
        guard route.installsOnlineFix else { return nil }
        // A Mac build takes the patch in its own files: the Photon app id, and any code
        // change the game's profile names. There is no Windows chain to complete, and
        // the routing applies as it does for any other build.
        if let bundle = FixInstaller.nativeMacBundle(in: folder),
           MacBundlePatch.canPatch(bundle) {
            _ = try? MacBundlePatch.setEnabled(true, app: bundle)
            // The switch reads this flag, so the record has to agree with the bundle.
            if let index = games.firstIndex(where: { $0.id == appID }),
               !games[index].picoPark2Photon {
                games[index].picoPark2Photon = true
                persist()
            }
            return nil
        }
        // The candidates are proof enough that this is a Photon game. Asking the
        // filename cache as well could refuse a game whose fix supplied the Photon
        // assemblies after that cache was filled.
        let targets = photonTargets(appID: appID)
        let report = await Task.detached(priority: .userInitiated) {
            PhotonPatch.autoPatch(in: folder, realtime: targets.0, voice: targets.1)
        }.value
        if report.replaced != nil {
            fixMessage = photonPatchMessage(name, report)
        } else if let skipped = report.skipped {
            fixMessage = skipped
        }
        persist()
        return report
    }

    /// The patch every Photon game gets without being asked: the app id its files
    /// carry is replaced by OnlineFix's, which is what lets it meet players on that
    /// app. It runs after each scan and is idempotent, so a game already carrying
    /// OnlineFix's id is left alone. PICO PARK 2 also needs its session limit lifted,
    /// so it goes through its own patch instead.
    private func autoPatchPhoton(appID: Int, name: String, found: [PhotonPatch.Candidate]) {
        guard fixIsInstalled(appID), !found.isEmpty else { return }
        guard found.contains(where: { !$0.isOnlineFixShared }) else { return }
        guard !photonScanning.contains(appID) else { return }
        guard let folder = Store.gameFolder(for: appID, name: name) else { return }
        let log = PhotonLog.read(gameFolder: folder,
                                 prefix: WineOverride.prefix(appID: appID))
        let route = PhotonRoute.decide(
            isPhoton: true,
            packagePresent: true,
            installedChain: PhotonFix.status(gameFolder: folder,
                                             fixInstalled: true).isPhoton,
            vendorLoader: PhotonChain.hasVendorLoader(in: folder, exe: nil),
            candidates: found,
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            ownsApp: log?.ownsApp ?? PhotonLog.ownsApp(appID: appID, folder: folder,
                                                       prefix: WineOverride.prefix(appID: appID)),
            log: log)
        guard route.installsOnlineFix else { return }

        if let bundle = FixInstaller.nativeMacBundle(in: folder),
           MacBundlePatch.canPatch(bundle) {
            _ = try? MacBundlePatch.setEnabled(true, app: bundle)
            return
        }
        let targets = photonTargets(appID: appID)
        photonScanning.insert(appID)
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                PhotonPatch.autoPatch(in: folder, realtime: targets.0, voice: targets.1)
            }.value
            guard let self else { return }
            self.photonScanning.remove(appID)
            if report.replaced != nil {
                self.fixMessage = self.photonPatchMessage(name, report)
                self.scanPhotonIDs(appID: appID, name: name, force: true)
            } else if let skipped = report.skipped {
                self.fixMessage = skipped
            }
        }
    }

    /// The ids a game should carry: the player's own when they set valid GUIDs, and
    /// OnlineFix's published pair otherwise. The custom ids are written at install, so
    /// the automatic pass must not put the defaults back over them.
    private func photonTargets(appID: Int) -> (String, String) {
        guard let game = games.first(where: { $0.id == appID }) else {
            return (PhotonIDs.realtime, PhotonIDs.voice)
        }
        let realtime = PhotonIDs.isGUID(game.repoPhoton.realtime)
            ? game.repoPhoton.realtime : PhotonIDs.realtime
        let voice = PhotonIDs.isGUID(game.repoPhoton.voice)
            ? game.repoPhoton.voice : PhotonIDs.voice
        return (realtime, voice)
    }

    private func photonPatchMessage(_ name: String, _ report: PhotonPatch.AutoPatch) -> String {
        if report.voiceReplaced != nil {
            return "Patched \(name)'s Photon realtime and voice app ids to OnlineFix's, "
                + "so it can meet players on that app. The game's own files are kept "
                + "beside them."
        }
        return "Patched \(name)'s Photon app id to OnlineFix's, so it can meet players "
            + "on that app. The game's own files are kept beside them."
    }

    /// Writes a Photon app id into the game's files, which is the patch itself: the id
    /// the game carries is swapped where the game keeps it, and the untouched file is
    /// kept beside it.
    func applyPhotonID(_ new: String, replacing old: String, for game: ManagedGame) {
        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            fixMessage = "Install \(game.name) in Steam first."
            return
        }
        let wanted = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            fixMessage = "Type the Photon app id to use first."
            return
        }
        guard !photonScanning.contains(game.id) else { return }
        photonScanning.insert(game.id)
        fixMessage = "Writing the new Photon app id into \(game.name)'s files…"
        Task { @MainActor [weak self] in
            var message: String
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    try PhotonPatch.replace(old, with: wanted, in: folder)
                }.value
                message = written.isEmpty
                    ? "Nothing changed: no file carries that app id any more, so the game "
                        + "was either patched already or has been verified since the scan."
                    : "Patched \(written.count) file(s) with the new Photon app id, and kept "
                        + "the untouched copies beside them. Launch the game from Steam."
                if !written.isEmpty {
                    FixPack.syncPhotonTargets(in: folder, targets: [wanted])
                }
                self?.scanPhotonIDs(appID: game.id, name: game.name, force: true)
            } catch {
                message = error.localizedDescription
            }
            self?.photonScanning.remove(game.id)
            self?.fixMessage = message
        }
    }

    /// Puts the game's own files back, which is how a Photon patch is taken off again.
    func restorePhotonIDs(for game: ManagedGame) {
        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            fixMessage = "Install \(game.name) in Steam first."
            return
        }
        guard !photonScanning.contains(game.id) else { return }
        photonScanning.insert(game.id)
        fixMessage = "Putting \(game.name)'s own files back…"
        Task { @MainActor [weak self] in
            var message: String
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try PhotonPatch.restore(in: folder)
                }.value
                message = restored.isEmpty
                    ? "There was nothing to put back: no file here was patched from this screen."
                    : "Put \(restored.count) game file(s) back, and signed the game again if it "
                        + "is a Mac build."
                if !restored.isEmpty { FixPack.syncPhotonTargets(in: folder, targets: []) }
                self?.scanPhotonIDs(appID: game.id, name: game.name, force: true)
            } catch {
                message = error.localizedDescription
            }
            self?.photonScanning.remove(game.id)
            self?.fixMessage = message
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
            FixPack.syncPhotonTargets(in: folder, targets: [])
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
                          testAfterInstall: Bool = false,
                          progress: @escaping @Sendable (String) -> Void = { _ in })
        async -> OnlineFixStoreOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "App \(appID)" : trimmed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            return OnlineFixStoreOutcome(message: nil,
                                         error: "Install the game in Steam first, OnlineFix needs its game folder.",
                                         needsGame: true, installed: false)
        }
        // A folder Steam made and never filled is not an install: the fix is built from
        // the game's files, and there are none to read.
        guard Store.isInstalled(appID: appID, folder: folder) else {
            return OnlineFixStoreOutcome(message: nil, error: Store.notInstalledMessage,
                                         needsGame: true, installed: false)
        }
        // OnlineFix is Windows PE files that hook Windows Steam's API. A native build
        // runs as a Mach-O process and loads `libsteam_api.dylib`, so its files can
        // never load there. A build whose Photon app id can be read is patched in its
        // own files instead; otherwise the way in is to switch the game to NotProton
        // and let Steam download the Windows build, which is what the store page does
        // with this reply.
        let nativeBuild = FixInstaller.nativeMacBundle(in: folder)
        let patchableMac = nativeBuild.map { MacBundlePatch.canPatch($0) } ?? false
        if let bundle = nativeBuild, !confirmed, !patchableMac {
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

            progress("Downloading \(archives.count) file(s) from online-fix.me…")
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
            let photon = photonTargets(appID: appID)
            let test = testAfterInstall && self.testAfterInstall
            let control = LaunchTest.Control()
            if test {
                launchTestControl = control
                launchTestRunning = true
            }
            defer {
                if test {
                    launchTestRunning = false
                    if launchTestControl === control { launchTestControl = nil }
                }
            }
            let outcome = try await FixService.installAndTest(
                appID: appID, name: display,
                archive: entry, password: FixSource.defaultPassword,
                photonRealtime: photon.0, photonVoice: photon.1,
                test: test, control: control,
                progress: progress)
            recordFix(outcome, for: game)
            let identity = outcome.keepRealAppID
                ? "its own AppID, which Steam's relay needs"
                : "AppID 480"
            // A store install normally launches the game once and records what it saw.
            // When that did not happen, do not let the card imply the connection was
            // checked: say it was not, and point at the Test button.
            let untested = !outcome.keepRealAppID
                && (!test || outcome.launchTest?.outcome != .launched)
            let message = outcome.message
                + (untested
                    ? " Spacewar (480) routing is set, but this install did not confirm the "
                      + "online connection. Press Test to launch it once and check."
                    : "")
                + " Launch \(display) from Steam. It runs as \(identity)."
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
        let folder = Store.gameFolder(for: appID, name: name)
        if let folder, FixPack.hasPack(in: folder) {
            // The pack holds every file the fix wrote and what each one replaced, so
            // it puts the game back exactly; the old sweep would guess.
            do {
                restored = try FixService.uninstall(appID: appID, name: name)
            } catch {
                return OnlineFixStoreOutcome(message: nil,
                                             error: error.localizedDescription,
                                             needsGame: false, installed: true)
            }
        } else if let record {
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
