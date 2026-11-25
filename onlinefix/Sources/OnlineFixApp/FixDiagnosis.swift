// What a game and its fix need before anything is copied, as a list of findings.
//
// Each finding has a code, how bad it is, and what the build will do about it. The
// rules are the errors OnlineFix games actually fail with: the wrong Steam API DLL
// where the game loads it, a loader whose files sit where Windows never looks, an
// ini with no app ids, an overlay that stops Godot and Unity before main(), a
// Photon game without OnlineFix's Photon patch, a game that needs its own AppID,
// and the leftovers of an earlier attempt.
import Foundation

struct FixFinding: Codable, Sendable, Equatable {
    enum Level: String, Codable, Sendable {
        /// The fix cannot work, so nothing is copied.
        case blocking
        /// The build works around it, and the player should know what changed.
        case warning
        /// What the build does as a matter of course.
        case notice
    }

    var code: String
    var level: Level
    var title: String
    var detail: String
    var remedy: String

    var line: String { "\(code): \(title)" }
}

struct FixDiagnosis: Sendable {
    var findings: [FixFinding] = []

    var blocking: [FixFinding] { findings.filter { $0.level == .blocking } }
    var warnings: [FixFinding] { findings.filter { $0.level == .warning } }
    var notices: [FixFinding] { findings.filter { $0.level == .notice } }

    var isBlocked: Bool { !blocking.isEmpty }

    /// One line per finding, for the window, the command line and the recipe.
    var summary: [String] { findings.map(\.line) }

    mutating func add(_ finding: FixFinding) { findings.append(finding) }

    /// The rules, in the order the work happens.
    static func run(scan: GameScan, package: FixPackage?,
                    candidates: [PhotonPatch.Candidate] = [],
                    probe: LaunchProbe.Result? = nil) -> FixDiagnosis {
        var diagnosis = FixDiagnosis()

        // Nothing else matters for these three: no Windows file can be copied, or
        // the game cannot work with the fix at all.
        if let bundle = scan.macBundle {
            diagnosis.add(FixFinding(
                code: "OF002", level: .warning,
                title: "This is the Mac build",
                detail: "Steam installed \(bundle.lastPathComponent), a Mach-O app, and OnlineFix's "
                    + "Windows files cannot load into it.",
                remedy: "Copy nothing. Start the game as itself, and use the file patch where one "
                    + "exists (PICO PARK 2) or the routing that works for a Mac build."))
            return diagnosis
        }
        // OF003: a Microsoft Store (GDK) build needs the Xbox GDK runtime, which only
        // exists on Windows. A game that ships Steam's API as well is the Steam build
        // with GDK support compiled in, and those files alone do not make it packaged.
        // OF080: the fix is the other kind, a GDK package that installs by registering
        // an Appx manifest. Its files can be copied into a Steam install, but nothing
        // registers it, so it keeps authenticating as Steam and Photon refuses the
        // handoff. PEAK is this case: its OnlineFix is the Microsoft Store fix.
        let gdk = scan.isGDK || package?.isGDK == true
        let hasSteamAPI = !scan.apiDLLs.isEmpty || package?.apiItems.isEmpty == false
        let storeFixInSteamGame = package?.requiresGDKRegistration == true
            && !scan.hasStoreManifest && !scan.apiDLLs.isEmpty
        if storeFixInSteamGame {
            diagnosis.add(FixFinding(
                code: "OF080", level: .blocking,
                title: "Microsoft Store fix, Steam copy",
                detail: "This fix installs by registering a Microsoft Store (GDK) package with "
                    + "GDK_Helper and an Appx manifest. The game in this folder is a Steam "
                    + "install and has no Appx manifest, so copying the files cannot register "
                    + "it. The game still authenticates as Steam, and Photon answers the "
                    + "handoff with 32755 (error response from Steam).",
                remedy: "Use the Microsoft Store build with GDK_Helper, or a Steam fix for this "
                    + "game. Nothing was copied."))
        } else if gdk, !hasSteamAPI {
            let why = package?.isGDK == true
                ? "this fix is the Microsoft Store (GDK) package"
                : "this game ships the Microsoft Store (GDK) runtime"
            diagnosis.add(FixFinding(
                code: "OF003", level: .blocking,
                title: "Cannot work under Wine (Microsoft Store build)",
                detail: "\(why.capitalized). It needs the Xbox GDK runtime (xgameruntime.dll), "
                    + "which only exists on Windows, and the fix stops at error 126 loading it.",
                remedy: "Copy nothing. Play the Steam build as itself without the fix."))
        } else if gdk {
            diagnosis.add(FixFinding(
                code: "OF003", level: .notice,
                title: "Microsoft Store build, with Steam's API beside it",
                detail: "The game ships the Xbox GDK runtime and Steam's API both, so it runs "
                    + "as the Steam build. Those runtime files are evidence of GDK support, "
                    + "not of a registered package.",
                remedy: "Install as usual when the package is a Steam fix."))
        }
        if scan.hasAntiCheat {
            diagnosis.add(FixFinding(
                code: "OF004", level: .blocking,
                title: "Cannot work with this anti-cheat",
                detail: "The game ships Easy Anti-Cheat or BattlEye, which refuses a session that "
                    + "OnlineFix and Wine cannot satisfy.",
                remedy: "Copy nothing. Joining a protected server would still be refused."))
        }
        if diagnosis.isBlocked { return diagnosis }

        // These hold whether or not a package is in hand.
        // OF030, OF031: what Steam reports to the game.
        if scan.usesSteamNetworking {
            diagnosis.add(FixFinding(
                code: "OF030", level: .notice,
                title: "Steam relay game",
                detail: "Its online play runs on Steam's own networking, which only works for the "
                    + "AppID Steam believes the game is.",
                remedy: "Keep the real AppID in the routing so the relay is issued."))
        } else {
            diagnosis.add(FixFinding(
                code: "OF030", level: .notice,
                title: "Matches as Spacewar",
                detail: "The routing starts the game as AppID 480, which is the identity every "
                    + "OnlineFix copy matches under.",
                remedy: "Route it as 480."))
        }

        // OF055, OF056, OF061: the fix's own guard, and a game whose loader may
        // never start it. A .NET game built for 32-bit Windows is the case Terraria
        // shows: OnlineFix's loader runs, and the game never reaches a window.
        //
        // A stale guard alone is only a warning. Every package made before a game's
        // last update has one, and taking the loader away from a game it does start
        // would break a fix that works. The loader is left out only on evidence that
        // it does not start this game: its bitness and runtime, or a probe that saw
        // no window.
        // OF055 is retired. A package's `[Hashes]` names no file, so a value that
        // matches none of the game's exe, API or Unity data proves nothing: PEAK's GDK
        // package hashes the Xbox build, and R.E.P.O.'s is from an older build. The
        // warning fired on every real package and pointed at no action.
        let dotNet32 = !scan.is64Bit && scan.usesDotNet
        if dotNet32 {
            diagnosis.add(FixFinding(
                code: "OF056", level: .warning,
                title: "32-bit .NET game",
                detail: "This is a .NET Framework game built for 32-bit Windows. OnlineFix's "
                    + "32-bit loader starts inside the .NET process and, under this Wine, can "
                    + "leave it running with no window.",
                remedy: "Prefer the routing: keep the game's own Steam API and run it as Spacewar."))
        }
        let probeResult = probe ?? LaunchProbe.savedResult(appID: scan.appID)
        let probeFailed = probeResult != nil && probeResult?.windowSeconds == nil
        if let probeResult, probeResult.windowSeconds == nil {
            diagnosis.add(FixFinding(
                code: "OF060", level: .warning,
                title: "The last launch never showed a window",
                detail: "The launch probe started the game and no window appeared within "
                    + "\(Int(probeResult.waited))s.",
                remedy: "Use the routing-only fix, then probe again."))
        }
        if dotNet32 || probeFailed {
            diagnosis.add(FixFinding(
                code: "OF061", level: .notice,
                title: "Run this game with its own Steam API",
                detail: "Its fix's loader is not what makes it work here: macSteam's routing "
                    + "already starts the game as Spacewar (480), which is the identity every "
                    + "OnlineFix copy meets on.",
                remedy: "Put the game's own Steam API back and copy none of the fix's loader "
                    + "files. The game then opens, and online play still meets other copies on 480."))
        }

        // OF070: what Photon said the last time the game tried to connect. The
        // game's own log is the only thing that knows, and the line the player sees
        // ("Failed to connect to Photon Network") does not say which side refused.
        if scan.isPhoton,
           let evidence = PhotonLog.read(gameFolder: scan.folder, prefix: scan.prefix),
           evidence.isFailure {
            diagnosis.add(FixFinding(code: "OF070", level: .warning,
                                     title: evidence.title, detail: evidence.detail,
                                     remedy: evidence.remedy))
        }

        // OF040: the Visual C++ runtime the fix and the game both need.
        if !runtimePresent(scan: scan) {
            diagnosis.add(FixFinding(
                code: "OF040", level: .notice,
                title: "Visual C++ runtime is not installed",
                detail: "msvcp140.dll and vcruntime140.dll come from the Microsoft VC++ "
                    + "runtime. Neither is beside the game nor in its Wine prefix, and the "
                    + "game stops at start when it needs them.",
                remedy: "Install vcrun2019 in the game's prefix with the prefix tools, or "
                    + "put the runtime DLLs beside the game."))
        }


        // OF034: two copies of the same Steam API DLL. Windows loads the first it
        // finds, so a stale copy left at the root can keep the fix's DLL from ever
        // being used, or run the game under the wrong AppID. This is about the game,
        // so it holds whether or not a package is in hand.
        let apisByName = Dictionary(grouping: scan.apiDLLs) { $0.lastPathComponent.lowercased() }
        let duplicateAPIs = apisByName.filter { $0.value.count > 1 }
        if !duplicateAPIs.isEmpty {
            let names = duplicateAPIs.keys.sorted().joined(separator: ", ")
            let paths = duplicateAPIs.values.flatMap { $0 }
                .map { $0.path.replacingOccurrences(of: scan.folder.path + "/", with: "") }
                .sorted()
                .joined(separator: ", ")
            diagnosis.add(FixFinding(
                code: "OF034", level: .warning,
                title: "More than one copy of the Steam API DLL",
                detail: "The game has \(names) in more than one folder (\(paths)). Windows loads "
                    + "the first it finds, so one copy shadows the other and a fix can end up "
                    + "installed into the copy the game never loads.",
                remedy: "Keep the copy in \(scan.apiFolder?.lastPathComponent ?? "the folder the game loads it from") "
                    + "and remove the others."))
        }

        // OF018: a stale steam_appid.txt beside the executable. Steam reads it
        // before the routing, so a game correctly started as one AppID can still
        // authenticate as another. An id of 480 is the Spacewar identity the routing
        // itself asks for, so only a different real id is a finding.
        if let file = scan.steamAppIDFile {
            if let id = scan.steamAppID, id != scan.appID, id != 480 {
                diagnosis.add(FixFinding(
                    code: "OF018", level: .warning,
                    title: "steam_appid.txt names another game",
                    detail: "\(file.lastPathComponent) asks Steam to report AppID \(id), but "
                        + "this game is \(scan.appID). The payload and the routing both answer "
                        + "for the wrong game, so online play cannot meet the right players.",
                    remedy: "Put \(scan.appID) back in the file. The install does this "
                        + "before the fix is copied, so the game and the fix answer as one app."))
            } else if scan.steamAppID == nil {
                diagnosis.add(FixFinding(
                    code: "OF018", level: .notice,
                    title: "steam_appid.txt is not a number",
                    detail: "\(file.lastPathComponent) is beside the executable but does not "
                        + "begin with an AppID. Steam ignores a file it cannot read, so the "
                        + "routing still decides.",
                    remedy: "Leave it alone, or remove it if the game starts under the wrong id."))
            }
        }

        // OF014: a list an earlier attempt left behind. It is read below only once a
        // package is in hand, but a list already on disk can be broken before that:
        // a partial install names the payload but no longer has it, or names
        // Custom.net, or ends with a blank line. Each stops OnlineFix64 with error
        // 126, and the player sees a fix that installs and does nothing.
        if let list = scan.dllListURL,
           let payload = ["onlinefix64.dll", "onlinefix.dll"]
                .first(where: { scan.loaderFiles[$0] != nil }) {
            let names = scan.dllListLines.map { $0.lowercased() }
            // Split only after folding CRLF to LF. Foundation treats a CRLF as two
            // separators, so components(separatedBy: .newlines) would invent an empty
            // line in every list OnlineFix itself writes.
            let rawLines = scan.dllListText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            let blank = rawLines.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let customNet = names.contains("custom.net")
            let missingPayload = !names.contains(payload)
            let overlay = scan.loaderFiles["steamoverlay64.dll"] != nil
            let overlayLater = overlay && names.contains("steamoverlay64.dll")
                && names.first != "steamoverlay64.dll"
            if missingPayload || customNet || blank || overlayLater {
                var problems: [String] = []
                if missingPayload { problems.append("it does not name \(payload)") }
                if customNet { problems.append("it names Custom.net, which is managed and "
                    + "cannot be loaded as a native DLL") }
                if blank { problems.append("it has a blank line, which OnlineFix64 reads as "
                    + "an empty DLL name") }
                if overlayLater { problems.append("it puts SteamOverlay64.dll after the "
                    + "first line, and OnlineFix64 expects the overlay first") }
                diagnosis.add(FixFinding(
                    code: "OF014", level: .warning,
                    title: "The installed loader list is broken",
                    detail: "\(list.lastPathComponent) is beside the game, but "
                        + problems.joined(separator: "; ") + ". OnlineFix64 stops with "
                        + "\"Failed to load from the list. Error code: 126\".",
                    remedy: "Repair the fix from the fix card; the post-install pass rewrites "
                        + "the list with the payload and the overlay in the order OnlineFix64 "
                        + "reads."))
            }
        }

        guard let package else { return diagnosis }

        // OF010, OF011: the Steam API DLL the game actually loads.
        let wanted = scan.is64Bit ? "steam_api64.dll" : "steam_api.dll"
        if package.apiItem(needs64: scan.is64Bit) == nil {
            if package.isGDK, !scan.apiDLLs.isEmpty {
                // A GDK repair package hooks the Steam API the game already ships; it
                // does not carry a second copy. OF003 says what the GDK files need.
            } else if package.apiItems.isEmpty {
                diagnosis.add(FixFinding(
                    code: "OF012", level: .warning,
                    title: "The package has no Steam API DLL",
                    detail: "It carries no steam_api64.dll or steam_api.dll, so this is not an "
                        + "OnlineFix package for a Steam build.",
                    remedy: "Install what it does carry, and say so."))
            } else {
                diagnosis.add(FixFinding(
                    code: "OF011", level: .blocking,
                    title: "The fix is for the other bitness",
                    detail: "The game runs at \(scan.is64Bit ? "64" : "32")-bit and the package only "
                        + "carries \(scan.is64Bit ? "steam_api.dll" : "steam_api64.dll").",
                    remedy: "Copy nothing: a DLL of the other bitness cannot load."))
            }
        } else if scan.apiDLLs.isEmpty {
            diagnosis.add(FixFinding(
                code: "OF010", level: .notice,
                title: "The game's Steam API DLL is not where it loads from yet",
                detail: "The fix's \(wanted) is put in \(scan.apiFolder?.lastPathComponent ?? "the game folder"), "
                    + "which is where the game looks for it.",
                remedy: "Copy the fix's DLL there and keep the game's own file as a backup."))
        }

        // OF112: a game that names a function in its import table needs that
        // exact export from the fix's DLL. A DLL of the right bitness with the
        // wrong export set is the failure Windows reports as "procedure entry
        // point not found" before any game code runs, and a copy of the fix for
        // another build is the usual cause.
        let importedAPI = scan.coreImportedFunctions[wanted] ?? []
        if let api = package.apiItem(needs64: scan.is64Bit), !importedAPI.isEmpty,
           let pe = PortableExecutable.read(api.url), !pe.isManaged {
            let missing = importedAPI.filter { !pe.covers($0) }.sorted()
            if !missing.isEmpty {
                diagnosis.add(FixFinding(
                    code: "OF112", level: .blocking,
                    title: "The fix's Steam API is missing a function the game imports",
                    detail: "The game imports " + missing.prefix(4).joined(separator: ", ")
                        + (missing.count > 4 ? " and \(missing.count - 4) more" : "")
                        + " from \(wanted), but the package's DLL does not export "
                        + (missing.count == 1 ? "it" : "them") + ".",
                    remedy: "Use the package made for this build of the game; this one "
                        + "would stop with a missing entry point."))
            }
        }
        // The same check for the doorway. A proxy commonly forwards the whole
        // system DLL, but a package built for a newer Windows can be missing the
        // one function this game calls.
        for name in ["winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll"] {
            guard let item = package.item(named: name),
                  let needed = scan.coreImportedFunctions[name], !needed.isEmpty,
                  let pe = PortableExecutable.read(item.url), !pe.isManaged else { continue }
            let missing = needed.filter { !pe.covers($0) }.sorted()
            guard !missing.isEmpty else { continue }
            diagnosis.add(FixFinding(
                code: "OF112", level: .blocking,
                title: "The fix's \(name) is missing a function the game imports",
                detail: "The game imports " + missing.prefix(4).joined(separator: ", ")
                    + " from \(name), but the package's doorway does not export "
                    + (missing.count == 1 ? "it" : "them") + ".",
                remedy: "Use a package whose \(name) covers this game, or one whose "
                    + "Steam API replacement works without that doorway."))
        }

        // OF017: Valve's renderer beside the game.
        if !scan.strayOverlayRenderers.isEmpty {
            diagnosis.add(FixFinding(
                code: "OF017", level: .warning,
                title: "A copy of Steam's overlay renderer is beside the game",
                detail: "GameOverlayRenderer64.dll in the game folder makes Steam take it for the "
                    + "client. Godot and Unity then die before main(), which is the crash "
                    + "Buckshot Roulette shows.",
                remedy: "Remove it. The copy that matters lives in the Wine prefix."))
        }

        // OF012, OF033: the loader chain.
        if !package.carriesPayload {
            diagnosis.add(FixFinding(
                code: "OF012", level: .warning,
                title: "The package carries no OnlineFix payload",
                detail: "There is no OnlineFix64.dll or OnlineFix.dll in it, so nothing starts the "
                    + "fix inside the game.",
                remedy: "Copy what the package does carry and say what is missing."))
        }
        if !scan.rootLoaderFiles.isEmpty {
            diagnosis.add(FixFinding(
                code: "OF033", level: .notice,
                title: "Fix files left at the game root",
                detail: "The game starts from \(scan.launchFolder.lastPathComponent), so Windows "
                    + "never looks at the copies at the game root.",
                remedy: "Put the loader beside the executable and remove the stray copies."))
        }

        // OF013, OF014: the ini and the loader's list.
        if package.item(named: "onlinefix.ini") == nil {
            diagnosis.add(FixFinding(
                code: "OF013", level: .warning,
                title: "The package has no OnlineFix.ini",
                detail: "OnlineFix's payload reads the app ids and its own hashes from that file. "
                    + "Without it the fix cannot tell which game it belongs to.",
                remedy: "Write one with RealAppId and FakeAppId; never invent the hashes."))
        } else if package.isGDK {
            // A GDK package names a Store ProductId instead of a Steam AppID; OF003
            // already explains what that means. Requiring RealAppId here would warn
            // about every Microsoft Store fix.
        } else if !package.iniKeys.contains("realappid") || !package.iniKeys.contains("fakeappid") {
            diagnosis.add(FixFinding(
                code: "OF013", level: .notice,
                title: "The ini is missing its app ids",
                detail: "RealAppId and FakeAppId are what tell the payload which game this is.",
                remedy: "Fill RealAppId=\(scan.appID) and FakeAppId=480."))
        } else if let real = package.iniValues["realappid"]
                    .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                  real != scan.appID {
            diagnosis.add(FixFinding(
                code: "OF013", level: .warning,
                title: "The fix belongs to another game",
                detail: "Its OnlineFix.ini names RealAppId \(real), while Steam gave this game "
                    + "\(scan.appID). The payload would run the other game's identity, so it "
                    + "would not meet this game's players.",
                remedy: "Use the package for AppID \(scan.appID), or route this game as itself."))
        }
        if package.carriesPayload,
           !diagnosis.findings.contains(where: { $0.code == "OF014" }),
           !package.dllList.contains(where: { $0.lowercased() == "onlinefix64.dll"
                || $0.lowercased() == "onlinefix.dll" }) {
            diagnosis.add(FixFinding(
                code: "OF014", level: .notice,
                title: "The loader's list does not name the payload",
                detail: "OnlineFix64.dll is only started when dlllist.txt names it.",
                remedy: "Add it to dlllist.txt."))
        }

        // OF015: the overlay that pops error 126.
        if package.hasOverlay || !scan.overlayDLLs.isEmpty {
            diagnosis.add(FixFinding(
                code: "OF015", level: .notice,
                title: "The overlay would stop the game with error 126",
                detail: "SteamOverlay64.dll loads Valve's renderer, and the compatibility layer "
                    + "prunes that copy on every launch. The dialog it puts up runs before the "
                    + "game reaches main().",
                remedy: "Make its DllMain return TRUE and drop its line from dlllist.txt. The "
                    + "overlay is cosmetic; the rest of the fix matters."))
        }

        // OF016: the Wine prefix's DLL override.
        if scan.prefix == nil {
            diagnosis.add(FixFinding(
                code: "OF016", level: .notice,
                title: "No Wine prefix yet",
                detail: "Steam makes the prefix on the game's first launch, so the DLL override "
                    + "cannot be written now.",
                remedy: "Write it on the next repair, once the prefix exists."))
        }

        // OF020, OF021: Photon.
        if scan.isPhoton {
            let gameDoorway = PhotonChain.doorway(in: scan.folder, exe: scan.exe)
            let bundled = gameDoorway.map { bundleHas($0) } ?? false
            if package.hasPhotonChain {
                diagnosis.add(FixFinding(
                    code: "OF021", level: .notice,
                    title: "Photon game with OnlineFix's Photon patch",
                    detail: "The package carries the doorstop, BepInEx's preloader and Custom.dll.",
                    remedy: "Install the chain and turn PhotonIntegration on."))
            } else if bundled, let gameDoorway {
                diagnosis.add(FixFinding(
                    code: "OF021", level: .notice,
                    title: "Photon game; the manager adds the missing patch",
                    detail: "The package carries no Custom.dll and BepInEx preloader. The "
                        + "manager ships the chain and copies it behind \(gameDoorway).",
                    remedy: "Install the fix; the bundled chain is added with the package."))
            } else {
                diagnosis.add(FixFinding(
                    code: "OF021", level: .warning,
                    title: "Photon game, but the package has no Photon patch",
                    detail: "Without Custom.dll and its BepInEx preloader the game answers "
                        + "CustomAuthenticationError when it joins a room.",
                    remedy: "Install the chain from another Photon game's package if there is one, "
                        + "and say what is missing otherwise."))
            }
            // A realtime/voice pair is not an ambiguity: Unity stores the two fields in
            // order, and the patch writes each one. Only unrelated ids leave it unclear.
            let photonPlan = PhotonPatch.plan(for: candidates)
            if let voice = photonPlan.voiceID, let id = photonPlan.id {
                diagnosis.add(FixFinding(
                    code: "OF020", level: .notice,
                    title: "The game carries a Photon app-id pair",
                    detail: "Its Photon settings carry a realtime id (\(id.prefix(12))…) and a "
                        + "voice id (\(voice.prefix(12))…), which the patch replaces in field order.",
                    remedy: "Patch both fields; they are not two different servers."))
            } else if let skipped = photonPlan.skipped {
                diagnosis.add(FixFinding(
                    code: "OF020", level: .warning,
                    title: "The game's Photon ids are ambiguous",
                    detail: skipped,
                    remedy: "Leave them alone and let the patch sheet choose."))
            } else {
                let distinct = Set(candidates.filter { !$0.isOnlineFixShared }.map(\.id))
                if distinct.count == 1, let id = distinct.first {
                    diagnosis.add(FixFinding(
                        code: "OF020", level: .notice,
                        title: "The game carries its own Photon app id",
                        detail: "Online play only meets other players on OnlineFix's Photon app, "
                            + "not the game's own.",
                        remedy: "Replace \(id.prefix(12))… with OnlineFix's id in the game's files."))
                } else if distinct.count > 1 {
                    diagnosis.add(FixFinding(
                        code: "OF020", level: .warning,
                        title: "The game carries more than one Photon app id",
                        detail: "Which one it connects to cannot be told from its files.",
                        remedy: "Leave them alone and let the patch sheet choose."))
                }
            }
        }

        // OF035: a doorway the game never imports is a fix that installs and does
        // nothing. PEAK's package ships winmm.dll, while UnityPlayer imports WINHTTP.
        let shippedDoorways = ["winmm.dll", "winhttp.dll", "version.dll"]
            .filter { package.item(named: $0) != nil }
        // A package can ship more than one doorway, and a Unity game's engine DLL can
        // import more than one of them. How to Fish imports both WINHTTP and WINMM
        // while its package ships winmm, so checking only the first import named a
        // doorway the package did not have and warned about a fix that works.
        let importedShippedDoorways = shippedDoorways.filter {
            scan.importedDLLs.contains($0)
        }
        let gameDoorway = PhotonChain.doorway(in: scan.folder, exe: scan.exe)
        let canAddDoorway = scan.isPhoton && (gameDoorway.map { bundleHas($0) } ?? false)
        if let gameDoorway, !shippedDoorways.isEmpty,
           importedShippedDoorways.isEmpty {
            if canAddDoorway {
                diagnosis.add(FixFinding(
                    code: "OF035", level: .notice,
                    title: "The package's doorway is not the one the game imports",
                    detail: "The package starts through "
                        + "\(shippedDoorways.joined(separator: ", ")), but the game imports "
                        + "\(gameDoorway). The manager adds the bundled \(gameDoorway) chain.",
                    remedy: "Install the fix; the bundled chain supplies \(gameDoorway)."))
            } else {
                diagnosis.add(FixFinding(
                    code: "OF035", level: .warning,
                    title: "The fix's doorway is not one the game imports",
                    detail: "The package starts through "
                        + "\(shippedDoorways.joined(separator: ", ")), "
                        + "but the game imports \(gameDoorway). Windows never loads a DLL the game "
                        + "does not import, so none of the fix runs.",
                    remedy: "Use a package with a \(gameDoorway) doorway, or put the fix's "
                        + "loader behind \(gameDoorway)."))
            }
        } else if let gameDoorway, shippedDoorways.isEmpty,
                  package.carriesPayload || package.hasPhotonChain {
            if canAddDoorway {
                diagnosis.add(FixFinding(
                    code: "OF035", level: .notice,
                    title: "The manager adds the doorway the game can load",
                    detail: "The game imports \(gameDoorway), and the package carries no "
                        + "winmm.dll, winhttp.dll or version.dll. The bundled chain has one.",
                    remedy: "Install the fix; the bundled \(gameDoorway) starts the loader."))
            } else {
                diagnosis.add(FixFinding(
                    code: "OF035", level: .warning,
                    title: "The fix has no doorway the game can load",
                    detail: "The game imports \(gameDoorway), but the package carries no "
                        + "winmm.dll, winhttp.dll or version.dll for it to load.",
                    remedy: "Add a \(gameDoorway) doorway beside the game; without one the "
                        + "loader is never started."))
            }
        }

        return diagnosis
    }

    /// True when one of the fix's hashes is of one of the game's own files.
    static func hashesMatch(_ hashes: [String], scan: GameScan) -> Bool {
        var candidates: [URL] = []
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: scan.launchFolder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension.lowercased() == "exe" {
            candidates.append(url)
        }
        candidates.append(contentsOf: scan.apiDLLs)
        if let original = scan.originalSteamAPI { candidates.append(original) }
        for url in candidates {
            guard let hash = Hash.sha512(url) else { continue }
            if hashes.contains(hash.lowercased()) { return true }
        }
        return false
    }

    /// True when the bundle the app ships carries this doorway.
    private static func bundleHas(_ doorway: String) -> Bool {
        guard let bundle = PhotonChain.bundle() else { return false }
        return Paths.fm.fileExists(atPath: bundle.appendingPathComponent(doorway).path)
    }

    /// True when the Visual C++ runtime is beside the executable, in the prefix, or
    /// not needed at all.
    private static func runtimePresent(scan: GameScan) -> Bool {
        if scan.hasVCRuntime { return true }
        // A Godot or Unity build ships its own runtime; the scan has already checked
        // the game folder and the prefix for the other engines.
        return scan.engine == .godot || scan.engine == .unityMono
    }
}
