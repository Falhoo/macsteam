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
        let version = versionKey(of: bundle)
        cacheLock.lock()
        let cached = stateCache[bundle.path]
        cacheLock.unlock()
        if let cached, cached.version == version { return cached.state }
        let state = readState(of: bundle)
        cacheLock.lock()
        stateCache[bundle.path] = (version, state)
        cacheLock.unlock()
        return state
    }

    /// The answers already worked out, so a sheet redraw does not read 26 MB again.
    private static let cacheLock = NSLock()
    private static var stateCache: [String: (version: String, state: State)] = [:]

    /// A change to any file the id can live in, or to the code, gives a new key.
    private static func versionKey(of app: URL) -> String {
        let paths = [binaryPath,
                     dataPath + "/resources.assets",
                     dataPath + "/il2cpp_data/Metadata/global-metadata.dat"]
        return paths.map { path -> String in
            let url = app.appendingPathComponent(path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            return String(Int(date))
        }.joined(separator: "-")
    }

    private static func readState(of bundle: URL) -> State {
        let binary = bundle.appendingPathComponent(binaryPath)
        guard let binaryData = data(at: binary) else {
            return State(bundle: bundle, message: "This PICO PARK 2 build does not have the "
                + "files the fix changes, so it was left alone.")
        }
        let ids = idFiles(in: bundle)
        let patchedID = !ids.onlineFix.isEmpty
        let stockID = !ids.stock.isEmpty
        let patchedCode = code(at: binaryData) == patchedCode
        let stockInstruction = code(at: binaryData) == stockCode
        var state = State(bundle: bundle)
        state.isPatched = patchedID && patchedCode
        state.canPatch = (patchedID || stockID) && (stockInstruction || patchedCode)
        if !state.canPatch {
            state.message = "This PICO PARK 2 build is not the one the fix was worked out "
                + "against, so its files were not touched. A game update usually means this."
        }
        return state
    }

    // MARK: - Apply

    /// Turns the fix on or off, and reports the files written.
    ///
    /// `sign` is the re-signing step, so a test can run the file work without a real
    /// Mach-O bundle.
    @discardableResult
    static func setEnabled(_ on: Bool, app: URL,
                           sign: (URL) throws -> Void = resign) throws -> [String] {
        let binary = app.appendingPathComponent(binaryPath)
        guard let binaryData = data(at: binary) else {
            throw ManagerError("The files PICO PARK 2's fix changes are missing from "
                + "\(app.lastPathComponent). Reinstall the game in Steam and try again.")
        }
        var written: [String] = []

        if on {
            let ids = idFiles(in: app)
            if !ids.stock.isEmpty {
                for file in ids.stock {
                    let patched = PhotonPatch.replacing(file.data, old: file.id, new: photonAppID)
                    guard patched != file.data else { continue }
                    try backUp(file.url)
                    try write(patched, to: file.url)
                    written.append(file.url.path)
                }
            } else if ids.onlineFix.isEmpty {
                throw ManagerError("This PICO PARK 2 build does not carry the Photon app "
                    + "id the fix replaces, so nothing was changed.")
            }
            if code(at: binaryData) != patchedCode {
                guard let start = instructionOffset(in: binaryData) else {
                    throw ManagerError("This PICO PARK 2 build's code is not the one the fix "
                        + "was worked out against, so nothing was changed.")
                }
                try backUp(binary)
                var patched = binaryData
                patched.replaceSubrange(start..<(start + stockCode.count),
                                        with: patchedCode)
                try write(patched, to: binary)
                written.append(binary.path)
            }
        } else {
            for file in backupFiles(in: app) {
                try write(data(at: file) ?? Data(), to: original(of: file))
                try? Paths.fm.removeItem(at: file)
                written.append(original(of: file).path)
            }
        }

        guard !written.isEmpty else { return [] }
        // The bundle's own seal covers both files, so it is signed again inner to outer.
        try sign(binary)
        try sign(app)
        cacheLock.lock()
        stateCache[app.path] = nil
        cacheLock.unlock()
        return written
    }

    /// Re-signs a patched bundle the way the fix's original does: ad-hoc, with the
    /// identifier macOS expects for the game's code.
    static func resign(_ url: URL) throws {
        let isBinary = url.pathExtension.lowercased() == "dylib"
        var args = ["--force", "--sign", "-"]
        if isBinary { args += ["--identifier", "GameAssembly"] }
        args += ["--timestamp=none", url.path]
        let out = Shell.run("/usr/bin/codesign", args)
        guard out.code == 0 else {
            throw ManagerError("The game was patched, but signing it again failed, so macOS "
                + "will not run it: \(out.err.isEmpty ? out.out : out.err)")
        }
    }

    // MARK: - The id, wherever the build keeps it

    private struct IDFile {
        let url: URL
        let data: Data
        /// The stock id this file carries.
        let id: String
    }

    private struct IDFiles {
        var stock: [IDFile] = []
        var onlineFix: [URL] = []
    }

    /// Files the id can live in, read once: the data folder's serialized assets and
    /// the IL2CPP metadata, which is where 1.0.7 moved it to.
    private static func idFiles(in app: URL) -> IDFiles {
        let stockIDs = PhotonPatch.knownStockIDs.map { Data($0.utf8) }
        let onlineFixID = Data(photonAppID.utf8)
        var found = IDFiles()
        for url in candidateFiles(in: app) {
            guard let data = data(at: url) else { continue }
            for (index, stock) in stockIDs.enumerated() where data.range(of: stock) != nil {
                found.stock.append(IDFile(url: url, data: data,
                                          id: PhotonPatch.knownStockIDs[index]))
            }
            if data.range(of: onlineFixID) != nil { found.onlineFix.append(url) }
        }
        return found
    }

    /// The data files worth reading for an app id: serialized assets and the metadata,
    /// not the multi-megabyte streaming payloads beside them.
    private static func candidateFiles(in app: URL) -> [URL] {
        let folder = app.appendingPathComponent(dataPath, isDirectory: true)
        let readable: Set<String> = ["assets", "dat", "bundle", "json", "txt", "ini"]
        var out: [URL] = []
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(backupSuffix) || name.hasSuffix(PhotonPatch.backupSuffix) { continue }
            guard readable.contains(url.pathExtension.lowercased()) || name == "globalgamemanagers"
            else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= PhotonPatch.maxFileSize
            else { continue }
            out.append(url)
        }
        return out
    }

    // MARK: - Files

    private static func data(at url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func code(at data: Data) -> [UInt8]? {
        guard let start = instructionOffset(in: data) else { return nil }
        return Array(data[start..<(start + stockCode.count)])
    }

    /// Where the instruction sits in this copy of the dylib, or nil when the code
    /// around it is not the one the fix was worked out against.
    static func instructionOffset(in data: Data) -> Int? {
        guard let found = data.range(of: Data(codeBefore)) else { return nil }
        let start = found.lowerBound + codeBefore.count
        let end = start + stockCode.count + codeAfter.count
        guard end <= data.count,
              data.subdata(in: (start + stockCode.count)..<end) == Data(codeAfter)
        else { return nil }
        return start
    }

    private static func original(of backup: URL) -> URL {
        URL(fileURLWithPath: String(backup.path.dropLast(backupSuffix.count)))
    }

    /// Every untouched copy this made, in the data folder and the binary.
    private static func backupFiles(in app: URL) -> [URL] {
        var out: [URL] = []
        let binary = app.appendingPathComponent(binaryPath)
        if Paths.fm.fileExists(atPath: binary.path + backupSuffix) {
            out.append(URL(fileURLWithPath: binary.path + backupSuffix))
        }
        let folder = app.appendingPathComponent(dataPath, isDirectory: true)
        guard let enumerator = Paths.fm.enumerator(at: folder,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.hasSuffix(backupSuffix) { out.append(url) }
        }
        return out
    }

    private static func backUp(_ url: URL) throws {
        let copy = URL(fileURLWithPath: url.path + backupSuffix)
        guard !Paths.fm.fileExists(atPath: copy.path) else { return }
        try Paths.fm.copyItem(at: url, to: copy)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
