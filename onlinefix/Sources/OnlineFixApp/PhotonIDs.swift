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

    /// The apps OnlineFix publishes for games other than R.E.P.O. R.E.P.O.'s own
    /// pair is a game app, not a shared one: a ticket request against it is the
    /// game asking for its own licence, not a game pointed at OnlineFix's app.
    static var shared: [String] {
        knownDefaults.filter { $0.id != realtime && $0.id != voice }.map { $0.id }
    }

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

        // Use the field-aware scanner: a PhotonServerSettings pair can hold the same
        // value twice, and replacing every copy would put the realtime id in the
        // voice field. Settings are found by name, so this also reaches a game whose
        // stock ids are not in the list below (PEAK's, for one).
        let found = PhotonPatch.scan(in: gameFolder)
        let relevant = found.filter { candidate in
            candidate.settings || knownDefaults.contains {
                $0.id.lowercased() == candidate.id.lowercased()
            }
        }
        var changes: [PhotonPatch.Change]
        if relevant.isEmpty {
            // A second edit finds the game carrying our own ids, which the scanner
            // no longer offers. The untouched copy still names the fields, so it is
            // what the next edit is worked out from.
            changes = try changesFromBackups(in: gameFolder,
                                             realtime: wantRealtime, voice: wantVoice)
        } else {
            let settings = relevant.filter(\.settings)
            var settingsFiles = Set<String>()
            if settings.count == 2 {
                let plan = PhotonPatch.plan(for: relevant, realtime: wantRealtime,
                                            voice: wantVoice)
                if let skipped = plan.skipped { throw ManagerError(skipped) }
                changes = plan.changes
                settingsFiles = Set(settings.map(\.file.path))
            } else if settings.count > 2 {
                throw ManagerError("This game's Photon settings carry more than a "
                    + "realtime/voice pair, so which two to change is unclear. Nothing "
                    + "was changed.")
            } else {
                changes = []
            }
            let live = relevant.filter { !settingsFiles.contains($0.file.path) }
            let nonVoice = Set(live.filter { candidate in
                !knownDefaults.contains {
                    $0.voice && $0.id.lowercased() == candidate.id.lowercased()
                }
            }.map(\.id))
            if nonVoice.count > 1 {
                throw ManagerError("This game's files carry more than one Photon app ID, "
                    + "so which is realtime and which is voice is unclear. Nothing was changed.")
            }
            for candidate in live {
                let target = knownDefaults.contains {
                    $0.voice && $0.id.lowercased() == candidate.id.lowercased()
                } ? wantVoice : wantRealtime
                guard !target.isEmpty, target != candidate.id else { continue }
                changes.append(PhotonPatch.Change(candidate: candidate, old: candidate.id,
                                                  new: target))
            }
        }
        guard !changes.isEmpty else {
            throw ManagerError("Nothing changed: those are the IDs the game already carries.")
        }
        let written = try PhotonPatch.apply(changes, in: gameFolder)
        guard !written.isEmpty else {
            throw ManagerError("Nothing changed: those are the IDs the game already carries.")
        }
        return written
    }

    /// The fields named by the untouched copies, as changes to write into the game's
    /// current files. This is how a second edit reaches a field the first one already
    /// replaced; the offsets are the same as in the current file.
    private static func changesFromBackups(in folder: URL, realtime: String,
                                           voice: String) throws -> [PhotonPatch.Change] {
        var changes: [PhotonPatch.Change] = []
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let backup as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard backup.lastPathComponent.hasSuffix(backupSuffix),
                  let values = try? backup.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: backup, options: [.mappedIfSafe])
            else { continue }
            let original = URL(fileURLWithPath: String(backup.path.dropLast(backupSuffix.count)))
            guard let current = try? Data(contentsOf: original, options: [.mappedIfSafe]) else {
                continue
            }
            let settings = PhotonPatch.assetIDs(in: data)
            if settings.count == 2 {
                for (index, item) in settings.enumerated() {
                    let target = index == 0 ? realtime : voice
                    // An empty voice field asks for the game's own voice id back.
                    let wanted = target.isEmpty && index == 1 ? item.id : target
                    let old = currentID(at: item.offset, in: current) ?? item.id
                    guard !wanted.isEmpty, wanted != old else { continue }
                    let candidate = PhotonPatch.Candidate(
                        file: original, id: item.id, kind: .guid,
                        offset: item.offset, settings: true)
                    changes.append(PhotonPatch.Change(candidate: candidate, old: old,
                                                      new: wanted))
                }
                continue
            }
            for item in PhotonPatch.ids(in: data) where item.kind == .guid {
                guard let known = knownDefaults.first(where: {
                    $0.id.lowercased() == item.id.lowercased()
                }) else { continue }
                let target = known.voice ? voice : realtime
                let wanted = target.isEmpty && known.voice ? item.id : target
                let old = currentID(at: item.offset, in: current) ?? item.id
                guard !wanted.isEmpty, wanted != old else { continue }
                let candidate = PhotonPatch.Candidate(
                    file: original, id: item.id, kind: .guid, offset: item.offset)
                changes.append(PhotonPatch.Change(candidate: candidate, old: old,
                                                  new: wanted))
            }
        }
        return changes
    }

    /// The GUID the current file holds where the untouched copy had one. A second
    /// edit replaces what the first one wrote, not the original value, so this is the
    /// value that change has to name.
    private static func currentID(at offset: Int, in data: Data) -> String? {
        guard offset >= 0, offset + 36 <= data.count,
              let text = String(data: data[offset..<(offset + 36)], encoding: .utf8),
              isGUID(text) else { return nil }
        return text
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

}
