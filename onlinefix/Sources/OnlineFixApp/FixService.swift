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
        /// The install test, when one ran.
        var launchTest: LaunchTest.Result?
        /// Changes the test made after seeing a known failure.
        var testRepairs: [String] = []
        var testNote: String?

        var message: String {
            if let error { return error }
            var parts: [String] = []
            if installed {
                parts.append("OnlineFix installed: \(files.count) file(s) written into the game folder.")
            }
            if !repaired.isEmpty {
                parts.append("Put \(repaired.count) file(s) back from the fix pack.")
            }
            if !testRepairs.isEmpty {
                parts.append("The test run repaired: \(testRepairs.joined(separator: ", ")).")
            }
            if let launchTest {
                parts.append(launchTest.message)
            } else if let testNote {
                parts.append(testNote)
            }
            // A Mac build's patch is not one of the pack's files, so a repair that only
            // had to write it back still has notes and no "nothing changed" sentence.
            if parts.isEmpty, notes.isEmpty {
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

    /// Installs, then starts the game once. A known failure gets one audited repair
    /// and one more launch; success leaves every game and fix file untouched.
    static func installAndTest(appID: Int, name: String, archive: URL, password: String?,
                               photonRealtime: String = PhotonIDs.realtime,
                               photonVoice: String = PhotonIDs.voice,
                               test: Bool = true,
                               control: LaunchTest.Control = LaunchTest.Control(),
                               progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        var outcome = try await install(appID: appID, name: name, archive: archive,
                                        password: password,
                                        photonRealtime: photonRealtime,
                                        photonVoice: photonVoice, progress: progress)
        guard test, outcome.error == nil, outcome.installed else { return outcome }
        outcome = await testInstalled(outcome, appID: appID, name: name,
                                      control: control, progress: progress)
        return outcome
    }

    /// Runs the install test for an outcome that is already on disk.
    static func testInstalled(_ outcome: Outcome, appID: Int, name: String,
                              control: LaunchTest.Control = LaunchTest.Control(),
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        var outcome = outcome
        guard let folder = Store.gameFolder(for: appID, name: name) else { return outcome }
        let scan = GameScan.read(folder: folder, appID: appID, name: name)
        guard let exe = scan.exe else {
            outcome.testNote = "The game has no Windows executable to test."
            return outcome
        }
        progress("Testing the game (up to 2 minutes)…")
        var result = await LaunchTest.run(appID: appID, name: name, exe: exe,
                                          cancel: { control.isCancelled() },
                                          progress: progress)
        outcome.launchTest = result
        if result.outcome == .failed, result.issue.repairable {
            let repair = LaunchTestRepair.apply(result, appID: appID, name: name, progress: progress)
            outcome.testRepairs = repair.actions
            if repair.changed {
                outcome.testNote = repair.notes.joined(separator: " ")
                // The runner and wineserver need a moment to let the first process
                // go; without it the second test can mistake the old process for a
                // game the player already has open.
                _ = await LaunchTest.waitUntilStopped(
                    exe: exe, stem: exe.deletingPathExtension().lastPathComponent.lowercased(),
                    timeout: 10)
                progress("The fix was repaired. Testing it again…")
                result = await LaunchTest.run(appID: appID, name: name, exe: exe,
                                              cancel: { control.isCancelled() },
                                              progress: progress)
                outcome.launchTest = result
            } else if !repair.notes.isEmpty {
                outcome.testNote = repair.notes.joined(separator: " ")
            }
        }
        if var recipe = FixPack.read(in: folder) {
            recipe.launchTest = outcome.launchTest
            if !repairNotes(outcome).isEmpty {
                recipe.notes.append("Install test: " + repairNotes(outcome))
            }
            // The test started the game, so Photon has already answered for this
            // install. Take that answer now: the fix is only worth the connection it
            // gets, and a wrong auth type is the commonest thing that stops one.
            var learned = Outcome()
            if learnPhotonAuth(appID: appID, folder: folder, recipe: &recipe,
                               outcome: &learned) {
                outcome.notes.append(contentsOf: learned.notes)
                outcome.testNote = learned.notes.joined(separator: " ")
            }
            try? FixPack.writeRecipe(recipe, in: folder)
        }
        return outcome
    }

    private static func repairNotes(_ outcome: Outcome) -> String {
        var parts: [String] = []
        if !outcome.testRepairs.isEmpty {
            parts.append(outcome.testRepairs.joined(separator: "; "))
        }
        if let test = outcome.launchTest, !test.issueDetail.isEmpty, test.outcome != .launched {
            parts.append(test.issueDetail)
        }
        return parts.joined(separator: ". ")
    }

    /// The same, from an already extracted package (the tests use this).
    static func install(appID: Int, name: String, root: URL, packageName: String = "",
                        photonRealtime: String = PhotonIDs.realtime,
                        photonVoice: String = PhotonIDs.voice,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Outcome {
        var outcome = Outcome()
        // The Steam compatibility tool has its own copy of the runner. Repair it
        // before the game reads it, not only when the tool is first installed.
        _ = CompatibilityRunner.ensure()
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
        let log = PhotonLog.read(gameFolder: folder, prefix: scan.prefix)
        var plan = FixPlan.build(appID: appID, name: name, scan: scan,
                                 package: package, diagnosis: diagnosis,
                                 candidates: candidates, log: log)
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
        // A fix is not a single copy step: placing the loader can change what the
        // game imports, a proxy can reveal a second Steam API folder, and a Photon
        // chain can appear only after the loader is beside it. Read the folder again
        // after every repair, up to six rounds, instead of trusting the first read.
        var latestScan = scan
        var reported = Set<String>()
        for round in 1...6 {
            let audit = FixAudit.run(appID: appID, name: name, scan: latestScan,
                                     package: package, installed: plan,
                                     expectedAPI: expectedAPI,
                                     candidates: candidates, log: log)
            for finding in audit.findings {
                let key = finding.code + "|" + finding.title + "|" + finding.detail
                guard !reported.contains(key) else { continue }
                reported.insert(key)
                outcome.findings.append(finding)
            }
            guard audit.changed else { break }
            progress("Checking the installed fix against the game"
                + (round > 1 ? " (round \(round))" : "") + ": "
                + "\(audit.repairs.count) file(s) to put right.")
            let repaired = try FixApply.apply(audit.plan, appID: appID, folder: folder,
                                              progress: progress)
            applied = merge(applied, repaired)
            plan.notes.append(contentsOf: audit.notes)
            plan.wineDLLs = Array(Set(plan.wineDLLs + audit.plan.wineDLLs)).sorted()
            // Keep the audit's copies in the next round's installed view, or a
            // repair that fixed a file would look missing on the next read.
            for copy in audit.plan.copies where
                !plan.copies.contains(where: { $0.relative == copy.relative }) {
                plan.copies.append(copy)
            }
            for removal in audit.plan.removals where
                !plan.removals.contains(where: { $0.path == removal.path }) {
                plan.removals.append(removal)
            }
            // A Photon game whose chain only the consistency pass completed still
            // needs its app id patched, or the new plugin connects with the game's id.
            // `plan.photonSwap` was decided before the first copy, from the game's
            // log and package. An audit copy of the chain must not turn a Steam-auth
            // route into a swap: the chain is only legitimate when the route is
            // OnlineFix's shared app. Leave the flag alone.
            latestScan = GameScan.read(folder: folder, appID: appID, name: name)
        }

        // A Mac build takes the patch in its own files. The files written are what
        // the fix record holds, so the fix counts as installed (and the game stays
        // routed as itself) and a repair can put them back.
        var macWritten: [String] = []
        if plan.picoPark2, let bundle = latestScan.macBundle {
            macWritten = try MacBundlePatch.setEnabled(true, app: bundle, auth: plan.photonAuth)
        }
        var photonWritten: [String] = []
        let finalRoute = PhotonRoute.decide(
            isPhoton: latestScan.isPhoton,
            packagePresent: true,
            packageSaysPhoton: package.iniValues["photonintegration"]?.lowercased() == "true"
                || package.items.contains { $0.name == "custom.dll" },
            packageHasCustom: package.items.contains { $0.name == "custom.dll" },
            packageHasChain: package.hasPhotonChain,
            installedChain: PhotonFix.status(gameFolder: folder, fixInstalled: true).isPhoton,
            vendorLoader: PhotonChain.hasVendorLoader(in: folder, exe: latestScan.exe),
            candidates: candidates,
            usesSteamNetworking: latestScan.usesSteamNetworking,
            ownsApp: log?.ownsApp ?? PhotonLog.ownsApp(appID: appID, folder: folder,
                                                       prefix: scan.prefix),
            log: log)
        // An unowned game plays on OnlineFix's shared app, so its ids are the ones
        // written; there is no ticket of its own to keep.
        var authWritten: [String] = []
        if plan.photonSwap, finalRoute.installsOnlineFix || finalRoute.kind == .customUnlicensed {
            let shared = PhotonIDs.shared
            let wanted = finalRoute.kind == .customUnlicensed && !shared.isEmpty
                ? shared : [photonRealtime, photonVoice]
            let report = PhotonPatch.autoPatch(in: folder, realtime: wanted[0],
                                               voice: wanted.count > 1 ? wanted[1] : "")
            photonWritten = report.written
            outcome.photonTargets = report.targets
        } else if plan.photonSwap {
            plan.photonSwap = false
        }
        // The auth type is the other half: without it Photon still asks Steam to
        // vouch for a game this account does not hold.
        if let mode = plan.photonAuth {
            authWritten = try PhotonAuth.setEnabled(true, in: folder, mode: mode)
            photonWritten += authWritten
        }

        var recipe = FixRecipe(
            appID: appID, name: name, installedAt: Date(),
            packageName: package.archiveName, findings: outcome.findings,
            entries: [], removed: applied.removed,
            keepRealAppID: plan.keepRealAppID, photonSwap: plan.photonSwap,
            photonRoute: finalRoute.kind.rawValue,
            photonAuth: plan.photonAuth?.rawValue,
            picoPark2: plan.picoPark2, wineDLLs: plan.wineDLLs,
            macBuild: plan.macBuild,
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
                PhotonPatch.carries(data, id: $0)
            }
            if !carrying.isEmpty { fileIDs[relative] = carrying }
        }
        recipe.photonFileIDs = fileIDs
        recipe.notes.append(contentsOf: diagnosis.warnings.map { "\($0.code): \($0.title)." })

        // The Mac build's own files are not entries: its patch keeps the untouched
        // copies beside them, and undo and repair go through MacBundlePatch, so the
        // pack does not need a second copy of a 100 MB binary.
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
        clearLaunchWarning(recipe: &recipe, outcome: &outcome, folder: folder)
        progress("Packed the fix: \(recipe.entries.count) file(s) recorded in "
            + ".macsteam-onlinefix, so a repair needs no download.")

        outcome.files = applied.wrote.map { folder.appendingPathComponent($0.relative).path }
            + photonWritten + macWritten
        outcome.notes = recipe.notes
        outcome.keepRealAppID = plan.keepRealAppID
        outcome.installed = true
        return outcome
    }

    /// Puts the Mac build's patch back when a verify or an update took it. The files
    /// are not in the pack, so `FixPack.verify` cannot see them; this is where that
    /// half is restored, and it says so when it had work to do.
    /// Puts the Photon auth patch back if a Steam verify replaced the assembly.
    /// Photon's own answer decides the auth type. Every game ships a different app,
    /// and nothing on disk says which auth that app is registered for; the log does.
    /// When it names a refusal, the patch moves to the type that refusal implies, and
    /// the recipe keeps the new one so the next repair starts from it.
    @discardableResult
    private static func learnPhotonAuth(appID: Int, folder: URL, recipe: inout FixRecipe,
                                        outcome: inout Outcome) -> Bool {
        let log = PhotonLog.read(gameFolder: folder, prefix: nil)
        guard let evidence = log, evidence.isFailure else { return false }
        let current = recipe.photonAuth.flatMap(PhotonAuth.Mode.init(rawValue:))
            ?? PhotonAuth.observedMode(in: folder)
        guard let next = PhotonAuth.nextMode(after: evidence.failure, current: current,
                                             in: folder) else { return false }
        guard let written = try? PhotonAuth.setEnabled(true, in: folder, mode: next),
              !written.isEmpty else { return false }
        recipe.photonAuth = next.rawValue
        let said = evidence.title.lowercased()
        let was = current?.title ?? "what the game shipped"
        outcome.notes.append("Photon said \(said), so the auth type is now \(next.title) "
            + "instead of \(was); launch it again.")
        return true
    }

    private static func repatchPhotonAuth(_ recipe: FixRecipe, folder: URL,
                                          outcome: inout Outcome) -> Bool {
        guard let raw = recipe.photonAuth, let mode = PhotonAuth.Mode(rawValue: raw) else {
            return false
        }
        guard let written = try? PhotonAuth.setEnabled(true, in: folder, mode: mode),
              !written.isEmpty else { return false }
        outcome.notes.append("Put the Photon auth patch back in "
            + written.map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ") + ".")
        return true
    }

    /// Returns true when it had to write anything.
    @discardableResult
    private static func repatchMacBuild(_ recipe: FixRecipe, folder: URL,
                                        outcome: inout Outcome) -> Bool {
        guard recipe.picoPark2,
              let bundle = FixInstaller.nativeMacBundle(in: folder) else { return false }
        let auth = recipe.photonAuth.flatMap(PhotonAuth.Mode.init(rawValue:))
        guard let written = try? MacBundlePatch.setEnabled(true, app: bundle, auth: auth),
              !written.isEmpty else { return false }
        let names = written.map { URL(fileURLWithPath: $0).lastPathComponent }
        outcome.findings.removeAll { $0.code == "OF032" }
        outcome.notes.append("Put the Mac build's patch back in "
            + names.joined(separator: ", ") + " and signed it again.")
        return true
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
        let candidates = PhotonPatch.scan(in: folder)
        let log = PhotonLog.read(gameFolder: folder, prefix: scan.prefix)
        let audit = FixAudit.run(appID: appID, name: name, scan: scan, package: nil,
                                 installed: installed, expectedAPI: nil,
                                 candidates: candidates, log: log)
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
        // A repair can discover a file to move aside that the first install did
        // not know about, such as Steam restoring Unity's crash reporter. Record
        // it here or uninstall would leave it renamed.
        for removed in applied.removed where !recipe.removed.contains(removed) {
            recipe.removed.append(removed)
        }
        try? FixPack.write(recipe, in: folder)
    }

    static func repair(appID: Int, name: String) -> Outcome {
        var outcome = Outcome()
        _ = CompatibilityRunner.ensure()
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
        // A pack made by an older scanner can carry a warning the game no longer
        // justifies, such as OF035 when the game imports a doorway the package
        // actually ships. Re-read the game and drop that stale warning.
        let current = GameScan.read(folder: folder, appID: appID, name: name)
        let doorwayNames = Set(WineOverride.proxies)
        let carriedDoorways = Set(recipe.entries.map {
            ($0.path as NSString).lastPathComponent.lowercased()
        }).intersection(doorwayNames)
        if !carriedDoorways.isDisjoint(with: current.importedDLLs) {
            recipe.findings.removeAll { $0.code == "OF035" }
            outcome.findings.removeAll { $0.code == "OF035" }
            recipe.notes.removeAll { $0.hasPrefix("OF035:") }
            try? FixPack.write(recipe, in: folder)
        }

        let changed = FixPack.verify(in: folder)
        guard !changed.isEmpty else {
            // The patch a game takes in its own files is not one of the copied files,
            // so it is checked and re-applied here; every call is idempotent. A
            // repair must not stop at "no copied file changed" when the game's own
            // file lost its patch, which is exactly what a Steam verify leaves.
            ensureWine(recipe, appID: appID)
            prepareLaunchOverrides(recipe: recipe, folder: folder)
            clearLaunchWarning(recipe: &recipe, outcome: &outcome, folder: folder)
            auditRepair(&recipe, folder: folder, appID: appID, name: name, outcome: &outcome)
            recordPhotonPatch(&recipe, folder: folder)
            let macPatched = repatchMacBuild(recipe, folder: folder, outcome: &outcome)
            let authPatched = repatchPhotonAuth(recipe, folder: folder, outcome: &outcome)
            // Photon's own answer outranks the recipe's idea of which auth the game
            // wants: a game that was patched with the type its app refuses says so in
            // its log, and moving to the other type is the difference between the fix
            // working and the player seeing "CustomAuthenticationFailed".
            if learnPhotonAuth(appID: appID, folder: folder, recipe: &recipe,
                               outcome: &outcome) {
                try? FixPack.write(recipe, in: folder)
            }
            if !macPatched, !authPatched {
                outcome.notes.append("Every file the fix put in place is still there.")
            }
            return outcome
        }

        outcome.repaired = FixPack.restore(changed, in: folder)
        // A restored file is byte-for-byte the pack's copy. The recipe was written
        // against the game's old file, so update those records before verify runs
        // again, or the same files look changed forever.
        refreshEntries(outcome.repaired, recipe: &recipe, folder: folder)
        try? FixPack.write(recipe, in: folder)
        auditRepair(&recipe, folder: folder, appID: appID, name: name, outcome: &outcome)
        recordPhotonPatch(&recipe, folder: folder)
        repatchMacBuild(recipe, folder: folder, outcome: &outcome)
        repatchPhotonAuth(recipe, folder: folder, outcome: &outcome)
        ensureWine(recipe, appID: appID)
        prepareLaunchOverrides(recipe: recipe, folder: folder)
        clearLaunchWarning(recipe: &recipe, outcome: &outcome, folder: folder)

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
        // A read-only diagnosis after install has no archive open. The pack kept
        // beside the game is the same package, so use its payload rather than
        // reporting a package-less game.
        let recipe = FixPack.read(in: folder)
        let root = packageRoot ?? FixPack.folder(in: folder)
            .appendingPathComponent(FixPack.payloadName, isDirectory: true)
        let package = Paths.fm.fileExists(atPath: root.path)
            ? FixPackage.read(root: root, archiveName: recipe?.packageName ?? "")
            : nil
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
        // Packs written before the route was recorded have no field. Read the folder
        // rather than trusting the old flag: a ticket in the log outranks a swap.
        if let stored = recipe.photonRoute {
            guard stored == PhotonRoute.Kind.onlineFix.rawValue else { return }
        } else {
            let scan = GameScan.read(folder: folder, appID: recipe.appID, name: recipe.name)
            let log = PhotonLog.read(gameFolder: folder, prefix: scan.prefix)
            let route = PhotonRoute.decide(
                isPhoton: scan.isPhoton, packagePresent: true,
                installedChain: PhotonFix.status(gameFolder: folder,
                                                 fixInstalled: true).isPhoton,
                vendorLoader: PhotonChain.hasVendorLoader(in: folder, exe: scan.exe),
                usesSteamNetworking: scan.usesSteamNetworking,
                ownsApp: log?.ownsApp, log: log)
            guard route.installsOnlineFix else { return }
        }
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
                PhotonPatch.carries(data, id: $0)
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

    /// Re-reads the pack's entries after a restore. Only the paths that were
    /// actually written are touched, so a file the pack could not restore still
    /// shows up in the verify pass.
    private static func refreshEntries(_ paths: [String], recipe: inout FixRecipe,
                                       folder: URL) {
        for relative in paths {
            guard let file = FixPack.file(relative, in: folder),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, let hash = Hash.sha256(file),
                  let index = recipe.entries.firstIndex(where: { $0.path == relative })
            else { continue }
            recipe.entries[index].size = Int64(size)
            recipe.entries[index].sha256 = hash
        }
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
        // A game can keep its executable in a subfolder ("How to Fish/How to Fish.exe").
        // The DLLs are beside that executable, not at the Steam install root, so a
        // root-only existence check silently produced no launch options at all.
        let carried = Set(recipe.entries.map {
            ($0.path as NSString).lastPathComponent.lowercased()
        })
        func present(_ name: String) -> Bool {
            carried.contains(name)
                || Paths.fm.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        var names = Set(recipe.wineDLLs.map { $0.lowercased() })
        names.formUnion(WineOverride.emulators)
        for proxy in WineOverride.proxies where present(proxy) {
            names.insert(proxy)
        }
        return names
            .filter(present)
            .sorted()
            .map(WineOverride.environment)
    }

    /// The runner detects OnlineFix beside the executable and sets Wine's DLL
    /// overrides itself. Older packs also put the same list on Steam's launch
    /// options, where a semicolon list is split by /bin/sh unless every semicolon
    /// is escaped. Take that old copy out and let the runner own the environment.
    private static func prepareLaunchOverrides(recipe: FixRecipe, folder: URL) {
        let assignments = launchAssignments(recipe: recipe, folder: folder)
        guard !assignments.isEmpty else { return }
        NSLog("OnlineFixLaunch clear app=%d dlls=%@", recipe.appID,
              assignments.joined(separator: ","))
        clearLaunchOverrides(appID: recipe.appID, assignments: assignments)
    }

    /// Old packs could leave OF111 behind when Steam's config was unreadable. The
    /// warning no longer applies because the launch options are not the mechanism.
    private static func clearLaunchWarning(recipe: inout FixRecipe, outcome: inout Outcome,
                                           folder: URL) {
        guard recipe.findings.contains(where: { $0.code == "OF111" }) else { return }
        recipe.findings.removeAll { $0.code == "OF111" }
        outcome.findings.removeAll { $0.code == "OF111" }
        recipe.notes.removeAll { $0.hasPrefix("OF111:") }
        try? FixPack.write(recipe, in: folder)
    }

    private static func clearLaunchOverrides(appID: Int, assignments: [String]) {
        guard !assignments.isEmpty else { return }
        guard let clearer = OnlineFixLaunchBridge.clearer else {
            _ = LaunchOptionsStore.clear(appID: appID, assignments: assignments)
            return
        }
        Task.detached(priority: .utility) {
            let cleared = await clearer(appID, assignments)
            if !cleared {
                _ = LaunchOptionsStore.clear(appID: appID, assignments: assignments)
            }
        }
    }
}
