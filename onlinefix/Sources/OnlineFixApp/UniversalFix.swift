// What every OnlineFix needs to load, whatever game it was installed into.
//
// An OnlineFix is three things working together: a Steam API DLL the game loads,
// a payload DLL (`OnlineFix64.dll`, `winmm.dll`, and the other proxies) that the
// loader starts, and `OnlineFix.ini`, which tells the payload which AppID the game
// really is. Fix archives put those files wherever their author had them, and not
// every archive agrees with the game's own layout: a fix whose `steam_api64.dll`
// went into `_Data/Plugins/x86_64` while `OnlineFix64.dll` stayed at the game root
// loads nothing, `SteamAPI_Init` fails, and a lot of games exit or crash on the
// spot. The same happens when the game's own Steam API DLL is the one it loads,
// because the fix only replaced a copy nothing reads.
//
// This pass repairs both cases after an install and again on every refresh, so a
// game works with whatever the archive contained. It copies, never moves, and it
// never overwrites a file it did not put there without keeping a backup, so the
// fix's own uninstall can still put the game back.
import Foundation

enum UniversalFix {

    struct Report: Sendable {
        /// Files this pass added or replaced, so the fix's record can undo them.
        var additions: [String] = []
        /// What was repaired, in words, for the patch sheet and the store card.
        var notes: [String] = []

        var changed: Bool { !additions.isEmpty || !notes.isEmpty }
    }

    /// Proxy DLLs an OnlineFix or BepInEx starts from beside the executable.
    static let proxies: Set<String> = [
        "onlinefix64.dll", "onlinefix.dll",
        "winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll",
        "steamoverlay64.dll",
    ]

    /// Everything that has to sit in the same folder as the loader. The Steam API
    /// DLL is not here on purpose: where the game loads it is decided by the game,
    /// so it is adopted where it actually is instead of sprayed around.
    static let companions: Set<String> = proxies.union([
        "onlinefix.ini", "onlinefix.url", "dlllist.txt",
    ])

    /// The game's Steam API DLL, under both of its names.
    static let apiNames: Set<String> = ["steam_api64.dll", "steam_api.dll"]

    /// Deep enough for a game's executable and its plugins inside an engine tree.
    static let maxDepth = 8

    // MARK: - Entry point

    /// Repairs an installed fix in place. Safe to call on every refresh: it only
    /// writes when something is missing or in the wrong folder.
    @discardableResult
    static func apply(appID: Int, gameFolder: URL, fixFiles: [String]) -> Report {
        var report = Report()
        guard !fixFiles.isEmpty else { return report }

        let recorded = fixFiles.map { URL(fileURLWithPath: $0) }
        let present = recorded.filter { Paths.fm.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return report }

        // The fix's own copy of each companion is the source of every copy made
        // below, so a repaired folder always holds the fix's files, never a stale
        // or unrelated build of the same name.
        var sources: [String: URL] = [:]
        for file in present {
            let name = file.lastPathComponent.lowercased()
            if companions.contains(name), sources[name] == nil { sources[name] = file }
        }

        // Where the loader looks: the folder of the executable Steam starts, the
        // folder of the Steam API DLL the game loads, and any folder that already
        // holds one of the fix's proxies (an archive unpacked by hand).
        let destinations = destinationFolders(gameFolder: gameFolder, present: present)

        var copied = 0
        for folder in destinations {
            for name in sources.keys.sorted() {
                guard let source = sources[name] else { continue }
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                if samePath(destination, source) { continue }
                guard !Paths.fm.fileExists(atPath: destination.path) else { continue }
                if copy(source, into: folder) != nil {
                    report.additions.append(destination.path)
                    copied += 1
                }
            }
        }
        if copied > 0 {
            report.notes.append("Copied \(copied) fix file(s) beside the executable so the "
                + "loader can find them.")
        }

        let adopted = adoptSteamAPI(recorded: present, gameFolder: gameFolder)
        report.additions.append(contentsOf: adopted)
        if !adopted.isEmpty {
            report.notes.append("Put the fix's Steam API DLL where the game loads it "
                + "(\(adopted.count) file(s)), so the game runs the fix instead of its "
                + "own copy.")
        }

        // Every copy of the ini now in play gets the same treatment: a package
        // whose ini is missing those keys cannot tell the payload which game it is.
        var inis = Set<URL>()
        for folder in destinations {
            if let ini = file(named: "onlinefix.ini", in: folder) { inis.insert(ini) }
        }
        for source in sources.values where source.lastPathComponent.lowercased() == "onlinefix.ini" {
            inis.insert(source)
        }
        for ini in inis {
            if normaliseINI(at: ini, appID: appID) { report.notes.append(iniNote) }
        }
        return report
    }

    // MARK: - Where the loader looks

    private static func destinationFolders(gameFolder: URL, present: [URL]) -> [URL] {
        var folders: [URL] = []
        func add(_ folder: URL) {
            guard folders.contains(where: { samePath($0, folder) }) == false else { return }
            folders.append(folder)
        }
        add(FixInstaller.launchFolder(in: gameFolder) ?? gameFolder)
        if let api = try? FixInstaller.findExistingAPIDLL(in: gameFolder) {
            add(api.deletingLastPathComponent())
        }
        for file in present where proxies.contains(file.lastPathComponent.lowercased()) {
            add(file.deletingLastPathComponent())
        }
        return folders
    }

    // MARK: - The Steam API DLL

    /// Puts the fix's Steam API DLL over any other copy of it in the game folder.
    ///
    /// A fix only works when the DLL the game loads is the fix's. When the archive
    /// carries a trampoline and the game also ships the untouched DLL elsewhere,
    /// the game loads its own, OnlineFix never starts, and the rest of the fix's
    /// files are dead weight. The game's copy is backed up first.
    private static func adoptSteamAPI(recorded: [URL], gameFolder: URL) -> [String] {
        var fixCopies: [String: URL] = [:]
        for file in recorded {
            let name = file.lastPathComponent.lowercased()
            if apiNames.contains(name), fixCopies[name] == nil { fixCopies[name] = file }
        }
        guard !fixCopies.isEmpty else { return [] }

        guard let enumerator = Paths.fm.enumerator(
            at: gameFolder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var replaced: [String] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard let fixCopy = fixCopies[name] else { continue }
            // The backups this app keeps are not the game's files.
            if url.path.contains("/.macsteam-fix/") || url.path.hasSuffix(".onlinefix-backup") {
                continue
            }
            if samePath(url, fixCopy) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    != (try? fixCopy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            else { continue }
            if copyOver(fixCopy, at: url) { replaced.append(url.path) }
        }
        return replaced
    }

    // MARK: - OnlineFix.ini

    private static let iniNote = "Filled in the fix's missing App ID settings so its loader knows "
        + "which game it belongs to."

    /// Adds `RealAppId` and `FakeAppId` when the ini has no such keys. An ini that
    /// names a different game is left alone: OnlineFix's own protection refuses a
    /// pair it did not ship, so rewriting a value it wrote is worse than saying so.
    private static func normaliseINI(at url: URL, appID: Int) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let wanted = [("RealAppId", "\(appID)"), ("FakeAppId", "480")]
        var missing: [(String, String)] = []
        for (key, value) in wanted where !hasKey(key, in: text) {
            missing.append((key, value))
        }
        guard !missing.isEmpty else { return false }

        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "[main]"
        }) {
            var insertAt = index + 1
            // Keep any comment that introduces the section where it is.
            while insertAt < lines.count,
                  lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix(";")
                    || lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                insertAt += 1
            }
            for (key, value) in missing {
                lines.insert("\(key)=\(value)", at: insertAt)
                insertAt += 1
            }
        } else {
            lines.insert(contentsOf: ["[Main]"] + missing.map { "\($0.0)=\($0.1)" }, at: 0)
        }
        let joined = lines.joined(separator: "\n")
        guard (try? joined.data(using: .utf8)?.write(to: url, options: .atomic)) != nil else {
            return false
        }
        return true
    }

    /// True for `Key=value` in any spelling OnlineFix writes.
    private static func hasKey(_ key: String, in text: String) -> Bool {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(key) == .orderedSame {
                return true
            }
        }
        return false
    }

    // MARK: - Files

    /// A file in a folder, matched the way Windows does: without regard to case.
    private static func file(named name: String, in folder: URL) -> URL? {
        guard let entries = try? Paths.fm.contentsOfDirectory(atPath: folder.path) else {
            return nil
        }
        guard let match = entries.first(where: {
            $0.lowercased() == name.lowercased()
        }) else { return nil }
        return folder.appendingPathComponent(match)
    }

    private static func samePath(_ one: URL, _ other: URL) -> Bool {
        one.standardizedFileURL.resolvingSymlinksInPath()
            == other.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Copies a file into a folder without ever replacing one already there.
    @discardableResult
    private static func copy(_ source: URL, into folder: URL) -> URL? {
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let staging = folder.appendingPathComponent(".\(source.lastPathComponent).universal-new")
        do {
            try Paths.ensureDir(folder)
            try? Paths.fm.removeItem(at: staging)
            try Paths.fm.copyItem(at: source, to: staging)
            guard !Paths.fm.fileExists(atPath: destination.path) else {
                try? Paths.fm.removeItem(at: staging)
                return nil
            }
            try Paths.fm.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? Paths.fm.removeItem(at: staging)
            return nil
        }
    }

    /// Puts the fix's copy at a path another copy already occupies, keeping the
    /// game's own file as `*.onlinefix-backup` so uninstall can put it back.
    private static func copyOver(_ source: URL, at destination: URL) -> Bool {
        let backup = destination.appendingPathExtension("onlinefix-backup")
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).universal-new")
        do {
            if Paths.fm.fileExists(atPath: destination.path),
               !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: destination, to: backup)
            }
            try? Paths.fm.removeItem(at: staging)
            try Paths.fm.copyItem(at: source, to: staging)
            if Paths.fm.fileExists(atPath: destination.path) {
                try Paths.fm.removeItem(at: destination)
            }
            try Paths.fm.moveItem(at: staging, to: destination)
            return true
        } catch {
            try? Paths.fm.removeItem(at: staging)
            return false
        }
    }
}
