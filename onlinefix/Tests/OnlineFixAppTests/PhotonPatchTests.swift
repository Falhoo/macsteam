// The generic Photon app id scanner and swapper, checked against stand-in game files
// so the byte work is exercised without a game.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonPatchTests {

    private let guid = "0f8c1e42-7d33-4b6a-9c21-5eb0a7f2d114"
    private var quantum: String { String(repeating: "A", count: 63) + "/" }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The scan reports the path it walked, which is /private/var/... rather than
        // the /var/... the temporary directory names.
        return url.resolvingSymlinksInPath()
    }

    /// A file shaped like a Unity assets file: the id next to the settings object's
    /// name, with other bytes around it.
    private func write(_ body: String, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    /// PEAK's shape: a Unity PhotonServerSettings asset stores each app id as a 32-bit
    /// length of 36 and then the GUID, with the class name written once and no field
    /// name beside any value. Nothing else in the file names Photon near the id.
    @Test
    func anAssetOfPhotonServerSettingsYieldsItsIDs() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        var blob = Data("PhotonServerSettings".utf8)
        blob.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        for id in [guid, "ba60e90a-af6f-4965-80cf-ff783c91c992"] {
            blob.append(contentsOf: [0x24, 0, 0, 0])
            blob.append(Data(id.utf8))
            blob.append(contentsOf: [0, 0, 0, 0])
        }
        blob.append(contentsOf: [0x03, 0, 0, 0])
        blob.append(Data("0.2".utf8))
        try blob.write(to: root.appendingPathComponent("resources.assets"))

        let ids = PhotonPatch.scan(in: root).map(\.id)
        #expect(ids.contains(guid))
        #expect(ids.contains("ba60e90a-af6f-4965-80cf-ff783c91c992"))
    }

    @Test
    func aGuidNextToPhotonIsFound() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("PhotonAppSettings\0\0\(guid)\0\0", named: "resources.assets", in: folder)

        let found = PhotonPatch.scan(in: folder)
        #expect(found.count == 1)
        #expect(found.first?.id == guid)
        #expect(found.first?.kind == .guid)
        #expect(found.first?.file.lastPathComponent == "resources.assets")
    }

    @Test
    func aQuantumIdInAnAssetsFileIsFound() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("\0QuantumUnityNativeAllocator\0\(quantum)\0", named: "resources.assets", in: folder)

        let found = PhotonPatch.scan(in: folder)
        #expect(found.map(\.id) == [quantum])
        #expect(found.first?.kind == .quantum)
    }

    /// An assets file carries thousands of GUIDs; only the one by something Photon
    /// names is the app id.
    @Test
    func aGuidWithNothingPhotonNearbyIsNotOffered() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let padding = String(repeating: "x", count: 400)
        try write(padding + guid + padding, named: "resources.assets", in: folder)

        #expect(PhotonPatch.ids(in: Data((padding + guid).utf8)).map(\.id) == [guid])
        #expect(PhotonPatch.scan(in: folder).isEmpty)
    }

    /// An IL2CPP build's metadata carries each assembly's own id beside the library's
    /// name, and those are not the game's Photon app id.
    @Test
    func anAssemblyIdBesideTheLibraryNameIsNotOffered() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("\0PhotonDeterministic\0\(guid)\0quantum.core\0",
                  named: "global-metadata.dat", in: folder)

        #expect(PhotonPatch.ids(in: Data(("\0PhotonDeterministic\0\(guid)").utf8)).count == 1)
        #expect(PhotonPatch.scan(in: folder).isEmpty)
    }

    /// OnlineFix's own ids are the ones a fix points the game at, so they are offered
    /// wherever they sit.
    @Test
    func anOnlineFixIdIsOfferedWithoutContext() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(String(repeating: "x", count: 300) + PhotonIDs.realtime,
                  named: "Assembly-CSharp.dll", in: folder)

        #expect(PhotonPatch.scan(in: folder).map(\.id) == [PhotonIDs.realtime])
    }

    /// A fix's own files carry Photon's strings too, and the copies this keeps beside
    /// a patched file must never be read as the game.
    @Test
    func fixFilesAndBackupsAreSkipped() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("PhotonAppSettings \(guid)", named: "winmm.dll", in: folder)
        try write("PhotonAppSettings \(guid)", named: "resources.assets", in: folder)
        try write("PhotonAppSettings \(guid)", named: "resources.assets" + PhotonPatch.backupSuffix,
                  in: folder)

        #expect(PhotonPatch.scan(in: folder).map(\.id) == [guid])
    }

    @Test
    func replaceSwapsEveryOccurrenceAndKeepsABackup() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = "99515094-45b7-4c98-ab70-a448c548c83d"
        let file = try write("PhotonAppSettings \(guid) and again \(guid)",
                             named: "resources.assets", in: folder)

        let written = try PhotonPatch.replace(guid, with: other, in: folder, sign: { _ in })
        #expect(written.map { ($0 as NSString).lastPathComponent } == ["resources.assets"])
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains(guid))
        #expect(text == "PhotonAppSettings \(other) and again \(other)")

        let backup = URL(fileURLWithPath: file.path + PhotonPatch.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains(guid))
        #expect(PhotonPatch.hasBackups(in: folder))
        #expect(PhotonPatch.scan(in: folder).map(\.id) == [other])
    }

    /// A pair can hold the same value in both fields, as R.E.P.O.'s does. A manual
    /// replace that treats it as one value writes the realtime id into the voice field.
    @Test
    func aManualReplaceKeepsTheTwoSettingsFieldsApart() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var blob = Data("PhotonServerSettings".utf8)
        blob.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        for _ in 0..<2 {
            blob.append(contentsOf: [0x24, 0, 0, 0])
            blob.append(Data(guid.utf8))
            blob.append(contentsOf: [0, 0, 0, 0])
        }
        let file = folder.appendingPathComponent("resources.assets")
        try blob.write(to: file)
        let voice = "ba60e90a-af6f-4965-80cf-ff783c91c992"

        _ = try PhotonPatch.replace(guid, with: voice, in: folder, sign: { _ in })
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.components(separatedBy: voice).count - 1 == 1)
        #expect(text.components(separatedBy: guid).count - 1 == 1)
    }

    @Test
    func aReplacementOfAnotherShapeIsRefused() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("PhotonAppSettings \(guid)", named: "resources.assets", in: folder)

        #expect(throws: ManagerError.self) {
            try PhotonPatch.replace(guid, with: "not-an-app-id", in: folder, sign: { _ in })
        }
        #expect(throws: ManagerError.self) {
            try PhotonPatch.replace(guid, with: quantum, in: folder, sign: { _ in })
        }
        #expect(try PhotonPatch.replace(guid, with: guid, in: folder, sign: { _ in }).isEmpty)
    }

    /// A file shaped like an IL2CPP `global-metadata.dat`: the header, the literal
    /// table, and the blob the literals are packed into with nothing between them, so
    /// each one is glued to its neighbours the way a real build's are.
    @discardableResult
    private func metadata(_ literals: [String], named name: String = "global-metadata.dat",
                          in folder: URL, mentionsPhoton: Bool = true) throws -> URL {
        var blob = Data()
        var entries: [(length: UInt32, start: UInt32)] = []
        for literal in literals + (mentionsPhoton ? ["PhotonQuantum"] : []) {
            let bytes = Data(literal.utf8)
            entries.append((UInt32(bytes.count), UInt32(blob.count)))
            blob.append(bytes)
        }
        let tableStart = 32
        var header = Data()
        for value in [UInt32(0xFAB1_1BAF), 29,
                      UInt32(tableStart), UInt32(entries.count * 8),
                      UInt32(tableStart + entries.count * 8), UInt32(blob.count), 0, 0] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        var table = Data()
        for entry in entries {
            for value in [entry.length, entry.start] {
                withUnsafeBytes(of: value.littleEndian) { table.append(contentsOf: $0) }
            }
        }
        let url = folder.appendingPathComponent(name)
        try (header + table + blob).write(to: url)
        return url
    }

    /// R.E.P.O.'s stock pair belongs to R.E.P.O., not to OnlineFix's shared app.
    /// Treating it as shared made the auto-patch replace the game's own ids.
    @Test
    func repoStockPairIsNotOnlineFixShared() {
        for id in [PhotonIDs.realtime, PhotonIDs.voice] {
            let candidate = PhotonPatch.Candidate(
                file: URL(fileURLWithPath: "/tmp/photon"), id: id,
                kind: .guid, settings: true)
            #expect(candidate.isOnlineFixShared == false)
        }
    }

    /// A build whose id sits in the IL2CPP string table, glued to its neighbours: the
    /// 64-character run rule cannot see it, so the known id is matched by its bytes.
    @Test
    func aKnownStockIDInsideAStringTableIsFound() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("1E1F1\(PhotonPatch.knownStockIDs[0])1ms22.02.0",
                  named: "global-metadata.dat", in: folder)

        let found = PhotonPatch.scan(in: folder)
        #expect(found.map(\.id) == [PhotonPatch.knownStockIDs[0]])
        #expect(found.first?.kind == .quantum)
        #expect(found.first?.isOnlineFixShared == false)
    }

    /// A Quantum id nobody wrote down is found through the literal table, which is what
    /// a game that has never been patched before needs.
    @Test
    func aQuantumIDInAStringTableIsFoundWithoutBeingKnown() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = String(repeating: "Qx7", count: 21) + "/"
        #expect(!PhotonPatch.knownStockIDs.contains(id))
        try metadata(["ms1E1F", id, "1DAxis"], in: folder)

        let found = PhotonPatch.scan(in: folder)
        #expect(found.map(\.id) == [id])
        #expect(found.first?.kind == .quantum)
        #expect(found.first?.isOnlineFixShared == false)
        #expect(found.first?.file.lastPathComponent == "global-metadata.dat")
    }

    /// A Mac build keeps its metadata inside its `.app`, seven folders down. It is
    /// found there too, which is what the deep search is for.
    @Test
    func aMacBundleMetadataIsScannedThroughItsBundle() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = String(repeating: "Qx7", count: 21) + "/"
        let relative = "pico_park_2.app/Contents/Resources/Data/il2cpp_data/Metadata"
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(relative), withIntermediateDirectories: true)
        try metadata(["ms1E1F", id, "1DAxis"],
                     named: "\(relative)/global-metadata.dat", in: folder)

        #expect(PhotonPatch.scan(in: folder).map(\.id) == [id])
    }

    /// The automatic patch replaces that id, leaves its neighbours alone, and stops
    /// once the game carries OnlineFix's id.
    @Test
    func autoPatchReplacesAQuantumIDItWasNotToldAbout() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = String(repeating: "Qx7", count: 21) + "/"
        let file = try metadata(["ms1E1F", id, "1DAxis"], in: folder)

        let report = PhotonPatch.autoPatch(in: folder, sign: { _ in })
        #expect(report.replaced == id)
        #expect(report.written.map { ($0 as NSString).lastPathComponent } == ["global-metadata.dat"])

        let data = try Data(contentsOf: file)
        #expect(data.range(of: Data(("ms1E1F" + PhotonPatch.onlineFixQuantumID
            + "1DAxis").utf8)) != nil)

        let again = PhotonPatch.autoPatch(in: folder, sign: { _ in })
        #expect(again.written.isEmpty)
        #expect(again.replaced == nil)
        #expect(again.skipped == nil)
    }

    /// The base64 alphabet is 64 characters of the same stuff and is not an app id.
    @Test
    func theBase64AlphabetIsNotTakenForAnAppID() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try metadata(["ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"],
                     in: folder)

        #expect(PhotonPatch.scan(in: folder).isEmpty)
    }

    /// A 64-character literal in a file that never names Photon is something else, and
    /// is left alone.
    @Test
    func aQuantumLiteralInAFileWithoutPhotonIsNotOffered() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = String(repeating: "Qx7", count: 21) + "/"
        try metadata(["ms1E1F", id, "1DAxis"], in: folder, mentionsPhoton: false)

        #expect(PhotonPatch.scan(in: folder).isEmpty)
    }

    /// The automatic pass replaces it with OnlineFix's app, and only once.
    @Test
    func autoPatchReplacesTheGamesIDOnce() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("1E1F1\(PhotonPatch.knownStockIDs[0])1ms22.02.0",
                             named: "global-metadata.dat", in: folder)

        let report = PhotonPatch.autoPatch(in: folder, sign: { _ in })
        #expect(report.replaced == PhotonPatch.knownStockIDs[0])
        #expect(report.written.map { ($0 as NSString).lastPathComponent } == ["global-metadata.dat"])
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text == "1E1F1\(PhotonPatch.onlineFixQuantumID)1ms22.02.0")

        let again = PhotonPatch.autoPatch(in: folder, sign: { _ in })
        #expect(again.written.isEmpty)
        #expect(again.replaced == nil)
        #expect(again.skipped == nil)
    }

    /// Two different ids are left to the player: which one the game connects to
    /// cannot be told from the files.
    @Test
    func autoPatchRefusesTwoDifferentIDs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("PhotonAppSettings \(guid)", named: "resources.assets", in: folder)
        try write("PhotonAppSettings 11111111-2222-3333-4444-555555555555",
                  named: "global-metadata.dat", in: folder)

        let report = PhotonPatch.autoPatch(in: folder, sign: { _ in })
        #expect(report.written.isEmpty)
        #expect(report.skipped?.contains("different Photon app ids") == true)
    }

    @Test
    func restorePutsTheGameFilesBack() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = "99515094-45b7-4c98-ab70-a448c548c83d"
        let file = try write("PhotonAppSettings \(guid)", named: "resources.assets", in: folder)
        try write("\0QuantumUnityNativeAllocator\0\(quantum)", named: "globalgamemanagers",
                  in: folder)

        _ = try PhotonPatch.replace(guid, with: other, in: folder, sign: { _ in })
        _ = try PhotonPatch.replace(quantum, with: String(repeating: "B", count: 63) + "+",
                                    in: folder, sign: { _ in })
        #expect(PhotonPatch.scan(in: folder).map(\.id).sorted() != [guid, quantum].sorted())

        let restored = try PhotonPatch.restore(in: folder, sign: { _ in })
        #expect(restored.count == 2)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(guid))
        #expect(!PhotonPatch.hasBackups(in: folder))
        #expect(PhotonPatch.scan(in: folder).map(\.id).sorted() == [guid, quantum].sorted())
    }
}
