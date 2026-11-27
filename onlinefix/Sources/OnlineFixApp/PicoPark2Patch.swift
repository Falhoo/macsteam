// PICO PARK 2's Photon fix, for the native macOS build.
//
// The game's online play runs on Photon Quantum, not on Steam, so nothing macSteam
// does to Steam's AppID can make it connect. What the game needs is OnlineFix's
// Photon app, and on a Mac build there is no DLL to inject that: the app is a signed
// Mach-O bundle. The fix is therefore made to the game's own files, in two changes:
//
//  1. The Photon app id the game connects to is replaced with OnlineFix's. It is a
//     64-character string, and which file carries it depends on the build: up to
//     1.0.6 it is in `resources.assets`, 1.0.7 keeps it in the IL2CPP string table
//     inside `il2cpp_data/Metadata/global-metadata.dat`. The whole data folder is
//     therefore read and the id is swapped wherever it is found.
//  2. `GameAssembly.dylib` caps a session: `mov w8, #1` (one player) is rewritten to
//     `mov w8, #255`. The instruction is at a fixed offset in the build this was
//     worked out against.
//
// Both changes are checked against the bytes that are expected before anything is
// written, so a game build that does not match is refused rather than corrupted, and
// the untouched files are kept beside them for "off".
//
// The same file changes cannot be made to the Windows build: its `GameAssembly.dll`
// is a different instruction set, and its fix has to happen in memory, which is what
// OnlineFix's own DLLs do.
//
// This file is the game's profile in `MacBundlePatch`, which does the file work for
// any Mac build; the constants here name the bytes this one carries.
import Foundation

enum PicoPark2Patch {

    /// Steam's macOS build of the game.
    static let bundleID = "com.tecopark.picopark2"

    /// Where the two changes live inside the bundle.
    static let dataPath = "Contents/Resources/Data"
    static let binaryPath = "Contents/Frameworks/GameAssembly.dylib"

    /// The Photon app id a stock build carries, and the one OnlineFix's Photon app
    /// answers on. Both are 64 characters, so a swap keeps every file its own size.
    static let stockAppID = PhotonPatch.knownStockIDs[0]
    static let photonAppID = PhotonPatch.onlineFixQuantumID

    /// The instruction the fix rewrites, and the code that sits around it in the stock
    /// build. Signing the dylib again rewrites its signature and moves everything after
    /// the header by a whole number of pages, so the instruction is found by the code
    /// beside it rather than by an offset. `codeOffset` is where it sits before the
    /// build is signed again.
    static let codeOffset = 0x402_E7D4
    static let stockCode: [UInt8] = [0x28, 0x00, 0x80, 0x52]     // mov w8, #1
    static let patchedCode: [UInt8] = [0xE8, 0x1F, 0x80, 0x52]   // mov w8, #255
    static let codeBefore: [UInt8] = [
        0xD9, 0x8D, 0x60, 0x94, 0xB4, 0x02, 0x00, 0xB4, 0xE1, 0x03, 0x00, 0xAA,
        0x95, 0x89, 0x01, 0xF0, 0xB5, 0xA2, 0x14, 0x91, 0xE0, 0x03, 0x14, 0xAA,
        0x01, 0x0C, 0x03, 0xF8, 0x36, 0xF8, 0xF7, 0x97,
    ]
    static let codeAfter: [UInt8] = [
        0x88, 0x42, 0x00, 0x39, 0x62, 0x32, 0x40, 0xF9, 0xA1, 0x02, 0x40, 0xF9,
        0x88, 0x02, 0x40, 0xF9, 0x09, 0x8D, 0x5A, 0xA9, 0xE0, 0x03, 0x14, 0xAA,
        0x20, 0x01, 0x3F, 0xD6,
    ]

    static let backupSuffix = ".onlinefix-picopark2-backup"

    /// The game's entry in the general Mac patch engine.
    static var profile: MacBundlePatch.Profile {
        MacBundlePatch.Profile(
            bundleID: bundleID,
            appIDs: [2644470],
            name: "PICO PARK 2",
            backupSuffix: backupSuffix,
            codePatches: [
                MacBundlePatch.CodePatch(
                    name: "the session limit",
                    file: binaryPath,
                    before: codeBefore,
                    stock: stockCode,
                    patched: patchedCode,
                    after: codeAfter),
            ])
    }

    // MARK: - State

    struct State: Equatable, Sendable {
        /// The bundle this is about, or nil when the Mac build is not installed.
        var bundle: URL?
        /// True when both files carry the fix.
        var isPatched = false
        /// True when the bundle is there and its files are the ones this knows.
        var canPatch = false
        /// What to say instead of the switch, when it cannot be used.
        var message: String?
    }

    /// What the switch should show for a game folder.
    static func state(in gameFolder: URL?) -> State {
        guard let folder = gameFolder,
              let bundle = FixInstaller.nativeMacBundle(in: folder) else {
            return State(message: "This fix is for the Mac version of PICO PARK 2. In Steam, "
                + "open the game's Properties, Compatibility, turn off the forced Windows "
                + "version, and let Steam install the Mac build first.")
        }
        let general = MacBundlePatch.state(of: bundle)
        return State(bundle: bundle, isPatched: general.isPatched,
                     canPatch: general.canPatch, message: general.message)
    }

    // MARK: - Apply

    /// Turns the fix on or off, and reports the files written.
    @discardableResult
    static func setEnabled(_ on: Bool, app: URL,
                           sign: (URL) throws -> Void = resign) throws -> [String] {
        try MacBundlePatch.setEnabled(on, app: app, sign: sign)
    }

    /// Re-signs a patched bundle the way the fix's original does: ad-hoc, with the
    /// identifier macOS expects for the game's code.
    static func resign(_ url: URL) throws {
        try PhotonPatch.resign(url)
    }

    /// Where the instruction sits in this copy of the dylib, or nil when the code
    /// around it is not the one the fix was worked out against.
    static func instructionOffset(in data: Data) -> Int? {
        MacBundlePatch.instructionOffset(in: data, patch: profile.codePatches[0])
    }
}
