// Reading a Photon game's own log, which is the only thing that says which side
// refused the connection.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonLogTests {

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonlog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// PEAK's own log, trimmed to the lines that matter.
    private let peak = """
    Setting breakpad minidump AppID = 480
    EOS auth start (steam)
    Steam auth ticket received, adding it to PhotonNetwork
    Photon StartPeerCreated using app version: 3.1
    OperationResponse 230: ReturnCode: 32755 (Failed(2): error response from Steam). Parameters: {} Server: NameServer Address: ns.photonengine.io:5058
    Opening disconnected modal
    """

    @Test
    func aTicketSteamRefusedIsReadFromTheLog() throws {
        let source = URL(fileURLWithPath: "/tmp/Player.log")
        let evidence = PhotonLog.parse(peak, source: source)

        #expect(evidence.ranAs == 480)
        #expect(evidence.returnCode == 32755)
        #expect(evidence.message == "Failed(2): error response from Steam")
        #expect(evidence.failure == .ticketRejected)
        #expect(evidence.isFailure)
        #expect(evidence.title.contains("Steam ticket"))
        #expect(evidence.remedy.contains("own AppID"))
        #expect(evidence.lines.contains { $0.contains("Steam auth ticket received") })
    }

    @Test
    func anAppIDPhotonDoesNotKnowIsReadFromTheLog() {
        let log = """
        OperationResponse 230: ReturnCode: 32755 (Failed(2): ApplicationId is not set). Parameters: {}
        """
        let evidence = PhotonLog.parse(log, source: URL(fileURLWithPath: "/tmp/Player.log"))
        #expect(evidence.failure == .appIDRefused)
        #expect(evidence.title.contains("app id"))
    }

    @Test
    func aGameThatConnectedSaysNothing() {
        let log = """
        Setting breakpad minidump AppID = 480
        Photon StartPeerCreated using app version: 3.1
        Connected to region eu
        """
        let evidence = PhotonLog.parse(log, source: URL(fileURLWithPath: "/tmp/Player.log"))
        #expect(evidence.failure == .none)
        #expect(!evidence.isFailure)
        #expect(evidence.ranAs == 480)
    }

    /// The newest log wins: an older failed run must not be reported over a new one.
    @Test
    func theNewestLogIsTheOneRead() throws {
        let prefix = try folder("prefix")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let low = prefix.appendingPathComponent(
            "drive_c/users/steamuser/AppData/LocalLow/LandCrab/PEAK", isDirectory: true)
        let older = low.appendingPathComponent("Player-prev.log")
        try write(peak, to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        try write("Setting breakpad minidump AppID = 480\nConnected to region eu\n",
                  to: low.appendingPathComponent("Player.log"))

        let game = try folder("game")
        defer { try? FileManager.default.removeItem(at: game) }

        let evidence = PhotonLog.read(gameFolder: game, prefix: prefix)
        // `.none` on an optional means nil, so the case is spelled out.
        #expect(evidence?.failure == PhotonLog.Evidence.Failure.none)
        #expect(evidence?.source.lastPathComponent == "Player.log")
    }

    /// A game that has never run has written no log, so there is nothing to say.
    @Test
    func noLogMeansNoEvidence() throws {
        let game = try folder("empty")
        defer { try? FileManager.default.removeItem(at: game) }
        #expect(PhotonLog.read(gameFolder: game, prefix: nil) == nil)
    }
}
