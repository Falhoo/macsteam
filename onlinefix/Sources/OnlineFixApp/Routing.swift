import Foundation

/// One game's OnlineFix settings, in the shape macSteam's dylib reads from
/// config.yaml when that game launches.
public struct RoutingEntry: Sendable, Equatable {
    public let appID: Int
    public let name: String
    /// Whether the fix's own files are still in the game folder. A recorded fix
    /// whose files Steam has put back is not passed at all, so the game starts as
    /// itself instead of as Spacewar without a fix.
    public let hasFix: Bool
    public let keepRealAppID: Bool
    public let startupAppID: Bool
    public let overlayAppID: Bool
    public let inputAppID: Bool
    public let statsAppID: Bool

    public init(appID: Int, name: String, hasFix: Bool, keepRealAppID: Bool,
                startupAppID: Bool, overlayAppID: Bool,
                inputAppID: Bool, statsAppID: Bool) {
        self.appID = appID
        self.name = name
        self.hasFix = hasFix
        self.keepRealAppID = keepRealAppID
        self.startupAppID = startupAppID
        self.overlayAppID = overlayAppID
        self.inputAppID = inputAppID
        self.statsAppID = statsAppID
    }
}

/// The manager's list and toggles are the source of truth for routing: the config
/// app installs `didChange` and writes them into config.yaml, where macSteam's
/// dylib reads them at each game's launch.
@MainActor
public enum OnlineFixRouting {
    public static var didChange: (([RoutingEntry]) -> Void)?

    public static func emit(_ entries: [RoutingEntry]) {
        didChange?(entries)
    }
}
