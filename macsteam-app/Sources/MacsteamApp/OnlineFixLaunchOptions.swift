// OnlineFix's proxy DLLs only load when Wine is told to prefer the copies
// beside the game. The prefix registry has that answer, but NotProton passes
// its own WINEDLLOVERRIDES in the child's environment, and Wine then ignores
// the registry. So the same names go on the game's launch options, where
// NotProton turns NAME=value before %command% into the environment of the
// process that starts Wine.
import AppKit
import Foundation

enum OnlineFixLaunchOptions {

    /// Merges the fix's DLL names into the app's launch options, through Steam
    /// itself so the change survives the client's own config write. Returns true
    /// when Steam accepted it, or when there was nothing new to set.
    static func apply(appID: Int, assignments: [String]) async -> Bool {
        NSLog("OnlineFixLaunch enter app=%d steam=%d", appID, steamIsRunning ? 1 : 0)
        guard !assignments.isEmpty else { return true }
        let current = LaunchOptions.current(appID: appID) ?? "%command%"
        let updated = LaunchOptions.mergingEnvironment(
            "WINEDLLOVERRIDES", entries: assignments, into: current)
        guard updated != current else { return true }
        // Steam closed is the easy case: its own file is the right copy, and it
        // reads that file when it next starts. Do this before asking its UI.
        if !steamIsRunning {
            let ok = LaunchOptions.set(updated, appID: appID)
            NSLog("OnlineFixLaunch apply app=%d via file ok=%d current=%@ updated=%@",
                  appID, ok ? 1 : 0, current, updated)
            return ok
        }
        let ok = await SteamUICompat.setLaunchOptions(appID: appID, options: updated)
        NSLog("OnlineFixLaunch apply app=%d via Steam ok=%d current=%@ updated=%@",
              appID, ok ? 1 : 0, current, updated)
        return ok
    }

    /// Takes these names back out when the fix is removed, leaving any other
    /// overrides the player had on the same line.
    static func clear(appID: Int, assignments: [String]) async -> Bool {
        guard !assignments.isEmpty else { return true }
        let current = LaunchOptions.current(appID: appID) ?? "%command%"
        let updated = LaunchOptions.clearingEnvironment(
            "WINEDLLOVERRIDES", entries: assignments, from: current)
        guard updated != current else { return true }
        if !steamIsRunning { return LaunchOptions.set(updated, appID: appID) }
        return await SteamUICompat.setLaunchOptions(appID: appID, options: updated)
    }

    private static var steamIsRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.valvesoftware.steam").isEmpty
    }
}
