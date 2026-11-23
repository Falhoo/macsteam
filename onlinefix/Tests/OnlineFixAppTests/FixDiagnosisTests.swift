// The rules that say what a game and its fix need, one simulated error at a time.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixDiagnosisTests {

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnose-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A plain Steamworks game with a Unity plugin folder and one exe.
    private func game(_ name: String = "plain", withAPI: Bool = true) throws -> URL {
        let root = try folder(name)
        try write("exe", to: root.appendingPathComponent("Game.exe"))
        if withAPI {
            try write("api", to: root.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll"))
        }
        return root
    }

    /// A Steamworks package with the loader and its files.
    private func package(_ name: String = "pkg", extra: [String] = []) throws -> URL {
        let root = try folder(name)
        try write("api", to: root.appendingPathComponent("steam_api64.dll"))
        try write("payload", to: root.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: root.appendingPathComponent("winmm.dll"))
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n",
                  to: root.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: root.appendingPathComponent("dlllist.txt"))
        for path in extra { try write("x", to: root.appendingPathComponent(path)) }
        return root
    }

    private func codes(_ diagnosis: FixDiagnosis) -> [String] {
        diagnosis.findings.map(\.code)
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

    @Test
    func aPlainSteamworksGameHasNothingBlocking() throws {
        let gameFolder = try game()
        let packageRoot = try package()
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))

        #expect(!diagnosis.isBlocked)
        #expect(!codes(diagnosis).contains("OF003"))
        #expect(!codes(diagnosis).contains("OF011"))
        #expect(codes(diagnosis).contains("OF030"))
    }

    /// A Mac build takes no Windows files at all.
    @Test
    func aMacBuildIsNotGivenWindowsFiles() throws {
        let root = try folder("mac")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", to: root.appendingPathComponent("Game.app/Contents/MacOS/Game"))
        let scan = GameScan.read(folder: root, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(codes(diagnosis) == ["OF002"])
        #expect(!diagnosis.isBlocked)
    }

    @Test
    func aMicrosoftStoreBuildIsRefused() throws {
        // No Steam API at all: nothing on this Mac can supply the Xbox runtime.
        let root = try game("gdk", withAPI: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("gdk", to: root.appendingPathComponent("Game_Data/Managed/Unity.Microsoft.GDK.dll"))
        let scan = GameScan.read(folder: root, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF003"))
    }

    /// PEAK: the Steam build ships the GDK runtime as well, and it runs. That is not
    /// the Microsoft Store build the refusal is for.
    @Test
    func aStoreBuildWithSteamAPIBesideItIsNotRefused() throws {
        let root = try game("gdk-steam")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("gdk", to: root.appendingPathComponent("GDK_Helper.bat"))
        try write("gdk", to: root.appendingPathComponent("xsapi.dll"))

        let scan = GameScan.read(folder: root, appID: 3527290, name: "PEAK")
        #expect(scan.isGDK)

        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(!diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF003"))
        #expect(diagnosis.findings.first { $0.code == "OF003" }?.level == .notice)
    }

    @Test
    func anAntiCheatGameIsRefused() throws {
        let root = try game("ac")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("ac", to: root.appendingPathComponent("EasyAntiCheat/EasyAntiCheat_x64.dll"))
        let scan = GameScan.read(folder: root, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF004"))
    }

    /// The game is 64-bit and the package only brought the 32-bit DLL.
    @Test
    func theOtherBitnessIsRefused() throws {
        let gameFolder = try game()
        let packageRoot = try folder("32bit")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("api", to: packageRoot.appendingPathComponent("steam_api.dll"))
        try write("payload", to: packageRoot.appendingPathComponent("OnlineFix64.dll"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF011"))
    }

    /// The crash Buckshot Roulette shows: Valve's renderer beside the game.
    @Test
    func aStrayOverlayRendererIsFound() throws {
        let gameFolder = try game("godot")
        let packageRoot = try package("godot")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("pck", to: gameFolder.appendingPathComponent("Game.pck"))
        try write("renderer", to: gameFolder.appendingPathComponent("GameOverlayRenderer64.dll"))

        let scan = GameScan.read(folder: gameFolder, appID: 2835570, name: "Game")
        #expect(scan.engine == .godot)
        #expect(scan.strayOverlayRenderers.count == 1)

        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF017"))
        #expect(!diagnosis.isBlocked)
    }

    @Test
    func anOverlayNeedsStubbingAndAPhotonGameNeedsItsChain() throws {
        let gameFolder = try game("photon")
        let packageRoot = try package("photon", extra: ["SteamOverlay64.dll"])
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("managed", to: gameFolder.appendingPathComponent(
            "Game_Data/Managed/PhotonRealtime.dll"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        #expect(scan.isPhoton)

        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF015"))
        // The package has no Custom.dll, so the Photon patch is the warning.
        let photon = diagnosis.findings.first { $0.code == "OF021" }
        #expect(photon?.level == .warning)
    }

    @Test
    func aSteamRelayGameAsksForItsRealAppID() throws {
        let gameFolder = try game("relay")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        try write("SteamNetworkingSockets", to: gameFolder.appendingPathComponent("Game.exe"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        #expect(scan.usesSteamNetworking)
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        let relay = diagnosis.findings.first { $0.code == "OF030" }
        #expect(relay?.title == "Steam relay game")
    }

    /// Terraria's case: the loader's `[Hashes]` guard is of a build Steam has
    /// replaced. That is a warning on its own, because every package made before an
    /// update has one, and taking the loader away from a game it does start would
    /// break a fix that works.
    @Test
    func aFixMadeForAnotherBuildIsOnlyAWarning() throws {
        let gameFolder = try game("stale")
        let packageRoot = try package("stale")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n[Hashes]\n0=\(String(repeating: "a", count: 128))\n",
                  to: packageRoot.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: gameFolder, appID: 990001, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF055"))
        #expect(!codes(diagnosis).contains("OF061"))
    }

    /// The second half of Terraria's case: a 32-bit .NET game, where the loader
    /// starts inside the runtime and the window never comes.
    @Test
    func a32BitDotNetGameAsksForRouting() throws {
        let gameFolder = try folder("dotnet")
        let packageRoot = try folder("dotnet-package")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try writeBinary(dotNet32, to: gameFolder.appendingPathComponent("Game.exe"))
        try write("api", to: gameFolder.appendingPathComponent("steam_api.dll"))
        try write("api", to: packageRoot.appendingPathComponent("steam_api.dll"))
        try write("payload", to: packageRoot.appendingPathComponent("OnlineFix.dll"))

        let scan = GameScan.read(folder: gameFolder, appID: 990002, name: "Game")
        #expect(!scan.is64Bit)
        #expect(scan.usesDotNet)

        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF056"))
        #expect(codes(diagnosis).contains("OF061"))
        #expect(!diagnosis.isBlocked)
    }

    /// A probe that saw no window is the proof the files in place were not enough.
    @Test
    func aLaunchWithNoWindowAsksForRouting() throws {
        let gameFolder = try game("nowindow")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        let scan = GameScan.read(folder: gameFolder, appID: 990003, name: "Game")
        let probe = LaunchProbe.Result(appID: 990003, name: "Game", at: Date(),
                                       windowSeconds: nil, waited: 75, windowOwner: nil,
                                       note: "No window appeared in 75s.")

        let diagnosis = FixDiagnosis.run(scan: scan, package: nil, probe: probe)
        #expect(codes(diagnosis).contains("OF060"))
        #expect(codes(diagnosis).contains("OF061"))
    }

    /// A probe that saw the window leaves a working fix alone.
    @Test
    func aLaunchWithAWindowKeepsTheFix() throws {
        let gameFolder = try game("window")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        let scan = GameScan.read(folder: gameFolder, appID: 990004, name: "Game")
        let probe = LaunchProbe.Result(appID: 990004, name: "Game", at: Date(),
                                       windowSeconds: 12, waited: 12, windowOwner: "wine",
                                       note: "A window appeared after 12s (wine).")

        let diagnosis = FixDiagnosis.run(scan: scan, package: nil, probe: probe)
        #expect(!codes(diagnosis).contains("OF060"))
        #expect(!codes(diagnosis).contains("OF061"))
    }
}
