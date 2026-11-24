// Reading a fix package before anything is put into a game.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct FixPackageTests {

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test
    func readsTheRolesOfASteamworksPackage() throws {
        let root = try folder("steam")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("api", to: root.appendingPathComponent("steam_api64.dll"))
        try write("payload", to: root.appendingPathComponent("OnlineFix64.dll"))
        try write("doorstop", to: root.appendingPathComponent("winmm.dll"))
        try write("overlay", to: root.appendingPathComponent("SteamOverlay64.dll"))
        try write("[Main]\nRealAppId=10\nFakeAppId=480\n",
                  to: root.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", to: root.appendingPathComponent("dlllist.txt"))

        let package = FixPackage.read(root: root, archiveName: "fix.rar")
        #expect(package.archiveName == "fix.rar")
        #expect(package.carriesPayload)
        #expect(package.hasOverlay)
        #expect(!package.hasPhotonChain)
        #expect(!package.isGDK)
        #expect(package.iniKeys.contains("realappid"))
        #expect(package.dllList == ["OnlineFix64.dll"])
        #expect(package.apiItem(needs64: true)?.name == "steam_api64.dll")
        #expect(package.apiItem(needs64: false) == nil)
    }

    /// A Mac archive brings resource forks and Finder litter along. None of it is a
    /// fix file, and copying it would put `__MACOSX` into the game.
    @Test
    func archiveJunkIsNotAFixFile() throws {
        let root = try folder("junk")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("payload", to: root.appendingPathComponent("OnlineFix64.dll"))
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n",
                  to: root.appendingPathComponent("OnlineFix.ini"))
        try write("fork", to: root.appendingPathComponent("__MACOSX/._OnlineFix64.dll"))
        try write("fork", to: root.appendingPathComponent("._steam_api64.dll"))
        try write("finder", to: root.appendingPathComponent(".DS_Store"))
        try write("finder", to: root.appendingPathComponent("BepInEx/.DS_Store"))
        try write("windows", to: root.appendingPathComponent("Thumbs.db"))

        let package = FixPackage.read(root: root)
        #expect(package.names == ["onlinefix.ini", "onlinefix64.dll"])
        #expect(FixPackage.isJunk("__MACOSX/._OnlineFix64.dll"))
        #expect(FixPackage.isJunk("sub/._file"))
        #expect(!FixPackage.isJunk("OnlineFix64.dll"))
    }

    @Test
    func aPhotonPackageCarriesTheChainWithoutAGameRootAssumption() throws {
        let root = try folder("photon")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("doorstop", to: root.appendingPathComponent("winmm.dll"))
        try write("preloader", to: root.appendingPathComponent("BepInEx/core/BepInEx.Preloader.dll"))
        try write("plugin", to: root.appendingPathComponent("Custom.dll"))
        try write("payload", to: root.appendingPathComponent("OnlineFix64.dll"))

        let package = FixPackage.read(root: root)
        #expect(package.hasPhotonChain)
        #expect(package.chainItems.map(\.name).sorted()
            == ["bepinex.preloader.dll", "custom.dll", "winmm.dll"])
        #expect(FixPackage.isChainPath("BepInEx/core/BepInEx.Preloader.dll"))
        #expect(!FixPackage.isChainPath("Custom.dll"))
    }

    @Test
    func aMicrosoftStorePackageIsRecognised() throws {
        let gdk = try folder("gdk")
        defer { try? FileManager.default.removeItem(at: gdk) }
        try write("helper", to: gdk.appendingPathComponent("GDK_Helper.bat"))
        try write("payload", to: gdk.appendingPathComponent("OnlineFix64.dll"))
        #expect(FixPackage.read(root: gdk).isGDK)

        let packaged = try folder("packaged")
        defer { try? FileManager.default.removeItem(at: packaged) }
        try write("[Main]\nIsPackaged=false\nProductId = 9NMKF7LPVX44\n",
                  to: packaged.appendingPathComponent("OnlineFix.ini"))
        #expect(FixPackage.read(root: packaged).isGDK)

        let plain = try folder("plain")
        defer { try? FileManager.default.removeItem(at: plain) }
        try write("[Main]\nRealAppId=1\nFakeAppId=480\n",
                  to: plain.appendingPathComponent("OnlineFix.ini"))
        #expect(!FixPackage.read(root: plain).isGDK)
    }
}
