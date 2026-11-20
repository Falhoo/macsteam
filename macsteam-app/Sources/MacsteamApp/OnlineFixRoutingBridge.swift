// The OnlineFix Manager is the source of truth for OnlineFix settings.
//
// Its list and per-game toggles are copied into config.yaml's OnlineFix section,
// which macSteam's dylib reads at each game's launch and turns into the AppID 480
// session with the optional App ID restores. Each game is also added to the Apps
// list, so a game added in the manager can be launched from Steam straight away.
import Foundation
import OnlineFixApp

enum OnlineFixRoutingBridge {

    /// Merges the manager's games into the config. Returns true when anything changed.
    @MainActor
    static func merge(_ entries: [RoutingEntry], into cfg: inout MacsteamConfig) -> Bool {
        var changed = false
        var wanted: [Int: OnlineFixOptions] = [:]

        for entry in entries {
            // Every game in My Games runs as AppID 480: that is how OnlineFix
            // matches other players, and a fix is not required for it (the game
            // may have been unlocked by LuaTools instead). "Keep real AppID" is
            // the per-game opt-out.
            wanted[entry.appID] = OnlineFixOptions(
                keepRealAppID: entry.keepRealAppID,
                startupAppID: entry.startupAppID,
                overlayAppID: entry.overlayAppID,
                inputAppID: entry.inputAppID,
                statsAppID: entry.statsAppID)

            if !cfg.apps.contains(entry.appID) {
                cfg.apps.append(entry.appID)
                changed = true
            }
            if (cfg.appNames[entry.appID] ?? "").isEmpty, !entry.name.isEmpty {
                cfg.appNames[entry.appID] = entry.name
                changed = true
            }
        }

        if cfg.onlineFixGames != wanted {
            cfg.onlineFixGames = wanted
            changed = true
        }
        // The separate dylib routes from its own file; keep the routed subset in
        // step with the toggles so a change applies on the next launch.
        OnlineFixRoutingFile.writeFromManager()
        return changed
    }
}
