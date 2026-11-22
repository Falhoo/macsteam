// Whether a game's online play runs on Steam's own networking (SDR relay).
//
// Steam's relay is per AppID: the client asks Valve for that AppID's relay
// config and tickets. A game started as Spacewar (480) has none of that, so it
// sits at "waiting for other resources before starting the steam network relay"
// and never joins. Those games need "Keep real AppID": their own identity is the
// only one Steam can issue a relay for.
//
// This reads the game's own code only, never the files an OnlineFix installs:
// those contain the same entry point names because the fix emulates Steam
// networking, so counting them would mark every fixed game as a relay game.
import Foundation

enum SteamNetworking {

    /// What a Steam API user asks SteamNetworkingSockets for. Both are string names
    /// in the import table, so they survive into the binary.
    static let markers = ["SteamNetworkingSockets", "SteamNetworkingUtils"]

    /// The game's own code, not its assets: a Windows build keeps these in
    /// Binaries/Win64, a native one in its .app.
    static let extensions: Set<String> = ["exe", "dll", "so", "dylib"]

    /// Files an OnlineFix installs. They contain Steam's networking entry point
    /// names because the fix emulates Steam networking, so reading them says
    /// nothing about the game.
    static let fixFiles: Set<String> = [
        "steam_api64.dll", "steam_api.dll", "steam_api64.of", "steam_api.of",
        "onlinefix64.dll", "onlinefix.dll", "winmm.dll", "steamoverlay64.dll",
    ]

    /// Reading a multi-gigabyte folder once per game is enough; the answer is
    /// remembered per game folder.
    static let maxFileSize = 512 * 1024 * 1024
    static let maxTotalSize = 1536 * 1024 * 1024
    /// Deep enough for a game's executable inside an engine tree: with the game
    /// folder as the root, `Ride/Binaries/Win64/Ride-Win64-Shipping.exe` sits at
    /// level 4 and the fix's `OnlineFix64.dll` beside it at the same level. One
    /// more level is allowed for a tree that wraps everything in the game's name.
    static let maxDepth = 6

    /// Part of the cache key. A change to what the scan looks at must not keep
    /// answering from what an older build worked out.
    private static let cacheVersion = "3"

    private static var cacheFile: URL {
        Paths.appSupport.appendingPathComponent("steam-networking.json")
    }

    /// A game with an OnlineFix installed matches other players as Spacewar (480).
    /// That holds even when the game's own code uses Steam's relay: the fix is the
    /// Steam API those calls go through, and its matching is what puts players in
    /// the same lobby. Started as its own AppID, a fixed relay game cannot create a
    /// lobby at all (RV There Yet?, both roles), while Spacewar works for host and
    /// joiner. So a fixed game is kept on Spacewar, relay code or not.
    static func spacewarRequired(usesSteamNetworking: Bool, fixInstalled: Bool) -> Bool {
        fixInstalled && usesSteamNetworking
    }

    /// True when an OnlineFix's files are somewhere in the game folder.
    static func hasFix(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name == "onlinefix64.dll" || name == "onlinefix.dll" || name == "onlinefix.ini" {
                return true
            }
        }
        return false
    }

    /// The remembered answer for this game folder, scanning it the first time.
    static func uses(appID: Int, gameFolder: URL?) -> Bool {
        guard let folder = gameFolder else { return false }
        let key = "\(cacheVersion):\(appID):\(folder.path)"
        var cache = loadCache()
        if let known = cache[key] { return known }
        let answer = scan(folder: folder)
        cache[key] = answer
        saveCache(cache)
        return answer
    }

    /// Reads the game's binaries looking for the Steam networking entry points,
    /// leaving out the files an OnlineFix installs.
    static func scan(folder: URL) -> Bool {
        let wanted = markers.map { Data($0.utf8) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var total = 0
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard !fixFiles.contains(name), !name.hasSuffix(".onlinefix-backup") else { continue }
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= maxFileSize else { continue }
            guard total + size <= maxTotalSize else { return false }
            total += size
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            if wanted.contains(where: { data.range(of: $0) != nil }) { return true }
        }
        return false
    }

    private static func loadCache() -> [String: Bool] {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return cache
    }

    private static func saveCache(_ cache: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? Paths.ensureDir(Paths.appSupport)
        try? data.write(to: cacheFile, options: .atomic)
    }
}
