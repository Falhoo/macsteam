import Foundation

/// Whether a recorded fix is still in the game folder.
///
/// Steam re-downloads, verifies and repairs games by putting the game's own files
/// back, which silently removes an installed fix while the record of it stays
/// behind. A record alone is therefore not proof that a game is fixed.
enum FixState: Equatable, Sendable {
    /// Every file the fix wrote is still there.
    case installed
    /// Recorded files that are no longer on disk, so the game runs without the fix.
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
        let missing = fix.files.filter { !FileManager.default.fileExists(atPath: $0) }
        return missing.isEmpty ? .installed : .missing(missing)
    }

    /// True only when every file the fix wrote is still in the game folder.
    static func isInstalled(_ fix: FixRecord) -> Bool {
        state(of: fix) == .installed
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
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ImportResult {
        try await install(archive: archive, game: game,
                          password: FixSource.defaultPassword, progress: progress)
    }

    static func install(
        archive: URL,
        game: ManagedGame,
        password: String?,
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
        return try installExtracted(from: temp, game: game, progress: progress)
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
        progress: (String) -> Void
    ) throws -> ImportResult {

        guard let folder = Store.gameFolder(for: game.id, name: game.name) else {
            throw ManagerError("Could not find the installed game folder for \(game.name) (App \(game.id)). Install it in Steam first.")
        }
        if let bundle = nativeMacBundle(in: folder) {
            throw ManagerError("Steam installed the native macOS build of \(game.name) "
                + "(\(bundle.lastPathComponent)), and OnlineFix only patches Windows game files, "
                + "so there is nothing here for it to change. In Steam, open the game's Properties, "
                + "Compatibility, force the Windows version, and try again.")
        }
        return try installExtracted(from: root, into: folder, appID: game.id, progress: progress)
    }

    /// The same, into a game folder the caller already knows (the tests use one).
    static func installExtracted(
        from root: URL,
        into folder: URL,
        appID: Int? = nil,
        progress: (String) -> Void
    ) throws -> ImportResult {

        progress("Inspecting the fix…")
        let extracted = try enumerateFiles(in: root).filter { $0.lastPathComponent != ".DS_Store" }
        guard !extracted.isEmpty else {
            throw ManagerError("The archive is empty.")
        }

        let apiDLLs = extracted.filter {
            let n = $0.lastPathComponent.lowercased()
            return n == "steam_api64.dll" || n == "steam_api.dll"
        }

        var written: [String] = []

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

            progress("Installing Steam API DLL(s) into \(targetDir.lastPathComponent)…")
            // Every file that ships beside the Steam API DLL belongs to the fix.
            // OnlineFix's steam_api64.dll imports OnlineFix64.dll and
            // SteamOverlay64.dll; installing only the API DLL leaves the game
            // unable to load it (status c0000135) while Steam still shows it running.
            let apiDirs = Set(apiDLLs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
            var siblings = extracted.filter {
                apiDirs.contains($0.deletingLastPathComponent().standardizedFileURL.path)
            }
            siblings += extracted.filter {
                !siblings.contains($0) && ["ini", "txt"].contains($0.pathExtension.lowercased())
            }
            for file in siblings {
                written.append(try place(file, into: targetDir))
            }
            written.append(contentsOf: try installOverlayRenderer(into: targetDir, appID: appID,
                                                                  progress: progress))
            return ImportResult(files: written, targetDirectory: targetDir.path)
        }

        // Whole-folder fix: merge the tree into the game folder, keeping originals.
        progress("Unpacking the fix into \(folder.lastPathComponent)…")
        let basePath = root.standardizedFileURL.path
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
        return ImportResult(files: written, targetDirectory: folder.path)
    }

    // MARK: - Helpers

    /// Copies a file into a folder, keeping a one-time backup of anything it replaces.
    private static func place(_ source: URL, into folder: URL) throws -> String {
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if Paths.fm.fileExists(atPath: destination.path) {
            let backup = destination.appendingPathExtension("onlinefix-backup")
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: destination, to: backup)
            }
            try Paths.fm.removeItem(at: destination)
        }
        try Paths.fm.copyItem(at: source, to: destination)
        return destination.path
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
    private static func installOverlayRenderer(into folder: URL, appID: Int?,
                                               progress: (String) -> Void) throws -> [String] {
        guard Paths.fm.fileExists(atPath: folder.appendingPathComponent("SteamOverlay64.dll").path),
              let source = steamOverlayRenderer() else { return [] }

        var written: [String] = []
        var announced = false
        for target in [folder] + windowsPrefixDirectories(for: appID) {
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
