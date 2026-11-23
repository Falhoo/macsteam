// Clearing the launch options Steam on macOS cannot run, at a moment Steam cannot
// write its old copy back over the change.
//
// A game that goes back to a native launch keeps the `NAME=value` prefixes
// NotProton wrote for its compatibility tool, and Steam's macOS client has no
// shell to run them: it tries to exec the whole string and the game stops with
// "Failed to start process for this game: OS error 260". The player sees only the
// error, so the prefixes are cleared here, before Steam reads its config.
import Foundation

enum LaunchOptionsRepair {

    /// What one pass did.
    struct Outcome {
        /// The apps whose launch options were cleared.
        let appIDs: [Int]
        /// True when Steam was quit and started again to apply the change.
        let restartedSteam: Bool
        /// True when the pass did nothing because a game was being played.
        let skipped: Bool
    }

    /// Clears the stale options of every game that is now a native Mac build.
    ///
    /// Steam keeps its launch options in memory and writes them back when it
    /// quits, so the file is only safe to change while the client is closed:
    /// here it is quit through its own `steam://exit`, which lets it write its
    /// cache on the way out, and started again afterwards. A game being played
    /// now is left for the next start, since quitting Steam would end it. A game
    /// that is not a Mac build keeps its options: those belong to the
    /// compatibility tool it runs through.
    @MainActor
    @discardableResult
    static func run() async -> Outcome {
        let stale = LaunchOptions.staleApps().filter { NativeMacGames.installedNative(appID: $0) }
        guard !stale.isEmpty else {
            return Outcome(appIDs: [], restartedSteam: false, skipped: false)
        }
        guard !aGameIsRunning() else {
            note("launch options: \(stale) kept for now, a game is running")
            return Outcome(appIDs: [], restartedSteam: false, skipped: true)
        }

        let wasRunning = steamIsRunning()
        if wasRunning {
            _ = Subprocess.run("/usr/bin/open", ["steam://exit"])
            if !(await waitForExit(seconds: 20)) {
                Subprocess.killSteam()
                _ = await waitForExit(seconds: 10)
            }
        }

        let cleared = LaunchOptions.clear(stale)

        if wasRunning {
            _ = Subprocess.run("/usr/bin/open", [Paths.steamApp.path])
            _ = await waitForStart(seconds: 120)
        }
        note("launch options: cleared \(cleared), Steam \(wasRunning ? "restarted" : "was closed")")
        return Outcome(appIDs: cleared, restartedSteam: wasRunning, skipped: false)
    }

    /// A game runs out of `steamapps/common`, so anything started from there means
    /// Steam is in use and must not be quit.
    private static func aGameIsRunning() -> Bool {
        Subprocess.run("/usr/bin/pgrep", ["-f", "steamapps/common/"]).code == 0
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

    /// Appends one line to macSteam's log, so the change can be followed.
    private static func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [launch-options] \(text)\n"
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: Paths.appLog.path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
