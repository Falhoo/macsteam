// One decision about how a Photon game authenticates, made from every piece of
// evidence the installer already has: the game's own code, the package it is about
// to install, the ids in its files, and the last thing its log said.
//
// The rule this replaces treated "the game imports SteamNetworkingSockets" as
// "the game takes a Steam Photon ticket". Those are different things. A game can
// use Steam's relay for voice or achievements and still take OnlineFix's custom
// Photon auth; treating it as Steam-auth skips the chain it needs. The reverse is
// just as wrong: a game with its own Photon app and no Steam networking used to be
// swapped onto OnlineFix's app without asking.
import Foundation

enum PhotonRoute {

    enum Kind: String, Sendable, Equatable {
        case notPhoton
        /// The game's own Photon app, checked against a Steam auth ticket.
        case steamAuth
        /// OnlineFix's shared app and Custom.dll chain, custom auth, 480 route.
        case onlineFix
        /// The game's own Photon app with no Steam-ticket evidence and no OnlineFix
        /// patch. Keep the ids as they are; do not install a chain.
        case nativeCustom
        /// Photon is present but the evidence does not say which side checks it.
        case ambiguous
    }

    struct Decision: Sendable, Equatable {
        var kind: Kind
        var isPhoton: Bool
        var ownIDs: [String]
        var sharedIDs: [String]
        var requestsSteamTicket: Bool
        var usesSteamNetworking: Bool
        var hasOnlineFixPatch: Bool
        var reasons: [String]

        var isSteamAuth: Bool { kind == .steamAuth }
        var installsOnlineFix: Bool { kind == .onlineFix }
        var swapsIDs: Bool { kind == .onlineFix }

        var title: String {
            switch kind {
            case .notPhoton: return "Not a Photon game"
            case .steamAuth: return "Steam-auth Photon route"
            case .onlineFix: return "OnlineFix shared Photon route"
            case .nativeCustom: return "The game's own Photon app"
            case .ambiguous: return "Photon route not determined"
            }
        }
    }

    /// Decide from evidence, not from a single marker. `packageHasCustom` means the
    /// package carries Custom.dll; `packageHasChain` means it carries BepInEx's
    /// doorstop/preloader. A package that only says PhotonIntegration=true is also
    /// evidence that the fix expects the shared route. `vendorLoader` means
    /// OnlineFix's own loader (`OnlineFix64.dll` beside the game) is there, which is
    /// the chain that supplies custom auth itself under the runner.
    static func decide(isPhoton: Bool,
                       packagePresent: Bool = false,
                       packageSaysPhoton: Bool = false,
                       packageHasCustom: Bool = false,
                       packageHasChain: Bool = false,
                       installedChain: Bool = false,
                       vendorLoader: Bool = false,
                       candidates: [PhotonPatch.Candidate] = [],
                       usesSteamNetworking: Bool = false,
                       log: PhotonLog.Evidence? = nil) -> Decision {
        let shared = candidates.filter(\.isOnlineFixShared)
        let own = candidates.filter { !$0.isOnlineFixShared }
        let hasPatch = packageHasCustom || packageHasChain || packageSaysPhoton
            || installedChain
        let photon = isPhoton || hasPatch || !shared.isEmpty
        let ticket = log?.requestsSteamTicket == true
        // R.E.P.O.'s own realtime/voice pair is Steam-auth even before its first log
        // exists. Without this, a fresh install with a generic Custom.dll package
        // looks like custom auth and gets the BepInEx chain that Unity 6 hangs on.
        let steamAuthPair = candidates.contains { candidate in
            candidate.id.caseInsensitiveCompare(PhotonIDs.realtime) == .orderedSame
                || candidate.id.caseInsensitiveCompare(PhotonIDs.voice) == .orderedSame
        }

        var reasons: [String] = []
        if vendorLoader { reasons.append("OnlineFix's own loader is in the game folder") }
        if ticket { reasons.append("the game's log asks Steam for an auth ticket") }
        if steamAuthPair { reasons.append("the game's files carry its own Steam-auth Photon pair") }
        if hasPatch { reasons.append("the package carries OnlineFix's Photon patch") }
        if usesSteamNetworking && !ticket && !steamAuthPair {
            reasons.append("the game imports Steam networking")
        }
        if !own.isEmpty {
            reasons.append("the game's files carry its own Photon app id")
        }
        if !shared.isEmpty {
            reasons.append("the game's files carry OnlineFix's shared app id")
        }

        let kind: Kind
        if !photon {
            kind = .notPhoton
        } else if vendorLoader {
            // OnlineFix's own loader is the chain that replaces Photon's Steam
            // ticket with its custom auth: the launch log shows WINMM.dll,
            // OnlineFix64.dll and the game's own Mono loading as native modules,
            // for R.E.P.O. and PICO PARK 2 alike. A ticket request, or the game's
            // own realtime/voice pair, is the request this payload answers, so it
            // cannot outrank it.
            kind = .onlineFix
        } else if ticket || steamAuthPair {
            // The ticket is the strongest evidence. A package that also carries
            // Custom.dll cannot make a Steam ticket valid for OnlineFix's app.
            kind = .steamAuth
        } else if hasPatch {
            kind = .onlineFix
        } else if usesSteamNetworking {
            // No package evidence of custom auth: this is a game whose own app
            // expects Steam, and the chain would only replace it.
            kind = .steamAuth
        } else if packagePresent, isPhoton {
            // An OnlineFix package for a Photon game with no chain still gets the
            // vendor chain; the game is on the shared route by construction.
            kind = .onlineFix
        } else if !shared.isEmpty {
            kind = .onlineFix
        } else if !own.isEmpty {
            kind = .nativeCustom
        } else {
            kind = .ambiguous
        }

        if kind == .ambiguous, reasons.isEmpty {
            reasons.append("Photon was found, but no app id or ticket evidence was")
        }
        if kind == .notPhoton {
            reasons.append("no Photon assembly, package, or app id was found")
        }

        return Decision(kind: kind, isPhoton: photon,
                        ownIDs: Array(Set(own.map(\.id))).sorted(),
                        sharedIDs: Array(Set(shared.map(\.id))).sorted(),
                        requestsSteamTicket: ticket,
                        usesSteamNetworking: usesSteamNetworking,
                        hasOnlineFixPatch: hasPatch,
                        reasons: reasons)
    }
}
