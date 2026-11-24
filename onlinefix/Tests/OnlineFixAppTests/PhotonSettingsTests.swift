// The two shapes a real Photon game uses, taken from R.E.P.O. and PEAK: a
// PhotonServerSettings asset whose values are length-prefixed GUIDs, and a Mono
// assembly that stores the same GUID as UTF-16.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonSettingsTests {

    private let repoID = "9551e103-6003-43b6-9415-d4ff80eefaea"
    private let peakRealtime = "2be03cc8-3633-4033-a22e-7ef1c243b1fd"
    private let peakVoice = "ba60e90a-af6f-4965-80cf-ff783c91c992"
    private let productGUID = "cad66cca-38eb-40ea-9058-136819ea55b2"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func wide(_ text: String) -> Data {
        Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    /// `PhotonServerSettings`, then each id as a 32-bit length of 36 and its bytes.
    private func settings(_ ids: [String]) -> Data {
        var data = Data("PhotonServerSettings".utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        for id in ids {
            data.append(contentsOf: [0x24, 0, 0, 0])
            data.append(Data(id.utf8))
            data.append(contentsOf: [0, 0, 0, 0])
        }
        return data
    }

    /// R.E.P.O. sets both fields to the same id. A global replace would give both
    /// the realtime id; the pair has to be written field by field.
    @Test
    func aRepeatedPairIsPatchedByPosition() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("resources.assets")
        try settings([repoID, repoID]).write(to: file)

        let plan = PhotonPatch.plan(for: PhotonPatch.scan(in: root))
        #expect(plan.changes.count == 2)
        #expect(plan.id == repoID)
        #expect(plan.voiceID == repoID)

        let report = PhotonPatch.autoPatch(in: root, sign: { _ in })
        #expect(report.replaced == repoID)
        #expect(report.voiceReplaced == repoID)

        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains(repoID))
        #expect(text.contains(PhotonIDs.realtime))
        #expect(text.contains(PhotonIDs.voice))
        let first = text.range(of: PhotonIDs.realtime)!.lowerBound
        let second = text.range(of: PhotonIDs.voice)!.lowerBound
        #expect(first < second)
    }

    /// PEAK's two fields differ, and the first is the realtime app.
    @Test
    func aDifferentPairKeepsRealtimeAndVoiceInOrder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("resources.assets")
        try settings([peakRealtime, peakVoice]).write(to: file)

        _ = PhotonPatch.autoPatch(in: root, sign: { _ in })
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains(peakRealtime))
        #expect(!text.contains(peakVoice))
        #expect(text.range(of: PhotonIDs.realtime)!.lowerBound
            < text.range(of: PhotonIDs.voice)!.lowerBound)
    }

    /// A game's `productGUID` is a length-prefixed GUID too, and `globalgamemanagers`
    /// can mention the settings class elsewhere. Only the values right after the
    /// class name are Photon ids: the old rule patched this product id instead.
    @Test
    func aProductGUIDIsNotAPhotonID() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data("public.app-category.games".utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0x24, 0, 0, 0])
        data.append(Data(productGUID.utf8))
        data.append(0)
        data.append(Data(repeating: 0x41, count: 700))
        data.append(Data("PhotonServerSettings".utf8))
        try data.write(to: root.appendingPathComponent("globalgamemanagers"))

        #expect(PhotonPatch.ids(in: data).contains { $0.id == productGUID })
        #expect(PhotonPatch.scan(in: root).isEmpty)
    }

    /// A Mono assembly writes its strings as UTF-16, so the scanner has to match the
    /// marker and the id in that encoding, and the write has to keep it.
    @Test
    func aUTF16IDIsFoundAndPatched() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Assembly-CSharp.dll")
        try wide("Photon - Set AppId \(repoID)").write(to: file)

        let found = PhotonPatch.scan(in: root)
        #expect(found.map(\.id) == [repoID])
        #expect(found.first?.offset == wide("Photon - Set AppId ").count)

        let report = PhotonPatch.autoPatch(in: root, sign: { _ in })
        #expect(report.replaced == repoID)
        let after = try Data(contentsOf: file)
        #expect(after.range(of: wide(repoID)) == nil)
        #expect(after.range(of: wide(PhotonIDs.realtime)) != nil)
    }

    /// Resource blobs are most of a Unity game's size and hold no settings, so they
    /// are not read; `global-metadata.dat` still is.
    @Test
    func resourceBlobsAreNotReadButMetadataIs() {
        let root = URL(fileURLWithPath: "/tmp/game")
        #expect(!PhotonPatch.isReadable(root.appendingPathComponent("resources.resource")))
        #expect(PhotonPatch.isReadable(root.appendingPathComponent("resources.assets")))
        #expect(PhotonPatch.isReadable(root.appendingPathComponent("globalgamemanagers")))
        #expect(PhotonPatch.isReadable(root.appendingPathComponent("global-metadata.dat")))
        #expect(!PhotonPatch.isReadable(root.appendingPathComponent("cache.dat")))
    }
}
