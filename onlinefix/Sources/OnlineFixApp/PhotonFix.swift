// OnlineFix's Photon support is a second, separate patch from its Steam API fix.
//
// It runs inside the game's managed runtime as a BepInEx plugin ("Custom.dll"),
// and only loads through a doorstop proxy ("winmm.dll") that starts
// "BepInEx.Preloader.dll" before Unity initialises. A fix whose files were only
// partly unpacked still looks installed while that chain never runs: the game then
// authenticates with OnlineFix's custom auth without the patch that makes Photon
// accept it, which is the "CustomAuthenticationError" players see.
//
// This checks every piece of the chain, so the app can say which one is missing
// instead of guessing from the game folder as a whole.
import Foundation

enum PhotonFix {

    /// One step of the chain that has to be on disk for the patch to run.
    struct Piece: Equatable, Sendable {
        let name: String
        /// Relative to the game folder; any one of them counts.
        let paths: [String]
        /// The file as the fix archive names it, for the message.
        let file: String
    }

    /// The chain, in the order Unity loads it.
    static let pieces: [Piece] = [
        Piece(name: "the BepInEx doorstop",
              paths: ["winmm.dll", "winhttp.dll", "version.dll"],
              file: "winmm.dll"),
        Piece(name: "the BepInEx preloader",
              paths: ["BepInEx/core/BepInEx.Preloader.dll"],
              file: "BepInEx/core/BepInEx.Preloader.dll"),
        Piece(name: "the Photon patch",
              paths: ["BepInEx/plugins/Custom.dll", "Custom.dll"],
              file: "Custom.dll"),
    ]

    /// Managed assemblies a Photon game ships next to its own code. Names differ by
    /// SDK version and by packaging: PUN's library is PhotonUnityNetworking.dll in
    /// one build and Photon.Realtime.dll in another, and the Quantum SDK brings
    /// Quantum.Core.dll. Any one of them is evidence of Photon, so the list is broad
    /// rather than tied to the games that have been tested.
    static let assemblies: Set<String> = [
        "photonrealtime.dll", "photonunitynetworking.dll", "photon3unity3d.dll",
        "photonvoice.dll", "photonchat.dll", "photon.dll", "photonwebsocket.dll",
        "photonquantum.dll", "quantum.core.dll", "quantumunity.dll",
        "exitgames.client.photon.dll", "exitgames.client.photon.realtime.dll",
        "exitgames.client.photon.chat.dll", "exitgames.client.photon.voicenetworking.dll",
        "photon.socket.server.dll",
    ]

    /// What an installed fix's Photon chain looks like on disk.
    struct Status: Sendable {
        var isPhoton = false
        var missing: [Piece] = []
        /// False when the game's Wine prefix still loads its own winmm.dll instead
        /// of the fix's loader.
        var loaderReady = true

        var isComplete: Bool { isPhoton && missing.isEmpty }
        var isIncomplete: Bool { isPhoton && !missing.isEmpty }
        var needsPrefixOverride: Bool { isPhoton && missing.isEmpty && !loaderReady }

        /// What is wrong, in words for the player, or nil when there is nothing to say.
        var message: String? {
            if !missing.isEmpty {
                let names = missing.map { "\($0.name) (\($0.file))" }.joined(separator: ", ")
                return "OnlineFix's Photon patch will not load: \(names) is missing from the game "
                    + "folder, so the game fails with CustomAuthenticationError. Reinstall the fix "
                    + "so the patch can run."
            }
            if needsPrefixOverride {
                return "OnlineFix's winmm.dll is in the game folder, but this game's Wine prefix "
                    + "loads its own winmm.dll instead, so the Photon patch never runs. Reopen "
                    + "macSteam to set the prefix up."
            }
            return nil
        }
    }

    /// The chain a recorded fix needs. A game with no fix, one whose online play is
    /// not Photon, or one whose fix ships no Photon patch at all (PEAK's GDK fix has
    /// only the Steam API side) has nothing to check.
    static func status(gameFolder: URL?, fixInstalled: Bool, appID: Int? = nil,
                       fixFiles: [String] = []) -> Status {
        guard fixInstalled, let gameFolder else { return Status() }
        // The chain sits beside the executable, which for a game in a subfolder is
        // below the folder Steam installed. Reading the install root would report a
        // complete chain as missing on every refresh.
        let folder = FixInstaller.launchFolder(in: gameFolder) ?? gameFolder
        let names = Set(fixFiles.map {
            ($0 as NSString).lastPathComponent.lowercased()
        })
        let rawNames = Set(fixFiles.map { $0.lowercased().replacingOccurrences(of: "\\", with: "/") })
        let rootCustom = exists(any: ["Custom.dll"], in: folder)
        let pluginCustom = exists(any: [PhotonChain.plugin], in: folder)
        let preloader = exists(any: ["BepInEx/core/BepInEx.Preloader.dll"], in: folder)
        let shipsChain = names.contains("custom.dll")
            || names.contains("bepinex.preloader.dll")
            || rawNames.contains(where: { $0.hasPrefix("bepinex/") })
            || rootCustom || pluginCustom || preloader
        guard shipsChain else { return Status() }

        var status = Status()
        status.isPhoton = true
        // A root Custom.dll is loaded directly by dlllist.txt through OnlineFix64.
        // Only a plugin or preloader layout needs BepInEx's doorstop and core.
        let chainLayout = preloader || pluginCustom
            || rawNames.contains(where: { $0.hasPrefix("bepinex/") })
            || names.contains("bepinex.preloader.dll")
        if chainLayout {
            for piece in pieces where !exists(any: piece.paths, in: folder) {
                status.missing.append(piece)
            }
            // A prefix Steam has not made yet has nothing to override; it is set the
            // first time the game is launched.
            if let appID, prefix(appID: appID) != nil {
                status.loaderReady = loaderOverrideInPlace(appID: appID)
            }
        } else if !rootCustom {
            status.missing.append(pieces[2])
        }
        return status
    }

    /// True when the game carries Photon assemblies.
    ///
    /// A Mono build names them in `*_Data/Managed`, which is cheap to look at. An
    /// IL2CPP build has no Managed folder: the names are string literals in the
    /// game's metadata and code instead, so those files are read (in chunks,
    /// stopping at the first hit). PICO PARK 2 is one of those.
    static func isPhotonGame(in folder: URL) -> Bool {
        cacheLock.lock()
        let cached = photonCache[folder.path]
        cacheLock.unlock()
        if let cached { return cached }
        var answer = false
        for managed in managedFolders(in: folder) {
            let names = (try? Paths.fm.contentsOfDirectory(atPath: managed.path)) ?? []
            if names.contains(where: { assemblies.contains($0.lowercased()) }) {
                answer = true
                break
            }
        }
        if !answer { answer = il2cppCarriesPhoton(in: folder) }
        if !answer { answer = settingsCarryPhoton(in: folder) }
        cacheLock.lock()
        photonCache[folder.path] = answer
        cacheLock.unlock()
        return answer
    }

    /// Drops one folder's cached answer after a fix put Photon assemblies in place.
    /// Without this, a game first seen before its fix stays "not Photon" for the rest
    /// of the run, and the Photon patch is never offered.
    static func forget(folder: URL) {
        cacheLock.lock()
        photonCache[folder.path] = nil
        photonCache[GameScan.canonical(folder).path] = nil
        cacheLock.unlock()
    }

    /// The answer per folder, so a big game's metadata is read once per run rather
    /// than once per fix on every refresh.
    private static let cacheLock = NSLock()
    private static var photonCache: [String: Bool] = [:]

    /// Assembly names as an IL2CPP build keeps them: string literals in the
    /// metadata, not a folder of .dll files.
    static let il2cppMarkers: [String] = [
        "PhotonRealtime", "Photon3Unity3D", "PhotonUnityNetworking", "PhotonQuantum",
        "PhotonVoice",
    ]

    /// How much of a game's code is read before giving up on finding Photon.
    static let il2cppReadLimit = 512 * 1024 * 1024
    /// One chunk at a time, so a large binary is never held in memory.
    static let il2cppChunk = 4 * 1024 * 1024

    /// A Unity build serializes its Photon settings into an assets file. When the
    /// managed assemblies are stripped or renamed, that class name is the remaining
    /// evidence that the game speaks Photon, so it is read before giving up.
    private static func settingsCarryPhoton(in folder: URL) -> Bool {
        let markers = [Data("PhotonServerSettings".utf8), Data("PhotonAppSettings".utf8),
                       Data("PhotonNetwork".utf8)]
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if enumerator.level > 8 {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name == "bepinex" || name == "doorstop" || name == ".macsteam-onlinefix" {
                enumerator.skipDescendants()
                continue
            }
            guard name.hasSuffix(".assets") || name == "globalgamemanagers" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size <= PhotonPatch.maxFileSize else { continue }
            if carries(markers, in: url, limit: size, overlap: 32) { return true }
        }
        return false
    }

    private static func il2cppCarriesPhoton(in folder: URL) -> Bool {
        let wanted = il2cppMarkers.map { Data($0.utf8) }
        for file in il2cppFiles(in: folder) {
            if carries(wanted, in: file, limit: il2cppReadLimit, overlap: 16) { return true }
        }
        return false
    }

    /// Reads one file for any of the byte markers, keeping enough of the previous
    /// chunk that a marker on a boundary still matches. The handle is closed at the
    /// end of this call, not when the folder walk finishes.
    private static func carries(_ markers: [Data], in url: URL, limit: Int,
                                overlap: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var read = 0
        var carry = Data()
        while read < limit {
            guard let chunk = (try? handle.read(upToCount: 4 * 1024 * 1024)) ?? nil,
                  !chunk.isEmpty else { break }
            read += chunk.count
            var window = carry
            window.append(chunk)
            if markers.contains(where: { window.range(of: $0) != nil }) { return true }
            carry = window.suffix(overlap)
        }
        return false
    }

    /// The files an IL2CPP build keeps its assembly names in, smallest first: the
    /// metadata answers for most games without the game's code file being read.
    private static func il2cppFiles(in folder: URL) -> [URL] {
        var small: [URL] = []
        var large: [URL] = []
        let relatives = ["il2cpp_data/Metadata/global-metadata.dat",
                         "globalgamemanagers", "globalgamemanagers.assets",
                         "resources.assets", "data.unity3d"]
        for entry in directories(in: folder) {
            // A Mac build keeps the same files inside its `.app`: the data under
            // `Contents/Resources/Data`, the code under `Contents/Frameworks`.
            if entry.pathExtension.lowercased() == "app" {
                let data = entry.appendingPathComponent("Contents/Resources/Data")
                for relative in relatives {
                    let url = data.appendingPathComponent(relative)
                    if Paths.fm.fileExists(atPath: url.path) { small.append(url) }
                }
                let dylib = entry.appendingPathComponent("Contents/Frameworks/GameAssembly.dylib")
                if Paths.fm.fileExists(atPath: dylib.path) { large.append(dylib) }
                continue
            }
            if !entry.lastPathComponent.lowercased().hasSuffix("_data") {
                // A build that wraps everything in a folder of the game's own name.
                let nested = il2cppFiles(in: entry)
                small.append(contentsOf: nested.filter { !$0.lastPathComponent.hasPrefix("GameAssembly") })
                large.append(contentsOf: nested.filter { $0.lastPathComponent.hasPrefix("GameAssembly") })
                continue
            }
            for relative in relatives {
                let url = entry.appendingPathComponent(relative)
                if Paths.fm.fileExists(atPath: url.path) { small.append(url) }
            }
            let code = entry.deletingLastPathComponent()
                .appendingPathComponent("GameAssembly.dll")
            if Paths.fm.fileExists(atPath: code.path) { large.append(code) }
        }
        return small + large
    }

    /// Every `Managed` folder in the game, wherever the engine put it. A wrapped
    /// build keeps it two folders down, an Unreal or custom layout can keep it under
    /// `Engine/Binaries`, and a Mac bundle keeps it inside `.app/Contents/Resources`.
    /// The walk stops at BepInEx, which has its own managed folder that says nothing
    /// about the game.
    static func managedFolders(in folder: URL) -> [URL] {
        var found: [URL] = []
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return found }
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name == "bepinex" || name == "doorstop" {
                enumerator.skipDescendants()
                continue
            }
            guard isDirectory(url) else { continue }
            if name == "managed" { found.append(url) }
        }
        // A Mac bundle is a package; `.skipsPackageDescendants` would hide its Data
        // folder, so the known build layout is added explicitly.
        for app in directories(in: folder) where app.pathExtension.lowercased() == "app" {
            for relative in ["Contents/Resources/Data/Managed",
                             "Contents/Resources/Data/il2cpp_data/Metadata"] {
                let candidate = app.appendingPathComponent(relative, isDirectory: true)
                if isDirectory(candidate), !found.contains(candidate) { found.append(candidate) }
            }
        }
        return found
    }

    /// True when the file at this archive-relative path belongs at the game's own
    /// root rather than beside the Steam API DLL. Unity loads the doorstop from
    /// beside its executable, and BepInEx keeps its tree there.
    static func belongsAtGameRoot(_ relative: String) -> Bool {
        let lower = relative.lowercased().replacingOccurrences(of: "\\", with: "/")
        if lower.hasPrefix("bepinex/") || lower.hasPrefix("doorstop/") { return true }
        return ["winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll",
                "custom.dll", "doorstop_config.ini"].contains(lower)
    }

    // MARK: - Wine prefix

    /// Steam's Wine prefix for a game, or nil before its first launch.
    static func prefix(appID: Int) -> URL? {
        WineOverride.prefix(appID: appID)
    }

    /// True when the prefix is already set to load the fix's `winmm.dll`.
    static func loaderOverrideInPlace(appID: Int) -> Bool {
        WineOverride.has(appID: appID, dll: "winmm.dll")
    }

    /// Adds the DLL override the fix's loader needs, and reports whether it is in
    /// place afterwards. Only meaningful once Steam has made the game's prefix.
    @discardableResult
    static func ensureLoaderOverride(appID: Int) -> Bool {
        WineOverride.ensure(appID: appID, dll: "winmm.dll")
    }

    // MARK: - Helpers

    private static func dataFolder(_ url: URL) -> URL? {
        guard url.lastPathComponent.lowercased().hasSuffix("_data") else { return nil }
        let managed = url.appendingPathComponent("Managed", isDirectory: true)
        return isDirectory(managed) ? managed : nil
    }

    private static func directories(in folder: URL) -> [URL] {
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter(isDirectory)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
    }

    private static func exists(any paths: [String], in folder: URL) -> Bool {
        paths.contains { Paths.fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}
