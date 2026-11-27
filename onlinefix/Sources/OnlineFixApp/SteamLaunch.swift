// Starting a game through Steam without starting a second Steam.
//
// Steam's patched copy is /Applications/Steam.app: its Info.plist supplies
// DYLD_INSERT_LIBRARIES, and LaunchServices only honours that when the app is
// opened through LaunchServices. Running Steam.AppBundle's steam_osx directly
// starts an unpatched client: no macsteam.dylib, no licence hooks, and if a
// patched Steam is already running the second client takes the login lock.
//
// open(1) with a steam:// URL goes through LaunchServices instead. It also
// hands the launch to the running client rather than starting another one.
import Foundation

enum SteamLaunch {

    static let bundle = Paths.steamApp

    static func url(appID: Int) -> URL {
        URL(string: "steam://run/\(appID)")!
    }

    /// Opens the game through the patched Steam bundle. Returns false only when
    /// open(1) itself could not be started.
    @discardableResult
    static func run(appID: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", bundle.path, url(appID: appID).absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

extension SteamLaunch {
    /// The path that must not be run directly. Kept in one place so the launch
    /// probe and the in-app test cannot drift back to it.
    static var unpatchedClient: URL {
        Paths.steamSupport.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    }
}