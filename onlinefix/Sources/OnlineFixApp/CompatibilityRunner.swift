// Steam keeps its own copy of the compatibility runner, generated from whatever
// NotProton shipped when the tool was installed. Patching the runner inside
// macSteam's payload is not enough: an existing tool keeps the old copy, and that
// copy splits "/…/How to Fish/How to Fish.exe" at the first space. Every repair
// therefore checks the installed tool as well.
import Foundation

public enum CompatibilityRunner {

    /// Makes every installed NotProton tool keep the game executable whole.
    /// Returns true when a runner was changed.
    @discardableResult
    public static func ensure(steamRoot: URL? = nil) -> Bool {
        let support = steamRoot ?? Paths.steamSupport
        let root = support.appendingPathComponent("compatibilitytools.d", isDirectory: true)
        guard let tools = try? Paths.fm.contentsOfDirectory(at: root,
                                                             includingPropertiesForKeys: nil) else {
            return false
        }
        var changed = false
        for tool in tools where tool.lastPathComponent.lowercased().contains("notproton") {
            let runner = tool.appendingPathComponent("run")
            guard let text = try? String(contentsOf: runner, encoding: .utf8),
                  let patched = patched(text) else { continue }
            guard patched != text, (try? patched.write(to: runner, atomically: true,
                                                       encoding: .utf8)) != nil else { continue }
            try? Paths.fm.setAttributes([.posixPermissions: 0o755],
                                        ofItemAtPath: runner.path)
            changed = true
        }
        return changed
    }

    /// The old runner took the first word of the joined arguments. Keep the
    /// executable whole and use it wherever the OnlineFix scan asks for the game.
    static func patched(_ text: String) -> String? {
        if text.contains("np_launch_exe=") { return text }
        let add = """

        np_launch_exe=""
        for np_arg in "$@"; do
          case "$np_arg" in
            *=*) continue ;;
            *.[eE][xX][eE]) np_launch_exe="$np_arg"; break ;;
          esac
        done
        [ -n "$np_launch_exe" ] || np_launch_exe="${1:-}"
        """
        guard let marker = text.range(of: "launch_args=\"$*\"") else { return nil }
        var result = text
        result.insert(contentsOf: add, at: marker.upperBound)

        let oldIf = "if [ -n \"$launch_args\" ]; then"
        if let range = result.range(of: oldIf) {
            result.replaceSubrange(range, with: "if [ -n \"$np_launch_exe\" ]; then")
        }
        let oldAwk = "np_game_exe=$(printf '%s\\n' \"$launch_args\" | awk '{print $1}' | tr -d '\"')"
        if let range = result.range(of: oldAwk) {
            result.replaceSubrange(range, with: "np_game_exe=$(printf '%s' \"$np_launch_exe\" | tr -d '\"')")
        }
        let oldPlain = "np_game_exe=$(printf '%s' \"$launch_args\" | tr -d '\"')"
        if let range = result.range(of: oldPlain) {
            result.replaceSubrange(range, with: "np_game_exe=$(printf '%s' \"$np_launch_exe\" | tr -d '\"')")
        }
        return result
    }
}
