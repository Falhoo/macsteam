// A .NET assembly, read just deeply enough to find a method and its IL.
//
// A Photon game ships Photon's own managed DLLs, and the one thing that decides
// whether it authenticates is a property on `Photon.Realtime.AuthenticationValues`.
// Reading that property means reading the assembly's metadata tables (ECMA-335 II.22),
// which is what this does: the type, field and method tables, the constants that give
// an enum its numbers, and the IL body behind a method's RVA.
//
// Nothing here is Photon specific and nothing here writes.
import Foundation

struct ManagedAssembly: Sendable {

    struct TypeDef: Sendable {
        var row: Int
        var name: String
        var namespace: String
        /// 1-based rows in the Field and MethodDef tables.
        var fieldStart: Int
        var fieldEnd: Int
        var methodStart: Int
        var methodEnd: Int

        var fullName: String { namespace.isEmpty ? name : "\(namespace).\(name)" }
    }

    struct Field: Sendable {
        var row: Int
        var name: String
        /// The field's signature blob, which names its type.
        var signature: [UInt8]
    }

    struct Method: Sendable {
        var row: Int
        var name: String
        var rva: UInt32
    }

    private struct Section: Sendable {
        var virtualAddress: UInt32
        var virtualSize: UInt32
        var rawPointer: UInt32
        var rawSize: UInt32
    }

    let data: Data
    private let sections: [Section]
    private let stringsHeap: Range<Int>
    private let blobsHeap: Range<Int>
    private let heapSizes: UInt8
    private let rowCounts: [Int]
    private let tableOffsets: [Int]
    private let tableEnd: Int

    // MARK: - Reading

    /// Reads an assembly, or nil when the file is not one this can parse.
    init?(_ file: URL) {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            return nil
        }
        self.init(data)
    }

    init?(_ data: Data) {
        guard data.count > 0x40,
              let peOffset = ManagedAssembly.u32(data, 0x3C),
              Int(peOffset) + 24 < data.count,
              data[Int(peOffset)..<Int(peOffset) + 4].elementsEqual([0x50, 0x45, 0, 0])
        else { return nil }
        let coff = Int(peOffset) + 4
        guard let sectionCount = ManagedAssembly.u16(data, coff + 2),
              let optionalSize = ManagedAssembly.u16(data, coff + 16) else { return nil }
        let optional = coff + 20
        guard let magic = ManagedAssembly.u16(data, optional) else { return nil }
        let is64 = magic == 0x20B
        let directories = optional + (is64 ? 112 : 96)
        // Data directory 14 is the CLI header.
        guard let cliRVA = ManagedAssembly.u32(data, directories + 14 * 8) else { return nil }

        var sections: [Section] = []
        let sectionStart = optional + Int(optionalSize)
        for index in 0..<Int(sectionCount) {
            let base = sectionStart + index * 40
            guard let virtualSize = ManagedAssembly.u32(data, base + 8),
                  let virtualAddress = ManagedAssembly.u32(data, base + 12),
                  let rawSize = ManagedAssembly.u32(data, base + 16),
                  let rawPointer = ManagedAssembly.u32(data, base + 20) else { return nil }
            sections.append(Section(virtualAddress: virtualAddress, virtualSize: virtualSize,
                                    rawPointer: rawPointer, rawSize: rawSize))
        }
        self.sections = sections
        self.data = data
        guard let cliOffset = ManagedAssembly.offset(for: cliRVA, in: sections),
              let metadataRVA = ManagedAssembly.u32(data, cliOffset + 8),
              let metadataOffset = ManagedAssembly.offset(for: metadataRVA, in: sections)
        else { return nil }

        // Metadata root: signature, version string, then the stream headers.
        guard let signature = ManagedAssembly.u32(data, metadataOffset), signature == 0x424A5342,
              let versionLength = ManagedAssembly.u32(data, metadataOffset + 12) else { return nil }
        var cursor = metadataOffset + 16 + Int(versionLength)
        // Flags, then the stream count, then the stream headers.
        guard let streamCount = ManagedAssembly.u16(data, cursor + 2) else { return nil }
        cursor += 4
        var tables = Range<Int>(uncheckedBounds: (0, 0))
        var strings = Range<Int>(uncheckedBounds: (0, 0))
        var blobs = Range<Int>(uncheckedBounds: (0, 0))
        for _ in 0..<Int(streamCount) {
            guard let offset = ManagedAssembly.u32(data, cursor),
                  let size = ManagedAssembly.u32(data, cursor + 4) else { return nil }
            let nameStart = cursor + 8
            var nameEnd = nameStart
            while nameEnd < data.count, data[nameEnd] != 0 { nameEnd += 1 }
            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
            cursor = nameStart + ((nameEnd - nameStart + 1 + 3) & ~3)
            let range = Range<Int>(uncheckedBounds: (metadataOffset + Int(offset),
                                                     metadataOffset + Int(offset) + Int(size)))
            switch name {
            case "#~", "#-": tables = range
            case "#Strings": strings = range
            case "#Blob": blobs = range
            default: break
            }
        }
        guard tables.lowerBound != tables.upperBound,
              strings.lowerBound != strings.upperBound,
              blobs.lowerBound != blobs.upperBound else { return nil }

        guard let heapSizes = ManagedAssembly.u8(data, tables.lowerBound + 6),
              let valid = ManagedAssembly.u64(data, tables.lowerBound + 8) else { return nil }
        self.heapSizes = heapSizes
        self.stringsHeap = strings
        self.blobsHeap = blobs

        var counts = [Int](repeating: 0, count: 64)
        var cursor2 = tables.lowerBound + 24
        for table in 0..<64 where valid & (1 << UInt64(table)) != 0 {
            guard let rows = ManagedAssembly.u32(data, cursor2) else { return nil }
            counts[table] = Int(rows)
            cursor2 += 4
        }
        self.rowCounts = counts
        var offsets = [Int](repeating: 0, count: 64)
        for table in 0..<64 where counts[table] > 0 {
            offsets[table] = cursor2
            cursor2 += counts[table] * ManagedAssembly.rowSize(table, counts: counts,
                                                              heapSizes: heapSizes)
        }
        self.tableOffsets = offsets
        self.tableEnd = cursor2
        guard tableEnd <= data.count else { return nil }
    }

    // MARK: - Types, fields, methods

    var types: [TypeDef] {
        guard rowCounts[0x02] > 0 else { return [] }
        var out: [TypeDef] = []
        out.reserveCapacity(rowCounts[0x02])
        for row in 1...rowCounts[0x02] {
            let base = tableOffsets[0x02] + (row - 1) * ManagedAssembly.rowSize(
                0x02, counts: rowCounts, heapSizes: heapSizes)
            var cursor = base
            cursor += 4
            let name = string(at: cursor)
            cursor += stringSize
            let namespace = string(at: cursor)
            cursor += stringSize
            cursor += codedSize(.typeDefOrRef)
            let fieldStart = tableIndex(at: cursor, table: 0x04)
            cursor += tableSize(0x04)
            let methodStart = tableIndex(at: cursor, table: 0x06)
            let fieldEnd = row < rowCounts[0x02]
                ? typeFieldStart(row + 1) : rowCounts[0x04] + 1
            let methodEnd = row < rowCounts[0x02]
                ? typeMethodStart(row + 1) : rowCounts[0x06] + 1
            out.append(TypeDef(row: row, name: name, namespace: namespace,
                               fieldStart: fieldStart, fieldEnd: fieldEnd,
                               methodStart: methodStart, methodEnd: methodEnd))
        }
        return out
    }

    private func typeFieldStart(_ row: Int) -> Int {
        let base = tableOffsets[0x02]
            + (row - 1) * ManagedAssembly.rowSize(0x02, counts: rowCounts, heapSizes: heapSizes)
        return tableIndex(at: base + 4 + stringSize * 2 + codedSize(.typeDefOrRef), table: 0x04)
    }

    private func typeMethodStart(_ row: Int) -> Int {
        let base = tableOffsets[0x02]
            + (row - 1) * ManagedAssembly.rowSize(0x02, counts: rowCounts, heapSizes: heapSizes)
        return tableIndex(at: base + 4 + stringSize * 2 + codedSize(.typeDefOrRef)
                          + tableSize(0x04), table: 0x06)
    }

    func type(named name: String, namespace: String? = nil) -> TypeDef? {
        types.first { type in
            type.name == name && (namespace == nil || type.namespace == namespace)
        }
    }

    func fields(of type: TypeDef) -> [Field] {
        var out: [Field] = []
        guard type.fieldEnd > type.fieldStart else { return out }
        for row in type.fieldStart..<type.fieldEnd where row <= rowCounts[0x04] {
            let base = tableOffsets[0x04] + (row - 1) * ManagedAssembly.rowSize(
                0x04, counts: rowCounts, heapSizes: heapSizes)
            let name = string(at: base + 2)
            let signature = blob(at: base + 2 + stringSize)
            out.append(Field(row: row, name: name, signature: signature))
        }
        return out
    }

    func methods(of type: TypeDef) -> [Method] {
        var out: [Method] = []
        guard type.methodEnd > type.methodStart else { return out }
        for row in type.methodStart..<type.methodEnd where row <= rowCounts[0x06] {
            let base = tableOffsets[0x06] + (row - 1) * ManagedAssembly.rowSize(
                0x06, counts: rowCounts, heapSizes: heapSizes)
            let rva = ManagedAssembly.u32(data, base) ?? 0
            let name = string(at: base + 8)
            out.append(Method(row: row, name: name, rva: rva))
        }
        return out
    }

    /// The integer value of an enum member, from the Constant table.
    func enumValue(of field: Field) -> Int32? {
        guard rowCounts[0x0B] > 0 else { return nil }
        let coded = codedSize(.hasConstant)
        for row in 1...rowCounts[0x0B] {
            let base = tableOffsets[0x0B] + (row - 1) * ManagedAssembly.rowSize(
                0x0B, counts: rowCounts, heapSizes: heapSizes)
            let type = ManagedAssembly.u8(data, base) ?? 0
            let parent = readCoded(at: base + 2, kind: .hasConstant)
            guard parent.tag == 0, parent.row == field.row else { continue }
            let value = blob(at: base + 2 + coded)
            return Self.integer(type: type, bytes: value)
        }
        return nil
    }

    /// A Constant row's value, as the signed integer an enum member is.
    private static func integer(type: UInt8, bytes: [UInt8]) -> Int32? {
        func word(_ count: Int) -> UInt32? {
            guard bytes.count >= count else { return nil }
            var value: UInt32 = 0
            for index in 0..<count { value |= UInt32(bytes[index]) << (8 * UInt32(index)) }
            return value
        }
        switch type {
        case 0x08, 0x09: // I4, U4
            guard let value = word(4) else { return nil }
            return Int32(bitPattern: value)
        case 0x06: // I2
            guard let value = word(2) else { return nil }
            return Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
        case 0x07: // U2
            guard let value = word(2) else { return nil }
            return Int32(UInt16(truncatingIfNeeded: value))
        case 0x05: // I1
            guard let first = bytes.first else { return nil }
            return Int32(Int8(bitPattern: first))
        case 0x04: // U1
            guard let first = bytes.first else { return nil }
            return Int32(first)
        default:
            return nil
        }
    }

    /// The type token a field or method signature names, when it names one.
    /// A field signature is `FIELD (0x06) <type>`; a type is `VALUETYPE (0x11)` or
    /// `CLASS (0x12)` plus a compressed TypeDefOrRef token.
    func signatureTypeToken(_ signature: [UInt8]) -> (table: Int, row: Int)? {
        guard signature.count >= 3, signature[0] == 0x06 else { return nil }
        var index = 1
        var element = signature[index]
        index += 1
        if element == 0x1D || element == 0x0F { // SZARRAY / PTR
            guard index < signature.count else { return nil }
            element = signature[index]
            index += 1
        }
        guard element == 0x11 || element == 0x12 else { return nil }
        guard let value = Self.compressed(signature, at: &index) else { return nil }
        let tag = value & 0x3
        let row = value >> 2
        switch tag {
        case 0: return (0x02, row)   // TypeDef
        case 1: return (0x01, row)   // TypeRef
        default: return nil
        }
    }

    /// The IL body behind a method's RVA: the code, and where it sits in the file.
    func ilBody(rva: UInt32) -> (offset: Int, code: Range<Int>)? {
        guard rva != 0, let start = Self.offset(for: rva, in: sections) else { return nil }
        guard let first = Self.u8(data, start) else { return nil }
        if first & 0x3 == 0x2 {
            let size = Int(first >> 2)
            let codeStart = start + 1
            guard codeStart + size <= data.count else { return nil }
            return (start, codeStart..<(codeStart + size))
        }
        guard first & 0x3 == 0x3,
              let size = Self.u32(data, start + 4) else { return nil }
        let codeStart = start + 12
        guard codeStart + Int(size) <= data.count else { return nil }
        return (start, codeStart..<(codeStart + Int(size)))
    }

    // MARK: - Heaps

    private var stringSize: Int { heapSizes & 0x01 != 0 ? 4 : 2 }
    private var guidSize: Int { heapSizes & 0x02 != 0 ? 4 : 2 }
    private var blobSize: Int { heapSizes & 0x04 != 0 ? 4 : 2 }

    private func index(at offset: Int, size: Int) -> Int {
        size == 2 ? Int(Self.u16(data, offset) ?? 0) : Int(Self.u32(data, offset) ?? 0)
    }

    private func string(at offset: Int) -> String {
        let start = stringsHeap.lowerBound + index(at: offset, size: stringSize)
        guard start >= stringsHeap.lowerBound, start < stringsHeap.upperBound else { return "" }
        var end = start
        while end < stringsHeap.upperBound, data[end] != 0 { end += 1 }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    private func blob(at offset: Int) -> [UInt8] {
        var cursor = blobsHeap.lowerBound + index(at: offset, size: blobSize)
        guard cursor < blobsHeap.upperBound,
              let length = Self.compressed(data, at: &cursor) else { return [] }
        let end = min(cursor + length, blobsHeap.upperBound)
        return Array(data[cursor..<end])
    }

    /// An ECMA-335 compressed unsigned integer (II.23.2): one, two or four bytes,
    /// where the high bits of the first byte say which form it is.
    static func compressed(_ bytes: [UInt8], at index: inout Int) -> Int? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        if first & 0x80 == 0 {
            index += 1
            return Int(first)
        }
        if first & 0xC0 == 0x80 {
            guard index + 1 < bytes.count else { return nil }
            let value = Int(first & 0x3F) << 8 | Int(bytes[index + 1])
            index += 2
            return value
        }
        guard index + 3 < bytes.count else { return nil }
        let value = Int(first & 0x1F) << 24 | Int(bytes[index + 1]) << 16
            | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        index += 4
        return value
    }

    static func compressed(_ data: Data, at cursor: inout Int) -> Int? {
        let slice = Array(data[min(cursor, data.count)...])
        var local = 0
        guard let value = compressed(slice, at: &local) else { return nil }
        cursor += local
        return value
    }

    // MARK: - Table plumbing

    private func tableSize(_ table: Int) -> Int {
        rowCounts[table] < 65536 ? 2 : 4
    }

    private func tableIndex(at offset: Int, table: Int) -> Int {
        rowCounts[table] < 65536 ? Int(Self.u16(data, offset) ?? 0)
                                 : Int(Self.u32(data, offset) ?? 0)
    }

    enum Coded: String {
        case typeDefOrRef, hasConstant, hasCustomAttribute, hasFieldMarshal
        case hasDeclSecurity, memberRefParent, hasSemantics, methodDefOrRef
        case memberForwarded, implementation, customAttributeType, resolutionScope
        case typeOrMethodDef
    }

    private struct CodedKind {
        var tables: [Int]
        var bits: Int
    }

    private static let codedKinds: [Coded: CodedKind] = [
        .typeDefOrRef: CodedKind(tables: [0x02, 0x01, 0x1B], bits: 2),
        .hasConstant: CodedKind(tables: [0x04, 0x08, 0x17], bits: 2),
        .hasCustomAttribute: CodedKind(
            tables: [0x06, 0x04, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x00, 0x0E, 0x17,
                     0x14, 0x11, 0x1A, 0x1B, 0x20, 0x23, 0x26, 0x27, 0x28, 0x2A, 0x2B, 0x2C],
            bits: 5),
        .hasFieldMarshal: CodedKind(tables: [0x04, 0x08], bits: 1),
        .hasDeclSecurity: CodedKind(tables: [0x02, 0x06, 0x20], bits: 2),
        .memberRefParent: CodedKind(tables: [0x02, 0x01, 0x1A, 0x06, 0x1B], bits: 3),
        .hasSemantics: CodedKind(tables: [0x14, 0x17], bits: 1),
        .methodDefOrRef: CodedKind(tables: [0x06, 0x0A], bits: 1),
        .memberForwarded: CodedKind(tables: [0x04, 0x06], bits: 1),
        .implementation: CodedKind(tables: [0x26, 0x23, 0x27], bits: 2),
        .customAttributeType: CodedKind(tables: [0x06, 0x0A], bits: 3),
        .resolutionScope: CodedKind(tables: [0x00, 0x1A, 0x23, 0x01], bits: 2),
        .typeOrMethodDef: CodedKind(tables: [0x02, 0x06], bits: 1),
    ]

    private func codedSize(_ kind: Coded) -> Int {
        guard let coded = Self.codedKinds[kind] else { return 2 }
        let maxRows = coded.tables.map { rowCounts[$0] }.max() ?? 0
        return maxRows < (1 << (16 - coded.bits)) ? 2 : 4
    }

    private func readCoded(at offset: Int, kind: Coded) -> (row: Int, tag: Int) {
        guard let coded = Self.codedKinds[kind] else { return (0, 0) }
        let value = codedSize(kind) == 2 ? Int(Self.u16(data, offset) ?? 0)
                                         : Int(Self.u32(data, offset) ?? 0)
        return (value >> coded.bits, value & ((1 << coded.bits) - 1))
    }

    /// The byte width of one row of a table, from its columns.
    private static func rowSize(_ table: Int, counts: [Int], heapSizes: UInt8) -> Int {
        let str = heapSizes & 0x01 != 0 ? 4 : 2
        let guid = heapSizes & 0x02 != 0 ? 4 : 2
        let blob = heapSizes & 0x04 != 0 ? 4 : 2
        func tableIndexSize(_ t: Int) -> Int { counts[t] < 65536 ? 2 : 4 }
        func coded(_ kind: Coded) -> Int {
            guard let coded = codedKinds[kind] else { return 2 }
            let maxRows = coded.tables.map { counts[$0] }.max() ?? 0
            return maxRows < (1 << (16 - coded.bits)) ? 2 : 4
        }
        switch table {
        case 0x00: return 2 + str + guid * 3
        case 0x01: return coded(.resolutionScope) + str * 2
        case 0x02: return 4 + str * 2 + coded(.typeDefOrRef)
            + tableIndexSize(0x04) + tableIndexSize(0x06)
        case 0x03: return tableIndexSize(0x04)
        case 0x04: return 2 + str + blob
        case 0x05: return tableIndexSize(0x06)
        case 0x06: return 4 + 2 + 2 + str + blob + tableIndexSize(0x08)
        case 0x07: return tableIndexSize(0x08)
        case 0x08: return 2 + 2 + str
        case 0x09: return tableIndexSize(0x02) + coded(.typeDefOrRef)
        case 0x0A: return coded(.memberRefParent) + str + blob
        case 0x0B: return 1 + 1 + coded(.hasConstant) + blob
        case 0x0C: return coded(.hasCustomAttribute) + coded(.customAttributeType) + blob
        case 0x0D: return coded(.hasFieldMarshal) + blob
        case 0x0E: return 2 + coded(.hasDeclSecurity) + blob
        case 0x0F: return 2 + 4 + tableIndexSize(0x02)
        case 0x10: return 4 + tableIndexSize(0x04)
        case 0x11: return blob
        case 0x12: return tableIndexSize(0x02) + tableIndexSize(0x14)
        case 0x13: return tableIndexSize(0x14)
        case 0x14: return 2 + str + coded(.typeDefOrRef)
        case 0x15: return tableIndexSize(0x02) + tableIndexSize(0x17)
        case 0x16: return tableIndexSize(0x17)
        case 0x17: return 2 + str + blob
        case 0x18: return 2 + tableIndexSize(0x06) + coded(.hasSemantics)
        case 0x19: return tableIndexSize(0x02) + coded(.methodDefOrRef) * 2
        case 0x1A: return str
        case 0x1B: return blob
        case 0x1C: return 2 + coded(.memberForwarded) + str + tableIndexSize(0x1A)
        case 0x1D: return 4 + tableIndexSize(0x04)
        case 0x1E, 0x1F: return 4 + 4
        case 0x20: return 4 + 2 * 4 + 4 + blob + str * 2
        case 0x21: return 4
        case 0x22: return 4 * 3
        case 0x23: return 2 * 4 + 4 + blob + str * 2 + blob
        case 0x24: return 4 + tableIndexSize(0x23)
        case 0x25: return 4 * 3 + tableIndexSize(0x23)
        case 0x26: return 4 + str + blob
        case 0x27: return 4 + 4 + str * 2 + coded(.implementation)
        case 0x28: return 4 + 4 + str + coded(.implementation)
        case 0x29: return tableIndexSize(0x02) * 2
        case 0x2A: return 2 + 2 + coded(.typeOrMethodDef) + str
        case 0x2B: return coded(.methodDefOrRef) + blob
        case 0x2C: return tableIndexSize(0x2A) + coded(.typeDefOrRef)
        default: return 0
        }
    }

    // MARK: - Bytes

    private static func offset(for rva: UInt32, in sections: [Section]) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            if rva >= section.virtualAddress, rva < section.virtualAddress + span {
                return Int(rva - section.virtualAddress) + Int(section.rawPointer)
            }
        }
        return nil
    }

    private static func u8(_ data: Data, _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[offset]
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

    private static func u64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << (8 * UInt64(index))
        }
        return value
    }
}
