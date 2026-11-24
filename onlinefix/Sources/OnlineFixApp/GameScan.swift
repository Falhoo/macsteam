// What a game folder says about itself, read before a fix is built for it.
//
// Every rule in `FixDiagnosis` reads this and nothing else, so a game is described
// once per pass: where Steam starts it from, which Steam API DLL it actually loads,
// what is already in place from an earlier attempt, which engine it is, and what it
// does online. Read only.
import Darwin
import Foundation

struct GameScan: Sendable {

    enum Engine: String, Sendable {
        case unityMono, unityIL2CPP, godot, unreal, other

        var name: String {
            switch self {
            case .unityMono: return "Unity (Mono)"
            case .unityIL2CPP: return "Unity (IL2CPP)"
            case .godot: return "Godot"
            case .unreal: return "Unreal"
            case .other: return "unknown engine"
            }
        }
    }

    /// The game's own Steam AppID, as the app knows it.
    let appID: Int
    let folder: URL
    /// The folder Steam starts the game from, which is where Windows looks for a DLL.
    let launchFolder: URL
    let exe: URL?
    let is64Bit: Bool
    /// Every Steam API DLL the game folder holds.
    let apiDLLs: [URL]
    /// The folder the game loads its Steam API DLL from.
    let apiFolder: URL?
    /// The loader files already in place, by lowercased name.
    let loaderFiles: [String: URL]
    let iniURL: URL?
    let dllListURL: URL?
    let overlayDLLs: [URL]
    /// Valve's renderer beside the game, where it breaks Godot and Unity.
    let strayOverlayRenderers: [URL]
    /// Loader files left at the game root while the game runs from a folder inside it.
    let rootLoaderFiles: [URL]
    let engine: Engine
    /// A .NET Framework game, which the fix's loader has more trouble with.
    let usesDotNet: Bool
    /// The game's own Steam API DLL, kept by the fix as `.of` or a backup.
    let originalSteamAPI: URL?
    let isPhoton: Bool
    /// Every module the game's native binaries import, lowercased. This is the list
    /// Windows resolves at load, so a doorway is in it only when the game really asks
    /// for that DLL.
    let importedDLLs: Set<String>
    let isIL2CPP: Bool
    let usesSteamNetworking: Bool
    let isGDK: Bool
    /// A real Microsoft Store manifest, which only a registered package has. The
    /// GDK runtime files alone are not one: Steam builds such as PEAK ship those too.
    let hasStoreManifest: Bool
    let hasAntiCheat: Bool
    let macBundle: URL?
    let prefix: URL?
    let iniText: String
    let dllListLines: [String]

    // MARK: - Markers

    /// Photon ships these managed assemblies.
    static let photonAssemblies: Set<String> = [
        "photonrealtime.dll", "photonunitynetworking.dll", "photon3unity3d.dll",
        "photonvoice.dll", "photonchat.dll",
    ]

    /// The Microsoft Store (GDK) runtime's files, which Wine cannot supply.
    static let gdkFiles: Set<String> = [
        "unity.microsoft.gdk.dll", "xgameruntime.dll", "gamingservices.dll",
        "gamingservicesnet.dll", "appxmanifest.xml", "gdk_helper.bat",
        "wdapp.exe", "xsapi.dll",
    ]

    /// Anti-cheat that OnlineFix and Wine cannot satisfy.
    static let antiCheatFiles: Set<String> = [
        "easyanticheat.exe", "easyanticheat_x64.dll", "easyanticheat.dll",
        "easyanticheat_eos.dll", "battleye.dll", "beservice.exe", "beclient.dll",
        "beclient_x64.dll",
    ]

    /// Files a fix installs, which are not evidence of anything about the game.
    static let fixNames: Set<String> = [
        "onlinefix64.dll", "onlinefix.dll", "onlinefix.ini", "onlinefix.url",
        "dlllist.txt", "winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll",
        "custom.dll", "custom.net", "steamoverlay64.dll", "gameoverlayrenderer64.dll",
    ]

    /// Deep enough for a game's executable and its plugins inside an engine tree.
    static let maxDepth = 6

    // MARK: - Reading

    static func read(folder input: URL, appID: Int, name: String) -> GameScan {
        // One spelling for every path: the enumerator hands back /private/var where
        // the caller passed /var, and two spellings of one file compare as two files.
        let folder = canonical(input)
        let launch = canonical(FixInstaller.launchFolder(in: folder) ?? folder)
        let executable = mainExecutable(in: launch)
        let files = markerFiles(in: folder)
        let apiDLLs = (try? FixInstaller.enumerateFiles(in: folder))?.filter {
            FixPackage.apiNames.contains($0.lastPathComponent.lowercased())
        } ?? []

        var loader: [String: URL] = [:]
        for url in loaderCandidates(in: folder, launch: launch, apiDLLs: apiDLLs)
        where loader[url.lastPathComponent.lowercased()] == nil {
            loader[url.lastPathComponent.lowercased()] = url
        }
        let is64Bit = executable.map(is64) ?? apiDLLs.contains {
            $0.lastPathComponent.lowercased() == "steam_api64.dll"
        }
        let engine = engine(in: folder, executable: executable, launch: launch)
        let imports = importedDLLs(in: folder, launch: launch, exe: executable)

        return GameScan(
            appID: appID,
            folder: folder,
            launchFolder: launch,
            exe: executable,
            is64Bit: is64Bit,
            apiDLLs: apiDLLs,
            apiFolder: apiFolder(in: folder, launch: launch, apiDLLs: apiDLLs,
                                 prefer64: is64Bit),
            loaderFiles: loader,
            iniURL: loader["onlinefix.ini"],
            dllListURL: loader["dlllist.txt"],
            overlayDLLs: loader["steamoverlay64.dll"].map { [$0] } ?? [],
            strayOverlayRenderers: renderers(in: folder, launch: launch),
            rootLoaderFiles: rootLeftovers(in: folder, launch: launch),
            engine: engine,
            usesDotNet: executable.map(usesDotNet) ?? false,
            originalSteamAPI: originalSteamAPI(in: folder, launch: launch, apiDLLs: apiDLLs),
            isPhoton: PhotonFix.isPhotonGame(in: folder),
            importedDLLs: imports,
            isIL2CPP: engine == .unityIL2CPP,
            usesSteamNetworking: SteamNetworking.uses(appID: appID, gameFolder: folder),
            isGDK: !files.isDisjoint(with: gdkFiles),
            hasStoreManifest: files.contains("appxmanifest.xml"),
            hasAntiCheat: !files.isDisjoint(with: antiCheatFiles),
            macBundle: FixInstaller.nativeMacBundle(in: folder),
            prefix: WineOverride.prefix(appID: appID),
            iniText: loader["onlinefix.ini"].flatMap(text) ?? "",
            dllListLines: loader["dlllist.txt"].map(lines) ?? []
        )
    }

    /// The one spelling of a path. Foundation hands back `/private/var/...` for the
    /// children of a folder the caller named `/var/...`, and a comparison that mixes
    /// the two sees two different files.
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return URL(fileURLWithPath: path)
    }

    /// True for a .NET Framework executable: it imports mscoree and names the
    /// runtime it was built for.
    static func usesDotNet(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? handle.close() }
        var read = 0
        while read < 8 * 1024 * 1024 {
            guard let chunk = (try? handle.read(upToCount: 2 * 1024 * 1024)) ?? nil,
                  !chunk.isEmpty else { break }
            read += chunk.count
            if chunk.range(of: Data("mscoree.dll".utf8)) != nil { return true }
            if chunk.range(of: Data("v4.0.30319".utf8)) != nil { return true }
        }
        return false
    }

    /// Every module the game's own native binaries import. Managed assemblies have
    /// no native import table, and fix files describe the fix rather than the game, so
    /// both are left out. A game wrapped in a folder of its own is walked from the
    /// launch folder, where the executable lives.
    static func importedDLLs(in folder: URL, launch: URL, exe: URL?) -> Set<String> {
        var files: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let canonical = canonical(url)
            guard seen.insert(canonical.path).inserted,
                  Paths.fm.fileExists(atPath: canonical.path) else { return }
            files.append(canonical)
        }
        if let exe { add(exe) }
        for name in ["UnityPlayer.dll", "GameAssembly.dll"] {
            add(launch.appendingPathComponent(name))
            add(folder.appendingPathComponent(name))
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
                if ["bepinex", "doorstop", "managed", ".macsteam-onlinefix"]
                    .contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard ["exe", "dll"].contains(url.pathExtension.lowercased()),
                      !FixPackage.loaderNames.contains(name),
                      !fixNames.contains(name),
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

    /// The game's own Steam API DLL, which a fix keeps beside the one it installs:
    /// `steam_api.dll.onlinefix-backup`, or an older OnlineFix's `steam_api.of`.
    /// The plugin folder counts too: a Unity fix can put its Steam API there, and the
    /// untouched copy stays beside it.
    static func originalSteamAPI(in folder: URL, launch: URL, apiDLLs: [URL] = []) -> URL? {
        var dirs: [URL] = [launch]
        dirs.append(contentsOf: apiDLLs.map { $0.deletingLastPathComponent() })
        dirs.append(folder)
        var seen = Set<String>()
        for dir in dirs where seen.insert(dir.path).inserted {
            let entries = (try? Paths.fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if let name = entries.first(where: {
                let lower = $0.lowercased()
                return lower == "steam_api.dll.onlinefix-backup"
                    || lower == "steam_api64.dll.onlinefix-backup"
            }) {
                return dir.appendingPathComponent(name)
            }
            if let name = entries.first(where: {
                let lower = $0.lowercased()
                return lower == "steam_api.of" || lower == "steam_api64.of"
            }) {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    private static func text(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func lines(_ url: URL) -> [String] {
        (text(url) ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every file the loader can be sitting in: the launch folder, the game root and
    /// the folder the game loads its Steam API DLL from.
    private static func loaderCandidates(in folder: URL, launch: URL,
                                        apiDLLs: [URL]) -> [URL] {
        var folders: [URL] = [launch, folder]
        folders.append(contentsOf: apiDLLs.map { $0.deletingLastPathComponent() })
        var found: [URL] = []
        var seen = Set<String>()
        for dir in folders where seen.insert(dir.path).inserted {
            let entries = (try? Paths.fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for entry in entries where FixPackage.loaderNames.contains(entry.lowercased()) {
                found.append(dir.appendingPathComponent(entry))
            }
        }
        return found
    }

    /// Valve's overlay renderer, when it is sitting beside the game rather than in
    /// the prefix's Steam folder. A copy there makes Steam take the game folder for
    /// the client, and Godot and Unity die before main().
    private static func renderers(in folder: URL, launch: URL) -> [URL] {
        var found: [URL] = []
        for dir in [launch, folder] {
            let entries = (try? Paths.fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for entry in entries where entry.lowercased() == "gameoverlayrenderer64.dll" {
                let url = dir.appendingPathComponent(entry)
                if !found.contains(where: { $0.path == url.path }) { found.append(url) }
            }
        }
        return found
    }

    /// Loader files at the game root when the game runs from a folder inside it: an
    /// earlier fix put them where Windows never looks.
    private static func rootLeftovers(in folder: URL, launch: URL) -> [URL] {
        guard folder.standardizedFileURL.path != launch.standardizedFileURL.path else { return [] }
        let entries = (try? Paths.fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries
            .filter { FixPackage.loaderNames.contains($0.lowercased()) }
            .map { folder.appendingPathComponent($0) }
    }

    /// The folder the game loads its Steam API DLL from: beside the exe when a copy
    /// is there, otherwise Unity's plugin folder, otherwise the exe's own folder.
    /// The shortest path is not the answer: a copy left at the game root is not the
    /// one a game running from a folder inside it loads.
    private static func apiFolder(in folder: URL, launch: URL, apiDLLs: [URL],
                                  prefer64: Bool) -> URL? {
        if let existing = bestAPI(apiDLLs, launch: launch, prefer64: prefer64) {
            return existing.deletingLastPathComponent()
        }
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: launch, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.lastPathComponent.lowercased().hasSuffix("_data") {
            for arch in ["x86_64", "x86"] {
                let plugins = entry.appendingPathComponent("Plugins/\(arch)", isDirectory: true)
                if Paths.fm.fileExists(atPath: plugins.path) { return plugins }
            }
        }
        // A build wrapped in a folder of its own keeps its data beside the exe one
        // level up from the game root.
        for entry in (try? Paths.fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let data = folder.appendingPathComponent(entry)
            guard entry.lowercased().hasSuffix("_data"),
                  let inner = try? Paths.fm.contentsOfDirectory(atPath: data.path) else { continue }
            for name in inner where name.lowercased() == "plugins" {
                for arch in ["x86_64", "x86"] {
                    let plugins = data.appendingPathComponent("Plugins/\(arch)")
                    if Paths.fm.fileExists(atPath: plugins.path) { return plugins }
                }
            }
        }
        return launch
    }

    /// The Steam API DLL the game is most likely to load: beside the exe first, then
    /// a Unity plugin folder, and the one matching the game's bitness on a tie.
    static func bestAPI(_ apiDLLs: [URL], launch: URL, prefer64: Bool) -> URL? {
        apiDLLs.max {
            score($0, launch: launch, prefer64: prefer64)
                < score($1, launch: launch, prefer64: prefer64)
        }
    }

    private static func score(_ url: URL, launch: URL, prefer64: Bool) -> Int {
        let lower = url.path.lowercased()
        var score = url.pathComponents.count
        if url.deletingLastPathComponent().path == launch.path { score += 32 }
        if lower.contains("/plugins/") { score += 16 }
        if lower.contains("_data/") { score += 4 }
        let preferred = prefer64 ? "steam_api64.dll" : "steam_api.dll"
        if url.lastPathComponent.lowercased() == preferred { score += 8 }
        return score
    }

    private static func mainExecutable(in launch: URL) -> URL? {
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: launch, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        let executables = entries.filter {
            $0.pathExtension.lowercased() == "exe"
                && !FixInstaller.helperExecutableNames.contains($0.lastPathComponent.lowercased())
        }
        return executables.max { one, other in
            let oneSize = (try? one.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let otherSize = (try? other.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return oneSize < otherSize
        }
    }

    /// True for a 64-bit PE: the machine field of its header.
    static func is64(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x40), head.count >= 0x40,
              head[0] == 0x4D, head[1] == 0x5A else { return true }
        let pe = Int(head[0x3C]) | Int(head[0x3D]) << 8 | Int(head[0x3E]) << 16 | Int(head[0x3F]) << 24
        guard pe > 0, (try? handle.seek(toOffset: UInt64(pe))) != nil,
              let header = try? handle.read(upToCount: 6), header.count == 6,
              header[0] == 0x50, header[1] == 0x45 else { return true }
        let machine = UInt16(header[4]) | UInt16(header[5]) << 8
        return machine == 0x8664 || machine == 0xAA64
    }

    private static func engine(in folder: URL, executable: URL?, launch: URL) -> Engine {
        if (try? FixInstaller.enumerateFiles(in: folder))?.contains(where: {
            $0.lastPathComponent.lowercased() == "global-metadata.dat"
                || $0.lastPathComponent.lowercased() == "gameassembly.dll"
                || $0.lastPathComponent.lowercased() == "gameassembly.dylib"
        }) == true { return .unityIL2CPP }
        if PhotonFix.managedFolders(in: folder).contains(where: {
            Paths.fm.fileExists(atPath: $0.path)
        }) { return .unityMono }
        if (try? Paths.fm.contentsOfDirectory(atPath: launch.path))?.contains(where: {
            $0.lowercased().hasSuffix(".pck")
        }) == true { return .godot }
        if Paths.fm.fileExists(atPath: folder.appendingPathComponent("Engine").path)
            || (executable?.lastPathComponent.lowercased().hasSuffix("-win64-shipping.exe") ?? false) {
            return .unreal
        }
        return .other
    }

    /// Names in the game folder that say what the game needs, at the depth a fix's
    /// files live at.
    private static func markerFiles(in folder: URL) -> Set<String> {
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var names: Set<String> = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard photonAssemblies.contains(name) || gdkFiles.contains(name)
                    || antiCheatFiles.contains(name) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.insert(name)
            }
        }
        return names
    }
}
