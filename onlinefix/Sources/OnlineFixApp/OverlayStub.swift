// OnlineFix's SteamOverlay64.dll cannot load Steam's overlay renderer under Wine.
//
// Its DllMain asks the loader for `GameOverlayRenderer64.dll` and puts up a modal
// "Failed to load steam overlay dll. Error code: 126" when that fails. The dialog
// runs while the game's Steam API DLL is still loading, so Godot and Unity never
// reach main(): the game shows a small box and nothing else. A copy of the
// renderer does not help — Steam's renderer started from the game folder takes it
// for the Steam client. The overlay is cosmetic, so its DllMain is made to report
// success and do nothing; the import that needs this DLL still resolves.
import Foundation

enum OverlayStub {

    /// `mov eax, 1; ret`: DllMain returns TRUE without running anything.
    static let patched: [UInt8] = [0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3]

    /// True when the file exists and does nothing at load. Idempotent.
    @discardableResult
    static func disable(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              var bytes = try? Data(contentsOf: url).map({ $0 }) else { return false }
        guard entryPoint(of: bytes) != nil,
              containsExportName(bytes) else { return false }
        guard let entry = entryPoint(of: bytes), bytes.count >= entry + patched.count else {
            return false
        }
        if Array(bytes[entry..<entry + patched.count]) == patched { return true }
        bytes.replaceSubrange(entry..<entry + patched.count, with: patched)
        do {
            try Data(bytes).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// True when the stub has already been neutralised.
    static func isDisabled(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let entry = entryPoint(of: data.map { $0 }),
              data.count >= entry + patched.count else { return false }
        return Array(data[entry..<entry + patched.count]) == patched
    }

    // MARK: - PE

    /// File offset of the PE entry point (DllMain's CRT startup on a DLL).
    static func entryPoint(of bytes: [UInt8]) -> Int? {
        guard bytes.count > 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return nil }
        let pe = Int(u32(bytes, 0x3C))
        guard pe > 0, pe + 24 <= bytes.count, u32(bytes, pe) == 0x0000_4550 else { return nil }
        let sections = Int(u16(bytes, pe + 6))
        let optionalSize = Int(u16(bytes, pe + 20))
        let optional = pe + 24
        guard optional + 2 <= bytes.count else { return nil }
        let magic = u16(bytes, optional)
        guard magic == 0x010B || magic == 0x020B else { return nil }
        let entryRVA = u32(bytes, optional + 16)
        let tableStart = optional + optionalSize
        for index in 0..<sections {
            let header = tableStart + index * 40
            guard header + 40 <= bytes.count else { return nil }
            let virtualSize = u32(bytes, header + 8)
            let virtualAddress = u32(bytes, header + 12)
            let rawSize = u32(bytes, header + 16)
            let rawAddress = u32(bytes, header + 20)
            let span = max(virtualSize, rawSize)
            if entryRVA >= virtualAddress, entryRVA < virtualAddress + span {
                return Int(rawAddress) + Int(entryRVA - virtualAddress)
            }
        }
        return nil
    }

    private static func containsExportName(_ bytes: [UInt8]) -> Bool {
        // Cheap sanity check before rewriting a file: the stub exports "OnlineFix".
        let needle = Array("OnlineFix".utf8)
        guard bytes.count > needle.count else { return false }
        return Data(bytes).range(of: Data(needle)) != nil
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
