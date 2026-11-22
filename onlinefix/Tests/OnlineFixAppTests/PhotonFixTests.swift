// OnlineFix's Photon patch only runs through the BepInEx chain. A fix that ships
// the managed patch but not the doorstop looks installed and still fails in game,
// so the chain is checked piece by piece.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonFixTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonfix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A Photon game with the whole chain in place has nothing to report.
    @Test
    func aCompleteChainSaysNothing() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        try write("managed", to: game.appendingPathComponent("REPO_Data/Managed/PhotonRealtime.dll"))
        try write("game", to: game.appendingPathComponent("REPO.exe"))
        try write("doorstop", to: game.appendingPathComponent("winmm.dll"))
        try write("preloader", to: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
        try write("plugin", to: game.appendingPathComponent("Custom.dll"))

        let status = PhotonFix.status(gameFolder: game, fixInstalled: true)
        #expect(status.isPhoton)
        #expect(status.isComplete)
        #expect(status.message == nil)
    }

    /// A fix installed without its doorstop or its plugin is named as such: that is
    /// the state that gives "CustomAuthenticationError" in game.
    @Test
    func aPartlyInstalledFixNamesWhatIsMissing() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        try write("managed", to: game.appendingPathComponent("REPO_Data/Managed/PhotonRealtime.dll"))
        try write("game", to: game.appendingPathComponent("REPO.exe"))
        try write("preloader", to: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))

        let status = PhotonFix.status(gameFolder: game, fixInstalled: true)
        #expect(status.isIncomplete)
        #expect(status.missing.map(\.file) == ["winmm.dll", "Custom.dll"])
        let message = status.message ?? ""
        #expect(message.contains("winmm.dll"))
        #expect(message.contains("Custom.dll"))
        #expect(message.contains("CustomAuthenticationError"))
    }

    /// The plugin is found in BepInEx's plugins folder too, which is where some
    /// versions of the fix put it.
    @Test
    func thePluginCountsInThePluginsFolder() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        try write("managed", to: game.appendingPathComponent("REPO_Data/Managed/PhotonRealtime.dll"))
        try write("game", to: game.appendingPathComponent("REPO.exe"))
        try write("doorstop", to: game.appendingPathComponent("winmm.dll"))
        try write("preloader", to: game.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
        try write("plugin", to: game.appendingPathComponent("BepInEx/plugins/Custom.dll"))

        #expect(PhotonFix.status(gameFolder: game, fixInstalled: true).isComplete)
    }

    /// A game with no fix, or one whose online play is not Photon, has nothing to say.
    @Test
    func onlyFixedPhotonGamesAreReported() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        try write("managed", to: game.appendingPathComponent("REPO_Data/Managed/PhotonRealtime.dll"))
        try write("game", to: game.appendingPathComponent("REPO.exe"))

        #expect(!PhotonFix.status(gameFolder: game, fixInstalled: false).isPhoton)
        // No fix means no chain to check, and a Photon game whose fix ships no
        // Photon patch is not warned about either.
        #expect(PhotonFix.status(gameFolder: game, fixInstalled: true).message == nil)
        #expect(PhotonFix.status(gameFolder: game, fixInstalled: true,
                                 fixFiles: ["steam_api64.dll", "OnlineFix64.dll"]).message == nil)
        // A fix that does ship the patch is checked.
        #expect(PhotonFix.status(gameFolder: game, fixInstalled: true,
                                 fixFiles: ["winmm.dll", "Custom.dll"]).message != nil)

        let plain = try folder()
        defer { try? FileManager.default.removeItem(at: plain) }
        try write("managed", to: plain.appendingPathComponent("Game_Data/Managed/Assembly-CSharp.dll"))
        #expect(!PhotonFix.status(gameFolder: plain, fixInstalled: true).isPhoton)
    }

    /// PEAK's fix is a GDK one with no BepInEx or Custom.dll at all. There is no
    /// Photon patch to load, so nothing is missing and the game must not be warned.
    @Test
    func aPhotonGameWhoseFixHasNoPatchIsNotWarned() throws {
        let game = try folder()
        defer { try? FileManager.default.removeItem(at: game) }
        try write("managed", to: game.appendingPathComponent("PEAK_Data/Managed/PhotonRealtime.dll"))
        try write("game", to: game.appendingPathComponent("PEAK.exe"))
        try write("proxy", to: game.appendingPathComponent("winmm.dll"))

        let fix = ["wdapp.exe", "winmm.dll", "OnlineFix.url", "OnlineFix64.dll",
                   "xsapi.dll", "GDK_Helper.bat", "OnlineFix.ini", "dlllist.txt"]
            .map { game.appendingPathComponent($0).path }

        let status = PhotonFix.status(gameFolder: game, fixInstalled: true, fixFiles: fix)
        #expect(!status.isPhoton)
        #expect(status.message == nil)
    }

    /// The doorstop and the BepInEx tree load from beside Unity's executable, not
    /// from the folder the Steam API DLL happens to live in.
    @Test
    func theLoaderChainBelongsAtTheGameRoot() {
        #expect(PhotonFix.belongsAtGameRoot("winmm.dll"))
        #expect(PhotonFix.belongsAtGameRoot("Custom.dll"))
        #expect(PhotonFix.belongsAtGameRoot("BepInEx/core/BepInEx.Preloader.dll"))
        #expect(PhotonFix.belongsAtGameRoot("BepInEx\\plugins\\Custom.dll"))
        #expect(!PhotonFix.belongsAtGameRoot("REPO_Data/Plugins/x86_64/OnlineFix64.dll"))
        #expect(!PhotonFix.belongsAtGameRoot("OnlineFix.ini"))
        #expect(!PhotonFix.belongsAtGameRoot("dlllist.txt"))
    }
}
