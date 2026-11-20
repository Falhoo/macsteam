import Foundation

/// What the Steam store card knows about a game's OnlineFix state.
public struct OnlineFixStoreStatus: Codable, Sendable {
    public let inList: Bool
    public let fixInstalled: Bool
    public let gameInstalled: Bool
    /// The game's online play runs on Steam's relay network (SDR), which only
    /// exists for the game's own AppID: as Spacewar it never connects.
    public let usesSteamNetworking: Bool
    /// The game is set to start as itself instead of Spacewar.
    public let keepRealAppID: Bool
}

/// How an OnlineFix install started from the Steam store page ended.
public struct OnlineFixStoreOutcome: Codable, Sendable {
    public let message: String?
    public let error: String?
    public let needsGame: Bool
    public let installed: Bool
    /// Similar uploads folders the store page should offer when the game's own
    /// name had no folder. Picking one re-runs the install with `folder`.
    public var choices: [OnlineFixStoreChoice]? = nil
}

/// One folder that could be the game's fix, as offered on the store page.
public struct OnlineFixStoreChoice: Codable, Sendable {
    public let name: String
    public let percent: Int
}
