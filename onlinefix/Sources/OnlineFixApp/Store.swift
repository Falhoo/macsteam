import Foundation

enum Store {

    // MARK: - games.json

    static func load() -> GamesFile {
        guard let data = try? Data(contentsOf: Paths.gamesFile) else { return GamesFile() }
        return (try? JSONDecoder().decode(GamesFile.self, from: data)) ?? GamesFile()
    }

    static func save(_ file: GamesFile) throws {
        try Paths.ensureDir(Paths.appSupport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: Paths.gamesFile, options: .atomic)
    }

    // MARK: - Steam library

    static func scanLibrary() -> [LibraryApp] {
        var result: [LibraryApp] = []
        guard let entries = try? Paths.fm.contentsOfDirectory(atPath: Paths.steamApps.path) else { return [] }
        for entry in entries where entry.hasPrefix("appmanifest_") && entry.hasSuffix(".acf") {
            let url = Paths.steamApps.appendingPathComponent(entry)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard
                let appIDString = firstMatch(in: text, pattern: "\"appid\"\\s+\"(\\d+)\""),
                let appID = Int(appIDString)
            else { continue }
            let name = firstMatch(in: text, pattern: "\"name\"\\s+\"([^\"]*)\"") ?? "App \(appID)"
            let installDir = firstMatch(in: text, pattern: "\"installdir\"\\s+\"([^\"]*)\"") ?? name
            let folder = Paths.steamApps
                .appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(installDir, isDirectory: true)
            result.append(LibraryApp(
                id: appID,
                name: name,
                installDir: installDir,
                folder: Paths.fm.fileExists(atPath: folder.path) ? folder : nil
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func installDirectory(for appID: Int) -> String? {
        let manifest = Paths.steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        return firstMatch(in: text, pattern: "\"installdir\"\\s+\"([^\"]*)\"")
    }

    static func gameFolder(for appID: Int) -> URL? {
        guard let dir = installDirectory(for: appID) else { return nil }
        let url = Paths.steamApps.appendingPathComponent("common", isDirectory: true).appendingPathComponent(dir, isDirectory: true)
        return Paths.fm.fileExists(atPath: url.path) ? url : nil
    }

    /// A game folder in steamapps/common whose name matches the game's name.
    /// Used when there is no appmanifest (a game macSteam unlocked, or one
    /// Steam has not written a manifest for yet).
    static func folder(named name: String) -> URL? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        let common = Paths.steamApps.appendingPathComponent("common", isDirectory: true)
        guard let entries = try? Paths.fm.contentsOfDirectory(atPath: common.path) else { return nil }
        for entry in entries where normalized(entry) == wanted {
            let url = common.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            if Paths.fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    /// The folder for an app: its manifest first, then a folder named like the game.
    static func gameFolder(for appID: Int, name: String) -> URL? {
        gameFolder(for: appID) ?? folder(named: name)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Helpers

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
