// What a fix needs, and the tools the fix kit uses.
//
// An OnlineFix is three things working together: a Steam API DLL the game loads, a
// payload DLL (`OnlineFix64.dll`, `winmm.dll`, and the other proxies) that the loader
// starts, and `OnlineFix.ini`, which tells the payload which AppID the game really is.
// Deciding where each of those goes is `FixPlan`'s job and putting them there is
// `FixApply`'s; this file keeps the extraction, the small facts about a game folder
// (where Steam starts it from, which Steam API DLL it loads, whether it is a Mac
// build), the record of what an install wrote, and the checks that read it back.
import Foundation

/// Whether a recorded fix is still in the game folder.
///
/// Steam re-downloads, verifies and repairs games by putting the game's own files
/// back, which silently removes an installed fix while the record of it stays
/// behind. A record alone is therefore not proof that a game is fixed.
enum FixState: Equatable, Sendable {
    /// Every file the fix wrote is still the fix's own file.
    case installed
    /// Recorded files that are gone, or that Steam has put its own copy of back at
    /// the same path (a verify, an update, a repair), so the game runs without the
    /// fix even though the record and the paths are still there.
    case missing([String])
}

/// Installs a game-files fix (the package from online-fix.me) into a game.
enum FixInstaller {

    static func sevenZip() -> URL? {
        Steam.bundledResource("7zz")
    }

    // MARK: - State

    /// What is actually on disk for a recorded fix.
    static func state(of fix: FixRecord) -> FixState {
        var changed: [String] = []
        for path in fix.files where !isOptional(path) {
            guard let size = fileSize(path) else {
                changed.append(path)
                continue
            }
            // A path alone proves nothing: a Steam verify downloads the game's own
            // file to the same path the fix wrote. The size tells them apart. The
            // little files the app rewrites or the player edits are the exception.
            if !isEditable(path), let recorded = fix.sizes[path], recorded != size {
                changed.append(path)
            }
        }
        return changed.isEmpty ? .installed : .missing(changed)
    }

    /// Files whose content legitimately changes after the install: the app drops the
    /// overlay line from `dlllist.txt`, and a player may tune `OnlineFix.ini`. Their
    /// size changing does not mean Steam put the game's files back.
    static func isEditable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == "dlllist.txt" || name == "onlinefix.ini" || name == "onlinefix.url"
    }

    /// The overlay renderer OnlineFix's SteamOverlay64.dll loads is a compatibility
    /// aid Steam itself ships, and a prefix cleanup easily removes it. Losing it
    /// costs the in-game overlay, not the fix, so it does not make the fix "missing".
    static func isOptional(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "GameOverlayRenderer64.dll"
    }

    /// The sizes to record for a set of written files.
    static func sizes(of files: [String]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for path in files {
            if let size = fileSize(path) { sizes[path] = size }
        }
        return sizes
    }

    private static func fileSize(_ path: String) -> Int64? {
        guard let attributes = try? Paths.fm.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// True only when every file the fix wrote is still in the game folder.
    static func isInstalled(_ fix: FixRecord) -> Bool {
        state(of: fix) == .installed
    }

    /// True when the game folder holds the Windows build: an executable and no Mac
    /// bundle. Steam installs one platform at a time, so after the NotProton switch
    /// and its update this flips and the fix can be installed for real.
    static func hasWindowsBuild(in folder: URL) -> Bool {
        if nativeMacBundle(in: folder) != nil { return false }
        return hasAnyWindowsBuild(in: folder)
    }

    /// Whether the folder holds the game's Windows build, even with a Mac build beside
    /// it. `hasWindowsBuild` answers "is Windows what Steam starts?"; this answers
    /// "was the Windows version installed?", which is what the store card needs.
    static func hasAnyWindowsBuild(in folder: URL) -> Bool {
        !windowsExecutables(in: folder).isEmpty
    }

    /// The game's own `.exe` files, largest first.
    ///
    /// A folder can be full of executables that are not the game: Unity's crash
    /// handler, uninstallers, redistributables, a workshop tool. Counting those made a
    /// Mac-only game look like it had a Windows build (and the other way round), so
    /// each one has to be a real PE executable and not one of the known helpers.
    static func windowsExecutables(in folder: URL) -> [URL] {
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Int)] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  !isHelperExecutable(url.lastPathComponent),
                  isPEExecutable(url) else { continue }
            found.append((url, values.fileSize ?? 0))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Executables that ship with a game but are not the game.
    private static func isHelperExecutable(_ name: String) -> Bool {
        let lower = name.lowercased()
        let helpers = ["unitycrashhandler", "crashhandler", "unins", "setup", "install",
                       "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "dotnetfx",
                       "godotworkshoputility", "notification_helper", "steamerrorreporter"]
        return helpers.contains { lower.hasPrefix($0) || lower.contains($0) }
    }

    /// `MZ` and a PE header where the DOS stub points.
    static func isPEExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x40), head.count == 0x40,
              head[0] == 0x4d, head[1] == 0x5a else { return false }
        let offset = Int(head[0x3c]) | Int(head[0x3d]) << 8
            | Int(head[0x3e]) << 16 | Int(head[0x3f]) << 24
        guard offset > 0, offset < 4096 else { return false }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let marker = try? handle.read(upToCount: 4), marker.count == 4 else { return false }
        return marker[0] == 0x50 && marker[1] == 0x45
    }

    /// A macOS app bundle that still has its program in it. Steam leaves an empty
    /// `Game.app/Contents/MacOS` behind when it installs the Windows build beside it,
    /// and counting that skeleton made the store card call a Windows folder a Mac one.
    static func isMacAppBundle(_ url: URL) -> Bool {
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: macos, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.contains { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            return true
        }
    }

    /// Whether a file is a thin or fat Mach-O.
    static func machO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let thin: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe]
        let magic = UInt32(head[0]) << 24 | UInt32(head[1]) << 16
            | UInt32(head[2]) << 8 | UInt32(head[3])
        if thin.contains(magic) { return true }
        return magic == 0xcafebabe || magic == 0xbebafeca   // fat, big or little endian
    }

    /// A native macOS bundle at the top of a game folder. Steam runs that instead
    /// of the Windows build, and OnlineFix replaces Windows steam_api DLLs, so a
    /// Mac bundle leaves nothing for it to patch.
    static func nativeMacBundle(in folder: URL) -> URL? {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension.lowercased() == "app" {
            let isDirectory = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            guard isDirectory else { continue }
            if fm.fileExists(atPath: url.appendingPathComponent("Contents/MacOS").path),
               isMacAppBundle(url) { return url }
        }
        return nil
    }

    struct ImportResult {
        var files: [String]
        var targetDirectory: String
    }

    // MARK: - Extracting

    /// Unpacks a fix archive and returns the folder it unpacked into, which the caller
    /// removes. Where each file goes is decided afterwards, from the package and the
    /// game's own folder.
    static func extract(archive: URL, password: String?,
                        progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let sevenZip = sevenZip() else {
            throw ManagerError("The bundled 7-Zip tool is missing from this app.")
        }
        let temp = Paths.fm.temporaryDirectory
            .appendingPathComponent("onlinefix-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(temp)

        let name = archive.lastPathComponent
        progress("Extracting \(name)…")
        let pw = (password?.isEmpty == false) ? password! : FixSource.defaultPassword
        var args = ["x", "-y", "-bsp2", "-bb1", "-o\(temp.path)", "-p\(pw)", archive.path]
        var result = await extract(sevenZip: sevenZip, args: args, name: name, progress: progress)

        if result.timedOut {
            try? Paths.fm.removeItem(at: temp)
            throw ManagerError("Extracting \(name) took longer than 15 minutes and was "
                + "stopped. If that archive is the whole game rather than a fix, unpack it "
                + "by hand and use “Choose archive…” on the extracted folder's files.")
        }
        if result.code != 0 {
            // Not encrypted after all? Try once without a password.
            args = ["x", "-y", "-bsp2", "-bb1", "-o\(temp.path)", archive.path]
            progress("Retrying \(name) without a password…")
            let second = await extract(sevenZip: sevenZip, args: args, name: name,
                                       progress: progress)
            if second.timedOut {
                try? Paths.fm.removeItem(at: temp)
                throw ManagerError("Extracting \(name) took longer than 15 minutes and was stopped.")
            }
            if second.code == 0 {
                result = second
            } else {
                try? Paths.fm.removeItem(at: temp)
                let detail = (result.err + result.out).lowercased()
                if detail.contains("password") || detail.contains("wrong") {
                    throw ManagerError("The archive password was rejected. The default is "
                        + "“\(FixSource.defaultPassword)”.")
                }
                throw ManagerError("Extraction failed: \((second.err + second.out).suffix(600))")
            }
        }
        return temp
    }

    private static func extract(sevenZip: URL, args: [String], name: String,
                                progress: @escaping @Sendable (String) -> Void) async -> Shell.Result {
        let throttle = Throttle()
        return await Shell.runAsync(sevenZip.path, args, timeout: 900) { line in
            guard let text = progressText(line, name: name), throttle.allow() else { return }
            progress(text)
        }
    }

    /// "Extracting <archive>… 40%" when 7-Zip reports a percentage, otherwise the
    /// name of the file it is on.
    private static func progressText(_ line: String, name: String) -> String? {
        if let percent = percentage(in: line) {
            return "Extracting \(name)… \(percent)%"
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let file = (path as NSString).lastPathComponent
        return file.isEmpty ? nil : "Extracting \(name)… \(file)"
    }

    /// 7-Zip prints lines like "  5% 12 - name"; the number keeps the window
    /// moving while a large archive unpacks.
    private static func percentage(in line: String) -> Int? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else {
            return nil
        }
        return Int(line[range].dropLast())
    }

    /// 7-Zip prints a line per file, which for a big archive is far more window
    /// updates than anyone can read.
    private final class Throttle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date.distantPast
        private let interval: TimeInterval = 0.2

        func allow() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if now.timeIntervalSince(last) < interval { return false }
            last = now
            return true
        }
    }

    // MARK: - Helpers

    /// Executables a game ships beside its own but Steam never starts.
    static let helperExecutableNames: Set<String> = [
        "unitycrashhandler64.exe", "unitycrashhandler32.exe", "crashreportclient.exe",
        "wdapp.exe", "gamelaunchhelper.exe", "vcredist_x64.exe", "vcredist_x86.exe",
        "dxwebsetup.exe", "unins000.exe",
    ]

    /// The folder Steam starts the game from: the one holding its main executable.
    ///
    /// The executable named after the game wins; otherwise the largest one does. A
    /// game wrapped in a folder of its own (`Buckshot Roulette_windows`) has it one
    /// level down, and Windows only finds a DLL from the executable's own folder.
    static func launchFolder(in folder: URL) -> URL? {
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let wanted = Store.normalized(folder.lastPathComponent)
        var best: (url: URL, named: Bool, size: Int64)?
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  !helperExecutableNames.contains(url.lastPathComponent.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let named = Store.normalized(url.deletingPathExtension().lastPathComponent) == wanted
            if best == nil || (named && !best!.named) || (named == best!.named && size > best!.size) {
                best = (url, named, size)
            }
        }
        return best?.url.deletingLastPathComponent()
    }

    static func enumerateFiles(in root: URL) throws -> [URL] {
        guard let enumerator = Paths.fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    static func findExistingAPIDLL(in folder: URL) throws -> URL? {
        let files = try enumerateFiles(in: folder)
        return files
            .filter {
                let n = $0.lastPathComponent.lowercased()
                return n == "steam_api64.dll" || n == "steam_api.dll"
            }
            .sorted { $0.path.count < $1.path.count }
            .first
    }

    /// Removes a fix this app installed. Files it replaced are restored from their
    /// `*.onlinefix-backup` copies; files it added are deleted. Returns how many.
    @discardableResult
    static func uninstall(_ fix: FixRecord) throws -> Int {
        let fm = Paths.fm
        var changed = 0
        for path in fix.files {
            let file = URL(fileURLWithPath: path)
            // A patch keeps the untouched file under its own suffix. Putting one back
            // is not the same as removing OnlineFix's copy: the game needs the file.
            // The auth patch has its own suffix, and a file it edits is also one the
            // id patch edits, so both are checked before the copied-DLL backup.
            for suffix in [PhotonAuth.backupSuffix, ".onlinefix-photon-backup"] {
                let kept = URL(fileURLWithPath: file.path + suffix)
                guard fm.fileExists(atPath: kept.path) else { continue }
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                try fm.moveItem(at: kept, to: file)
                changed += 1
                break
            }
            if fm.fileExists(atPath: file.path) { continue }
            // OnlineFix replaced this file, so its untouched copy goes back; with no
            // copy it was OnlineFix's own file and is removed.
            let backup = file.appendingPathExtension("onlinefix-backup")
            if fm.fileExists(atPath: backup.path) {
                try fm.moveItem(at: backup, to: file)
                changed += 1
            } else if fm.fileExists(atPath: file.path) {
                try fm.removeItem(at: file)
                changed += 1
            }
        }
        return changed
    }

    /// OnlineFix's SteamOverlay64.dll loads Valve's GameOverlayRenderer64.dll, and
    /// when that is missing it pops up "Failed to load steam overlay dll. Error
    /// code: 126". Steam ships a Windows build of that renderer for its legacy
    /// compatibility layer; put a copy wherever the overlay looks: beside the
    /// game, in the Windows prefix's Steam install folder (the registry's
    /// InstallPath under Wine) and in its system32.
    /// A warning for a fix built for the Microsoft Store (GDK) version of a game.
    ///
    /// Those packages are not the Steam fix: they ship `GDK_Helper.bat`, `wdapp.exe`
    /// and `xsapi.dll`, and they need the Xbox GDK runtime (`xgameruntime.dll`) that
    /// ships with the Xbox app on Windows. Wine has no such runtime, so the fix
    /// aborts on startup with error 126.
    /// A Microsoft Store (GDK) fix is for the Xbox build. It needs the GDK runtime
    /// (`xgameruntime.dll`), which is not part of Wine: the game stops at start with
    /// "Failed to load xgameruntime.dll. Error code: 126".
    static func gdkIssue(for fix: FixRecord) -> String? {
        guard isGDKFix(fix) else { return nil }
        // A fix that carries Steam's API as well belongs to a game that runs as the
        // Steam build, which is what PEAK does: its GDK files are the runtime the game
        // looks for, not a sign that it cannot start. Only a fix with no Steam side is
        // the Microsoft Store one that stops at error 126.
        let names = Set(fix.files.map { ($0 as NSString).lastPathComponent.lowercased() })
        guard !names.contains("steam_api64.dll"), !names.contains("steam_api.dll") else {
            return nil
        }
        return "This is the Microsoft Store (GDK) version of the fix, and it needs the Xbox GDK "
            + "runtime (xgameruntime.dll), which only exists on Windows. The game stops with "
            + "error 126 while loading it. Remove the fix and play the Steam build as itself."
    }

    private static func isGDKFix(_ fix: FixRecord) -> Bool {
        let names = Set(fix.files.map { ($0 as NSString).lastPathComponent.lowercased() })
        return names.contains("gdk_helper.bat")
            || names.contains("wdapp.exe")
            || names.contains("xsapi.dll")
    }

    /// True when the game's Windows prefix already has the Xbox GDK runtime.
    private static func gdkRuntimeAvailable(in folder: URL, appID: Int?) -> Bool {
        let names = ["xgameruntime.dll", "gamingservices.dll", "gamingservicesnet.dll"]
        if names.contains(where: {
            Paths.fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }) { return true }
        guard let appID else { return false }
        let system32 = Paths.steamSupport
            .appendingPathComponent("steamapps/compatdata/\(appID)/pfx/drive_c/windows/system32",
                                    isDirectory: true)
        return names.contains {
            Paths.fm.fileExists(atPath: system32.appendingPathComponent($0).path)
        }
    }

    private static func overlayFolder(under folder: URL) -> URL? {
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == "SteamOverlay64.dll" {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }
}