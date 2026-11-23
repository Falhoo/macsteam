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
        // with GDK support compiled in, which does run here: PEAK opens and reaches
        // Photon, and its fix carries the runtime files the game looks for. Only a
        // build with no Steam API at all has nothing to run as.
        let gdk = scan.isGDK || package?.isGDK == true
        let hasSteamAPI = !scan.apiDLLs.isEmpty || package?.apiItems.isEmpty == false
        if gdk, !hasSteamAPI {
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
                    + "as the Steam build. The fix's own GDK files (xsapi.dll, wdapp.exe) are "
                    + "copied with the rest and the prefix is told to load them.",
                remedy: "Install as usual."))
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
        let packageHashes = package?.hashes ?? []
        if !packageHashes.isEmpty, !FixDiagnosis.hashesMatch(packageHashes, scan: scan) {
            diagnosis.add(FixFinding(
                code: "OF055", level: .warning,
                title: "The fix is for another build of the game",
                detail: "OnlineFix's loader checks hashes of the game's own files, and none of "
                    + "the \(packageHashes.count) in this package match the installed build. "
                    + "It can refuse to start the game, or wait on a check that never passes.",
                remedy: "Install it, then probe. If no window appears, run it with its own "
                    + "Steam API as Spacewar instead."))
        }
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
                title: "Visual C++ runtime not beside the game",
                detail: "msvcp140.dll and vcruntime140.dll come from the Microsoft VC++ runtime. "
                    + "A prefix without it stops the game at start.",
                remedy: "Report it; install vcrun2019 in the game's prefix with the prefix tools."))
        }


        guard let package else { return diagnosis }

        // OF010, OF011: the Steam API DLL the game actually loads.
        let wanted = scan.is64Bit ? "steam_api64.dll" : "steam_api.dll"
        if package.apiItem(needs64: scan.is64Bit) == nil {
            if package.apiItems.isEmpty {
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
        } else if !package.iniKeys.contains("realappid") || !package.iniKeys.contains("fakeappid") {
            diagnosis.add(FixFinding(
                code: "OF013", level: .notice,
                title: "The ini is missing its app ids",
                detail: "RealAppId and FakeAppId are what tell the payload which game this is.",
                remedy: "Fill RealAppId=\(scan.appID) and FakeAppId=480."))
        }
        if package.carriesPayload,
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
            if package.hasPhotonChain {
                diagnosis.add(FixFinding(
                    code: "OF021", level: .notice,
                    title: "Photon game with OnlineFix's Photon patch",
                    detail: "The package carries the doorstop, BepInEx's preloader and Custom.dll.",
                    remedy: "Install the chain and turn PhotonIntegration on."))
            } else {
                diagnosis.add(FixFinding(
                    code: "OF021", level: .warning,
                    title: "Photon game, but the package has no Photon patch",
                    detail: "Without Custom.dll and its BepInEx preloader the game answers "
                        + "CustomAuthenticationError when it joins a room.",
                    remedy: "Install the chain from another Photon game's package if there is one, "
                        + "and say what is missing otherwise."))
            }
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

    /// True when the Visual C++ runtime is beside the executable or not needed at all.
    private static func runtimePresent(scan: GameScan) -> Bool {
        let names = ["msvcp140.dll", "vcruntime140.dll", "msvcp140_1.dll"]
        if names.contains(where: {
            Paths.fm.fileExists(atPath: scan.launchFolder.appendingPathComponent($0).path)
        }) { return true }
        // A Godot or Unity build ships its own runtime beside the exe.
        return scan.engine == .godot || scan.engine == .unityMono
    }
}
