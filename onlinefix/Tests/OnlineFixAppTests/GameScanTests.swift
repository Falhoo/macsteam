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
}
