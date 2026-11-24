// One fix archive, read before anything is put into a game.
//
// The same OnlineFix package can be laid out in several ways: a flat set of files
// for the game's own folder, a tree that mirrors the game (`Engine/Binaries/...`),
// or a whole-folder build. What every package shares is a small set of roles: the
// Steam API DLL a game loads, the payload and proxies that start it, the ini that
// says which game it is, the list of what to load, the overlay, and sometimes the
// BepInEx chain OnlineFix's Photon patch runs through. This reads the roles and
// leaves the deciding to `FixDiagnosis` and `FixPlan`.
import Foundation

struct FixPackage: Sendable {

    struct Item: Sendable, Equatable {
        let url: URL
        /// The file's path from the archive's root, with "/" between folders.
        let relative: String
        var name: String { (relative as NSString).lastPathComponent.lowercased() }
        var parent: String {
            let parent = (relative as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }
    }

    let root: URL
    let archiveName: String
    let items: [Item]
    let ini: String
    let dllList: [String]

    // MARK: - Names

    /// What a game loads from beside its executable: the payload, the proxies it
    /// starts through, the overlay, and the small files that configure them.
    static let loaderNames: Set<String> = [
        "onlinefix64.dll", "onlinefix.dll", "winmm.dll", "winhttp.dll", "version.dll",
        "dinput8.dll", "steamoverlay64.dll", "onlinefix.ini", "onlinefix.url", "dlllist.txt",
    ]

    /// The OnlineFix payload itself, as opposed to the doorstop and its helpers.
    static let payloadNames: Set<String> = ["onlinefix64.dll", "onlinefix.dll"]

    /// Steam's own API DLL, under the names a fix replaces it by.
    static let apiNames: Set<String> = ["steam_api64.dll", "steam_api.dll"]

    /// The BepInEx chain OnlineFix's Photon patch runs through.
    static let chainNames: Set<String> = ["custom.dll", "winmm.dll", "doorstop_config.ini"]

    /// Files only the Microsoft Store (GDK) build of a fix ships.
    static let gdkNames: Set<String> = [
        "gdk_helper.bat", "wdapp.exe", "xsapi.dll", "xgameruntime.dll",
    ]

    static func isChainPath(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        return lower.hasPrefix("bepinex/") || lower.hasPrefix("doorstop/")
    }

    // MARK: - Reading

    static func read(root input: URL, archiveName: String = "") -> FixPackage {
        // One spelling for the root and its files: the enumerator can hand back
        // /private/var where the caller passed /var, and the prefix test then fails.
        let root = GameScan.canonical(input)
        let files = (try? FixInstaller.enumerateFiles(in: root)) ?? []
        var items: [Item] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let url = GameScan.canonical(file)
            let path = url.path
            let base = root.path
            let relative = path.hasPrefix(base + "/")
                ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            guard !relative.isEmpty, !isJunk(relative) else { continue }
            items.append(Item(url: url, relative: relative))
        }
        let iniItem = items.first { $0.name == "onlinefix.ini" }
        let listItem = items.first { $0.name == "dlllist.txt" }
        return FixPackage(
            root: root,
            archiveName: archiveName.isEmpty ? root.lastPathComponent : archiveName,
            items: items,
            ini: iniItem.flatMap { text(at: $0.url) } ?? "",
            dllList: listItem.map { lines(of: $0.url) } ?? []
        )
    }

    /// Files a Mac archive picks up on the way to Windows and the fix never needs.
    /// `__MACOSX` and `._name` are AppleDouble resource forks, not game files.
    static func isJunk(_ relative: String) -> Bool {
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return true }
        if components.contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") }) {
            return true
        }
        let name = components.last!.lowercased()
        return name == ".ds_store" || name == "thumbs.db" || name == "desktop.ini"
    }

    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func lines(of url: URL) -> [String] {
        guard let text = text(at: url) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Roles

    var names: Set<String> { Set(items.map(\.name)) }

    func items(named name: String) -> [Item] {
        items.filter { $0.name == name.lowercased() }
    }

    func item(named name: String) -> Item? { items(named: name).first }

    /// The fix's own copy of the Steam API DLL, for the bitness the game runs at.
    func apiItem(needs64: Bool) -> Item? {
        let wanted = needs64 ? "steam_api64.dll" : "steam_api.dll"
        return item(named: wanted)
    }

    var apiItems: [Item] { items.filter { FixPackage.apiNames.contains($0.name) } }

    var payloadItems: [Item] { items.filter { FixPackage.payloadNames.contains($0.name) } }

    var carriesPayload: Bool { !payloadItems.isEmpty }

    var hasOverlay: Bool { item(named: "steamoverlay64.dll") != nil }

    /// The doorstop, the preloader and the plugin: what makes a Photon game's patch
    /// run inside the game.
    var chainItems: [Item] {
        items.filter {
            FixPackage.chainNames.contains($0.name) || FixPackage.isChainPath($0.relative)
        }
    }

    /// True when the package brings the whole OnlineFix Photon patch, not just its
    /// doorstop: BepInEx's preloader and `Custom.dll`.
    var hasPhotonChain: Bool {
        chainItems.contains { $0.name == "custom.dll" }
            && chainItems.contains { $0.name == "bepinex.preloader.dll" }
    }

    /// A fix built for the Microsoft Store (GDK) version of a game.
    var isGDK: Bool {
        !names.isDisjoint(with: FixPackage.gdkNames)
            || iniValues["productid"] != nil
    }

    /// A package that installs by registering an Appx manifest with GDK_Helper.
    /// Copying its files into a Steam install cannot register it, and the game stays
    /// a Steam copy to the services it talks to.
    var requiresGDKRegistration: Bool {
        isGDK && (item(named: "gdk_helper.bat") != nil || item(named: "wdapp.exe") != nil)
    }

    /// The hashes OnlineFix's loader checks against the game's own files. They are
    /// made for the build the fix was packaged from, so a game Steam has updated
    /// since does not match them.
    var hashes: [String] {
        var found: [String] = []
        var inSection = false
        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[hashes]"
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 64 { found.append(value.lowercased()) }
        }
        return found
    }

    /// The ini's values by lowercased key, so the package's game can be compared with
    /// the game it is being installed into.
    var iniValues: [String: String] {
        var values: [String: String] = [:]
        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    /// The ini keys and sections the package brought, lowercased.
    var iniKeys: Set<String> {
        var keys: Set<String> = []
        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            keys.insert(line[..<equals].trimmingCharacters(in: .whitespaces).lowercased())
        }
        return keys
    }

    func relativePath(for destination: URL, in gameFolder: URL) -> String {
        let path = destination.standardizedFileURL.path
        let base = gameFolder.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1))
                                          : destination.lastPathComponent
    }
}
