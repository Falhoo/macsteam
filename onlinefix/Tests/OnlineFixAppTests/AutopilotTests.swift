import Foundation
import Testing
@testable import OnlineFixApp

/// Reading the answer the autopilot wrote, and only driving games that can be driven.
@Suite struct AutopilotTests {

    private func folder(_ lines: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent(Autopilot.log),
                                                atomically: true, encoding: .utf8)
        return folder
    }

    @Test func nothingWrittenIsNoAnswer() throws {
        let empty = try folder([])
        #expect(Autopilot.outcome(in: empty) == nil)
    }

    @Test func aRefusalKeepsPhotonsOwnWords() throws {
        let refusal = try folder(["12:00:01 start", "12:00:09 fail CustomAuthenticationFailed",
                                  "12:00:09 fail CustomAuthenticationFailed region=asia"])
        #expect(Autopilot.outcome(in: refusal) == .refused("CustomAuthenticationFailed region=asia"))
        #expect(Autopilot.outcome(in: refusal)?.refusal == "CustomAuthenticationFailed region=asia")
    }

    @Test func authenticatingIsNotARefusal() throws {
        let ok = try folder(["12:00:01 start", "12:00:05 region=eu",
                             "12:00:06 state Authenticating", "12:00:09 ok ConnectedToMasterServer"])
        let outcome = Autopilot.outcome(in: ok)
        #expect(outcome?.isAuthenticated == true)
        #expect(outcome?.isAnswer == true)
        #expect(outcome?.summary.contains("eu") == true)
    }

    @Test func anAuthThatIsAlreadyThereNeedsNoRegion() throws {
        let ok = try folder(["12:00:01 start", "12:00:02 ok already-connected"])
        #expect(Autopilot.outcome(in: ok) == .authenticated(region: ""))
    }

    @Test func aGameThatNeverReachedPhotonIsSilent() throws {
        let quiet = try folder(["12:00:01 start", "12:01:02 fail no-photon"])
        #expect(Autopilot.outcome(in: quiet)?.isAnswer == false)
        #expect(Autopilot.outcome(in: quiet)?.isAuthenticated == false)
    }

    @Test func aTimeoutIsReportedAsOne() throws {
        let stuck = try folder(["12:00:01 start", "12:00:40 fail timeout at ConnectingToMasterServer"])
        #expect(Autopilot.outcome(in: stuck)?.refusal?.hasPrefix("timeout") == true)
    }

    @Test func onlyAMonoPhotonGameUnderWineIsDriven() {
        #expect(Autopilot.canDrive(photonGame: true, managed: true, nativeMacBuild: false))
        // IL2CPP: no Mono to load an assembly into.
        #expect(!Autopilot.canDrive(photonGame: true, managed: false, nativeMacBuild: false))
        // A native Mac build runs no Wine and no Mono either.
        #expect(!Autopilot.canDrive(photonGame: true, managed: true, nativeMacBuild: true))
        // Nothing to ask a game that does not speak Photon.
        #expect(!Autopilot.canDrive(photonGame: false, managed: true, nativeMacBuild: false))
    }

    @Test func theAskFlagIsShortLived() throws {
        let folder = try folder([])
        Autopilot.start(in: folder)
        #expect(Paths.fm.fileExists(atPath: folder.appendingPathComponent(Autopilot.flag).path))
        try "answer".write(to: folder.appendingPathComponent(Autopilot.log), atomically: true,
                           encoding: .utf8)
        Autopilot.finish(in: folder)
        #expect(!Paths.fm.fileExists(atPath: folder.appendingPathComponent(Autopilot.flag).path))
        // The log stays, so a report can quote it; the next run empties it before the
        // game starts, which is what keeps a stale answer from being read.
        #expect(Paths.fm.fileExists(atPath: folder.appendingPathComponent(Autopilot.log).path))
        Autopilot.start(in: folder)
        let emptied = (try? String(contentsOf: folder.appendingPathComponent(Autopilot.log),
                                   encoding: .utf8)) ?? "unreadable"
        #expect(emptied.isEmpty)
    }

    @Test func theShutdownClearsWhatItOwns() throws {
        let folder = try folder([])
        for name in Autopilot.owned {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true,
                          encoding: .utf8)
        }
        Autopilot.forget(in: folder)
        for name in Autopilot.owned {
            #expect(!Paths.fm.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
    }

    @Test func theShimIsNamedAfterTheRuntimeItNeeds() throws {
        // The shim reaches the Mono the game has already loaded, so its dlllist entry
        // has to come after that load — the list is read top to bottom.
        let folder = try folder([])
        let list = ["SteamOverlay64.dll", "OnlineFix64.dll",
                    "MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll", "Custom.dll"]
            .joined(separator: "\r\n")
        try list.write(to: folder.appendingPathComponent("dlllist.txt"), atomically: true,
                       encoding: .utf8)
        #expect(Autopilot.name(in: folder, launchFolder: folder))
        let lines = try String(contentsOf: folder.appendingPathComponent("dlllist.txt"),
                               encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let mono = try #require(lines.firstIndex(of:
            "MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll"))
        let shim = try #require(lines.firstIndex(of: Autopilot.dll))
        #expect(shim > mono)
        // Naming it twice would load the shim twice.
        #expect(!Autopilot.name(in: folder, launchFolder: folder))
    }
}
