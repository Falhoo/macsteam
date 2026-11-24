// The BepInEx chain OnlineFix's Photon patch runs through, complete.
//
// OnlineFix's Photon patch is a BepInEx plugin (`Custom.dll`). BepInEx reaches it
// through a doorway DLL the game already imports: the doorway starts
// `BepInEx/core/BepInEx.Preloader.dll`, which loads `BepInEx.dll`, which chainloads
// everything in `BepInEx/plugins`. A game with only the plugin and the preloader, or
// with a doorway it never imports, looks fixed and does nothing.
//
// PEAK is the case that shows it: its `UnityPlayer.dll` imports WINHTTP.dll and no
// winmm at all, so OnlineFix's winmm doorway never ran, BepInEx never started, and
// the Photon patch was never applied. The game then connected to Photon with its own
// app id and Steam refused the ticket.
import Foundation

enum PhotonChain {

    /// The doorway DLLs a Unity game can import, in the order to try. The name is
    /// the file in the game folder; the needle is what the import table spells, in
    /// any case, so one search finds "WINHTTP.dll" and "winhttp.dll" both.
    static let doorways: [(file: String, needle: String)] = [
        ("winhttp.dll", "inhttp"),
        ("winmm.dll", "inmm"),
        ("version.dll", "ersion.dll"),
    ]

    /// Files every chain needs, from the game folder. `BepInEx.dll` is the one that
    /// loads plugins; without it the preloader starts and quits, which is what a
    /// package carrying only the preloader does.
    static let core = [
        "BepInEx/core/BepInEx.dll",
        "BepInEx/core/BepInEx.Preloader.dll",
        "BepInEx/core/0Harmony.dll",
        "BepInEx/core/0Harmony20.dll",
        "BepInEx/core/BepInEx.Harmony.dll",
        "BepInEx/core/HarmonyXInterop.dll",
        "BepInEx/core/Mono.Cecil.dll",
        "BepInEx/core/Mono.Cecil.Mdb.dll",
        "BepInEx/core/Mono.Cecil.Pdb.dll",
        "BepInEx/core/Mono.Cecil.Rocks.dll",
        "BepInEx/core/MonoMod.RuntimeDetour.dll",
        "BepInEx/core/MonoMod.Utils.dll",
    ]

    /// The OnlineFix Photon patch itself, where BepInEx looks for plugins.
    static let plugin = "BepInEx/plugins/Custom.dll"

    /// The chain's own configuration, which points the doorway at the preloader.
    static let config = "doorstop_config.ini"

    // MARK: - Where the bundle is

    /// The chain the app ships: `Resources/photon` in the app, or `vendor/photon`
    /// beside the sources when the manager runs from a build tree.
    static func bundle() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("photon", isDirectory: true))
        }
        // A command line run from a checkout has no Resources/photon; the sources'
        // own vendor folder is the same files. Both the directory the app runs from
        // and the working directory are checked: a test bundle's executable lives in
        // SwiftPM's helper, while its working directory is the package root.
        var starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                          isDirectory: true)]
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        starts.append(executable.deletingLastPathComponent())
        for start in starts {
            var directory = start
            for _ in 0..<8 {
                for relative in ["vendor/photon", "onlinefix/vendor/photon"] {
                    let candidate = directory.appendingPathComponent(relative, isDirectory: true)
                    if !candidates.contains(candidate) { candidates.append(candidate) }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return candidates.first { url in
            Paths.fm.fileExists(atPath: url.appendingPathComponent(config).path)
        }
    }

    // MARK: - What the game can load

    /// True when one of the game's own binaries imports this doorway.
    static func imports(_ doorway: String, in folder: URL, exe: URL?) -> Bool {
        importedModules(in: folder, exe: exe).contains(doorway.lowercased())
    }

    /// The doorway this game can actually load, or nil when it imports none of them.
    static func doorway(in folder: URL, exe: URL?) -> String? {
        let imported = importedModules(in: folder, exe: exe)
        return doorways.first { imported.contains($0.file) }?.file
    }

    /// Every module the executable and the engine binaries import. The canvas is the
    /// launch folder and its immediate engine/plugin folders: a game's own import
    /// table is there, while walking every asset would read files that can never
    /// import a DLL. The PE reader, not a byte search, decides.
    static func importedModules(in folder: URL, exe: URL?) -> Set<String> {
        var files: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let canonical = GameScan.canonical(url)
            guard seen.insert(canonical.path).inserted,
                  Paths.fm.fileExists(atPath: canonical.path) else { return }
            files.append(canonical)
        }
        if let exe { add(exe) }
        let launch = exe?.deletingLastPathComponent() ?? folder
        for base in [folder, launch] {
            for name in ["UnityPlayer.dll", "GameAssembly.dll"] {
                add(base.appendingPathComponent(name))
            }
        }
        if let enumerator = Paths.fm.enumerator(
            at: launch,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if enumerator.level > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent.lowercased()
                if ["bepinex", "doorstop", "managed", ".macsteam-onlinefix"].contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard ["exe", "dll"].contains(url.pathExtension.lowercased()),
                      !FixPackage.loaderNames.contains(name),
                      !GameScan.fixNames.contains(name),
                      name != "custom.dll", !name.hasPrefix("bepinex."),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                add(url)
            }
        }
        var imports = Set<String>()
        for file in files {
            if let pe = PortableExecutable.read(file) {
                if !pe.isManaged { imports.formUnion(pe.imports) }
            } else {
                imports.formUnion(PortableExecutable.fallbackImports(in: file))
            }
        }
        return imports
    }

    // MARK: - What is on disk

    /// The files the chain needs and the game folder does not have.
    static func missing(in folder: URL, doorway: String?) -> [String] {
        var wanted: [String] = [config] + core + [plugin]
        if let doorway { wanted.insert(doorway, at: 0) }
        return wanted.filter {
            !Paths.fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// True when the chain is complete and the game can load its doorway.
    static func isComplete(in folder: URL, doorway: String?) -> Bool {
        doorway != nil && missing(in: folder, doorway: doorway).isEmpty
    }

    // MARK: - Putting it there

    /// Copies the chain into the game folder, and says what it wrote. A doorway the
    /// game does not import is not copied: two doorways would start two preloaders.
    ///
    /// The doorway also needs the prefix's DLL override. Wine answers a game's import
    /// with its own built-in copy unless the prefix prefers the native one, so a
    /// doorway that is in the folder and not in the registry never loads.
    @discardableResult
    static func install(into folder: URL, from bundle: URL, doorway: String?, appID: Int? = nil,
                        progress: (@Sendable (String) -> Void)? = nil) throws -> [String] {
        guard let doorway else {
            throw ManagerError("This game imports none of the doorway DLLs a BepInEx chain "
                + "needs (winhttp.dll, winmm.dll, version.dll), so the Photon patch cannot "
                + "be loaded into it.")
        }
        var wanted: [String] = [config] + core + [plugin]
        wanted.insert(doorway, at: 0)

        var written: [String] = []
        for relative in wanted {
            let source = bundle.appendingPathComponent(relative)
            guard Paths.fm.fileExists(atPath: source.path) else { continue }
            let destination = folder.appendingPathComponent(relative)
            progress?("Adding \(relative)…")
            try FixApply.copyIntoPlace(source, at: destination)
            written.append(relative)
        }
        if let appID, WineOverride.prefix(appID: appID) != nil {
            let ok = WineOverride.ensure(appID: appID, dll: doorway,
                                        native: WineOverride.needsNative(doorway))
            progress?(ok ? "Told the prefix to load \(doorway) from the game folder."
                         : "The prefix would not take the \(doorway) override.")
        }
        return written
    }
}
