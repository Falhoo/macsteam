// Taking OnlineFix out, and nothing else.
//
// OnlineFix is not a dylib of its own any more: its routing lives inside
// macsteam.dylib and reads the `OnlineFix:` section of macSteam's config at each
// game's launch. So removing it means clearing the state it left behind:
//
//   * the manager's folder (My Games, the fix records, the routing list, the
//     per-build profiles),
//   * the `OnlineFix:` block in macSteam's config,
//   * `onlinefix.dylib` and the `ONLINEFIX_*` keys in Steam.app, which OnlineFix's
//     own install wrote,
//   * the files each fix put in a game folder, with the game's own files put back,
//   * the Photon patches it applied to a game's own files,
//   * the DLL overrides it wrote into each game's Wine prefix.
//
// What it deliberately leaves alone: macsteam.dylib, cloud_redirect.dylib,
// notproton.dylib, the injection list, the Steam update block, the signatures, the
// notproton runners, launchers and prefixes, and Steam's own compatibility and
// launch settings. Steam runs exactly as it did, just with no game routed.
import Foundation

enum OnlineFixRemoval {

    struct Options: Sendable {
        /// Put the game files each fix replaced back. Off keeps them, so another fix
        /// can be tried without downloading the game again.
        var restoreGameFiles = true
        /// Quit Steam when it is running, since Steam.app is edited.
        var quitSteam = true
    }

    struct Report: Sendable, Equatable {
        /// Where the manager's folder was moved to, when it existed.
        var stateArchive: URL?
        /// True when `onlinefix.dylib` was in Steam.app and is gone.
        var removedDylib = false
        /// The Steam.app environment keys that were cleared.
        var environmentKeys: [String] = []
        /// True when the `OnlineFix:` block was taken out of macSteam's config.
        var clearedConfig = false
        /// One line per game whose fix owned files were put back.
        var restoredGameFiles: [String] = []
        /// The game files a Photon patch restored.
        var restoredPhoton: [String] = []
        /// Payload files an earlier install left behind, now moved aside.
        var movedFiles: [String] = []
        /// The games whose Wine prefix had OnlineFix's DLL overrides taken out.
        var clearedOverrides: [Int] = []
        /// Things that could not be done, in words.
        var failures: [String] = []

        /// The removal in words, for a terminal or the app's status line.
        var summary: String {
            var lines = ["OnlineFix has been removed."]
            if let stateArchive {
                lines.append("Manager state moved to \(stateArchive.path).")
            } else {
                lines.append("There was no manager state to move.")
            }
            if removedDylib { lines.append("onlinefix.dylib was taken out of Steam.app.") }
            if !environmentKeys.isEmpty {
                lines.append("Cleared from Steam.app: " + environmentKeys.joined(separator: ", ") + ".")
            }
            if clearedConfig {
                lines.append("The OnlineFix section is gone from macSteam's config.")
            }
            if !restoredGameFiles.isEmpty {
                lines.append("Game files put back: " + restoredGameFiles.joined(separator: "; ") + ".")
            }
            if !restoredPhoton.isEmpty {
                lines.append("Photon patches reverted in \(restoredPhoton.count) file(s).")
            }
            if !movedFiles.isEmpty {
                lines.append("Moved aside: \(movedFiles.count) file(s) an earlier install left in "
                    + "the game folders.")
            }
            if !clearedOverrides.isEmpty {
                lines.append("Wine DLL overrides cleared for "
                    + clearedOverrides.map(String.init).joined(separator: ", ") + ".")
            }
            lines.append("macSteam, NotProton, the runners, the launchers and the Wine "
                + "prefixes were left alone.")
            if !failures.isEmpty {
                lines.append("Could not finish: " + failures.joined(separator: "; ") + ".")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The keys OnlineFix's install adds to Steam.app's environment.
    static let environmentKeys = ["ONLINEFIX_SIG", "ONLINEFIX_CONFIG", "ONLINEFIX_LOG"]

    /// Removes OnlineFix and reports what went.
    static func run(options: Options = Options()) -> Report {
        var report = Report()
        // Read the list before its folder is moved: the fix records are in it.
        let file = Store.load()

        if options.quitSteam, Steam.isRunning() {
            quitSteam()
            if Steam.isRunning() {
                report.failures.append("Steam did not close, so Steam.app was left alone")
            }
        }

        let archive = archiveRoot()
        report.stateArchive = archiveState(into: archive)

        if Paths.fm.fileExists(atPath: Paths.installedDylib.path) {
            do {
                try Paths.fm.removeItem(at: Paths.installedDylib)
                report.removedDylib = true
            } catch {
                report.failures.append("onlinefix.dylib: \(error.localizedDescription)")
            }
        }
        report.environmentKeys = clearSteamEnvironment()
        if report.removedDylib || !report.environmentKeys.isEmpty {
            // Steam.app's seal covers what was just changed.
            do {
                try Steam.codesign(Paths.steamApp)
            } catch {
                report.failures.append("Signing Steam.app: \(error.localizedDescription)")
            }
        }
        report.clearedConfig = clearHostConfig()

        if options.restoreGameFiles {
            for fix in file.fixes {
                do {
                    let folder = Store.gameFolder(for: fix.id, name: fix.gameName)
                    // The pack says which files the fix wrote and what each one
                    // replaced, which is more than a list of names can.
                    let changed: Int
                    if let folder, FixPack.hasPack(in: folder) {
                        changed = try FixPack.undo(in: folder)
                    } else {
                        changed = try FixInstaller.uninstall(fix)
                    }
                    if changed > 0 { report.restoredGameFiles.append("\(fix.gameName): \(changed)") }
                } catch {
                    report.failures.append("\(fix.gameName): \(error.localizedDescription)")
                }
            }
        }

        for game in file.games {
            guard let folder = Store.gameFolder(for: game.id, name: game.name) else { continue }
            if options.restoreGameFiles {
                // The Photon patches are made to the game's own files, so they come off
                // the same way whatever the fix record says.
                if let restored = try? PhotonPatch.restore(in: folder), !restored.isEmpty {
                    report.restoredPhoton.append(contentsOf: restored)
                }
                if let app = FixInstaller.nativeMacBundle(in: folder) {
                    if let written = try? MacBundlePatch.setEnabled(false, app: app) {
                        report.restoredPhoton.append(contentsOf: written)
                    }
                }
            }
            let cleared = WineOverride.clear(appID: game.id)
            if !cleared.isEmpty { report.clearedOverrides.append(game.id) }
        }

        if options.restoreGameFiles {
            // A fix installed twice keeps files its record does not name, and a game
            // removed from My Games keeps them too, so the whole library is looked at.
            for folder in sweepTargets(games: file.games) {
                report.movedFiles.append(contentsOf: sweep(folder, into: archive,
                                                           game: folder.lastPathComponent))
            }
        }
        return report
    }

    // MARK: - State

    /// Where everything this moves aside goes: one folder per removal, beside the
    /// manager's own folder.
    private static func archiveRoot() -> URL {
        Paths.appSupport.deletingLastPathComponent()
            .appendingPathComponent("OnlineFixManager-removed-\(timestamp())", isDirectory: true)
    }

    /// Moves the manager's folder aside, so My Games and the fix records can be put
    /// back if this was a mistake.
    private static func archiveState(into archive: URL) -> URL? {
        let fm = Paths.fm
        guard fm.fileExists(atPath: Paths.appSupport.path) else { return nil }
        let target = archive.appendingPathComponent("OnlineFixManager", isDirectory: true)
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            try fm.moveItem(at: Paths.appSupport, to: target)
            return target
        } catch {
            return nil
        }
    }

    // MARK: - What an earlier install left behind

    /// Names an OnlineFix package leaves in a game folder. A fix installed over
    /// another one brings its files back with the backup, so the record alone does
    /// not empty the folder.
    static let payloadNames: Set<String> = [
        "onlinefix64.dll", "onlinefix.dll", "onlinefix.ini", "onlinefix.url",
        "custom.dll", "custom.net", "dlllist.txt", "steamoverlay64.dll",
        "doorstop_config.ini",
    ]

    /// Folders the fix's loader keeps its own files in.
    static let payloadFolders: Set<String> = ["bepinex"]

    /// Proxy DLL names a game can own too, so they only go when the fix's own loader
    /// folder is there beside them.
    static let proxyNames: Set<String> = ["winmm.dll", "winhttp.dll", "version.dll",
                                          "dinput8.dll"]

    /// The game folders to look at: the ones in My Games, and every folder beside
    /// them in the Steam library.
    static func sweepTargets(games: [ManagedGame]) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for game in games {
            guard let folder = Store.gameFolder(for: game.id, name: game.name) else { continue }
            if seen.insert(folder.path).inserted { found.append(folder) }
        }
        let common = Paths.steamApps.appendingPathComponent("common", isDirectory: true)
        let entries = (try? Paths.fm.contentsOfDirectory(at: common,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            let isDirectory = ((try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            guard isDirectory, seen.insert(entry.path).inserted else { continue }
            found.append(entry)
        }
        return found
    }

    /// Moves the payload files this game folder still holds into the archive, and
    /// reports them as "Game/relative/path".
    static func sweep(_ folder: URL, into archive: URL, game: String) -> [String] {
        var found: [URL] = []
        var proxies: [URL] = []
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if payloadFolders.contains(name) {
                found.append(url)
                enumerator.skipDescendants()
                continue
            }
            if payloadNames.contains(name) || name.hasSuffix(".onlinefix-endpoint.lock") {
                found.append(url)
            } else if proxyNames.contains(name) {
                proxies.append(url)
            }
        }
        // A proxy beside the fix's loader folder is the fix's; on its own it may be
        // the game's, and is left where it is.
        let hadLoader = found.contains { payloadFolders.contains($0.lastPathComponent.lowercased()) }
        if hadLoader { found.append(contentsOf: proxies) }
        var moved: [String] = []
        let root = archive.appendingPathComponent("game-files", isDirectory: true)
            .appendingPathComponent(game.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        for url in found {
            let relative = url.path.hasPrefix(folder.path + "/")
                ? String(url.path.dropFirst(folder.path.count + 1))
                : url.lastPathComponent
            let target = root.appendingPathComponent(relative)
            do {
                try Paths.fm.createDirectory(at: target.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
                if Paths.fm.fileExists(atPath: target.path) {
                    try Paths.fm.removeItem(at: target)
                }
                try Paths.fm.moveItem(at: url, to: target)
                moved.append("\(game)/\(relative)")
            } catch {
                // A file that will not move is reported by the caller not seeing it.
                continue
            }
        }
        return moved
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    // MARK: - Steam.app

    /// Takes OnlineFix's keys out of Steam.app's `LSEnvironment`, leaving every other
    /// key, macSteam's injection first of all, exactly as it was.
    static func clearSteamEnvironment(plistURL: URL = Paths.steamInfoPlist) -> [String] {
        guard let data = try? Data(contentsOf: plistURL),
              var root = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any],
              var env = root["LSEnvironment"] as? [String: Any] else { return [] }
        var cleared: [String] = []
        for key in environmentKeys where env[key] != nil {
            env.removeValue(forKey: key)
            cleared.append(key)
        }
        if let libraries = env["DYLD_INSERT_LIBRARIES"] as? String {
            let all = libraries.split(separator: ":").map(String.init)
            let kept = all.filter { $0 != Paths.installedDylib.path }
            if kept.count != all.count {
                if kept.isEmpty { env.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
                else { env["DYLD_INSERT_LIBRARIES"] = kept.joined(separator: ":") }
                cleared.append("DYLD_INSERT_LIBRARIES")
            }
        }
        guard !cleared.isEmpty else { return [] }
        root["LSEnvironment"] = env
        guard let out = try? PropertyListSerialization.data(fromPropertyList: root,
                                                            format: .xml, options: 0) else {
            return []
        }
        do {
            try out.write(to: plistURL, options: .atomic)
        } catch {
            return []
        }
        return cleared
    }

    /// Quits Steam the way its own menu does, so it writes its caches on the way out.
    private static func quitSteam() {
        Shell.run("/usr/bin/open", ["steam://exit"], timeout: 10)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !Steam.isRunning() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if Steam.isRunning() {
            Shell.run("/usr/bin/pkill", ["-9", "-x", "steam_osx"], timeout: 10)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - macSteam's config

    /// Takes the `OnlineFix:` block out of macSteam's config, leaving every other key.
    @discardableResult
    static func clearHostConfig(file: URL = Paths.hostConfigFile) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let cleaned = clearingOnlineFixSection(in: text)
        guard cleaned != text else { return false }
        return (try? cleaned.write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    /// The config's text without its `OnlineFix:` block. The block runs from that key
    /// to the next line that starts at the left margin, since every entry in it is
    /// indented.
    static func clearingOnlineFixSection(in text: String) -> String {
        var kept: [String] = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            let atMargin = !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
            if atMargin {
                inSection = line.trimmingCharacters(in: .whitespaces) == "OnlineFix:"
                if inSection { continue }
            }
            if inSection { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
