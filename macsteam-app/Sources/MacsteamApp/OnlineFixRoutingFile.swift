// The game list the injected OnlineFix dylib routes through AppID 480.
//
// The manager's games.json is the list of My Games; not every game in it should
// be remapped. A game whose multiplayer runs on Steam's own networking (SDR
// relay, as RV There Yet? does) never gets past "connecting to Steam relay
// servers" while the game's Steam pipe carries Spacewar's AppID 480, so it has
// to reach the client as itself — the same thing the LuaTools fixes do by
// keeping the game's real AppID.
//
// The dylib reads its own JSON (ONLINEFIX_CONFIG), so the routed subset is
// written out next to the manager's file rather than editing theirs.
import Foundation

enum OnlineFixRoutingFile {

    /// Rewrites the routed list from the manager's games.json. Returns true when
    /// the file was written. An unreadable list writes an empty one: routing
    /// nothing is the safe state.
    @discardableResult
    static func writeFromManager() -> Bool {
        let routed = routedGames(from: Paths.onlineFixGamesFile)
        do {
            try Paths.ensureDir(Paths.onlineFixSupportDir)
            let data = try JSONSerialization.data(
                withJSONObject: ["games": routed],
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Paths.onlineFixRoutingFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The manager's games minus the ones set to keep their real AppID. The
    /// entries are copied unchanged so every patch flag the dylib reads survives.
    static func routedGames(from file: URL) -> [[String: Any]] {
        guard
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let games = root["games"] as? [[String: Any]]
        else { return [] }

        return games.filter { game in
            guard let id = game["id"] as? Int, id > 0, id != 480 else { return false }
            return !(game["keepRealAppID"] as? Bool ?? false)
        }
    }
}
