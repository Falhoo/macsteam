// The things a script needs from the app, without a window.
//
// They are what scripts/onlinefix-lab.sh calls: one to get back to a machine with no
// OnlineFix, one to put a fix on a game again, and one to read a game's Photon ids
// without touching them.
import Foundation

public enum OnlineFixCommand {

    /// Removes OnlineFix and nothing else. Prints the report and returns an exit code.
    public static func uninstall(keepGameFiles: Bool) -> Int32 {
        var options = OnlineFixRemoval.Options()
        options.restoreGameFiles = !keepGameFiles
        let report = OnlineFixRemoval.run(options: options)
        print(report.summary)
        return report.failures.isEmpty ? 0 : 1
    }

    /// Takes the fix off one game, keeping the rest of the library alone. This is
    /// the app's own uninstall path, so the manager's record and routing go with it.
    @MainActor
    public static func uninstallGame(appID: Int, name: String = "") -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        let outcome = OnlineFixEmbed.storeUninstall(appID: appID)
        if let error = outcome.error {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            return 1
        }
        if let message = outcome.message { print(message) }
        else { print("Removed the fix for \(display).") }
        return 0
    }

    /// Installs the fix for one AppID the way the app's own install does, printing
    /// each step, and returns an exit code.
    @MainActor
    public static func install(appID: Int, name: String) async -> Int32 {
        let model = AppModel()
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (model.games.first { $0.id == appID }?.name ?? "App \(appID)")
            : name
        let outcome = await model.installFromStore(appID: appID, name: display, confirmed: true,
                                                   progress: { print($0) })
        if let error = outcome.error {
            FileHandle.standardError.write(Data((error + "\n").utf8))
            return 1
        }
        if let message = outcome.message { print(message) }
        // The window patches the game's Photon id and writes its record in the
        // background; a script needs that finished before it launches the game.
        await model.finishPhotonPatch(appID: appID, name: display)
        if !model.fixMessage.isEmpty { print(model.fixMessage) }
        if outcome.installed {
            let tested = await model.testInstalledFix(appID: appID, name: display) { print($0) }
            print(tested)
            print("The fix for \(display) is installed.")
        }
        return outcome.installed ? 0 : 1
    }

    /// Reads the Photon app ids a game's files carry and says what the automatic patch
    /// would do with them, writing nothing. This is the read-only half of the lab: a
    /// wrong guess shows up here, before any file is changed.
    public static func photonIDs(appID: Int, name: String = "") -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        print("\(display) (\(appID))")
        print("folder: \(folder.path)")
        print("Photon game: \(PhotonFix.isPhotonGame(in: folder) ? "yes" : "no")")

        let candidates = PhotonPatch.scan(in: folder)
        let ids = Set(candidates.map(\.id))
        print(ids.isEmpty ? "Photon app ids found: none"
                          : "Photon app ids found: \(ids.count)")
        for candidate in candidates {
            let path = candidate.file.path
            let relative = path.hasPrefix(folder.path + "/")
                ? String(path.dropFirst(folder.path.count + 1)) : path
            let kind = candidate.kind == .guid ? "GUID" : "Quantum"
            let shared = candidate.isOnlineFixShared ? "  (OnlineFix's already)" : ""
            print("  \(kind)  \(candidate.id)  \(relative)\(shared)")
        }

        if let mac = FixInstaller.nativeMacBundle(in: folder) {
            print("Mac build: \(mac.lastPathComponent), which starts as itself and takes "
                + "the patch in its own files rather than the fix's Windows ones")
        }

        let plan = PhotonPatch.plan(for: candidates)
        if let skipped = plan.skipped {
            print("Automatic patch: \(skipped)")
        } else if let id = plan.id, let target = plan.target {
            var line = "would replace \(id) with \(target)"
            if let voiceID = plan.voiceID, let voiceTarget = plan.voiceTarget {
                line += ", and the voice id \(voiceID) with \(voiceTarget)"
            }
            print("Automatic patch: \(line)")
        } else {
            print("Automatic patch: nothing to do")
        }
        return 0
    }

    /// Reads a Mac build and says what the patch would do with it, writing nothing:
    /// --onlinefix-mac-patch <folder> (read only unless --apply is given).
    ///
    /// The folder is a game folder, not a bundle: the bundle inside it is found the
    /// same way the install finds it.
    public static func macPatch(folder: URL, apply: Bool, off: Bool) -> Int32 {
        guard let bundle = FixInstaller.nativeMacBundle(in: folder) else {
            FileHandle.standardError.write(Data(
                "No macOS app bundle in \(folder.path).\n".utf8))
            return 1
        }
        let profile = MacBundlePatch.profile(for: bundle)
        print("bundle: \(bundle.path)")
        print("profile: \(profile?.name ?? "none (the Photon app id alone)")")
        let state = MacBundlePatch.state(of: bundle)
        print("can patch: \(state.canPatch ? "yes" : "no"), patched: \(state.isPatched ? "yes" : "no")")
        for id in state.photonIDs { print("Photon app id: \(id)") }
        if let message = state.message { print("message: \(message)") }
        guard apply else { return 0 }
        do {
            let written = try MacBundlePatch.setEnabled(!off, app: bundle)
            print(written.isEmpty ? "nothing to change" : "wrote:")
            for path in written { print("  \(path)") }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    /// Reports every piece of Photon evidence and the route it selects, writing
    /// nothing: --onlinefix-photon-audit <appid> [--name <name>].
    public static func photonAudit(appID: Int, name: String = "",
                                   folder override: URL? = nil) -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        let folder = override ?? Store.gameFolder(for: appID, name: display)
        guard let folder else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: display)
        let candidates = PhotonPatch.scan(in: folder)
        let status = PhotonFix.status(gameFolder: folder,
                                      fixInstalled: PhotonFix.isPhotonGame(in: folder))
        let log = PhotonLog.read(gameFolder: folder, prefix: scan.prefix)
        let route = PhotonRoute.decide(
            isPhoton: scan.isPhoton || status.isPhoton,
            packagePresent: status.isPhoton,
            installedChain: status.isPhoton,
            vendorLoader: PhotonChain.hasVendorLoader(in: folder, exe: scan.exe),
            candidates: candidates,
            usesSteamNetworking: scan.usesSteamNetworking,
            log: log)

        print("\(display) (\(appID))")
        print("folder: \(folder.path)")
        print("Unity: \(scan.unityVersion ?? "unknown")")
        print("route: \(route.kind.rawValue)  (\(route.title))")
        print("Photon: \(route.isPhoton ? "yes" : "no")  "
            + "Steam networking: \(route.usesSteamNetworking ? "yes" : "no")  "
            + "Steam ticket: \(route.requestsSteamTicket ? "yes" : "no")")
        print("OnlineFix chain: \(status.isPhoton ? "present" : "absent")"
            + (status.missing.isEmpty ? "" : " (missing: \(status.missing.map(\.name).joined(separator: ", ")))"))
        print("own app ids: \(route.ownIDs.isEmpty ? "none" : route.ownIDs.joined(separator: ", "))")
        print("shared app ids: \(route.sharedIDs.isEmpty ? "none" : route.sharedIDs.joined(separator: ", "))")
        for reason in route.reasons { print("  evidence: \(reason)") }
        if let log {
            print("log: \(log.source.path)")
            print("  \(log.detail)")
        } else {
            print("log: none")
        }
        switch route.kind {
        case .steamAuth:
            print("install: keep the game's own ids, keep the real AppID, no chain")
        case .onlineFix:
            print("install: OnlineFix's chain and shared Photon app")
        case .nativeCustom:
            print("install: keep the game's own ids, no chain")
        case .ambiguous:
            print("install: nothing until the conflicting evidence is resolved")
        case .notPhoton:
            print("install: no Photon route")
        }
        return 0
    }

    /// Reports what a game and a fix package need, writing nothing. This is the lab's
    /// read-only check, and what tells a player why a fix will not work.
    public static func diagnose(appID: Int, name: String = "", packageRoot: URL? = nil) -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        print("\(display) (\(appID))")
        print("folder: \(folder.path)")

        let (scan, diagnosis) = FixService.diagnose(appID: appID, name: display,
                                                    packageRoot: packageRoot)
        if let scan {
            print("engine: \(scan.engine.name), \(scan.is64Bit ? "64" : "32")-bit")
            print("starts from: \(scan.launchFolder.path)")
            print("Photon: \(scan.isPhoton ? "yes" : "no")  "
                + "Steam networking: \(scan.usesSteamNetworking ? "yes" : "no")")
        }
        if let pack = FixPack.read(in: folder) {
            let changed = FixPack.verify(in: folder)
            print("pack: \(pack.summary)")
            print(changed.isEmpty ? "pack state: every file in place"
                                  : "pack state: \(changed.count) changed: " + changed.joined(separator: ", "))
        } else {
            print("pack: none")
        }

        if diagnosis.findings.isEmpty { print("findings: none") }
        for finding in diagnosis.findings {
            print("  \(finding.code) [\(finding.level.rawValue)] \(finding.title)")
            print("      \(finding.detail)")
            print("      -> \(finding.remedy)")
        }
        return diagnosis.isBlocked ? 1 : 0
    }

    /// Keeps the game's own Steam API and relies on the routing, for a game whose fix
    /// loader never opens it. Prints what it did and returns an exit code.
    public static func routingOnly(appID: Int, name: String = "") -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        let outcome = FixService.routingOnly(appID: appID, name: display)
        print("\(display): \(outcome.message)")
        return outcome.error == nil ? 0 : 1
    }

    /// Launches the game through Steam and reports whether its window appeared.
    public static func probe(appID: Int, name: String = "", seconds: Double = 75,
                            settle: Double = 0) -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let exe = GameScan.read(folder: folder, appID: appID, name: display).exe
        print("Launching \(display) through Steam and watching for its window…")
        let result = LaunchProbe.run(appID: appID, name: display, exe: exe,
                                     seconds: seconds, settle: settle)
        print(result.note)
        return result.opened ? 0 : 1
    }

    /// The install test without a window: launch once, read the real failure, and
    /// optionally apply one safe repair and retest.
    @MainActor
    public static func test(appID: Int, name: String = "", seconds: Double = 120,
                            settle: Double = 12, repair: Bool = false) async -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: display)
        var result = await LaunchTest.run(appID: appID, name: display, exe: scan.exe,
                                          timeout: seconds, settle: settle,
                                          progress: { print($0) })
        print(result.message)
        if result.outcome == .failed, result.issue.repairable, repair {
            let applied = LaunchTestRepair.apply(result, appID: appID, name: display,
                                                progress: { print($0) })
            print(applied.notes.joined(separator: " "))
            if applied.changed {
                print("Testing again after the repair…")
                result = await LaunchTest.run(appID: appID, name: display, exe: scan.exe,
                                              timeout: seconds, settle: settle,
                                              progress: { print($0) })
                print(result.message)
            }
        }
        if var recipe = FixPack.read(in: folder) {
            recipe.launchTest = result
            try? FixPack.writeRecipe(recipe, in: folder)
        }
        if !result.evidence.isEmpty {
            print("Evidence:")
            for line in result.evidence.suffix(12) { print("  \(line)") }
        }
        return result.opened ? 0 : 1
    }

    /// What the game's own log says Photon made of its last connection. Read only:
    /// the log is the game's, and this only says what it means.
    public static func photon(appID: Int, name: String = "") -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: display)
        print("\(display) (\(appID))")
        print("Photon game: \(scan.isPhoton ? "yes" : "no")")
        guard let evidence = PhotonLog.read(gameFolder: folder, prefix: scan.prefix) else {
            print("log: none yet. Launch the game once, then run this again.")
            return 1
        }
        print("log: \(evidence.source.path)")
        if let ranAs = evidence.ranAs { print("ran as AppID: \(ranAs)") }
        if let code = evidence.returnCode {
            print("Photon answered: \(code)" + (evidence.message.map { " (\($0))" } ?? ""))
        }
        print("verdict: \(evidence.title)")
        print("  \(evidence.detail)")
        print("  -> \(evidence.remedy)")
        if !evidence.lines.isEmpty {
            print("lines:")
            for line in evidence.lines { print("  \(line)") }
        }
        return evidence.isFailure ? 1 : 0
    }

    /// Puts the complete BepInEx chain OnlineFix's Photon patch needs into a game that
    /// already has its fix. A package that carries only the plugin and the preloader,
    /// or a doorway the game never imports, looks installed and patches nothing.
    public static func photonChain(appID: Int, name: String = "") -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let scan = GameScan.read(folder: folder, appID: appID, name: display)
        guard scan.isPhoton else {
            print("\(display) is not a Photon game, so it has no patch to load.")
            return 1
        }
        guard let bundle = PhotonChain.bundle() else {
            FileHandle.standardError.write(Data(
                "This build carries no Photon chain (Resources/photon is missing).\n".utf8))
            return 1
        }
        let doorway = PhotonChain.doorway(in: folder, exe: scan.exe)
        print("\(display) (\(appID))")
        print("folder: \(folder.path)")
        print("doorway this game imports: \(doorway ?? "none of winhttp, winmm, version")")
        let missing = PhotonChain.missing(in: folder, doorway: doorway)
        if missing.isEmpty {
            // The files are there; the prefix may still load its own copy of the
            // doorway, which is the half that is easy to miss.
            if let doorway, WineOverride.prefix(appID: appID) != nil {
                let ok = WineOverride.ensure(appID: appID, dll: doorway,
                                            native: WineOverride.needsNative(doorway))
                print(ok ? "Prefix: loads \(doorway) from the game folder."
                         : "Prefix: would not take the \(doorway) override.")
            }
            print("The chain is complete: BepInEx and the Photon patch are in place.")
            return 0
        }
        print("missing: \(missing.count) file(s): \(missing.joined(separator: ", "))")
        do {
            let written = try PhotonChain.install(into: folder, from: bundle, doorway: doorway,
                                                 appID: appID, progress: { print($0) })
            print("Wrote \(written.count) file(s). Launch \(display) once, then run "
                + "--onlinefix-photon \(appID) to see what Photon answered.")
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    /// Replaces the Photon app id a game carries with OnlineFix's, which is the app the
    /// other OnlineFix copies meet on. A game with several ids needs the one named.
    public static func photonSwap(appID: Int, name: String = "", id: String? = nil) -> Int32 {
        let stored = Store.load().games.first { $0.id == appID }?.name ?? ""
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = typed.isEmpty ? (stored.isEmpty ? "App \(appID)" : stored) : typed
        guard let folder = Store.gameFolder(for: appID, name: display) else {
            FileHandle.standardError.write(Data(
                "\(display) (\(appID)) has no folder in this Steam library.\n".utf8))
            return 1
        }
        let candidates = PhotonPatch.scan(in: folder)
        print("\(display) (\(appID))")
        for candidate in candidates {
            print("  \(candidate.kind == .guid ? "GUID" : "Quantum")  \(candidate.id)"
                + "  \(candidate.file.lastPathComponent)"
                + (candidate.isOnlineFixShared ? "  (OnlineFix's already)" : ""))
        }
        let old: String
        if let id, !id.isEmpty {
            guard candidates.contains(where: { $0.id.lowercased() == id.lowercased() }) else {
                FileHandle.standardError.write(Data(
                    "This game does not carry \(id).\n".utf8))
                return 1
            }
            old = id
        } else {
            guard let first = candidates.first(where: { !$0.isOnlineFixShared }) else {
                print(candidates.isEmpty
                    ? "No Photon app id found in this game's files."
                    : "Every id found is OnlineFix's already.")
                return candidates.isEmpty ? 1 : 0
            }
            old = first.id
        }
        let new = PhotonPatch.onlineFixID(for: candidates.first { $0.id == old }?.kind ?? .guid)
        print("replacing \(old) with \(new)")
        do {
            let written = try PhotonPatch.replace(old, with: new, in: folder)
            for path in written { print("  wrote \(path)") }
            print(written.isEmpty ? "Nothing was changed." : "Done. Launch the game, then run "
                + "--onlinefix-photon \(appID).")
            return written.isEmpty ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    /// Puts back anything a fix pack says has changed, for one game or for all of them.
    public static func repair(appID: Int? = nil) -> Int32 {
        let stored = Store.load()
        var failed = false
        if let appID {
            let name = stored.games.first { $0.id == appID }?.name ?? "App \(appID)"
            let outcome = FixService.repair(appID: appID, name: name)
            print("\(name): \(outcome.message)")
            failed = outcome.error != nil
        } else {
            let results = FixService.verifyAll(games: stored.games, fixes: stored.fixes)
            if results.isEmpty {
                print("Every fix pack matches its game folder.")
            }
            for (id, outcome) in results.sorted(by: { $0.key < $1.key }) {
                print("\(id): \(outcome.message)")
                if outcome.error != nil { failed = true }
            }
        }
        return failed ? 1 : 0
    }
}
