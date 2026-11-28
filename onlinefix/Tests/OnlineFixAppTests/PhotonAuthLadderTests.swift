import Foundation
import Testing
@testable import OnlineFixApp

/// Photon is the only thing that knows which auth type a game's app is registered
/// for, so its answer decides the patch: a refused type moves to the other type, a
/// refused ticket moves off Steam auth entirely.
@Suite struct PhotonAuthLadderTests {

    /// A game folder with the real Photon assembly fixture in it.
    private func folder() throws -> URL {
        let url = try #require(Bundle.module.url(forResource: "PhotonRealtime",
                                                 withExtension: "dll",
                                                 subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonauth-ladder-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("Game_Data/Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data(contentsOf: url).write(to: managed.appendingPathComponent("PhotonRealtime.dll"))
        return root
    }

    private func evidence(_ failure: PhotonLog.Evidence.Failure) -> PhotonLog.Evidence {
        PhotonLog.Evidence(source: URL(fileURLWithPath: "/tmp/Player.log"), ranAs: 480,
                           returnCode: 32755, message: "", failure: failure, lines: [])
    }

    @Test func aRefusedTypeTakesTheOtherType() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let modes = PhotonAuth.modes(in: root)
        try #require(modes.count >= 2)
        // Whichever type is in use, the refusal of that type picks a different one.
        for current in modes where current != .none {
            let next = PhotonAuth.nextMode(after: .authTypeRefused, current: current, in: root)
            #expect(next != nil)
            #expect(next != current)
        }
    }

    @Test func aRefusedTicketLeavesSteamAuth() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(PhotonAuth.modes(in: root).contains(.steam))
        let next = PhotonAuth.nextMode(after: .ticketRejected, current: .steam, in: root)
        #expect(next == .custom)
        // From the app's own auth it goes the other way: a custom login Photon refused
        // is the plugin's ticket being turned down, and Steam auth is the retry.
        #expect(PhotonAuth.nextMode(after: .ticketRejected, current: .custom, in: root) == .steam)
    }

    @Test func theModeInUseIsReadBackOffTheAssembly() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = PhotonAuth.observedMode(in: root)
        try PhotonAuth.setEnabled(true, in: root, mode: .none)
        #expect(PhotonAuth.observedMode(in: root) != before || before == nil)
        try PhotonAuth.setEnabled(false, in: root)
        #expect(PhotonAuth.observedMode(in: root) == before)
    }

    @Test func nothingSaidMeansNoChange() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PhotonAuth.nextMode(after: .none, current: .steam, in: root) == nil)
    }

    /// What the autopilot hears when a custom login is refused. Photon's own cause,
    /// by name, has to end up in the same terms as a line from the log.
    @Test func aRefusedCustomLoginReadsAsARefusedTicket() {
        for cause in ["CustomAuthenticationFailed", "CustomAuthenticationFailed region=asia"] {
            let failure = PhotonLog.classify(message: cause, returnCode: nil, text: cause)
            #expect(failure == .ticketRejected)
        }
    }

    /// The same cause the log would give, from the answer instead: the auth type moves
    /// off custom auth, which is the whole point of asking.
    @Test func aRefusedCustomLoginMovesTheAuthType() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cause = "CustomAuthenticationFailed"
        let failure = PhotonLog.classify(message: cause, returnCode: nil, text: cause)
        let next = PhotonAuth.nextMode(after: failure, current: .custom, in: root)
        #expect(next == .steam)
    }

    /// The installer's own path: the answer the autopilot got is the evidence, and a
    /// refused custom login has to move the patch to Steam auth by itself.
    @Test func theInstallerLearnsFromWhatPhotonAnswered() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try PhotonAuth.setEnabled(true, in: root, mode: .steam)
        var recipe = FixRecipe(appID: 3241660, name: "Repo", installedAt: Date(),
                               packageName: "p.rar", findings: [], entries: [],
                               removed: [], keepRealAppID: false, photonSwap: false,
                               picoPark2: false, wineDLLs: [])
        recipe.photonAuth = "steam"

        var result = LaunchTest.Result(appID: 3241660, name: "Repo", at: Date(),
                                       outcome: .launched, windowSeconds: 9, runtimeSeconds: 20,
                                       exitStatus: 0, issue: .none, issueDetail: "",
                                       evidence: [], logPaths: [], repairs: [],
                                       online: LaunchTest.OnlineEvidence())
        result.online.autopilotCause = "CustomAuthenticationFailed region=asia"
        var outcome = FixService.Outcome()
        outcome.launchTest = result

        #expect(FixService.learnPhotonAuth(appID: 3241660, folder: root, recipe: &recipe,
                                          outcome: &outcome))
        // The patch moved, and the note says so with Photon's own words.
        #expect(recipe.photonAuth == "custom")
        #expect(PhotonAuth.observedMode(in: root) == .custom)
        #expect(outcome.notes.joined(separator: " ").contains("customauthenticationfailed"))
    }
}
