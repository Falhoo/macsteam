// Patching a native macOS build: the Photon app id any Unity build carries, and the
// per-game code a profile names. These use stand-in bundles so the file work is
// exercised without a game, and the PICO PARK 2 profile as the worked example.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct MacBundlePatchTests {

    private let guid = "0f8c1e42-7d33-4b6a-9c21-5eb0a7f2d114"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macpatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    /// A Mac game whose Photon settings sit in a Unity asset, the way R.E.P.O. and
    /// PEAK store them: the class name once, then each app id as a length-prefixed
    /// string. This is what a Mac build of such a game looks like inside its bundle.
    private func guidBundle(in root: URL, id: String? = nil) throws -> URL {
        let app = root.appendingPathComponent("PhotonGame.app", isDirectory: true)
        let data = app.appendingPathComponent("Contents/Resources/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var blob = Data("PhotonServerSettings".utf8)
        blob.append(contentsOf: [UInt8](repeating: 0, count: 8))
        blob.append(contentsOf: [0x24, 0, 0, 0])
        blob.append(Data((id ?? guid).utf8))
        blob.append(contentsOf: [0, 0, 0, 0])
        try blob.write(to: data.appendingPathComponent("resources.assets"))
        return app
    }

    /// A Mac bundle with no Photon content at all.
    private func emptyBundle(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Plain.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Plain"))
        return app
    }

    /// The PICO PARK 2 Mac build's shape: the stock Photon app id in a data file and
    /// the code the profile changes, without an Info.plist, so the bundle is
    /// recognised by the code it carries.
    private func picoBundle(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("PICO PARK 2.app", isDirectory: true)
        let metadata = app.appendingPathComponent(
            PicoPark2Patch.dataPath + "/il2cpp_data/Metadata/global-metadata.dat")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(("1E1F1" + PicoPark2Patch.stockAppID + "1ms22.02.0").utf8).write(to: metadata)
        let binary = app.appendingPathComponent(PicoPark2Patch.binaryPath)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 0x1000)
        data.append(contentsOf: PicoPark2Patch.codeBefore)
        data.append(contentsOf: PicoPark2Patch.stockCode)
        data.append(contentsOf: PicoPark2Patch.codeAfter)
        try data.write(to: binary)
        return app
    }

    private func text(_ url: URL) -> String {
        (try? String(decoding: Data(contentsOf: url), as: UTF8.self)) ?? ""
    }

    private func dataFile(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/Resources/Data/resources.assets")
    }

    /// The scanner reports the resolved path, while the temporary directory names an
    /// unresolved one (`/var/...` against `/private/var/...`), so written paths are
    /// compared by their tail.
    private func wrote(_ written: [String], _ file: URL) -> Bool {
        written.count == 1 && (written[0] as NSString).lastPathComponent
            == file.lastPathComponent
    }

    // MARK: - The Photon id, for any Mac build

    /// Any Mac build whose Photon id can be read gets OnlineFix's app, with no game
    /// named in the code: this is the generic half of the fix.
    @Test
    func aGuidGameInAMacBuildIsSwapped() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try guidBundle(in: root)
        let file = dataFile(app)

        let state = MacBundlePatch.state(of: app)
        #expect(state.canPatch)
        #expect(!state.isPatched)
        #expect(state.photonIDs.contains(guid))

        var signed: [URL] = []
        let written = try MacBundlePatch.setEnabled(true, app: app, sign: { signed.append($0) })

        #expect(wrote(written, file))
        #expect(text(file).contains(PhotonIDs.realtime))
        #expect(!text(file).contains(guid))
        // The bundle's seal covers the changed file, so it is signed again.
        #expect(signed.contains { $0.standardizedFileURL == app.standardizedFileURL })
        #expect(MacBundlePatch.state(of: app).isPatched)
    }

    /// On again after on writes nothing: the file already carries the fix.
    @Test
    func aSecondPassWritesNothing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try guidBundle(in: root)
        try MacBundlePatch.setEnabled(true, app: app, sign: { _ in })

        #expect(try MacBundlePatch.setEnabled(true, app: app, sign: { _ in }).isEmpty)
    }

    /// Off puts the game's own id back and drops the untouched copy.
    @Test
    func offRestoresTheGamesOwnID() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try guidBundle(in: root)
        let file = dataFile(app)
        try MacBundlePatch.setEnabled(true, app: app, sign: { _ in })

        let written = try MacBundlePatch.setEnabled(false, app: app, sign: { _ in })

        #expect(wrote(written, file))
        #expect(text(file).contains(guid))
        #expect(!text(file).contains(PhotonIDs.realtime))
        #expect(!FileManager.default.fileExists(
            atPath: file.path + PhotonPatch.backupSuffix))
    }

    /// A Mac build with no Photon id is left alone, and says why.
    @Test
    func aBuildWithNoPhotonIDIsNotOffered() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try emptyBundle(in: root)

        let state = MacBundlePatch.state(of: app)
        #expect(!state.canPatch)
        #expect(state.message?.contains("no Photon app id") == true)
    }

    // MARK: - A game the profiles know

    /// PICO PARK 2's build is recognised by the code it carries even without an
    /// Info.plist, and both of its changes are applied.
    @Test
    func aKnownBuildIsPatchedByIdAndCode() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try picoBundle(in: root)

        #expect(MacBundlePatch.profile(for: app)?.name == "PICO PARK 2")
        let state = MacBundlePatch.state(of: app)
        #expect(state.canPatch)
        #expect(!state.isPatched)

        let written = try MacBundlePatch.setEnabled(true, app: app, sign: { _ in })
        #expect(written.count == 2)
        #expect(text(app.appendingPathComponent(
            PicoPark2Patch.dataPath + "/il2cpp_data/Metadata/global-metadata.dat"))
            .contains(PicoPark2Patch.photonAppID))
        let binary = try Data(contentsOf: app.appendingPathComponent(PicoPark2Patch.binaryPath))
        let start = try #require(PicoPark2Patch.instructionOffset(in: binary))
        #expect(Array(binary[start..<(start + 4)]) == PicoPark2Patch.patchedCode)
        #expect(MacBundlePatch.state(of: app).isPatched)
    }

    /// The game is found by the AppID the manager knows it as, which is what the
    /// install uses before it has read the bundle.
    @Test
    func theAppIDFindsTheProfile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try emptyBundle(in: root)

        #expect(MacBundlePatch.profile(for: app) == nil)
        #expect(MacBundlePatch.profile(appID: 2644470, bundle: app)?.name == "PICO PARK 2")
        #expect(MacBundlePatch.profile(appID: 1, bundle: app) == nil)
    }

    /// A game whose bundle identifier is in the profiles is found by it, even when
    /// its files match none of the code the profile changes.
    @Test
    func theBundleIdentifierFindsTheProfile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try emptyBundle(in: root)
        let plist: [String: Any] = ["CFBundleIdentifier": PicoPark2Patch.bundleID]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                     format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        #expect(MacBundlePatch.profile(for: app)?.name == "PICO PARK 2")
    }
}

/// The auth-type patch is part of the Mac fix for a game nobody owns: the bundle's
/// Photon assembly is changed like the Windows one, and undone with the rest.
@Suite
struct MacBundleAuthPatchTests {

    private func bundle() throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: "PhotonRealtime",
                                                    withExtension: "dll",
                                                    subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macauth-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("PhotonGame.app", isDirectory: true)
        let managed = app.appendingPathComponent("Contents/Resources/Data/Managed",
                                                isDirectory: true)
        let assets = app.appendingPathComponent("Contents/Resources/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: managed.appendingPathComponent("PhotonRealtime.dll"))
        var blob = Data("PhotonServerSettings".utf8)
        blob.append(contentsOf: [UInt8](repeating: 0, count: 8))
        blob.append(contentsOf: [0x24, 0, 0, 0])
        blob.append(Data("0f8c1e42-7d33-4b6a-9c21-5eb0a7f2d114".utf8))
        try blob.write(to: assets.appendingPathComponent("resources.assets"))
        return app
    }

    @Test
    func theAuthTypeIsWrittenAndUndone() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let assembly = app.appendingPathComponent(
            "Contents/Resources/Data/Managed/PhotonRealtime.dll")

        let written = try MacBundlePatch.setEnabled(true, app: app, auth: .custom, sign: { _ in })
        #expect(written.contains { $0.hasSuffix("PhotonRealtime.dll") })
        let info = try #require(PhotonAuth.inspect(file: assembly))
        #expect(info.patched)

        let undone = try MacBundlePatch.setEnabled(false, app: app, sign: { _ in })
        #expect(undone.contains { $0.hasSuffix("PhotonRealtime.dll") })
        let after = try #require(PhotonAuth.inspect(file: assembly))
        #expect(!after.patched)
        #expect(!FileManager.default.fileExists(
            atPath: assembly.path + PhotonAuth.backupSuffix))
    }

    /// Without the mode nothing about auth is touched, which is what an owned game or
    /// a non-Photon build needs.
    @Test
    func noModeLeavesTheAuthTypeAlone() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let assembly = app.appendingPathComponent(
            "Contents/Resources/Data/Managed/PhotonRealtime.dll")

        _ = try MacBundlePatch.setEnabled(true, app: app, sign: { _ in })
        #expect(!PhotonAuth.inspect(file: assembly)!.patched)
    }
}
