// The real RV There Yet? fix archive, unpacked: the Steam API DLL deep in the
// Engine tree and the loader (OnlineFix64.dll + its winmm proxy) next to the
// game's executable. Nothing sits at the archive root.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixTreeTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixtree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private let apiPath = "Engine/Binaries/ThirdParty/Steamworks/Steamv16/Win64/steam_api64.dll"
    private let binPath = "Ride/Binaries/Win64"

    /// The archive online-fix.me publishes for RV There Yet?, file for file.
    private func rideFix(in root: URL) throws -> URL {
        let fix = root.appendingPathComponent("fix", isDirectory: true)
        try write("fixed api", to: fix.appendingPathComponent(apiPath))
        try write("[Main]\n", to: fix.appendingPathComponent("\(binPath)/OnlineFix.ini"))
        try write("https://online-fix.me", to: fix.appendingPathComponent("\(binPath)/OnlineFix.url"))
        try write("onlinefix core", to: fix.appendingPathComponent("\(binPath)/OnlineFix64.dll"))
        try write("OnlineFix64.dll\n", to: fix.appendingPathComponent("\(binPath)/dlllist.txt"))
        try write("proxy", to: fix.appendingPathComponent("\(binPath)/winmm.dll"))
        return fix
    }

    private func rideGame(in root: URL) throws -> URL {
        let game = root.appendingPathComponent("game", isDirectory: true)
        try write("original api", to: game.appendingPathComponent(apiPath))
        try write("exe", to: game.appendingPathComponent("\(binPath)/Ride-Win64-Shipping.exe"))
        return game
    }

    /// The loader goes beside the executable and the Steam API DLL where the game
    /// already loads one, with the game's own copy kept.
    @Test
    func theRealFixLandsWhereTheGameLoadsIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fix = try rideFix(in: root)
        let game = try rideGame(in: root)

        let scan = GameScan.read(folder: game, appID: 1, name: "Ride")
        #expect(scan.launchFolder.path.hasSuffix(binPath))
        let plan = FixPlan.build(appID: 1, name: "Ride", scan: scan,
                                 package: FixPackage.read(root: fix))
        _ = try FixApply.apply(plan, appID: 1, folder: game)

        let fm = FileManager.default
        for name in ["OnlineFix64.dll", "OnlineFix.ini", "OnlineFix.url", "dlllist.txt", "winmm.dll"] {
            #expect(fm.fileExists(atPath: game.appendingPathComponent("\(binPath)/\(name)").path),
                    "\(name) must land beside the game's executable")
        }
        let api = game.appendingPathComponent(apiPath)
        #expect(contents(api) == "fixed api")
        #expect(contents(api.appendingPathExtension("onlinefix-backup")) == "original api")
    }

    /// A readme at the archive root must not disturb the tree: the loader files and
    /// the Steam API DLL still go where the game looks for them.
    @Test
    func aStrayRootFileDoesNotDropTheTree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fix = try rideFix(in: root)
        try write("read me", to: fix.appendingPathComponent("ReadMe.txt"))
        let game = try rideGame(in: root)

        let scan = GameScan.read(folder: game, appID: 1, name: "Ride")
        let plan = FixPlan.build(appID: 1, name: "Ride", scan: scan,
                                 package: FixPackage.read(root: fix))
        _ = try FixApply.apply(plan, appID: 1, folder: game)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: game.appendingPathComponent("\(binPath)/OnlineFix64.dll").path))
        #expect(fm.fileExists(atPath: game.appendingPathComponent("\(binPath)/winmm.dll").path))
        #expect(contents(game.appendingPathComponent(apiPath)) == "fixed api")
    }
}
