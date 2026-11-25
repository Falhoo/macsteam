// Putting a plan into a game folder, and nothing else.
//
// Every copy lands in a staging file first and keeps the game's own file as
// `<name>.onlinefix-backup`, so a full disk or a lost permission never leaves the
// game with neither version. The ini and the loader's list are edited after they
// are placed, because OnlineFix's payload reads them at launch.
import Foundation

enum FixApply {

    struct Wrote: Sendable, Equatable {
        var relative: String
        /// True when the game had no such file, so undoing means deleting it.
        var created: Bool
    }

    struct Result: Sendable {
        var wrote: [Wrote] = []
        /// The files actually moved aside, as paths from the game folder, so the pack
        /// never claims to have removed one it could not.
        var removed: [String] = []
        var notes: [String] = []
        var changed: Bool { !wrote.isEmpty || !removed.isEmpty }
    }

    // MARK: - Apply

    static func apply(_ plan: FixPlan, appID: Int, folder: URL,
                      progress: (@Sendable (String) -> Void)? = nil) throws -> Result {
        var result = Result()

        for (index, copy) in plan.copies.enumerated() {
            progress?("Copying \(copy.destination.lastPathComponent) "
                + "(\(index + 1) of \(plan.copies.count))…")
            let created = try copyIntoPlace(copy.source, at: copy.destination)
            record(copy.destination, created: created, folder: folder, in: &result)
        }

        // A file the game already had, put back over the fix's copy. The fix's copy is
        // kept beside it, so switching back is one copy away.
        for restore in plan.restores {
            guard Paths.fm.fileExists(atPath: restore.source.path) else { continue }
            progress?("Putting the game's own \(restore.destination.lastPathComponent) back…")
            let created = try copyIntoPlace(restore.source, at: restore.destination)
            record(restore.destination, created: created, folder: folder, in: &result)
            result.notes.append("Put the game's own \(restore.destination.lastPathComponent) back.")
        }

        for edit in plan.edits {
            progress?("Editing \(edit.path.lastPathComponent)…")
            let changed: Bool
            switch edit.kind {
            case .iniAppIDs:
                changed = setAppIDs(at: edit.path, appID: appID)
            case .iniPhotonIntegration:
                changed = enablePhotonIntegration(at: edit.path)
            case .dllListEntries:
                let names = edit.names.isEmpty ? dllListNames(for: plan) : edit.names
                let ensured = ensureDLLListEntries(names, at: edit.path)
                let keep = Set(names.map { $0.lowercased() })
                let pruned = pruneDLLList(at: edit.path, folder: folder, keep: keep)
                changed = ensured || pruned
            case .dllListDropOverlay:
                changed = dropDLLListLine("steamoverlay64.dll", at: edit.path)
            case .steamAppID:
                changed = setSteamAppID(at: edit.path, appID: appID)
            }
            if changed { record(edit.path, created: false, folder: folder, in: &result) }
        }

        for url in plan.stubOverlay where Paths.fm.fileExists(atPath: url.path) {
            if OverlayStub.disable(at: url) {
                result.notes.append("Made \(url.lastPathComponent) do nothing at load, so its "
                    + "missing Steam renderer cannot stop the game.")
            }
        }

        for removal in plan.removals {
            guard Paths.fm.fileExists(atPath: removal.path.path) else { continue }
            // Keep what is taken out. A removed file is often the only copy of
            // something, and uninstall has to be able to put it back.
            let backup = removal.path.appendingPathExtension("onlinefix-removed")
            do {
                if Paths.fm.fileExists(atPath: backup.path) {
                    try Paths.fm.removeItem(at: backup)
                }
                try Paths.fm.moveItem(at: removal.path, to: backup)
                result.removed.append(relative(removal.path, in: folder))
                result.notes.append("Removed \(removal.path.lastPathComponent): \(removal.reason).")
            } catch {
                result.notes.append("Could not remove \(removal.path.lastPathComponent): "
                    + error.localizedDescription)
            }
        }

        // The prefix is Steam's, and it exists only after the game's first launch.
        if WineOverride.prefix(appID: appID) != nil {
            for dll in plan.wineDLLs {
                WineOverride.ensure(appID: appID, dll: dll, native: WineOverride.needsNative(dll))
            }
        }
        return result
    }

    /// The path as the recipe stores it, from the game folder.
    static func relative(_ url: URL, in folder: URL) -> String {
        FixPlan.relative(url, in: folder)
    }

    private static func record(_ url: URL, created: Bool, folder: URL, in result: inout Result) {
        let relative = FixPlan.relative(url, in: folder)
        if let index = result.wrote.firstIndex(where: { $0.relative == relative }) {
            // The copy decided this; an edit only adds a file it did not place.
            _ = index
            return
        }
        result.wrote.append(Wrote(relative: relative, created: created))
    }

    /// Steam's DRM stub is a native loader for Windows only, but Wine can run it.
    /// A Unity crash handler beside the game is what turns its exception into a
    /// dead process, so the handler is moved aside rather than the stub dropped.
    static func isDRMStubName(_ name: String) -> Bool {
        ["stubdrm64.dll", "stubdrm.dll"].contains(name.lowercased())
    }

    /// Unity starts this helper when the game takes an exception. Under Wine the
    /// helper can end the game while Steam's DRM stub is doing its work, so the
    /// fix moves it aside. It is only a crash reporter; gameplay does not need it.
    static func unityCrashHandlers(in folder: URL) -> [URL] {
        let names: Set<String> = ["unitycrashhandler64.exe", "unitycrashhandler.exe"]
        guard let contents = try? Paths.fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { names.contains($0.lastPathComponent.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The native files dlllist.txt has to carry. Custom.net is deliberately not
    /// here: it is the managed companion Custom.dll loads itself, not a library for
    /// OnlineFix64 to load. Naming it makes OnlineFix64 stop with error 126.
    static func dllListNames(for plan: FixPlan) -> [String] {
        var names: [String] = []
        for copy in plan.copies {
            let name = copy.destination.lastPathComponent
            let lower = name.lowercased()
            if FixPackage.payloadNames.contains(lower) || lower == "steamoverlay64.dll"
                || isDRMStubName(lower) {
                names.append(name)
            }
            // A root Custom.dll is loaded through dlllist.txt. A plugin under
            // BepInEx is started by the preloader instead.
            if lower == "custom.dll", !copy.relative.lowercased().hasPrefix("bepinex/") {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Files

    /// Copies a file into place, keeping the game's own copy once.
    @discardableResult
    static func copyIntoPlace(_ source: URL, at destination: URL) throws -> Bool {
        let fm = Paths.fm
        let parent = destination.deletingLastPathComponent()
        try Paths.ensureDir(parent)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).onlinefix-new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)

        var created = true
        if fm.fileExists(atPath: destination.path) {
            let backup = destination.appendingPathExtension("onlinefix-backup")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: destination, to: backup)
            }
            try fm.removeItem(at: destination)
            created = false
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return created
    }

    // MARK: - steam_appid.txt

    /// Puts the game's real AppID back in the text file beside the executable.
    /// Steam reads that file before the AppID it was started with, so a copy left
    /// by another game makes OnlineFix answer as that game.
    @discardableResult
    static func setSteamAppID(at url: URL, appID: Int) -> Bool {
        let original = TextFile.read(url)
        let current = (original?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != "\(appID)" else { return false }
        return TextFile.write("\(appID)", to: url, like: original)
    }

    // MARK: - OnlineFix.ini

    /// Fills in the two app ids the payload needs when the package left them out.
    /// A pair the package wrote is left alone: OnlineFix's protection refuses one it
    /// did not ship, so rewriting its values is worse than saying so.
    @discardableResult
    static func setAppIDs(at url: URL, appID: Int) -> Bool {
        guard var text = read(url) else { return false }
        let wanted = [("RealAppId", "\(appID)"), ("FakeAppId", "480")]
        let lineEnding = text.contains("\r\n") ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        var found = Set<String>()
        var changed = false

        // A package can carry an ini from another game, so a key that is present
        // but wrong is as much of an inconsistency as a key that is absent. Replace
        // every occurrence in place, preserving its indentation and CRLF.
        for index in lines.indices {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard let match = wanted.first(where: {
                $0.0.caseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            found.insert(match.0)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != match.1 else { continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            let carriageReturn = raw.hasSuffix("\r") ? "\r" : ""
            lines[index] = "\(indent)\(match.0)=\(match.1)\(carriageReturn)"
            changed = true
        }

        let missing = wanted.filter { !found.contains($0.0) }
        guard !missing.isEmpty || changed else { return false }
        if !missing.isEmpty {
            if let index = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[main]"
            }) {
                var insertAt = index + 1
                while insertAt < lines.count {
                    let trimmed = lines[insertAt].trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(";") || trimmed.hasPrefix("#") else { break }
                    insertAt += 1
                }
                for (key, value) in missing {
                    lines.insert("\(key)=\(value)\(lineEnding)", at: insertAt)
                    insertAt += 1
                }
            } else {
                lines.insert(contentsOf: ["[Main]\(lineEnding)"]
                    + missing.map { "\($0.0)=\($0.1)\(lineEnding)" }, at: 0)
            }
        }
        text = lines.joined(separator: "\n")
        return write(text, to: url)
    }

    /// `[Misc] PhotonIntegration=true`, leaving everything else alone. CRLF is what
    /// OnlineFix's own archives use, so a value that is already there must not look
    /// missing and grow a second section on every pass.
    @discardableResult
    static func enablePhotonIntegration(at url: URL) -> Bool {
        guard var text = read(url) else { return false }
        let wanted = ["true", "yes", "1"]
        let lineEnding = text.contains("\r\n") ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        // A value that is already on is left alone. A value that is off is
        // replaced in place: adding a second key above it leaves whichever one
        // the payload reads last deciding the answer.
        if let index = lines.firstIndex(where: {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("PhotonIntegration") == .orderedSame
        }) {
            let raw = lines[index]
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count == 2
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            if wanted.contains(value) { return false }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            let carriageReturn = raw.hasSuffix("\r") ? "\r" : ""
            lines[index] = "\(indent)PhotonIntegration=true\(carriageReturn)"
        } else if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[misc]"
        }) {
            lines.insert("PhotonIntegration=true\(lineEnding)", at: index + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[Misc]\(lineEnding)")
            lines.append("PhotonIntegration=true\(lineEnding)")
        }
        text = lines.joined(separator: "\n")
        return write(text, to: url)
    }

    /// True for `Key=value` in any spelling OnlineFix writes.
    static func hasKey(_ key: String, in text: String) -> Bool {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare(key) == .orderedSame { return true }
        }
        return false
    }

    static func hasPhotonIntegration(_ text: String) -> Bool {
        let wanted = ["true", "yes", "1"]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("photonintegration") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return wanted.contains(parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    // MARK: - dlllist.txt

    /// Adds the names the loader has to start, each once.
    @discardableResult
    static func ensureDLLListEntries(_ names: [String], at url: URL) -> Bool {
        // A package can leave the list out entirely. Creating it with the payload
        // and the Photon patch is what makes OnlineFix64 load either.
        guard !names.isEmpty else { return false }
        let original = read(url) ?? ""
        let newline = original.isEmpty || original.contains("\r\n") ? "\r\n" : "\n"
        let rawLines = dllListLines(original)
        var kept = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let wantedNames = names
        let removedUnsafe = kept.contains { $0.lowercased() == "custom.net" }
        kept.removeAll { $0.lowercased() == "custom.net" }
        var seen = Set<String>()
        let deduped = kept.filter { seen.insert($0.lowercased()).inserted }
        let hadDuplicate = deduped.count != kept.count
        kept = deduped
        let present = Set(kept.map { $0.lowercased() })
        let missing = wantedNames.filter { !present.contains($0.lowercased()) }
        // A blank line at the end is not harmless: OnlineFix64 reads it as an empty
        // DLL name and stops with "Failed to load  from the list. Error code: 126".
        // So the list is rewritten without a trailing newline.
        let overlayIndex = kept.firstIndex { $0.lowercased() == "steamoverlay64.dll" }
        let needsReorder = overlayIndex != nil && overlayIndex != 0
        // A blank line anywhere, and especially at the end, is read as an empty
        // DLL name. Detect it even when every wanted name is already present.
        let hadBlankLine = rawLines.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard removedUnsafe || !missing.isEmpty || needsReorder || hadBlankLine
            || hadDuplicate else {
            return false
        }
        kept.append(contentsOf: missing)
        // OnlineFix64 expects the overlay first. A list repaired from an older pack
        // may have it later, which fails the same way as leaving it out.
        if let index = kept.firstIndex(where: { $0.lowercased() == "steamoverlay64.dll" }),
           index != 0 {
            let overlay = kept.remove(at: index)
            kept.insert(overlay, at: 0)
        }
        return write(kept.joined(separator: newline), to: url)
    }

    /// Splits a loader list without inventing a blank line between the CR and LF of
    /// a Windows line ending. Every list OnlineFix writes is CRLF, and Foundation's
    /// newline set treats the two bytes as two separators.
    static func dllListLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Drops a name whose DLL is not beside the list or the game. A list carried
    /// over from another game names libraries that are not here, and OnlineFix64
    /// stops on the first one it cannot load with error 126.
    @discardableResult
    static func pruneDLLList(at url: URL, folder: URL, keep: Set<String>) -> Bool {
        guard let text = read(url) else { return false }
        let lines = dllListLines(text)
        let listFolder = url.deletingLastPathComponent()
        let wanted = Set(keep.map { $0.lowercased() })
        let kept = lines.filter { line in
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            let lower = name.lowercased()
            // A name the plan is about to place is kept even before the copy.
            if wanted.contains(lower) { return true }
            // A path is relative to the game or the list, not a bare file name.
            let relative = name.replacingOccurrences(of: "\\", with: "/")
            let candidates = [listFolder, folder].map { $0.appendingPathComponent(relative) }
            return candidates.contains { Paths.fm.fileExists(atPath: $0.path) }
        }
        guard kept.count != lines.count else { return false }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        return write(kept.joined(separator: newline), to: url)
    }

    /// Drops a line, such as the overlay loader that stops on error 126.
    @discardableResult
    static func dropDLLListLine(_ prefix: String, at url: URL) -> Bool {
        guard let text = read(url) else { return false }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(prefix.lowercased())
        }
        guard kept.count != lines.count else { return false }
        return write(kept.joined(separator: "\n"), to: url)
    }

    // MARK: - Text

    private static func read(_ url: URL) -> String? {
        TextFile.text(url)
    }

    private static func write(_ text: String, to url: URL) -> Bool {
        // Keep the ini or list in the encoding it arrived in. A UTF-16 OnlineFix.ini
        // rewritten as UTF-8 is still readable, but converting it back is one less
        // difference between the file the package shipped and the one left here.
        TextFile.write(text, to: url, like: TextFile.read(url))
    }
}
