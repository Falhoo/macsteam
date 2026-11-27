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
            /// The app does not accept the auth type the client sent: "Authentication
            /// type not supported" means the app is registered for another one.
            case authTypeRefused
            /// Photon refused the credentials for another reason, or never connected.
            case authRefused
        }

        var title: String {
            switch failure {
            case .none: return "Photon's log shows no refusal"
            case .ticketRejected: return "Photon refused the Steam ticket"
            case .appIDRefused: return "Photon refused the app id"
            case .authTypeRefused: return "Photon does not accept the auth type used"
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
            case .authTypeRefused:
                text += " The app is registered for a different authentication type, so the "
                    + "credentials were refused before any room was joined. Which type it "
                    + "wants is the app's setting, not the game's: a Steam-auth app takes the "
                    + "game's own ticket, OnlineFix's apps take custom auth."
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
            case .authTypeRefused:
                return "Match the app to the credentials: an unowned game plays on OnlineFix's "
                    + "shared app with the custom auth the fix writes, and an owned one on the "
                    + "game's own app with Steam's ticket. Which of the two is in the files is "
                    + "what the app id says."
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

    /// Every log a game writes for itself in its Wine prefix.
    ///
    /// Unity uses `AppData/LocalLow/<company>/<product>/Player.log`, and some builds
    /// are told to use `AppData/Local` instead. An Unreal build writes
    /// `AppData/Local/<project>/Saved/Logs/*.log`, and a launcher the game ships can
    /// write its own crash log beside the executable, which Photon's answer sometimes
    /// reaches rather than Unity's. All three are read; the newest wins.
    static func logs(in prefix: URL?, gameFolder: URL? = nil) -> [URL] {
        var found: [URL] = []
        if let gameFolder {
            for name in ["Player.log", "output_log.txt", "photon.log"] {
                let url = gameFolder.appendingPathComponent(name)
                if Paths.fm.fileExists(atPath: url.path) { found.append(url) }
            }
        }
        guard let prefix else { return found }
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let entries = (try? Paths.fm.contentsOfDirectory(
            at: users, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for user in entries {
            for base in ["AppData/LocalLow", "AppData/Local"] {
                let root = user.appendingPathComponent(base, isDirectory: true)
                for company in directories(in: root) {
                    for product in directories(in: company) {
                        for name in ["Player.log", "Player-prev.log"] {
                            let url = product.appendingPathComponent(name)
                            if Paths.fm.fileExists(atPath: url.path) { found.append(url) }
                        }
                        // Unreal's logs, and its crash folder.
                        for folder in ["Saved/Logs", "Saved/Crashes"] {
                            let dir = product.appendingPathComponent(folder, isDirectory: true)
                            for url in files(in: dir) where url.pathExtension.lowercased() == "log" {
                                found.append(url)
                            }
                        }
                    }
                }
            }
        }
        return found
    }

    private static func entries(in url: URL, key: URLResourceKey) -> [URL] {
        let found: [URL] = (try? Paths.fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [key],
            options: [.skipsHiddenFiles])) ?? []
        return found.filter {
            (try? $0.resourceValues(forKeys: [key]))?.allValues[key] as? Bool == true
        }
    }

    private static func directories(in url: URL) -> [URL] {
        entries(in: url, key: .isDirectoryKey)
    }

    private static func files(in url: URL) -> [URL] {
        entries(in: url, key: .isRegularFileKey)
    }

    /// The newest log this game wrote, including the Photon patch's own. A stale
    /// `photondiag.log` from an earlier attempt must not hide the Player.log the
    /// game wrote after it: the patch's log is only preferred when it is newer.
    static func newestLog(gameFolder: URL, prefix: URL?) -> URL? {
        var candidates = logs(in: prefix, gameFolder: gameFolder)
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
    ///
    /// The client's log runs to megabytes and is asked about once per finding, per
    /// plan and per round of the consistency pass, so the answer is kept until the
    /// log grows. A nil is kept too: "never mentioned" does not change while the file
    /// does not.
    static func clientOwnership(appID: Int) -> Bool? {
        let file = Paths.home
            .appendingPathComponent("Library/Application Support/macsteam/macsteam.log")
        let stamp = ((try? file.resourceValues(forKeys: [.contentModificationDateKey,
                                                         .fileSizeKey]))).map {
            "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0)|\($0.fileSize ?? 0)"
        } ?? ""

        ownershipLock.lock()
        if let cached = ownershipCache[appID], cached.stamp == stamp {
            ownershipLock.unlock()
            return cached.answer
        }
        ownershipLock.unlock()

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 2 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let answer = ownership(inClientLog: String(decoding: data, as: UTF8.self), appID: appID)

        ownershipLock.lock()
        ownershipCache[appID] = (stamp, answer)
        ownershipLock.unlock()
        return answer
    }

    private static let ownershipLock = NSLock()
    nonisolated(unsafe) private static var ownershipCache: [Int: (stamp: String, answer: Bool?)] = [:]

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
        guard let data = tail(of: url) else { return nil }
        // UTF-8 first; the replacement decoder never fails, so one bad byte in a
        // log does not throw the whole answer away.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// The end of a log. A `Player.log` runs to tens of megabytes on a game that has
    /// been played for a while, and the connection attempt is at the end of it, so only
    /// the last stretch is read. The window is generous enough to hold the whole of a
    /// launch, and starts on a line break so the first line is not cut in half.
    static func tail(of url: URL, bytes: UInt64 = 2 * 1024 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: from)
        guard var data = try? handle.readToEnd() else { return nil }
        if from > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return data
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
        // "Authentication type not supported (none configured)": the app answered about
        // the type itself, before any ticket was checked. It outranks the token rule:
        // OnlineFix's apps put the words "custom auth" in the same message.
        if said.contains("authenticationtype") { return .authTypeRefused }
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
