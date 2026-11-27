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

    /// The files the other serialization and engine formats keep settings in. A Unity
    /// text asset is the one that also names its fields.
    @Test
    func settingsFilesOfOtherFormatsAreRead() {
        let root = URL(fileURLWithPath: "/tmp/game")
        for name in ["PhotonServerSettings.asset", "appsettings.json", "DefaultEngine.ini",
                     "photon.cfg", "settings.yaml", "PhotonAppSettings.bytes"] {
            #expect(PhotonPatch.isReadable(root.appendingPathComponent(name)))
        }
        // A bulky blob is only read while it is small enough to be settings.
        #expect(PhotonPatch.sizeAllows(root.appendingPathComponent("PhotonAppSettings.bytes"),
                                      size: 4_000))
        #expect(!PhotonPatch.sizeAllows(root.appendingPathComponent("settings.bin"),
                                       size: 64 * 1024 * 1024))
        #expect(PhotonPatch.sizeAllows(root.appendingPathComponent("global-metadata.dat"),
                                      size: 64 * 1024 * 1024))
    }
}

/// A project saved with Unity's text serialization writes `PhotonServerSettings.asset`
/// as YAML, with the field names spelled out. Before this was read, such a game had no
/// candidate at all: its ids are not length-prefixed, and the field names are the only
/// thing that says which field is which.
@Suite
struct PhotonTextSettingsTests {

    private let realtime = "2be03cc8-3633-4033-a22e-7ef1c243b1fd"
    private let voice = "ba60e90a-af6f-4965-80cf-ff783c91c992"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func asset(realtime: String, voice: String) -> Data {
        Data("""
        %YAML 1.1
        %TAG !u! tag:unity3d.com,2011:
        --- !u!114 &11400000
        MonoBehaviour:
          m_Script: {fileID: 11500000, guid: 8d4e1e5f, type: 3}
          AppIdRealtime: \(realtime)
          AppIdVoice: \(voice)
          AppVersion: 4.1
        """.utf8)
    }

    @Test
    func aTextAssetNamesItsFields() {
        let found = PhotonPatch.textSettings(in: asset(realtime: realtime, voice: voice))
        #expect(found.map(\.id) == [realtime, voice])
        #expect(found.map(\.field) == ["appidrealtime", "appidvoice"])
    }

    @Test
    func aPairIsOrderedByNameAcrossTwoFiles() throws {
        // Both values in separate assets, which field order alone cannot order.
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try asset(realtime: realtime, voice: "").write(to: root.appendingPathComponent("a.asset"))
        let second = root.appendingPathComponent("b.asset")
        try asset(realtime: voice, voice: "").write(to: second)
        // Rewrite the second file's field so it is the voice one.
        var text = String(decoding: try Data(contentsOf: second), as: UTF8.self)
        text = text.replacingOccurrences(of: "AppIdRealtime", with: "AppIdVoice")
        try Data(text.utf8).write(to: second)

        let plan = PhotonPatch.plan(for: PhotonPatch.scan(in: root))
        #expect(plan.skipped == nil)
        #expect(plan.id == realtime)
        #expect(plan.voiceID == voice)
    }

    @Test
    func thePairIsPatched() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("PhotonServerSettings.asset")
        try asset(realtime: realtime, voice: voice).write(to: file)

        let report = PhotonPatch.autoPatch(in: root, sign: { _ in })
        // The enumerator spells a temp path `/private/var`, the caller `/var`.
        #expect(report.written.map { GameScan.canonical(URL(fileURLWithPath: $0)) }
            == [GameScan.canonical(file)])
        let after = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(after.contains("AppIdRealtime: \(PhotonIDs.realtime)"))
        #expect(after.contains("AppIdVoice: \(PhotonIDs.voice)"))
        #expect(!after.contains(realtime))
    }

    /// A line that only looks like a field, and a value that is not an id.
    @Test
    func nonFieldsAndNonIdsAreIgnored() {
        let text = Data("""
          m_AppIdRealtime: nope
          AppIdRealtime: 9551e103-6003-43b6-9415-d4ff80eefaea
        """.utf8)
        let found = PhotonPatch.textSettings(in: text)
        #expect(found.map(\.id) == ["9551e103-6003-43b6-9415-d4ff80eefaea"])
    }
}

/// An id is stored two ways and both count. A Mono assembly keeps its strings as
/// UTF-16, so an ASCII-only check called a correctly patched assembly "changed" and a
/// repair kept trying to put it back.
@Suite
struct PhotonEncodingsTests {
    @Test
    func bothEncodingsAreSeen() {
        let id = "80449c66-0a91-49a5-acb6-ca805e84e605"
        let wide = Data(id.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        #expect(PhotonPatch.carries(Data(("x" + id + "y").utf8), id: id))
        #expect(PhotonPatch.carries(wide, id: id))
        #expect(!PhotonPatch.carries(Data("nothing".utf8), id: id))
    }
}
