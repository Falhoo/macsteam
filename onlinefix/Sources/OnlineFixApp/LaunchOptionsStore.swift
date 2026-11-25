// The launch options are a second place the fix has to be consistent.
//
// The prefix registry only carries the DLL preference while nothing else sets
// WINEDLLOVERRIDES. NotProton exports its own value, so the same names also belong
// on the app's launch options, where Steam stores them in localconfig.vdf. The
// running app writes those through Steam's UI; this is the fallback for the command
// line and for a Steam UI that refuses the call.
import Foundation

enum LaunchOptionsStore {

    /// Adds the fix's DLL names to the app's launch options. Returns true when a
    /// Steam config was found and already carries them or now does.
    @discardableResult
    static func apply(appID: Int, assignments: [String], steamRoot: URL = Paths.steamSupport) -> Bool {
        guard !assignments.isEmpty else { return true }
        var found = false
        for file in configFiles(in: steamRoot) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            found = true
            let current = current(appID: appID, in: text) ?? "%command%"
            let updated = mergingEnvironment("WINEDLLOVERRIDES", entries: assignments,
                                              into: current)
            guard updated != current else { continue }
            let next = setting(updated, appID: appID, in: text)
            guard next != text else { continue }
            try? next.write(to: file, atomically: true, encoding: .utf8)
        }
        return found
    }

    /// Whether every name the fix needs is already in the app's launch options.
    static func has(appID: Int, assignments: [String], steamRoot: URL = Paths.steamSupport) -> Bool {
        guard !assignments.isEmpty else { return true }
        for file in configFiles(in: steamRoot) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let options = current(appID: appID, in: text) else { continue }
            let value = tokens(options).first { $0.hasPrefix("WINEDLLOVERRIDES=") }
            guard let value else { continue }
            let entries = environmentEntries(String(value.dropFirst("WINEDLLOVERRIDES=".count)))
            let names = Set(entries.map { $0.0.lowercased() })
            let wanted = Set(assignments.map { environmentEntry($0).0.lowercased() })
            if wanted.isSubset(of: names) { return true }
        }
        return false
    }

    /// Takes these names back out when the fix is removed, leaving any other
    /// overrides the player had on the same line.
    @discardableResult
    static func clear(appID: Int, assignments: [String], steamRoot: URL = Paths.steamSupport) -> Bool {
        guard !assignments.isEmpty else { return true }
        var found = false
        for file in configFiles(in: steamRoot) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let current = current(appID: appID, in: text) else { continue }
            found = true
            let updated = clearingEnvironment("WINEDLLOVERRIDES", entries: assignments,
                                               from: current)
            guard updated != current else { continue }
            let next = setting(updated, appID: appID, in: text)
            guard next != text else { continue }
            try? next.write(to: file, atomically: true, encoding: .utf8)
        }
        return found
    }

    // MARK: - One compatibility variable

    /// Adds or updates `NAME=value` before `%command%`, keeping the rest of the
    /// line. `WINEDLLOVERRIDES` itself is a semicolon list: entries here win over
    /// the same names already there, and names this does not mention stay.
    static func mergingEnvironment(_ name: String, entries: [String],
                                   into options: String) -> String {
        var words = tokens(options)
        let prefix = "\(name)="
        var list: [(String, String)] = []
        if let index = words.firstIndex(where: { $0.hasPrefix(prefix) }) {
            list = environmentEntries(String(words[index].dropFirst(prefix.count)))
            words.remove(at: index)
        }
        for entry in entries {
            let pair = environmentEntry(entry)
            guard !pair.0.isEmpty else { continue }
            if let index = list.firstIndex(where: {
                $0.0.caseInsensitiveCompare(pair.0) == .orderedSame
            }) {
                list[index].1 = pair.1
            } else {
                list.append(pair)
            }
        }
        let value = list.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
        if !value.isEmpty {
            let command = words.firstIndex(of: "%command%") ?? words.count
            words.insert("\(prefix)\(value)", at: command)
        }
        if !words.contains("%command%") { words.append("%command%") }
        return words.joined(separator: " ")
    }

    static func clearingEnvironment(_ name: String, entries: [String],
                                    from options: String) -> String {
        var words = tokens(options)
        let prefix = "\(name)="
        guard let index = words.firstIndex(where: { $0.hasPrefix(prefix) }) else {
            return options
        }
        let drop = Set(entries.map { environmentEntry($0).0.lowercased() })
        var list = environmentEntries(String(words[index].dropFirst(prefix.count)))
        list.removeAll { drop.contains($0.0.lowercased()) }
        if list.isEmpty {
            words.remove(at: index)
        } else {
            words[index] = prefix + list.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
        }
        return words.joined(separator: " ")
    }

    private static func environmentEntry(_ text: String) -> (String, String) {
        guard let equals = text.firstIndex(of: "=") else { return (text, "n,b") }
        return (String(text[..<equals]), String(text[text.index(after: equals)...]))
    }

    private static func environmentEntries(_ value: String) -> [(String, String)] {
        value.split(separator: ";").compactMap { part in
            let entry = String(part)
            guard !entry.isEmpty else { return nil }
            return environmentEntry(entry)
        }
    }

    // MARK: - Steam's file

    private static func configFiles(in steamRoot: URL) -> [URL] {
        let userdata = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        let dirs = (try? Paths.fm.contentsOfDirectory(at: userdata,
                                                       includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("config/localconfig.vdf") }
    }

    static func current(appID: Int, in text: String) -> String? {
        guard let block = appBlock(in: text, appID: appID) else { return nil }
        return quotedValue("LaunchOptions", in: block)
    }

    static func setting(_ options: String, appID: Int, in text: String) -> String {
        guard let block = appBlocks(in: text).first(where: { $0.appID == appID }) else {
            return text
        }
        let body = text[block.range]
        let escaped = options
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var result = text
        if let key = body.range(of: "\"LaunchOptions\""),
           let open = body[key.upperBound...].firstIndex(of: "\""),
           let close = body[body.index(after: open)...].firstIndex(of: "\"") {
            result.replaceSubrange(body.index(after: open)..<close, with: escaped)
            return result
        }
        guard let brace = body.firstIndex(of: "{") else { return text }
        let insertion = "\n\t\t\t\t\"LaunchOptions\"\t\t\"\(escaped)\""
        result.insert(contentsOf: insertion, at: text.index(after: brace))
        return result
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[..<equals]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (name.first?.isLetter ?? false)
    }

    private static func tokens(_ options: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in options {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func quotedValue(_ key: String, in block: String) -> String? {
        guard let range = block.range(of: "\"\(key)\"") else { return nil }
        let rest = block[range.upperBound...]
        guard let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else {
            return nil
        }
        return String(rest[rest.index(after: open)..<close])
    }

    private static func appBlock(in text: String, appID: Int) -> String? {
        block(named: "\(appID)", in: text)
    }

    struct AppBlock {
        let appID: Int
        let range: Range<String.Index>
    }

    static func appBlocks(in text: String) -> [AppBlock] {
        var out: [AppBlock] = []
        var index = text.startIndex
        while let quote = text[index...].firstIndex(of: "\"") {
            guard let close = text[text.index(after: quote)...].firstIndex(of: "\"") else {
                break
            }
            let key = text[text.index(after: quote)..<close]
            var after = text.index(after: close)
            while after < text.endIndex, text[after].isWhitespace {
                after = text.index(after: after)
            }
            if !key.isEmpty, key.allSatisfy(\.isNumber), after < text.endIndex,
               text[after] == "{", let end = matchingBrace(in: text, from: after),
               let appID = Int(key) {
                out.append(AppBlock(appID: appID,
                                    range: after..<text.index(after: end)))
            }
            index = text.index(after: close)
        }
        return out
    }

    private static func block(named key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        guard let open = text[range.upperBound...].firstIndex(of: "{"),
              let close = matchingBrace(in: text, from: open) else { return nil }
        return String(text[open...close])
    }

    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }
}
