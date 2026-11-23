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
                        progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let root = try await FixInstaller.extract(archive: archive, password: password,
                                                  progress: progress)
        defer { try? Paths.fm.removeItem(at: root) }
        return try install(appID: appID, name: name, root: root,
                           packageName: archive.lastPathComponent, progress: progress)
    }

    /// The same, from an already extracted package (the tests use this).
    static func install(appID: Int, name: String, root: URL, packageName: String = "",
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
        let plan = FixPlan.build(appID: appID, name: name, scan: scan,
                                 package: package, diagnosis: diagnosis)
        var steps: [String] = []
        if !plan.copies.isEmpty { steps.append("copy \(plan.copies.count) file(s)") }
        if !plan.restores.isEmpty { steps.append("put \(plan.restores.count) back") }
        if !plan.edits.isEmpty { steps.append("edit \(plan.edits.count)") }
        if !plan.removals.isEmpty { steps.append("remove \(plan.removals.count)") }
        progress("Plan: " + (steps.isEmpty ? "nothing to change" : steps.joined(separator: ", ")) + ".")
        let applied = try FixApply.apply(plan, appID: appID, folder: folder, progress: progress)

        if plan.picoPark2, let bundle = scan.macBundle {
            _ = try PicoPark2Patch.setEnabled(true, app: bundle)
        }
        if plan.photonSwap, scan.isPhoton {
            _ = PhotonPatch.autoPatch(in: folder)
        }

        var recipe = FixRecipe(
            appID: appID, name: name, installedAt: Date(),
            packageName: package.archiveName, findings: diagnosis.findings,
            entries: [], removed: plan.removals.map { $0.path.lastPathComponent },
            keepRealAppID: plan.keepRealAppID, photonSwap: plan.photonSwap,
            picoPark2: plan.picoPark2, wineDLLs: plan.wineDLLs,
            notes: applied.notes + plan.notes)
        recipe.notes.append(contentsOf: diagnosis.warnings.map { "\($0.code): \($0.title)." })

        for wrote in applied.wrote {
            let url = folder.appendingPathComponent(wrote.relative)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, let hash = Hash.sha256(url) else { continue }
            recipe.entries.append(FixRecipe.Entry(path: wrote.relative, size: Int64(size),
                                                  sha256: hash, created: wrote.created))
        }
        try FixPack.write(recipe, in: folder)
        progress("Packed the fix: \(recipe.entries.count) file(s) recorded in "
            + ".macsteam-onlinefix, so a repair needs no download.")

        outcome.files = applied.wrote.map { folder.appendingPathComponent($0.relative).path }
        outcome.notes = recipe.notes
        outcome.installed = true
        return outcome
    }

    // MARK: - Repair

    /// Puts back anything the pack says has changed since it was written.
    static func repair(appID: Int, name: String) -> Outcome {
        var outcome = Outcome()
        guard let folder = Store.gameFolder(for: appID, name: name) else {
            outcome.error = "Install \(name) in Steam first."
            return outcome
        }
        guard let recipe = FixPack.read(in: folder) else {
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
            if recipe.photonSwap { _ = PhotonPatch.autoPatch(in: folder) }
            if recipe.picoPark2, let bundle = FixInstaller.nativeMacBundle(in: folder) {
                _ = try? PicoPark2Patch.setEnabled(true, app: bundle)
            }
            outcome.notes.append("Every file the fix put in place is still there.")
            return outcome
        }

        outcome.repaired = FixPack.restore(changed, in: folder)
        if recipe.photonSwap {
            _ = PhotonPatch.autoPatch(in: folder)
        }
        if recipe.picoPark2, let bundle = FixInstaller.nativeMacBundle(in: folder) {
            _ = try? PicoPark2Patch.setEnabled(true, app: bundle)
        }
        ensureWine(recipe, appID: appID)

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

    /// Repairs every game whose pack no longer matches its folder.
    static func verifyAll(games: [ManagedGame], fixes: [FixRecord]) -> [Int: Outcome] {
        var results: [Int: Outcome] = [:]
        for fix in fixes {
            guard let folder = Store.gameFolder(for: fix.id, name: fix.gameName),
                  FixPack.hasPack(in: folder),
                  !FixPack.verify(in: folder).isEmpty else { continue }
            results[fix.id] = repair(appID: fix.id, name: fix.gameName)
        }
        return results
    }

    // MARK: - Uninstall and diagnosis

    /// Puts the game's own files back from the pack, and removes it.
    @discardableResult
    static func uninstall(appID: Int, name: String) -> Int {
        guard let folder = Store.gameFolder(for: appID, name: name) else { return 0 }
        return (try? FixPack.undo(in: folder)) ?? 0
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

    /// A path as the player sees it: from the game folder, or the last two parts.
    private static func short(_ url: URL, in folder: URL) -> String {
        let relative = FixPlan.relative(url, in: folder)
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private static func ensureWine(_ recipe: FixRecipe, appID: Int) {
        guard WineOverride.prefix(appID: appID) != nil else { return }
        for dll in recipe.wineDLLs {
            WineOverride.ensure(appID: appID, dll: dll, native: WineOverride.needsNative(dll))
        }
    }
}
