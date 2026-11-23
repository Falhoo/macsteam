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
        var notes: [String] = []
        var changed: Bool { !wrote.isEmpty }
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
                changed = ensureDLLListEntries(dllListNames(for: plan), at: edit.path)
            case .dllListDropOverlay:
                changed = dropDLLListLine("steamoverlay64.dll", at: edit.path)
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
            try? Paths.fm.removeItem(at: removal.path)
            result.notes.append("Removed \(removal.path.lastPathComponent): \(removal.reason).")
        }

        // The prefix is Steam's, and it exists only after the game's first launch.
        if WineOverride.prefix(appID: appID) != nil {
            for dll in plan.wineDLLs {
                WineOverride.ensure(appID: appID, dll: dll, native: WineOverride.needsNative(dll))
            }
        }
        return result
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

    /// The names dlllist.txt has to carry: the payload the package brought, and the
    /// Photon patch when its preloader is there.
    static func dllListNames(for plan: FixPlan) -> [String] {
        var names: [String] = []
        for copy in plan.copies {
            let name = copy.destination.lastPathComponent
            let lower = name.lowercased()
            if FixPackage.payloadNames.contains(lower) { names.append(name) }
            if lower == "custom.dll" { names.append("Custom.net") }
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

    // MARK: - OnlineFix.ini

    /// Fills in the two app ids the payload needs when the package left them out.
    /// A pair the package wrote is left alone: OnlineFix's protection refuses one it
    /// did not ship, so rewriting its values is worse than saying so.
    @discardableResult
    static func setAppIDs(at url: URL, appID: Int) -> Bool {
        guard var text = read(url) else { return false }
        let wanted = [("RealAppId", "\(appID)"), ("FakeAppId", "480")]
        let missing = wanted.filter { !hasKey($0.0, in: text) }
        guard !missing.isEmpty else { return false }

        var lines = text.components(separatedBy: "\n")
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
                lines.insert("\(key)=\(value)", at: insertAt)
                insertAt += 1
            }
        } else {
            lines.insert(contentsOf: ["[Main]"] + missing.map { "\($0.0)=\($0.1)" }, at: 0)
        }
        text = lines.joined(separator: "\n")
        return write(text, to: url)
    }

    /// `[Misc] PhotonIntegration=true`, leaving everything else alone. CRLF is what
    /// OnlineFix's own archives use, so a value that is already there must not look
    /// missing and grow a second section on every pass.
    @discardableResult
    static func enablePhotonIntegration(at url: URL) -> Bool {
        guard var text = read(url), !hasPhotonIntegration(text) else { return false }
        var lines = text.components(separatedBy: "\n")
        let line = "PhotonIntegration=true"
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[misc]"
        }) {
            lines.insert(line, at: index + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[Misc]")
            lines.append(line)
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
        guard var text = read(url) else { return false }
        let present = Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let missing = names.filter { !present.contains($0.lowercased()) }
        guard !missing.isEmpty else { return false }
        if !text.hasSuffix("\n") { text += "\n" }
        text += missing.joined(separator: "\n") + "\n"
        return write(text, to: url)
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

    /// Adds `Custom.net` to the loader list, which is how OnlineFix64 learns to start
    /// the Photon patch.
    @discardableResult
    static func addCustomToDLLList(at url: URL) -> Bool {
        ensureDLLListEntries(["Custom.net"], at: url)
    }

    // MARK: - Text

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func write(_ text: String, to url: URL) -> Bool {
        (try? text.data(using: .utf8)?.write(to: url, options: .atomic)) != nil
    }
}
