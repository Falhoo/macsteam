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
        // Nothing left to try from the app's own auth: the ticket is not the problem.
        #expect(PhotonAuth.nextMode(after: .ticketRejected, current: .custom, in: root) == nil)
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
}
