// What a Photon game needs from Steam, and whether its files are set up for it.
//
// There are two kinds of Photon game in an OnlineFix folder, and they fail in
// opposite ways:
//
//  - The game's own Photon app expects a Steam auth ticket. It works only when
//    Steam starts the game as its real AppID and can issue that game's licence.
//    OnlineFix's shared Photon app is registered for custom auth, so pointing
//    this kind of game at it gets 32755 from Photon.
//  - The game uses OnlineFix's shared Photon app and its custom auth. That is
//    the 480 route, and the chain that loads Custom.dll has to be complete.
//
// The game's own log is the evidence for which kind it is: R.E.P.O. writes
// "Getting Steam Auth Ticket..." before it connects, and names the app id it
// used. This reads that, without changing anything.
import Foundation

enum PhotonProfile {

    enum Route: String, Sendable, Equatable {
        case notPhoton
        /// The game's own Photon app, which asks Steam for a ticket.
        case steamAuth
        /// The game asks Steam for a ticket but is pointed at OnlineFix's app.
        case steamAuthWithSharedApp
        /// OnlineFix's shared Photon app, used with its custom auth on 480.
        case onlineFix
        /// The game's own Photon app with no Steam-ticket evidence. It may use its
        /// own custom auth; keep its ids and do not install OnlineFix's chain.
        case nativeCustom
        /// Photon is there, but no app id was readable.
        case unknown
        /// The account does not own the game, so it plays on OnlineFix's app with
        /// the custom auth the fix writes.
        case customUnlicensed
    }

    struct Profile: Sendable, Equatable {
        var route: Route
        var isPhoton: Bool
        var chainComplete: Bool
        /// The app ids found in the game's own files, in file order.
        var appIDs: [String]
        /// True when every readable app id is one OnlineFix publishes.
        var usesSharedApp: Bool
        var requestsSteamTicket: Bool
        var ranAs: Int?

        var title: String {
            switch route {
            case .notPhoton: return "Not a Photon game"
            case .steamAuth: return "Photon app with Steam auth"
            case .steamAuthWithSharedApp: return "Steam-auth game on OnlineFix's app"
            case .onlineFix: return "OnlineFix's shared Photon app"
            case .nativeCustom: return "The game's own Photon app"
            case .unknown: return "Photon app not found"
            case .customUnlicensed: return "OnlineFix's app (no licence)"
            }
        }

        var detail: String {
            switch route {
            case .notPhoton:
                return "This game does not carry a Photon assembly, so Photon has nothing to route."
            case .steamAuth:
                return "The game asks Steam for an auth ticket and uses its own Photon app. "
                    + "Photon checks that ticket against the app's registered Steam AppID, so the "
                    + "game has to run as itself, not as Spacewar (480)."
            case .steamAuthWithSharedApp:
                return "The game asks Steam for an auth ticket, but its files point at OnlineFix's "
                    + "shared Photon app. That app is registered for OnlineFix's custom auth, not "
                    + "Steam auth, so Photon answers 32755 (Authentication type not supported)."
            case .onlineFix:
                return "The game points at OnlineFix's shared Photon app and authenticates through "
                    + "OnlineFix's patch. This is the 480 route; the doorstop, preloader and "
                    + "Custom.dll all have to be in place for it to run."
            case .nativeCustom:
                return "The game carries its own Photon app id and no Steam-ticket request. "
                    + "That is its own custom-auth route; changing the id or adding OnlineFix's "
                    + "chain would move it away from the players it already meets."
            case .unknown:
                return "Photon is present, but no app id could be read from the game's files, so "
                    + "there is no target to check or patch."
            case .customUnlicensed:
                return "Steam has no licence for this game, so the ticket it signs is not for an "
                    + "app the game's own Photon application accepts. The fix points the game at "
                    + "OnlineFix's shared app and changes the auth type its Photon assembly sends "
                    + "to custom auth, which asks Steam nothing."
            }
        }

        var remedy: String {
            switch route {
            case .notPhoton:
                return "Nothing to do."
            case .steamAuth:
                return "Keep real AppID on, and use an account Steam can issue this game's licence "
                    + "to. No file patch or AppID switch substitutes for that licence."
            case .steamAuthWithSharedApp:
                return "Restore the game's own Photon ids (the manager keeps a backup when it "
                    + "patches them) and keep the real AppID on. Only an account that owns the "
                    + "game can pass this check."
            case .onlineFix:
                return chainComplete
                    ? "The chain is complete; turn PhotonIntegration on in OnlineFix.ini."
                    : "Reinstall the fix so the missing chain files are put back."
            case .nativeCustom:
                return "Keep the game's own Photon ids. No OnlineFix chain is needed for this route."
            case .unknown:
                return "Find the Photon app id in the patch sheet, or install the fix that carries "
                    + "the game's ids."
            case .customUnlicensed:
                return "Nothing to undo: install the fix and launch the game. If Photon still "
                    + "refuses, the shared app is the part to change, not your account."
            }
        }

        /// True when the player's current files cannot work with the AppID route.
        var needsAttention: Bool {
            route == .steamAuthWithSharedApp || (isPhoton && !chainComplete && route == .onlineFix)
        }
    }

    /// Reads the evidence already gathered for a game. `candidates` are the app ids
    /// found in the game's files; `log` is the newest game log, when one exists.
    static func read(isPhoton: Bool, status: PhotonFix.Status = PhotonFix.Status(),
                     candidates: [PhotonPatch.Candidate] = [],
                     log: PhotonLog.Evidence? = nil) -> Profile {
        var profile = Profile(route: .notPhoton, isPhoton: isPhoton,
                              chainComplete: status.isComplete || !status.isIncomplete,
                              appIDs: [], usesSharedApp: false,
                              requestsSteamTicket: false, ranAs: log?.ranAs)
        guard isPhoton else { return profile }

        let readable = candidates.filter { $0.settings }.isEmpty
            ? candidates : candidates.filter { $0.settings }
        profile.appIDs = (readable.isEmpty ? (log?.appIDs ?? []) : readable.map(\.id)).uniqued()
        profile.usesSharedApp = !profile.appIDs.isEmpty && profile.appIDs.allSatisfy { id in
            id == PhotonPatch.onlineFixQuantumID
                || PhotonIDs.shared.contains { $0.lowercased() == id.lowercased() }
        }
        profile.requestsSteamTicket = log?.requestsSteamTicket ?? false

        let steamAuthPair = profile.appIDs.contains { id in
            id.caseInsensitiveCompare(PhotonIDs.realtime) == .orderedSame
                || id.caseInsensitiveCompare(PhotonIDs.voice) == .orderedSame
        }
        if log?.ownsApp == false {
            profile.route = .customUnlicensed
        } else if profile.requestsSteamTicket || steamAuthPair {
            profile.route = profile.usesSharedApp ? .steamAuthWithSharedApp : .steamAuth
        } else if profile.usesSharedApp {
            profile.route = .onlineFix
        } else if !readable.isEmpty {
            // The game's own app id with no ticket request: its own custom auth.
            profile.route = .nativeCustom
        } else {
            profile.route = .unknown
        }
        return profile
    }
}

extension PhotonLog.Evidence {
    /// The game asks Steam for an auth ticket. This line is written by the game's
    /// own Photon integration, so it distinguishes Steam auth from OnlineFix's
    /// custom auth even when the configured app id looks like a shared one.
    var requestsSteamTicket: Bool {
        lines.contains { line in
            ["Getting Steam Auth Ticket", "Steam auth ticket received"].contains {
                line.localizedCaseInsensitiveContains($0)
            }
        }
    }

    /// The app ids the game's own log says it used, when the files have not been
    /// scanned. Both fields matter: a realtime/voice pair names the same app twice.
    var appIDs: [String] {
        lines.compactMap { line in
            for marker in ["Photon - AppId (Realtime):", "Photon - AppId (Voice):"] {
                if let range = line.range(of: marker) {
                    let id = line[range.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return id.isEmpty ? nil : id
                }
            }
            return nil
        }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}