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

    /// Managed assemblies a Photon game ships next to its own code.
    static let assemblies: Set<String> = [
        "photonrealtime.dll", "photonunitynetworking.dll", "photon3unity3d.dll",
        "photonvoice.dll", "photonchat.dll",
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
        guard fixInstalled, let folder = gameFolder, isPhotonGame(in: folder) else {
            return Status()
        }
        let names = Set(fixFiles.map {
            ($0 as NSString).lastPathComponent.lowercased()
        })
        let shipsChain = names.contains("custom.dll")
            || names.contains("bepinex.preloader.dll")
            || exists(any: ["BepInEx/core/BepInEx.Preloader.dll", "Custom.dll"], in: folder)
        guard shipsChain else { return Status() }
        var status = Status()
        status.isPhoton = true
        for piece in pieces where !exists(any: piece.paths, in: folder) {
            status.missing.append(piece)
        }
        // A prefix Steam has not made yet has nothing to override; it is set the
        // first time the game is launched.
        if let appID, prefix(appID: appID) != nil {
            status.loaderReady = loaderOverrideInPlace(appID: appID)
        }
        return status
    }

    /// True when the game's managed assemblies include Photon.
    ///
    /// Only the `*_Data/Managed` folders are read: Unity names its assemblies there,
    /// and walking a whole game folder (hundreds of megabytes of assets) for every
    /// row of the list would be pointless.
    static func isPhotonGame(in folder: URL) -> Bool {
        for managed in managedFolders(in: folder) {
            let names = (try? Paths.fm.contentsOfDirectory(atPath: managed.path)) ?? []
            if names.contains(where: { assemblies.contains($0.lowercased()) }) { return true }
        }
        return false
    }

    /// `*_Data/Managed`, one level deep: a build wrapped in a folder of the game's
    /// own name keeps it at two.
    static func managedFolders(in folder: URL) -> [URL] {
        var found: [URL] = []
        for entry in directories(in: folder) {
            if let managed = dataFolder(entry) { found.append(managed) }
            for child in directories(in: entry) {
                if let managed = dataFolder(child) { found.append(managed) }
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
