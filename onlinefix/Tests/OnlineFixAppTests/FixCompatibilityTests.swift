// The check that runs before an OnlineFix is installed: it must ask the player
// when a fix may install fine and still never connect.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixCompatibilityTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixcompat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A plain Windows game with nothing standing in the way installs without asking.
    @Test
    func aPlainWindowsGameGoesAhead() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("game", to: root.appendingPathComponent("Game.exe"))

        let check = FixCompatibility.check(appID: 1, name: "Game", folder: root)
        #expect(check.verdict == FixCompatibilityVerdict.works.rawValue)
        #expect(!check.needsConfirmation)
    }

    /// R.E.P.O.'s online play runs on Photon, and OnlineFix's Photon patch does not
    /// work everywhere, so the player is asked before anything is downloaded.
    @Test
    func aPhotonGameIsAskedAboutFirst() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("managed", to: root.appendingPathComponent(
            "REPO/REPO_Data/Managed/PhotonRealtime.dll"))

        let check = FixCompatibility.check(appID: 3241660, name: "R.E.P.O.", folder: root)
        #expect(check.verdict == FixCompatibilityVerdict.risky.rawValue)
        #expect(check.needsConfirmation)
    }

    /// A game that ships Easy Anti-Cheat cannot join protected servers under Wine.
    @Test
    func anAntiCheatGameIsAskedAboutFirst() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("ac", to: root.appendingPathComponent("EasyAntiCheat/EasyAntiCheat_x64.dll"))

        let check = FixCompatibility.check(appID: 1, name: "Game", folder: root)
        #expect(check.verdict == FixCompatibilityVerdict.risky.rawValue)
        #expect(check.needsConfirmation)
    }

    /// A native macOS build can never take a Windows OnlineFix.
    @Test
    func aNativeMacGameIsRefused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)

        let check = FixCompatibility.check(appID: 1, name: "Game", folder: root)
        #expect(check.verdict == FixCompatibilityVerdict.unsupported.rawValue)
        #expect(check.needsConfirmation)
    }

    /// A GDK game is called out with that sentence and still offered: the tick in
    /// the store card is the player's choice to download it anyway.
    @Test
    func aGDKGameIsCalledOut() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("gdk", to: root.appendingPathComponent(
            "PEAK_Data/Managed/Unity.Microsoft.GDK.dll"))
        try write("exe", to: root.appendingPathComponent("PEAK.exe"))

        #expect(FixCompatibility.isGDK(folder: root))

        let check = FixCompatibility.check(appID: 3527290, name: "PEAK", folder: root)
        #expect(check.verdict == FixCompatibilityVerdict.unsupported.rawValue)
        #expect(check.title == "games gonna crash yo, GDK and allat")
        #expect(check.needsConfirmation)
        #expect(check.reason.contains("GDK"))

        let plain = try folder()
        defer { try? FileManager.default.removeItem(at: plain) }
        try write("game", to: plain.appendingPathComponent("Game.exe"))
        #expect(!FixCompatibility.isGDK(folder: plain))
    }

    /// Without the game folder there is nothing to check or install.
    @Test
    func noGameFolderIsRefused() {
        let check = FixCompatibility.check(appID: 1, name: "Game", folder: nil)
        #expect(check.verdict == FixCompatibilityVerdict.unsupported.rawValue)
        #expect(!FixCompatibility.isGDK(folder: nil))
    }
}
