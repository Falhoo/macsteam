// The two file changes PICO PARK 2's Photon fix makes, checked against a stand-in
// bundle so the file work is exercised without the game.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PicoPark2PatchTests {

    /// Where the code sits in the stand-in binary. Anywhere will do: the fix finds the
    /// instruction by the code around it, since signing the dylib moves it.
    private let anchor = 0x1000

    /// The build's id as it sits in the game: glued to its neighbours in the IL2CPP
    /// string table, which is why a plain 64-character run does not find it.
    private var metadataText: String {
        "1E1F1" + PicoPark2Patch.stockAppID + "1ms22.02.0"
    }

    /// A bundle shaped like the game's: the metadata carrying the stock Photon app id,
    /// and a binary with the stock instruction and the code around it.
    private func game(idFile: String = "il2cpp_data/Metadata/global-metadata.dat",
                      idText: String? = nil) throws -> (folder: URL, app: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pico-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("PICO PARK 2.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        let data = app.appendingPathComponent(PicoPark2Patch.dataPath + "/" + idFile)
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((idText ?? metadataText).utf8).write(to: data)

        let code = app.appendingPathComponent(PicoPark2Patch.binaryPath)
        try FileManager.default.createDirectory(at: code.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try binary().write(to: code)
        return (folder, app)
    }

    /// A binary with the patch site where the fix expects to find it.
    private func binary(instruction: [UInt8] = PicoPark2Patch.stockCode,
                        shift: Int = 0) -> Data {
        var data = Data(repeating: 0, count: anchor + shift)
        data.append(contentsOf: PicoPark2Patch.codeBefore)
        data.append(contentsOf: instruction)
        data.append(contentsOf: PicoPark2Patch.codeAfter)
        data.append(Data(repeating: 0, count: 64))
        return data
    }

    private func idFileText(_ app: URL, at path: String) throws -> String {
        String(decoding: try Data(contentsOf: app.appendingPathComponent(path)), as: UTF8.self)
    }

    private func code(_ app: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: app.appendingPathComponent(PicoPark2Patch.binaryPath))
        guard let start = PicoPark2Patch.instructionOffset(in: data) else { return [] }
        return Array(data[start..<(start + PicoPark2Patch.stockCode.count)])
    }

    /// Both changes land, and the untouched files are kept beside them.
    @Test
    func turningItOnPatchesTheIDAndTheCode() throws {
        let (_, app) = try game()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let written = try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })
        #expect(written.count == 2)
        let text = try idFileText(app, at: PicoPark2Patch.dataPath
                                  + "/il2cpp_data/Metadata/global-metadata.dat")
        #expect(text.contains(PicoPark2Patch.photonAppID))
        #expect(!text.contains(PicoPark2Patch.stockAppID))
        #expect(text.hasPrefix("1E1F1"))
        #expect(text.hasSuffix("1ms22.02.0"))
        #expect(try code(app) == PicoPark2Patch.patchedCode)
        #expect(FileManager.default.fileExists(
            atPath: app.appendingPathComponent(PicoPark2Patch.binaryPath
                                               + PicoPark2Patch.backupSuffix).path))
    }

    /// An older build keeps the id in `resources.assets` instead, and is patched too.
    @Test
    func anOlderBuildIsPatchedWhereItKeepsTheID() throws {
        let (_, app) = try game(idFile: "resources.assets")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        _ = try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })
        let text = try idFileText(app, at: PicoPark2Patch.dataPath + "/resources.assets")
        #expect(text.contains(PicoPark2Patch.photonAppID))
    }

    /// A second "on" writes nothing: the files already carry the fix.
    @Test
    func turningItOnTwiceIsANoOp() throws {
        let (_, app) = try game()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })

        #expect(try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in }).isEmpty)
    }

    /// Signing the dylib again moves its code, and the fix still finds the instruction
    /// and reads the bundle as patched.
    @Test
    func theCodeIsFoundAfterSigningMovesIt() throws {
        let (folder, app) = try game()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })

        // What codesign does to the file: everything after the header shifts.
        let binaryURL = app.appendingPathComponent(PicoPark2Patch.binaryPath)
        try binary(instruction: PicoPark2Patch.patchedCode, shift: 0x4000).write(to: binaryURL)

        #expect(try code(app) == PicoPark2Patch.patchedCode)
        let state = PicoPark2Patch.state(in: folder)
        #expect(state.isPatched)
        #expect(try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in }).isEmpty)
    }

    /// Off puts the stock bytes back and drops the backups.
    @Test
    func turningItOffRestoresTheStockFiles() throws {
        let (_, app) = try game()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })

        let written = try PicoPark2Patch.setEnabled(false, app: app, sign: { _ in })
        #expect(written.count == 2)
        let text = try idFileText(app, at: PicoPark2Patch.dataPath
                                  + "/il2cpp_data/Metadata/global-metadata.dat")
        #expect(text.contains(PicoPark2Patch.stockAppID))
        #expect(try code(app) == PicoPark2Patch.stockCode)
        #expect(!FileManager.default.fileExists(
            atPath: app.appendingPathComponent(PicoPark2Patch.binaryPath
                                               + PicoPark2Patch.backupSuffix).path))
    }

    /// A build this was not worked out against is refused rather than half patched.
    @Test
    func anotherBuildIsLeftAlone() throws {
        let (_, app) = try game(idText: "header something else entirely")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(throws: ManagerError.self) {
            try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })
        }
        #expect(try code(app) == PicoPark2Patch.stockCode)
    }

    /// The switch says what is wrong instead of offering itself.
    @Test
    func theStateExplainsAMissingMacBuild() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pico-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let state = PicoPark2Patch.state(in: folder)
        #expect(!state.canPatch)
        #expect(state.message?.contains("Mac version") == true)
    }

    /// A patched bundle reads as patched, so the switch starts on.
    @Test
    func theStateSeesAnAppliedFix() throws {
        let (folder, app) = try game()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PicoPark2Patch.setEnabled(true, app: app, sign: { _ in })

        let state = PicoPark2Patch.state(in: folder)
        #expect(state.canPatch)
        #expect(state.isPatched)
        #expect(state.message == nil)
    }
}
