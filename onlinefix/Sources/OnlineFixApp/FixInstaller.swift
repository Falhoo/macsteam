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
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "exe",
               (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
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
            let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            if fm.fileExists(atPath: macos.path) { return url }
        }
        return nil
    }

    struct ImportResult {
        var files: [String]
        var targetDirectory: String
    }

    // MARK: - From an archive

    /// Unpacks a fix archive and installs it. The unpacking runs off the calling
    /// thread and reports its percentage, because a fix archive can be large and
    /// 7-Zip gives no sign of life for minutes at a time.
    static func install(
        archive: URL,
        game: ManagedGame,
        allowGDK: Bool = false,
        allowNative: Bool = false,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ImportResult {
        try await install(archive: archive, game: game,
                          password: FixSource.defaultPassword, allowGDK: allowGDK,
                          allowNative: allowNative, progress: progress)
    }

    static func install(
        archive: URL,
        game: ManagedGame,
        password: String?,
        allowGDK: Bool = false,
        allowNative: Bool = false,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ImportResult {
        guard let sevenZip = sevenZip() else {
            throw ManagerError("The bundled 7-Zip tool is missing from this app.")
        }

        let temp = Paths.fm.temporaryDirectory
            .appendingPathComponent("onlinefix-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(temp)
        defer { try? Paths.fm.removeItem(at: temp) }

        let name = archive.lastPathComponent
        progress("Extracting \(name)…")
        let pw = (password?.isEmpty == false) ? password! : FixSource.defaultPassword
        // -bsp2 puts 7-Zip's progress on stdout and -bb1 its file names, which is
        // what lets the window show that it is still working.
        var args = ["x", "-y", "-bsp2", "-bb1", "-o\(temp.path)", "-p\(pw)", archive.path]
        var result = await extract(sevenZip: sevenZip, args: args, name: name, progress: progress)

        if result.timedOut {
            throw ManagerError("Extracting \(name) took longer than 15 minutes and was stopped. "
                + "If that archive is the whole game rather than a fix, unpack it by hand and "
                + "use “Choose archive…” on the extracted folder's files.")
        }

        if result.code != 0 {
            // Not encrypted after all? Try once without a password.
            args = ["x", "-y", "-bsp2", "-bb1", "-o\(temp.path)", archive.path]
            progress("Retrying \(name) without a password…")
            let second = await extract(sevenZip: sevenZip, args: args, name: name,
                                       progress: progress)
            if second.timedOut {
                throw ManagerError("Extracting \(name) took longer than 15 minutes and was stopped.")
            }
            if second.code == 0 {
                result = second
            } else {
                let detail = (result.err + result.out).lowercased()
                if detail.contains("password") || detail.contains("wrong") {
                    throw ManagerError("The archive password was rejected. The default is “\(FixSource.defaultPassword)”.")
                }
                throw ManagerError("Extraction failed: \((second.err + second.out).suffix(600))")
            }
        }

        progress("Installing the fix…")
        return try installExtracted(from: temp, game: game, allowGDK: allowGDK,
                                    allowNative: allowNative, progress: progress)
    }

    /// Runs 7-Zip and turns its progress output into messages for the window.
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

    // MARK: - From an extracted folder

    /// Two shapes are supported:
    ///  * Steamworks games: the package contains `steam_api64.dll`, which replaces the
    ///    copy the game actually loads.
    ///  * Everything else (GDK / Microsoft Store builds): the package is meant to be
    ///    unpacked into the game folder, so its contents are merged in.
    static func installExtracted(
        from root: URL,
        game: ManagedGame,
        allowGDK: Bool = false,
        allowNative: Bool = false,
        progress: (String) -> Void
    ) throws -> ImportResult {

        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            throw ManagerError("Could not find the installed game folder for \(game.name) (App \(game.id)). Install it in Steam first.")
        }
        if !allowNative, let bundle = nativeMacBundle(in: folder) {
            throw ManagerError("Steam installed the native macOS build of \(game.name) "
                + "(\(bundle.lastPathComponent)), and OnlineFix only patches Windows game files, "
                + "so there is nothing here for it to change. In Steam, open the game's Properties, "
                + "Compatibility, force the Windows version, and try again.")
        }
        return try installExtracted(from: root, into: folder, appID: game.id,
                                    allowGDK: allowGDK, allowNative: allowNative,
                                    progress: progress)
    }

    /// The same, into a game folder the caller already knows (the tests use one).
    static func installExtracted(
        from root: URL,
        into folder: URL,
        appID: Int? = nil,
        allowGDK: Bool = false,
        allowNative: Bool = false,
        progress: (String) -> Void
    ) throws -> ImportResult {

        progress("Inspecting the fix…")
        let extracted = try enumerateFiles(in: root).filter { $0.lastPathComponent != ".DS_Store" }
        guard !extracted.isEmpty else {
            throw ManagerError("The archive is empty.")
        }

        // The Microsoft Store (GDK) package needs the Xbox GDK runtime, which is not
        // part of Wine: its xsapi.dll stops the game at "Failed to load
        // xgameruntime.dll. Error code: 126". Its own self-protection also rejects a
        // rewritten Steam shape, so nothing of it can be used here.
        let archiveNames = Set(extracted.map { $0.lastPathComponent.lowercased() })
        let isGDK = archiveNames.contains("gdk_helper.bat")
            || archiveNames.contains("wdapp.exe")
            || archiveNames.contains("xsapi.dll")
        if isGDK, !allowGDK, !gdkRuntimeAvailable(in: folder, appID: appID) {
            throw ManagerError("This fix is the Microsoft Store (GDK) build: it needs the "
                + "Xbox GDK runtime (xgameruntime.dll), which only exists on Windows, and its "
                + "self-protection refuses a rewritten Steam version. Play the game as itself "
                + "without the fix.")
        }

        let apiDLLs = extracted.filter {
            let n = $0.lastPathComponent.lowercased()
            return n == "steam_api64.dll" || n == "steam_api.dll"
        }

        var written: [String] = []
        let basePath = root.standardizedFileURL.path

        if !apiDLLs.isEmpty {
            let existing = try findExistingAPIDLL(in: folder)
            let targetDir: URL
            if let existing {
                targetDir = existing.deletingLastPathComponent()
            } else if let win64 = findWin64Binaries(in: folder) {
                targetDir = win64
            } else {
                targetDir = folder
            }

            // Some fixes are laid out like the game folder itself
            // (`Engine/Binaries/.../steam_api64.dll`, `Ride/Binaries/Win64/OnlineFix64.dll`).
            // Those relative paths say where every file goes. Deciding per file
            // matters: requiring the whole archive to mirror the game folder meant
            // one stray file at its root (a readme, a second `.url`) sent everything
            // down the flat fallback below, which dropped OnlineFix64.dll and the
            // winmm.dll proxy, so the game could not load the patched Steam API DLL
            // while Steam still showed the fix installed.
            var mirrored: [(source: URL, folder: URL)] = []
            // Files outside the mirrored tree keep their archive path. A Photon fix
            // ships `winmm.dll`, `BepInEx/core/BepInEx.Preloader.dll` and
            // `Custom.dll` at its root, and Unity only loads that chain from beside
            // its executable: dropping them left a fix that looked installed while
            // OnlineFix's Photon patch never ran.
            var loose: [(source: URL, relative: String?)] = []
            for file in extracted {
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(basePath + "/") else { loose.append((file, nil)); continue }
                let relative = String(path.dropFirst(basePath.count + 1))
                if let parent = mirroredParent(for: relative, in: folder) {
                    mirrored.append((file, parent))
                } else {
                    loose.append((file, relative))
                }
            }

            if !mirrored.isEmpty {
                progress("Unpacking the fix into \(folder.lastPathComponent)…")
                for item in mirrored {
                    written.append(try place(item.source, into: item.folder))
                }
                // The archive is laid out like the game folder, so a loose file's own
                // path says where it goes. Everything at the archive root belongs at
                // the game root: OnlineFix's loader reads `dlllist.txt`, `OnlineFix.ini`
                // and `OnlineFix64.dll` from there, not from the Steam API DLL's folder.
                let wrapper = archiveWrapper(mirrored: mirrored, base: basePath, in: folder)
                for item in loose {
                    guard let relative = item.relative else {
                        if isFixPayload(item.source) {
                            written.append(try place(item.source, into: targetDir))
                        }
                        continue
                    }
                    written.append(try place(item.source,
                                             at: stripping(wrapper, from: relative),
                                             in: folder))
                }
                written.append(contentsOf: try installOverlayRenderer(
                    into: overlayFolder(written: written, fallback: targetDir),
                    appID: appID, progress: progress))
                disableOverlayStub(in: written)
                return ImportResult(files: written, targetDirectory: targetDir.path)
            }

            progress("Installing Steam API DLL(s)…")
            // A flat fix (no folders of its own) is laid out for the game's own
            // executable: the Steam API DLL goes where the game loads it from, and
            // everything else beside the executable, which is where Windows searches
            // for a DLL. Putting the whole set at the game folder's root left games
            // whose executable lives one level down — Buckshot Roulette keeps it in
            // "Buckshot Roulette_windows" — with a fix Windows never loads.
            let exeFolder = launchFolder(in: folder) ?? folder
            let apiFolder = apiDestination(near: exeFolder, fallback: targetDir)
            for file in extracted {
                let relative = archiveRelative(file, base: basePath)
                let name = file.lastPathComponent.lowercased()
                if name == "steam_api64.dll" || name == "steam_api.dll"
                    || name == "steam_api64.of" || name == "steam_api.of" {
                    written.append(try place(file, into: apiFolder))
                } else if PhotonFix.belongsAtGameRoot(relative) {
                    written.append(try place(file, at: relative, in: exeFolder))
                } else {
                    written.append(try place(file, into: exeFolder))
                }
            }
            written.append(contentsOf: try installOverlayRenderer(
                into: overlayFolder(written: written, fallback: exeFolder),
                appID: appID, progress: progress))
            disableOverlayStub(in: written)
            return ImportResult(files: written, targetDirectory: apiFolder.path)
        }

        // Whole-folder fix: merge the tree into the game folder, keeping originals.
        progress("Unpacking the fix into \(folder.lastPathComponent)…")
        for file in extracted {
            let relative = file.standardizedFileURL.path.replacingOccurrences(of: basePath + "/", with: "")
            guard !relative.isEmpty else { continue }
            let parent = (relative as NSString).deletingLastPathComponent
            let destinationFolder = parent.isEmpty ? folder : folder.appendingPathComponent(parent, isDirectory: true)
            if !Paths.fm.fileExists(atPath: destinationFolder.path) {
                try Paths.ensureDir(destinationFolder)
            }
            written.append(try place(file, into: destinationFolder))
        }
        disableOverlayStub(in: written)
        return ImportResult(files: written, targetDirectory: folder.path)
    }

    // MARK: - Helpers

    /// Executables a game ships beside its own but Steam never starts.
    private static let helperExecutables: Set<String> = [
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
                  !helperExecutables.contains(url.lastPathComponent.lowercased()),
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

    /// Where the game loads its Steam API DLL from. Unity installs it under
    /// `<Name>_Data/Plugins/<arch>`; other builds keep it beside the executable.
    private static func apiDestination(near exeFolder: URL, fallback: URL) -> URL {
        if let existing = try? findExistingAPIDLL(in: exeFolder) {
            return existing.deletingLastPathComponent()
        }
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: exeFolder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.lastPathComponent.lowercased().hasSuffix("_data") {
            for arch in ["x86_64", "x86"] {
                let plugins = entry.appendingPathComponent("Plugins/\(arch)", isDirectory: true)
                if Paths.fm.fileExists(atPath: plugins.path) { return plugins }
            }
        }
        if Paths.fm.fileExists(atPath: exeFolder.path) { return exeFolder }
        return fallback
    }

    /// The game folder an archive path belongs in, or nil when the path names no
    /// folder of this game. The archive is normally laid out like the game folder,
    /// so the file's own parent is the answer; some archives wrap everything in a
    /// folder named after the game, in which case dropping that first component
    /// finds the real one.
    private static func mirroredParent(for relative: String, in folder: URL) -> URL? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        let candidates = [Array(parts.dropLast()), Array(parts.dropLast().dropFirst())]
        for parts in candidates where !parts.isEmpty {
            let url = folder.appendingPathComponent(parts.joined(separator: "/"),
                                                    isDirectory: true)
            if Paths.fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Where the fix put SteamOverlay64.dll, so the renderer it loads goes beside it
    /// rather than in the Steam API DLL's folder.
    private static func overlayFolder(written: [String], fallback: URL) -> URL {
        for path in written where (path as NSString).lastPathComponent == "SteamOverlay64.dll" {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return fallback
    }

    /// Turns each placed SteamOverlay64.dll into one that does nothing at load, so
    /// its missing renderer cannot stop the game before it starts.
    private static func disableOverlayStub(in written: [String]) {
        for path in written where (path as NSString).lastPathComponent == "SteamOverlay64.dll" {
            OverlayStub.disable(at: URL(fileURLWithPath: path))
        }
    }

    /// What a fix archive ships around the Steam API DLL: the loader DLL, the
    /// overlay, and the small text files that configure them.
    private static func isFixPayload(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        return name == "onlinefix64.dll" || name == "onlinefix.dll"
            || name == "steamoverlay64.dll"
            || ["ini", "txt", "url"].contains(file.pathExtension.lowercased())
    }

    /// Copies a file into a folder, keeping a one-time backup of anything it replaces.
    ///
    /// The copy lands in a staging file first, so the game's own file stays in place
    /// until the fix's copy is whole. A full disk or a lost permission used to leave
    /// the game with neither its original nor the fix, which then would not start.
    private static func place(_ source: URL, into folder: URL) throws -> String {
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let staging = folder.appendingPathComponent(".\(source.lastPathComponent).onlinefix-new")
        try? Paths.fm.removeItem(at: staging)
        try Paths.fm.copyItem(at: source, to: staging)
        do {
            if Paths.fm.fileExists(atPath: destination.path) {
                let backup = destination.appendingPathExtension("onlinefix-backup")
                if !Paths.fm.fileExists(atPath: backup.path) {
                    try Paths.fm.copyItem(at: destination, to: backup)
                }
                try Paths.fm.removeItem(at: destination)
            }
            try Paths.fm.moveItem(at: staging, to: destination)
        } catch {
            try? Paths.fm.removeItem(at: staging)
            throw error
        }
        return destination.path
    }

    /// Copies a file to an archive-relative path under the game folder, creating the
    /// folders it needs. The BepInEx chain has to keep its tree (`core/`, `plugins/`).
    private static func place(_ source: URL, at relative: String, in folder: URL) throws -> String {
        let parent = (relative as NSString).deletingLastPathComponent
        let destinationFolder = parent.isEmpty
            ? folder
            : folder.appendingPathComponent(parent, isDirectory: true)
        if !Paths.fm.fileExists(atPath: destinationFolder.path) {
            try Paths.ensureDir(destinationFolder)
        }
        return try place(source, into: destinationFolder)
    }

    /// A file's path relative to the extracted archive's root.
    private static func archiveRelative(_ file: URL, base: String) -> String {
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return file.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    /// Some archives wrap everything in a folder named after the game. When a
    /// mirrored file only matched after its first component was dropped, that
    /// component is the wrapper and every loose file has it too.
    private static func archiveWrapper(mirrored: [(source: URL, folder: URL)],
                                       base: String, in folder: URL) -> String? {
        for item in mirrored {
            let parts = archiveRelative(item.source, base: base)
                .split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            let stripped = parts.dropFirst().joined(separator: "/")
            if Paths.fm.fileExists(atPath: folder.appendingPathComponent(stripped).path) {
                return parts[0]
            }
        }
        return nil
    }

    private static func stripping(_ wrapper: String?, from relative: String) -> String {
        guard let wrapper, relative.hasPrefix(wrapper + "/") else { return relative }
        return String(relative.dropFirst(wrapper.count + 1))
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
            let backup = file.appendingPathExtension("onlinefix-backup")
            if fm.fileExists(atPath: backup.path) {
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
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

    /// Drops the Steam overlay from an installed `dlllist.txt`.
    ///
    /// OnlineFix's overlay loader needs Steam's `GameOverlayRenderer64.dll` in the
    /// Wine prefix, and compatibility layers that manage that folder prune it on
    /// every launch. The loader then stops with error 126 before it reaches
    /// `Custom.dll`, so the Photon patch never runs. The overlay is cosmetic; the
    /// rest of the fix matters, so its line is taken out of the list.
    ///
    /// Returns true when the list was changed.
    @discardableResult
    static func removingOverlayFromDLLList(at path: String) -> Bool {
        let list = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: list, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("steamoverlay64.dll")
        }
        guard kept.count != lines.count else { return false }
        let backup = list.appendingPathExtension("onlinefix-backup")
        if !Paths.fm.fileExists(atPath: backup.path) {
            try? Paths.fm.copyItem(at: list, to: backup)
        }
        return (try? kept.joined(separator: "\n").data(using: .utf8)?.write(to: list, options: .atomic)) != nil
    }

    /// Steam's overlay loader (`SteamOverlay64.dll`) reads Steam's path from the
    /// Wine registry and loads `GameOverlayRenderer64.dll` from there. A Steam update
    /// or a prefix repair removes that copy, and the overlay then fails with error
    /// 126, which stops the loader before OnlineFix's Photon patch is reached.
    /// Puts it back in the game folder and in the prefix. Safe to call often.
    /// Puts the renderer beside the fix's own SteamOverlay64.dll (where the
    /// recorded path says it is), and in the Windows prefix. Called on refresh, so
    /// a prefix Steam made after the install still gets it.
    static func ensureOverlayRenderer(appID: Int, gameFolder: URL, fixFiles: [String]) {
        let recorded = fixFiles.first {
            ($0 as NSString).lastPathComponent == "SteamOverlay64.dll"
        }
        let folder = recorded.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? overlayFolder(under: gameFolder)
        guard let folder else { return }
        _ = try? installOverlayRenderer(into: folder, appID: appID, progress: { _ in })
    }

    /// The folder holding the overlay stub, when the record does not say.
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

    private static func installOverlayRenderer(into folder: URL, appID: Int?,
                                               progress: (String) -> Void) throws -> [String] {
        guard Paths.fm.fileExists(atPath: folder.appendingPathComponent("SteamOverlay64.dll").path),
              let source = steamOverlayRenderer() else { return [] }

        var written: [String] = []
        var announced = false
        // Only into the prefix's Steam folders: the stub asks Steam's registry entry
        // for them. A copy beside the game is what Windows would use, but in the
        // Wine prefix Steam's renderer started from the game folder takes that folder
        // for the Steam client and exits the process before the game initialises —
        // Godot and Unity then die with no log at all.
        for target in windowsPrefixDirectories(for: appID) {
            guard Paths.fm.fileExists(atPath: target.path) else { continue }
            let renderer = target.appendingPathComponent("GameOverlayRenderer64.dll")
            guard !Paths.fm.fileExists(atPath: renderer.path) else { continue }
            if !announced {
                progress("Installing the Steam overlay the OnlineFix overlay loads…")
                announced = true
            }
            written.append(try place(source, into: target))
        }
        return written
    }

    /// Where the game's Windows prefix keeps Steam: the overlay asks the registry
    /// for Steam's InstallPath and then loads the renderer from there.
    private static func windowsPrefixDirectories(for appID: Int?) -> [URL] {
        guard let appID else { return [] }
        let pfx = Paths.steamSupport
            .appendingPathComponent("steamapps/compatdata/\(appID)/pfx", isDirectory: true)
        guard Paths.fm.fileExists(atPath: pfx.path) else { return [] }
        return [
            pfx.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true),
            pfx.appendingPathComponent("drive_c/windows/system32", isDirectory: true),
        ]
    }

    /// The Windows overlay renderer Steam already ships for its legacy compat layer.
    private static func steamOverlayRenderer() -> URL? {
        let roots = [
            "/Applications/Steam.app/Contents/MacOS/legacycompat",
            Paths.steamSupport
                .appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/legacycompat")
                .path,
            Paths.home
                .appendingPathComponent("Library/Application Support/notproton/bridge/legacycompat")
                .path,
        ]
        for root in roots {
            let url = URL(fileURLWithPath: root)
                .appendingPathComponent("GameOverlayRenderer64.dll")
            if Paths.fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func findWin64Binaries(in folder: URL) -> URL? {
        let candidates = [
            folder.appendingPathComponent("Dungeons/Binaries/Win64", isDirectory: true),
            folder.appendingPathComponent("Binaries/Win64", isDirectory: true),
        ]
        for candidate in candidates where Paths.fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        if let enumerator = Paths.fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "Win64",
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                if let contents = try? Paths.fm.contentsOfDirectory(atPath: url.path),
                   contents.contains(where: { $0.lowercased().hasSuffix(".exe") }) {
                    return url
                }
            }
        }
        return nil
    }
}
