// Telling a game that plays over Steam's relay network (SDR) from one that
// does not: only the first kind has to keep its real AppID.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct SteamNetworkingTests {

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test
    func findsTheRelayEntryPointsInTheGameBinaries() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("....SteamNetworkingSockets....",
                  to: root.appendingPathComponent("Binaries/Win64/Game-Win64-Shipping.exe"))
        #expect(SteamNetworking.scan(folder: root))
    }

    @Test
    func aGameThatOnlyUsesLobbiesIsLeftAlone() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("....SteamUserStats...SteamMatchmaking....",
                  to: root.appendingPathComponent("Binaries/Win64/Game-Win64-Shipping.exe"))
        #expect(!SteamNetworking.scan(folder: root))
    }

    @Test
    func assetsAreNotReadAsBinaries() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SteamNetworkingSockets", to: root.appendingPathComponent("Content/Game.pak"))
        #expect(!SteamNetworking.scan(folder: root))
    }
}
