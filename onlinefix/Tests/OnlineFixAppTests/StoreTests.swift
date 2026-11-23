// What counts as an installed game: the files a fix is built from, not just a folder
// with the game's name on it.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct StoreTests {

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// An app manifest as Steam writes one, with only the flags this reads.
    private func manifest(_ flags: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("appmanifest_1.acf")
        try write("""
        "AppState"
        {
            "appid"     "1"
            "StateFlags"        "\(flags)"
        }
        """, to: url)
        return url
    }

    @Test
    func aFolderWithTheGamesExecutableIsInstalled() throws {
        let game = try folder("full")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))

        #expect(Store.hasGameFiles(in: game))
        #expect(Store.isInstalled(appID: 1, folder: game))
    }

    /// Steam makes the folder before it writes anything, and a cancelled download
    /// leaves one behind. There is nothing for the scan to read in it.
    @Test
    func anEmptyFolderIsNotInstalled() throws {
        let game = try folder("empty")
        defer { try? FileManager.default.removeItem(at: game) }

        #expect(!Store.hasGameFiles(in: game))
        #expect(!Store.isInstalled(appID: 1, folder: game))
        #expect(!Store.isInstalled(appID: 1, folder: nil))
    }

    /// The fix's own files are not the game: a folder holding only those is not an
    /// install, and the scan would have nothing to say about the game.
    @Test
    func aFolderWithOnlyFixFilesIsNotInstalled() throws {
        let game = try folder("fixonly")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("x", to: game.appendingPathComponent("OnlineFix64.dll"))
        try write("x", to: game.appendingPathComponent("OnlineFix.ini"))
        try write("x", to: game.appendingPathComponent("winmm.dll"))

        #expect(!Store.isInstalled(appID: 1, folder: game))
    }

    /// A download in progress is not an install, whatever is already on disk.
    @Test
    func aManifestThatIsStillDownloadingIsNotInstalled() throws {
        let game = try folder("downloading")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        let acf = try manifest(2, in: game)

        #expect(!Store.isInstalled(appID: 1, folder: game, manifest: acf))
    }

    @Test
    func aFullyInstalledManifestIsInstalled() throws {
        let game = try folder("done")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        let acf = try manifest(4, in: game)

        #expect(Store.isInstalled(appID: 1, folder: game, manifest: acf))
    }

    /// A Mac build is read from its bundle, so it counts as installed too.
    @Test
    func aMacBundleIsInstalled() throws {
        let game = try folder("mac")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("binary", to: game.appendingPathComponent("Game.app/Contents/MacOS/Game"))

        #expect(Store.isInstalled(appID: 1, folder: game))
    }
}
