// CRLF is what OnlineFix's own archives use. Reading those lines with a whitespace
// trim leaves the carriage return behind, so a key that is already there looks
// missing and the file grows a duplicate section on every refresh.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonSupportTests {

    private func temporaryFile(_ text: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test
    func aCRLFIniDoesNotGainADuplicateSection() throws {
        let url = try temporaryFile("[Main]\r\nRealAppId=1\r\n\r\n[Misc]\r\nExtraProtection=false\r\n",
                                    name: "OnlineFix.ini")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PhotonSupport.enablePhotonIntegration(at: url))
        let once = try String(contentsOf: url, encoding: .utf8)
        #expect(once.components(separatedBy: "[Misc]").count == 2)
        #expect(once.components(separatedBy: "PhotonIntegration=true").count == 2)

        // Already on: nothing more is written.
        #expect(!PhotonSupport.enablePhotonIntegration(at: url))
        let twice = try String(contentsOf: url, encoding: .utf8)
        #expect(twice == once)
    }

    @Test
    func aCRLFDLLListIsNotGivenASecondCustomEntry() throws {
        let url = try temporaryFile("OnlineFix64.dll\r\nCustom.net\r\n", name: "dlllist.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!PhotonSupport.addCustomToDLLList(at: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "Custom.net").count == 2)

        let plain = try temporaryFile("OnlineFix64.dll\r\n", name: "dlllist.txt")
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(PhotonSupport.addCustomToDLLList(at: plain))
        #expect(try String(contentsOf: plain, encoding: .utf8).contains("Custom.net"))
    }
}
