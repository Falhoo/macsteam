import Foundation
import Testing
@testable import OnlineFixApp

/// Which build Steam starts decides what the store card says. The folder is the
/// answer, because that is what Steam launches from; a fix's record only breaks the
/// tie between two builds that are both there.
@Suite struct BuildInUseTests {

    /// A throwaway folder with the shapes a game folder takes. The binaries have to be
    /// real Mach-O and PE files, since that is what the detection reads.
    struct FakeFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        func cleanUp() { try? FileManager.default.removeItem(at: url) }
        func make(mac: Bool, windows: Bool) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if mac {
                let macos = url.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)
                try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                                 to: macos.appendingPathComponent("Game"))
            }
            if windows {
                try FixFixture.peExecutable().write(to: url.appendingPathComponent("Game.exe"))
            }
        }
    }

    private func record(in root: URL, mac: Bool) throws {
        var recipe = FixRecipe(appID: 1, name: "G", installedAt: Date(), packageName: "",
                               findings: [], entries: [], removed: [], keepRealAppID: false,
                               photonSwap: false, picoPark2: false, wineDLLs: [])
        recipe.macBuild = mac
        try FixPack.write(recipe, in: root)
    }

    @Test func theFolderSpeaksFirst() throws {
        let windowsOnly = FakeFolder()
        try windowsOnly.make(mac: false, windows: true)
        defer { windowsOnly.cleanUp() }
        // A Mac record left behind must not outlive the .app Steam removed.
        try record(in: windowsOnly.url, mac: true)
        #expect(GameBuildInUse.resolve(appID: 1, folder: windowsOnly.url) == .windows)

        let macOnly = FakeFolder()
        try macOnly.make(mac: true, windows: false)
        defer { macOnly.cleanUp() }
        try record(in: macOnly.url, mac: false)
        #expect(GameBuildInUse.resolve(appID: 1, folder: macOnly.url) == .mac)
    }

    /// Both builds on disk: Steam left the Windows one there, which is the one a fix
    /// can work with, so that is the answer whatever a record says.
    @Test func bothPresentMeansWindows() throws {
        let both = FakeFolder()
        try both.make(mac: true, windows: true)
        defer { both.cleanUp() }
        #expect(GameBuildInUse.resolve(appID: 1, folder: both.url) == .windows)
        try record(in: both.url, mac: true)
        #expect(GameBuildInUse.resolve(appID: 1, folder: both.url) == .windows)
    }

    /// An `.app` left behind by Steam holds no executable; it is not a Mac build.
    @Test func anEmptyAppDoesNotCount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Game.app/Contents/MacOS"), withIntermediateDirectories: true)
        try FixFixture.peExecutable().write(to: root.appendingPathComponent("Game.exe"))
        #expect(FixInstaller.nativeMacBundle(in: root) == nil)
        #expect(GameBuildInUse.resolve(appID: 1, folder: root) == .windows)
        // Nor does a helper executable count as the game.
        #expect(FixInstaller.windowsExecutables(in: root).map(\.lastPathComponent) == ["Game.exe"])
    }

    @Test func noBuildAtAll() throws {
        let empty = FakeFolder()
        try empty.make(mac: false, windows: false)
        defer { empty.cleanUp() }
        #expect(GameBuildInUse.resolve(appID: 1, folder: empty.url) == .none)
        #expect(GameBuildInUse.resolve(appID: 1, folder: nil) == .none)
    }
}

/// The smallest thing that passes as a PE executable: `MZ`, the PE header offset, and
/// the `PE\0\0` marker where it points.
enum FixFixture {
    static func peExecutable() -> Data {
        var data = Data(repeating: 0, count: 0x80)
        data[0] = 0x4d; data[1] = 0x5a
        data[0x3c] = 0x40
        data[0x40] = 0x50; data[0x41] = 0x45; data[0x42] = 0; data[0x43] = 0
        return data
    }
}
