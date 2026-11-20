// The achievement list writer lives in the client dylib
// (`src/feats/achiev_cache.c`), which is inert outside Steam. The Store bridge
// can load it in its own process and build a game's library cache entry as soon
// as the game is added, so the entry is already on disk when Steam next starts —
// which is what makes one restart enough to show its achievements instead of
// two.

import Foundation
import Darwin

enum AchievCache {
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        Paths.steamAppInjectedDylib.path, RTLD_LAZY | RTLD_LOCAL)

    private typealias Sync = @convention(c) (Int32) -> Int32

    private static let sync: Sync? = {
        guard let handle, let symbol = dlsym(handle, "sx_achiev_cache_sync_app") else { return nil }
        return unsafeBitCast(symbol, to: Sync.self)
    }()

    /// Writes the app's achievement list into Steam's library cache now.
    /// Returns false when the dylib is not installed or has no schema for the
    /// game yet, which is the caller's cue to wait for one.
    @discardableResult
    static func syncNow(appID: Int) -> Bool {
        guard appID > 0, appID <= Int32.max, let sync else { return false }
        return sync(Int32(appID)) != 0
    }

    /// Whether the library cache entry already carries a non-empty achievement
    /// list for the app, across every account on this Mac.
    static func hasList(appID: Int) -> Bool {
        guard appID > 0 else { return false }
        for directory in libraryCacheDirectories() {
            let file = directory.appendingPathComponent("\(appID).json")
            guard let data = try? Data(contentsOf: file),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                continue
            }
            for case let pair as [Any] in document where pair.count == 2 {
                guard pair[0] as? String == "achievements",
                      let entry = pair[1] as? [String: Any],
                      let data = entry["data"] as? [String: Any] else { continue }
                if let total = data["nTotal"] as? Int, total > 0 { return true }
            }
        }
        return false
    }

    private static func libraryCacheDirectories() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/userdata", isDirectory: true)
        guard let accounts = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return accounts
            .filter { Int($0.lastPathComponent) != nil }
            .map { $0.appendingPathComponent("config/librarycache", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
