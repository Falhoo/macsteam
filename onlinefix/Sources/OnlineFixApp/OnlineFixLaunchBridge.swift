// The host app's way of writing a game's launch options. It lives apart from
// OnlineFixEmbed because touching that type can initialize its AppModel, which
// reads the installed fixes; the writer has to be in place before that happens.
import Foundation

public enum OnlineFixLaunchBridge {
    /// Merges the fix's DLL names into an app's launch options.
    nonisolated(unsafe) public static var writer:
        (@Sendable (Int, [String]) async -> Bool)?
    /// Takes the same names back out when the fix is removed.
    nonisolated(unsafe) public static var clearer:
        (@Sendable (Int, [String]) async -> Bool)?
}
