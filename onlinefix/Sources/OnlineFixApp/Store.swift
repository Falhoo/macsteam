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

    /// True when Steam has put the game's files there, not just a folder with its name.
    ///
    /// A fix is built from what the game's own files say: its bitness, the folder it
    /// loads Steam's API DLL from, whether it is a .NET build, which engine it is. A
    /// folder Steam made and never filled, or one a cancelled download left behind,
    /// gives the scan nothing to read, and the build would then guess at the rest.
    /// Steam writes `StateFlags 4` once every file of an app is on disk.
    static func isInstalled(appID: Int, folder: URL?, manifest: URL? = nil) -> Bool {
        guard let folder else { return false }
        let file = manifest ?? appManifest(for: appID)
        if let flags = stateFlags(manifest: file), flags != 0 {
            if flags & uninstalled != 0 { return false }
            // Steam writes "Update Required" while the game is still on disk.
            // Rejecting that sent players to a fresh download of a game they
            // already had (common with a family-shared copy). Only an active
            // update / download / validation is not usable.
            if flags & fullyInstalled == 0, flags & busyStates != 0 { return false }
        }
        return hasGameFiles(in: folder)
    }

    /// What a player is told when the folder exists but the game is not downloaded:
    /// the fix is built from the game's own files, so there has to be something to read.
    static let notInstalledMessage =
        "Install the game in Steam first: OnlineFix builds the fix from what the game's "
        + "own files say (its bitness, its engine, where it loads Steam from), and its "
        + "folder has none of them yet. Start the download in Steam, and install the fix "
        + "once it finishes."

    /// Steam's flag for an app whose files are all on disk.
    static let fullyInstalled = 4
    private static let uninstalled = 1
    /// Update running, validating, downloading, staging, committing and the like.
    /// "Update Required" and "Update Queued" are not here: those still have the
    /// game's files on disk.
    private static let busyStates = 16 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 8192 | 16384 | 32768 | 65536

    static func appManifest(for appID: Int) -> URL {
        Paths.steamApps.appendingPathComponent("appmanifest_\(appID).acf")
    }

    static func stateFlags(manifest: URL) -> Int? {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        return firstMatch(in: text, pattern: "\"StateFlags\"\\s+\"?(\\d+)").flatMap { Int($0) }
    }

    /// An executable, or a Mac app bundle: the two things the scan reads a game from.
    static func hasGameFiles(in folder: URL) -> Bool {
        if FixInstaller.nativeMacBundle(in: folder) != nil { return true }
        return FixInstaller.launchFolder(in: folder) != nil
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
