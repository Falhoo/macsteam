// The route matrix: which evidence wins, and what must not be inferred from
// Steam networking alone.
// An account that does not own a game cannot pass Photon's Steam-ticket check, so the
// route has to change from the ticket to OnlineFix's app and custom auth. These pin
// that, and that an owned game keeps the old, preferred route.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite("PhotonRoute")
struct PhotonRouteTests {

    private func candidate(_ id: String) -> PhotonPatch.Candidate {
        PhotonPatch.Candidate(file: URL(fileURLWithPath: "/game/resources.assets"),
                              id: id, kind: .guid)
    }

    private var ticket: PhotonLog.Evidence {
        PhotonLog.parse("Getting Steam Auth Ticket...\nAppID = 3241660\n",
                        source: URL(fileURLWithPath: "/game/Player.log"))
    }

    @Test
    func noEvidenceIsNotPhoton() {
        let route = PhotonRoute.decide(isPhoton: false)
        #expect(route.kind == .notPhoton)
        #expect(!route.isPhoton)
        #expect(!route.installsOnlineFix)
    }

    @Test
    func aTicketOutranksACustomPackage() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true,
            packageSaysPhoton: true, packageHasCustom: true, packageHasChain: true,
            candidates: [candidate(PhotonIDs.shared[0])],
            usesSteamNetworking: true, log: ticket)
        #expect(route.kind == .steamAuth)
        #expect(route.requestsSteamTicket)
        #expect(!route.installsOnlineFix)
        #expect(!route.swapsIDs)
    }

    @Test
    func steamNetworkingWithACustomPackageIsNotSteamAuth() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true,
            packageHasCustom: true, packageHasChain: true,
            candidates: [candidate("11111111-2222-4333-8444-555555555555")],
            usesSteamNetworking: true)
        #expect(route.kind == .onlineFix)
        #expect(route.installsOnlineFix)
    }

    /// R.E.P.O.'s own pair is Steam-auth even before a log exists. A generic package
    /// with Custom.dll must not win over it.
    @Test
    func theSteamAuthPairOutranksACustomPackageWithoutALog() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true,
            packageHasCustom: true, packageHasChain: true,
            candidates: [candidate(PhotonIDs.realtime), candidate(PhotonIDs.voice)],
            usesSteamNetworking: true)
        #expect(route.kind == .steamAuth)
        #expect(route.requestsSteamTicket == false)
        #expect(!route.installsOnlineFix)
    }

    @Test
    func aCustomPackageWithNoNetworkIsStillOnlineFix() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true, packageSaysPhoton: true,
            usesSteamNetworking: false)
        #expect(route.kind == .onlineFix)
    }

    @Test
    func ownIDsWithoutAPackageAreNativeCustom() {
        let own = "11111111-2222-4333-8444-555555555555"
        let route = PhotonRoute.decide(
            isPhoton: true, candidates: [candidate(own)])
        #expect(route.kind == .nativeCustom)
        #expect(route.ownIDs == [own])
        #expect(!route.swapsIDs)
    }

    @Test
    func aPhotonGameWithNoPackageAndNoIDsIsAmbiguous() {
        let route = PhotonRoute.decide(isPhoton: true)
        #expect(route.kind == .ambiguous)
        #expect(route.isPhoton)
        #expect(!route.installsOnlineFix)
    }

    @Test
    func sharedIDsWithoutAPackageAreOnlineFix() {
        let route = PhotonRoute.decide(
            isPhoton: true, candidates: [candidate(PhotonIDs.shared[0])])
        #expect(route.kind == .onlineFix)
        #expect(route.sharedIDs == [PhotonIDs.shared[0]])
    }

    @Test
    func aTicketAndOnlySharedIDsIsAContradictionTheProfileCanReport() {
        let route = PhotonRoute.decide(
            isPhoton: true, candidates: [candidate(PhotonIDs.shared[0])], log: ticket)
        #expect(route.kind == .steamAuth)
        #expect(route.ownIDs.isEmpty)
        #expect(route.sharedIDs == [PhotonIDs.shared[0]])
    }

    /// OnlineFix's own loader runs inside the game's Mono and replaces Photon's
    /// Steam ticket with its custom auth, so the ticket cannot outrank it. R.E.P.O.
    /// is the case: its log asks Steam for 3241660 and the account cannot be
    /// issued one, which is what made Photon answer InvalidAuthentication.
    @Test
    func theVendorLoaderOutranksTheTicket() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true,
            packageSaysPhoton: true, packageHasCustom: true, packageHasChain: false,
            vendorLoader: true,
            candidates: [candidate(PhotonIDs.realtime), candidate(PhotonIDs.voice)],
            usesSteamNetworking: true, log: ticket)
        #expect(route.kind == .onlineFix)
        #expect(route.installsOnlineFix)
        #expect(route.requestsSteamTicket)
        #expect(route.reasons.contains { $0.contains("own loader") })
    }

    /// The pair on its own is only evidence when no loader can answer it.
    @Test
    func theVendorLoaderOutranksThePairWithoutALog() {
        let route = PhotonRoute.decide(
            isPhoton: true, packagePresent: true, vendorLoader: true,
            candidates: [candidate(PhotonIDs.realtime), candidate(PhotonIDs.voice)],
            usesSteamNetworking: true)
        #expect(route.kind == .onlineFix)
        #expect(route.requestsSteamTicket == false)
    }

    /// PICO PARK 2 has the loader and no ticket request: still the same route.
    @Test
    func theVendorLoaderAloneIsOnlineFix() {
        let route = PhotonRoute.decide(isPhoton: true, vendorLoader: true)
        #expect(route.kind == .onlineFix)
        #expect(route.installsOnlineFix)
    }
}

    /// Not owned: the game's own app cannot validate a ticket, so its ids go and
    /// custom auth is written, whatever the ticket line says.
    @Test
    func anUnownedGameUsesTheSharedAppAndCustomAuth() {
        let decision = PhotonRoute.decide(
            isPhoton: true, packagePresent: true,
            packageHasCustom: true, packageHasChain: true,
            candidates: [
                PhotonPatch.Candidate(file: URL(fileURLWithPath: "/g/x.dll"),
                                      id: "99515094-45b7-4c98-ab70-a448c548c83d",
                                      kind: .guid, offset: 0, settings: true),
            ],
            ownsApp: false)
        #expect(decision.kind == .customUnlicensed)
        #expect(decision.swapsIDs)
        #expect(decision.reasons.contains { $0.contains("does not own") })
    }

    /// Owned: the ticket is good, so nothing moves the game off its own app.
    @Test
    func anOwnedGameKeepsTheSteamRoute() {
        let decision = PhotonRoute.decide(
            isPhoton: true, packagePresent: true, packageHasCustom: true,
            candidates: [
                PhotonPatch.Candidate(file: URL(fileURLWithPath: "/g/x.dll"),
                                      id: "99515094-45b7-4c98-ab70-a448c548c83d",
                                      kind: .guid, offset: 0, settings: true),
            ],
            ownsApp: true)
        #expect(decision.kind == .steamAuth)
    }

    /// Ownership is unknown on a first run: nothing is decided by a guess, so the
    /// ticket evidence still rules.
    @Test
    func withoutOwnershipEvidenceTheTicketDecides() {
        let decision = PhotonRoute.decide(
            isPhoton: true, packagePresent: true, packageHasCustom: true,
            candidates: [
                PhotonPatch.Candidate(file: URL(fileURLWithPath: "/g/x.dll"),
                                      id: "99515094-45b7-4c98-ab70-a448c548c83d",
                                      kind: .guid, offset: 0, settings: true),
            ])
        #expect(decision.kind == .steamAuth)
}
