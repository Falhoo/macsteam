// Taking OnlineFix out and nothing else, checked against stand-in files so the
// reading and writing is exercised without a Steam install.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct OnlineFixRemovalTests {

    /// macSteam's config, with the OnlineFix block between two other keys.
    private let config = """
    Apps:
      - 2644470  # PICO PARK 2
      - 4000

    OnlineFix:
      2644470:
        KeepRealAppID: yes
        StartupAppID: yes
        OverlayAppID: yes
        InputAppID: yes
        StatsAppID: yes

    PackageIds:
      - 20200
    """

    @Test
    func theConfigLosesOnlyItsOnlineFixBlock() {
        let cleaned = OnlineFixRemoval.clearingOnlineFixSection(in: config)
        #expect(!cleaned.contains("OnlineFix:"))
        #expect(!cleaned.contains("KeepRealAppID"))
        #expect(cleaned.contains("  - 2644470  # PICO PARK 2"))
        #expect(cleaned.contains("  - 4000"))
        #expect(cleaned.contains("PackageIds:"))
        #expect(cleaned.contains("  - 20200"))
        // A second pass changes nothing.
        #expect(OnlineFixRemoval.clearingOnlineFixSection(in: cleaned) == cleaned)
    }

    @Test
    func theConfigWithoutAnOnlineFixBlockIsLeftAlone() {
        let text = "Apps:\n  - 4000\n"
        #expect(OnlineFixRemoval.clearingOnlineFixSection(in: text) == text)
    }

    /// Steam.app keeps macSteam's injection; only OnlineFix's keys and its entry in
    /// the injection list go.
    @Test
    func theEnvironmentLosesOnlyOnlineFixsKeys() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Info.plist")

        let macSteam = "/Applications/Steam.app/Contents/MacOS/macsteam.dylib"
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.valvesoftware.steam",
            "LSEnvironment": [
                "DYLD_INSERT_LIBRARIES": "\(macSteam):\(Paths.installedDylib.path)",
                "ONLINEFIX_SIG": "/tmp/runtime",
                "ONLINEFIX_CONFIG": "/tmp/routing.json",
                "ONLINEFIX_LOG": "/tmp/onlinefix.log",
                "LC_ALL": "en_US.UTF-8",
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)

        let cleared = OnlineFixRemoval.clearSteamEnvironment(plistURL: url)
        #expect(Set(cleared) == ["ONLINEFIX_SIG", "ONLINEFIX_CONFIG", "ONLINEFIX_LOG",
                                "DYLD_INSERT_LIBRARIES"])

        let after = try PropertyListSerialization
            .propertyList(from: try Data(contentsOf: url), format: nil) as? [String: Any]
        let env = after?["LSEnvironment"] as? [String: Any]
        #expect(env?["ONLINEFIX_SIG"] == nil)
        #expect(env?["ONLINEFIX_CONFIG"] == nil)
        #expect(env?["ONLINEFIX_LOG"] == nil)
        #expect(env?["LC_ALL"] as? String == "en_US.UTF-8")
        #expect(env?["DYLD_INSERT_LIBRARIES"] as? String == macSteam)
        #expect(after?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam")
    }

    /// A plist with nothing of OnlineFix's is reported as unchanged.
    @Test
    func anEnvironmentWithoutOnlineFixIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Info.plist")
        let plist: [String: Any] = ["LSEnvironment": ["LC_ALL": "en_US.UTF-8"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)

        #expect(OnlineFixRemoval.clearSteamEnvironment(plistURL: url).isEmpty)
    }

    /// The overrides a fix needed come out of the prefix's registry; everything else
    /// in it stays, including the same key outside Wine's own section.
    @Test
    func theWineOverridesAFixWroteComeOut() {
        let text = """
        WINE REGISTRY Version 2
        [Software\\\\Wine\\\\DllOverrides]
        "winmm"="native,builtin"
        "onlinefix64"="native"
        "someother"="builtin"
        [Software\\\\Other]
        "winmm"="native"
        """
        let cleared = WineOverride.clearing(text)
        #expect(cleared.removed.sorted() == ["onlinefix64.dll", "winmm.dll"])
        #expect(!cleared.text.contains("\"onlinefix64\"=\"native\""))
        #expect(cleared.text.contains("\"someother\"=\"builtin\""))
        #expect(cleared.text.contains("[Software\\\\Wine\\\\DllOverrides]"))
        // The same key in another section is not this fix's to remove.
        #expect(cleared.text.contains("[Software\\\\Other]\n\"winmm\"=\"native\""))
    }

    @Test
    func aPrefixWithoutOverridesIsLeftAlone() {
        let text = "[Software\\\\Wine\\\\DllOverrides]\n\"other\"=\"native\"\n"
        #expect(WineOverride.clearing(text).removed.isEmpty)
        #expect(WineOverride.clearing(text).text == text)
    }

    /// Whatever an earlier install left in a game folder is moved aside, and the
    /// game's own files stay where they are.
    @Test
    func thePayloadLeftInAGameFolderIsMovedAside() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        let game = root.appendingPathComponent("Some Game", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: game.appendingPathComponent("Game_Data/Managed"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appendingPathComponent("BepInEx/core"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("fix".utf8).write(to: game.appendingPathComponent("OnlineFix64.dll"))
        try Data("fix".utf8).write(to: game.appendingPathComponent("Custom.dll"))
        try Data("fix".utf8).write(to: game.appendingPathComponent("Game_Data/dlllist.txt"))
        try Data("lock".utf8).write(to: game.appendingPathComponent("game.app.onlinefix-endpoint.lock"))
        try Data("loader".utf8).write(to: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
        try Data("doorstop".utf8).write(to: game.appendingPathComponent("winmm.dll"))
        // The game's own file, which is not OnlineFix's to take.
        try Data("game".utf8).write(to: game.appendingPathComponent("Game_Data/Managed/Assembly-CSharp.dll"))

        let moved = OnlineFixRemoval.sweep(game, into: archive, game: "Some Game")
        #expect(moved.count == 6)
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("Custom.dll").path))
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("BepInEx").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("Game_Data/Managed/Assembly-CSharp.dll").path))
        // Kept, not deleted.
        #expect(fm.fileExists(atPath: archive.appendingPathComponent(
            "game-files/Some Game/Custom.dll").path))
        #expect(fm.fileExists(atPath: archive.appendingPathComponent(
            "game-files/Some Game/BepInEx/core/BepInEx.Preloader.dll").path))
        // The doorstop went with the loader it belongs to.
        #expect(!fm.fileExists(atPath: game.appendingPathComponent("winmm.dll").path))
    }

    /// A proxy DLL on its own may be the game's, so it stays where it is.
    @Test
    func aProxyWithoutTheLoaderIsLeftWhereItIs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        let game = root.appendingPathComponent("Other Game", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("game".utf8).write(to: game.appendingPathComponent("winmm.dll"))

        #expect(OnlineFixRemoval.sweep(game, into: archive, game: "Other Game").isEmpty)
        #expect(fm.fileExists(atPath: game.appendingPathComponent("winmm.dll").path))
    }

    @Test
    func theReportSaysWhatWent() {
        var report = OnlineFixRemoval.Report()
        report.removedDylib = true
        report.environmentKeys = ["ONLINEFIX_SIG"]
        report.clearedConfig = true
        report.clearedOverrides = [2644470]
        report.restoredPhoton = ["/game/metadata"]

        let summary = report.summary
        #expect(summary.contains("OnlineFix has been removed"))
        #expect(summary.contains("onlinefix.dylib"))
        #expect(summary.contains("ONLINEFIX_SIG"))
        #expect(summary.contains("2644470"))
        #expect(summary.contains("left alone"))
    }
}
