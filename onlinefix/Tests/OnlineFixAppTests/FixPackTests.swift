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

    /// A realtime id can live in an assembly and the pair in an asset. Each file only
    /// has to hold the ids it carried, or the second file can hide a restored first.
    @Test
    func eachPatchedFileIsCheckedForItsOwnIDs() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        let realtime = "11111111-2222-3333-4444-555555555555"
        let voice = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        let a = game.appendingPathComponent("Game_Data/Managed/Assembly-CSharp.dll")
        let b = game.appendingPathComponent("Game_Data/resources.assets")
        try write("patched \(realtime)", to: a)
        try write("patched \(realtime) and \(voice)", to: b)
        try write("stock", to: a.appendingPathExtension("onlinefix-photon-backup"))
        try write("stock", to: b.appendingPathExtension("onlinefix-photon-backup"))

        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [], removed: [], keepRealAppID: false,
            photonSwap: true, picoPark2: false,
            photonPatched: ["Game_Data/Managed/Assembly-CSharp.dll",
                            "Game_Data/resources.assets"],
            photonIDs: [realtime, voice],
            photonFileIDs: ["Game_Data/Managed/Assembly-CSharp.dll": [realtime],
                            "Game_Data/resources.assets": [realtime, voice]],
            wineDLLs: [])
        try FixPack.write(recipe, in: game)
        #expect(FixPack.verify(in: game).isEmpty)

        try write("stock", to: a)
        #expect(FixPack.verify(in: game) == ["Game_Data/Managed/Assembly-CSharp.dll"])
    }

    /// A custom id from the patch sheet is not one the scanner knows, so syncing must
    /// record the bytes the manual patch actually wrote instead of dropping the file.
    @Test
    func aManualCustomPhotonTargetIsRecorded() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        let custom = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let asset = game.appendingPathComponent("Game_Data/resources.assets")
        try write("patched \(custom)", to: asset)
        try write("stock", to: asset.appendingPathExtension("onlinefix-photon-backup"))

        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [], removed: [], keepRealAppID: false,
            photonSwap: true, picoPark2: false, wineDLLs: [])
        try FixPack.write(recipe, in: game)

        FixPack.syncPhotonTargets(in: game, targets: [custom])
        let synced = FixPack.read(in: game)
        #expect(synced?.photonPatched == ["Game_Data/resources.assets"])
        #expect(synced?.photonIDs == [custom])
        #expect(synced?.photonFileIDs?["Game_Data/resources.assets"] == [custom])
        #expect(FixPack.verify(in: game).isEmpty)

        FixPack.syncPhotonTargets(in: game, targets: [])
        let cleared = FixPack.read(in: game)
        #expect(cleared?.photonPatched?.isEmpty == true)
        #expect(cleared?.photonIDs?.isEmpty == true)
    }

    /// A Steam verify puts the game's own asset back; the pack has to notice that its
    /// Photon ids are no longer in the file, not just compare the files it copied.
    @Test
    func aRestoredPhotonAssetIsNoticedAndPatchedAgain() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        let assets = game.appendingPathComponent("Game_Data/resources.assets")
        let realtime = "11111111-2222-3333-4444-555555555555"
        let voice = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        try write("stock \(PhotonIDs.realtime) and \(PhotonIDs.voice)", to: assets)
        try write("patched \(realtime) and \(voice)",
                  to: assets.appendingPathExtension("onlinefix-photon-backup"))

        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [], removed: [], keepRealAppID: false,
            photonSwap: true, picoPark2: false,
            photonPatched: ["Game_Data/resources.assets"],
            photonIDs: [realtime, voice], wineDLLs: [])
        try FixPack.write(recipe, in: game)
        #expect(FixPack.verify(in: game) == ["Game_Data/resources.assets"])

        try write("patched \(realtime) and \(voice)", to: assets)
        #expect(FixPack.verify(in: game).isEmpty)
    }

    /// The plan can say a file is removed, but only the apply knows whether it could
    /// be moved. The recipe has to store what happened, not what was intended.
    @Test
    func onlyTheFilesActuallyRemovedAreRecorded() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        let overlay = game.appendingPathComponent("GameOverlayRenderer64.dll")
        try write("the renderer", to: overlay)

        var plan = FixPlan()
        plan.removals = [FixPlan.Removal(path: overlay, reason: "it stops the game")]
        let applied = try FixApply.apply(plan, appID: 42, folder: game)
        #expect(applied.removed == ["GameOverlayRenderer64.dll"])
        #expect(!FileManager.default.fileExists(atPath: overlay.path))
        #expect(contents(overlay.appendingPathExtension("onlinefix-removed")) == "the renderer")

        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [], removed: applied.removed, keepRealAppID: false,
            photonSwap: false, picoPark2: false, wineDLLs: [])
        try FixPack.write(recipe, in: game)
        #expect(try FixPack.undo(in: game) == 1)
        #expect(contents(overlay) == "the renderer")
    }

    /// What undo used to lose: a removed file was deleted outright, and the Photon
    /// swap changes the game's own assets without putting a copy in `entries`.
    @Test
    func undoRestoresRemovalsAndPhotonBackups() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }

        let renderer = game.appendingPathComponent("GameOverlayRenderer64.dll")
        try write("the game's renderer", to: renderer.appendingPathExtension("onlinefix-removed"))
        let assets = game.appendingPathComponent("Game_Data/resources.assets")
        try write("already patched", to: assets)
        try write("the game's own assets", to: assets.appendingPathExtension("onlinefix-photon-backup"))

        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [], removed: ["GameOverlayRenderer64.dll"],
            keepRealAppID: false, photonSwap: true, picoPark2: false,
            photonPatched: ["Game_Data/resources.assets"], wineDLLs: [])
        try FixPack.write(recipe, in: game)

        let changed = try FixPack.undo(in: game)
        #expect(changed == 2)
        #expect(contents(renderer) == "the game's renderer")
        #expect(contents(assets) == "the game's own assets")
        #expect(!FileManager.default.fileExists(atPath: assets.path + ".onlinefix-photon-backup"))
        #expect(!FixPack.hasPack(in: game))
    }

    /// The pack is the only copy of what the fix replaced. A failed restore must not
    /// delete it, or the game has neither version.
    @Test
    func aFailedUndoKeepsThePackAndTheGameFile() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        let replaced = game.appendingPathComponent("steam_api64.dll")
        try write("the fix's api", to: replaced)
        let recipe = FixRecipe(
            appID: 42, name: "Game", installedAt: Date(), packageName: "fix.rar",
            findings: [], entries: [FixRecipe.Entry(
                path: "steam_api64.dll", size: 12, sha256: "x", created: false)],
            removed: [], keepRealAppID: false, photonSwap: false, picoPark2: false,
            wineDLLs: [])
        try FixPack.write(recipe, in: game)

        #expect(throws: ManagerError.self) { _ = try FixPack.undo(in: game) }
        #expect(contents(replaced) == "the fix's api")
        #expect(FixPack.hasPack(in: game))
    }

    /// A recipe is a file inside the game folder; a path in it may not reach outside.
    @Test
    func aRecipePathCannotLeaveTheGameFolder() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        #expect(FixPack.file("../outside.dll", in: game) == nil)
        #expect(FixPack.file("/tmp/outside.dll", in: game) == nil)
        #expect(FixPack.file("Game_Data/resources.assets", in: game) != nil)
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
