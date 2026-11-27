// The post-install pass: read the game and the fix as they now sit on disk, find
// what does not line up, and build a second plan that puts it right.
//
// The pre-install diagnosis can only reason about the package and the game before
// anything is copied. This runs after the package's files are in place, so it sees
// what actually landed: a payload a partial extraction left out, a proxy the game
// never imports, a Steam API DLL in the folder Windows does not read, a Photon
// plugin outside the folder BepInEx loads, an ini whose Photon switch is off. Every
// repair is a normal FixPlan copy, removal, edit or override, so uninstall restores
// exactly the same backups as an install.
//
// Nothing here is per game. The rules are about roles (payload, proxy, API, plugin,
// ini, list, prefix), and a new OnlineFix package exercises the same code.
import Foundation

enum FixAudit {

    struct Report: Sendable {
        var findings: [FixFinding] = []
        var plan = FixPlan()
        var notes: [String] = []
        /// True when a problem has no repair with the files at hand.
        var blocking: Bool {
            findings.contains { $0.level == .blocking }
        }

        var repairs: [String] { plan.copies.map(\.relative).sorted() }
        var changed: Bool {
            !plan.isEmpty || !plan.wineDLLs.isEmpty || !plan.stubOverlay.isEmpty
        }
    }

    // MARK: - Entry point

    /// Reads the installed fix and the game, then returns the repairs it would make.
    /// The caller applies them with the same FixApply an install uses.
    static func run(appID: Int, name: String, scan: GameScan, package: FixPackage?,
                    installed: FixPlan? = nil, expectedAPI: URL? = nil,
                    candidates: [PhotonPatch.Candidate] = [],
                    log: PhotonLog.Evidence? = nil) -> Report {
        var report = Report()
        // A Mac build loads none of these files. The plan leaves it alone, and the
        // audit must too, or installing a Windows fix would scatter DLLs in the app.
        // What the build does take is the patch in its own files, and a Steam update or
        // verify puts those back, so that is what is checked here. The repair is not a
        // copy: `FixService` applies it again once this pass has run.
        if let bundle = scan.macBundle {
            let state = MacBundlePatch.state(of: bundle)
            // Only a build the fix was already put into can have lost the patch; on a
            // first install the bundle is expected to be stock.
            let wasPatched = FixPack.read(in: scan.folder)?.picoPark2 == true
            if state.canPatch, !state.isPatched, wasPatched {
                report.findings.append(FixFinding(
                    code: "OF032", level: .warning,
                    title: "The Mac build's patch is gone",
                    detail: "Steam put \(bundle.lastPathComponent)'s own files back, so the "
                        + "Photon app id it needs is no longer in the bundle.",
                    remedy: "Writes the patch into the bundle again and signs it"))
                report.notes.append("\(name)'s Mac build takes its patch again: Steam put "
                    + "the game's own files back.")
            } else if state.canPatch {
                report.notes.append("\(name)'s Mac build takes its patch in its own files.")
            }
            return report
        }
        let launch = scan.launchFolder
        let folder = scan.folder
        // A routing fix deliberately leaves the loader out and keeps the game's own
        // Steam API. The audit must not put the loader back: that is the state the
        // player chose.
        let routingOnly = installed?.keepGameAPI == true

        func exists(_ url: URL?) -> Bool {
            guard let url else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }

        /// Where a copy can come from when the file is missing: the package first,
        /// then the pack this app wrote, then the chain bundled with the app.
        func addCopy(_ source: URL, to destination: URL, code: String, title: String,
                     detail: String, remedy: String) {
            let relative = FixPlan.relative(destination, in: folder)
            if report.plan.copies.contains(where: {
                $0.destination.standardizedFileURL.path == destination.standardizedFileURL.path
            }) {
                return
            }
            report.plan.copies.append(FixPlan.Copy(source: source, destination: destination,
                                                   relative: relative))
            report.findings.append(FixFinding(code: code, level: .warning, title: title,
                                              detail: detail, remedy: remedy))
        }

        /// True only for a native DLL whose architecture cannot load in this game.
        /// A managed assembly is AnyCPU and is left to the runtime.
        func wrongBitness(_ url: URL, needs64: Bool) -> Bool {
            guard let pe = PortableExecutable.read(url), !pe.isManaged else { return false }
            return needs64 ? !pe.is64BitNative : !pe.is32BitNative
        }

        func missingExports(_ needed: Set<String>,
                            from pe: PortableExecutable) -> [String] {
            needed.filter { !pe.covers($0) }.sorted()
        }

        func hasEdit(_ kind: FixPlan.Edit.Kind, at url: URL) -> Bool {
            report.plan.edits.contains { $0.kind == kind && $0.path.path == url.path }
        }

        func addEdit(_ kind: FixPlan.Edit.Kind, at url: URL, code: String, title: String,
                     detail: String, remedy: String, names: [String] = [],
                     allowMissing: Bool = false) {
            let willExist = allowMissing || exists(url) || report.plan.copies.contains {
                $0.destination.standardizedFileURL.path == url.standardizedFileURL.path
            }
            guard willExist, !hasEdit(kind, at: url) else { return }
            report.plan.edits.append(FixPlan.Edit(kind: kind, path: url, names: names))
            report.findings.append(FixFinding(code: code, level: .warning, title: title,
                                              detail: detail, remedy: remedy))
        }

        // MARK: The files the package placed

        let apiNames: Set<String> = ["steam_api64.dll", "steam_api.dll"]
        if let installed {
            for copy in installed.copies {
                let target = copy.destination
                guard !exists(target) else { continue }
                // The role checks below know the game's bitness. Re-copying one of
                // these here would put a wrong build back before they can refuse it.
                let name = target.lastPathComponent.lowercased()
                let isRoleFile = apiNames.contains(name)
                    || FixPackage.payloadNames.contains(name)
                    || PortableExecutable.read(copy.source)?.exportsOnlineFix == true
                guard !isRoleFile else { continue }
                guard FileManager.default.fileExists(atPath: copy.source.path) else {
                    report.findings.append(FixFinding(
                        code: "OF100", level: .blocking,
                        title: "The package is missing \(copy.relative)",
                        detail: "\(target.lastPathComponent) is not in the game folder and the "
                            + "package does not carry it either.",
                        remedy: "Download the fix package again and install it."))
                    continue
                }
                addCopy(copy.source, to: target, code: "OF100",
                        title: "The fix is incomplete",
                        detail: "\(copy.relative) is missing from the game folder after the copy.",
                        remedy: "Copy it back from the package, then check the rest of the fix.")
            }
        }

        // MARK: The Steam API

        let expectedName = scan.is64Bit ? "steam_api64.dll" : "steam_api.dll"
        let installedAPI = installed?.copies.first {
            apiNames.contains($0.destination.lastPathComponent.lowercased())
        }?.destination
        let apiDestination = installedAPI
            ?? expectedAPI
            ?? scan.apiFolder?.appendingPathComponent(expectedName)
            ?? launch.appendingPathComponent(expectedName)
        if !routingOnly, let api = package?.apiItem(needs64: scan.is64Bit) {
            if wrongBitness(api.url, needs64: scan.is64Bit) {
                report.findings.append(FixFinding(
                    code: "OF101", level: .blocking,
                    title: "The package's Steam API is the wrong bitness",
                    detail: "\(api.url.lastPathComponent) is not a \(scan.is64Bit ? "64" : "32")-bit "
                        + "DLL, so the game cannot load it.",
                    remedy: "Use the package made for this build of the game."))
            } else if !exists(apiDestination) {
                addCopy(api.url, to: apiDestination, code: "OF106",
                        title: "The game's Steam API is not where it loads it",
                        detail: "\(apiDestination.lastPathComponent) is missing from "
                            + "\(apiDestination.deletingLastPathComponent().lastPathComponent), "
                            + "the folder Windows searches first.",
                        remedy: "Copy the fix's Steam API DLL there.")
            } else if wrongBitness(apiDestination, needs64: scan.is64Bit) {
                // The package has the matching build, so replacing the wrong copy is a
                // real repair. The old file is kept as .onlinefix-backup like any copy.
                addCopy(api.url, to: apiDestination, code: "OF101",
                        title: "The Steam API DLL has the wrong bitness",
                        detail: "\(apiDestination.lastPathComponent) cannot load in a "
                            + "\(scan.is64Bit ? "64" : "32")-bit game.",
                        remedy: "Put the package's matching Steam API DLL in its place.")
            }
        } else if !routingOnly, !exists(apiDestination),
                  package?.apiItem(needs64: !scan.is64Bit) != nil {
            report.findings.append(FixFinding(
                code: "OF101", level: .blocking,
                title: "The package has no \(scan.is64Bit ? "64" : "32")-bit Steam API",
                detail: "The game runs as \(scan.is64Bit ? "64" : "32")-bit, and the package only "
                    + "carries the other build.",
                remedy: "Use the package made for this build of the game."))
        }
        if exists(apiDestination), let pe = PortableExecutable.read(apiDestination),
           !pe.isManaged {
            let wrong = scan.is64Bit ? !pe.is64BitNative : !pe.is32BitNative
            let willReplace = report.plan.copies.contains {
                $0.destination.standardizedFileURL.path == apiDestination.standardizedFileURL.path
            }
            if wrong, !willReplace {
                report.findings.append(FixFinding(
                    code: "OF101", level: .blocking,
                    title: "The Steam API DLL has the wrong bitness",
                    detail: "\(apiDestination.lastPathComponent) is "
                        + "\(pe.architecture.rawValue) but the game runs as "
                        + "\(scan.is64Bit ? "64" : "32")-bit.",
                    remedy: "Use the package made for this build of the game."))
            }
        }

        // OF112: the file has the right name and bitness but not the function
        // this game imports. Windows stops while loading the DLL, so no amount
        // of file placement repairs it.
        let apiToCheck = report.plan.copies.first {
            $0.destination.standardizedFileURL.path == apiDestination.standardizedFileURL.path
        }?.source ?? apiDestination
        if let pe = PortableExecutable.read(apiToCheck), !pe.isManaged,
           let needed = scan.coreImportedFunctions[expectedName], !needed.isEmpty {
            let missing = missingExports(needed, from: pe)
            if !missing.isEmpty {
                report.findings.append(FixFinding(
                    code: "OF112", level: .blocking,
                    title: "The fix's Steam API is missing a function the game imports",
                    detail: "\(expectedName) does not export "
                        + missing.prefix(4).joined(separator: ", ")
                        + (missing.count > 4 ? " and \(missing.count - 4) more" : "")
                        + ", which the game's import table names.",
                    remedy: "Use the package made for this build of the game."))
            }
        }

        // The dynamic path when the API is already installed and no package
        // source is available to inspect.
        if let pe = PortableExecutable.read(apiToCheck), !pe.isManaged,
           package?.isGDK != true {
            let required = ["SteamAPI_GetHSteamPipe", "SteamAPI_GetHSteamUser",
                            "SteamAPI_Shutdown"]
            var missing = required.filter { !pe.covers($0) }
            if !pe.covers("SteamAPI_Init") && !pe.covers("SteamInternal_SteamAPI_Init") {
                missing.append("SteamAPI_Init")
            }
            if !missing.isEmpty {
                report.findings.append(FixFinding(
                    code: "OF112", level: .blocking,
                    title: "The fix's Steam API is missing a core function",
                    detail: "\(expectedName) does not export "
                        + missing.joined(separator: ", ")
                        + ", which the game uses to start and stop Steam.",
                    remedy: "Use the package made for this build of the game."))
            }
        }

        let apis = Dictionary(grouping: scan.apiDLLs) { $0.lastPathComponent.lowercased() }
        for (name, copies) in apis where copies.count > 1 {
            let paths = copies.map { FixPlan.relative($0, in: folder) }.sorted()
            report.findings.append(FixFinding(
                code: "OF107", level: .warning,
                title: "More than one \(name) is in the game",
                detail: "Windows loads the first copy it finds, so one of these is ignored: "
                    + paths.joined(separator: ", ") + ".",
                remedy: "Keep the copy the game loads in "
                    + "\(apiDestination.deletingLastPathComponent().lastPathComponent) "
                    + "and remove the stale one."))
        }

        // MARK: The loader and its door

        let packageItems = package?.items ?? []
        let payloads = packageItems.filter { FixPackage.payloadNames.contains($0.name) }
        var rootCustomPatch = exists(launch.appendingPathComponent("Custom.dll"))
            || report.plan.copies.contains {
                $0.destination.lastPathComponent.lowercased() == "custom.dll"
                    && $0.destination.deletingLastPathComponent().standardizedFileURL
                        == launch.standardizedFileURL
            }
        let customPatch = rootCustomPatch
            || exists(launch.appendingPathComponent(PhotonChain.plugin))
            || report.plan.copies.contains {
                $0.destination.lastPathComponent.lowercased() == "custom.dll"
            }
        for payload in payloads where !routingOnly {
            let target = launch.appendingPathComponent(payload.url.lastPathComponent)
            if !exists(target) {
                if wrongBitness(payload.url, needs64: scan.is64Bit) {
                    report.findings.append(FixFinding(
                        code: "OF101", level: .blocking,
                        title: "The package's OnlineFix payload is the wrong bitness",
                        detail: "\(payload.url.lastPathComponent) cannot load in a "
                            + "\(scan.is64Bit ? "64" : "32")-bit game.",
                        remedy: "Use the package made for this build of the game."))
                    continue
                }
                addCopy(payload.url, to: target, code: "OF100",
                        title: "The OnlineFix payload is missing",
                        detail: "\(target.lastPathComponent) is not beside the executable.",
                        remedy: "Copy the payload back from the package.")
            }
            if let pe = PortableExecutable.read(target), !pe.isManaged {
                let wrong = scan.is64Bit ? !pe.is64BitNative : !pe.is32BitNative
                if !wrong, !pe.exportsOnlineFix {
                    if PortableExecutable.read(payload.url)?.exportsOnlineFix == true {
                        addCopy(payload.url, to: target, code: "OF100",
                                title: "The OnlineFix payload cannot be started",
                                detail: "\(target.lastPathComponent) has no OnlineFix export.",
                                remedy: "Put the package's payload back.")
                    } else {
                        report.findings.append(FixFinding(
                            code: "OF112", level: .blocking,
                            title: "The fix payload does not export OnlineFix",
                            detail: "\(target.lastPathComponent) has no OnlineFix export, "
                                + "so the doorway cannot start it.",
                            remedy: "Use the package's real OnlineFix payload."))
                    }
                }
                if wrong {
                    if !wrongBitness(payload.url, needs64: scan.is64Bit) {
                        addCopy(payload.url, to: target, code: "OF101",
                                title: "The OnlineFix payload has the wrong bitness",
                                detail: "\(target.lastPathComponent) is \(pe.architecture.rawValue), "
                                    + "which the \(scan.is64Bit ? "64" : "32")-bit game cannot load.",
                                remedy: "Put the package's matching payload in its place.")
                    } else {
                        report.findings.append(FixFinding(
                            code: "OF101", level: .blocking,
                            title: "The OnlineFix payload has the wrong bitness",
                            detail: "\(target.lastPathComponent) is \(pe.architecture.rawValue), "
                                + "which the \(scan.is64Bit ? "64" : "32")-bit game cannot load.",
                            remedy: "Use the package made for this build of the game."))
                    }
                }
            }
        }

        // A proxy is a package DLL that exports OnlineFix. Its own name is the import
        // the game must make, whatever that name is.
        let proxies = packageItems.filter { item in
            guard item.name.hasSuffix(".dll"),
                  !FixPackage.payloadNames.contains(item.name),
                  !FixPackage.apiNames.contains(item.name),
                  item.name != "steamoverlay64.dll",
                  !FixPackage.isChainPath(item.relative)
            else { return false }
            return PortableExecutable.read(item.url)?.exportsOnlineFix == true
        }
        let importedProxies = proxies.filter { scan.importedDLLs.contains($0.name) }
        for proxy in importedProxies where !routingOnly {
            let target = launch.appendingPathComponent(proxy.url.lastPathComponent)
            if !exists(target) {
                if wrongBitness(proxy.url, needs64: scan.is64Bit) {
                    report.findings.append(FixFinding(
                        code: "OF101", level: .blocking,
                        title: "The package's doorway is the wrong bitness",
                        detail: "\(proxy.url.lastPathComponent) cannot load in a "
                            + "\(scan.is64Bit ? "64" : "32")-bit game.",
                        remedy: "Use the package made for this build of the game."))
                    continue
                }
                addCopy(proxy.url, to: target, code: "OF102",
                        title: "The fix's doorway is missing",
                        detail: "The game imports \(target.lastPathComponent), but the fix's "
                            + "copy of it is not beside the executable.",
                        remedy: "Copy the proxy back from the package.")
            }
            if let pe = PortableExecutable.read(target), !pe.isManaged {
                let wrong = scan.is64Bit ? !pe.is64BitNative : !pe.is32BitNative
                if wrong {
                    if !wrongBitness(proxy.url, needs64: scan.is64Bit) {
                        addCopy(proxy.url, to: target, code: "OF101",
                                title: "The fix's doorway has the wrong bitness",
                                detail: "\(target.lastPathComponent) is \(pe.architecture.rawValue), "
                                    + "but the game is \(scan.is64Bit ? "64" : "32")-bit.",
                                remedy: "Put the package's matching doorway in its place.")
                    } else {
                        report.findings.append(FixFinding(
                            code: "OF101", level: .blocking,
                            title: "The fix's doorway has the wrong bitness",
                            detail: "\(target.lastPathComponent) is \(pe.architecture.rawValue), "
                                + "but the game is \(scan.is64Bit ? "64" : "32")-bit.",
                            remedy: "Use the package made for this build of the game."))
                    }
                }
            }
            // OF112: the doorway exports OnlineFix but not a function this
            // game calls. Loading stops at the import table.
            let proxyToCheck = report.plan.copies.first {
                $0.destination.standardizedFileURL.path == target.standardizedFileURL.path
            }?.source ?? target
            if let pe = PortableExecutable.read(proxyToCheck), !pe.isManaged,
               let needed = scan.coreImportedFunctions[proxy.name], !needed.isEmpty {
                let missing = missingExports(needed, from: pe)
                if !missing.isEmpty {
                    report.findings.append(FixFinding(
                        code: "OF112", level: .blocking,
                        title: "The fix's \(proxy.name) is missing a function the game imports",
                        detail: "\(proxy.name) does not export "
                            + missing.prefix(4).joined(separator: ", ")
                            + (missing.count > 4 ? " and \(missing.count - 4) more" : "")
                            + ", which the game's import table names.",
                        remedy: "Use a package whose doorway covers this game."))
                }
            }
            if !report.plan.wineDLLs.contains(target.lastPathComponent.lowercased()) {
                report.plan.wineDLLs.append(target.lastPathComponent.lowercased())
            }
        }

        let installedDoorways = FixPackage.loaderNames.filter {
            $0.hasSuffix(".dll") && scan.importedDLLs.contains($0)
                && exists(launch.appendingPathComponent($0))
        }
        if !routingOnly, !payloads.isEmpty, importedProxies.isEmpty, installedDoorways.isEmpty,
           scan.importedDLLs.isDisjoint(with: FixPackage.loaderNames) {
            report.findings.append(FixFinding(
                code: "OF102", level: .warning,
                title: "The game does not import the fix's doorway",
                detail: "OnlineFix starts through a DLL the game imports, and this game's "
                    + "import table names none of the fix's proxies.",
                remedy: "The Steam API replacement can still work; if the game has no online "
                    + "play, run it with its own API and macSteam's routing."))
        }

        // A steam_appid.txt beside the executable overrides the AppID Steam passes
        // to the game. If the package left one naming another game, the fix and the
        // real game authenticate as two different apps.
        if let file = scan.steamAppIDFile, let id = scan.steamAppID,
           id != appID, id != 480 {
            addEdit(.steamAppID, at: file, code: "OF018",
                    title: "steam_appid.txt names another game",
                    detail: "\(file.lastPathComponent) is read before the AppID Steam starts "
                        + "the game with, so the game and the fix answer as the wrong app.",
                    remedy: "Put the real AppID back in the file.")
        }

        // MARK: The Photon patch

        let packageSaysPhoton = package?.iniValues["photonintegration"]?.lowercased() == "true"
        let packageHasCustom = package?.items.contains { $0.name == "custom.dll" } ?? false
        let photonCandidate = scan.isPhoton || packageSaysPhoton || packageHasCustom
            || (installed?.photonSwap ?? false)
        // A Steam-auth game keeps its own Photon app. Its ticket is checked against
        // that app's Steam AppID, and BepInEx's preloader can stop Unity 6. The
        // log's ticket line outranks Steam networking, which a custom-auth game can
        // also import for voice or achievements.
        let route = PhotonRoute.decide(
            isPhoton: photonCandidate,
            packagePresent: package != nil,
            packageSaysPhoton: packageSaysPhoton,
            packageHasCustom: packageHasCustom,
            packageHasChain: package?.hasPhotonChain ?? false,
            installedChain: PhotonFix.status(gameFolder: launch, fixInstalled: true).isPhoton,
            vendorLoader: PhotonChain.hasVendorLoader(in: launch, exe: scan.exe),
            candidates: candidates,
            usesSteamNetworking: scan.usesSteamNetworking,
            ownsApp: PhotonLog.ownsApp(appID: appID, folder: scan.folder, prefix: scan.prefix),
            log: log ?? PhotonLog.read(gameFolder: scan.folder, prefix: scan.prefix))
        let steamAuthPhoton = route.isSteamAuth
        let photon = route.installsOnlineFix
        // An earlier install may have written the chain that this route must not
        // load. Take it out here too, not only in FixPlan: a repair runs the audit
        // on the folder as it is, and must not leave the Unity 6 hang behind.
        if steamAuthPhoton, !routingOnly {
            let bep = launch.appendingPathComponent("BepInEx", isDirectory: true)
            var isBepDirectory: ObjCBool = false
            if Paths.fm.fileExists(atPath: bep.path, isDirectory: &isBepDirectory),
               isBepDirectory.boolValue {
                report.plan.removals.append(FixPlan.Removal(
                    path: bep,
                    reason: "The Steam-auth Photon route does not load OnlineFix's BepInEx chain"))
                for name in ["winhttp.dll", "version.dll", "doorstop_config.ini"] {
                    let url = launch.appendingPathComponent(name)
                    if Paths.fm.fileExists(atPath: url.path) {
                        report.plan.removals.append(FixPlan.Removal(
                            path: url,
                            reason: "The Steam-auth Photon route does not load OnlineFix's BepInEx chain"))
                    }
                }
            }
            let custom = launch.appendingPathComponent("Custom.dll")
            if Paths.fm.fileExists(atPath: custom.path) {
                report.plan.removals.append(FixPlan.Removal(
                    path: custom,
                    reason: "The Steam-auth Photon route does not load OnlineFix's Photon plugin"))
            }
            if !report.plan.removals.isEmpty {
                report.plan.notes.append("Removed OnlineFix's BepInEx chain: this Steam-auth "
                    + "Photon game runs as its own AppID and does not use it.")
            }
        }
        if photon, !routingOnly {
            let launchCustom = launch.appendingPathComponent("Custom.dll")
            // BepInEx lives beside the executable, not at the install root.
            let plugin = launch.appendingPathComponent(PhotonChain.plugin)
            let packageCustom = package?.items.first { $0.name == "custom.dll" }
            let bundle = PhotonChain.bundle()

            // Where the package's own Custom.dll goes decides how it starts: beside the
            // executable it is loaded by dlllist.txt, in BepInEx/plugins it needs the
            // preloader chain. A package that brought one and not the other is a
            // partial install even when every file the package carried is present.
            let plannedCustom = installed?.copies.first {
                $0.destination.lastPathComponent.lowercased() == "custom.dll"
            }?.relative.lowercased()
            let customBelongsInPlugins = plannedCustom.map { $0.hasPrefix("bepinex/") }
                ?? (packageCustom?.parent.lowercased().hasPrefix("bepinex") ?? false)
            if !exists(launchCustom), !exists(plugin), let packageCustom {
                let destination = customBelongsInPlugins ? plugin : launchCustom
                addCopy(packageCustom.url, to: destination, code: "OF103",
                        title: "The Photon patch is missing",
                        detail: "The package carries Custom.dll, but it is not where the loader "
                            + "reads it.",
                        remedy: "Copy the Photon patch back from the package.")
                if !customBelongsInPlugins { rootCustomPatch = true }
            }

            // A game that already had BepInEx, or a package that put Custom.dll in its
            // plugins folder, uses the chain. A root Custom.dll is loaded directly by
            // the OnlineFix payload, so it must not get a second, unused chain.
            let hasPreloader = exists(launch.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
            let hasDoorstop = exists(launch.appendingPathComponent(PhotonChain.config))
            let needsChain = exists(plugin) || hasPreloader || hasDoorstop
                || (customBelongsInPlugins && customPatch)
            if needsChain, let bundle {
                if let doorway = PhotonChain.doorway(in: folder, exe: scan.exe) {
                    for relative in PhotonChain.missing(in: launch, doorway: doorway) {
                        let bundled = bundle.appendingPathComponent(relative)
                        guard exists(bundled) else { continue }
                        // Prefer the package's own plugin: it knows the game's Photon layout.
                        let source = relative.lowercased().hasSuffix("custom.dll") && packageCustom != nil
                            ? packageCustom!.url : bundled
                        addCopy(source, to: launch.appendingPathComponent(relative),
                                code: "OF103", title: "The Photon chain is incomplete",
                                detail: "\(relative) is missing, so the Photon patch cannot load.",
                                remedy: "Put the missing chain file back.")
                    }
                    if !report.plan.wineDLLs.contains(doorway) {
                        report.plan.wineDLLs.append(doorway)
                    }
                } else {
                    report.findings.append(FixFinding(
                        code: "OF103", level: .warning,
                        title: "The Photon chain has no doorway",
                        detail: "The game imports none of winhttp.dll, winmm.dll or version.dll, "
                            + "so a BepInEx chain cannot start in it.",
                        remedy: "Use a package whose Custom.dll sits beside the executable, "
                            + "where OnlineFix64 loads it directly."))
                }
            }
            let launchList = launch.appendingPathComponent("dlllist.txt")
            let dllList = installed?.copies.first {
                $0.destination.lastPathComponent.lowercased() == "dlllist.txt"
            }?.destination ?? (exists(launchList) ? launchList : nil) ?? launchList
            let launchINI = launch.appendingPathComponent("OnlineFix.ini")
            if let ini = installed?.copies.first(where: {
                $0.destination.lastPathComponent.lowercased() == "onlinefix.ini"
            })?.destination ?? (exists(launchINI) ? launchINI : nil) {
                if exists(ini) {
                    let text = TextFile.text(ini) ?? ""
                    if !FixApply.hasPhotonIntegration(text) {
                        addEdit(.iniPhotonIntegration, at: ini, code: "OF109",
                                title: "Photon is not switched on in OnlineFix.ini",
                                detail: "The game is a Photon game, but the ini has no "
                                    + "PhotonIntegration=true.",
                                remedy: "Turn PhotonIntegration on in OnlineFix.ini.")
                    }
                }
            }
        }

        // MARK: The ini and the loader list

        func willExist(_ url: URL) -> Bool {
            exists(url) || report.plan.copies.contains {
                $0.destination.standardizedFileURL.path == url.standardizedFileURL.path
            }
        }

        let launchINI = launch.appendingPathComponent("OnlineFix.ini")
        let packageHasINI = package?.item(named: "onlinefix.ini") != nil
        if !routingOnly, let ini = installed?.copies.first(where: {
            $0.destination.lastPathComponent.lowercased() == "onlinefix.ini"
        })?.destination
            ?? (exists(launchINI) ? launchINI : nil)
            ?? (packageHasINI ? launchINI : nil) {
            if !exists(ini), let item = package?.item(named: "onlinefix.ini") {
                addCopy(item.url, to: ini, code: "OF109",
                        title: "OnlineFix.ini is missing",
                        detail: "The payload has no app ids without it.",
                        remedy: "Copy the ini back from the package.")
            }
            if willExist(ini) {
                let text = TextFile.text(ini) ?? ""
                func value(_ key: String) -> String? {
                    for raw in text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let equals = line.firstIndex(of: "=") else { continue }
                        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
                        guard name.caseInsensitiveCompare(key) == .orderedSame else { continue }
                        return line[line.index(after: equals)...]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return nil
                }
                let real = value("RealAppId")
                let fake = value("FakeAppId")
                if !exists(ini) || real != "\(appID)" || fake != "480" {
                    addEdit(.iniAppIDs, at: ini, code: "OF109",
                            title: real == nil || fake == nil
                                ? "OnlineFix.ini has no app ids" : "OnlineFix.ini has wrong app ids",
                            detail: "The payload needs RealAppId=\(appID) and FakeAppId=480.",
                            remedy: "Write the game's AppID and 480 into the ini.")
                }
                if steamAuthPhoton, FixApply.hasPhotonIntegration(text) {
                    addEdit(.iniPhotonIntegrationOff, at: ini, code: "OF109",
                            title: "The OnlineFix Photon chain is switched on",
                            detail: "This game takes Steam's Photon ticket and runs as its own "
                                + "AppID. PhotonIntegration=true makes the loader look for a chain "
                                + "that is not part of this route.",
                            remedy: "Turn PhotonIntegration off; the game's own Photon app "
                                + "receives the ticket.")
                } else if photon && !FixApply.hasPhotonIntegration(text) {
                    addEdit(.iniPhotonIntegration, at: ini, code: "OF109",
                            title: "Photon is not switched on in OnlineFix.ini",
                            detail: "The game is a Photon game, but the ini has no "
                                + "PhotonIntegration=true.",
                            remedy: "Turn PhotonIntegration on in OnlineFix.ini.")
                }
                if let real = package?.iniValues["realappid"],
                   let value = Int(real), value != appID {
                    report.findings.append(FixFinding(
                        code: "OF109", level: .warning,
                        title: "The package's RealAppId is another game",
                        detail: "OnlineFix.ini says \(value), but this game is \(appID). "
                            + "The payload will answer for the wrong app.",
                        remedy: "Use a package made for \(name)."))
                }
            }
        }

        if !routingOnly {
            let launchList = launch.appendingPathComponent("dlllist.txt")
            let list = installed?.copies.first(where: {
                $0.destination.lastPathComponent.lowercased() == "dlllist.txt"
            })?.destination ?? (exists(launchList) ? launchList : nil) ?? launchList
            if !exists(list), let item = package?.item(named: "dlllist.txt") {
                addCopy(item.url, to: list, code: "OF110",
                        title: "dlllist.txt is missing",
                        detail: "OnlineFix64 loads the payloads named in this list.",
                        remedy: "Copy the list back from the package.")
            }
            let text = TextFile.text(list) ?? ""
            let lines = Set(text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            var wanted: [String] = []
            for payload in payloads {
                wanted.append(payload.url.lastPathComponent)
            }
            if exists(launch.appendingPathComponent("SteamOverlay64.dll")) {
                wanted.append("SteamOverlay64.dll")
            }
            if exists(launch.appendingPathComponent("Custom.dll")) {
                wanted.append("Custom.dll")
            }
            for stub in ["StubDRM64.dll", "StubDRM.dll"]
            where exists(launch.appendingPathComponent(stub)) {
                wanted.append(stub)
            }
            // The plan has not run yet; a name it is about to place is wanted.
            for copy in report.plan.copies {
                let lower = copy.destination.lastPathComponent.lowercased()
                if FixPackage.payloadNames.contains(lower) || lower == "steamoverlay64.dll"
                    || FixApply.isDRMStubName(lower)
                    || (lower == "custom.dll"
                        && copy.destination.deletingLastPathComponent().standardizedFileURL
                            == launch.standardizedFileURL) {
                    wanted.append(copy.destination.lastPathComponent)
                }
            }
            // OnlineFix's own list names managed patch assemblies (…net.org) and
            // Custom.net on purpose: OnlineFix64 loads them into the game's Mono and
            // that is the Photon patch. Only a list written without them treats
            // Custom.net as the typo it is elsewhere.
            let vendorPatchList = lines.contains { $0.hasSuffix(".net.org") }
            let hasCustomNet = !vendorPatchList && lines.contains("custom.net")
            let rawLines = FixApply.dllListLines(text)
            let ordered = rawLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let overlayOutOfPlace = ordered.contains {
                $0.lowercased() == "steamoverlay64.dll"
            } && ordered.first?.lowercased() != "steamoverlay64.dll"
            let hasBlankLine = rawLines.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let hasDuplicate = ordered.count != Set(ordered.map { $0.lowercased() }).count
            // A name left by another game is not harmless: OnlineFix64 stops on
            // the first DLL in the list it cannot load, with error 126.
            let listFolder = list.deletingLastPathComponent()
            let wantedLower = Set(wanted.map { $0.lowercased() })
            let stale = ordered.contains { line in
                let lower = line.lowercased()
                if wantedLower.contains(lower) { return false }
                let relative = line.replacingOccurrences(of: "\\", with: "/")
                let candidates = [listFolder, launch, folder].map {
                    $0.appendingPathComponent(relative)
                }
                return !candidates.contains { exists($0) }
            }
            if !wanted.isEmpty,
               !exists(list) || hasCustomNet || overlayOutOfPlace || hasBlankLine
                || hasDuplicate || stale
                || wanted.contains(where: { !lines.contains($0.lowercased()) }) {
                let title = stale ? "The loader's list names a file that is not here"
                    : "The loader's list is incomplete"
                let detail = stale
                    ? "dlllist.txt names a DLL this game does not have, so OnlineFix64 "
                        + "stops with error 126 before the game opens."
                    : "dlllist.txt is missing " + wanted.joined(separator: ", ") + "."
                addEdit(.dllListEntries, at: list, code: "OF110",
                        title: title, detail: detail,
                        remedy: stale ? "Remove the names whose DLL is not here."
                            : "Add the missing names to dlllist.txt.", names: wanted,
                        allowMissing: !exists(list))
            }

            // Steam's DRM stub is allowed to load. Unity's crash reporter is
            // what ends the game under Wine while the stub is working, so it is
            // moved aside whenever the stub is in the folder and named by the list.
            let stubPresent = exists(launch.appendingPathComponent("StubDRM64.dll"))
                || exists(launch.appendingPathComponent("StubDRM.dll"))
                || report.plan.copies.contains {
                    FixApply.isDRMStubName($0.destination.lastPathComponent)
                }
            let stubNamed = ordered.contains { FixApply.isDRMStubName($0) }
            if stubPresent || stubNamed {
                for handler in FixApply.unityCrashHandlers(in: launch)
                where !report.plan.removals.contains(where: { $0.path.path == handler.path }) {
                    report.plan.removals.append(FixPlan.Removal(
                        path: handler,
                        reason: "Unity's crash reporter stops the game while Steam's DRM stub loads"))
                    report.findings.append(FixFinding(
                        code: "OF113", level: .warning,
                        title: "Unity's crash reporter stops the DRM stub",
                        detail: handler.lastPathComponent + " starts when Unity takes an "
                            + "exception. While Steam's DRM stub is loaded under Wine, "
                            + "that reporter ends the game before its window stays open.",
                        remedy: "Move the crash reporter aside. Uninstall puts it back."))
                }
            }
        }

        // MARK: The overlay, removals and the prefix

        let overlays = scan.overlayDLLs + (installed?.copies.compactMap {
            $0.destination.lastPathComponent.lowercased() == "steamoverlay64.dll"
                ? $0.destination : nil
        } ?? [])
        for overlay in overlays where exists(overlay) {
            // A 32-bit overlay in a 64-bit game (or the reverse) can never be
            // loaded. Remove it and its list line instead of stubbing a file the
            // loader will still reject.
            if let pe = PortableExecutable.read(overlay), !pe.isManaged {
                let wrong = scan.is64Bit ? !pe.is64BitNative : !pe.is32BitNative
                if wrong {
                    report.plan.removals.append(FixPlan.Removal(
                        path: overlay,
                        reason: "it is \(pe.architecture.rawValue) in a "
                            + "\(scan.is64Bit ? "64" : "32")-bit game"))
                    let launchList = launch.appendingPathComponent("dlllist.txt")
                    let list = report.plan.edits.first {
                        $0.kind == .dllListEntries
                    }?.path ?? (exists(launchList) ? launchList : nil)
                    if let list, !report.plan.edits.contains(where: {
                        $0.kind == .dllListDropOverlay && $0.path.path == list.path
                    }) {
                        report.plan.edits.append(FixPlan.Edit(kind: .dllListDropOverlay, path: list))
                    }
                    report.findings.append(FixFinding(
                        code: "OF110", level: .warning,
                        title: "The overlay is the wrong bitness",
                        detail: "\(overlay.lastPathComponent) is \(pe.architecture.rawValue) "
                            + "in a \(scan.is64Bit ? "64" : "32")-bit game, so the loader "
                            + "stops with error 126.",
                        remedy: "The repair removes the overlay and its loader line."))
                    continue
                }
            }
            if !OverlayStub.isDisabled(at: overlay) {
                if !report.plan.stubOverlay.contains(where: { $0.path == overlay.path }) {
                    report.plan.stubOverlay.append(overlay)
                }
                report.findings.append(FixFinding(
                    code: "OF110", level: .warning,
                    title: "The overlay can still stop the game",
                    detail: "SteamOverlay64.dll is beside the game and its loader is not inert. "
                        + "Under Wine it looks for a Steam renderer and can stop the game before "
                        + "it opens.",
                    remedy: "Make the overlay's DllMain return success without loading anything."))
            }
        }

        for removal in installed?.removals ?? [] where exists(removal.path) {
            if !report.plan.removals.contains(where: { $0.path.path == removal.path.path }) {
                report.plan.removals.append(FixPlan.Removal(path: removal.path,
                                                            reason: removal.reason))
            }
        }
        for leftover in scan.rootLoaderFiles where !report.plan.removals.contains(where: {
            $0.path.path == leftover.path
        }) {
            report.plan.removals.append(FixPlan.Removal(
                path: leftover,
                reason: "the game starts from \(scan.launchFolder.lastPathComponent)"))
            report.findings.append(FixFinding(
                code: "OF102", level: .warning,
                title: "The fix is in the wrong folder",
                detail: "\(leftover.lastPathComponent) sits at the game root while the game "
                    + "starts from \(scan.launchFolder.lastPathComponent).",
                remedy: "Remove the stray copy; Windows never loads it."))
        }

        // Steam makes the prefix on the game's first launch. Before that there is
        // nothing to override, and warning about it would be noise.
        if WineOverride.prefix(appID: appID) != nil {
            for doorway in report.plan.wineDLLs
                where !WineOverride.has(appID: appID, dll: doorway) {
                report.findings.append(FixFinding(
                    code: "OF105", level: .warning,
                    title: "The prefix will answer for \(doorway)",
                    detail: "The game folder has \(doorway), but this game's Wine prefix still "
                        + "loads its own copy.",
                    remedy: "Set the prefix to prefer the native \(doorway)."))
            }
        }

        if !report.plan.copies.isEmpty {
            report.notes.append("The consistency check will put \(report.plan.copies.count) "
                + "missing file(s) back after the install.")
        }
        return report
    }
}
