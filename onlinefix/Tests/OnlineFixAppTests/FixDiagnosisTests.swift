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

    /// A real enough PE for the bitness reader, with no exports. The payload
    /// check needs a native DLL that is not a valid OnlineFix payload.
    private func peHeader(machine: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x4D; bytes[1] = 0x5A
        func u16(_ value: UInt16, _ offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func u32(_ value: UInt32, _ offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        u32(0x40, 0x3C)
        bytes[0x40] = 0x50; bytes[0x41] = 0x45
        u16(machine, 0x44)
        u16(0, 0x46)
        u16(0xE0, 0x54)
        u16(0x2002, 0x56)
        u16(0x020B, 0x58)
        u32(0, 0x58 + 108)
        return Data(bytes)
    }


    /// A payload of the right bitness that does not export OnlineFix is copied
    /// and never started. It has to stop the install, not look installed.
    @Test
    func aPayloadWithoutTheOnlineFixExportIsRefused() throws {
        let gameFolder = try game()
        let packageRoot = try package()
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try writeBinary(peHeader(machine: 0x8664),
                        to: packageRoot.appendingPathComponent("OnlineFix64.dll"))
        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF112"))
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

    /// PEAK: the only fix online-fix.me has is the Microsoft Store package. Copying
    /// it into the Steam install cannot register the Appx manifest, and Photon still
    /// sees a Steam ticket.
    @Test
    func aStoreRegistrationFixIsRefusedForASteamCopy() throws {
        let root = try game("gdk-steam-fix")
        let packageRoot = try folder("gdk-package")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("api", to: packageRoot.appendingPathComponent("steam_api64.dll"))
        try write("payload", to: packageRoot.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: packageRoot.appendingPathComponent("winmm.dll"))
        try write("gdk", to: packageRoot.appendingPathComponent("GDK_Helper.bat"))
        try write("gdk", to: packageRoot.appendingPathComponent("wdapp.exe"))
        try write("gdk", to: packageRoot.appendingPathComponent("xsapi.dll"))
        try write("[Main]\nIsPackaged=false\nProductId=9NMKF7LPVX44\n",
                  to: packageRoot.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: root, appID: 3527290, name: "PEAK")
        let package = FixPackage.read(root: packageRoot)
        #expect(package.requiresGDKRegistration)
        #expect(!scan.hasStoreManifest)

        let diagnosis = FixDiagnosis.run(scan: scan, package: package)
        #expect(diagnosis.isBlocked)
        #expect(codes(diagnosis).contains("OF080"))
        #expect(diagnosis.findings.first { $0.code == "OF080" }?.level == .blocking)
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
        // The game imports no doorway at all, so the bundled chain cannot be loaded:
        // the missing Photon patch stays a warning.
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

    /// Two copies of the same DLL: Windows loads one, and a fix can end up in the
    /// other, so the game runs the untouched one.
    @Test
    func twoCopiesOfTheSteamAPIWarn() throws {
        let gameFolder = try game("duplicate-api")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        try write("stale", to: gameFolder.appendingPathComponent("steam_api64.dll"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        let duplicate = diagnosis.findings.first { $0.code == "OF034" }
        #expect(duplicate?.level == .warning)
        #expect(duplicate?.detail.contains("Game_Data/Plugins/x86_64/steam_api64.dll") == true)
        #expect(duplicate?.detail.contains("steam_api64.dll") == true)
    }

    /// A package for another game would run that game's identity and meet its
    /// players, not this game's.
    @Test
    func aPackageForAnotherGameWarns() throws {
        let gameFolder = try game("mismatch")
        let packageRoot = try package("mismatch")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("[Main]\nRealAppId=999\nFakeAppId=480\n",
                  to: packageRoot.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: gameFolder, appID: 100, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        let mismatch = diagnosis.findings.first { $0.code == "OF013" }
        #expect(mismatch?.level == .warning)
        #expect(mismatch?.title == "The fix belongs to another game")
    }

    /// A GDK package names a Store product, not a Steam AppID. Demanding RealAppId
    /// would warn about every Microsoft Store fix.
    @Test
    func aGDKPackageDoesNotDemandSteamAppIDs() throws {
        let gameFolder = try game("gdk")
        let packageRoot = try package("gdk")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("x", to: gameFolder.appendingPathComponent("xsapi.dll"))
        try write("x", to: packageRoot.appendingPathComponent("xsapi.dll"))
        try write("[Main]\nIsPackaged=false\nProductId=9NMKF7LPVX44\n",
                  to: packageRoot.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: gameFolder, appID: 100, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF003"))
        #expect(!codes(diagnosis).contains("OF013"))
        // The game's own Steam API is the one the fix hooks, so a GDK package
        // carrying none is not a missing-API warning.
        #expect(!codes(diagnosis).contains("OF012"))
    }

    /// How to Fish imports both WINHTTP and WINMM from UnityPlayer, while its
    /// package ships winmm. The first imported doorway is not the one the package
    /// has, but a later one is, so Wine loads the fix.
    @Test
    func aShippedDoorwayTheGameImportsIsNotAWarning() throws {
        let gameFolder = try game("two-doorways")
        let packageRoot = try package("two-doorways")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("\u{0}WINHTTP.dll\u{0}WINMM.dll\u{0}",
                  to: gameFolder.appendingPathComponent("Game.exe"))

        let scan = GameScan.read(folder: gameFolder, appID: 100, name: "Game")
        #expect(scan.importedDLLs.contains("winmm.dll"))
        #expect(scan.importedDLLs.contains("winhttp.dll"))
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(!codes(diagnosis).contains("OF035"))
    }

    /// PEAK's package starts through winmm.dll, but its UnityPlayer imports WINHTTP.
    /// The fix installs, the doorway never loads, and nothing it carries runs.
    @Test
    func aDoorwayTheGameDoesNotImportWarns() throws {
        let gameFolder = try game("doorway")
        let packageRoot = try package("doorway")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("\u{0}WINHTTP.dll\u{0}", to: gameFolder.appendingPathComponent("Game.exe"))

        let scan = GameScan.read(folder: gameFolder, appID: 100, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        let doorway = diagnosis.findings.first { $0.code == "OF035" }
        #expect(doorway?.level == .warning)
        #expect(doorway?.detail.contains("winhttp.dll") == true)
    }

    /// R.E.P.O. and PEAK store their realtime and voice ids as a pair of fields.
    /// They are not two servers, and calling them ambiguous hides the patch that
    /// exists for exactly this layout.
    @Test
    func aRealtimeVoicePairIsNotAmbiguous() throws {
        let gameFolder = try game("pair")
        let packageRoot = try package("pair")
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("assembly", to: gameFolder.appendingPathComponent("Game_Data/Managed/PhotonVoice.dll"))
        let realtime = "11111111-2222-3333-4444-555555555555"
        let voice = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        var assets = Data("PhotonServerSettings".utf8)
        for id in [realtime, voice] {
            assets.append(Data([0x24, 0x00, 0x00, 0x00]))
            assets.append(Data(id.utf8))
        }
        try writeBinary(assets, to: gameFolder.appendingPathComponent("Game_Data/resources.assets"))

        let scan = GameScan.read(folder: gameFolder, appID: 100, name: "Game")
        let candidates = PhotonPatch.scan(in: gameFolder)
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot),
                                         candidates: candidates)
        let pair = diagnosis.findings.first { $0.code == "OF020" }
        #expect(pair?.level == .notice)
        #expect(pair?.title == "The game carries a Photon app-id pair")
        #expect(PhotonPatch.plan(for: candidates).changes.count == 2)
    }

    /// OF055 is retired: a package's `[Hashes]` values name no file, so one that
    /// matches nothing proves nothing. PEAK's GDK package hashes the Xbox build and
    /// R.E.P.O.'s is older than the installed one, yet both fixes work.
    @Test
    func aFixsHashGuardIsNotGuessedAt() throws {
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
        #expect(!codes(diagnosis).contains("OF055"))
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

    /// A leftover `steam_appid.txt` for another game is stronger than the routing:
    /// Steam reports its id to every Steam API call, including the fix's payload.
    @Test
    func aSteamAppIDFileForAnotherGameIsReported() throws {
        let gameFolder = try game("appid-file")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        try write("1509960\n", to: gameFolder.appendingPathComponent("steam_appid.txt"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(codes(diagnosis).contains("OF018"))
        #expect(diagnosis.findings.first { $0.code == "OF018" }?.level == .warning)
    }

    /// Steam's DRM stub does load, but Unity's crash reporter ends the game
    /// under Wine while the stub is working. The reporter is the thing to move.
    @Test
    func aUnityCrashReporterIsReportedForTheDRMStub() throws {
        let gameFolder = try game("drm-handler")
        let packageRoot = try package("drm-handler", extra: ["StubDRM64.dll"])
        defer {
            try? FileManager.default.removeItem(at: gameFolder)
            try? FileManager.default.removeItem(at: packageRoot)
        }
        try write("crash", to: gameFolder.appendingPathComponent("UnityCrashHandler64.exe"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: FixPackage.read(root: packageRoot))
        #expect(codes(diagnosis).contains("OF113"))
        #expect(diagnosis.findings.first { $0.code == "OF113" }?.level == .warning)
    }

    /// An earlier install's list is read before a package is in hand. A trailing
    /// newline is enough to make OnlineFix64 treat it as an empty DLL name.
    @Test
    func aBrokenInstalledLoaderListIsReported() throws {
        let gameFolder = try game("broken-list")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        try write("payload", to: gameFolder.appendingPathComponent("OnlineFix64.dll"))
        try write("overlay", to: gameFolder.appendingPathComponent("SteamOverlay64.dll"))
        try write("OnlineFix64.dll\r\n", to: gameFolder.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(codes(diagnosis).contains("OF014"))
        #expect(diagnosis.findings.first { $0.code == "OF014" }?.level == .warning)
    }

    /// A complete list with Windows line endings has no blank line. Splitting a CRLF
    /// with Foundation's newline set would invent one and warn on every good fix.
    @Test
    func aValidCRLFLoaderListIsNotReported() throws {
        let gameFolder = try game("crlf-list")
        defer { try? FileManager.default.removeItem(at: gameFolder) }
        try write("payload", to: gameFolder.appendingPathComponent("OnlineFix64.dll"))
        try write("overlay", to: gameFolder.appendingPathComponent("SteamOverlay64.dll"))
        try write("SteamOverlay64.dll\r\nOnlineFix64.dll",
                  to: gameFolder.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: gameFolder, appID: 1, name: "Game")
        let diagnosis = FixDiagnosis.run(scan: scan, package: nil)
        #expect(!codes(diagnosis).contains("OF014"))
    }
}
