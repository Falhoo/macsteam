// The fix, packed in the game folder so it can be repaired and undone offline.
//
// `.macsteam-onlinefix/recipe.json` says what the fix is, which files it wrote, what
// each one hashed to, and what it removed. `.macsteam-onlinefix/payload/` keeps a
// copy of every file the fix put in place, which is what a repair copies from when a
// Steam verify or an update has put the game's own files back. Neither needs the
// download or the network.
import Foundation

struct FixRecipe: Codable, Sendable, Equatable {

    struct Entry: Codable, Sendable, Equatable {
        /// From the game folder, with "/" between folders.
        var path: String
        var size: Int64
        var sha256: String
        /// True when the game had no such file, so undoing means deleting it.
        var created: Bool
    }

    var appID: Int
    var name: String
    var installedAt: Date
    var packageName: String
    var findings: [FixFinding]
    var entries: [Entry]
    /// Files taken out, such as Valve's renderer beside the game.
    var removed: [String]
    var keepRealAppID: Bool
    var photonSwap: Bool
    var picoPark2: Bool
    var wineDLLs: [String]
    var notes: [String] = []

    var summary: String {
        "\(name) (\(appID)): \(entries.count) file(s) from \(packageName.isEmpty ? "a fix package" : packageName)"
    }
}

enum FixPack {

    static let folderName = ".macsteam-onlinefix"
    static let recipeName = "recipe.json"
    static let payloadName = "payload"

    static func folder(in gameFolder: URL) -> URL {
        gameFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    static func recipeURL(in gameFolder: URL) -> URL {
        folder(in: gameFolder).appendingPathComponent(recipeName)
    }

    static func payloadURL(in gameFolder: URL, for relative: String) -> URL {
        folder(in: gameFolder)
            .appendingPathComponent(payloadName, isDirectory: true)
            .appendingPathComponent(relative)
    }

    static func hasPack(in gameFolder: URL) -> Bool {
        Paths.fm.fileExists(atPath: recipeURL(in: gameFolder).path)
    }

    // MARK: - Read and write

    static func read(in gameFolder: URL) -> FixRecipe? {
        guard let data = try? Data(contentsOf: recipeURL(in: gameFolder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let recipe = try? decoder.decode(FixRecipe.self, from: data) { return recipe }
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(FixRecipe.self, from: data)
    }

    /// Writes the recipe and a copy of every file the fix put in place. The copies are
    /// made now, so they hold the edited ini and dlllist as well as the payload.
    static func write(_ recipe: FixRecipe, in gameFolder: URL) throws {
        let pack = folder(in: gameFolder)
        try? Paths.fm.removeItem(at: pack.appendingPathComponent(payloadName))
        try Paths.ensureDir(pack.appendingPathComponent(payloadName, isDirectory: true))

        for entry in recipe.entries {
            let source = gameFolder.appendingPathComponent(entry.path)
            guard Paths.fm.fileExists(atPath: source.path) else { continue }
            let destination = payloadURL(in: gameFolder, for: entry.path)
            try Paths.ensureDir(destination.deletingLastPathComponent())
            try? Paths.fm.removeItem(at: destination)
            try Paths.fm.copyItem(at: source, to: destination)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recipe).write(to: recipeURL(in: gameFolder), options: .atomic)
    }

    // MARK: - Verify

    /// The files the recipe recorded that are no longer there or no longer the same,
    /// which is what a Steam verify or an update leaves behind.
    static func verify(in gameFolder: URL) -> [String] {
        guard let recipe = read(in: gameFolder) else { return [] }
        var changed: [String] = []
        for entry in recipe.entries {
            let file = gameFolder.appendingPathComponent(entry.path)
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, Int64(size) == entry.size,
                  let hash = Hash.sha256(file), hash == entry.sha256 else {
                changed.append(entry.path)
                continue
            }
        }
        return changed
    }

    /// Puts the listed files back from the pack. Returns the ones it restored.
    @discardableResult
    static func restore(_ paths: [String], in gameFolder: URL) -> [String] {
        var restored: [String] = []
        for relative in paths {
            let source = payloadURL(in: gameFolder, for: relative)
            guard Paths.fm.fileExists(atPath: source.path) else { continue }
            let destination = gameFolder.appendingPathComponent(relative)
            do {
                try Paths.ensureDir(destination.deletingLastPathComponent())
                if Paths.fm.fileExists(atPath: destination.path) {
                    try Paths.fm.removeItem(at: destination)
                }
                try Paths.fm.copyItem(at: source, to: destination)
                restored.append(relative)
            } catch {
                continue
            }
        }
        return restored
    }

    // MARK: - Undo

    /// Puts the game back the way the pack found it and removes the pack.
    /// Returns how many files changed.
    @discardableResult
    static func undo(in gameFolder: URL) throws -> Int {
        guard let recipe = read(in: gameFolder) else {
            try? Paths.fm.removeItem(at: folder(in: gameFolder))
            return 0
        }
        var changed = 0
        for entry in recipe.entries.reversed() {
            let file = gameFolder.appendingPathComponent(entry.path)
            let backup = file.appendingPathExtension("onlinefix-backup")
            if Paths.fm.fileExists(atPath: backup.path) {
                try? Paths.fm.removeItem(at: file)
                if (try? Paths.fm.moveItem(at: backup, to: file)) != nil { changed += 1 }
            } else if entry.created, Paths.fm.fileExists(atPath: file.path) {
                try? Paths.fm.removeItem(at: file)
                changed += 1
            }
        }
        try? Paths.fm.removeItem(at: folder(in: gameFolder))
        return changed
    }
}
