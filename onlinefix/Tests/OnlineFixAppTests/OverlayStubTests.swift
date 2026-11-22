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

        #expect(PhotonSupport.enablePhotonIntegration(at: ini))

        let text = try String(contentsOf: ini, encoding: .utf8)
        #expect(text.contains("[Misc]\nPhotonIntegration=true"))
        #expect(text.contains("ExtraProtection=false"))
        #expect(!PhotonSupport.enablePhotonIntegration(at: ini))

        // An ini with no [Misc] gets one.
        try Data("[Main]\nRealAppId=1\n".utf8).write(to: ini)
        #expect(PhotonSupport.enablePhotonIntegration(at: ini))
        let withoutMisc = try String(contentsOf: ini, encoding: .utf8)
        #expect(withoutMisc.contains("[Misc]\nPhotonIntegration=true"))
    }
}
