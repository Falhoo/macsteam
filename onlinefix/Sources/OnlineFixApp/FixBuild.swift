// The fix for one game, worked out on the spot from its package and its own folder.
//
// Nothing here is per game: the plan is copies, removals and edits, each of which
// follows from a finding. Applying it is `FixApply`'s job, and the result is packed
// in the game folder by `FixPack`.
import Foundation

struct FixPlan: Sendable {

    struct Copy: Sendable, Equatable {
        let source: URL
        let destination: URL
        /// Where the file ends up, from the game folder, for the pack.
        let relative: String
    }

    struct Removal: Sendable, Equatable {
        let path: URL
        let reason: String
    }

    /// A file the game already had, put back over the fix's copy of it.
    struct Restore: Sendable, Equatable {
        let source: URL
        let destination: URL
        let relative: String
    }

    struct Edit: Sendable, Equatable {
        enum Kind: String, Sendable {
            /// RealAppId and FakeAppId, when the ini has no such keys.
            case iniAppIDs
            /// PhotonIntegration=true, for a Photon game.
            case iniPhotonIntegration
            /// Name the payload and the Photon patch in dlllist.txt.
            case dllListEntries
            /// Drop the overlay from dlllist.txt.
            case dllListDropOverlay
        }
        let kind: Kind
        let path: URL
    }

    var copies: [Copy] = []
    var removals: [Removal] = []
    var restores: [Restore] = []
    /// True when the fix's loader is left out and the game keeps its own Steam API.
    var keepGameAPI = false
    var edits: [Edit] = []
    /// Copies of OnlineFix's overlay, made inert after they are placed.
    var stubOverlay: [URL] = []
    var wineDLLs: [String] = []
    var keepRealAppID = false
    var picoPark2 = false
    var photonSwap = false
    var notes: [String] = []

    var isEmpty: Bool {
        copies.isEmpty && removals.isEmpty && edits.isEmpty && restores.isEmpty
    }

    // MARK: - Building

    static func build(appID: Int, name: String, scan: GameScan, package: FixPackage?,
                      diagnosis: FixDiagnosis? = nil) -> FixPlan {
        var plan = FixPlan()

        // A Mac build loads none of the fix's files. What works there is the routing
        // and, for a game that needs it, the patch in its own files.
        if scan.macBundle != nil {
            plan.keepRealAppID = true
            if appID == 2644470 {
                plan.picoPark2 = true
                plan.notes.append("PICO PARK 2's Mac build takes its Photon patch in its own "
                    + "files: the Photon app id and the session limit.")
            } else {
                plan.notes.append("This is the Mac build, so no Windows files are copied. "
                    + "It starts as itself.")
            }
            return plan
        }

        guard let package else {
            plan.keepRealAppID = scan.usesSteamNetworking
            return plan
        }

        // Leftovers that stop a Godot or Unity game before main().
        for renderer in scan.strayOverlayRenderers {
            plan.removals.append(Removal(
                path: renderer,
                reason: "Steam takes the game folder for its own when its overlay renderer is in it"))
            plan.notes.append("Removed \(renderer.lastPathComponent) from the game folder.")
        }

        // A game whose fix loader does not start it keeps its own Steam API, and the
        // routing gives it the Spacewar identity instead. Copying the loader anyway
        // is what leaves it running with no window.
        let routingOnly = diagnosis?.findings.contains { $0.code == "OF061" } ?? false
        if routingOnly {
            plan.keepGameAPI = true
            plan.keepRealAppID = false
            if let original = scan.originalSteamAPI,
               let api = scan.loaderFiles["steam_api.dll"]
                    ?? scan.loaderFiles["steam_api64.dll"]
                    ?? scan.apiDLLs.first(where: { FixPackage.apiNames.contains($0.lastPathComponent.lowercased()) }) {
                plan.restores.append(Restore(source: original, destination: api,
                                             relative: relative(api, in: scan.folder)))
                plan.notes.append("Kept the game's own Steam API; macSteam's routing runs it "
                    + "as Spacewar, which is where the other copies meet.")
            }
            plan.notes.append("The fix's loader is left out: it did not start this game.")
            return plan
        }

        // The Steam API DLL, where the game loads it.
        let apiFolder = scan.apiFolder ?? scan.launchFolder
        if let api = package.apiItem(needs64: scan.is64Bit) {
            plan.copies.append(copy(api, to: apiFolder.appendingPathComponent(api.url.lastPathComponent),
                                    scan: scan))
        }

        // Everything the loader needs, and nothing of Steam's own DLL again. A tree
        // such as `BepInEx/core` keeps its shape: the preloader is only found there.
        for item in package.items where !FixPackage.apiNames.contains(item.name) {
            let destination: URL
            if FixPackage.isChainPath(item.relative) {
                destination = scan.launchFolder.appendingPathComponent(item.relative)
            } else {
                destination = destinationFolder(for: item, scan: scan)
                    .appendingPathComponent(item.url.lastPathComponent)
            }
            plan.copies.append(copy(item, to: destination, scan: scan))
        }

        // A stray copy at the game root is not where Windows looks.
        for leftover in scan.rootLoaderFiles {
            plan.removals.append(Removal(
                path: leftover,
                reason: "the game starts from \(scan.launchFolder.lastPathComponent)"))
            plan.notes.append("Removed the stray \(leftover.lastPathComponent) at the game root.")
        }

        // The ini and the loader's list are edited where they were placed.
        if let ini = placed("onlinefix.ini", in: plan) {
            plan.edits.append(Edit(kind: .iniAppIDs, path: ini))
            if scan.isPhoton { plan.edits.append(Edit(kind: .iniPhotonIntegration, path: ini)) }
        }
        if let list = placed("dlllist.txt", in: plan) {
            plan.edits.append(Edit(kind: .dllListEntries, path: list))
            if package.hasOverlay || !scan.overlayDLLs.isEmpty {
                plan.edits.append(Edit(kind: .dllListDropOverlay, path: list))
            }
        }
        if placed("onlinefix.ini", in: plan) == nil,
           let ini = existing("onlinefix.ini", in: scan) {
            // An ini left by an earlier attempt: fill it in rather than leave it empty.
            plan.edits.append(Edit(kind: .iniAppIDs, path: ini))
            if scan.isPhoton { plan.edits.append(Edit(kind: .iniPhotonIntegration, path: ini)) }
        }

        // The overlay OnlineFix ships cannot load its renderer; make it inert.
        for url in plan.copies.map(\.destination) where url.lastPathComponent.lowercased() == "steamoverlay64.dll" {
            plan.stubOverlay.append(url)
        }
        for url in scan.overlayDLLs where !plan.stubOverlay.contains(where: { $0.path == url.path }) {
            plan.stubOverlay.append(url)
        }

        // Every DLL the fix brought needs its native copy in the prefix, so Wine
        // cannot answer for the emulator with a copy of its own.
        var dlls = Set(package.items.map(\.name).filter { $0.hasSuffix(".dll") })
        dlls.insert("winmm.dll")
        plan.wineDLLs = dlls.sorted()

        plan.keepRealAppID = scan.usesSteamNetworking
        plan.photonSwap = scan.isPhoton && !plan.isEmpty
        if scan.isPhoton && !package.hasPhotonChain {
            plan.notes.append("This package has no Photon patch (Custom.dll and its BepInEx "
                + "preloader), so a Photon game may still answer CustomAuthenticationError.")
        }
        return plan
    }

    // MARK: - Where each file goes

    /// A package can be laid out like the game folder, so a file whose own parent
    /// exists under the game goes there; the loader's files go beside the executable.
    private static func destinationFolder(for item: FixPackage.Item, scan: GameScan) -> URL {
        if FixPackage.chainNames.contains(item.name) {
            return scan.launchFolder
        }
        if !item.parent.isEmpty {
            let mirrored = scan.folder.appendingPathComponent(item.parent, isDirectory: true)
            if isDirectory(mirrored) { return mirrored }
        }
        return scan.launchFolder
    }

    private static func copy(_ item: FixPackage.Item, to destination: URL,
                             scan: GameScan) -> Copy {
        Copy(source: item.url, destination: destination,
             relative: relative(destination, in: scan.folder))
    }

    /// The file the plan placed, matched the way Windows matches names.
    static func placed(_ name: String, in plan: FixPlan) -> URL? {
        plan.copies.map(\.destination)
            .first { $0.lastPathComponent.lowercased() == name.lowercased() }
    }

    static func existing(_ name: String, in scan: GameScan) -> URL? {
        scan.loaderFiles[name.lowercased()]
    }

    static func relative(_ url: URL, in folder: URL) -> String {
        let path = GameScan.canonical(url).path
        let base = GameScan.canonical(folder).path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1))
                                          : url.lastPathComponent
    }

    private static func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
    }
}
