// The Photon app a game connects to, as the original OnlineFix Manager patches it.
//
// A Unity game carries the Photon app id as a GUID inside one of its data files. When
// OnlineFix's default app is overloaded, the original manager replaces those GUIDs
// with ones the player supplies; this does the same for any Photon game, keeps the
// untouched file as a backup, and puts it back when the fields are cleared.
//
// Only ids that OnlineFix's own packages publish are replaced, so a game's other
// GUIDs (asset ids, unrelated services) are never touched.
import Foundation

enum PhotonIDs {

    /// R.E.P.O.'s pair, which is the one place realtime and voice differ.
    static let realtime = "99515094-45b7-4c98-ab70-a448c548c83d"
    static let voice = "dfc40a01-c3a4-4395-9707-b71118816d2b"

    /// Every Photon app OnlineFix's packages publish, and whether it is a voice id.
    /// The single ones belong to the other Photon games the original manager patches.
    static let knownDefaults: [(id: String, voice: Bool)] = [
        (realtime, false),
        (voice, true),
        ("80449c66-0a91-49a5-acb6-ca805e84e605", false),
        ("9cb5e203-aa4b-4bed-9533-ac78b5672cb4", false),
        ("f06cfaa3-c29b-4dba-a8ca-551f45bf9b6d", false),
    ]

    /// Where a Unity game keeps its data, and the backups this makes.
    private static let backupSuffix = ".onlinefix-photon-backup"

    /// Applies the IDs to the game files. Both empty restores the backups.
    /// Returns the files written.
    @discardableResult
    static func apply(gameFolder: URL, realtime wantedRealtime: String,
                      voice wantedVoice: String) throws -> [String] {
        let wantRealtime = wantedRealtime.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantVoice = wantedVoice.trimmingCharacters(in: .whitespacesAndNewlines)

        if wantRealtime.isEmpty, wantVoice.isEmpty {
            return try restore(gameFolder: gameFolder)
        }
        guard isGUID(wantRealtime) else {
            throw ManagerError("The realtime app ID must be a GUID, like \(realtime).")
        }
        if !wantVoice.isEmpty {
            guard isGUID(wantVoice) else {
                throw ManagerError("The voice app ID must be a GUID, like \(voice).")
            }
            guard wantVoice != wantRealtime else {
                throw ManagerError("Realtime and voice need different app IDs.")
            }
        }

        let files = candidates(in: gameFolder)
        guard !files.isEmpty else {
            throw ManagerError("No Photon app ID from OnlineFix was found in this game's "
                + "files, so there is nothing to replace.")
        }

        // A file may hold the realtime/voice pair (R.E.P.O.) or a single id (the other
        // games). A single one always becomes the realtime id.
        var written: [String] = []
        for file in files {
            let located = knownDefaults.filter { file.data.range(of: Data($0.id.utf8)) != nil }
            let singles = located.filter { !$0.voice && $0.id != Self.realtime }
            if singles.count > 1, !located.contains(where: { $0.id == Self.realtime }) {
                throw ManagerError("This game's files carry more than one Photon app ID, "
                    + "so which is realtime and which is voice is unclear. Nothing was changed.")
            }
            var data = file.data
            for item in located {
                let replacement = item.voice ? wantVoice : wantRealtime
                guard !replacement.isEmpty else { continue }
                data = replacing(data, old: item.id, new: replacement)
            }
            guard data != file.data else { continue }
            let backup = URL(fileURLWithPath: file.url.path + backupSuffix)
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: file.url, to: backup)
            }
            try data.write(to: file.url, options: .atomic)
            written.append(file.url.path)
        }
        guard !written.isEmpty else {
            throw ManagerError("Nothing changed: those are the IDs the game already carries.")
        }
        return written
    }

    /// Puts every patched file back and drops the backups.
    @discardableResult
    static func restore(gameFolder: URL) throws -> [String] {
        var restored: [String] = []
        guard let enumerator = Paths.fm.enumerator(
            at: gameFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(backupSuffix) else { continue }
            let original = URL(fileURLWithPath: String(url.path.dropLast(backupSuffix.count)))
            try? Paths.fm.removeItem(at: original)
            try Paths.fm.copyItem(at: url, to: original)
            try? Paths.fm.removeItem(at: url)
            restored.append(original.path)
        }
        return restored
    }

    /// True when the text is a GUID, the only shape Photon takes.
    static func isGUID(_ text: String) -> Bool {
        text.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                   options: .regularExpression) != nil
    }

    // MARK: - Files

    private struct Candidate {
        let url: URL
        let data: Data
    }

    /// The game's data files that could hold a Photon app id, read once.
    private static func candidates(in folder: URL) -> [Candidate] {
        let names: Set<String> = ["resources.assets", "globalgamemanagers.assets",
                                  "global-metadata.dat", "level0"]
        var out: [Candidate] = []
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 5 {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.hasSuffix(backupSuffix) { continue }
            let name = url.lastPathComponent.lowercased()
            let inManaged = url.path.lowercased().contains("/managed/")
            guard names.contains(name)
                || (inManaged && name.hasSuffix(".dll"))
                || (url.path.contains(".app/Contents/MacOS/") && !inManaged) else { continue }
            // A file patched before is compared through its untouched copy, so a second
            // edit does not replace ids that are no longer there.
            let backup = URL(fileURLWithPath: url.path + backupSuffix)
            let base = Paths.fm.fileExists(atPath: backup.path) ? backup : url
            guard let values = try? base.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024,
                  let data = try? Data(contentsOf: base, options: .mappedIfSafe) else { continue }
            guard knownDefaults.contains(where: { data.range(of: Data($0.id.utf8)) != nil })
            else { continue }
            out.append(Candidate(url: url, data: data))
        }
        return out
    }

    private static func replacing(_ data: Data, old: String, new: String) -> Data {
        guard old.utf8.count == new.utf8.count else { return data }
        guard let range = data.range(of: Data(old.utf8)) else { return data }
        var result = data
        result.replaceSubrange(range, with: Data(new.utf8))
        return result
    }
}
