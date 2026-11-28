import Foundation
import Testing
@testable import OnlineFixApp

/// Which build Steam starts decides what the store card says. The folder is the
/// answer, because that is what Steam launches from; a fix's record only breaks the
/// tie between two builds that are both there.
@Suite struct BuildInUseTests {

    private func folder(mac: Bool, windows: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        if mac {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Game.app/Contents/MacOS"),
                withIntermediateDirectories: true)
        }
        if windows {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("Game.exe"))
        }
        if !mac && !windows {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func record(in root: URL, mac: Bool) throws {
        var recipe = FixRecipe(appID: 1, name: "G", installedAt: Date(), packageName: "",
                               findings: [], entries: [], removed: [], keepRealAppID: false,
                               photonSwap: false, picoPark2: false, wineDLLs: [])
        recipe.macBuild = mac
        try FixPack.write(recipe, in: root)
    }

    @Test func theFolderSpeaksFirst() throws {
        let windowsOnly = try folder(mac: false, windows: true)
        defer { try? FileManager.default.removeItem(at: windowsOnly) }
        // A Mac record left behind must not outlive the .app Steam removed.
        try record(in: windowsOnly, mac: true)
        #expect(GameBuildInUse.resolve(appID: 1, folder: windowsOnly) == .windows)

        let macOnly = try folder(mac: true, windows: false)
        defer { try? FileManager.default.removeItem(at: macOnly) }
        try record(in: macOnly, mac: false)
        #expect(GameBuildInUse.resolve(appID: 1, folder: macOnly) == .mac)
    }

    @Test func theRecordBreaksTheTie() throws {
        let both = try folder(mac: true, windows: true)
        defer { try? FileManager.default.removeItem(at: both) }
        #expect(GameBuildInUse.resolve(appID: 1, folder: both) == .mac)
        try record(in: both, mac: false)
        #expect(GameBuildInUse.resolve(appID: 1, folder: both) == .windows)
    }

    @Test func noBuildAtAll() throws {
        let empty = try folder(mac: false, windows: false)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(GameBuildInUse.resolve(appID: 1, folder: empty) == .none)
        #expect(GameBuildInUse.resolve(appID: 1, folder: nil) == .none)
    }
}
