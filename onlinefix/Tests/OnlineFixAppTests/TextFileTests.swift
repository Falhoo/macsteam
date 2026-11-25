import Foundation
import Testing
@testable import OnlineFixApp

@Suite("TextFileTests")
struct TextFileTests {

    /// An OnlineFix.ini from a Windows archive can be UTF-16. Read as UTF-8 it
    /// looks like one line of NUL bytes, so every key looks missing and the edit
    /// grows a second section. The keys have to be found, and the file has to stay
    /// in the encoding it arrived in.
    @Test
    func aUTF16IniIsReadAndKeptUTF16() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("textfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("OnlineFix.ini")
        let original = "[Main]\r\nRealAppId=1\r\nFakeAppId=2\r\n"
        let body = try #require(original.data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + body).write(to: url)

        let content = try #require(TextFile.read(url))
        #expect(content.encoding == .utf16LittleEndian)
        #expect(content.hasBOM)
        #expect(content.text.contains("RealAppId=1"))

        #expect(FixApply.setAppIDs(at: url, appID: 42))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.starts(with: [0xFF, 0xFE]))
        let repaired = try #require(TextFile.read(url))
        #expect(repaired.encoding == .utf16LittleEndian)
        #expect(repaired.text.contains("RealAppId=42"))
        #expect(repaired.text.contains("FakeAppId=480"))
        #expect(!repaired.text.contains("RealAppId=1\r\n"))
        // One [Main], not a second one inserted above the first.
        #expect(repaired.text.components(separatedBy: "[Main]").count == 2)
    }

    /// A UTF-8 byte-order mark is part of the file, not the first key. It is
    /// preserved when the list or ini is edited.
    @Test
    func aUTF8MarkIsNotPartOfTheFirstKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("textfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dlllist.txt")
        let text = "OnlineFix64.dll\nSteamOverlay64.dll"
        let body = try #require(text.data(using: .utf8))
        try (TextFile.utf8BOM + body).write(to: url)

        let content = try #require(TextFile.read(url))
        #expect(content.text == text)
        #expect(content.hasBOM)
        #expect(FixApply.ensureDLLListEntries(["Custom.dll"], at: url))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(TextFile.read(url)?.text.contains("Custom.dll") == true)
    }

    /// A file that cannot be read is nil, not empty text that looks like a file
    /// with every key absent.
    @Test
    func aMissingFileIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("textfile-\(UUID().uuidString)")
        #expect(TextFile.read(url) == nil)
    }
}