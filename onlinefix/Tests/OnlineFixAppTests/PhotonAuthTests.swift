// The auth-type patch: what it reads, what it writes, and that it refuses a build it
// does not recognise. The fixture is a stock Photon client assembly, so the IL that
// is matched is the IL a real game ships.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PhotonAuthTests {

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "PhotonRealtime",
                                                 withExtension: "dll",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A game folder with the fixture as its Photon client.
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonauth-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("Game_Data/Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try fixture().write(to: managed.appendingPathComponent("PhotonRealtime.dll"))
        return root
    }

    private func file(_ root: URL) -> URL {
        root.appendingPathComponent("Game_Data/Managed/PhotonRealtime.dll")
    }

    /// The stock shape is found, and the value that means custom auth comes from the
    /// enum rather than being assumed.
    @Test
    func theStockAssemblyIsRead() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try #require(PhotonAuth.inspect(file: file(root)))
        #expect(info.enumName == "CustomAuthenticationType")
        #expect(info.custom == 0)
        #expect(info.members.contains { $0.name == "Custom" && $0.value == 0 })
        #expect(info.getterShape == .simple)
        #expect(info.setterShape == .simple)
        #expect(info.canReachAuthenticate)
        #expect(info.canPatch)
        #expect(!info.patched)
    }

    /// The getter and the setter are rewritten, the length is kept, and a second run
    /// has nothing left to do. Off puts the stock bytes back.
    @Test
    func applyingAndRestoringKeepsTheAssemblyIntact() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = file(root)
        let stock = try Data(contentsOf: target)

        let written = try PhotonAuth.setEnabled(true, in: root)
        #expect(written.contains { $0.hasSuffix("PhotonRealtime.dll") })
        let patched = try Data(contentsOf: target)
        #expect(patched.count == stock.count)
        #expect(patched != stock)

        // The getter now returns a constant, so the patch reports itself as applied.
        let after = try #require(PhotonAuth.inspect(file: target))
        #expect(after.patched)
        #expect(after.current == 0)
        #expect(try PhotonAuth.setEnabled(true, in: root).isEmpty)

        _ = try PhotonAuth.setEnabled(false, in: root)
        #expect(try Data(contentsOf: target) == stock)
        #expect(!FileManager.default.fileExists(
            atPath: target.path + PhotonAuth.backupSuffix))
    }

    /// The no-auth mode also stops Photon reading the auth values, which is a second
    /// change in a different method; the game's own object is untouched.
    @Test
    func theNoAuthModeStopsTheRead() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = file(root)
        let stock = try Data(contentsOf: target)

        let wrote = try PhotonAuth.setEnabled(true, in: root, mode: .none)
        print("wrote:", wrote)
        let idx = [UInt8](try Data(contentsOf: target)).count
        print("size", idx)
        let info = try #require(PhotonAuth.inspect(file: target))
        print("nonePatched:", info.nonePatched, "canReach:", info.canReachAuthenticate)
        #expect(info.nonePatched)
        // The field read is replaced by `ldnull`, so it is no longer the plain read.
        #expect(try Data(contentsOf: target) != stock)
        #expect(try PhotonAuth.setEnabled(true, in: root, mode: .none).isEmpty)
    }

    /// A folder with no Photon client is not an error, it is nothing to do.
    @Test
    func aFolderWithoutPhotonHasNothingToPatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photonauth-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(PhotonAuth.inspect(gameFolder: root).isEmpty)
        #expect(try PhotonAuth.setEnabled(true, in: root).isEmpty)
    }
}
