// Wine's own DLLs win over the ones a game ships.
//
// OnlineFix (and BepInEx) work by putting a proxy DLL beside a game: `winmm.dll`
// starts the loader, `winhttp.dll` / `version.dll` / `dinput8.dll` do the same for
// other engines. Wine only loads those files when the game's prefix says the native
// one comes first, which is what this writes into the prefix's registry. Without it
// the fix installs, the game starts, and nothing the fix added ever runs.
import Foundation

enum WineOverride {

    /// Proxies OnlineFix and BepInEx ship. Naming one that the game has no local
    /// copy of is harmless: Wine falls back to its own, which is why these are
    /// overridden as `native,builtin`.
    static let proxies = ["winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll"]

    /// DLLs an OnlineFix brings that have to come from the game folder itself.
    ///
    /// `OnlineFix64.dll` is the emulator. The loader asks it for its interface and,
    /// when Wine resolves the name to something else, stops with "Failed to get
    /// OnlineFix interface" before the game starts. Forcing these to the native
    /// copy is the fix the CrossOver community uses for exactly that error (MECCHA
    /// CHAMELEON and others), so every fixed game gets it here.
    static let emulators = ["onlinefix64.dll", "onlinefix.dll", "steamoverlay64.dll",
                            "dnet.dll", "steam_api64.dll", "steam_api.dll"]

    /// Every DLL name a fix can need an override for.
    static var fixDLLs: [String] { proxies + emulators }

    /// A fix DLL needs the native copy and nothing to fall back to, or Wine can
    /// still answer with one of its own. Only the proxies keep a builtin fallback,
    /// for the games that ship none.
    static func needsNative(_ dll: String) -> Bool {
        !proxies.contains(dll.lowercased())
    }

    /// Steam's Wine prefix for a game, or nil before its first launch.
    static func prefix(appID: Int) -> URL? {
        let pfx = Paths.compatData
            .appendingPathComponent("\(appID)", isDirectory: true)
            .appendingPathComponent("pfx", isDirectory: true)
        return Paths.fm.fileExists(atPath: pfx.path) ? pfx : nil
    }

    /// Wine's registry keys for this prefix, exactly as it writes them.
    static var section: String {
        let bs = String(repeating: "\\", count: 2)
        return "[Software\(bs)Wine\(bs)DllOverrides]"
    }

    /// `"winmm"="native,builtin"`: prefer the file the game ships, fall back to
    /// Wine's own when a game has none. The fix's own DLLs are plain `native`.
    static func key(for dll: String, native: Bool = false) -> String {
        native ? "\"\(dll)\"=\"native\"" : "\"\(dll)\"=\"native,builtin\""
    }

    /// True when the prefix already asks for this DLL's native copy.
    static func has(appID: Int, dll: String) -> Bool {
        guard let reg = userReg(appID: appID),
              let text = try? String(contentsOf: reg, encoding: .isoLatin1) else { return false }
        return line(for: dll, in: text) != nil
    }

    /// Adds the override and reports whether it is in place afterwards. Only
    /// meaningful once Steam has made the game's prefix.
    @discardableResult
    static func ensure(appID: Int, dll: String, native: Bool = false) -> Bool {
        guard let reg = userReg(appID: appID) else { return false }
        // A `native,builtin` line already counts for a fix DLL: native is tried
        // first, and a fix DLL is present, so the builtin fallback never wins.
        if has(appID: appID, dll: dll) { return true }
        guard var text = try? String(contentsOf: reg, encoding: .isoLatin1) else { return false }
        text = adding(dll: dll, to: text, native: native)
        do {
            let data = text.data(using: .isoLatin1) ?? Data(text.utf8)
            try data.write(to: reg, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The override line already in the prefix, in any spelling Wine accepts.
    static func line(for dll: String, in text: String) -> String? {
        let name = dll.lowercased()
        let bare = (name as NSString).deletingPathExtension
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.hasPrefix(section)
                continue
            }
            guard inSection else { continue }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("\"\(name)\"=") || lower.hasPrefix("\"\(bare)\"=") {
                return trimmed
            }
        }
        return nil
    }

    /// The same registry text with the override added to its section, creating the
    /// section when the prefix has none.
    static func adding(dll: String, to text: String, native: Bool = false) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(section)
        }) {
            var insertAt = index + 1
            if insertAt < lines.count,
               lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("#time=") {
                insertAt += 1
            }
            lines.insert(key(for: dll, native: native), at: insertAt)
            return lines.joined(separator: "\n")
        }
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(section)
        lines.append(key(for: dll, native: native))
        return lines.joined(separator: "\n")
    }

    private static func userReg(appID: Int) -> URL? {
        prefix(appID: appID)?.appendingPathComponent("user.reg")
    }

    // MARK: - Removal

    /// The same registry text without any of the overrides a fix needed, and the DLL
    /// names whose lines went. Every other key in the prefix is left as it is.
    static func clearing(_ text: String) -> (text: String, removed: [String]) {
        var result = text
        var removed: [String] = []
        for dll in fixDLLs {
            while let found = line(for: dll, in: result) {
                let next = removing(line: found, from: result)
                // A line that does not come out would loop forever, so stop instead.
                guard next != result else { break }
                result = next
                if !removed.contains(dll) { removed.append(dll) }
            }
        }
        return (result, removed)
    }

    /// The text with one exact registry line gone.
    static func removing(line target: String, from text: String) -> String {
        let wanted = target.trimmingCharacters(in: .whitespaces)
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == wanted }) {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    /// Takes this game's OnlineFix overrides out of its prefix, and reports the DLLs
    /// whose line went. Only the lines this wrote are touched.
    @discardableResult
    static func clear(appID: Int) -> [String] {
        guard let reg = userReg(appID: appID),
              let text = try? String(contentsOf: reg, encoding: .isoLatin1) else { return [] }
        let cleared = clearing(text)
        guard !cleared.removed.isEmpty else { return [] }
        let data = cleared.text.data(using: .isoLatin1) ?? Data(cleared.text.utf8)
        return (try? data.write(to: reg, options: .atomic)) != nil ? cleared.removed : []
    }
}
