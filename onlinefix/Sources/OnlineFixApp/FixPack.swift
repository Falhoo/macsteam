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
    /// Files taken out, as paths from the game folder, such as Valve's renderer
    /// beside the game. Each is kept as `<path>.onlinefix-removed` for undo.
    var removed: [String]
    var keepRealAppID: Bool
    var photonSwap: Bool
    /// The route the install used, so a repair does not re-apply a Photon swap to a
    /// Steam-auth game. Optional so packs written by older builds still decode.
    var photonRoute: String? = nil
    /// The auth type the install wrote into the game's Photon assembly (custom or
    /// none), so a repair re-applies it and an undo restores the assembly.
    var photonAuth: String? = nil
    var picoPark2: Bool
    /// Files the Photon swap changed in place, as paths from the game folder. Their
    /// untouched copies are beside them with `.onlinefix-photon-backup`.
    var photonPatched: [String]? = nil
    /// The ids the Photon swap left in those files, so a Steam restore that puts the
    /// game's own ids back is noticed without keeping a copy of a multi-gigabyte asset.
    var photonIDs: [String]? = nil
    /// Which of those ids each patched file carries. A game can keep a realtime id in
    /// one file and a realtime/voice pair in another, so one global list cannot say
    /// what a single file is supposed to hold.
    var photonFileIDs: [String: [String]]? = nil
    var wineDLLs: [String]
    /// The last install test and the evidence it read. Optional so packs written by
    /// older builds still decode.
    var launchTest: LaunchTest.Result? = nil
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

    /// A recipe path resolved under the game folder, or nil when it would leave it.
    /// A recipe is written by this app, but it is a file in the game folder and can
    /// be edited; no relative path in it may point outside the game.
    static func file(_ relative: String, in gameFolder: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        let base = GameScan.canonical(gameFolder)
        let url = GameScan.canonical(base.appendingPathComponent(relative))
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        return url
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
            guard let source = file(entry.path, in: gameFolder),
                  Paths.fm.fileExists(atPath: source.path),
                  let destination = file(entry.path, in: payloadURL(in: gameFolder, for: ""))
            else { continue }
            try Paths.ensureDir(destination.deletingLastPathComponent())
            try? Paths.fm.removeItem(at: destination)
            try Paths.fm.copyItem(at: source, to: destination)
        }

        try writeRecipe(recipe, in: gameFolder)
    }

    /// Rewrites only the recipe, leaving the payload alone. Used when a patch in the
    /// game's own files changes and the pack has to remember the ids it now carries.
    static func writeRecipe(_ recipe: FixRecipe, in gameFolder: URL) throws {
        try Paths.ensureDir(folder(in: gameFolder))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recipe).write(to: recipeURL(in: gameFolder), options: .atomic)
    }

    /// Records the ids the game's Photon fields carry now, after a manual patch or a
    /// restore, so a later verify or repair compares against what is really there.
    ///
    /// Pass `targets` when the patch wrote ids the scanner cannot know (a custom pair
    /// from the patch sheet): the recipe has to point at those bytes, not at whatever
    /// OnlineFix's defaults were. Pass an empty list after a restore to clear the
    /// record; no argument rescans for the ids the scanner does know.
    static func syncPhotonTargets(in gameFolder: URL, targets: [String]? = nil) {
        guard var recipe = read(in: gameFolder), recipe.photonSwap else { return }

        if let targets {
            guard !targets.isEmpty else {
                clearPhotonTargets(&recipe, in: gameFolder)
                return
            }
            let ids = targets.filter { !$0.isEmpty }
            guard !ids.isEmpty else {
                clearPhotonTargets(&recipe, in: gameFolder)
                return
            }
            let backups = photonBackupFiles(in: gameFolder)
            var files = Set(recipe.photonPatched ?? [])
            var fileIDs = recipe.photonFileIDs ?? [:]
            for relative in backups {
                guard let file = file(relative, in: gameFolder),
                      let data = try? Data(contentsOf: file, options: [.mappedIfSafe])
                else { continue }
                let carrying = ids.filter { PhotonPatch.carries(data, id: $0) }
                if !carrying.isEmpty { files.insert(relative) }
                let kept = (fileIDs[relative] ?? []).filter {
                    PhotonPatch.carries(data, id: $0)
                }
                if !carrying.isEmpty || !kept.isEmpty {
                    fileIDs[relative] = Array(Set(carrying + kept)).sorted()
                }
            }
            guard files.sorted() != recipe.photonPatched || ids != recipe.photonIDs
                    || fileIDs != (recipe.photonFileIDs ?? [:]) else { return }
            recipe.photonPatched = files.sorted()
            recipe.photonIDs = ids
            recipe.photonFileIDs = fileIDs
            try? writeRecipe(recipe, in: gameFolder)
            return
        }

        let candidates = PhotonPatch.scan(in: gameFolder)
        let patched = Set(candidates.map(\.file.path)).filter {
            Paths.fm.fileExists(atPath: $0 + ".onlinefix-photon-backup")
        }
        let plan = PhotonPatch.plan(for: candidates)
        let ids = [plan.id, plan.voiceID].compactMap { $0 }
        let files = patched.map { FixPlan.relative(URL(fileURLWithPath: $0), in: gameFolder) }
            .sorted()
        var fileIDs: [String: [String]] = [:]
        for relative in files {
            guard let file = file(relative, in: gameFolder),
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
                continue
            }
            let carrying = ids.filter { PhotonPatch.carries(data, id: $0) }
            if !carrying.isEmpty { fileIDs[relative] = carrying }
        }
        if files.isEmpty || ids.isEmpty {
            clearPhotonTargets(&recipe, in: gameFolder)
            return
        }
        guard files != recipe.photonPatched || ids != recipe.photonIDs
                || fileIDs != (recipe.photonFileIDs ?? [:]) else { return }
        recipe.photonPatched = files
        recipe.photonIDs = ids
        recipe.photonFileIDs = fileIDs
        try? writeRecipe(recipe, in: gameFolder)
    }

    private static func clearPhotonTargets(_ recipe: inout FixRecipe, in gameFolder: URL) {
        guard recipe.photonPatched?.isEmpty == false || recipe.photonIDs?.isEmpty == false
                || recipe.photonFileIDs?.isEmpty == false else { return }
        recipe.photonPatched = []
        recipe.photonIDs = []
        recipe.photonFileIDs = [:]
        try? writeRecipe(recipe, in: gameFolder)
    }

    /// Every untouched Photon copy in the game folder, as paths from its root.
    private static func photonBackupFiles(in gameFolder: URL) -> [String] {
        guard let enumerator = Paths.fm.enumerator(
            at: gameFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".onlinefix-photon-backup") else { continue }
            let relative = FixPlan.relative(
                URL(fileURLWithPath: String(url.path.dropLast(".onlinefix-photon-backup".count))),
                in: gameFolder)
            if !relative.isEmpty, !relative.hasPrefix(".macsteam-onlinefix/") {
                out.append(relative)
            }
        }
        return out.sorted()
    }

    // MARK: - Verify

    /// The files the recipe recorded that are no longer there or no longer the same,
    /// which is what a Steam verify or an update leaves behind.
    static func verify(in gameFolder: URL) -> [String] {
        guard let recipe = read(in: gameFolder) else { return [] }
        var changed: [String] = []
        for entry in recipe.entries {
            guard let file = file(entry.path, in: gameFolder) else { continue }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, Int64(size) == entry.size,
                  let hash = Hash.sha256(file), hash == entry.sha256 else {
                changed.append(entry.path)
                continue
            }
        }
        // A Steam verify puts the game's own assets back. The patch wrote ids, not a
        // file, so look for the ids it left rather than hashing the whole asset.
        if let ids = recipe.photonIDs, !ids.isEmpty {
            for relative in recipe.photonPatched ?? [] {
                guard let file = file(relative, in: gameFolder) else { continue }
                // A file the auth patch also edits keeps its own untouched copy, and
                // that copy is what says whether it is intact.
                if Paths.fm.fileExists(atPath: file.path + PhotonAuth.backupSuffix) {
                    continue
                }
                let backup = file.appendingPathExtension("onlinefix-photon-backup")
                // A game can keep its ids in more than one file (settings in
                // resources.assets, a copy in an assembly), and each file carries
                // only the fields it had. Require one recorded id, and require the
                // file to differ from its untouched copy.
                let wanted = recipe.photonFileIDs?[relative] ?? ids
                guard Paths.fm.fileExists(atPath: backup.path),
                      let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                      wanted.allSatisfy({ PhotonPatch.carries(data, id: $0) }) else {
                    changed.append(relative)
                    continue
                }
            }
        }
        return changed
    }

    /// Puts the listed files back from the pack. Returns the ones it restored.
    @discardableResult
    static func restore(_ paths: [String], in gameFolder: URL) -> [String] {
        var restored: [String] = []
        for relative in paths {
            guard let destination = file(relative, in: gameFolder),
                  let source = file(relative, in: payloadURL(in: gameFolder, for: "")),
                  Paths.fm.fileExists(atPath: source.path) else { continue }
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
        var failed: [String] = []
        for entry in recipe.entries.reversed() {
            guard let file = file(entry.path, in: gameFolder) else {
                failed.append(entry.path)
                continue
            }
            let backup = file.appendingPathExtension("onlinefix-backup")
            if Paths.fm.fileExists(atPath: backup.path) {
                if putBack(backup, at: file) { changed += 1 } else { failed.append(entry.path) }
            } else if entry.created {
                if !Paths.fm.fileExists(atPath: file.path) { continue }
                do {
                    try Paths.fm.removeItem(at: file)
                    changed += 1
                } catch {
                    failed.append(entry.path)
                }
            } else if Paths.fm.fileExists(atPath: file.path) {
                // The fix replaced this file, but its untouched copy is gone. Removing
                // the pack now would throw away the only way back.
                failed.append(entry.path)
            }
        }

        // The Photon swap edits the game's own assets, which no copy put in place.
        for relative in (recipe.photonPatched ?? []).reversed() {
            guard let file = file(relative, in: gameFolder) else {
                failed.append(relative)
                continue
            }
            // Restored by the auth patch below, from its own copy.
            if Paths.fm.fileExists(atPath: file.path + PhotonAuth.backupSuffix) {
                continue
            }
            let backup = file.appendingPathExtension("onlinefix-photon-backup")
            guard Paths.fm.fileExists(atPath: backup.path) else {
                if Paths.fm.fileExists(atPath: file.path) { failed.append(relative) }
                continue
            }
            if putBack(backup, at: file) { changed += 1 } else { failed.append(relative) }
        }

        // Valve's renderer and the other files taken out were moved aside, not deleted.
        for relative in recipe.removed.reversed() {
            guard let file = file(relative, in: gameFolder) else {
                failed.append(relative)
                continue
            }
            let backup = file.appendingPathExtension("onlinefix-removed")
            let fallback = gameFolder.appendingPathComponent(
                (relative as NSString).lastPathComponent)
            let candidates = [backup, fallback.appendingPathExtension("onlinefix-removed")]
            guard let back = candidates.first(where: {
                Paths.fm.fileExists(atPath: $0.path)
            }) else {
                if !Paths.fm.fileExists(atPath: file.path) { failed.append(relative) }
                continue
            }
            if putBack(back, at: file) { changed += 1 } else { failed.append(relative) }
        }

        if recipe.photonAuth != nil {
            do {
                try PhotonAuth.setEnabled(false, in: gameFolder)
                changed += 1
            } catch {
                failed.append("the Photon auth patch")
            }
        }

        if recipe.picoPark2,
           let bundle = FixInstaller.nativeMacBundle(in: gameFolder) {
            do {
                try MacBundlePatch.setEnabled(false, app: bundle)
                changed += 1
            } catch {
                failed.append("the Mac build's patch")
            }
        }

        guard failed.isEmpty else {
            throw ManagerError("Could not put back \(failed.prefix(3).joined(separator: ", "))"
                + (failed.count > 3 ? " and \(failed.count - 3) more" : "")
                + ". The untouched copies and the fix pack are still in the game folder, so "
                + "nothing is lost; fix the folder's permissions and undo again.")
        }

        // A prefix told to load the fix's DLLs would keep looking for them after the
        // files are gone, which stops the game from starting.
        _ = WineOverride.clear(appID: recipe.appID)

        try? Paths.fm.removeItem(at: folder(in: gameFolder))
        return changed
    }

    /// Moves a file aside, puts the backup in its place, and only then drops the
    /// staged copy. A failed move leaves the game file where it was.
    private static func putBack(_ backup: URL, at file: URL) -> Bool {
        let staged = file.appendingPathExtension("onlinefix-undo")
        try? Paths.fm.removeItem(at: staged)
        do {
            if Paths.fm.fileExists(atPath: file.path) {
                try Paths.fm.moveItem(at: file, to: staged)
            }
            do {
                try Paths.fm.moveItem(at: backup, to: file)
            } catch {
                if Paths.fm.fileExists(atPath: staged.path) {
                    try? Paths.fm.moveItem(at: staged, to: file)
                }
                throw error
            }
            try? Paths.fm.removeItem(at: staged)
            return true
        } catch {
            return false
        }
    }
}
