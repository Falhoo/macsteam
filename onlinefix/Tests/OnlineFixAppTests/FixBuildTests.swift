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

        // The ini names the game, and the overlay stays in the loader's list: its
        // DllMain is inert, and OnlineFix64 expects the first entry to be there.
        let ini = contents(game.appendingPathComponent("OnlineFix.ini"))
        #expect(ini.contains("RealAppId=99"))
        #expect(ini.contains("FakeAppId=480"))
        let list = contents(game.appendingPathComponent("dlllist.txt"))
        #expect(list.contains("OnlineFix64.dll"))
        #expect(list.lowercased().contains("steamoverlay64.dll"))
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
        #expect(list.contains("OnlineFix64.dll"))
        #expect(!list.contains("Custom.net"))
        #expect(contents(game.appendingPathComponent("OnlineFix.ini")).contains("PhotonIntegration=true"))
    }

    /// A package can put Custom.dll beside the executable, where dlllist.txt loads it
    /// through OnlineFix64. That layout must not also get BepInEx: the plugin would
    /// run twice, and a game that never needed the chain gets a second loader.
    @Test
    func aRootPhotonPatchNeedsNoBepInExChain() throws {
        let game = try folder("root-photon")
        let package = try folder("root-photon-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("managed", to: game.appendingPathComponent("Game_Data/Managed/PhotonRealtime.dll"))
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("plugin", to: package.appendingPathComponent("Custom.dll"))
        try write("[Main]\nRealAppId=7\nFakeAppId=480\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 7, name: "Game")
        let plan = FixPlan.build(appID: 7, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.photonSwap)
        #expect(plan.copies.contains { $0.relative == "Custom.dll" })
        #expect(!plan.copies.contains { $0.relative.lowercased().contains("bepinex") })
        #expect(!plan.copies.contains { $0.destination.lastPathComponent.lowercased() == "winmm.dll" })

        _ = try FixApply.apply(plan, appID: 7, folder: game)
        let list = contents(game.appendingPathComponent("dlllist.txt"))
        #expect(list.contains("Custom.dll"))
        #expect(!list.contains("Custom.net"))
        #expect(contents(game.appendingPathComponent("OnlineFix.ini")).contains("PhotonIntegration=true"))
    }

    /// Some packages say PhotonIntegration without shipping the patch. The package
    /// is evidence, so the app's chain is added even when the game's own assemblies
    /// were stripped or are hidden from the scan.
    @Test
    func aPackageThatSaysPhotonGetsTheBundledChain() throws {
        let game = try folder("says-photon")
        let package = try folder("says-photon-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        try write("... WINHTTP.dll ...", to: game.appendingPathComponent("UnityPlayer.dll"))
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("door", to: package.appendingPathComponent("winmm.dll"))
        try write("[Main]\nRealAppId=7\nFakeAppId=480\nPhotonIntegration=true\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 7, name: "Game")
        #expect(!scan.isPhoton)
        let plan = FixPlan.build(appID: 7, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(plan.photonSwap)
        #expect(plan.copies.contains { $0.relative == "winhttp.dll" })
        #expect(plan.copies.contains { $0.relative == PhotonChain.plugin })
        #expect(plan.copies.contains { $0.relative == "BepInEx/core/BepInEx.dll" })
        #expect(plan.wineDLLs.contains("winhttp.dll"))
    }

    /// PEAK's GDK fix has no Custom.dll and registers a Microsoft Store package.
    /// A generic BepInEx chain in that folder is not part of the fix and is not added.
    @Test
    func aStorePackageWithoutAPhotonPatchGetsNoChain() throws {
        let game = try folder("photon-no-chain")
        let package = try folder("photon-no-chain-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("managed", to: game.appendingPathComponent("Game_Data/Managed/PhotonRealtime.dll"))

        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))
        try write("gdk", to: package.appendingPathComponent("GDK_Helper.bat"))
        try write("gdk", to: package.appendingPathComponent("wdapp.exe"))
        try write("gdk", to: package.appendingPathComponent("xsapi.dll"))
        try write("[Main]\nRealAppId=1\nFakeAppId=480\nProductId=9NMKF7LPVX44\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        let plan = FixPlan.build(appID: 1, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package))
        #expect(scan.isPhoton)
        #expect(!plan.copies.contains { $0.relative.lowercased().contains("bepinex") })
        #expect(!plan.copies.contains {
            $0.destination.lastPathComponent.lowercased() == "custom.dll"
        })
        #expect(plan.notes.contains { $0.contains("has no Photon patch") })
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

    /// PEAK's package has no BepInEx chain and a winmm doorway, while UnityPlayer
    /// imports WINHTTP. The plan adds the bundled chain behind the doorway the game
    /// actually loads, so the Photon plugin can run.
    @Test
    func aPhotonPackageWithoutAChainGetsTheBundledOne() throws {
        let game = try folder("photon-no-chain")
        let package = try folder("photon-no-chain-package")
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: package)
        }
        try write("MZ", to: game.appendingPathComponent("PEAK.exe"))
        try write("... WINHTTP.dll ...",
                  to: game.appendingPathComponent("UnityPlayer.dll"))
        try write("managed", to: game.appendingPathComponent("PEAK_Data/Managed/PhotonRealtime.dll"))
        try write("payload", to: package.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: package.appendingPathComponent("winmm.dll"))
        try write("[Main]\nIsPackaged=false\nProductId=9NMKF7LPVX44\n",
                  to: package.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: game, appID: 1, name: "PEAK")
        let read = FixPackage.read(root: package)
        #expect(!read.hasPhotonChain)
        let plan = FixPlan.build(appID: 1, name: "PEAK", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        #expect(plan.copies.contains { $0.relative == "winhttp.dll" })
        #expect(plan.copies.contains { $0.relative == PhotonChain.plugin })
        #expect(plan.copies.contains { $0.relative == "BepInEx/core/BepInEx.dll" })
        #expect(plan.wineDLLs.contains("winhttp.dll"))

        _ = try FixApply.apply(plan, appID: 1, folder: game)
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("winhttp.dll").path))
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent(PhotonChain.plugin).path))
    }

    /// OnlineFix64 reads an empty trailing line as an empty DLL name and stops with
    /// error 126, and it expects the overlay first. A repaired list must have
    /// neither a blank line nor the overlay in the middle.
    @Test
    func aListIsRewrittenWithoutABlankLineAndWithTheOverlayFirst() throws {
        let game = try folder("list-shape")
        defer { try? FileManager.default.removeItem(at: game) }
        let list = game.appendingPathComponent("dlllist.txt")
        try write("OnlineFix64.dll\r\nGameAssembly.dll\r\nSteamOverlay64.dll\r\n", to: list)

        let changed = FixApply.ensureDLLListEntries(
            ["OnlineFix64.dll", "SteamOverlay64.dll", "GameAssembly.dll", "Custom.dll"],
            at: list)

        #expect(changed)
        #expect(contents(list) == "SteamOverlay64.dll\r\nOnlineFix64.dll\r\n"
            + "GameAssembly.dll\r\nCustom.dll")
    }

    /// A list with every name and the overlay first can still fail: one trailing
    /// newline is enough for OnlineFix64 to try an empty DLL name.
    @Test
    func aTrailingBlankLineIsTakenOffEvenWhenEveryNameIsThere() throws {
        let game = try folder("list-trailing")
        defer { try? FileManager.default.removeItem(at: game) }
        let list = game.appendingPathComponent("dlllist.txt")
        try write("SteamOverlay64.dll\r\nOnlineFix64.dll\r\n"
            + "GameAssembly.dll\r\nCustom.dll\r\n", to: list)

        let changed = FixApply.ensureDLLListEntries(
            ["SteamOverlay64.dll", "OnlineFix64.dll", "GameAssembly.dll", "Custom.dll"],
            at: list)

        #expect(changed)
        #expect(contents(list) == "SteamOverlay64.dll\r\nOnlineFix64.dll\r\n"
            + "GameAssembly.dll\r\nCustom.dll")
    }

    /// A Windows line ending is two bytes, but one line. A complete CRLF list is left
    /// byte for byte alone; treating the CR and LF separately would rewrite it on
    /// every audit and record a change that never happened.
    @Test
    func aCompleteCRLFListIsLeftAlone() throws {
        let game = try folder("list-crlf")
        defer { try? FileManager.default.removeItem(at: game) }
        let list = game.appendingPathComponent("dlllist.txt")
        let text = "SteamOverlay64.dll\r\nOnlineFix64.dll"
        try write(text, to: list)

        let changed = FixApply.ensureDLLListEntries(
            ["SteamOverlay64.dll", "OnlineFix64.dll"], at: list)

        #expect(!changed)
        #expect(contents(list) == text)
    }
}
