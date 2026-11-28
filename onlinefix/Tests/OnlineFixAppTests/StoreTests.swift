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

    /// `machO: true` writes a Mach-O head in front of the text, so the file reads as
    /// an executable the way a real game's does.
    private func write(_ text: String, to url: URL, machO: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(text.utf8)
        if machO { data = Data([0xcf, 0xfa, 0xed, 0xfe]) + data }
        try data.write(to: url)
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

    /// An active update/download is not an install, whatever is already on disk.
    @Test
    func aManifestThatIsStillDownloadingIsNotInstalled() throws {
        let game = try folder("downloading")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        let acf = try manifest(26, in: game) // update required + queued + running

        #expect(!Store.isInstalled(appID: 1, folder: game, manifest: acf))
    }

    /// Steam writes "Update Required" while the game is still fully on disk.
    /// Treating that as missing sent players to a fresh download of a game they
    /// already had (common with a family-shared copy).
    @Test
    func anUpdateRequiredManifestStillUsesTheInstalledFiles() throws {
        let game = try folder("update-required")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        let acf = try manifest(2, in: game)

        #expect(Store.isInstalled(appID: 1, folder: game, manifest: acf))
    }

    /// Uninstalled wins even if an old folder was left behind.
    @Test
    func anUninstalledManifestIsNotInstalledEvenWithFiles() throws {
        let game = try folder("uninstalled")
        defer { try? FileManager.default.removeItem(at: game) }
        try write("MZ", to: game.appendingPathComponent("Game.exe"))
        let acf = try manifest(1, in: game)

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
        try write("binary", to: game.appendingPathComponent("Game.app/Contents/MacOS/Game"), machO: true)

        #expect(Store.isInstalled(appID: 1, folder: game))
    }
}
