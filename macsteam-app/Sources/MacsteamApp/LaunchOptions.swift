// Launch options Steam on macOS cannot run.
//
// NotProton writes a graphics backend as a `NAME=value` prefix before
// `%command%`, e.g. `CX_GRAPHICS_BACKEND=dxvk %command%`. Only the compat tool
// understands that prefix. When the game goes back to a native launch (tool
// unset), Steam's macOS client tries to exec the whole string as the
// executable and the launch stops with "Failed to start process for this game:
// OS error 260". Those prefixes are what a native launch keeps; removing them
// restores the plain `%command%` launch.
import Foundation

enum LaunchOptions {

    /// The app's launch options when they carry Windows-only prefixes and no
    /// compat tool is set for it. Nil when there is nothing to fix.
    static func stale(appID: Int) -> String? {
        guard let options = current(appID: appID), hasPrefixAssignments(options) else { return nil }
        guard !isMappedToCompatTool(appID: appID) else { return nil }
        return options
    }

    /// `NAME=value` words before `%command%` are not Steam's on macOS: it does
    /// not run a shell, so nothing expands them.
    static func hasPrefixAssignments(_ options: String) -> Bool {
        for token in tokens(options) {
            if token == "%command%" { return false }
            if isAssignment(token) { return true }
        }
        return false
    }

    /// Drops the prefix assignments, keeping `%command%` and everything after it,
    /// which are the game's own arguments.
    static func stripped(_ options: String) -> String {
        var words = tokens(options)
        while let first = words.first, isAssignment(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    // MARK: - Every game at once

    /// Every app whose launch options carry a Windows-only prefix while no compat
    /// tool is mapped for it: each of those cannot start natively.
    static func staleApps() -> [Int] {
        var ids = Set<Int>()
        for file in configFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for id in staleAppIDs(in: text) where !isMappedToCompatTool(appID: id) {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    /// The apps in one file's text that carry such a prefix.
    static func staleAppIDs(in text: String) -> [Int] {
        appBlocks(in: text).compactMap { block in
            guard let options = quotedValue("LaunchOptions", in: String(text[block.range])),
                  hasPrefixAssignments(options) else { return nil }
            return block.appID
        }
    }

    /// That text with these apps' launch options cleared.
    static func cleared(_ appIDs: [Int], in text: String) -> String {
        let wanted = Set(appIDs)
        var result = text
        // Back to front, so clearing one value cannot move a block still to do.
        for block in appBlocks(in: result).reversed() where wanted.contains(block.appID) {
            let body = result[block.range]
            guard let key = body.range(of: "\"LaunchOptions\""),
                  let open = body[key.upperBound...].firstIndex(of: "\""),
                  let close = body[body.index(after: open)...].firstIndex(of: "\"")
            else { continue }
            let value = String(body[body.index(after: open)..<close])
            let clean = stripped(value)
            guard clean != value else { continue }
            result.replaceSubrange(body.index(after: open)..<close, with: clean)
        }
        return result
    }

    /// Writes the cleared options into Steam's own file, and reports the apps
    /// changed. Steam must not be running: the client writes its own copy of this
    /// file when it quits, which would put the prefixes back.
    @discardableResult
    static func clear(_ appIDs: [Int]) -> [Int] {
        guard !appIDs.isEmpty else { return [] }
        let wanted = Set(appIDs)
        var done = Set<Int>()
        for file in configFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let updated = cleared(appIDs, in: text)
            guard updated != text else { continue }
            guard (try? updated.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
            done.formUnion(staleAppIDs(in: text).filter { wanted.contains($0) })
        }
        return done.sorted()
    }

    // MARK: - Steam's files

    private static var userdata: URL {
        Paths.steamRoot.appendingPathComponent("userdata", isDirectory: true)
    }

    private static func configFiles() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: userdata,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("config/localconfig.vdf") }
    }

    /// The LaunchOptions Steam has stored for this app.
    static func current(appID: Int) -> String? {
        for file in configFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let block = appBlock(in: text, appID: appID),
                  let value = quotedValue("LaunchOptions", in: block) else { continue }
            return value
        }
        return nil
    }

    /// Whether Steam is set to start the app through a compatibility tool. While
    /// it is, the prefix belongs to that tool and is left alone.
    static func isMappedToCompatTool(appID: Int) -> Bool {
        let config = Paths.steamRoot.appendingPathComponent("config/config.vdf")
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let mapping = block(named: "CompatToolMapping", in: text) else { return false }
        return appBlock(in: mapping, appID: appID) != nil
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (name.first?.isLetter ?? false)
    }

    /// Space-separated, honouring single and double quotes well enough for a
    /// launch option line.
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

    // MARK: - Text VDF

    private static func quotedValue(_ key: String, in block: String) -> String? {
        guard let range = block.range(of: "\"\(key)\"") else { return nil }
        let rest = block[range.upperBound...]
        guard let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(rest[rest.index(after: open)..<close])
    }

    private static func appBlock(in text: String, appID: Int) -> String? {
        block(named: "\(appID)", in: text)
    }

    /// One `"<appid>" { ... }` of the file, with where it sits in the text.
    struct AppBlock {
        let appID: Int
        let range: Range<String.Index>
    }

    /// Every `"<appid>" { ... }` the text holds, in the order it holds them. Keys
    /// that are not a number are skipped, so only app sections come back.
    static func appBlocks(in text: String) -> [AppBlock] {
        var out: [AppBlock] = []
        var index = text.startIndex
        while let quote = text[index...].firstIndex(of: "\"") {
            guard let close = text[text.index(after: quote)...].firstIndex(of: "\"") else { break }
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

    /// The `{ ... }` that follows a quoted key, brace-matched.
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
