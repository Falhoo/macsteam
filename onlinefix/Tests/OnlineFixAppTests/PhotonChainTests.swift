// The BepInEx chain OnlineFix's Photon patch runs through, and the doorway a game
// can actually load.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonChainTests {

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// PEAK: the import table of UnityPlayer.dll spells it "WINHTTP.dll", and there is
    /// no winmm import at all. OnlineFix's winmm doorway never ran there.
    @Test
    func theDoorwayIsTheOneTheGameImports() throws {
        let game = try folder("peak")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("PEAK.exe"))
        try write("... WINHTTP.dll ... kernel32.dll ...",
                  to: game.appendingPathComponent("UnityPlayer.dll"))

        #expect(PhotonChain.doorway(in: game, exe: game.appendingPathComponent("PEAK.exe"))
                == "winhttp.dll")
    }

    @Test
    func aGameThatImportsWinmmGetsThatDoorway() throws {
        let game = try folder("winmm")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        try write("... winmm.dll ...", to: game.appendingPathComponent("UnityPlayer.dll"))

        #expect(PhotonChain.doorway(in: game, exe: game.appendingPathComponent("Game.exe"))
                == "winmm.dll")
    }

    @Test
    func aGameWithNoneOfThemSaysSo() throws {
        let game = try folder("none")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        #expect(PhotonChain.doorway(in: game, exe: game.appendingPathComponent("Game.exe")) == nil)
    }

    /// What a package carrying only the plugin and the preloader looks like: the
    /// chain is not there, and the missing list names what is.
    @Test
    func aPartialChainIsReportedMissing() throws {
        let game = try folder("partial")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("plugin", to: game.appendingPathComponent("Custom.dll"))
        try write("preloader",
                  to: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))

        let missing = PhotonChain.missing(in: game, doorway: "winhttp.dll")
        #expect(missing.contains("winhttp.dll"))
        #expect(missing.contains("BepInEx/core/BepInEx.dll"))
        #expect(missing.contains("BepInEx/plugins/Custom.dll"))
        #expect(!PhotonChain.isComplete(in: game, doorway: "winhttp.dll"))
    }

    /// Installing copies the doorway the game imports, the core and the plugin, and
    /// leaves the doorway it does not import out.
    @Test
    func installingWritesTheChainTheGameCanLoad() throws {
        let bundle = try folder("bundle")
        let game = try folder("game")
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: game)
        }
        for path in [PhotonChain.config, "winhttp.dll", "winmm.dll"] + PhotonChain.core
                    + [PhotonChain.plugin] {
            try write("x", to: bundle.appendingPathComponent(path))
        }

        let written = try PhotonChain.install(into: game, from: bundle,
                                              doorway: "winhttp.dll")
        #expect(written.contains("winhttp.dll"))
        #expect(!written.contains("winmm.dll"))
        #expect(PhotonChain.isComplete(in: game, doorway: "winhttp.dll"))
        #expect(!FileManager.default.fileExists(
            atPath: game.appendingPathComponent("winmm.dll").path))
    }
}
