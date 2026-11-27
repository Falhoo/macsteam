import Foundation
import XCTest
@testable import OnlineFixApp

final class PhotonProfileTests: XCTestCase {

    private func candidate(_ id: String, shared: Bool = false) -> PhotonPatch.Candidate {
        PhotonPatch.Candidate(file: URL(fileURLWithPath: "/tmp/photon"), id: id,
                              kind: .guid, settings: true)
    }

    private func evidence(_ lines: [String]) -> PhotonLog.Evidence {
        PhotonLog.Evidence(source: URL(fileURLWithPath: "/tmp/Player.log"),
                           ranAs: 480, returnCode: 32755,
                           message: "Authentication type not supported (none configured).",
                           failure: .authRefused, lines: lines)
    }

    func testSteamTicketWithTheGamesOwnApp() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: true, missing: []),
            candidates: [candidate(PhotonIDs.realtime)],
            log: evidence(["Getting Steam Auth Ticket..."]))

        XCTAssertEqual(profile.route, .steamAuth)
        XCTAssertTrue(profile.requestsSteamTicket)
        XCTAssertFalse(profile.usesSharedApp)
        XCTAssertTrue(profile.remedy.contains("licence"))
    }

    func testSteamTicketWithOnlineFixAppIsThe32755Mismatch() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: true, missing: []),
            candidates: [candidate(PhotonIDs.shared[0])],
            log: evidence(["Getting Steam Auth Ticket...",
                           "OperationResponse 230: ReturnCode: 32755 (Authentication type not supported)"]))

        XCTAssertEqual(profile.route, .steamAuthWithSharedApp)
        XCTAssertTrue(profile.needsAttention)
        XCTAssertTrue(profile.remedy.contains("Restore the game's own Photon ids"))
    }

    func testSharedAppWithoutSteamTicketUsesTheOnlineFixRoute() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: true, missing: []),
            candidates: [candidate(PhotonIDs.shared[0])],
            log: evidence(["Photon - AppId (Realtime): \(PhotonIDs.shared[0])"]))

        XCTAssertEqual(profile.route, .onlineFix)
        XCTAssertFalse(profile.requestsSteamTicket)
        XCTAssertTrue(profile.chainComplete)
    }

    /// The card reads a log before the patch sheet has been scanned. The log names
    /// the app it used, which is enough to spot the 32755 mismatch.
    func testTheLogsAppIDIsEnoughToSpotTheMismatch() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: true, missing: []),
            candidates: [],
            log: evidence(["Photon - AppId (Realtime): \(PhotonIDs.shared[0])",
                           "Getting Steam Auth Ticket..."]))

        XCTAssertEqual(profile.route, .steamAuthWithSharedApp)
        XCTAssertTrue(profile.needsAttention)
    }

    func testChainMissingIsReportedForSharedApp() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: true, missing: []),
            candidates: [candidate(PhotonIDs.shared[0])])

        XCTAssertEqual(profile.route, .onlineFix)
        XCTAssertFalse(profile.needsAttention)
        XCTAssertTrue(profile.remedy.contains("PhotonIntegration"))
    }

    func testTheGamesOwnAppWithNoTicketIsItsOwnRoute() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: false, missing: []),
            candidates: [candidate("11111111-2222-4333-8444-555555555555")])
        XCTAssertEqual(profile.route, .nativeCustom)
        XCTAssertFalse(profile.usesSharedApp)
        XCTAssertFalse(profile.needsAttention)
        XCTAssertTrue(profile.remedy.contains("Keep the game's own"))
    }

    func testTheSteamAuthPairIsRecognisedBeforeALogExists() {
        let profile = PhotonProfile.read(
            isPhoton: true,
            status: .init(isPhoton: false, missing: []),
            candidates: [candidate(PhotonIDs.realtime), candidate(PhotonIDs.voice)])
        XCTAssertEqual(profile.route, .steamAuth)
        XCTAssertFalse(profile.requestsSteamTicket)
        XCTAssertFalse(profile.usesSharedApp)
    }

    func testNotPhotonHasNoRoute() {
        let profile = PhotonProfile.read(isPhoton: false)
        XCTAssertEqual(profile.route, .notPhoton)
        XCTAssertEqual(profile.remedy, "Nothing to do.")
    }
}