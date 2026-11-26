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


    private let parentRunner = #"""
    #!/bin/sh
    np_launch_exe="$1"
    np_game_dir=$(dirname "$np_launch_exe")
    np_onlinefix_dir=""
    for np_try in "$np_game_dir" "$np_game_dir/.." "$np_game_dir/../.."; do
      if [ -f "$np_try/OnlineFix64.dll" ]; then
        np_onlinefix_dir="$np_try"
        break
      fi
    done
    """#

    private let besideRunner = #"""
    #!/bin/sh
    np_launch_exe="$1"
    np_game_dir=$(dirname "$np_launch_exe")
    np_onlinefix_dir=""
    if [ -f "$np_game_dir/OnlineFix64.dll" ]; then
      np_onlinefix_dir="$np_game_dir"
    fi
    if [ -f "$np_game_dir/.macsteam-winelog" ]; then
      export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
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

    @Test
    func runnerFindsOnlineFixBelowTheLauncher() {
        let patched = CompatibilityRunner.patched(parentRunner)
        #expect(patched?.contains("\"$np_game_dir\"/*/Binaries/Win64") == true)
        #expect(patched?.contains("\"$np_game_dir\"/*/*/Binaries/Win64") == true)
        #expect(patched?.contains("# np_nested_onlinefix") == true)
    }

    @Test
    func olderSingleCheckGetsTheNestedScan() {
        let patched = CompatibilityRunner.patched(besideRunner)
        #expect(patched?.contains("\"$np_game_dir\"/*/Binaries/Win64") == true)
        #expect(patched?.contains("# np_nested_onlinefix") == true)
        #expect(patched?.contains("if [ -n \"$np_onlinefix_dir\" ] && [ -f \"$np_onlinefix_dir/.macsteam-winelog\" ]") == true)
        #expect(patched?.contains("if [ -f \"$np_game_dir/OnlineFix64.dll\" ]; then") == false)
    }

    @Test
    func patchingTheNestedScanTwiceChangesNothing() {
        let once = CompatibilityRunner.patched(parentRunner)
        let twice = CompatibilityRunner.patched(once ?? "")
        #expect(twice == once)
    }


}
