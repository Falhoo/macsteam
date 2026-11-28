// The facts about a game folder the fix kit reads, and the record of what an
// install wrote: where Steam starts the game from, which Steam API DLL it loads,
// and whether a recorded fix is still the fix's own files.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixInstallerTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixinstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test
    func stateFollowsTheFilesOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("OnlineFix64.dll")
        let gone = root.appendingPathComponent("winmm.dll")
        try write("payload", to: kept)

        let record = FixRecord(id: 1, gameName: "Game", files: [kept.path, gone.path],
                               sizes: FixInstaller.sizes(of: [kept.path]))
        #expect(FixInstaller.state(of: record) == .missing([gone.path]))
        #expect(!FixInstaller.isInstalled(record))

        try write("proxy", to: gone)
        #expect(FixInstaller.state(of: record) == .installed)
        #expect(FixInstaller.isInstalled(record))
    }

    /// A Steam verify puts the game's own file back at the same path, so a record
    /// that only remembers paths would call it fixed.
    @Test
    func legacyUninstallRestoresAPhotonBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = root.appendingPathComponent("Game_Data/resources.assets")
        try write("patched", to: asset)
        try write("stock", to: asset.appendingPathExtension("onlinefix-photon-backup"))
        let record = FixRecord(id: 1, gameName: "Game", files: [asset.path])

        #expect(try FixInstaller.uninstall(record) == 1)
        #expect((try? String(contentsOf: asset, encoding: .utf8)) == "stock")
        #expect(!FileManager.default.fileExists(
            atPath: asset.appendingPathExtension("onlinefix-photon-backup").path))
    }

    @Test
    func stateNoticesAFileSteamPutBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let api = root.appendingPathComponent("steam_api64.dll")
        try write("the fix's api", to: api)
        let sizes = FixInstaller.sizes(of: [api.path])
        let record = FixRecord(id: 1, gameName: "Game", files: [api.path], sizes: sizes)
        #expect(FixInstaller.state(of: record) == .installed)

        try write("the game's own api, a different size", to: api)
        #expect(FixInstaller.state(of: record) == .missing([api.path]))
    }

    /// The files a player may edit, and the overlay, do not make a fix "missing".
    @Test
    func editedFilesAndTheOverlayDoNotUnfixTheGame() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ini = root.appendingPathComponent("OnlineFix.ini")
        let list = root.appendingPathComponent("dlllist.txt")
        let overlay = root.appendingPathComponent("GameOverlayRenderer64.dll")
        try write("[Main]\nRealAppId=1\n", to: ini)
        try write("OnlineFix64.dll\n", to: list)
        try write("overlay", to: overlay)

        let record = FixRecord(id: 1, gameName: "Game",
                               files: [ini.path, list.path, overlay.path],
                               sizes: FixInstaller.sizes(of: [ini.path, list.path, overlay.path]))
        #expect(FixInstaller.isEditable(ini.path))
        #expect(FixInstaller.isEditable(list.path))
        #expect(FixInstaller.isOptional(overlay.path))

        // The player edits the ini, and the overlay loader is taken away.
        try write("[Main]\nRealAppId=1\nPhotonIntegration=true\n", to: ini)
        try? FileManager.default.removeItem(at: overlay)
        #expect(FixInstaller.state(of: record) == .installed)
    }

    @Test
    func spotsANativeMacBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FixInstaller.nativeMacBundle(in: root) == nil)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Terraria.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        try TestBundle.writeBinary(to: root.appendingPathComponent("Terraria.app/Contents/MacOS/Terraria"))
        #expect(FixInstaller.nativeMacBundle(in: root)?.lastPathComponent == "Terraria.app")
        #expect(!FixInstaller.hasWindowsBuild(in: root))
    }

    /// The folder Steam starts the game from: the one holding its executable, even
    /// when the game is wrapped in a folder of its own.
    @Test
    func findsTheLaunchFolderAndTheSteamAPIDLL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("exe", to: root.appendingPathComponent("Game.exe"))
        try write("api", to: root.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll"))

        #expect(FixInstaller.launchFolder(in: root)?.lastPathComponent == root.lastPathComponent)
        let api = try FixInstaller.findExistingAPIDLL(in: root)
        #expect(api?.lastPathComponent == "steam_api64.dll")
        #expect(api?.deletingLastPathComponent().lastPathComponent == "x86_64")

        let wrapped = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: wrapped) }
        try write("exe", to: wrapped.appendingPathComponent("wrapped/Game.exe"))
        #expect(FixInstaller.launchFolder(in: wrapped)?.lastPathComponent == "wrapped")
    }
}
