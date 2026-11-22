// What a native macOS build can use from OnlineFix, and what it cannot.
//
// An OnlineFix is Windows PE DLLs a game's own process loads in place of its
// Steam API: `steam_api64.dll`, `OnlineFix64.dll`, `winmm.dll`. A native Mac game
// is a Mach-O process, its Steam API is `libsteam_api.dylib`, and macOS will not
// load a PE file into it. So no OnlineFix package can be installed into a Mac
// build, and the app says so instead of copying files that can never run.
//
// What does work, and is the whole fix for such a game, is the identity. macSteam
// hooks the Steam client and starts the game's Steam pipe as Spacewar (480),
// which is what an OnlineFix would otherwise have done from inside the game.
// A Mac build Steam sells needs nothing else: it is not a Windows PE file for a
// fix to patch.
import Foundation

enum MacAppFix {

    struct Status: Sendable {
        /// The game's bundle, e.g. `Game.app`.
        let bundle: URL
        /// True when the bundle carries Steam's Mac API, so the game talks to the
        /// client and the routing applies to it.
        let hasSteamAPI: Bool

        /// One line for the patch sheet: no fix files, routing only.
        var summary: String {
            hasSteamAPI
                ? "This is the Mac build: OnlineFix's Windows files cannot load here, so there "
                    + "is nothing to install. Routing through 480 is the whole fix for it."
                : "This is the Mac build, and it does not use Steam's API, so neither a fix "
                    + "nor routing applies to it."
        }

        /// What this Mac build can be given instead of a fix.
        var message: String {
            "This is the Mac build of the game. OnlineFix's Windows DLLs cannot load "
                + "into a Mac process, so nothing from online-fix.me can be installed here. "
                + (hasSteamAPI
                    ? "macSteam can still start it as Spacewar (480), which is what an "
                        + "OnlineFix does for a Windows build: turn off Keep real AppID for "
                        + "this game and it is routed like a fixed one."
                    : "The game does not use Steam's API, so there is nothing to route either.")
        }
    }

    /// The native bundle at the top of a game folder, with the facts that decide
    /// whether routing is worth anything for it.
    static func status(gameFolder: URL?) -> Status? {
        guard let folder = gameFolder,
              let bundle = FixInstaller.nativeMacBundle(in: folder) else { return nil }
        return Status(bundle: bundle, hasSteamAPI: hasSteamAPI(bundle: bundle))
    }

    /// Whether the bundle links Steam's Mac API, as a Steam game does. A game that
    /// ships its own copy keeps it in `Contents/Frameworks`; one that relies on the
    /// client has no copy, so its executable is read for the API's name instead.
    static func hasSteamAPI(bundle: URL) -> Bool {
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if let names = try? Paths.fm.contentsOfDirectory(atPath: frameworks.path),
           names.contains(where: { $0.lowercased().hasPrefix("libsteam_api") }) {
            return true
        }
        let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard let executables = try? Paths.fm.contentsOfDirectory(atPath: macos.path) else {
            return false
        }
        let needle = Data("SteamAPI".utf8)
        return executables.contains { name in
            let url = macos.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return false
            }
            return data.range(of: needle) != nil
        }
    }
}
