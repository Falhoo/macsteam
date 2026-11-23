// Finding, and replacing, a game's Photon app id.
//
// A game whose online play runs on Photon keeps an app id somewhere in its own
// files: a GUID in a Mono assembly or an assets file (R.E.P.O., Phasmophobia), a
// 64-character base64 id in a Quantum build (PICO PARK 2). Steam's AppID has
// nothing to do with it, so no amount of routing makes such a game connect: its
// Photon app has to be the one the other players are on.
//
// Rather than keeping a hand-written patch per game, this reads the game folder,
// reports the ids it finds and where, and replaces one with another when asked. Both
// the files it looks at and the two shapes an id takes are the ones the games above
// use, so a game nobody has patched yet can still be given a working id on the spot.
import Foundation

enum PhotonPatch {

    /// The shape of an id, which is what tells the two kinds of game apart.
    enum Kind: String, Sendable {
        /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, as Mono and Unity assets store it.
        case guid
        /// 64 base64 characters, as a Quantum build stores its app id.
        case quantum
    }

    /// One id found in one file.
    struct Candidate: Sendable, Equatable, Hashable {
        let file: URL
        let id: String
        let kind: Kind
        /// True when this is the app OnlineFix's own patch points the game at, so there
        /// is nothing left to replace.
        var isOnlineFixShared: Bool {
            if kind == .quantum { return id == PhotonPatch.onlineFixQuantumID }
            return PhotonIDs.knownDefaults.contains { $0.id.lowercased() == id.lowercased() }
        }
    }

    /// An id with where it sits in its file, before the file's ids are narrowed down.
    struct Found: Sendable, Equatable {
        let id: String
        let kind: Kind
        let offset: Int
    }

    static let backupSuffix = ".onlinefix-photon-backup"

    /// The app OnlineFix's own patches point a game at: the Quantum app its PICO PARK 2
    /// package uses, and the realtime app it publishes for GUID games. A game's own id
    /// is replaced by one of these, which is what makes it meet the players who are on
    /// OnlineFix's app rather than the game's.
    static let onlineFixQuantumID = "pdFIvYRhGmBUiGEWWHQc3RnLReb6atz2r0rcjmkqivLFgrSF9T78X/Q/HNq4j3xM"

    static func onlineFixID(for kind: Kind) -> String {
        kind == .quantum ? onlineFixQuantumID : PhotonIDs.realtime
    }

    /// Ids this knows by their bytes, which is the last resort: a build whose literal
    /// table cannot be read at all. A build that can be read needs no entry here.
    static let knownStockIDs: [String] = [
        "1X/x3gHpVGj8kVdROgk35V/YofQ7JXOXiXzT753mc1DKWnu2nk9rGL5joT0KdWky",
    ]

    private static func isKnownStock(_ id: String) -> Bool {
        knownStockIDs.contains(id)
    }

    /// Files larger than this are not searched: an id is a string, and the files that
    /// carry one are settings, assemblies and small asset bundles.
    static let maxFileSize = 256 * 1024 * 1024
    /// Deep enough for a Mac build, whose data sits inside its `.app`:
    /// `pico_park_2.app/Contents/Resources/Data/il2cpp_data/Metadata` is six folders
    /// down, and the metadata file in it is the seventh.
    static let maxDepth = 8

    /// An assets file holds thousands of GUIDs, so only this many per file are offered
    /// once they are narrowed down.
    static let maxCandidatesPerFile = 12

    /// How far from an id a Photon name may sit and still mark it as the app id.
    static let contextRadius = 256

    /// What a Photon app id sits next to. A GUID is one of thousands in an assets file,
    /// and an assembly's own id sits beside the library's name too, so a GUID counts
    /// only by a settings field's name; a 64-character base64 run is specific enough
    /// that the library's name is evidence enough.
    static let fieldMarkers = ["appid", "applicationid", "appsettings"]
    static let libraryMarkers = ["photon", "quantum"]

    /// Files a fix itself installs. They carry Photon's names too, and patching them
    /// would break the fix rather than the game.
    static let skipNames: Set<String> = [
        "onlinefix64.dll", "onlinefix.dll", "onlinefix.ini", "onlinefix.url",
        "dlllist.txt", "winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll",
        "custom.dll", "custom.net", "steamoverlay64.dll", "d3d9.dll", "d3d11.dll",
        "bepinex.preloader.dll", "doorstop_config.ini", "launchoptions.vdf",
    ]

    /// Extensions worth reading. An id lives in code or serialized assets.
    static let readExtensions: Set<String> = [
        "assets", "dat", "dll", "dylib", "exe", "so", "json", "txt", "ini", "bundle",
        "resource", "xml", "cfg",
    ]

    private static let guidLength = 36
    private static let quantumLength = 64
    private static let dashByte = UInt8(ascii: "-")
    private static let slashByte = UInt8(ascii: "/")
    private static let plusByte = UInt8(ascii: "+")

    // MARK: - Scan

    /// Every Photon app id the game's files carry, with the file each is in.
    static func scan(in folder: URL) -> [Candidate] {
        var found: [Candidate] = []
        var seen = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(backupSuffix) || skipNames.contains(name) { continue }
            // A Mac build keeps its code and assets inside the bundle, a few
            // directories down from the game folder.
            guard readExtensions.contains(url.pathExtension.lowercased())
                    || name == "globalgamemanagers" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= maxFileSize,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            var items = ids(in: data)
            // An IL2CPP build packs its string literals end to end, so an id with a
            // letter either side of it is never a run of its own. The literal table
            // says where each one starts and how long it is, which finds it anyway.
            let literals = quantumLiterals(in: data)
            let literalIDs = Set(literals.map(\.id))
            for literal in literals where !items.contains(where: { $0.id == literal.id }) {
                items.append(literal)
            }
            // An id this knows by its bytes is the last resort, for a build whose table
            // this cannot read.
            for stock in knownStockIDs
            where data.range(of: Data(stock.utf8)) != nil && !items.contains(where: { $0.id == stock }) {
                items.append(Found(id: stock, kind: .quantum, offset: 0))
            }
            // A Unity PhotonServerSettings asset keeps its app ids as length-prefixed
            // strings with no field name beside them, which is the only place PEAK has
            // one: the marker check below cannot see those.
            let fromSettings = assetIDs(in: data)
            let settingsIDs = Set(fromSettings.map(\.id))
            for item in fromSettings where !items.contains(where: { $0.id == item.id }) {
                items.append(item)
            }
            // A Quantum id is one literal among hundreds, so one taken from the table
            // counts by the file carrying Photon's name somewhere, which every Photon
            // build does and a build of something else does not.
            let photonNamed = !literalIDs.isEmpty && namesPhoton(data)
            var perFile = 0
            for item in items {
                // Only the ids sitting next to something Photon names are the app id.
                let markers = item.kind == .guid
                    ? fieldMarkers
                    : fieldMarkers + libraryMarkers
                guard isKnown(item.id) || isKnownStock(item.id)
                        || settingsIDs.contains(item.id)
                        || hasMarker(data, at: item.offset, markers: markers)
                        || (item.kind == .quantum && photonNamed && literalIDs.contains(item.id))
                else { continue }
                let key = "\(url.path)|\(item.id)"
                guard seen.insert(key).inserted else { continue }
                found.append(Candidate(file: url, id: item.id, kind: item.kind))
                perFile += 1
                if perFile >= maxCandidatesPerFile { break }
            }
        }
        return found.sorted { ($0.file.path, $0.id) < ($1.file.path, $1.id) }
    }

    /// The ids inside one file's bytes.
    ///
    /// Read byte by byte rather than as text: the files are binary, some are large,
    /// and an id is plain ASCII wherever it sits. A GUID is taken at its first dash,
    /// so one is found once, and a Quantum id is a base64 run of exactly its length
    /// that holds a `/` or `+`, which no run of names or code does.
    static func ids(in data: Data) -> [Found] {
        guard !data.isEmpty else { return [] }
        var out: [Found] = []
        var seen = Set<String>()
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == dashByte {
                    if let item = guid(at: index, in: bytes), seen.insert(item.id).inserted {
                        out.append(item)
                    }
                    index += 1
                    continue
                }
                if isBase64(byte) {
                    let start = index
                    while index < bytes.count, isBase64(bytes[index]) { index += 1 }
                    if index - start == quantumLength,
                       let item = quantum(at: start, in: bytes), seen.insert(item.id).inserted {
                        out.append(item)
                    }
                    continue
                }
                index += 1
            }
        }
        return out
    }

    // MARK: - String literals

    /// The first four bytes of an IL2CPP `global-metadata.dat`, which are the sanity
    /// 0xFAB11BAF read little-endian.
    static let metadataMagic = Data([0xAF, 0x1B, 0xB1, 0xFA])

    /// The Quantum app ids a build keeps as IL2CPP string literals.
    ///
    /// An IL2CPP build packs its string literals end to end in one blob, so an id with a
    /// letter either side of it is never a 64-character run of its own and the rule
    /// above cannot see it. The literal table that goes with the blob gives each
    /// literal's length and where it starts, so the id is found whatever sits beside it,
    /// without knowing the game in advance.
    static func quantumLiterals(in data: Data) -> [Found] {
        guard data.count >= 24, data.prefix(4) == metadataMagic else { return [] }
        var out: [Found] = []
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            // The header's opening fields: the literal table, then the blob it points
            // into, each an offset and a size from the start of the file. This part of
            // the layout has not changed across the metadata versions in use.
            let tableOffset = int(at: 8, in: bytes)
            let tableSize = int(at: 12, in: bytes)
            let blobOffset = int(at: 16, in: bytes)
            let blobSize = int(at: 20, in: bytes)
            guard tableOffset > 0, tableSize >= 8, blobOffset > 0, blobSize > 0,
                  tableOffset + tableSize <= data.count,
                  blobOffset + blobSize <= data.count,
                  tableSize % 8 == 0 else { return }
            var seen = Set<String>()
            // Each entry is the literal's length and where it starts in the blob.
            for entry in stride(from: tableOffset, to: tableOffset + tableSize, by: 8) {
                let length = int(at: entry, in: bytes)
                let start = blobOffset + int(at: entry + 4, in: bytes)
                guard length == quantumLength, start >= blobOffset,
                      start + length <= blobOffset + blobSize,
                      (start..<(start + length)).allSatisfy({ isBase64(bytes[$0]) })
                else { continue }
                let id = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
                guard isQuantumLooking(id), seen.insert(id).inserted else { continue }
                out.append(Found(id: id, kind: .quantum, offset: start))
            }
        }
        return out
    }

    /// True when a 64-character string reads as a Quantum app id rather than as another
    /// literal of the same length: it holds a base64 symbol, and a character that
    /// repeats. The one long hand-written string of this length a build carries, the
    /// base64 alphabet, has no repeated character, and a random id almost always has
    /// several.
    static func isQuantumLooking(_ id: String) -> Bool {
        guard kind(of: id) == .quantum else { return false }
        guard id.contains("/") || id.contains("+") else { return false }
        return Set(id).count < id.count
    }

    /// True when the file carries one of Photon's names somewhere in it, which every
    /// Photon build does and a build of something else does not.
    static func namesPhoton(_ data: Data) -> Bool {
        containsInsensitive(libraryMarkers, in: data)
    }

    /// The app ids of a Unity `PhotonServerSettings` asset: each is stored as a 32-bit
    /// length of 36 followed by the GUID, in field order, with the class name written
    /// once in the same file. Nothing names the field beside the value, so this is the
    /// only way to find an id in a build that serialises it that way.
    static func assetIDs(in data: Data) -> [Found] {
        guard containsInsensitive(["photonserversettings"], in: data) else { return [] }
        let prefix = Data([0x24, 0x00, 0x00, 0x00])
        var found: [Found] = []
        var search = data.startIndex
        while search < data.endIndex,
              let range = data.range(of: prefix, in: search..<data.endIndex) {
            let start = range.upperBound
            let end = data.index(start, offsetBy: 36, limitedBy: data.endIndex) ?? data.endIndex
            if data.distance(from: start, to: end) == 36,
               let text = String(data: data[start..<end], encoding: .utf8),
               PhotonIDs.isGUID(text) {
                found.append(Found(id: text.lowercased(), kind: .guid,
                                   offset: data.distance(from: data.startIndex, to: start)))
            }
            search = range.upperBound
        }
        return found
    }

    /// True when one of these names sits anywhere in the data, whatever capitals it is
    /// written in: a build writes `PhotonQuantum` and `photon` both.
    static func containsInsensitive(_ markers: [String], in data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for marker in markers {
                let needle = Array(marker.utf8)
                guard !needle.isEmpty, needle.count <= bytes.count else { continue }
                let first = needle[0]
                var index = 0
                while index <= bytes.count - needle.count {
                    guard lowercased(bytes[index]) == first else {
                        index += 1
                        continue
                    }
                    var matched = true
                    for offset in 1..<needle.count
                    where lowercased(bytes[index + offset]) != needle[offset] {
                        matched = false
                        break
                    }
                    if matched { return true }
                    index += 1
                }
            }
            return false
        }
    }

    private static func int(at offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return -1 }
        let value = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Int(value)
    }

    // MARK: - Replace

    /// Replaces one id with another in every file that carries it, and reports the
    /// files written. Each file is kept once, beside itself, for `restore`.
    @discardableResult
    static func replace(_ old: String, with new: String, in folder: URL,
                        sign: (URL) throws -> Void = resign) throws -> [String] {
        guard let shape = kind(of: old) else {
            throw ManagerError("“\(old)” is not a Photon app id: those are 36-character "
                + "GUIDs, as Mono and Unity assets store them, or 64-character base64 "
                + "strings, as a Quantum build stores them.")
        }
        guard kind(of: new) == shape else {
            throw ManagerError(shape == .guid
                ? "The new id has to be a GUID of the same shape as the one it replaces, "
                    + "like \(old), or the game's files break."
                : "The new id has to be \(quantumLength) base64 characters, the same "
                    + "length as the one it replaces, or the game's files break.")
        }
        guard old != new else { return [] }
        var written: [String] = []
        var bundles = Set<String>()
        for candidate in scan(in: folder) where candidate.id == old {
            let file = candidate.file
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            let patched = replacing(data, old: old, new: new)
            guard patched != data else { continue }
            let backup = URL(fileURLWithPath: file.path + backupSuffix)
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: file, to: backup)
            }
            try patched.write(to: file, options: .atomic)
            written.append(file.path)
            if let bundle = bundle(containing: file) { bundles.insert(bundle.path) }
        }
        // A Mac bundle's seal covers its files, so it is signed again after they change.
        for path in bundles.sorted() {
            try sign(URL(fileURLWithPath: path))
        }
        return written
    }

    // MARK: - Automatic patch

    /// What one automatic pass did.
    struct AutoPatch: Sendable, Equatable {
        /// The files written, empty when there was nothing to do.
        var written: [String] = []
        /// The id that was replaced.
        var replaced: String?
        /// Why nothing was changed, when that needs saying.
        var skipped: String?
    }

    /// What the automatic patch would do with what a scan found, worked out without
    /// writing anything, so a probe can show it before a file is touched.
    struct Plan: Sendable, Equatable {
        /// The game's own id, when there is one to replace.
        var id: String?
        var kind: Kind?
        /// What it would be replaced by.
        var target: String?
        /// Why nothing would be changed, when that needs saying.
        var skipped: String?
    }

    /// Decides what an automatic patch would do, and changes nothing.
    ///
    /// Two ids of different values leave it alone: which one the game actually connects
    /// to cannot be told from the files, and guessing could patch the wrong one. The
    /// patch sheet still offers both.
    static func plan(for candidates: [PhotonPatch.Candidate]) -> Plan {
        var plan = Plan()
        let candidates = candidates.filter { !$0.isOnlineFixShared }
        let distinct = Set(candidates.map(\.id))
        guard let candidate = candidates.first else { return plan }
        guard distinct.count == 1 else {
            plan.skipped = "This game carries \(distinct.count) different Photon app ids, "
                + "so which one it connects to is unclear. Nothing was changed."
            return plan
        }
        plan.id = candidate.id
        plan.kind = candidate.kind
        plan.target = onlineFixID(for: candidate.kind)
        return plan
    }

    /// Replaces a game's own Photon app id with the one OnlineFix's patch uses, which
    /// is the patch a Photon game needs before it can meet other players. Called for
    /// every game a scan found an id in, and idempotent: once the game carries
    /// OnlineFix's id there is nothing left to replace.
    static func autoPatch(in folder: URL,
                          sign: (URL) throws -> Void = resign) -> AutoPatch {
        var report = AutoPatch()
        let plan = plan(for: scan(in: folder))
        if let skipped = plan.skipped {
            report.skipped = skipped
            return report
        }
        guard let id = plan.id, let target = plan.target, id != target else { return report }
        do {
            report.written = try replace(id, with: target, in: folder, sign: sign)
            report.replaced = report.written.isEmpty ? nil : id
        } catch {
            report.skipped = error.localizedDescription
        }
        return report
    }

    /// Puts every file this replaced back the way it was, and drops the backups.
    @discardableResult
    static func restore(in folder: URL, sign: (URL) throws -> Void = resign) throws -> [String] {
        var restored: [String] = []
        var bundles = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(backupSuffix) else { continue }
            let original = URL(fileURLWithPath: String(url.path.dropLast(backupSuffix.count)))
            guard let data = try? Data(contentsOf: url) else { continue }
            try data.write(to: original, options: .atomic)
            try? Paths.fm.removeItem(at: url)
            restored.append(original.path)
            if let bundle = bundle(containing: original) { bundles.insert(bundle.path) }
        }
        for path in bundles.sorted() {
            try sign(URL(fileURLWithPath: path))
        }
        return restored
    }

    /// True when this folder has files this could put back.
    static func hasBackups(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.hasSuffix(backupSuffix) { return true }
        }
        return false
    }

    // MARK: - Shapes

    /// The shape an id has, or nil when it is not one.
    static func kind(of id: String) -> Kind? {
        if PhotonIDs.isGUID(id) { return .guid }
        let base64 = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        if id.count == quantumLength, id.allSatisfy({ base64.contains($0) }) { return .quantum }
        return nil
    }

    private static func isKnown(_ id: String) -> Bool {
        PhotonIDs.knownDefaults.contains { $0.id.lowercased() == id.lowercased() }
    }

    // MARK: - Bytes

    private static func guid(at dash: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Found? {
        let start = dash - 8
        let end = start + guidLength
        guard start >= 0, end <= bytes.count else { return nil }
        // A window inside a longer run of hex is part of something else.
        guard start == 0 || !isHex(bytes[start - 1]) else { return nil }
        guard end == bytes.count || !isHex(bytes[end]) else { return nil }
        for offset in 0..<guidLength {
            let byte = bytes[start + offset]
            switch offset {
            case 8, 13, 18, 23:
                guard byte == dashByte else { return nil }
            default:
                guard isHex(byte) else { return nil }
            }
        }
        let id = String(decoding: bytes[start..<end], as: UTF8.self)
        return Found(id: id, kind: .guid, offset: start)
    }

    private static func quantum(at start: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Found? {
        let end = start + quantumLength
        guard end <= bytes.count else { return nil }
        let hasSymbol = (start..<end).contains { bytes[$0] == slashByte || bytes[$0] == plusByte }
        guard hasSymbol else { return nil }
        let id = String(decoding: bytes[start..<end], as: UTF8.self)
        return Found(id: id, kind: .quantum, offset: start)
    }

    /// True when one of these names sits within `contextRadius` bytes of the id.
    static func hasMarker(_ data: Data, at offset: Int,
                          markers: [String] = fieldMarkers + libraryMarkers) -> Bool {
        let start = max(0, offset - contextRadius)
        let end = min(data.count, offset + contextRadius)
        guard start < end else { return false }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for marker in markers {
                let needle = Array(marker.utf8)
                guard needle.count <= end - start else { continue }
                for position in start...(end - needle.count) {
                    var matched = true
                    for index in 0..<needle.count
                    where lowercased(bytes[position + index]) != needle[index] {
                        matched = false
                        break
                    }
                    if matched { return true }
                }
            }
            return false
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)      // 0-9
            || (byte >= 0x41 && byte <= 0x46)   // A-F
            || (byte >= 0x61 && byte <= 0x66)   // a-f
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)      // 0-9
            || (byte >= 0x41 && byte <= 0x5A)   // A-Z
            || (byte >= 0x61 && byte <= 0x7A)   // a-z
            || byte == plusByte || byte == slashByte
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    // MARK: - Helpers

    /// The `.app` a file sits inside, for the re-signing step.
    private static func bundle(containing file: URL) -> URL? {
        var url = file
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension.lowercased() == "app" { return url }
        }
        return nil
    }

    /// Re-signs a patched bundle the way the games' own patch does: the changed
    /// binary first, then the bundle around it.
    static func resign(_ url: URL) throws {
        let isBinary = ["dylib", "so"].contains(url.pathExtension.lowercased())
        var args = ["--force", "--sign", "-"]
        if isBinary { args += ["--identifier", url.deletingPathExtension().lastPathComponent] }
        args += ["--timestamp=none", url.path]
        let out = Shell.run("/usr/bin/codesign", args)
        guard out.code == 0 else {
            throw ManagerError("The game was patched, but signing it again failed, so macOS "
                + "will not run it: \(out.err.isEmpty ? out.out : out.err)")
        }
    }

    /// Every occurrence is replaced, since settings and the code that reads them can
    /// both carry the same id.
    static func replacing(_ data: Data, old: String, new: String) -> Data {
        let needle = Data(old.utf8)
        let replacement = Data(new.utf8)
        guard !needle.isEmpty, needle.count == replacement.count else { return data }
        var result = data
        var found = false
        var position = result.startIndex
        while position < result.endIndex,
              let range = result.range(of: needle, in: position..<result.endIndex) {
            result.replaceSubrange(range, with: replacement)
            position = range.lowerBound + replacement.count
            found = true
        }
        return found ? result : data
    }
}
