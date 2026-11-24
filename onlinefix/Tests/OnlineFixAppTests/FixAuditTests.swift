import Foundation
import Testing
@testable import OnlineFixApp

@Suite("FixAuditTests")
struct FixAuditTests {

    /// The package is installed, then one file from each part of the fix is taken
    /// away and the two text files are put back to a state an older fix would leave.
    /// The audit has to read the result, not the package, and plan every repair.
    @Test
    func anIncompleteInstallIsRepaired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(
            at: game.appendingPathComponent("Game_Data/Managed", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        func write(_ text: String, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", game.appendingPathComponent("Game.exe"))
        try write("... WINHTTP.dll ...", game.appendingPathComponent("UnityPlayer.dll"))
        try write("managed", game.appendingPathComponent("Game_Data/Managed/PhotonRealtime.dll"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("door", package.appendingPathComponent("winmm.dll"))
        try write("[Main]\nRealAppId=100\nFakeAppId=480\nPhotonIntegration=true\n",
                  package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\nCustom.net\n", package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 100, name: "Game")
        let read = FixPackage.read(root: package)
        let plan = FixPlan.build(appID: 100, name: "Game", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        _ = try FixApply.apply(plan, appID: 100, folder: game)

        // A partial copy, a package file the game had and lost, and a loader list and
        // ini from before the Photon patch was added.
        try FileManager.default.removeItem(
            at: game.appendingPathComponent("OnlineFix64.dll"))
        try FileManager.default.removeItem(
            at: game.appendingPathComponent("BepInEx/core/BepInEx.dll"))
        let ini = game.appendingPathComponent("OnlineFix.ini")
        var iniText = try String(contentsOf: ini, encoding: .utf8)
        iniText = iniText.replacingOccurrences(of: "PhotonIntegration=true\n", with: "")
        try Data(iniText.utf8).write(to: ini)
        let list = game.appendingPathComponent("dlllist.txt")
        // Empty, the way a Steam verify or an older uninstall can leave it.
        try Data("".utf8).write(to: list)

        let now = GameScan.read(folder: game, appID: 100, name: "Game")
        let audit = FixAudit.run(appID: 100, name: "Game", scan: now, package: read,
                                 installed: plan, expectedAPI: nil)
        #expect(audit.changed)
        #expect(!audit.blocking)
        #expect(audit.plan.copies.contains { $0.relative == "OnlineFix64.dll" })
        #expect(audit.plan.copies.contains { $0.relative == "BepInEx/core/BepInEx.dll" })
        #expect(audit.plan.edits.contains { $0.kind == .iniPhotonIntegration })
        #expect(audit.plan.edits.contains { $0.kind == .dllListEntries })
        #expect(audit.findings.filter { $0.code == "OF100" }.count >= 2)
        #expect(audit.findings.contains { $0.code == "OF109" })
        #expect(audit.findings.contains { $0.code == "OF110" })

        _ = try FixApply.apply(audit.plan, appID: 100, folder: game)
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("OnlineFix64.dll").path))
        #expect(FileManager.default.fileExists(
            atPath: game.appendingPathComponent("BepInEx/core/BepInEx.dll").path))
        #expect(try String(contentsOf: ini, encoding: .utf8).contains("PhotonIntegration=true"))
        #expect(try String(contentsOf: list, encoding: .utf8).contains("OnlineFix64.dll"))
        // The chain's Custom.dll is under BepInEx, where the preloader loads it.
        // dlllist.txt must not ask OnlineFix64 for a root Custom.net in that layout.
        #expect(!(try String(contentsOf: list, encoding: .utf8).contains("Custom.net")))
    }

    /// A package file that the game folder lost is not just copied back: the text
    /// edits that make it useful (app ids, PhotonIntegration, the loader list) have
    /// to be planned against the file that the copy will create.
    @Test
    func aMissingIniAndListAreFilledAfterTheyAreCopied() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        func write(_ text: String, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", game.appendingPathComponent("Game.exe"))
        try write("... WINMM.dll ...", game.appendingPathComponent("UnityPlayer.dll"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("plugin", package.appendingPathComponent("Custom.dll"))
        try write("[Main]\nPhotonIntegration=true\n",
                  package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 42, name: "Game")
        let read = FixPackage.read(root: package)
        let plan = FixPlan.build(appID: 42, name: "Game", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        _ = try FixApply.apply(plan, appID: 42, folder: game)
        let ini = game.appendingPathComponent("OnlineFix.ini")
        let list = game.appendingPathComponent("dlllist.txt")
        try FileManager.default.removeItem(at: ini)
        try FileManager.default.removeItem(at: list)

        let now = GameScan.read(folder: game, appID: 42, name: "Game")
        let audit = FixAudit.run(appID: 42, name: "Game", scan: now, package: read,
                                 installed: plan, expectedAPI: nil)
        #expect(audit.plan.copies.contains { $0.destination.lastPathComponent == "OnlineFix.ini" })
        #expect(audit.plan.copies.contains { $0.destination.lastPathComponent == "dlllist.txt" })
        #expect(audit.plan.edits.contains { $0.kind == .iniAppIDs })
        #expect(audit.plan.edits.contains { $0.kind == .iniPhotonIntegration })
        #expect(audit.plan.edits.contains { $0.kind == .dllListEntries })

        _ = try FixApply.apply(audit.plan, appID: 42, folder: game)
        let iniText = try String(contentsOf: ini, encoding: .utf8)
        let listText = try String(contentsOf: list, encoding: .utf8)
        #expect(iniText.contains("RealAppId=42"))
        #expect(iniText.contains("FakeAppId=480"))
        #expect(iniText.contains("PhotonIntegration=true"))
        #expect(listText.contains("OnlineFix64.dll"))
        #expect(!listText.contains("Custom.net"))
    }

    /// An ini can be present and still name another game. A wrong value is an
    /// inconsistency too, so the audit plans the same app-id edit as a missing one.
    @Test
    func aWrongIniAppIDIsCorrected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-appid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        func write(_ text: String, _ url: URL) throws {
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", game.appendingPathComponent("Game.exe"))
        try write("[Main]\nRealAppId=999\nFakeAppId=480\n",
                  game.appendingPathComponent("OnlineFix.ini"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("[Main]\nRealAppId=999\nFakeAppId=480\n",
                  package.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: game, appID: 42, name: "Game")
        let read = FixPackage.read(root: package)
        let audit = FixAudit.run(appID: 42, name: "Game", scan: scan, package: read,
                                 installed: FixPlan(), expectedAPI: nil)
        #expect(audit.plan.edits.contains { $0.kind == .iniAppIDs })
        _ = try FixApply.apply(audit.plan, appID: 42, folder: game)
        let text = try String(contentsOf: game.appendingPathComponent("OnlineFix.ini"),
                              encoding: .utf8)
        #expect(text.contains("RealAppId=42"))
        #expect(!text.contains("RealAppId=999"))
    }

    /// A package with no dlllist.txt at all still has to start its payload. The
    /// audit creates the list rather than only warning that it is missing.
    @Test
    func aMissingListIsCreatedFromThePayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-newlist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        func write(_ text: String, _ url: URL) throws {
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", game.appendingPathComponent("Game.exe"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("[Main]\nRealAppId=3\nFakeAppId=480\n",
                  package.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: game, appID: 3, name: "Game")
        let read = FixPackage.read(root: package)
        let plan = FixPlan.build(appID: 3, name: "Game", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        _ = try FixApply.apply(plan, appID: 3, folder: game)
        let list = game.appendingPathComponent("dlllist.txt")
        #expect(!FileManager.default.fileExists(atPath: list.path))

        let now = GameScan.read(folder: game, appID: 3, name: "Game")
        let audit = FixAudit.run(appID: 3, name: "Game", scan: now, package: read,
                                 installed: plan, expectedAPI: nil)
        #expect(audit.plan.edits.contains { $0.kind == .dllListEntries })
        #expect(audit.plan.copies.allSatisfy {
            $0.destination.lastPathComponent.lowercased() != "dlllist.txt"
        })

        _ = try FixApply.apply(audit.plan, appID: 3, folder: game)
        let text = try String(contentsOf: list, encoding: .utf8)
        #expect(text.contains("OnlineFix64.dll"))
    }

    /// A native Mac build takes no Windows files. The audit must not put the
    /// package's payload and list into the .app after the plan deliberately left it.
    @Test
    func aMacBuildGetsNoAuditFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-mac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(
            at: game.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: game.appendingPathComponent("Game.app/Contents/MacOS/Game"))
        try Data("payload".utf8).write(to: package.appendingPathComponent("OnlineFix64.dll"))
        try Data("[Main]\nRealAppId=1\nFakeAppId=480\n".utf8)
            .write(to: package.appendingPathComponent("OnlineFix.ini"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        #expect(scan.macBundle != nil)
        let audit = FixAudit.run(appID: 1, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package),
                                 installed: FixPlan(), expectedAPI: nil)
        #expect(!audit.changed)
        #expect(audit.plan.copies.isEmpty)
        #expect(audit.plan.edits.isEmpty)
    }

    /// A game that runs from a folder inside its install root keeps its BepInEx
    /// chain there. The audit must not copy a second chain to the root, where the
    /// game never loads it.
    @Test
    func aChainIsCheckedBesideTheExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-subfolder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        let launch = game.appendingPathComponent("Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("BepInEx/plugins", isDirectory: true),
            withIntermediateDirectories: true)

        func write(_ text: String, _ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", launch.appendingPathComponent("Game.exe"))
        try write("... WINHTTP.dll ...", launch.appendingPathComponent("UnityPlayer.dll"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("plugin", package.appendingPathComponent("BepInEx/plugins/Custom.dll"))
        try write("[Main]\nPhotonIntegration=true\n",
                  package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", package.appendingPathComponent("dlllist.txt"))

        let scan = GameScan.read(folder: game, appID: 7, name: "Game")
        #expect(scan.launchFolder.standardizedFileURL.path == launch.standardizedFileURL.path)
        let read = FixPackage.read(root: package)
        let plan = FixPlan.build(appID: 7, name: "Game", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        #expect(plan.copies.contains { $0.relative.hasPrefix("Binaries/Win64/BepInEx/") })
        _ = try FixApply.apply(plan, appID: 7, folder: game)

        let now = GameScan.read(folder: game, appID: 7, name: "Game")
        let audit = FixAudit.run(appID: 7, name: "Game", scan: now, package: read,
                                 installed: plan, expectedAPI: nil)
        // The chain is already beside the executable. The audit must not put a
        // second one at the install root, where the game never loads it.
        #expect(!audit.plan.copies.contains { $0.relative.hasPrefix("BepInEx/") })
    }

    /// A header that is a real enough PE for the architecture reader. Only the
    /// machine field matters here; imports and exports are empty.
    private func peHeader(machine: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        func u16(_ value: UInt16, _ offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func u32(_ value: UInt32, _ offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        u32(0x40, 0x3C)
        bytes[0x40] = 0x50
        bytes[0x41] = 0x45
        u16(machine, 0x44)
        u16(0, 0x46)
        u16(0xE0, 0x54)
        u16(0x2002, 0x56)
        u16(0x020B, 0x58)
        u32(0, 0x58 + 108)
        return Data(bytes)
    }

    /// A 32-bit payload cannot load in a 64-bit game, even when the package names
    /// the file OnlineFix.dll. The audit refuses it instead of copying it in.
    @Test
    func a32BitPayloadIsNotCopiedIntoA64BitGame() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-payload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try peHeader(machine: 0x8664).write(to: game.appendingPathComponent("Game.exe"))
        try peHeader(machine: 0x014C).write(to: package.appendingPathComponent("OnlineFix.dll"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        let read = FixPackage.read(root: package)
        let plan = FixPlan.build(appID: 1, name: "Game", scan: scan, package: read,
                                 diagnosis: FixDiagnosis.run(scan: scan, package: read))
        #expect(!plan.copies.contains {
            $0.destination.lastPathComponent.lowercased() == "onlinefix.dll"
        })
        let audit = FixAudit.run(appID: 1, name: "Game", scan: scan, package: read,
                                 installed: plan, expectedAPI: nil)
        #expect(audit.blocking)
        #expect(!audit.plan.copies.contains {
            $0.destination.lastPathComponent.lowercased() == "onlinefix.dll"
        })
    }

    /// The package has the matching copies, so the audit replaces a wrong-bit API
    /// and payload instead of only reporting that the game cannot load them.
    @Test
    func aWrongBitnessAPIAndPayloadAreReplaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-bits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        try peHeader(machine: 0x8664).write(to: game.appendingPathComponent("Game.exe"))
        try peHeader(machine: 0x014C).write(to: game.appendingPathComponent("steam_api64.dll"))
        try peHeader(machine: 0x014C).write(to: game.appendingPathComponent("OnlineFix64.dll"))
        try peHeader(machine: 0x8664).write(to: package.appendingPathComponent("steam_api64.dll"))
        try peHeader(machine: 0x8664).write(to: package.appendingPathComponent("OnlineFix64.dll"))

        let scan = GameScan.read(folder: game, appID: 1, name: "Game")
        let read = FixPackage.read(root: package)
        let audit = FixAudit.run(appID: 1, name: "Game", scan: scan, package: read,
                                 installed: FixPlan(), expectedAPI: nil)
        #expect(audit.findings.contains { $0.code == "OF101" })
        #expect(audit.plan.copies.contains {
            $0.destination.lastPathComponent == "steam_api64.dll"
        })
        #expect(audit.plan.copies.contains {
            $0.destination.lastPathComponent == "OnlineFix64.dll"
        })

        _ = try FixApply.apply(audit.plan, appID: 1, folder: game)
        #expect(PortableExecutable.read(game.appendingPathComponent("steam_api64.dll"))?
            .architecture == .x64)
        #expect(PortableExecutable.read(game.appendingPathComponent("OnlineFix64.dll"))?
            .architecture == .x64)
    }

    /// A routing fix leaves the loader out on purpose. The audit must not read the
    /// package and put the payload, proxies or Photon chain back.
    @Test
    func aRoutingFixIsNotTurnedBackIntoALoaderFix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        func write(_ text: String, _ url: URL) throws {
            try Data(text.utf8).write(to: url)
        }
        try write("MZ", game.appendingPathComponent("Game.exe"))
        try write("payload", package.appendingPathComponent("OnlineFix64.dll"))
        try write("[Main]\nPhotonIntegration=true\n", package.appendingPathComponent("OnlineFix.ini"))
        try write("OnlineFix64.dll\n", package.appendingPathComponent("dlllist.txt"))

        var routing = FixPlan()
        routing.keepGameAPI = true
        let scan = GameScan.read(folder: game, appID: 9, name: "Game")
        let audit = FixAudit.run(appID: 9, name: "Game", scan: scan,
                                 package: FixPackage.read(root: package),
                                 installed: routing, expectedAPI: nil)
        #expect(!audit.plan.copies.contains {
            FixPackage.payloadNames.contains($0.destination.lastPathComponent.lowercased())
        })
        #expect(audit.plan.edits.isEmpty)
        #expect(!audit.plan.photonSwap)
    }

    /// A non-PE fixture still names the doorway it loads, and the fallback is only
    /// asked for when the PE reader says the file is not a PE.
    @Test
    func aNonPEFileStillNamesItsDoorway() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixaudit-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("UnityPlayer.dll")
        try Data("... WINHTTP.dll ...".utf8).write(to: file)

        #expect(PortableExecutable.read(file) == nil)
        #expect(PortableExecutable.fallbackImports(in: file).contains("winhttp.dll"))
    }
}
