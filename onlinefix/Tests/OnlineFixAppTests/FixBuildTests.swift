// Building the fix for a game from its package and its own folder.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixBuildTests {

    private func folder(_ name: String = "game") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A minimal 32-bit .NET executable: an MZ header, a PE header for x86, and the
    /// runtime's own name in the body, which is what the scan looks for.
    private var dotNet32: Data {
        var bytes = [UInt8](repeating: 0, count: 0x48)
        bytes[0x00] = 0x4D; bytes[0x01] = 0x5A
        bytes[0x3C] = 0x40
        bytes[0x40] = 0x50; bytes[0x41] = 0x45
        bytes[0x44] = 0x4C; bytes[0x45] = 0x14
        var data = Data(bytes)
        data.append(Data("mscoree.dll".utf8))
        data.append(Data("v4.0.30319".utf8))
        return data
    }

    private func writeBinary(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The split that made fixed games crash: the game loads its API DLL from
    /// `_Data/Plugins/x86_64` while the fix put it at the game root.
    @Test
    func aSplitFixEndsUpWhereTheGameLoadsIt() throws {
        let game = try folder()
        let package = try folder("package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        let api = game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll")
        try write("the game's own", to: api)

        try write("the fix's", to: package.appendingPathComponent("steam_api64.dll"))
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))
        try write("overlay", to: package.appendingPathComponent("SteamOverlay64.dll"))
        try write("[Main]\nBuildId=0\n", to: package.appendingPathComponent("OnlineFix.ini"))
        try write("SteamOverlay64.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 99, name: "Game")
        let plan = FixPlan.build(appID: 99, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))

        let apiCopy = plan.copies.first { $0.destination.lastPathComponent == "steam_api64.dll" }
        #expect(apiCopy?.destination.deletingLastPathComponent().lastPathComponent == "x86_64")
        #expect(plan.copies.contains {
            $0.destination.lastPathComponent == "OnlineFix64.dll"
                && $0.destination.deletingLastPathComponent().path == scan.folder.path
        })

        let applied = try FixApply.apply(plan, appID: 99, folder: game)
        #expect(applied.changed)

        // The game's own DLL is kept, and the fix's is the one the game loads.
        #expect(contents(api) == "the fix's")
        #expect(contents(api.appendingPathExtension("onlinefix-backup")) == "the game's own")

        // The ini names the game, and the overlay is dropped from the loader's list.
        let ini = contents(game.appendingPathComponent("OnlineFix.ini"))
        #expect(ini.contains("RealAppId=99"))
        #expect(ini.contains("FakeAppId=480"))
        let list = contents(game.appendingPathComponent("dlllist.txt"))
        #expect(list.contains("OnlineFix64.dll"))
        #expect(!list.lowercased().contains("steamoverlay64.dll"))
    }

    /// A Photon game's chain has to keep its tree, and the loader has to be told
    /// about the patch.
    @Test
    func aPhotonChainKeepsItsTree() throws {
        let game = try folder("photon")
        let package = try folder("photon-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("managed", to: game.appendingPathComponent("Game_Data/Managed/PhotonRealtime.dll"))

        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))
        try write("preloader", to: package.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
        try write("plugin", to: package.appendingPathComponent("Custom.dll"))
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        let plan = FixPlan.build(appID: 1, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.photonSwap)
        #expect(plan.copies.contains {
            $0.relative == "BepInEx/core/BepInEx.Preloader.dll"
        })

        _ = try FixApply.apply(plan, appID: 1, folder: game)
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll").path))
        let list = contents(game.appendingPathComponent("dlllist.txt"))
        #expect(list.contains("Custom.net"))
        #expect(contents(game.appendingPathComponent("OnlineFix.ini")).contains("PhotonIntegration=true"))
    }

    /// Buckshot Roulette: Valve's renderer beside the game stops it before main().
    @Test
    func aStrayRendererIsRemoved() throws {
        let game = try folder("godot")
        let package = try folder("godot-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("pck", to: game.appendingPathComponent("Game.pck"))
        let renderer = game.appendingPathComponent("GameOverlayRenderer64.dll")
        try write("renderer", to: renderer)
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))

        let scan = GameScan.read(folder: game, appID: 2835570, name: "Game")
        let plan = FixPlan.build(appID: 2835570, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.removals.contains { $0.path.lastPathComponent == "GameOverlayRenderer64.dll" })

        _ = try FixApply.apply(plan, appID: 2835570, folder: game)
        #expect(!FileManager.default.fileExists(atPath: renderer.path))
    }

    /// A Mac build takes no Windows files; PICO PARK 2's takes its own patch.
    @Test
    func aMacBuildGetsNoWindowsFiles() throws {
        let game = try folder("mac")
        let package = try folder("mac-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("binary", to: game.appendingPathComponent("Game.app/Contents/MacOS/Game"))
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))

        let scan = GameScan.read(folder: game, appID: 2644470, name: "PICO PARK 2")
        let plan = FixPlan.build(appID: 2644470, name: "PICO PARK 2", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.copies.isEmpty)
        #expect(plan.keepRealAppID)
        #expect(plan.picoPark2)
    }

    /// Loader files at the game root while the game runs one folder down are not
    /// where Windows looks, so they are settled into the launch folder.
    @Test
    func rootLeftoversAreSettled() throws {
        let game = try folder("wrapped")
        let package = try folder("wrapped-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("wrapped/Game.exe"))
        let leftover = game.appendingPathComponent("winmm.dll")
        try write("old doorstop", to: leftover)
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))

        let scan = GameScan.read(folder: game, appID: 7, name: "Game")
        #expect(scan.launchFolder.lastPathComponent == "wrapped")
        #expect(scan.rootLoaderFiles.count == 1)

        let plan = FixPlan.build(appID: 7, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.removals.contains { $0.path.lastPathComponent == "winmm.dll" })
        #expect(plan.copies.contains {
            $0.destination.lastPathComponent == "winmm.dll"
                && $0.destination.deletingLastPathComponent().lastPathComponent == "wrapped"
        })

        _ = try FixApply.apply(plan, appID: 7, folder: game)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("wrapped/winmm.dll").path))
    }

    /// Terraria: the fix's loader starts and the game never opens a window. The plan
    /// puts the game's own Steam API back and copies none of the fix's loader, so
    /// the routing starts a game that actually runs.
    @Test
    func aGameItsLoaderNeverOpensKeepsItsOwnSteamAPI() throws {
        let game = try folder("dotnet")
        let package = try folder("dotnet-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try writeBinary(dotNet32, to: game.appendingPathComponent("Terraria.exe"))
        let api = game.appendingPathComponent("steam_api.dll")
        try write("the fix's", to: api)
        try write("the game's own", to: game.appendingPathComponent("steam_api.of"))
        try write("the game's own", to: game.appendingPathComponent("steam_api.dll.onlinefix-backup"))

        try write("the fix's", to: package.appendingPathComponent("steam_api.dll"))
        try write("payload", to: package.appendingPathComponent("OnlineFix.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 990005, name: "Terraria")
        let read = FixPackage.read(root: package)
        let diagnosis = FixDiagnosis.run(scan: scan, package: read)
        #expect(diagnosis.findings.contains { $0.code == "OF061" })

        let plan = FixPlan.build(appID: 990005, name: "Terraria", scan: scan,
                                 package: read, diagnosis: diagnosis)
        #expect(plan.keepGameAPI)
        #expect(!plan.keepRealAppID)
        #expect(plan.copies.isEmpty)
        #expect(plan.restores.contains { $0.destination.lastPathComponent == "steam_api.dll" })

        _ = try FixApply.apply(plan, appID: 990005, folder: game)
        #expect(contents(api) == "the game's own")
        #expect(!FileManager.default.fileExists(
            atPath: game.appendingPathComponent("OnlineFix.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: game.appendingPathComponent("winmm.dll").path))
    }
}
