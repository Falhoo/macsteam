// Making the game test its own online connection, so the player does not have to.
//
// Whether Photon accepts a patched game depends on the app id, the auth type and the
// region together, and nothing on disk records what Photon said last time. Reading it
// by pressing the game's menus needs to know where each game keeps its Play button.
//
// So the game is asked instead. `MacsteamAutopilot.dll` is loaded from the fix's
// dlllist and boots a small managed payload inside the game's own runtime, which calls
// Photon's own client and writes down the answer. This type owns the three files that
// arrangement needs and reads the answer back.
//
// Only Mono builds can be driven this way: an IL2CPP or native Mac build has no
// runtime to load an assembly into, and keeps the old "open the lobby yourself" path.
import Foundation

enum Autopilot {

    /// The shim, named verbatim in the fix's `dlllist.txt`.
    static let dll = "MacsteamAutopilot.dll"
    /// Beside the game: written before the launch, removed after it, because a game
    /// that connects itself outside a test should be left alone.
    static let flag = "macsteam-autopilot.on"
    /// What the run answered, line by line.
    static let log = "macsteam-autopilot.log"
    /// Set once a game has been through a run, so later attempts skip the long wait
    /// for shaders and the game's own loading.
    static let warm = "macsteam-autopilot.warm"

    /// Everything a run leaves behind, for undo.
    static var owned: [String] { [dll, flag, log, warm] }

    enum Outcome: Equatable, Sendable {
        case authenticated(region: String)
        case refused(String)
        case timedOut(String)
        /// The shim never ran, or the game never reached Photon.
        case silent(String)

        /// Photon's disconnect cause, e.g. "CustomAuthenticationFailed", when it refused.
        var refusal: String? {
            if case let .refused(cause) = self { return cause }
            if case let .timedOut(state) = self { return "timeout " + state }
            return nil
        }

        var isAuthenticated: Bool { if case .authenticated = self { return true }; return false }

        /// True when Photon answered at all, so the answer is worth learning from.
        var isAnswer: Bool { if case .silent = self { return false }; return true }

        var summary: String {
            switch self {
            case let .authenticated(region):
                return "Photon authenticated the game"
                    + (region.isEmpty ? "" : " in \(region)")
            case let .refused(cause):
                return "Photon refused the connection: \(cause)"
            case let .timedOut(state):
                return "Photon never finished the connection (\(state))"
            case let .silent(why):
                return why
            }
        }
    }

    // MARK: - When

    /// True when this game can be driven: a Mono build that speaks Photon, under Wine.
    /// `managed` is the runtime folder the game ships; an IL2CPP build has none.
    static func canDrive(photonGame: Bool, managed: Bool, nativeMacBuild: Bool) -> Bool {
        photonGame && managed && !nativeMacBuild
    }

    // MARK: - Files

    /// The shim shipped with the app, or beside the sources when run from a build tree.
    static func source() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("autopilot", isDirectory: true))
        }
        var start = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                        isDirectory: true)
        start = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for start in [start] {
            var directory = start
            for _ in 0..<8 {
                for relative in ["vendor/autopilot", "onlinefix/vendor/autopilot"] {
                    let candidate = directory.appendingPathComponent(relative, isDirectory: true)
                    if !candidates.contains(candidate) { candidates.append(candidate) }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return candidates.first {
            Paths.fm.fileExists(atPath: $0.appendingPathComponent(dll).path)
        }
    }

    /// Copies the shim into the game folder. Returns the file it wrote, or nil when the
    /// payload is not shipped or the game already has it.
    @discardableResult
    static func place(in folder: URL) -> URL? {
        let destination = folder.appendingPathComponent(dll)
        guard let source = source() else { return nil }
        let built = source.appendingPathComponent(dll)
        if let existing = try? Data(contentsOf: destination),
           let shipped = try? Data(contentsOf: built), existing == shipped {
            return nil
        }
        try? Paths.fm.removeItem(at: destination)
        guard (try? Paths.fm.copyItem(at: built, to: destination)) != nil else { return nil }
        return destination
    }

    /// Names the shim in the fix's `dlllist.txt`. It has to come after the runtime:
    /// the shim reaches the Mono the game already loaded, so that must be in first.
    @discardableResult
    static func name(in folder: URL, launchFolder: URL) -> Bool {
        let list = launchFolder.appendingPathComponent("dlllist.txt")
        guard Paths.fm.fileExists(atPath: list.path) else { return false }
        return FixApply.ensureDLLListEntries([dll], at: list)
    }

    /// Puts the shim in place and names it, and reports whether both are true — not
    /// whether anything changed, since a game already set up is still ready.
    static func ready(in folder: URL, launchFolder: URL) -> Bool {
        place(in: folder)
        name(in: folder, launchFolder: launchFolder)
        guard Paths.fm.fileExists(atPath: folder.appendingPathComponent(dll).path) else {
            return false
        }
        let list = launchFolder.appendingPathComponent("dlllist.txt")
        let text = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        return text.lowercased().contains(dll.lowercased())
    }

    static func start(in folder: URL) {
        // The log is emptied first: a previous run's answer would otherwise be read as
        // this one's before the game has said anything.
        try? Data().write(to: folder.appendingPathComponent(log))
        try? Data().write(to: folder.appendingPathComponent(flag))
    }

    /// Clears the ask flag and the warm mark, and leaves the shim and the log in place:
    /// the next run empties the log itself, and keeping it lets a report explain what
    /// this one said.
    static func finish(in folder: URL) {
        for name in [flag, warm] {
            try? Paths.fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func forget(in folder: URL) {
        for name in owned {
            try? Paths.fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - The answer

    /// What the last run said, or nil when it never wrote a line.
    static func outcome(in folder: URL) -> Outcome? {
        let text = (try? String(contentsOf: folder.appendingPathComponent(log),
                               encoding: .utf8)) ?? ""
        for raw in text.components(separatedBy: .newlines).reversed() {
            // Lines are stamped "<time> <word> …"; the word is what matters.
            let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let rest = parts.count > 2 ? String(parts[2]) : ""
            switch parts[1] {
            case "ok":
                // "ok already-connected" has no region; "ok Joined" is the state name.
                return .authenticated(region: rest.hasPrefix("already") ? "" : region(in: text))
            case "fail":
                let cause = rest.split(separator: " ").first.map(String.init) ?? ""
                if cause.hasPrefix("timeout") { return .timedOut(rest) }
                if cause == "no-photon" || cause.hasPrefix("exception") {
                    return .silent("the game never reached Photon (\(rest))")
                }
                return .refused(rest.isEmpty ? cause : rest)
            default:
                continue
            }
        }
        if text.isEmpty { return nil }
        return .silent("the autopilot started but never finished")
    }

    /// The region the client reported, from its own line, for the message.
    private static func region(in text: String) -> String {
        for raw in text.components(separatedBy: .newlines).reversed() {
            guard let range = raw.range(of: "region=") else { continue }
            return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}
