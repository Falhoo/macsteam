// Restarts Steam from the store card.
//
// A game added while Steam runs only gets its achievement list once the client
// has fetched it, and a library page draws only the list its cache held when the
// page was opened. So the card's "Restart" button loads the game's library page
// in the running client first — that is what makes Steam fetch the achievements —
// then quits Steam through its own `steam://exit` (as the menu does, so the client
// writes its cache on the way out), starts it again and comes back to that page.

import Foundation

enum SteamRestarter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _restarting = false

    /// True from the moment a restart is asked for until Steam is back, so the
    /// store bridge keeps waiting for it instead of deciding Steam has gone for
    /// good.
    static var isRestarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _restarting
    }

    /// Claims the restart, or says another one is already running.
    private static func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _restarting { return false }
        _restarting = true
        return true
    }

    private static func end() {
        lock.lock()
        defer { lock.unlock() }
        _restarting = false
    }

    static func restart(appID: Int?) async {
        guard begin() else { return }
        defer { end() }

        // Let the store page's reply reach it before the page goes away.
        try? await Task.sleep(for: .milliseconds(600))

        guard let appID, appID > 0 else {
            _ = await launchAndShow(appID: nil, quitting: false)
            return
        }

        // Load the game's library page in the running client first: opening the
        // page is what makes Steam fetch the achievements, and it is what the
        // player does by hand before quitting. Three seconds is all it needs.
        AchievCache.syncNow(appID: appID)
        _ = Subprocess.run("/usr/bin/open", ["steam://nav/games/details/\(appID)"])
        try? await Task.sleep(for: .seconds(3))
        let hadList = AchievCache.hasList(appID: appID)
        note("app \(appID): page loaded, list in the cache: \(hadList ? "yes" : "no")")

        _ = await launchAndShow(appID: appID, quitting: true)
    }

    /// Quits Steam and starts it again without opening anything: the store card
    /// uses it after a game is removed, so the client drops the title.
    static func restartOnly() async {
        guard begin() else { return }
        defer { end() }

        // Let the store page's reply reach it before the page goes away.
        try? await Task.sleep(for: .milliseconds(600))
        _ = Subprocess.run("/usr/bin/open", ["steam://exit"])
        let exited = await waitForExit(seconds: 20)
        note("plain restart: Steam quit \(exited ? "by itself" : "by force")")
        if !exited {
            Subprocess.killSteam()
            _ = await waitForExit(seconds: 10)
        }
        _ = Subprocess.run("/usr/bin/open", [Paths.steamApp.path])
        _ = await waitForStart(seconds: 120)
    }

    /// Appends one line to macSteam's log, so a restart can be followed.
    private static func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [restart] \(text)\n"
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: Paths.appLog.path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    /// Quits Steam (when asked), starts it again and opens the game's page.
    private static func launchAndShow(appID: Int?, quitting: Bool) async -> Bool {
        if quitting {
            // Quit the way the menu does: Steam://exit closes the client itself,
            // so it writes its own library cache on the way out. A killed client
            // skips that write, and the achievements then only show one start
            // later. A TERM alone is ignored, so this is the graceful route.
            _ = Subprocess.run("/usr/bin/open", ["steam://exit"])
            let exited = await waitForExit(seconds: 20)
            note("Steam quit \(exited ? "by itself" : "by force")")
            if !exited {
                Subprocess.killSteam()
                _ = await waitForExit(seconds: 10)
            }
        }

        // Launch it the way its icon does.
        _ = Subprocess.run("/usr/bin/open", [Paths.steamApp.path])
        var started = await waitForStart(seconds: 120)
        if !started {
            // One retry: launching while the old client was still finishing its
            // own shutdown is the one way this is known to be ignored.
            _ = Subprocess.run("/usr/bin/open", [Paths.steamApp.path])
            started = await waitForStart(seconds: 60)
        }
        guard started else { return false }

        // The library is only there a moment after the process appears.
        try? await Task.sleep(for: .seconds(10))
        if let appID, appID > 0 {
            _ = Subprocess.run("/usr/bin/open", ["steam://nav/games/details/\(appID)"])
        }
        return true
    }

    private static func steamIsRunning() -> Bool {
        Subprocess.run("/usr/bin/pgrep", ["-x", "steam_osx"]).code == 0
    }

    private static func waitForExit(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !steamIsRunning() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !steamIsRunning()
    }

    private static func waitForStart(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if steamIsRunning() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return steamIsRunning()
    }
}
