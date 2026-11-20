// Games Steam also ships as a native macOS build.
//
// A LuaTools fix is a Windows DLL patch: it patches the game's steam_api64.dll and
// drop-in DLLs. When Steam installs the Mac build there is nothing to patch, so the
// fix cannot work — the store page and macSteam hide those fixes instead of
// offering something that will fail.
import Foundation

@MainActor
enum NativeMacGames {

    /// Answers already looked up, one line per app, under macSteam's config folder.
    private static let cacheFile = Paths.configDir.appendingPathComponent("native-mac.json")

    private static var cache: [Int: Bool]?

    /// A `.app` bundle in the game's folder is proof: that is what Steam runs.
    static func installedNative(appID: Int) -> Bool {
        guard let folder = SteamLibrary.installDir(appID: appID) else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries.contains { $0.lowercased().hasSuffix(".app") }
    }

    /// The cached answer, if this game has been looked up before.
    static func isNative(appID: Int) -> Bool? {
        if installedNative(appID: appID) { return true }
        return cached()[appID]
    }

    /// True when the game has a native macOS build, asking the store once if the
    /// answer is not known yet. Errors are treated as "unknown" (false).
    static func resolve(appID: Int) async -> Bool {
        if installedNative(appID: appID) { return true }
        if let known = cached()[appID] { return known }
        _ = await refresh(appIDs: [appID])
        return cached()[appID] ?? false
    }

    /// Looks up the platforms of these games and caches the answers. Returns the
    /// ones with a native macOS build.
    @discardableResult
    static func refresh(appIDs: [Int]) async -> Set<Int> {
        var known = cached()
        let missing = Array(Set(appIDs))
            .filter { $0 > 0 && known[$0] == nil }
            .sorted()

        for start in stride(from: 0, to: missing.count, by: 50) {
            let chunk = Array(missing[start..<min(start + 50, missing.count)])
            let ids = chunk.map(String.init).joined(separator: ",")
            guard let url = URL(string:
                "https://store.steampowered.com/api/appdetails/?appids=\(ids)&filters=platforms&l=english")
            else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for id in chunk {
                let node = root[String(id)] as? [String: Any]
                let platforms = node?["platforms"] as? [String: Any]
                if let mac = platforms?["mac"] as? Bool {
                    known[id] = mac
                }
            }
        }

        if known != cached() { save(known) }
        return Set(appIDs.filter { installedNative(appID: $0) || known[$0] == true })
    }

    // MARK: - Cache

    private static func cached() -> [Int: Bool] {
        if let cache { return cache }
        var loaded: [Int: Bool] = [:]
        if let data = try? Data(contentsOf: cacheFile),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            for (key, value) in raw {
                if let id = Int(key) { loaded[id] = value }
            }
        }
        cache = loaded
        return loaded
    }

    private static func save(_ known: [Int: Bool]) {
        cache = known
        try? Paths.ensureDir(Paths.configDir)
        let raw = Dictionary(uniqueKeysWithValues: known.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
