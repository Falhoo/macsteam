import Foundation
import Testing
@testable import OnlineFixApp

/// Re-signing a game bundle must keep the hardened runtime and the entitlements it
/// already had. Steam injects its loader and overlay renderer into the game; a bundle
/// signed bare loses `disable-library-validation`, dyld then refuses them, and the
/// game sits on its first frame with a black window.
@Suite struct ResignKeepsSignatureTests {

    private func signedBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign-\(UUID().uuidString)", isDirectory: true)
        let macos = root.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        // Entitlements only embed in a Mach-O, so the fixture is a real binary.
        let binary = macos.appendingPathComponent("Game")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        let plist = root.appendingPathComponent("Game.app/Contents/Info.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.game</string>
        <key>CFBundleExecutable</key><string>Game</string>
        </dict></plist>
        """.utf8).write(to: plist)
        let entitlements = root.appendingPathComponent("ent.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """.utf8).write(to: entitlements)
        let out = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime",
                                                 "--entitlements", entitlements.path, root.appendingPathComponent("Game.app").path])
        try #require(out.code == 0, "signing the fixture failed: \(out.err)")
        return root.appendingPathComponent("Game.app")
    }

    @Test func entitlementsAndRuntimeSurvive() throws {
        let bundle = try signedBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        try PhotonPatch.resign(bundle)

        let details = Shell.run("/usr/bin/codesign", ["-d", "--verbose=2", bundle.path])
        #expect((details.out + details.err).contains("runtime"))
        let kept = Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path])
        #expect(kept.out.contains("disable-library-validation"))
        #expect(Shell.run("/usr/bin/codesign", ["--verify", "--strict", bundle.path]).code == 0)
    }
}
