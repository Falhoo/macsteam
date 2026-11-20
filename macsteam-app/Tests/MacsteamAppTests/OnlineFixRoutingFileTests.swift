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

    func testKeepingRealAppIDLeavesTheGameUnrouted() throws {
        let file = try gamesFile("""
        {"games": [
          {"id": 3949040, "name": "RV There Yet?", "keepRealAppID": true},
          {"id": 4000, "name": "Garry's Mod", "keepRealAppID": false}
        ]}
        """)

        let routed = OnlineFixRoutingFile.routedGames(from: file)

        XCTAssertEqual(routed.compactMap { $0["id"] as? Int }, [4000])
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

    func testSpacewarItselfIsNeverRouted() throws {
        let file = try gamesFile("""
        {"games": [{"id": 480, "name": "Spacewar"}]}
        """)
        XCTAssertTrue(OnlineFixRoutingFile.routedGames(from: file).isEmpty)
    }
}
