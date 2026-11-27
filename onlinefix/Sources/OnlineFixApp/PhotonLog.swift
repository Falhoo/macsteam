// What a Photon game's own log says about the connection it tried to make.
//
// "Failed to connect to Photon Network" is the game's text for every reason Photon
// can refuse, so it says nothing about the cause. The game's log does: the AppID it
// ran as, Photon's return code, Photon's own message naming the side that refused,
// and what EOS made of the same token. This reads the newest of those logs, so the
// diagnosis can say what happened instead of guessing from the game folder.
//
// Nothing here changes a game. It reads a file the game wrote and turns it into one
// sentence with a remedy.
import Foundation

enum PhotonLog {

    struct Evidence: Sendable, Equatable {
        /// The log this came from.
        var source: URL
        /// The AppID Steam told the game it was, from its own startup line.
        var ranAs: Int?
        /// Photon's Authenticate return code.
        var returnCode: Int?
        /// Photon's message, which names the side that refused.
        var message: String?
        var failure: Failure
        /// The lines worth showing, in the order the game wrote them.
        var lines: [String]
        /// False when the game's own log says Steam reported no licence for it
        /// (`CheckAppOwnership: SPOOFING appid N (orig=0)`), nil when it says nothing.
        var ownsApp: Bool?

        enum Failure: String, Sendable {
            /// Nothing in the log says Photon refused.
            case none
            /// Photon asked Steam to vouch for the ticket, and Steam said no.
            case ticketRejected
            /// Photon refused the app id itself.
            case appIDRefused
            /// Photon refused the credentials for another reason, or never connected.
            case authRefused
        }

        var title: String {
            switch failure {
            case .none: return "Photon's log shows no refusal"
            case .ticketRejected: return "Photon refused the Steam ticket"
            case .appIDRefused: return "Photon refused the app id"
            case .authRefused: return "Photon refused the connection"
            }
        }

        var detail: String {
            var parts: [String] = []
            parts.append("\(source.lastPathComponent) says")
            if let ranAs { parts.append("the game ran as AppID \(ranAs)") }
            if let returnCode {
                parts.append("Photon answered \(returnCode)"
                    + (message.map { " (\($0))" } ?? ""))
            } else if let message {
                parts.append("Photon said “\(message)”")
            }
            var text = parts.joined(separator: ", ") + "."
            switch failure {
            case .none:
                return text
            case .ticketRejected:
                text += " Photon asked Steam to vouch for the game's auth ticket and Steam "
                    + "refused it, because the ticket is not one Steam signed for this game: "
                    + "it was issued for the AppID the game ran as, not for the game itself."
            case .appIDRefused:
                text += " The app id the game connected with is not one Photon accepts for "
                    + "this game, so no player reaches a room."
            case .authRefused:
                text += " The credentials Photon received were refused before any room was "
                    + "joined."
            }
            return text
        }

        var remedy: String {
            switch failure {
            case .none:
                return "Nothing to do."
            case .ticketRejected:
                return "A ticket Steam will vouch for is the only thing that passes this "
                    + "check. Run the game as its own AppID and let Steam issue the ticket; "
                    + "an account that does not own the game cannot pass it, and no file in "
                    + "the game folder changes that."
            case .appIDRefused:
                return "Use OnlineFix's Photon app id: install its Photon patch, or replace "
                    + "the id in the game's own files."
            case .authRefused:
                return "Read the lines above; they name what Photon objected to."
            }
        }

        /// True when there is something the player has to know.
        var isFailure: Bool { failure != .none }
    }

    /// Photon's Authenticate return codes for credentials it would not take.
    static let authCodes: Set<Int> = [32755, 32756, 32757]

    /// Lines that carry a Photon or auth answer, kept for the report.
    static let interesting = ["photon", "eos auth", "auth ticket", "returncode",
                             "failed to connect", "failed to authenticate", "disconnect",
                             "authenticat", "app id", "appid"]

    /// The Photon patch's own log, if the diagnostic plugin has been run.
    static let pluginLog = "photondiag.log"

    // MARK: - Finding the log

    /// Every log a Unity game writes for itself in its Wine prefix.
    static func logs(in prefix: URL?) -> [URL] {
        guard let prefix else { return [] }
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: users, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var found: [URL] = []
        for user in entries {
            let low = user.appendingPathComponent("AppData/LocalLow", isDirectory: true)
            let companies = (try? Paths.fm.contentsOfDirectory(
                at: low, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for company in companies {
                let products = (try? Paths.fm.contentsOfDirectory(
                    at: company, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                for product in products {
                    for name in ["Player.log", "Player-prev.log"] {
                        let url = product.appendingPathComponent(name)
                        if Paths.fm.fileExists(atPath: url.path) { found.append(url) }
                    }
                }
            }
        }
        return found
    }

    /// The newest log this game wrote, including the Photon patch's own. A stale
    /// `photondiag.log` from an earlier attempt must not hide the Player.log the
    /// game wrote after it: the patch's log is only preferred when it is newer.
    static func newestLog(gameFolder: URL, prefix: URL?) -> URL? {
        var candidates = logs(in: prefix)
        let plugin = gameFolder.appendingPathComponent(pluginLog)
        if Paths.fm.fileExists(atPath: plugin.path) { candidates.append(plugin) }
        return candidates.max { one, other in
            modified(one) < modified(other)
        }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate) ?? .distantPast
    }

    // MARK: - Reading it

    /// Reads the game's newest log and says what Photon made of its credentials.
    /// Nil when the game has written no log at all.
    static func read(gameFolder: URL, prefix: URL?) -> Evidence? {
        guard let url = newestLog(gameFolder: gameFolder, prefix: prefix),
              let text = text(at: url) else { return nil }
        return parse(text, source: url)
    }

    /// True when this account holds no licence for the game, from what the game and
    /// the client's own log said the last time it ran. Nil when neither says.
    ///
    /// The client's log is the reliable one: its licence hook prints
    /// `CheckAppOwnership: SPOOFING appid N (orig=0)` only when Steam itself had no
    /// licence, which is exactly the case that makes a Photon ticket worthless.
    static func ownsApp(appID: Int, folder: URL, prefix: URL? = nil) -> Bool? {
        if let evidence = read(gameFolder: folder, prefix: prefix), let owns = evidence.ownsApp {
            return owns
        }
        return clientOwnership(appID: appID)
    }

    /// The last thing the client logged about owning this AppID.
    static func clientOwnership(appID: Int) -> Bool? {
        let file = Paths.home
            .appendingPathComponent("Library/Application Support/macsteam/macsteam.log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 2 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return ownership(inClientLog: String(decoding: data, as: UTF8.self), appID: appID)
    }

    /// The last verdict the client logged about owning `appID`, from a log's text.
    /// Nil when the client never mentioned it.
    static func ownership(inClientLog text: String, appID: Int) -> Bool? {
        let marker = "CheckAppOwnership: SPOOFING appid \(appID) (orig="
        var answer: Bool?
        for line in text.components(separatedBy: .newlines) {
            guard let range = line.range(of: marker) else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let orig = Int(digits) { answer = orig != 0 }
        }
        return answer
    }

    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // UTF-8 first; the replacement decoder never fails, so one bad byte in a
        // log does not throw the whole answer away.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// The lines of a log, turned into the one answer that matters.
    static func parse(_ text: String, source: URL) -> Evidence {
        var ranAs: Int?
        var returnCode: Int?
        var message: String?
        var ownsApp: Bool?
        var kept: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // "CheckAppOwnership: SPOOFING appid 3241660 (orig=0)": Steam said the
            // account holds no licence for the game.
            if line.contains("CheckAppOwnership") {
                if let range = line.range(of: "orig=") {
                    let digits = line[range.upperBound...].prefix { $0.isNumber }
                    if let own = Int(digits) { ownsApp = own != 0 }
                }
            }
            if let range = line.range(of: "AppID = ") {
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                if let id = Int(digits) { ranAs = id }
            }
            if let range = line.range(of: "ReturnCode: ") {
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                if let code = Int(digits) {
                    returnCode = code
                    // "… ReturnCode: 32755 (Failed(2): error response from Steam). …"
                    // The message is the outermost bracketed part of the same line.
                    if let left = line[range.upperBound...].firstIndex(of: "("),
                       let right = line.lastIndex(of: ")"), left < right {
                        message = String(line[line.index(after: left)..<right])
                    }
                }
            }
            if interesting.contains(where: { line.lowercased().contains($0) }) {
                kept.append(line)
            }
        }

        return Evidence(source: source, ranAs: ranAs, returnCode: returnCode,
                        message: message, failure: classify(message: message,
                                                            returnCode: returnCode,
                                                            text: text),
                        lines: Array(kept.suffix(12)), ownsApp: ownsApp)
    }

    /// Which side refused. Photon names it in the message: a ticket it passed to
    /// Steam, an app id it does not know, or something else it will not take.
    static func classify(message: String?, returnCode: Int?, text: String) -> Evidence.Failure {
        // Photon writes "app id", "AppId" and "ApplicationId" for the same thing.
        let said = (message ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if said.contains("steam") || said.contains("ticket") {
            return .ticketRejected
        }
        if said.contains("appid") || said.contains("applicationid") {
            return .appIDRefused
        }
        if let returnCode, authCodes.contains(returnCode) { return .authRefused }
        let whole = text.lowercased()
        if whole.contains("customauthentication") || whole.contains("failed to connect to photon") {
            return .authRefused
        }
        return .none
    }
}
