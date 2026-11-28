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
        /// Where the id begins in the file. Several fields can hold the same id (a
        /// realtime and a voice field set alike), so a pair is patched by position
        /// instead of by replacing every copy of one value.
        var offset: Int = 0
        /// True when this came from a `PhotonServerSettings` asset's length-prefixed
        /// fields. That is the strong evidence: the class name and the values sit in
        /// one object, while a plain GUID in a large file can be anything.
        var settings: Bool = false
        /// The field the value was written under, lowercased (`appidrealtime`,
        /// `appidvoice`), when the asset is text and names it. A field name says which
        /// id is which, so a pair stored in two files can still be told apart.
        var field: String? = nil
        /// True when this is the app OnlineFix's own patch points the game at, so there
        /// is nothing left to replace.
        var isOnlineFixShared: Bool {
            if kind == .quantum { return id == PhotonPatch.onlineFixQuantumID }
            return PhotonIDs.shared.contains { $0.lowercased() == id.lowercased() }
        }
    }

    /// An id with where it sits in its file, before the file's ids are narrowed down.
    struct Found: Sendable, Equatable {
        let id: String
        let kind: Kind
        let offset: Int
        var field: String? = nil
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

    /// Files larger than this are not searched. A Unity game's `resources.assets`
    /// can run past 300 MB, and its `PhotonServerSettings` asset sits inside it, so
    /// the old 256 MB limit hid the only real id in R.E.P.O. and PEAK.
    static let maxFileSize = 1024 * 1024 * 1024
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

    /// The same, for a text asset where the field name is written out in full:
    /// `AppIdRealtime: …`, `AppIdVoice: …`, `AppIdChat: …`.
    static let appIDFieldMarkers = ["appidrealtime", "appidvoice", "appidchat",
                                    "appidpuns", "fixedregion"]
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
    ///
    /// `resource` is left out on purpose: those files are the bulk of a Unity game's
    /// size (a 166 MB `resources.resource` is typical) and hold texture and audio
    /// blobs, never settings. Reading them cost 10–15 seconds a scan and found nothing.
    static let readExtensions: Set<String> = [
        "assets", "asset", "dat", "dll", "dylib", "exe", "json", "txt", "ini", "xml",
        "cfg", "settings", "unity3d", "yaml", "yml", "bin", "bytes", "plist",
    ]

    /// Extensions whose files are bigger than a settings file and hold bulk data.
    /// `resources.assets` can be hundreds of megabytes, so a `.bin` or `.dat` blob is
    /// only read when it is small enough to be a settings island.
    static let bulkExtensions: Set<String> = ["bin", "bytes", "dat"]

    /// True for a file that can carry an id. `globalgamemanagers` has no extension,
    /// and only `global-metadata.dat` is a metadata file, so a game's other `.dat`
    /// blobs (sound banks, caches) are not read.
    static func isReadable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == "globalgamemanagers" || name == "global-metadata.dat" { return true }
        let ext = url.pathExtension.lowercased()
        guard readExtensions.contains(ext) else { return false }
        // `.dat` is used for both: only the metadata file is settings, the rest are
        // the audio and cache blobs a game writes at run time.
        if ext == "dat" { return name == "global-metadata.dat" }
        return true
    }

    /// True when a file is worth reading at this size. A metadata file is read whole
    /// whatever it weighs; a bulk blob only while it is small enough to be settings.
    static func sizeAllows(_ url: URL, size: Int) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == "globalgamemanagers" || name == "global-metadata.dat" { return true }
        if bulkExtensions.contains(url.pathExtension.lowercased()) { return size <= smallFile } 
        return true
    }

    /// The size under which a bulk file is read as settings rather than data.
    static let smallFile = 8 * 1024 * 1024

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
            if name == ".macsteam-onlinefix" || name == "bepinex" || name == "doorstop" {
                enumerator.skipDescendants()
                continue
            }
            if name.hasSuffix(backupSuffix) || skipNames.contains(name) { continue }
            // A proxy exports OnlineFix; its strings are the fix's own, not the
            // game's. A package can name its proxy d3d9.dll or anything else, so the
            // export table is a safer marker than a list of names.
            if name.hasSuffix(".dll"), PortableExecutable.read(url)?.exportsOnlineFix == true {
                continue
            }
            // A Mac build keeps its code and assets inside the bundle, a few
            // directories down from the game folder.
            guard isReadable(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= maxFileSize,
                  sizeAllows(url, size: size),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            var items = ids(in: data)
            // An IL2CPP build packs its string literals end to end, so an id with a
            // letter either side of it is never a run of its own. The literal table
            // says where each one starts and how long it is, which finds it anyway.
            let literals = quantumLiterals(in: data)
            let literalIDs = Set(literals.map(\.id))
            for literal in literals where !items.contains(where: { $0.id == literal.id && $0.offset == literal.offset }) {
                items.append(literal)
            }
            // An id this knows by its bytes is the last resort, for a build whose table
            // this cannot read.
            for stock in knownStockIDs
            where data.range(of: Data(stock.utf8)) != nil && !items.contains(where: { $0.id == stock }) {
                items.append(Found(id: stock, kind: .quantum, offset: 0))
            }
            // A Unity PhotonServerSettings asset keeps its app ids as length-prefixed
            // strings with no field name beside them. The class name is the evidence,
            // and each value is kept with its offset so a realtime/voice pair that
            // holds the same value twice is patched field by field.
            // A text-serialized asset writes the same fields as YAML, with the field
            // name beside each value. The name is what tells a realtime id from a
            // voice one, so those are read first and kept whatever else the file holds.
            let fromSettings = assetIDs(in: data) + textSettings(in: data)
            let settingsOffsets = Set(fromSettings.map(\.offset))
            // The general GUID pass sees the same bytes in the same asset; drop those
            // copies so one field is not offered twice.
            items.removeAll { $0.kind == .guid && settingsOffsets.contains($0.offset) }
            // A Quantum id is one literal among hundreds, so one taken from the table
            // counts by the file carrying Photon's name somewhere, which every Photon
            // build does and a build of something else does not.
            let photonNamed = !literalIDs.isEmpty && namesPhoton(data)
            // Settings values are already anchored to the class name, so they are taken
            // even when no other marker is near, and they get their own budget: a long
            // assets file can hold a dozen unrelated GUIDs ahead of them, and running
            // out of room before the settings would lose the only real id in the file.
            var settingsCount = 0
            for item in fromSettings {
                let key = "\(url.path)|\(item.id)|\(item.offset)"
                guard seen.insert(key).inserted else { continue }
                found.append(Candidate(file: url, id: item.id, kind: item.kind,
                                       offset: item.offset, settings: true,
                                       field: item.field))
                settingsCount += 1
                if settingsCount >= maxCandidatesPerFile { break }
            }
            var perFile = 0
            for item in items {
                // Only the ids sitting next to something Photon names are the app id.
                let markers = item.kind == .guid
                    ? fieldMarkers + appIDFieldMarkers
                    : fieldMarkers + libraryMarkers
                guard isKnown(item.id) || isKnownStock(item.id)
                        || hasMarker(data, at: item.offset, markers: markers)
                        || (item.kind == .quantum && photonNamed && literalIDs.contains(item.id))
                else { continue }
                let key = "\(url.path)|\(item.id)|\(item.offset)"
                guard seen.insert(key).inserted else { continue }
                found.append(Candidate(file: url, id: item.id, kind: item.kind,
                                       offset: item.offset))
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
                    // A Mono assembly stores its strings as UTF-16, so the same GUID
                    // is there with a zero byte after every character. Without this
                    // pass the scanner could not see an id in Assembly-CSharp.dll,
                    // which is where R.E.P.O. keeps one.
                    let ascii = guid(at: index, in: bytes)
                    let wide = utf16Guid(at: index, in: bytes)
                    for item in [ascii, wide].compactMap({ $0 })
                    where seen.insert(item.id).inserted {
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
    /// length of 36 followed by the GUID, in field order, and the class name is
    /// written once in the same file.
    ///
    /// The class name alone is not enough. `globalgamemanagers` contains a game's
    /// `productGUID` as the same length-prefixed string, and a build that mentions
    /// `PhotonServerSettings` anywhere (as a preloaded asset, for example) made the
    /// old rule take that unrelated GUID for a Photon id. R.E.P.O. was patched that
    /// way and its real settings, in a 369 MB assets file, were never read. Only a
    /// value in the short run after the class name counts.
    static func assetIDs(in data: Data) -> [Found] {
        guard !data.isEmpty else { return [] }
        let marker = Data("PhotonServerSettings".utf8)
        let prefix = Data([0x24, 0x00, 0x00, 0x00])
        var found: [Found] = []
        var offsets = Set<Int>()
        var search = data.startIndex
        while search < data.endIndex,
              let range = data.range(of: marker, in: search..<data.endIndex) {
            // A serialized object puts its string values straight after its type
            // name; 512 bytes covers the app ids and the short version string.
            let windowStart = range.upperBound
            let windowEnd = data.index(windowStart, offsetBy: 512, limitedBy: data.endIndex)
                ?? data.endIndex
            let window = data[windowStart..<windowEnd]
            var cursor = window.startIndex
            while cursor < window.endIndex,
                  let match = window.range(of: prefix, in: cursor..<window.endIndex) {
                let start = match.upperBound
                let end = window.index(start, offsetBy: 36, limitedBy: window.endIndex)
                    ?? window.endIndex
                if window.distance(from: start, to: end) == 36,
                   let text = String(data: window[start..<end], encoding: .utf8),
                   PhotonIDs.isGUID(text) {
                    let offset = data.distance(from: data.startIndex, to: start)
                    if offsets.insert(offset).inserted {
                        found.append(Found(id: text.lowercased(), kind: .guid, offset: offset))
                    }
                }
                cursor = match.upperBound
            }
            search = range.upperBound
        }
        return found.sorted { $0.offset < $1.offset }
    }

    /// The app ids of a Unity asset saved as text, which Unity does under `Force Text`
    /// serialization and which is how `PhotonServerSettings.asset` looks in many
    /// projects: the field name, a colon, then the value.
    ///
    /// This is the only shape where the field name is part of the file, so it is also
    /// the only shape that says which id is the realtime one and which the voice one
    /// when a game keeps them apart.
    static func textSettings(in data: Data) -> [Found] {
        // Settings text is small and ASCII; a compressed or huge asset would be
        // binary and nothing here would match.
        guard data.count < 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              text.localizedCaseInsensitiveContains("appid") else { return [] }
        var found: [Found] = []
        let bytes = [UInt8](data)
        // Walk the UTF-8 bytes rather than String offsets: the value's position in the
        // file is what the patch writes at.
        var index = 0
        func matches(_ needle: String, at position: Int) -> Bool {
            let target = Array(needle.utf8)
            guard position + target.count <= bytes.count else { return false }
            for offset in 0..<target.count {
                guard lowercased(bytes[position + offset]) == target[offset] else { return false }
            }
            return true
        }
        while index < bytes.count {
            guard lowercased(bytes[index]) == UInt8(ascii: "a") else {
                index += 1
                continue
            }
            for field in appIDFieldMarkers {
                guard matches(field, at: index) else { continue }
                // The name has to start the line: `AppIdRealtime:`, not `MyAppIdThing`.
                let lineStart = bytes[..<index].lastIndex(where: { $0 == 0x0A })
                    .map { $0 + 1 } ?? 0
                let lead = bytes[lineStart..<index]
                guard lead.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x2D }) else { break }
                var cursor = index + field.utf8.count
                while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 {
                    cursor += 1
                }
                guard cursor < bytes.count,
                      bytes[cursor] == UInt8(ascii: ":") || bytes[cursor] == UInt8(ascii: "=")
                else { break }
                cursor += 1
                // Skip a space, then any opening quote.
                while cursor < bytes.count,
                      bytes[cursor] == 0x20 || bytes[cursor] == 0x09 || bytes[cursor] == 0x22 {
                    cursor += 1
                }
                let start = cursor
                while cursor < bytes.count, isBase64(bytes[cursor]) || bytes[cursor] == dashByte {
                    cursor += 1
                }
                guard cursor > start,
                      let id = String(data: data.subdata(in: start..<cursor), encoding: .utf8),
                      let kind = kind(of: id) else { break }
                found.append(Found(id: id, kind: kind, offset: start, field: field))
                break
            }
            index += 1
        }
        return found
    }

    /// True when these bytes carry the id, in either encoding an id is stored in: a
    /// Mono assembly keeps its strings as UTF-16, an assets file keeps bytes as they
    /// are. A comparison that only tried ASCII found nothing in the assembly and
    /// reported a correctly patched file as a lost one.
    static func carries(_ data: Data, id: String) -> Bool {
        if data.range(of: Data(id.utf8)) != nil { return true }
        let wide = Data(id.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return data.range(of: wide) != nil
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

    /// One field to rewrite: the candidate says where, so two fields holding the same
    /// value are still two changes.
    struct Change: Sendable, Equatable, Hashable {
        let candidate: Candidate
        let old: String
        let new: String
    }

    /// Replaces one id with another everywhere a scan offered it, and reports the files
    /// written. Each file is kept once, beside itself, for `restore`.
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
        let candidates = scan(in: folder).filter { $0.id == old }
        guard !candidates.isEmpty else { return [] }
        // In a PhotonServerSettings pair the two fields can hold the same value, and
        // a global replace would write the realtime id into the voice field. Each
        // field keeps its offset; other files still take every occurrence.
        var seenSettingsFiles = Set<String>()
        let settings = candidates.filter(\.settings).filter {
            seenSettingsFiles.insert($0.file.path).inserted
        }
        let settingsFiles = Set(settings.map(\.file.path))
        let otherFiles = Set(candidates.filter { !$0.settings }
            .map(\.file.path)).subtracting(settingsFiles)
        var written: [String] = []
        if !settings.isEmpty {
            written += try apply(settings.map {
                Change(candidate: $0, old: old, new: new)
            }, in: folder, sign: sign)
        }
        if !otherFiles.isEmpty {
            written += try applyEverywhere(old, new,
                to: otherFiles.map(URL.init(fileURLWithPath:)), sign: sign)
        }
        return Array(Set(written)).sorted()
    }

    /// Replaces the id at every place it occurs in these files, which is what a manual
    /// edit asks for: settings and the code that reads them can both carry it.
    @discardableResult
    static func applyEverywhere(_ old: String, _ new: String, to files: [URL],
                                sign: (URL) throws -> Void = resign) throws -> [String] {
        var written: [String] = []
        var bundles = Set<String>()
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let original = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            let patched = replacing(original, old: old, new: new)
            guard patched != original else { continue }
            let backup = URL(fileURLWithPath: file.path + backupSuffix)
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: file, to: backup)
            }
            try patched.write(to: file, options: .atomic)
            written.append(file.path)
            if let bundle = bundle(containing: file) { bundles.insert(bundle.path) }
        }
        for path in bundles.sorted() {
            try sign(URL(fileURLWithPath: path))
        }
        return written
    }

    /// Writes each change at the offset the scan found it. A file is read once, its
    /// untouched copy kept once, and a Mac bundle signed once at the end.
    @discardableResult
    static func apply(_ changes: [Change], in folder: URL,
                      sign: (URL) throws -> Void = resign) throws -> [String] {
        var byFile: [String: [Change]] = [:]
        var order: [String] = []
        for change in changes {
            let path = change.candidate.file.path
            if byFile[path] == nil { order.append(path) }
            byFile[path, default: []].append(change)
        }
        var written: [String] = []
        var bundles = Set<String>()
        for path in order {
            let file = URL(fileURLWithPath: path)
            guard let original = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            var data = original
            for change in byFile[path] ?? [] {
                if let patched = patching(data, at: change.candidate.offset,
                                          old: change.old, new: change.new) {
                    data = patched
                } else if change.candidate.offset == 0 {
                    // A stock id found by its bytes has no usable offset; fall back to
                    // the old global replace for that one case.
                    data = replacing(data, old: change.old, new: change.new)
                }
            }
            guard data != original else { continue }
            let backup = URL(fileURLWithPath: file.path + backupSuffix)
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: file, to: backup)
            }
            try data.write(to: file, options: .atomic)
            written.append(file.path)
            if let bundle = bundle(containing: file) { bundles.insert(bundle.path) }
        }
        // A Mac bundle's seal covers its files, so it is signed again after they change.
        for path in bundles.sorted() {
            try sign(URL(fileURLWithPath: path))
        }
        return written
    }

    /// The id rewritten where it sits, ASCII or UTF-16. Nil when those bytes are not
    /// the id any more, which is how a scan overtaken by another edit is skipped.
    static func patching(_ data: Data, at offset: Int, old: String, new: String) -> Data? {
        guard old.utf8.count == new.utf8.count, offset >= 0 else { return nil }
        let ascii = Data(old.utf8)
        if offset + ascii.count <= data.count,
           data[offset..<(offset + ascii.count)].elementsEqual(ascii) {
            var result = data
            result.replaceSubrange(offset..<(offset + ascii.count), with: Data(new.utf8))
            return result
        }
        let wide = Data(old.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard offset + wide.count <= data.count,
              data[offset..<(offset + wide.count)].elementsEqual(wide) else { return nil }
        let replacement = Data(new.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        var result = data
        result.replaceSubrange(offset..<(offset + wide.count), with: replacement)
        return result
    }

    // MARK: - Automatic patch

    /// What one automatic pass did.
    struct AutoPatch: Sendable, Equatable {
        /// The files written, empty when there was nothing to do.
        var written: [String] = []
        /// The id that was replaced.
        var replaced: String?
        /// The voice id that was replaced, when the game stores the pair.
        var voiceReplaced: String?
        /// The ids the game is meant to carry afterwards, for a later check that the
        /// patch is still in the files.
        var targets: [String] = []
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
        /// The voice id, when the game stores a realtime/voice pair.
        var voiceID: String?
        var voiceTarget: String?
        /// The fields to write, empty when the game already carries the target pair.
        var changes: [Change] = []
        /// Why nothing would be changed, when that needs saying.
        var skipped: String?
    }

    /// Decides what an automatic patch would do, and changes nothing.
    ///
    /// A `PhotonServerSettings` asset stores its realtime and voice ids in field
    /// order. The pair is patched field by field, because R.E.P.O.'s two fields hold
    /// the same value and a global replace would give both the realtime id. Without a
    /// settings pair, one distinct id is patched; several from unrelated places still
    /// leave it alone, since guessing could patch the wrong value.
    static func plan(for candidates: [PhotonPatch.Candidate],
                     realtime: String = PhotonIDs.realtime,
                     voice: String = PhotonIDs.voice) -> Plan {
        var plan = Plan()
        let settings = candidates
            .filter { $0.settings && $0.kind == .guid }
            .sorted { ($0.file.path, $0.offset) < ($1.file.path, $1.offset) }
        if settings.count > 2 {
            plan.skipped = "This game's Photon settings carry \(settings.count) app ids, "
                + "more than a realtime/voice pair, so which two to change is unclear. "
                + "Nothing was changed."
            return plan
        }
        // A text asset names each field, so a pair is ordered by its names whatever
        // file each one is in. Without names, field order only means
        // realtime-then-voice inside one asset: two files give no order, and swapping
        // them would break the game's own connection.
        var pair = settings
        if settings.count == 2,
           let realtime = settings.first(where: { $0.field?.lowercased() == "appidrealtime" }),
           let voice = settings.first(where: { $0.field?.lowercased() == "appidvoice" }),
           realtime.offset != voice.offset {
            pair = [realtime, voice]
        } else if settings.count == 2, settings[0].file.path != settings[1].file.path {
            plan.skipped = "This game keeps its Photon app ids in two different files and does "
                + "not name which field each one is, so which is the realtime id and which the "
                + "voice id is unclear. Nothing was changed."
            return plan
        }

        // A settings pair can hold OnlineFix's own defaults, which is exactly the pair
        // a player asks the patch sheet to move to a custom app. The shared flag only
        // says there is nothing to replace once the target is already there.
        let live = candidates
        guard let fallback = live.first else { return plan }
        let realtimeField = pair.count == 2 ? pair[0] : (pair.first ?? fallback)
        let voiceField = pair.count == 2 ? pair[1] : nil
        let oldRealtime = realtimeField.id
        let oldVoice = voiceField?.id
        // An id that is neither the realtime nor the voice value says this game uses
        // more than one Photon app, and guessing which one is live would be worse
        // than leaving it alone.
        var knownOld = Set([oldRealtime])
        if let oldVoice { knownOld.insert(oldVoice) }
        let foreign = Set(live.map(\.id)).subtracting(knownOld)
        if !foreign.isEmpty {
            plan.skipped = "This game carries \(foreign.count + knownOld.count) different "
                + "Photon app ids, so which one it connects to is unclear. Nothing was changed."
            return plan
        }

        plan.id = oldRealtime
        plan.kind = realtimeField.kind
        plan.target = realtimeField.kind == .quantum ? onlineFixID(for: .quantum) : realtime
        if let voiceField {
            plan.voiceID = voiceField.id
            plan.voiceTarget = voice
        }

        // Every copy of the old value is written, not just the first one. A game can
        // keep its app id in an assets file and in a managed assembly, and patching
        // one of them leaves the other pointing at the game's own Photon app. The
        // settings pair is still field by field: two fields holding the same value
        // must become the realtime and voice ids, not the same value twice.
        var byOffset: [String: Change] = [:]
        for candidate in candidates {
            let target: String?
            if candidate.settings, candidate.file.path == realtimeField.file.path,
               candidate.offset == realtimeField.offset {
                target = realtime
            } else if let voiceField, candidate.settings,
                      candidate.file.path == voiceField.file.path,
                      candidate.offset == voiceField.offset {
                target = voice
            } else if candidate.id == oldRealtime {
                target = plan.target
            } else if let oldVoice, candidate.id == oldVoice {
                target = voice
            } else {
                target = nil
            }
            guard let target, target != candidate.id else { continue }
            let key = "\(candidate.file.path)|\(candidate.offset)|\(candidate.id)"
            byOffset[key] = Change(candidate: candidate, old: candidate.id, new: target)
        }
        plan.changes = byOffset.values.sorted {
            ($0.candidate.file.path, $0.candidate.offset) < ($1.candidate.file.path, $1.candidate.offset)
        }
        return plan
    }

    /// Replaces a game's own Photon app id with the one OnlineFix's patch uses, which
    /// is the patch a Photon game needs before it can meet other players. Called for
    /// every game a scan found an id in, and idempotent: once the game carries
    /// OnlineFix's id there is nothing left to replace.
    static func autoPatch(in folder: URL,
                          realtime: String = PhotonIDs.realtime,
                          voice: String = PhotonIDs.voice,
                          sign: (URL) throws -> Void = resign) -> AutoPatch {
        var report = AutoPatch()
        let plan = plan(for: scan(in: folder), realtime: realtime, voice: voice)
        if let skipped = plan.skipped {
            report.skipped = skipped
            return report
        }
        report.targets = [plan.target, plan.voiceTarget].compactMap { $0 }
        guard !plan.changes.isEmpty else { return report }
        do {
            report.written = try apply(plan.changes, in: folder, sign: sign)
            guard !report.written.isEmpty else { return report }
            report.replaced = plan.id
            if let voice = plan.voiceID, voice != plan.voiceTarget {
                report.voiceReplaced = voice
            }
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

    /// A GUID stored as UTF-16LE: each of its 36 characters followed by a zero byte.
    /// `dash` is the position of the first dash, after eight two-byte characters.
    private static func utf16Guid(at dash: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Found? {
        guard dash + 1 < bytes.count, bytes[dash + 1] == 0 else { return nil }
        let start = dash - 8 * 2
        let end = start + guidLength * 2
        guard start >= 0, end <= bytes.count else { return nil }
        // A window inside a longer run of hex is part of something else.
        if start >= 2, bytes[start - 1] == 0, isHex(bytes[start - 2]) { return nil }
        if end + 1 < bytes.count, bytes[end + 1] == 0, isHex(bytes[end]) { return nil }
        var characters: [UInt8] = []
        characters.reserveCapacity(guidLength)
        for offset in 0..<guidLength {
            let byte = bytes[start + offset * 2]
            let high = bytes[start + offset * 2 + 1]
            guard high == 0 else { return nil }
            switch offset {
            case 8, 13, 18, 23:
                guard byte == dashByte else { return nil }
            default:
                guard isHex(byte) else { return nil }
            }
            characters.append(byte)
        }
        let id = String(decoding: characters, as: UTF8.self)
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

    /// True when one of these names sits within `contextRadius` bytes of the id,
    /// as ASCII or as the UTF-16 a Mono assembly writes.
    static func hasMarker(_ data: Data, at offset: Int,
                          markers: [String] = fieldMarkers + libraryMarkers) -> Bool {
        let start = max(0, offset - contextRadius)
        let end = min(data.count, offset + contextRadius)
        guard start < end else { return false }
        if containsInsensitive(markers, in: data.subdata(in: start..<end)) { return true }
        // The window can begin on either half of a UTF-16 character, so try both.
        for shift in 0...1 where start + shift < end {
            let slice = data.subdata(in: (start + shift)..<end)
            guard let text = String(data: slice, encoding: .utf16LittleEndian) else { continue }
            let lower = text.lowercased()
            if markers.contains(where: { lower.contains($0) }) { return true }
        }
        return false
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
    ///
    /// What the signature already carried is kept. A game that ships with the hardened
    /// runtime and `disable-library-validation` loses both if it is signed bare, and
    /// then dyld refuses the libraries Steam injects into it — the overlay deadlocks
    /// the game on its first frames and the window stays black.
    static func resign(_ url: URL) throws {
        let isBinary = ["dylib", "so"].contains(url.pathExtension.lowercased())
        var args = ["--force", "--sign", "-"]
        if isBinary { args += ["--identifier", url.deletingPathExtension().lastPathComponent] }
        var entitlements: URL?
        if !isBinary { entitlements = try KeptSignature.apply(url, to: &args) }
        defer { if let entitlements { try? Paths.fm.removeItem(at: entitlements) } }
        args += ["--timestamp=none", url.path]
        let out = Shell.run("/usr/bin/codesign", args)
        guard out.code == 0 else {
            throw ManagerError("The game was patched, but signing it again failed, so macOS "
                + "will not run it: \(out.err.isEmpty ? out.out : out.err)")
        }
    }

    /// Every occurrence is replaced, ASCII and UTF-16, since settings and the code
    /// that reads them can both carry the same id.
    static func replacing(_ data: Data, old: String, new: String) -> Data {
        guard old.utf8.count == new.utf8.count else { return data }
        let asciiOld = Data(old.utf8), asciiNew = Data(new.utf8)
        let wideOld = Data(old.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let wideNew = Data(new.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        var result = data
        for (needle, replacement) in [(asciiOld, asciiNew), (wideOld, wideNew)]
        where !needle.isEmpty {
            var position = result.startIndex
            while position < result.endIndex,
                  let range = result.range(of: needle, in: position..<result.endIndex) {
                result.replaceSubrange(range, with: replacement)
                position = range.lowerBound + replacement.count
            }
        }
        return result
    }
}

/// The parts of a bundle's existing signature that have to survive being replaced.
/// Signing again keeps the identity codesign already chose; the runtime flag and the
/// entitlements are not carried over on their own, so they are read out first.
enum KeptSignature {

    /// Adds `--options runtime` and `--entitlements <file>` to `args` for whatever the
    /// bundle already carried, and returns the written entitlements file to delete.
    static func apply(_ bundle: URL, to args: inout [String]) throws -> URL? {
        let details = Shell.run("/usr/bin/codesign", ["-d", "--verbose=2", bundle.path])
        if details.out.contains("flags=") || details.err.contains("flags=") {
            let text = details.out.isEmpty ? details.err : details.out
            if text.contains("runtime") { args += ["--options", "runtime"] }
        }
        let entitlements = Shell.run("/usr/bin/codesign",
                                     ["-d", "--entitlements", "-", "--xml", bundle.path])
        let xml = entitlements.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !xml.isEmpty, xml.hasPrefix("<?xml") else { return nil }
        let file = Paths.fm.temporaryDirectory
            .appendingPathComponent("kept-entitlements-\(UUID().uuidString).plist")
        try Data(xml.utf8).write(to: file)
        args += ["--entitlements", file.path]
        return file
    }
}
