import Foundation

/// Test fixtures write their `.app` bundles by hand, so the program inside one has to
/// be faked too: the detection reads `Contents/MacOS` for a non-empty executable, which
/// is what tells a real Mac build from the empty skeleton Steam leaves behind.
enum TestBundle {
    static func writeBinary(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]).write(to: url)
    }
}
