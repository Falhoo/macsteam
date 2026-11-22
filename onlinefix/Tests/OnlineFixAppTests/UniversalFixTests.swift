// The universal repair: whatever shape a fix archive had, the game must end up
// with the Steam API DLL it loads, the payload the loader starts, and an ini that
// names the game. These cover the split that made fixed games crash.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct UniversalFixTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("universal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A game whose Steam API DLL lives under `_Data/Plugins/x86_64`, a fix that put
    /// the proxy there and the payload at the game root, as several archives do.
    private func splitFix(in root: URL) throws -> (game: URL, files: [String]) {
        let game = root.appendingPathComponent("game", isDirectory: true)
        let exe = game.appendingPathComponent("Game.exe")
        let plugins = game.appendingPathComponent("Game_Data/Plugins/x86_64", isDirectory: true)

        try write("exe", to: exe)
        try write("original api", to: plugins.appendingPathComponent("steam_api64.dll"))
        try write("proxy api", to: plugins.appendingPathComponent("steam_api64.dll"))
        try write("[Main]\n", to: game.appendingPathComponent("OnlineFix.ini"))
        try write("onlinefix core", to: game.appendingPathComponent("OnlineFix64.dll"))
        try write("proxy", to: game.appendingPathComponent("winmm.dll"))

        let files = [
            plugins.appendingPathComponent("steam_api64.dll").path,
            game.appendingPathComponent("OnlineFix.ini").path,
            game.appendingPathComponent("OnlineFix64.dll").path,
            game.appendingPathComponent("winmm.dll").path,
        ]
        return (game, files)
    }

    @Test
    func copiesThePayloadBesideTheExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (game, files) = try splitFix(in: root)

        let report = UniversalFix.apply(appID: 1234, gameFolder: game, fixFiles: files)

        #expect(report.changed)
        // The loader only starts from beside the executable, so both go there too.
        for name in ["OnlineFix64.dll", "winmm.dll", "OnlineFix.ini"] {
            #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent(name).path),
                    "\(name) must also sit beside the game's executable")
        }
        // ... and the payload reaches the folder of the Steam API DLL the game loads.
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("Game_Data/Plugins/x86_64/OnlineFix64.dll").path))
    }

    @Test
    func aSecondRunChangesNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (game, files) = try splitFix(in: root)

        let first = UniversalFix.apply(appID: 1234, gameFolder: game, fixFiles: files)
        let second = UniversalFix.apply(appID: 1234, gameFolder: game,
                                        fixFiles: files + first.additions)

        #expect(!second.changed, "a repaired fix must stay repaired without more writes")
    }

    @Test
    func fillsInTheAppIDsTheIniIsMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (game, files) = try splitFix(in: root)

        _ = UniversalFix.apply(appID: 3241660, gameFolder: game, fixFiles: files)

        let ini = try String(contentsOf: game.appendingPathComponent("OnlineFix.ini"),
                             encoding: .utf8)
        #expect(ini.contains("RealAppId=3241660"))
        #expect(ini.contains("FakeAppId=480"))
    }

    @Test
    func leavesAnIniThatAlreadyNamesTheGameAlone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (game, files) = try splitFix(in: root)
        let iniURL = game.appendingPathComponent("OnlineFix.ini")
        try write("[Main]\nRealAppId=9999\nFakeAppId=480\n", to: iniURL)

        _ = UniversalFix.apply(appID: 1234, gameFolder: game, fixFiles: files)

        let ini = try String(contentsOf: iniURL, encoding: .utf8)
        #expect(ini.contains("RealAppId=9999"), "a value the fix shipped is never rewritten")
    }

    @Test
    func putsTheFixesSteamAPIDLLWhereTheGameLoadsIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let exe = game.appendingPathComponent("Game.exe")
        let plugins = game.appendingPathComponent("Game_Data/Plugins/x86_64", isDirectory: true)

        try write("exe", to: exe)
        // The fix's proxy went beside the executable; the copy the game loads is the
        // game's own untouched DLL, which is why the game ran without OnlineFix.
        let stray = game.appendingPathComponent("steam_api64.dll")
        try write("proxy api for the fix", to: stray)
        let loaded = plugins.appendingPathComponent("steam_api64.dll")
        try write("original", to: loaded)

        let report = UniversalFix.apply(appID: 77, gameFolder: game, fixFiles: [stray.path])

        let nowLoaded = try String(contentsOf: loaded, encoding: .utf8)
        #expect(nowLoaded == "proxy api for the fix")
        #expect(FileManager.default.fileExists(atPath: loaded.path + ".onlinefix-backup"))
        // A temporary folder is reached through /var, which resolves to /private/var:
        // compare the real path rather than the spelling.
        let resolved = { (path: String) in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        #expect(report.additions.map(resolved).contains(resolved(loaded.path)))
    }
}
