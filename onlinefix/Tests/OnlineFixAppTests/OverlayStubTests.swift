// The overlay stub patch and the Photon ini switch.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct OverlayStubTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlaystub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal x64 DLL whose entry point sits at file offset 0x200.
    private func syntheticDLL(entryBytes: [UInt8]) -> Data {
        var b = [UInt8](repeating: 0, count: 0x400)
        func put32(_ value: UInt32, _ offset: Int) {
            b[offset] = UInt8(value & 0xFF)
            b[offset + 1] = UInt8((value >> 8) & 0xFF)
            b[offset + 2] = UInt8((value >> 16) & 0xFF)
            b[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        b[0] = 0x4D; b[1] = 0x5A
        put32(0x80, 0x3C)
        b[0x80] = 0x50; b[0x81] = 0x45; b[0x82] = 0; b[0x83] = 0
        b[0x84] = 0x64; b[0x85] = 0x86            // machine: x86-64
        b[0x86] = 1                               // one section
        b[0x94] = 0xF0                            // optional header size
        let optional = 0x98
        b[optional] = 0x0B; b[optional + 1] = 0x02  // PE32+
        put32(0x1000, optional + 16)              // entry RVA
        let section = optional + 0xF0
        for (i, c) in ".text".utf8.enumerated() { b[section + i] = c }
        put32(0x200, section + 8)                 // virtual size
        put32(0x1000, section + 12)               // virtual address
        put32(0x200, section + 16)                // raw size
        put32(0x200, section + 20)                // raw pointer
        for (i, c) in entryBytes.enumerated() { b[0x200 + i] = c }
        for (i, c) in "OnlineFix".utf8.enumerated() { b[0x300 + i] = c }
        return Data(b)
    }

    @Test
    func theOverlayStubIsMadeToDoNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("SteamOverlay64.dll")
        try syntheticDLL(entryBytes: [0x48, 0x89, 0x5C, 0x24, 0x08]).write(to: url)

        #expect(!OverlayStub.isDisabled(at: url))
        #expect(OverlayStub.disable(at: url))
        #expect(OverlayStub.isDisabled(at: url))

        let data = try Data(contentsOf: url)
        #expect(Array(data[0x200..<0x206]) == OverlayStub.patched)
        // Running it again leaves the file alone.
        #expect(OverlayStub.disable(at: url))
    }

    @Test
    func aFileThatIsNotAStubIsLeftAlone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("OnlineFix64.dll")
        try Data("{not a pe}".utf8).write(to: url)

        #expect(!OverlayStub.disable(at: url))
        let untouched = try Data(contentsOf: url)
        #expect(untouched == Data("{not a pe}".utf8))
    }

    /// OnlineFix only runs its Photon patch when the ini says so.
    @Test
    func photonIntegrationIsTurnedOnInTheIni() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ini = root.appendingPathComponent("OnlineFix.ini")
        try Data("[Main]\nRealAppId=1\n\n[Misc]\nExtraProtection=false\n".utf8).write(to: ini)

        #expect(FixApply.enablePhotonIntegration(at: ini))

        let text = try String(contentsOf: ini, encoding: .utf8)
        #expect(text.contains("[Misc]\nPhotonIntegration=true"))
        #expect(text.contains("ExtraProtection=false"))
        #expect(!FixApply.enablePhotonIntegration(at: ini))

        // An ini with no [Misc] gets one.
        try Data("[Main]\nRealAppId=1\n".utf8).write(to: ini)
        #expect(FixApply.enablePhotonIntegration(at: ini))
        let withoutMisc = try String(contentsOf: ini, encoding: .utf8)
        #expect(withoutMisc.contains("[Misc]\nPhotonIntegration=true"))

        // A value already there but off is replaced, not duplicated: two keys would
        // leave whichever one the payload reads last deciding the answer.
        try Data("[Main]\nRealAppId=1\n\n[Misc]\nPhotonIntegration=false\nExtraProtection=false\n"
            .utf8).write(to: ini)
        #expect(FixApply.enablePhotonIntegration(at: ini))
        let replaced = try String(contentsOf: ini, encoding: .utf8)
        #expect(replaced.contains("PhotonIntegration=true"))
        #expect(!replaced.lowercased().contains("photonintegration=false"))
        #expect(replaced.components(separatedBy: "PhotonIntegration").count == 2)
        #expect(replaced.contains("ExtraProtection=false"))
        #expect(!FixApply.enablePhotonIntegration(at: ini))
    }

    /// The Steam-auth route keeps the game's own Photon app and leaves OnlineFix's
    /// chain out. The switch has to go off in place, not leave a second key behind.
    @Test
    func photonIntegrationIsTurnedOffForTheSteamAuthRoute() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ini = root.appendingPathComponent("OnlineFix.ini")
        try Data("[Main]\nRealAppId=1\n\n[Misc]\nPhotonIntegration=true\nExtraProtection=false\n"
            .utf8).write(to: ini)

        #expect(FixApply.disablePhotonIntegration(at: ini))

        let text = try String(contentsOf: ini, encoding: .utf8)
        #expect(text.contains("PhotonIntegration=false"))
        #expect(!text.lowercased().contains("photonintegration=true"))
        #expect(text.components(separatedBy: "PhotonIntegration").count == 2)
        #expect(text.contains("ExtraProtection=false"))
        #expect(!FixApply.disablePhotonIntegration(at: ini))

        // Absent already means off; there is nothing to write.
        try Data("[Main]\nRealAppId=1\n".utf8).write(to: ini)
        #expect(!FixApply.disablePhotonIntegration(at: ini))
    }

    /// A package can carry an ini from another game. A key that is present but
    /// wrong is replaced in place, and a missing key is added under [Main].
    @Test
    func appIDsAreReplacedWhenTheyAreWrong() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ini = root.appendingPathComponent("OnlineFix.ini")
        try Data("[Main]\r\n  RealAppId = 123\r\nFakeAppId=480\r\n\r\n[Misc]\r\n"
            .utf8).write(to: ini)

        #expect(FixApply.setAppIDs(at: ini, appID: 42))
        let text = try String(contentsOf: ini, encoding: .utf8)
        #expect(text.contains("  RealAppId=42\r\n"))
        #expect(!text.contains("123"))
        #expect(!FixApply.setAppIDs(at: ini, appID: 42))

        try Data("[Main]\n".utf8).write(to: ini)
        #expect(FixApply.setAppIDs(at: ini, appID: 42))
        let added = try String(contentsOf: ini, encoding: .utf8)
        #expect(added.contains("RealAppId=42"))
        #expect(added.contains("FakeAppId=480"))
    }
}
