// One fix, from the archive to a game that runs.
//
// Install reads the package and the game, decides what this game needs, builds and
// applies it, and packs the result in the game folder. Repair re-applies from that
// pack, so a Steam verify or an update needs no download. Uninstall puts the game
// back exactly as the pack found it.
import Foundation

enum FixService {

    struct Outcome: Sendable {
        var files: [String] = []
        var findings: [FixFinding] = []
        var notes: [String] = []
        /// Files a repair put back.
        var repaired: [String] = []
        /// The Photon ids the game was left carrying, when the patch ran.
        var photonTargets: [String] = []
        /// True when the plan keeps the game's own AppID for Steam's relay.
        var keepRealAppID = false
        var error: String?
        var installed = false

        var message: String {
            if let error { return error }
            var parts: [String] = []
            if installed {
                parts.append("OnlineFix installed: \(files.count) file(s) written into the game folder.")
            }
            if !repaired.isEmpty {
                parts.append("Put \(repaired.count) file(s) back from the fix pack.")
            }
            if parts.isEmpty {
                parts.append("The fix is in place; nothing needed changing.")
            }
            let worth = findings.filter { $0.level != .notice }
            if !worth.isEmpty {
                parts.append(worth.map { "\($0.code): \($0.title)." }.joined(separator: " "))
            }
            parts.append(contentsOf: notes)
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Install

    /// Unpacks a fix archive and builds it for the game.
    static func install(appID: Int, name: String, archive: URL, password: String?,
                        photonRealtime: String = PhotonIDs.realtime,
                        photonVoice: String = PhotonIDs.voice,
                        progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let root = try await FixInstaller.extract(archive: archive, password: password,
                                                  progress: progress)
        defer { try? Paths.fm.removeItem(at: root) }
        return try install(appID: appID, name: name, root: root,
                           packageName: archive.lastPathComponent,
                           photonRealtime: photonRealtime, photonVoice: photonVoice,
                           progress: progress)
    }

    /// The same, from an already extracted package (the tests use this).
    static func install(appID: Int, name: String, root: URL, packageName: String = "",
                        photonRealtime: String = PhotonIDs.realtime,
                        photonVoice: String = PhotonIDs.voice,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Outcome {
        var outcome = Outcome()
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            outcome.error = "Install \(name) in Steam first: OnlineFix needs its game folder "
                + "to put its files in."
            return outcome
        }
        guard Store.isInstalled(appID: appID, folder: folder) else {
            outcome.error = Store.notInstalledMessage
            return outcome
        }

        progress("Reading the fix…")
        let package = FixPackage.read(root: root, archiveName: packageName)
        var carried = "The package carries \(package.items.count) file(s)"
        if package.carriesPayload { carried += ", the OnlineFix payload among them" }
        if package.hasPhotonChain { carried += ", with its Photon patch" }
        progress(carried + ".")
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        progress("Reading \(name): \(scan.engine.name), \(scan.is64Bit ? "64" : "32")-bit"
            + (scan.apiFolder.map { ", Steam API in \(short($0, in: scan.folder))" } ?? "")
            + (scan.isPhoton ? ", Photon online play" : "") + ".")
        let candidates = PhotonPatch.scan(in: folder)
        let diagnosis = FixDiagnosis.run(scan: scan, package: package, candidates: candidates)
        outcome.findings = diagnosis.findings
        progress(diagnosis.findings.isEmpty
            ? "Nothing to work around for this game."
            : "\(diagnosis.findings.count) finding(s): "
                + diagnosis.findings.map(\.code).joined(separator: ", ") + ".")
        if diagnosis.isBlocked {
            outcome.error = diagnosis.blocking
                .map { "\($0.title). \($0.detail) \($0.remedy)" }
                .joined(separator: " ")
            return outcome
        }

        progress("Building the fix for \(name)…")
        var plan = FixPlan.build(appID: appID, name: name, scan: scan,
                                 package: package, diagnosis: diagnosis)
        var steps: [String] = []
        if !plan.copies.isEmpty { steps.append("copy \(plan.copies.count) file(s)") }
        if !plan.restores.isEmpty { steps.append("put \(plan.restores.count) back") }
        if !plan.edits.isEmpty { steps.append("edit \(plan.edits.count)") }
        if !plan.removals.isEmpty { steps.append("remove \(plan.removals.count)") }
        progress("Plan: " + (steps.isEmpty ? "nothing to change" : steps.joined(separator: ", ")) + ".")
        if plan.isEmpty, plan.keepGameAPI {
            outcome.error = "\(name)'s own Steam API DLL is no longer beside the fix's, so "
                + "there is nothing to put back. Verify the game in Steam, or install it again."
            return outcome
        }
        var applied = try FixApply.apply(plan, appID: appID, folder: folder, progress: progress)
        // The package may have brought Photon assemblies. Drop the pre-install answer
        // before the consistency pass reads the game again.
        PhotonFix.forget(folder: folder)

        // The package is in place now, so read the result rather than the intention:
        // a partial archive, a proxy the game never imports, an API DLL in the wrong
        // folder, a Photon plugin outside the loader's path. Every repair is a normal
        // plan, applied with the same backups as the install.
        let expectedAPI = plan.copies.first {
            FixPackage.apiNames.contains($0.destination.lastPathComponent.lowercased())
        }?.destination
        let audit = FixAudit.run(appID: appID, name: name, scan: GameScan.read(
            folder: folder, appID: appID, name: name), package: package,
            installed: plan, expectedAPI: expectedAPI)
        outcome.findings.append(contentsOf: audit.findings)
        if audit.changed {
            progress("Checking the installed fix against the game: "
                + "\(audit.repairs.count) file(s) to put right.")
            let repaired = try FixApply.apply(audit.plan, appID: appID, folder: folder,
                                              progress: progress)
            applied = merge(applied, repaired)
            plan.notes.append(contentsOf: audit.notes)
            plan.wineDLLs = Array(Set(plan.wineDLLs + audit.plan.wineDLLs)).sorted()
            // A Photon game whose chain only the consistency pass completed still
            // needs its app id patched, or the new plugin connects with the game's id.
            let chainNames: Set<String> = ["custom.dll", "bepinex.preloader.dll"]
            if audit.plan.copies.contains(where: {
                chainNames.contains($0.destination.lastPathComponent.lowercased())
            }) {
                plan.photonSwap = true
            }
        }

        if plan.picoPark2, let bundle = scan.macBundle {
            _ = try PicoPark2Patch.setEnabled(true, app: bundle)
        }
        var photonWritten: [String] = []
        if plan.photonSwap {
            let report = PhotonPatch.autoPatch(in: folder, realtime: photonRealtime,
                                               voice: photonVoice)
            photonWritten = report.written
            outcome.photonTargets = report.targets
        }

        var recipe = FixRecipe(
            appID: appID, name: name, installedAt: Date(),
            packageName: package.archiveName, findings: outcome.findings,
            entries: [], removed: applied.removed,
            keepRealAppID: plan.keepRealAppID, photonSwap: plan.photonSwap,
            picoPark2: plan.picoPark2, wineDLLs: plan.wineDLLs,
            notes: applied.notes + plan.notes)
        recipe.photonPatched = photonWritten.map {
            FixPlan.relative(URL(fileURLWithPath: $0), in: folder)
        }
        recipe.photonIDs = outcome.photonTargets
        var fileIDs: [String: [String]] = [:]
        for relative in recipe.photonPatched ?? [] {
            let file = folder.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
                continue
            }
            let carrying = outcome.photonTargets.filter {
                data.range(of: Data($0.utf8)) != nil
            }
            if !carrying.isEmpty { fileIDs[relative] = carrying }
        }
        recipe.photonFileIDs = fileIDs
        recipe.notes.append(contentsOf: diagnosis.warnings.map { "\($0.code): \($0.title)." })

        for wrote in applied.wrote {
            let url = folder.appendingPathComponent(wrote.relative)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, let hash = Hash.sha256(url) else { continue }
            recipe.entries.append(FixRecipe.Entry(path: wrote.relative, size: Int64(size),
                                                  sha256: hash, created: wrote.created))
        }
        try FixPack.write(recipe, in: folder)
        // The automatic swap records the files it wrote. A game that already carried
        // the target (or a custom pair from the patch sheet) still has its untouched
        // copies beside it, and those are what an undo has to restore.
        if recipe.photonSwap {
            FixPack.syncPhotonTargets(in: folder, targets: outcome.photonTargets)
        }
        prepareLaunchOverrides(recipe: recipe, folder: folder)
        progress("Packed the fix: \(recipe.entries.count) file(s) recorded in "
            + ".macsteam-onlinefix, so a repair needs no download.")

        outcome.files = applied.wrote.map { folder.appendingPathComponent($0.relative).path }
            + photonWritten
        outcome.notes = recipe.notes
        outcome.keepRealAppID = plan.keepRealAppID
        outcome.installed = true
        return outcome
    }

    // MARK: - Repair

    /// Puts back anything the pack says has changed since it was written.
    /// A repair puts the pack back exactly, then reads the result the same way an
    /// install does. That second pass is what catches a pack made by an older
    /// scanner, such as a dlllist.txt that names Custom.net or leaves the overlay out.
    private static func auditRepair(_ recipe: inout FixRecipe, folder: URL,
                                    appID: Int, name: String,
                                    outcome: inout Outcome) {
        var installed = FixPlan()
        installed.photonSwap = recipe.photonSwap
        installed.copies = recipe.entries.compactMap { entry in
            guard let destination = FixPack.file(entry.path, in: folder) else { return nil }
            return FixPlan.Copy(source: FixPack.payloadURL(in: folder, for: entry.path),
                                destination: destination, relative: entry.path)
        }
        installed.removals = recipe.removed.compactMap { relative in
            guard let path = FixPack.file(relative, in: folder) else { return nil }
            return FixPlan.Removal(path: path, reason: "removed by the fix")
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        let audit = FixAudit.run(appID: appID, name: name, scan: scan, package: nil,
                                 installed: installed, expectedAPI: nil)
        guard audit.changed else { return }
        guard let applied = try? FixApply.apply(audit.plan, appID: appID, folder: folder) else {
            outcome.notes.append("The repair found more to do but could not apply it.")
            return
        }
        outcome.findings.append(contentsOf: audit.findings)
        outcome.repaired.append(contentsOf: applied.wrote.map {
            folder.appendingPathComponent($0.relative).path
        })
        outcome.notes.append(contentsOf: applied.notes)
        for wrote in applied.wrote {
            let url = folder.appendingPathComponent(wrote.relative)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, let hash = Hash.sha256(url) else { continue }
            if let index = recipe.entries.firstIndex(where: { $0.path == wrote.relative }) {
                recipe.entries[index].size = Int64(size)
                recipe.entries[index].sha256 = hash
            } else {
                recipe.entries.append(FixRecipe.Entry(path: wrote.relative, size: Int64(size),
                                                      sha256: hash, created: wrote.created))
            }
        }
        try? FixPack.write(recipe, in: folder)
    }

    static func repair(appID: Int, name: String) -> Outcome {
        var outcome = Outcome()
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            outcome.error = "Install \(name) in Steam first."
            return outcome
        }
        guard var recipe = FixPack.read(in: folder) else {
            outcome.error = "No fix pack for \(name), so there is nothing to repair from. "
                + "Install the fix again to build one."
            return outcome
        }
        outcome.findings = recipe.findings

        let changed = FixPack.verify(in: folder)
        guard !changed.isEmpty else {
            // The patch a game takes in its own files is not one of the copied files,
            // so it is checked and re-applied here; both calls are idempotent.
            ensureWine(recipe, appID: appID)
            prepareLaunchOverrides(recipe: recipe, folder: folder)
            auditRepair(&recipe, folder: folder, appID: appID, name: name, outcome: &outcome)
            recordPhotonPatch(&recipe, folder: folder)
            if recipe.picoPark2, let bundle = FixInstaller.nativeMacBundle(in: folder) {
                _ = try? PicoPark2Patch.setEnabled(true, app: bundle)
            }
            outcome.notes.append("Every file the fix put in place is still there.")
            return outcome
        }

        outcome.repaired = FixPack.restore(changed, in: folder)
        auditRepair(&recipe, folder: folder, appID: appID, name: name, outcome: &outcome)
        recordPhotonPatch(&recipe, folder: folder)
        if recipe.picoPark2, let bundle = FixInstaller.nativeMacBundle(in: folder) {
            _ = try? PicoPark2Patch.setEnabled(true, app: bundle)
        }
        ensureWine(recipe, appID: appID)
        prepareLaunchOverrides(recipe: recipe, folder: folder)

        let remaining = FixPack.verify(in: folder)
        if !remaining.isEmpty {
            outcome.notes.append("Still to put back: \(remaining.joined(separator: ", ")). "
                + "Install the fix again to rebuild the pack.")
        }
        return outcome
    }

    /// Puts the game's own Steam API back and leaves the fix's loader out, for a game
    /// its loader never opens. macSteam's routing still starts the game as Spacewar,
    /// which is the identity the other OnlineFix copies meet on.
    static func routingOnly(appID: Int, name: String) -> Outcome {
        var outcome = Outcome()
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            outcome.error = "Install \(name) in Steam first."
            return outcome
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        guard let original = scan.originalSteamAPI else {
            outcome.error = "\(name)'s own Steam API DLL is not beside the fix's, so there is "
                + "nothing to put back. Install the game in Steam again, or verify its files."
            return outcome
        }
        guard let api = scan.loaderFiles["steam_api.dll"]
                ?? scan.loaderFiles["steam_api64.dll"]
                ?? scan.apiDLLs.first(where: {
                    FixPackage.apiNames.contains($0.lastPathComponent.lowercased())
                }) else {
            outcome.error = "\(name) has no Steam API DLL to put back."
            return outcome
        }
        do {
            try FixApply.copyIntoPlace(original, at: api)
        } catch {
            outcome.error = error.localizedDescription
            return outcome
        }
        outcome.repaired = [api.path]
        outcome.notes.append("Put \(name)'s own \(api.lastPathComponent) back and left the "
            + "fix's loader out. macSteam's routing starts it as Spacewar, so it opens and "
            + "still meets other copies on 480.")
        return outcome
    }

    /// Repairs every installed pack, not only one whose files changed. A pack made
    /// by an older scanner can match its own manifest and still carry a bad
    /// dlllist.txt; the audit inside repair is what catches that.
    static func verifyAll(games: [ManagedGame], fixes: [FixRecord]) -> [Int: Outcome] {
        var results: [Int: Outcome] = [:]
        for fix in fixes {
            guard let folder = Store.gameFolder(for: fix.id, name: fix.gameName),
                  FixPack.hasPack(in: folder) else { continue }
            results[fix.id] = repair(appID: fix.id, name: fix.gameName)
        }
        return results
    }

    // MARK: - Uninstall and diagnosis

    /// Puts the game's own files back from the pack, and removes it.
    static func uninstall(appID: Int, name: String) throws -> Int {
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            throw ManagerError("Install \(name) in Steam first.")
        }
        let recipe = FixPack.read(in: folder)
        let assignments = recipe.map { launchAssignments(recipe: $0, folder: folder) } ?? []
        let removed = try FixPack.undo(in: folder)
        clearLaunchOverrides(appID: appID, assignments: assignments)
        return removed
    }

    /// Re-applies the launch options for a fix that is already installed, so a
    /// fix packed by an older build gains the overrides without a reinstall.
    static func refreshLaunchOverrides(appID: Int, name: String) {
        guard let folder = Store.gameFolder(for: appID, name: name),
              let recipe = FixPack.read(in: folder) else { return }
        prepareLaunchOverrides(recipe: recipe, folder: folder)
    }

    /// What this game and this package need, without writing anything.
    static func diagnose(appID: Int, name: String,
                         packageRoot: URL? = nil) -> (GameScan?, FixDiagnosis) {
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            return (nil, FixDiagnosis())
        }
        let package = packageRoot.map { FixPackage.read(root: $0) }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        let candidates = PhotonPatch.scan(in: folder)
        return (scan, FixDiagnosis.run(scan: scan, package: package, candidates: candidates))
    }

    /// Re-applies the Photon swap after a restore and records any file it newly
    /// patched, so uninstall knows which backups to put back.
    private static func recordPhotonPatch(_ recipe: inout FixRecipe, folder: URL) {
        guard recipe.photonSwap,
              !(recipe.photonPatched ?? []).isEmpty || !(recipe.photonIDs ?? []).isEmpty
        else { return }
        let targets = recipe.photonIDs ?? []
        let report = PhotonPatch.autoPatch(
            in: folder,
            realtime: targets.first ?? PhotonIDs.realtime,
            voice: targets.count > 1 ? targets[1] : PhotonIDs.voice)
        var patched = Set(recipe.photonPatched ?? [])
        let before = patched
        for path in report.written {
            patched.insert(FixPlan.relative(URL(fileURLWithPath: path), in: folder))
        }
        var fileIDs: [String: [String]] = [:]
        for relative in patched.sorted() {
            let file = folder.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
                continue
            }
            let carrying = report.targets.filter {
                data.range(of: Data($0.utf8)) != nil
            }
            if !carrying.isEmpty { fileIDs[relative] = carrying }
        }
        guard patched != before || report.targets != targets
                || fileIDs != (recipe.photonFileIDs ?? [:]) else { return }
        recipe.photonPatched = patched.sorted()
        recipe.photonIDs = report.targets
        recipe.photonFileIDs = fileIDs
        try? FixPack.write(recipe, in: folder)
    }

    /// A path as the player sees it: from the game folder, or the last two parts.
    private static func short(_ url: URL, in folder: URL) -> String {
        let relative = FixPlan.relative(url, in: folder)
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    /// Folds the consistency pass into the install's report, so the recipe records
    /// every file either plan wrote and uninstall removes both sets.
    private static func merge(_ first: FixApply.Result,
                              _ second: FixApply.Result) -> FixApply.Result {
        var merged = first
        for wrote in second.wrote where !merged.wrote.contains(where: {
            $0.relative == wrote.relative
        }) {
            merged.wrote.append(wrote)
        }
        for removed in second.removed where !merged.removed.contains(removed) {
            merged.removed.append(removed)
        }
        for note in second.notes where !merged.notes.contains(note) {
            merged.notes.append(note)
        }
        return merged
    }

    private static func ensureWine(_ recipe: FixRecipe, appID: Int) {
        guard WineOverride.prefix(appID: appID) != nil else { return }
        for dll in recipe.wineDLLs {
            WineOverride.ensure(appID: appID, dll: dll, native: WineOverride.needsNative(dll))
        }
    }

    /// The DLL names the fix needs Wine to take from the game folder. Only the
    /// files actually present are named: a native preference for a missing name
    /// would stop Wine falling back to its own copy.
    private static func launchAssignments(recipe: FixRecipe, folder: URL) -> [String] {
        var names = Set(recipe.wineDLLs.map { $0.lowercased() })
        names.formUnion(WineOverride.emulators)
        for proxy in WineOverride.proxies
        where Paths.fm.fileExists(atPath: folder.appendingPathComponent(proxy).path) {
            names.insert(proxy)
        }
        return names
            .filter { Paths.fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            .sorted()
            .map(WineOverride.environment)
    }

    /// Writes the same preference into the app's launch options. Doing it in the
    /// background keeps install and repair synchronous, and the writer checks the
    /// current value first, so this is a no-op once it is in place.
    private static func prepareLaunchOverrides(recipe: FixRecipe, folder: URL) {
        let assignments = launchAssignments(recipe: recipe, folder: folder)
        NSLog("OnlineFixLaunch pack app=%d dlls=%@ writer=%d", recipe.appID,
              assignments.joined(separator: ","), OnlineFixLaunchBridge.writer == nil ? 0 : 1)
        guard !assignments.isEmpty,
              let writer = OnlineFixLaunchBridge.writer else { return }
        Task.detached(priority: .utility) { _ = await writer(recipe.appID, assignments) }
    }

    private static func clearLaunchOverrides(appID: Int, assignments: [String]) {
        guard !assignments.isEmpty,
              let clearer = OnlineFixLaunchBridge.clearer else { return }
        Task.detached(priority: .utility) { _ = await clearer(appID, assignments) }
    }
}
