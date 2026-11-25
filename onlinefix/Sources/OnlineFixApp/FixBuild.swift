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
            /// RealAppId and FakeAppId, filling missing keys and correcting wrong ones.
            case iniAppIDs
            /// PhotonIntegration=true, for a Photon game.
            case iniPhotonIntegration
            /// Name the payload, the overlay and a root Photon patch in dlllist.txt.
            case dllListEntries
            /// Drop the overlay from dlllist.txt.
            case dllListDropOverlay
            /// Put the real AppID back in steam_appid.txt.
            case steamAppID
        }
        let kind: Kind
        let path: URL
        /// Names to add, for a dlllist.txt edit. Empty means the plan's copies.
        var names: [String] = []
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

        // A steam_appid.txt left by another game overrides the AppID Steam passes
        // on, so OnlineFix authenticates as that game and the real one refuses the
        // session. 480 is Spacewar and is left as the routing writes it.
        if let file = scan.steamAppIDFile, let id = scan.steamAppID,
           id != appID, id != 480 {
            plan.edits.append(Edit(kind: .steamAppID, path: file))
            plan.notes.append("steam_appid.txt is put back to \(appID).")
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
            if let original = scan.originalSteamAPI {
                // The backup carries the fix's suffix; the game wants the name back
                // exactly as it loads it, in the folder it loads it from.
                let name = original.lastPathComponent
                let lower = name.lowercased()
                let base: String
                if lower.hasSuffix(".onlinefix-backup") {
                    base = String(name.dropLast(".onlinefix-backup".count))
                } else if lower == "steam_api.of" {
                    base = "steam_api.dll"
                } else if lower == "steam_api64.of" {
                    base = "steam_api64.dll"
                } else {
                    base = name
                }
                // Put it back where the untouched copy was kept: that is the folder
                // whose DLL the game was loading when the fix replaced it.
                let folder = original.deletingLastPathComponent()
                let api = folder.appendingPathComponent(base)
                plan.restores.append(Restore(source: original, destination: api,
                                             relative: relative(api, in: scan.folder)))
                plan.notes.append("Kept the game's own Steam API; macSteam's routing runs it "
                    + "as Spacewar, which is where the other copies meet.")
            } else {
                plan.notes.append("No untouched Steam API was found; the game's current "
                    + "copy is left as it is.")
            }
            plan.notes.append("The fix's loader is left out: it did not start this game.")
            return plan
        }

        // The Steam API DLL, where the game loads it.
        let apiFolder = scan.apiFolder ?? scan.launchFolder
        if let api = package.apiItem(needs64: scan.is64Bit), fits(api, scan: scan) {
            plan.copies.append(copy(api, to: apiFolder.appendingPathComponent(api.url.lastPathComponent),
                                    scan: scan))
        }

        // Everything the loader needs, and nothing of Steam's own DLL again. A tree
        // such as `BepInEx/core` keeps its shape: the preloader is only found there.
        for item in package.items where !FixPackage.apiNames.contains(item.name)
            && fits(item, scan: scan) {
            let destination: URL
            if FixPackage.isChainPath(item.relative) {
                destination = scan.launchFolder.appendingPathComponent(item.relative)
            } else {
                destination = destinationFolder(for: item, scan: scan)
                    .appendingPathComponent(item.url.lastPathComponent)
            }
            plan.copies.append(copy(item, to: destination, scan: scan))
        }

        // A package that carries Custom.dll or says PhotonIntegration is a Photon fix
        // even when the game's own assemblies are stripped, renamed or hidden in
        // IL2CPP metadata. The package is evidence in its own right.
        let packageSaysPhoton = package.iniValues["photonintegration"]?.lowercased() == "true"
            || package.items.contains { $0.name == "custom.dll" }
        let photonWanted = scan.isPhoton || packageSaysPhoton

        // A Photon package can ship the plugin and no chain, or a doorway the game
        // never imports. The app carries the whole chain, so fill what the package
        // left out: the doorway the game actually loads, BepInEx's core and the
        // plugin where BepInEx looks for it.
        // A GDK fix installs by registering a Microsoft Store package, not by loading
        // a BepInEx chain into a Steam copy. PEAK's fix is one, and adding the chain
        // to it puts files in the game that the fix never asked for.
        // A root Custom.dll is loaded by dlllist.txt through OnlineFix64, not through
        // BepInEx. Adding the chain to that layout loads the patch twice and puts
        // BepInEx in a game that never needed it.
        let rootCustomOnly = !package.hasPhotonChain && package.items.contains {
            $0.name == "custom.dll" && $0.parent.isEmpty
        }
        let addedVendorChain = photonWanted && !package.requiresGDKRegistration
            && !rootCustomOnly
            ? addVendorChain(to: &plan, scan: scan, package: package) : false

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
            if photonWanted { plan.edits.append(Edit(kind: .iniPhotonIntegration, path: ini)) }
        }
        if let list = placed("dlllist.txt", in: plan) {
            plan.edits.append(Edit(kind: .dllListEntries, path: list))
        }
        if placed("onlinefix.ini", in: plan) == nil,
           let ini = existing("onlinefix.ini", in: scan) {
            // An ini left by an earlier attempt: fill it in rather than leave it empty.
            plan.edits.append(Edit(kind: .iniAppIDs, path: ini))
            if photonWanted { plan.edits.append(Edit(kind: .iniPhotonIntegration, path: ini)) }
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
        let dlls = Set(package.items.map(\.name).filter { $0.hasSuffix(".dll") }
            + plan.wineDLLs)
        plan.wineDLLs = dlls.sorted()

        plan.keepRealAppID = scan.usesSteamNetworking
        plan.photonSwap = photonWanted && !plan.isEmpty
        if photonWanted && !package.hasPhotonChain && !addedVendorChain {
            plan.notes.append("This package has no Photon patch (Custom.dll and its BepInEx "
                + "preloader), and none was added, so a Photon game may still answer "
                + "CustomAuthenticationError.")
        }
        return plan
    }

    /// Adds the Photon chain the app ships where the package's own chain cannot run.
    /// A package that already has a complete chain is left alone; only its doorway is
    /// added when the game imports a different one.
    @discardableResult
    private static func addVendorChain(to plan: inout FixPlan, scan: GameScan,
                                       package: FixPackage) -> Bool {
        guard let doorway = PhotonChain.doorway(in: scan.folder, exe: scan.exe) else {
            plan.notes.append("This game imports none of the BepInEx doorways (winhttp.dll, "
                + "winmm.dll, version.dll), so its Photon patch cannot be loaded into it.")
            return false
        }
        guard let bundle = PhotonChain.bundle() else {
            plan.notes.append("The Photon chain is not bundled with this build, so the package's "
                + "own doorway is left as it is.")
            return false
        }
        let provided = Set(plan.copies.map { $0.relative.lowercased() })
        let wanted: [String]
        if package.hasPhotonChain {
            wanted = plan.copies.contains {
                $0.relative.lowercased() == doorway.lowercased()
            } ? [] : [doorway]
        } else {
            wanted = PhotonChain.missing(in: scan.folder, doorway: doorway)
        }
        var added: [String] = []
        for relative in wanted where !provided.contains(relative.lowercased()) {
            let source = bundle.appendingPathComponent(relative)
            guard Paths.fm.fileExists(atPath: source.path) else { continue }
            let destination = scan.launchFolder.appendingPathComponent(relative)
            plan.copies.append(Copy(source: source, destination: destination,
                                    relative: FixPlan.relative(destination, in: scan.folder)))
            added.append(relative)
        }
        guard !added.isEmpty else { return false }
        plan.wineDLLs = Array(Set(plan.wineDLLs + [doorway])).sorted()
        let carriesPlugin = added.contains(PhotonChain.plugin)
        if carriesPlugin {
            plan.notes.append("Added the bundled Photon chain the package left out: "
                + "\(doorway), BepInEx's core and Custom.dll.")
        } else {
            plan.notes.append("Added \(doorway) from the bundled Photon chain, the doorway "
                + "this game actually imports.")
        }
        return true
    }

    // MARK: - Where each file goes

    /// A package can be laid out like the game folder, so a file whose own parent
    /// exists under the game goes there; the loader's files go beside the executable.
    private static func destinationFolder(for item: FixPackage.Item, scan: GameScan) -> URL {
        // The loader is started by a DLL the executable imports, so it has to sit
        // beside the executable. A package that mirrors the game tree already does.
        if FixPackage.chainNames.contains(item.name)
            || FixPackage.loaderNames.contains(item.name) {
            return scan.launchFolder
        }
        if !item.parent.isEmpty {
            let mirrored = scan.folder.appendingPathComponent(item.parent, isDirectory: true)
            if isDirectory(mirrored) { return mirrored }
        }
        return scan.launchFolder
    }

    /// A native payload or proxy has to match the game's build. Managed assemblies
    /// and ordinary files are left to the plan, which has no bitness to impose.
    /// A wrong build is refused here so the install does not write a DLL the game
    /// can never load and then only report it afterward.
    private static func fits(_ item: FixPackage.Item, scan: GameScan) -> Bool {
        // Any native DLL in the package is loaded into the game process, so it
        // has to match the game's build. A wrong-bitness doorway or BepInEx
        // preloader is the same load failure as a wrong-bitness payload.
        guard let pe = PortableExecutable.read(item.url), !pe.isManaged else {
            return true
        }
        return scan.is64Bit ? pe.is64BitNative : pe.is32BitNative
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
