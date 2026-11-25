// Launch options are the copy of the DLL preference Steam actually passes on.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct LaunchOptionsStoreTests {

    private func steamRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-options-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = """
        "UserLocalConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"apps"
        \t\t\t\t{
        \t\t\t\t\t"4001890"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LaunchOptions"\t\t"%command% -windowed"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """
        try Data(text.utf8).write(to: config)
        return root
    }

    @Test
    func applyAddsTheWholeOverrideListAndKeepsTheArguments() throws {
        let root = try steamRoot()
        #expect(LaunchOptionsStore.apply(appID: 4001890,
                                         assignments: ["winmm=n,b", "winhttp=n,b"],
                                         steamRoot: root))
        let file = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        let text = try String(contentsOf: file, encoding: .utf8)
        let options = LaunchOptionsStore.current(appID: 4001890, in: text)
        #expect(options == "WINEDLLOVERRIDES='winmm=n,b;winhttp=n,b' %command% -windowed")
        #expect(LaunchOptionsStore.has(appID: 4001890, assignments: ["winmm=n,b"],
                                      steamRoot: root))
    }

    @Test
    func anUnquotedOverrideListIsRewritten() throws {
        let root = try steamRoot()
        let file = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "%command% -windowed",
                                         with: "WINEDLLOVERRIDES=winmm=n,b;winhttp=n,b %command%")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let assignments = ["winmm=n,b", "winhttp=n,b"]
        #expect(!LaunchOptionsStore.has(appID: 4001890, assignments: assignments,
                                       steamRoot: root))
        #expect(LaunchOptionsStore.apply(appID: 4001890, assignments: assignments,
                                         steamRoot: root))
        let updated = try String(contentsOf: file, encoding: .utf8)
        #expect(LaunchOptionsStore.current(appID: 4001890, in: updated)
                == "WINEDLLOVERRIDES='winmm=n,b;winhttp=n,b' %command%")
    }

    @Test
    func applyIsIdempotent() throws {
        let root = try steamRoot()
        let assignments = ["winmm=n,b", "winhttp=n,b"]
        #expect(LaunchOptionsStore.apply(appID: 4001890, assignments: assignments,
                                         steamRoot: root))
        let file = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        let once = try String(contentsOf: file, encoding: .utf8)
        #expect(LaunchOptionsStore.apply(appID: 4001890, assignments: assignments,
                                         steamRoot: root))
        let twice = try String(contentsOf: file, encoding: .utf8)
        #expect(once == twice)
    }

    @Test
    func clearRemovesOnlyTheFixNames() throws {
        let root = try steamRoot()
        let assignments = ["winmm=n,b", "winhttp=n,b"]
        _ = LaunchOptionsStore.apply(appID: 4001890, assignments: assignments, steamRoot: root)
        #expect(LaunchOptionsStore.clear(appID: 4001890, assignments: assignments,
                                        steamRoot: root))
        let file = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        let text = try String(contentsOf: file, encoding: .utf8)
        let options = LaunchOptionsStore.current(appID: 4001890, in: text)
        #expect(options == "%command% -windowed")
    }

    @Test
    func applyAddsAMissingLaunchOptionsKey() throws {
        let root = try steamRoot()
        let file = root.appendingPathComponent("userdata/123456/config/localconfig.vdf")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "LaunchOptions\"\t\t\"%command% -windowed\"",
                                         with: "Other\"\t\t\"1\"")
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = LaunchOptionsStore.apply(appID: 4001890, assignments: ["winmm=n,b"],
                                     steamRoot: root)
        let updated = try String(contentsOf: file, encoding: .utf8)
        #expect(LaunchOptionsStore.current(appID: 4001890, in: updated)
                == "WINEDLLOVERRIDES=winmm=n,b %command%")
    }
}
