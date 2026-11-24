import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonIDsTests {

    private func game() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonids-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("REPO_Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let asset = "start-\(PhotonIDs.realtime)-mid-\(PhotonIDs.voice)-end"
        try Data(asset.utf8).write(to: data.appendingPathComponent("resources.assets"))
        return root
    }

    private func text(_ folder: URL) throws -> String {
        String(decoding: try Data(contentsOf:
            folder.appendingPathComponent("REPO_Data/resources.assets")), as: UTF8.self)
    }

    @Test
    func replacesTheIDsAndRestoresThem() throws {
        let folder = try game()
        defer { try? FileManager.default.removeItem(at: folder) }
        let realtime = "11111111-2222-3333-4444-555555555555"
        let voice = "66666666-7777-8888-9999-aaaaaaaaaaaa"

        let written = try PhotonIDs.apply(gameFolder: folder, realtime: realtime, voice: voice)
        #expect(written.count == 1)
        #expect(written.first?.hasSuffix("REPO_Data/resources.assets") == true)
        var patched = try text(folder)
        #expect(patched.contains(realtime))
        #expect(patched.contains(voice))
        #expect(!patched.contains(PhotonIDs.realtime))
        #expect(FileManager.default.fileExists(atPath:
            folder.appendingPathComponent("REPO_Data/resources.assets.onlinefix-photon-backup").path))

        // A second edit works from the untouched file, not from the patched one.
        let other = "12121212-3434-5656-7878-909090909090"
        _ = try PhotonIDs.apply(gameFolder: folder, realtime: other, voice: "")
        patched = try text(folder)
        #expect(patched.contains(other))
        #expect(patched.contains(PhotonIDs.voice))   // empty voice means the default

        // Clearing both puts the default file back.
        _ = try PhotonIDs.apply(gameFolder: folder, realtime: "", voice: "")
        #expect(try text(folder).contains(PhotonIDs.realtime))
        #expect(try text(folder).contains(PhotonIDs.voice))
        #expect(!FileManager.default.fileExists(atPath:
            folder.appendingPathComponent("REPO_Data/resources.assets.onlinefix-photon-backup").path))
    }

    /// R.E.P.O.'s two fields can hold the same value. Rebuilding the file from the
    /// untouched copy and replacing one value would put that value back in the voice
    /// field on every refresh.
    @Test
    func aPairHoldingTheSameValueKeepsBothFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonpair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("REPO_Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var blob = Data("PhotonServerSettings".utf8)
        blob.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        for _ in 0..<2 {
            blob.append(contentsOf: [0x24, 0, 0, 0])
            blob.append(Data(PhotonIDs.realtime.utf8))
            blob.append(contentsOf: [0, 0, 0, 0])
        }
        let file = data.appendingPathComponent("resources.assets")
        try blob.write(to: file)

        let realtime = "11111111-2222-3333-4444-555555555555"
        let voice = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        _ = try PhotonIDs.apply(gameFolder: root, realtime: realtime, voice: voice)
        var text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.components(separatedBy: realtime).count - 1 == 1)
        #expect(text.components(separatedBy: voice).count - 1 == 1)
        #expect(!text.contains(PhotonIDs.realtime))

        // The refresh sees the pair already carrying the wanted ids.
        #expect(throws: Error.self) {
            _ = try PhotonIDs.apply(gameFolder: root, realtime: realtime, voice: voice)
        }
        text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.components(separatedBy: realtime).count - 1 == 1)
        #expect(text.components(separatedBy: voice).count - 1 == 1)
    }

    @Test
    func refusesWhatItCannotPatch() throws {
        let folder = try game()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: Error.self) {
            _ = try PhotonIDs.apply(gameFolder: folder, realtime: "not-a-guid", voice: "")
        }
        #expect(throws: Error.self) {
            _ = try PhotonIDs.apply(gameFolder: folder, realtime: PhotonIDs.realtime,
                                    voice: PhotonIDs.realtime)
        }
        #expect(!PhotonIDs.isGUID("99515094"))
        #expect(PhotonIDs.isGUID(PhotonIDs.realtime))
    }
}
