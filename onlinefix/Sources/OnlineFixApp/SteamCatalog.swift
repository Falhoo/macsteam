import Foundation

/// A game as Steam's store knows it.
struct StoreGame: Identifiable, Hashable {
    let id: Int
    let name: String
    let imageURL: URL?
}

/// Name → AppID lookups against Steam's public store endpoints.
enum SteamCatalog {

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ManagerError("Steam returned HTTP \(http.statusCode).")
        }
        return data
    }

    /// Full-text search over the store catalogue.
    static func search(_ term: String) async throws -> [StoreGame] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }

        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US"),
        ]
        guard let url = components?.url else { return [] }

        let data = try await get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
            let name = (item["name"] as? String) ?? "App \(id)"
            var image: URL?
            if let tiny = item["tiny_image"] as? String {
                image = URL(string: tiny)
            }
            return StoreGame(id: id, name: name, imageURL: image)
        }
    }

    /// Cover art for an AppID, for games added before artwork was stored.
    static func headerImageURL(for appID: Int) -> URL? {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    /// Name and artwork for one app id.
    static func details(for appID: Int) async throws -> StoreGame? {
        var components = URLComponents(string: "https://store.steampowered.com/api/appdetails/")
        components?.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "l", value: "english"),
        ]
        guard let url = components?.url else { return nil }

        let data = try await get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any],
              (entry["success"] as? Bool) == true,
              let payload = entry["data"] as? [String: Any]
        else { return nil }

        let name = (payload["name"] as? String) ?? "App \(appID)"
        var image: URL?
        if let header = payload["header_image"] as? String {
            image = URL(string: header)
        }
        return StoreGame(id: appID, name: name, imageURL: image)
    }
}
