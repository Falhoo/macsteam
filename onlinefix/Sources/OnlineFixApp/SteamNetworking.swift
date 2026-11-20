// Whether a game's online play runs on Steam's own networking (SDR relay).
//
// Steam's relay is per AppID: the client asks Valve for that AppID's relay
// config and tickets. A game started as Spacewar (480) has none of that, so it
// sits at "waiting for other resources before starting the steam network relay"
// and never joins. Those games need "Keep real AppID" — their own identity is the
// only one Steam can issue a relay for.
import Foundation

enum SteamNetworking {

    /// What a Steam-networking game imports from the Steam API DLL. Both are
    /// string names in the import table, so they survive into the binary.
    static let markers = ["SteamNetworkingSockets", "SteamNetworkingUtils"]

    /// The game's own code, not its assets: a Windows build keeps these in
    /// Binaries/Win64, a native one in its .app.
    static let extensions: Set<String> = ["exe", "dll", "so", "dylib"]

    /// Reading a multi-gigabyte folder once per game is enough; the answer is
    /// remembered per game folder.
    static let maxFileSize = 512 * 1024 * 1024
    static let maxTotalSize = 1536 * 1024 * 1024
    static let maxDepth = 4

    private static var cacheFile: URL {
        Paths.appSupport.appendingPathComponent("steam-networking.json")
    }

    /// The remembered answer for this game folder, scanning it the first time.
    static func uses(appID: Int, gameFolder: URL?) -> Bool {
        guard let folder = gameFolder else { return false }
        let key = "\(appID):\(folder.path)"
        var cache = loadCache()
        if let known = cache[key] { return known }
        let answer = scan(folder: folder)
        cache[key] = answer
        saveCache(cache)
        return answer
    }

    /// Reads the game's binaries looking for the Steam networking entry points.
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
