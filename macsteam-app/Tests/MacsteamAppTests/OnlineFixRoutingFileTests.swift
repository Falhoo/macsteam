import Foundation
import XCTest

@testable import MacsteamApp

final class OnlineFixRoutingFileTests: XCTestCase {

    private func gamesFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEveryGameIsRoutedByDefault() throws {
        let file = try gamesFile("""
        {"games": [
          {"id": 3949040, "name": "RV There Yet?", "patches": {"startupAppID": true}},
          {"id": 4000, "name": "Garry's Mod"}
        ]}
        """)

        let routed = OnlineFixRoutingFile.routedGames(from: file)

        XCTAssertEqual(routed.compactMap { $0["id"] as? Int }, [3949040, 4000])
    }

    /// "Keep real AppID" is a decision the dylib has to be told about. Leaving the
    /// game out of this file is not "keep the real AppID" to the dylib: absent means
    /// route as Spacewar (480), which is the opposite. The flag travels with the entry.
    func testKeepingRealAppIDStaysInTheRoutingWithItsFlag() throws {
        let file = try gamesFile("""
        {"games": [
          {"id": 3949040, "name": "RV There Yet?", "keepRealAppID": true},
          {"id": 4000, "name": "Garry's Mod", "keepRealAppID": false}
        ]}
        """)

        let routed = OnlineFixRoutingFile.routedGames(from: file)

        XCTAssertEqual(routed.compactMap { $0["id"] as? Int }, [3949040, 4000])
        XCTAssertEqual(routed.first?["keepRealAppID"] as? Bool, true)
    }

    func testEntriesKeepTheirPatchFlags() throws {
        let file = try gamesFile("""
        {"games": [
          {"id": 4000, "name": "Garry's Mod",
           "keepRealAppID": false,
           "patches": {"startupAppID": true, "statsAppID": false}}
        ]}
        """)

        let patches = OnlineFixRoutingFile.routedGames(from: file)
            .first?["patches"] as? [String: Any]

        XCTAssertEqual(patches?["startupAppID"] as? Bool, true)
        XCTAssertEqual(patches?["statsAppID"] as? Bool, false)
    }

    func testMissingOrBrokenFileRoutesNothing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertTrue(OnlineFixRoutingFile.routedGames(from: missing).isEmpty)

        let broken = try gamesFile("not json")
        XCTAssertTrue(OnlineFixRoutingFile.routedGames(from: broken).isEmpty)
    }

    /// A game whose recorded fix files are gone started as Spacewar without the fix
    /// that goes with it, which is how a game stops launching. It stays unrouted
    /// until the fix is installed again; its neighbours are unaffected.
    func testABrokenFixLeavesTheGameUnrouted() throws {
        let dll = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam_api64-\(UUID().uuidString).dll")
        try Data("fixed api".utf8).write(to: dll)
        addTeardownBlock { try? FileManager.default.removeItem(at: dll) }

        let intact = try gamesFile("""
        {"games": [{"id": 3949040, "name": "RV There Yet?"},
                   {"id": 4000, "name": "Garry's Mod"}],
         "fixes": [{"id": 3949040, "files": ["\(dll.path)"],
                    "sizes": {"\(dll.path)": 9}}]}
        """)
        XCTAssertEqual(OnlineFixRoutingFile.routedGames(from: intact)
            .compactMap { $0["id"] as? Int }, [3949040, 4000])

        // Same path, but Steam has put the game's own file back: a different size.
        try Data("the game's own steam_api64.dll".utf8).write(to: dll)

        XCTAssertEqual(OnlineFixRoutingFile.routedGames(from: intact)
            .compactMap { $0["id"] as? Int }, [4000])
    }

    func testSpacewarItselfIsNeverRouted() throws {
        let file = try gamesFile("""
        {"games": [{"id": 480, "name": "Spacewar"}]}
        """)
        XCTAssertTrue(OnlineFixRoutingFile.routedGames(from: file).isEmpty)
    }

    /// The app drops the overlay line from `dlllist.txt` after installing, which
    /// changes the file. That must not take the game out of routing: a game that is
    /// not routed cannot match players as Spacewar.
    func testAnEditedDllListKeepsTheGameRouted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let core = dir.appendingPathComponent("OnlineFix64.dll")
        let list = dir.appendingPathComponent("dlllist.txt")
        try Data("core".utf8).write(to: core)
        let original = "SteamOverlay64.dll\nOnlineFix64.dll\n"
        try Data(original.utf8).write(to: list)

        let file = try gamesFile("""
        {"games": [{"id": 4000, "name": "Garry's Mod"}],
         "fixes": [{"id": 4000, "files": ["\(core.path)", "\(list.path)"],
                    "sizes": {"\(core.path)": 4, "\(list.path)": \(original.utf8.count)}}]}
        """)
        XCTAssertEqual(OnlineFixRoutingFile.routedGames(from: file)
            .compactMap { $0["id"] as? Int }, [4000])

        try Data("OnlineFix64.dll\n".utf8).write(to: list)

        XCTAssertEqual(OnlineFixRoutingFile.routedGames(from: file)
            .compactMap { $0["id"] as? Int }, [4000])
    }
}
