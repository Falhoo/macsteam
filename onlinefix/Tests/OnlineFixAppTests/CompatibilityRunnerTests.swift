import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct CompatibilityRunnerTests {

    private let oldRunner = #"""
    #!/bin/sh
    verb="$1"
    shift || true
    launch_args="$*"

    case "$verb" in
      getcompatpath) exit 0 ;;
    esac

    if [ -n "$launch_args" ]; then
        np_game_exe=$(printf '%s\n' "$launch_args" | awk '{print $1}' | tr -d '"')
        np_game_dir=$(dirname "$np_game_exe")
    fi
    """#

    @Test
    func theInstalledToolKeepsAWholePathWithSpaces() {
        let patched = CompatibilityRunner.patched(oldRunner)
        #expect(patched?.contains("np_launch_exe=\"\"") == true)
        #expect(patched?.contains("if [ -n \"$np_launch_exe\" ]; then") == true)
        #expect(patched?.contains("np_game_exe=$(printf '%s' \"$np_launch_exe\"") == true)
        #expect(patched?.contains("$launch_args\" | awk") == false)
    }

    @Test
    func patchingTheToolTwiceChangesNothing() {
        let once = CompatibilityRunner.patched(oldRunner)
        let twice = CompatibilityRunner.patched(once ?? "")
        #expect(twice == once)
    }

    @Test
    func ensureWritesTheInstalledToolAndKeepsItExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-runner-\(UUID().uuidString)", isDirectory: true)
        let tool = root.appendingPathComponent("compatibilitytools.d/notproton-26.3",
                                               isDirectory: true)
        try FileManager.default.createDirectory(at: tool, withIntermediateDirectories: true)
        let runner = tool.appendingPathComponent("run")
        try Data(oldRunner.utf8).write(to: runner)

        #expect(CompatibilityRunner.ensure(steamRoot: root))
        let text = try String(contentsOf: runner, encoding: .utf8)
        #expect(text.contains("np_launch_exe="))
        let attributes = try FileManager.default.attributesOfItem(atPath: runner.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(CompatibilityRunner.ensure(steamRoot: root) == false)
    }
}
