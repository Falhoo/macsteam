// Installing a fix archive: everything that ships with the Steam API DLL has to
// go in, or the game cannot load it and never starts.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixInstallerTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixinstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// OnlineFix's steam_api64.dll imports OnlineFix64.dll and SteamOverlay64.dll.
    /// Copying only the API DLL left the game unable to start (c0000135) while
    /// Steam still showed it running.
    @Test
    func installsEveryFileBesideTheSteamAPIDLL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("fixed api", to: fix.appendingPathComponent("steam_api64.dll"))
        try write("onlinefix core", to: fix.appendingPathComponent("OnlineFix64.dll"))
        try write("overlay", to: fix.appendingPathComponent("SteamOverlay64.dll"))
        try write("[Main]\nRealAppId=1\n", to: fix.appendingPathComponent("OnlineFix.ini"))
        try write("notes", to: fix.appendingPathComponent("docs/readme.txt"))

        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("original api", to: game.appendingPathComponent("steam_api64.dll"))
        try write("game", to: game.appendingPathComponent("Buckshot Roulette.exe"))

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }

        let files = Set(result.files.map { ($0 as NSString).lastPathComponent })
        #expect(files.contains("steam_api64.dll"))
        #expect(files.contains("OnlineFix64.dll"))
        #expect(files.contains("SteamOverlay64.dll"))
        #expect(files.contains("OnlineFix.ini"))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("SteamOverlay64.dll").path))
        // The replaced DLL is kept so Uninstall can put it back.
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("steam_api64.dll.onlinefix-backup").path))
    }

    /// A fix with no Steam API DLL is a tree to merge into the game folder.
    @Test
    func mergesAWholeFolderFix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("data", to: fix.appendingPathComponent("Buckshot Roulette_windows/Extra/data.ini"))
        let game = root.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)

        let result = try FixInstaller.installExtracted(from: fix, into: game) { _ in }
        #expect(result.files.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("Buckshot Roulette_windows/Extra/data.ini").path))
    }

    /// A record is only "installed" while its files are on disk. Steam restores a
    /// game's own files on an update or a verify, which removes the fix, and the
    /// record that stays behind must not make the game look fixed.
    @Test
    func stateFollowsTheFilesOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = root.appendingPathComponent("steam_api64.dll")
        try write("fixed api", to: kept)
        let record = FixRecord(id: 1, gameName: "Game", files: [kept.path])

        #expect(FixInstaller.state(of: record) == .installed)
        #expect(FixInstaller.isInstalled(record))

        try FileManager.default.removeItem(at: kept)

        #expect(FixInstaller.state(of: record) == .missing([kept.path]))
        #expect(!FixInstaller.isInstalled(record))
    }

    /// Steam runs a native macOS bundle, not the Windows build, so OnlineFix has
    /// nothing to patch there.
    @Test
    func spotsANativeMacBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FixInstaller.nativeMacBundle(in: root) == nil)

        let macos = root.appendingPathComponent("Terraria.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        #expect(FixInstaller.nativeMacBundle(in: root)?.lastPathComponent == "Terraria.app")
    }
}
