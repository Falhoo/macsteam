// A Mac build takes no OnlineFix files; what is left is the identity Steam starts
// it with. These cover how the app decides that.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct MacAppFixTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    private func bundle(in root: URL, steam: Bool) throws -> URL {
        let game = root.appendingPathComponent("Game", isDirectory: true)
        let app = game.appendingPathComponent("Game.app", isDirectory: true)
        try write(steam ? "SteamAPI_Init" : "hello",
                  to: app.appendingPathComponent("Contents/MacOS/Game"), machO: true)
        if steam {
            try write("dylib", to: app.appendingPathComponent("Contents/Frameworks/libsteam_api.dylib"))
        }
        return game
    }

    @Test
    func aWindowsOnlyFolderIsNotAMacBuild() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("exe", to: game.appendingPathComponent("Game.exe"))

        #expect(MacAppFix.status(gameFolder: game) == nil)
    }

    @Test
    func aMacBuildWithSteamGetsTheRoutingStory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = try bundle(in: root, steam: true)

        let status = MacAppFix.status(gameFolder: game)

        #expect(status?.hasSteamAPI == true)
        #expect(status?.message.contains("Spacewar (480)") == true)
        // The story is now about where the fix goes, not about there being nothing
        // to install: a Mac build is patched in its own files when it has a place.
        #expect(status?.summary.contains("routing is its fix") == true)
        #expect(status?.summary.contains("nothing to install") == false)
    }

    @Test
    func aMacBuildWithoutSteamSaysRoutingDoesNotApply() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = try bundle(in: root, steam: false)

        let status = MacAppFix.status(gameFolder: game)

        #expect(status?.hasSteamAPI == false)
        #expect(status?.message.contains("nothing to route") == true)
    }
}
