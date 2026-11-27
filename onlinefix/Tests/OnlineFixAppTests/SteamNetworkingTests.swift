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

    /// The OnlineFix's own Steam API DLL contains the entry point names because it
    /// emulates Steam networking. Reading it says nothing about the game.
    @Test
    func theFixesOwnDllIsNotTheGamesCode() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SteamNetworkingSockets",
                  to: root.appendingPathComponent("Plugins/x86_64/steam_api64.dll"))
        try write("SteamUserStats", to: root.appendingPathComponent("Game.exe"))
        #expect(!SteamNetworking.scan(folder: root))
    }

    /// Steam updates a game in place. A cached "no" must not survive the executable
    /// growing the relay entry points.
    @Test
    func aChangedExecutableIsScannedAgain() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("Game.exe")
        try write("SteamUserStats", to: exe)
        #expect(!SteamNetworking.uses(appID: 9_900_001, gameFolder: root))
        try write("SteamUserStats....SteamNetworkingSockets....", to: exe)
        #expect(SteamNetworking.uses(appID: 9_900_001, gameFolder: root))
    }

    /// RV There Yet? imports SteamNetworkingSockets and has an OnlineFix. The answer
    /// comes from the game's own code, not from the fix's files, which sit deep in
    /// the game's tree: that is where the walk has to look.
    @Test
    func aFixedGameStillCountsAsARelayGame() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SteamNetworkingSockets",
                  to: root.appendingPathComponent("Ride/Binaries/Win64/Ride-Win64-Shipping.exe"))
        try write("SteamNetworkingSockets",
                  to: root.appendingPathComponent("Ride/Ride/Binaries/Win64/OnlineFix64.dll"))

        #expect(SteamNetworking.hasFix(in: root))
        #expect(SteamNetworking.uses(appID: 3949040, gameFolder: root))
    }

    /// The game's executables are read at the same depth as the fix, or a game
    /// inside an engine tree would look like it never uses Steam networking.
    @Test
    func aDeepExecutableIsStillRead() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SteamNetworkingSockets",
                  to: root.appendingPathComponent("Ride/Ride/Binaries/Win64/Game-Win64-Shipping.exe"))

        #expect(SteamNetworking.scan(folder: root))
    }

    /// With no fix in the folder, the game's own code is all that is left to ask.
    @Test
    func anUnfixedGameWithItsOwnRelayCodeNeedsItsAppID() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SteamNetworkingSockets",
                  to: root.appendingPathComponent("Game.exe"))

        #expect(SteamNetworking.uses(appID: 1, gameFolder: root))
    }

    /// A game on Steam's relay needs its own AppID at the client, which is what
    /// "Keep real AppID" sets. Its matchmaking identity is Spacewar either way.
    @Test
    func aFixedRelayGameNeedsItsOwnAppID() {
        #expect(SteamNetworking.needsRealAppID(usesSteamNetworking: true, fixInstalled: true))
        // Without a fix there is nothing matching players as Spacewar, so the real
        // AppID is the only identity left.
        #expect(!SteamNetworking.needsRealAppID(usesSteamNetworking: true, fixInstalled: false))
        // A game that does not use the relay never has to be itself.
        #expect(!SteamNetworking.needsRealAppID(usesSteamNetworking: false, fixInstalled: true))
    }
}
