// Text files a Windows fix writes are not always UTF-8. OnlineFix.ini and
// dlllist.txt come from Windows archives, and a UTF-16 copy read as UTF-8 looks
// like one long line of NUL bytes: every key looks missing, so the audit adds a
// second [Main] and a second Photon switch instead of editing the ones already
// there. Reading the byte-order mark, and the NUL pattern when there is no mark,
// keeps the edit in the file's own encoding and the keys findable.
import Foundation

struct TextFile: Sendable {
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    struct Content: Sendable {
        var text: String
        /// The encoding the file was read with, so a write keeps it.
        var encoding: String.Encoding
        /// True when the file began with a byte-order mark.
        var hasBOM: Bool
    }

    /// Reads a text file the way a Windows program wrote it. UTF-8 with or
    /// without a mark, UTF-16LE and UTF-16BE with or without one, and a plain
    /// Latin-1 fallback for an ANSI ini. A file that cannot be read is nil, not
    /// an empty string that would look like a file with every key missing.
    static func read(_ url: URL) -> Content? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(data)
    }

    static func read(_ data: Data) -> Content? {
        if data.starts(with: [0xFF, 0xFE]) {
            let body = data.dropFirst(2)
            guard let text = String(data: body, encoding: .utf16LittleEndian)
            else { return nil }
            return Content(text: text, encoding: .utf16LittleEndian, hasBOM: true)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            let body = data.dropFirst(2)
            guard let text = String(data: body, encoding: .utf16BigEndian)
            else { return nil }
            return Content(text: text, encoding: .utf16BigEndian, hasBOM: true)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            guard let text = String(data: body, encoding: .utf8) else { return nil }
            return Content(text: text, encoding: .utf8, hasBOM: true)
        }
        // A UTF-16 file from Windows has a BOM almost always. A NUL in the first
        // bytes is the remaining tell: ASCII UTF-16 is half NUL.
        if data.count >= 4 {
            let head = Array(data.prefix(8))
            let evenNUL = stride(from: 0, to: head.count - 1, by: 2)
                .filter { head[$0] == 0 }.count
            let oddNUL = stride(from: 1, to: head.count, by: 2)
                .filter { head[$0] == 0 }.count
            if oddNUL >= 2 && evenNUL == 0 {
                if let text = String(data: data, encoding: .utf16LittleEndian) {
                    return Content(text: text, encoding: .utf16LittleEndian, hasBOM: false)
                }
            }
            if evenNUL >= 2 && oddNUL == 0 {
                if let text = String(data: data, encoding: .utf16BigEndian) {
                    return Content(text: text, encoding: .utf16BigEndian, hasBOM: false)
                }
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return Content(text: text, encoding: .utf8, hasBOM: false)
        }
        // An ANSI ini is not UTF-8. Latin-1 maps every byte, so the ASCII keys stay
        // readable and an accented comment is at worst shown as another character.
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        return Content(text: text, encoding: .isoLatin1, hasBOM: false)
    }

    /// Writes the text back in the encoding it came in. A UTF-16 file gets its
    /// mark back; a UTF-8 file that had one keeps it.
    @discardableResult
    static func write(_ text: String, to url: URL, like original: Content?) -> Bool {
        let encoding = original?.encoding ?? .utf8
        let hasBOM = original?.hasBOM ?? false
        var data: Data
        switch encoding {
        case .utf16LittleEndian:
            guard let body = text.data(using: .utf16LittleEndian) else { return false }
            data = hasBOM ? Data([0xFF, 0xFE]) + Data(body) : Data(body)
        case .utf16BigEndian:
            guard let body = text.data(using: .utf16BigEndian) else { return false }
            data = hasBOM ? Data([0xFE, 0xFF]) + Data(body) : Data(body)
        case .isoLatin1:
            guard let body = text.data(using: .isoLatin1) else { return false }
            data = body
        default:
            guard let body = text.data(using: .utf8) else { return false }
            data = hasBOM ? utf8BOM + Data(body) : Data(body)
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The decoded text, for a reader that does not need to write it back.
    static func text(_ url: URL) -> String? { read(url)?.text }
}