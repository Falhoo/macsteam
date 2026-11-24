// Where a game loads its Steam API from, and where the untouched copy is kept.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct GameScanTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A game with a copy beside the exe and a stale one in Unity's plugin folder.
    /// Windows loads the one beside the exe, so that is where the fix belongs.
    @Test
    func theCopyBesideTheExeIsTheOneItLoads() throws {
        let game = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: game) }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("beside the exe", to: game.appendingPathComponent("steam_api64.dll"))
        try write("stale", to: game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.apiDLLs.count == 2)
        #expect(scan.apiFolder?.path == game.path)
    }

    /// A game wrapped in a folder: the copy at the outer root is not the one its
    /// exe loads, so the plugin folder beside the exe wins.
    @Test
    func aGameInASubfolderUsesTheAPIBesideIt() throws {
        let root = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Game", isDirectory: true)
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("outer", to: root.appendingPathComponent("steam_api64.dll"))
        try write("inner", to: game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll"))

        let scan = GameScan.read(folder: root, appID: 1, name: "Game")
        #expect(scan.launchFolder.path == game.path)
        #expect(scan.apiFolder?.path
            == game.appendingPathComponent("Game_Data/Plugins/x86_64").path)
    }

    /// OnlineFix keeps the game's own API as `.onlinefix-backup` beside the one it
    /// installs, which for a Unity game is the plugin folder.
    @Test
    func theUntouchedAPIIsFoundInThePluginFolder() throws {
        let game = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: game) }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        let api = game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll")
        try write("the fix's", to: api)
        try write("the game's own", to: api.appendingPathExtension("onlinefix-backup"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.originalSteamAPI?.lastPathComponent
            == "steam_api64.dll.onlinefix-backup")
        #expect(scan.originalSteamAPI?.deletingLastPathComponent().path
            == api.deletingLastPathComponent().path)
    }

    /// A larger launcher beside the game is not the executable Steam starts. The
    /// scan reads the one named after the game, which is what the game's bitness and
    /// doorway are read from.
    @Test
    func theNamedExecutableBeatsALargerLauncher() throws {
        let game = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: game) }
        try write(String(repeating: "x", count: 4096),
                  to: game.appendingPathComponent("Launcher.exe"))
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("api", to: game.appendingPathComponent("steam_api64.dll"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.exe?.lastPathComponent == "Game.exe")
    }

    /// A tiny `Game.exe` is a launcher when the real binary is
    /// `Game-Win64-Shipping.exe`. The name alone must not win over the game itself.
    @Test
    func aTinyNamedLauncherDoesNotBeatTheRealGame() throws {
        let game = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: game) }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write(String(repeating: "x", count: 5_000_000),
                  to: game.appendingPathComponent("Game-Win64-Shipping.exe"))
        try write("api", to: game.appendingPathComponent("steam_api64.dll"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.exe?.lastPathComponent == "Game-Win64-Shipping.exe")
    }

    /// `steam_appid.txt` overrides the AppID Steam passes on the command line, so
    /// the scan keeps the value rather than leaving the routing to guess.
    @Test
    func aSteamAppIDFileIsRead() throws {
        let game = GameScan.canonical(try folder())
        defer { try? FileManager.default.removeItem(at: game) }
        try write("exe", to: game.appendingPathComponent("Game.exe"))
        try write("1509960\r\n", to: game.appendingPathComponent("steam_appid.txt"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.steamAppID == 1_509_960)
        #expect(scan.steamAppIDFile?.lastPathComponent == "steam_appid.txt")
    }

    /// The VC++ runtime in the prefix counts. PICO PARK has it there and no copy
    /// beside the game; warning that it is missing is a false alarm.
    @Test
    func theRuntimeInThePrefixCounts() throws {
        let game = GameScan.canonical(try folder())
        let prefix = try folder()
        defer {
            try? FileManager.default.removeItem(at: game)
            try? FileManager.default.removeItem(at: prefix)
        }
        let bin = prefix.appendingPathComponent("drive_c/windows/system32")
        try write("runtime", to: bin.appendingPathComponent("vcruntime140.dll"))

        #expect(GameScan.runtimeFilesPresent(in: game, folder: game, prefix: prefix,
                                            is64Bit: true))
        #expect(!GameScan.runtimeFilesPresent(in: game, folder: game, prefix: nil,
                                             is64Bit: true))
    }
}
