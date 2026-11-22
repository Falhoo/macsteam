// Installing a fix archive: everything that ships with the Steam API DLL has to
// go in, or the game cannot load it and never starts.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixInstallerTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixinstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// OnlineFix's steam_api64.dll imports OnlineFix64.dll and SteamOverlay64.dll.
    /// Copying only the API DLL left the game unable to start (c0000135) while
    /// Steam still showed it running.
    @Test
    func installsEveryFileBesideTheSteamAPIDLL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("fixed api", to: fix.appendingPathComponent("steam_api64.dll"))
        try write("onlinefix core", to: fix.appendingPathComponent("OnlineFix64.dll"))
        try write("overlay", to: fix.appendingPathComponent("SteamOverlay64.dll"))
        try write("[Main]\nRealAppId=1\n", to: fix.appendingPathComponent("OnlineFix.ini"))
        try write("notes", to: fix.appendingPathComponent("docs/readme.txt"))

        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("original api", to: game.appendingPathComponent("steam_api64.dll"))
        try write("game", to: game.appendingPathComponent("Buckshot Roulette.exe"))

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let files = Set(result.files.map { ($0 as NSString).lastPathComponent })
        #expect(files.contains("steam_api64.dll"))
        #expect(files.contains("OnlineFix64.dll"))
        #expect(files.contains("SteamOverlay64.dll"))
        #expect(files.contains("OnlineFix.ini"))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("SteamOverlay64.dll").path))
        // The replaced DLL is kept so Uninstall can put it back.
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("steam_api64.dll.onlinefix-backup").path))
    }

    /// A fix with no Steam API DLL is a tree to merge into the game folder.
    @Test
    func mergesAWholeFolderFix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("data", to: fix.appendingPathComponent("Buckshot Roulette_windows/Extra/data.ini"))
        let game = root.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }
        #expect(result.files.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("Buckshot Roulette_windows/Extra/data.ini").path))
    }

    /// A record is only "installed" while its files are on disk. Steam restores a
    /// game's own files on an update or a verify, which removes the fix, and the
    /// record that stays behind must not make the game look fixed.
    @Test
    func stateFollowsTheFilesOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = root.appendingPathComponent("steam_api64.dll")
        try write("fixed api", to: kept)
        let record = FixRecord(id: 1, gameName: "Game", files: [kept.path])

        #expect(FixInstaller.state(of: record) == .installed)
        #expect(FixInstaller.isInstalled(record))

        try FileManager.default.removeItem(at: kept)

        #expect(FixInstaller.state(of: record) == .missing([kept.path]))
        #expect(!FixInstaller.isInstalled(record))
    }

    /// A Steam verify downloads the game's own file to the path the fix wrote. The
    /// path is still there, so the fix looked installed while the game ran unfixed
    /// and was launched as Spacewar, which is how it "stopped working".
    @Test
    func stateNoticesAFileSteamPutBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let api = root.appendingPathComponent("steam_api64.dll")
        try write("fixed api", to: api)
        let sizes = FixInstaller.sizes(of: [api.path])
        #expect(sizes[api.path] == 9)

        let record = FixRecord(id: 1, gameName: "Game", files: [api.path], sizes: sizes)
        #expect(FixInstaller.state(of: record) == .installed)

        try write("the game's own steam_api64.dll, put back by a verify", to: api)

        #expect(FixInstaller.state(of: record) == .missing([api.path]))
        #expect(!FixInstaller.isInstalled(record))
    }

    /// The app rewrites `dlllist.txt` (drops the overlay line) and a player may tune
    /// `OnlineFix.ini`. Their new size must not make the game look unfixed — that
    /// would stop it from being routed as 480 and break its online play.
    @Test
    func theFilesTheAppEditsDoNotUnfixTheGame() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let core = root.appendingPathComponent("OnlineFix64.dll")
        let list = root.appendingPathComponent("dlllist.txt")
        let ini = root.appendingPathComponent("OnlineFix.ini")
        try write("onlinefix core", to: core)
        try write("SteamOverlay64.dll\nOnlineFix64.dll\n", to: list)
        try write("[Main]\nPhotonIntegration=true\n", to: ini)
        let files = [core.path, list.path, ini.path]
        let record = FixRecord(id: 1, gameName: "Game", files: files,
                               sizes: FixInstaller.sizes(of: files))
        #expect(FixInstaller.state(of: record) == .installed)

        try write("OnlineFix64.dll\n", to: list)
        try write("[Main]\nPhotonIntegration=true\nRealAppId=1\n", to: ini)

        #expect(FixInstaller.state(of: record) == .installed)
    }

    /// The overlay renderer the fix copies into a Windows prefix is optional: a
    /// prefix cleanup removes it and only the in-game overlay is lost, so the game
    /// must stay routed.
    @Test
    func theOverlayRendererGoingAwayDoesNotUnfixTheGame() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let api = root.appendingPathComponent("steam_api64.dll")
        let renderer = root.appendingPathComponent("pfx/GameOverlayRenderer64.dll")
        try write("fixed api", to: api)
        try write("renderer", to: renderer)

        let files = [api.path, renderer.path]
        let record = FixRecord(id: 1, gameName: "Game", files: files,
                               sizes: FixInstaller.sizes(of: files))
        #expect(FixInstaller.state(of: record) == .installed)

        try FileManager.default.removeItem(at: renderer)

        #expect(FixInstaller.state(of: record) == .installed)
    }

    /// Steam runs a native macOS bundle, not the Windows build, so OnlineFix has
    /// nothing to patch there.
    @Test
    func spotsANativeMacBundle() throws {

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FixInstaller.nativeMacBundle(in: root) == nil)

        let macos = root.appendingPathComponent("Terraria.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        #expect(FixInstaller.nativeMacBundle(in: root)?.lastPathComponent == "Terraria.app")
    }

    /// Some fixes are laid out like the game folder: the Steam API DLL deep in the
    /// Engine tree and the loader (OnlineFix64.dll and its winmm.dll proxy) next to
    /// the game's executable. Installing only what sits beside the API DLL left the
    /// game completely unfixed.
    @Test
    func installsAFixLaidOutLikeTheGameFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let apiPath = "Engine/Binaries/ThirdParty/Steamworks/Steamv16/Win64/steam_api64.dll"
        let binPath = "Ride/Binaries/Win64"

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("fixed api", to: fix.appendingPathComponent(apiPath))
        try write("onlinefix core", to: fix.appendingPathComponent("\(binPath)/OnlineFix64.dll"))
        try write("proxy", to: fix.appendingPathComponent("\(binPath)/winmm.dll"))

        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("original api", to: game.appendingPathComponent(apiPath))
        try write("exe", to: game.appendingPathComponent("\(binPath)/Ride-Win64-Shipping.exe"))

        _ = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: game.appendingPathComponent("\(binPath)/OnlineFix64.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("\(binPath)/winmm.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent(apiPath).path))
        // The replaced API DLL keeps the original beside it.
        #expect(fm.fileExists(atPath: game.appendingPathComponent(apiPath + ".onlinefix-backup").path))
    }

    /// A Photon fix ships its managed patch in a BepInEx tree plus a doorstop at the
    /// archive's root. Those only load from beside Unity's executable: installed
    /// beside the Steam API DLL instead, the game ran anyway and answered
    /// "CustomAuthenticationError", because the patch that makes Photon accept
    /// OnlineFix's auth was never loaded.
    @Test
    func installsAPhotonChainAtTheGameRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let apiPath = "REPO_Data/Plugins/x86_64/steam_api64.dll"
        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("fixed api", to: fix.appendingPathComponent(apiPath))
        try write("loader", to: fix.appendingPathComponent("OnlineFix64.dll"))
        try write("[Misc]\nPhotonIntegration=true\n", to: fix.appendingPathComponent("OnlineFix.ini"))
        try write("list", to: fix.appendingPathComponent("dlllist.txt"))
        try write("overlay", to: fix.appendingPathComponent("SteamOverlay64.dll"))
        try write("doorstop", to: fix.appendingPathComponent("winmm.dll"))
        try write("plugin", to: fix.appendingPathComponent("Custom.dll"))
        try write("preloader", to: fix.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))

        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("original api", to: game.appendingPathComponent(apiPath))
        try write("exe", to: game.appendingPathComponent("REPO.exe"))
        try write("managed", to: game.appendingPathComponent("REPO_Data/Managed/PhotonRealtime.dll"))

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let fm = FileManager.default
        // Unity loads the doorstop from beside the executable, and BepInEx keeps its
        // tree there, so both land at the game root and not in the Plugins folder.
        #expect(fm.fileExists(atPath: game.appendingPathComponent("winmm.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("Custom.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll").path))
        // The rest of the archive root belongs at the game root too: the loader reads
        // dlllist.txt and OnlineFix.ini from there, not from the Steam API DLL's folder.
        #expect(fm.fileExists(atPath: game.appendingPathComponent("dlllist.txt").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("OnlineFix.ini").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("REPO_Data/Plugins/x86_64/dlllist.txt").path))
        // The mirrored Steam API DLL keeps going where the game loads it from.
        #expect(fm.fileExists(atPath: game.appendingPathComponent(apiPath).path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent(apiPath + ".onlinefix-backup").path))

        let chain = PhotonFix.status(gameFolder: game, fixInstalled: true)
        #expect(chain.isComplete, "the installed fix has the whole chain: \(chain.missing)")
        #expect(result.files.contains { $0.hasSuffix("winmm.dll") })
    }

    /// The overlay line makes the loader try Steam's renderer, which compatibility
    /// layers prune from the prefix, and its failure stops everything after it.
    @Test
    func dropsTheOverlayLineFromDLLList() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = root.appendingPathComponent("dlllist.txt")
        try write("SteamOverlay64.dll\nOnlineFix64.dll\nCustom.net\n", to: list)

        #expect(FixInstaller.removingOverlayFromDLLList(at: list.path))

        let text = try String(contentsOf: list, encoding: .utf8)
        #expect(!text.contains("SteamOverlay64"))
        #expect(text.contains("OnlineFix64.dll"))
        #expect(text.contains("Custom.net"))
        #expect(FileManager.default.fileExists(atPath: list.path + ".onlinefix-backup"))
        // Running it again changes nothing.
        #expect(!FixInstaller.removingOverlayFromDLLList(at: list.path))
    }

    /// PEAK's online-fix release is the Microsoft Store (GDK) package. Its loader
    /// needs the Xbox GDK runtime, which does not exist under Wine, so the fix is
    /// always reported for what it is.
    @Test
    func aGDKFixIsCalledOut() {
        let gdk = FixRecord(id: 3527290, gameName: "PEAK",
                            files: ["/game/wdapp.exe", "/game/xsapi.dll",
                                    "/game/GDK_Helper.bat", "/game/dlllist.txt"])
        #expect(FixInstaller.gdkIssue(for: gdk) != nil)

        let steam = FixRecord(id: 1, gameName: "Game",
                              files: ["/game/steam_api64.dll", "/game/OnlineFix64.dll",
                                      "/game/dlllist.txt"])
        #expect(FixInstaller.gdkIssue(for: steam) == nil)
    }

    /// A GDK archive is refused before anything is placed: the runtime it needs is
    /// not part of Wine, and its self-protection rejects a rewritten Steam shape.
    @Test
    func aGDKArchiveIsRefusedBeforeInstalling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fix = root.appendingPathComponent("fix", isDirectory: true)
        for name in ["wdapp.exe", "xsapi.dll", "GDK_Helper.bat", "OnlineFix64.dll"] {
            try write(name, to: fix.appendingPathComponent(name))
        }
        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("exe", to: game.appendingPathComponent("PEAK.exe"))

        #expect(throws: Error.self) {
            _ = try FixInstaller.installExtracted(from: fix, into: game, appID: nil) { _ in }
        }
        #expect(!FileManager.default.fileExists(
            atPath: game.appendingPathComponent("OnlineFix64.dll").path))
    }

    /// A flat fix (no folders of its own) belongs beside the game's executable. A
    /// game wrapped in a folder of its own keeps it one level down, and Windows only
    /// searches the executable's folder for a DLL, so the whole fix went unread when
    /// it was placed at the game folder's root.
    @Test
    func installsAFlatFixBesideTheExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        let files = ["OnlineFix.ini", "OnlineFix.url", "OnlineFix64.dll",
                     "steam_api64.dll", "steam_api64.of", "SteamOverlay64.dll"]
        for name in files { try write(name, to: fix.appendingPathComponent(name)) }

        let game = root.appendingPathComponent("Buckshot Roulette", isDirectory: true)
        let exeDir = game.appendingPathComponent("Buckshot Roulette_windows", isDirectory: true)
        try write("exe", to: exeDir.appendingPathComponent("Buckshot Roulette.exe"))
        try write("crash handler", to: exeDir.appendingPathComponent("UnityCrashHandler64.exe"))

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let fm = FileManager.default
        for name in files {
            #expect(fm.fileExists(atPath: exeDir.appendingPathComponent(name).path),
                    "\(name) must land beside the game's executable")
        }
        #expect(URL(fileURLWithPath: result.targetDirectory).standardizedFileURL.path == exeDir.standardizedFileURL.path)
    }

    /// Unity loads its Steam API DLL from `<Name>_Data/Plugins/<arch>`; the loader
    /// and its ini still go beside the executable.
    @Test
    func installsAFlatUnityFixIntoItsPluginsFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        for name in ["OnlineFix.ini", "OnlineFix64.dll", "steam_api64.dll"] {
            try write(name, to: fix.appendingPathComponent(name))
        }

        let game = root.appendingPathComponent("game", isDirectory: true)
        let plugins = game.appendingPathComponent("Game_Data/Plugins/x86_64", isDirectory: true)
        try write("original api", to: plugins.appendingPathComponent("steam_api64.dll"))
        try write("exe", to: game.appendingPathComponent("Game.exe"))

        _ = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: plugins.appendingPathComponent("steam_api64.dll").path))
        #expect(fm.fileExists(atPath: plugins.appendingPathComponent(
            "steam_api64.dll.onlinefix-backup").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("OnlineFix.ini").path))
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("steam_api64.dll").path))
    }

    /// The executable named after the game wins over a larger helper such as a crash
    /// handler, so the fix lands where Steam starts the game.
    @Test
    func theGameNamedExecutableWinsOverAHelper() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let game = root.appendingPathComponent("Buckshot Roulette", isDirectory: true)
        let exeDir = game.appendingPathComponent("Buckshot Roulette_windows", isDirectory: true)
        try write("small", to: exeDir.appendingPathComponent("Buckshot Roulette.exe"))
        try write(String(repeating: "x", count: 4096),
                  to: game.appendingPathComponent("UnityCrashHandler64.exe"))

        #expect(FixInstaller.launchFolder(in: game)?.lastPathComponent
                == "Buckshot Roulette_windows")
    }
}
