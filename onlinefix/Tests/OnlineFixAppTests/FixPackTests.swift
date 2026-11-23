// The pack in the game folder: what a repair and an undo read from.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixPackTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
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

    /// A pack for a game the fix changed: one file it added, one it replaced.
    private func makePack(in game: URL) throws -> FixRecipe {
        let added = game.appendingPathComponent("OnlineFix64.dll")
        try write("payload one", to: added)
        let replaced = game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll")
        try write("the fix's api", to: replaced)
        try write("the game's own api", to: replaced.appendingPathExtension("onlinefix-backup"))

        var recipe = FixRecipe(appID: 42, name: "Game", installedAt: Date(),
                               packageName: "fix.rar", findings: [], entries: [],
                               removed: [], keepRealAppID: false, photonSwap: false,
                               picoPark2: false, wineDLLs: [])
        for (url, created) in [(added, true), (replaced, false)] {
            let relative = FixPlan.relative(url, in: game)
            recipe.entries.append(FixRecipe.Entry(
                path: relative,
                size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                sha256: Hash.sha256(url) ?? "",
                created: created))
        }
        try FixPack.write(recipe, in: game)
        return recipe
    }

    @Test
    func aPackReadsBackAndVerifies() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        _ = try makePack(in: game)

        let read = FixPack.read(in: game)
        #expect(read?.appID == 42)
        #expect(read?.entries.count == 2)
        #expect(read?.summary.contains("2 file(s)") == true)
        #expect(FixPack.verify(in: game).isEmpty)
        // The payload holds the fix's own files, not the game's.
        #expect(contents(FixPack.payloadURL(in: game, for: "Game_Data/Plugins/x86_64/steam_api64.dll"))
            == "the fix's api")
    }

    @Test
    func aSteamVerifyIsNoticedAndPutRight() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        _ = try makePack(in: game)

        // Steam puts the game's own file back.
        let replaced = game.appendingPathComponent("OnlineFix64.dll")
        try write("something else", to: replaced)
        let changed = FixPack.verify(in: game)
        #expect(changed == ["OnlineFix64.dll"])

        let restored = FixPack.restore(changed, in: game)
        #expect(restored == ["OnlineFix64.dll"])
        #expect(contents(replaced) == "payload one")
        #expect(FixPack.verify(in: game).isEmpty)
    }

    @Test
    func undoPutsTheGameBackAndTakesThePackAway() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        _ = try makePack(in: game)

        let changed = try FixPack.undo(in: game)
        #expect(changed == 2)
        // What the fix added is gone, and what it replaced is the game's own again.
        #expect(!FileManager.default.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(contents(game.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll"))
            == "the game's own api")
        #expect(!FixPack.hasPack(in: game))
    }
}
