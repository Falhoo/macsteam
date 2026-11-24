// What a Windows binary actually imports and exports.
//
// A game's doorway into a fix is a DLL the executable's import table names, and a
// proxy is the DLL that exports OnlineFix. Guessing either from strings finds names
// in a log or a resource that the loader never reads; reading the PE directory finds
// exactly the modules Windows asks for, in the architecture it will load them in.
//
// This is deliberately small: DOS and PE headers, the section table, the import and
// delay-import directories, and the export names. Anything malformed returns nil
// instead of taking a guess, so a file that is not a PE can never be reported as one.
import Foundation

struct PortableExecutable: Sendable, Equatable {

    enum Architecture: String, Sendable {
        case x86
        case x64
        case arm64
        /// A managed assembly with no bitness requirement: it runs in either process.
        case anyCPU
        case unknown
    }

    let architecture: Architecture
    let isManaged: Bool
    let isDLL: Bool
    /// Lowercased module names, without a path: "kernel32.dll", "winhttp.dll".
    let imports: Set<String>
    /// Export names, as the binary spells them. Proxies export "OnlineFix".
    let exports: Set<String>

    var is64BitNative: Bool { architecture == .x64 || architecture == .arm64 }
    var is32BitNative: Bool { architecture == .x86 }
    var exportsOnlineFix: Bool { exports.contains("OnlineFix") }

    /// Last-resort names from a file the PE reader rejects. A test fixture or a
    /// stripped, non-standard binary can still spell the DLL it loads; the PE reader
    /// stays authoritative whenever it can read the file.
    static func fallbackImports(in url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count > 0, data.count <= 16 * 1024 * 1024,
              let text = String(data: data, encoding: .isoLatin1) else { return [] }
        let pattern = "[A-Za-z0-9_.-]{1,80}\\.dll"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var names = Set<String>()
        for match in regex.matches(in: text, options: [], range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            names.insert(String(text[r]).lowercased())
        }
        return names
    }

    /// Reads a file once per size and modification time. An install replaces files
    /// under the same path, and a cached answer from before the replacement would be
    /// worse than reading again.
    static func read(_ url: URL) -> PortableExecutable? {
        let path = GameScan.canonical(url).path
        let attributes = try? Paths.fm.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = attributes?[.modificationDate] as? Date
        cacheLock.lock()
        if let entry = cache[path], entry.size == size, entry.modified == modified {
            cacheLock.unlock()
            return entry.value
        }
        cacheLock.unlock()

        let value = (try? Data(contentsOf: url, options: [.mappedIfSafe])).flatMap(read)
        cacheLock.lock()
        cache[path] = Entry(size: size, modified: modified, value: value)
        cacheLock.unlock()
        return value
    }

    static func read(_ data: Data) -> PortableExecutable? {
        guard data.count >= 0x40,
              data[0] == 0x4D, data[1] == 0x5A,
              let peOffset = u32(data, 0x3C), peOffset > 0,
              Int(peOffset) + 24 <= data.count,
              u32(data, Int(peOffset)) == 0x0000_4550
        else { return nil }
        let pe = Int(peOffset)
        guard let machine = u16(data, pe + 4),
              let sectionCount = u16(data, pe + 6),
              let optionalSize = u16(data, pe + 20),
              let characteristics = u16(data, pe + 22)
        else { return nil }

        let optional = pe + 24
        guard optional + 2 <= data.count, let magic = u16(data, optional) else { return nil }
        let is64Header = magic == 0x020B
        guard is64Header || magic == 0x010B else { return nil }
        let directoryStart = optional + (is64Header ? 112 : 96)
        let directoryCount = Int(u32(data, optional + (is64Header ? 108 : 92)) ?? 0)
        let tableStart = optional + Int(optionalSize)
        guard tableStart <= data.count else { return nil }

        let sections = sectionTable(data, start: tableStart, count: Int(sectionCount))

        var imports = Set<String>()
        if directoryCount > 1,
           let importRVA = u32(data, directoryStart + 8), importRVA != 0,
           let importOffset = rvaToOffset(importRVA, sections: sections) {
            var descriptor = importOffset
            for _ in 0..<4096 {
                guard descriptor + 20 <= data.count else { break }
                let originalFirstThunk = u32(data, descriptor) ?? 0
                let nameRVA = u32(data, descriptor + 12) ?? 0
                let firstThunk = u32(data, descriptor + 16) ?? 0
                if originalFirstThunk == 0, nameRVA == 0, firstThunk == 0 { break }
                if nameRVA != 0, let offset = rvaToOffset(nameRVA, sections: sections),
                   let name = cString(data, at: offset) {
                    imports.insert(name.lowercased())
                }
                descriptor += 20
            }
        }
        if directoryCount > 13,
           let delayRVA = u32(data, directoryStart + 13 * 8), delayRVA != 0,
           let delayOffset = rvaToOffset(delayRVA, sections: sections) {
            var descriptor = delayOffset
            for _ in 0..<4096 {
                guard descriptor + 32 <= data.count else { break }
                let attributes = u32(data, descriptor) ?? 0
                // The delay-load DllName is at offset 4. Offset 12 is the import
                // address table, which is an RVA to code, not to a module name.
                let nameRVA = u32(data, descriptor + 4) ?? 0
                let iatRVA = u32(data, descriptor + 12) ?? 0
                if attributes == 0, nameRVA == 0, iatRVA == 0 { break }
                if nameRVA != 0, let offset = rvaToOffset(nameRVA, sections: sections),
                   let name = cString(data, at: offset) {
                    imports.insert(name.lowercased())
                }
                descriptor += 32
            }
        }

        var exports = Set<String>()
        if directoryCount > 0,
           let exportRVA = u32(data, directoryStart), exportRVA != 0,
           let exportOffset = rvaToOffset(exportRVA, sections: sections),
           exportOffset + 40 <= data.count {
            let nameCount = Int(u32(data, exportOffset + 24) ?? 0)
            let namesRVA = u32(data, exportOffset + 32) ?? 0
            if nameCount > 0, namesRVA != 0,
               let namesOffset = rvaToOffset(namesRVA, sections: sections) {
                for index in 0..<min(nameCount, 8192) {
                    let entry = namesOffset + index * 4
                    guard entry + 4 <= data.count,
                          let nameRVA = u32(data, entry),
                          let offset = rvaToOffset(nameRVA, sections: sections),
                          let name = cString(data, at: offset) else { continue }
                    exports.insert(name)
                }
            }
        }

        var managed = false
        var managed32BitOnly = false
        if directoryCount > 14,
           let clrRVA = u32(data, directoryStart + 14 * 8), clrRVA != 0,
           let clrOffset = rvaToOffset(clrRVA, sections: sections),
           clrOffset + 20 <= data.count {
            managed = true
            let flags = u32(data, clrOffset + 16) ?? 0
            managed32BitOnly = flags & 0x2 != 0
        }

        let architecture: Architecture
        if managed {
            if managed32BitOnly {
                architecture = .x86
            } else if machine == 0x8664 {
                architecture = .x64
            } else if machine == 0xAA64 {
                architecture = .arm64
            } else {
                architecture = .anyCPU
            }
        } else {
            switch machine {
            case 0x014C: architecture = .x86
            case 0x8664: architecture = .x64
            case 0xAA64: architecture = .arm64
            default: architecture = .unknown
            }
        }

        return PortableExecutable(
            architecture: architecture,
            isManaged: managed,
            isDLL: characteristics & 0x2000 != 0,
            imports: imports,
            exports: exports
        )
    }

    // MARK: - PE walking

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawAddress: UInt32
        let rawSize: UInt32
    }

    private static func sectionTable(_ data: Data, start: Int, count: Int) -> [Section] {
        var sections: [Section] = []
        for index in 0..<max(0, min(count, 96)) {
            let header = start + index * 40
            guard header + 40 <= data.count,
                  let virtualSize = u32(data, header + 8),
                  let virtualAddress = u32(data, header + 12),
                  let rawSize = u32(data, header + 16),
                  let rawAddress = u32(data, header + 20)
            else { break }
            sections.append(Section(virtualAddress: virtualAddress,
                                    virtualSize: virtualSize,
                                    rawAddress: rawAddress,
                                    rawSize: rawSize))
        }
        return sections
    }

    private static func rvaToOffset(_ rva: UInt32, sections: [Section]) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard span > 0, rva >= section.virtualAddress,
                  rva < section.virtualAddress + span else { continue }
            let offset = UInt64(section.rawAddress) + UInt64(rva - section.virtualAddress)
            guard offset <= UInt64(Int.max) else { return nil }
            return Int(offset)
        }
        return nil
    }

    private static func cString(_ data: Data, at offset: Int, limit: Int = 260) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = offset
        let maxEnd = min(data.count, offset + limit)
        while end < maxEnd, data[end] != 0 { end += 1 }
        guard end > offset else { return nil }
        return String(decoding: data[offset..<end], as: UTF8.self)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    // MARK: - Cache

    private struct Entry {
        let size: Int64
        let modified: Date?
        let value: PortableExecutable?
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: Entry] = [:]
}
