// Whether an OnlineFix is likely to work for a game, decided from the game's own
// files before anything is downloaded.
//
// A fix can install perfectly and still never connect: games whose online play
// runs on Photon with their own authentication (R.E.P.O. is one) only work when
// OnlineFix's in-game patch applies, which is not the case everywhere. Rather
// than let someone install and then find out, the check reports what it can see
// and the caller asks before going ahead.
import Foundation

/// How likely a fix is to make the game's online play work.
public enum FixCompatibilityVerdict: String, Codable, Sendable {
    /// Nothing in the game folder says the fix cannot work.
    case works
    /// It may install and still not connect; ask the player first.
    case risky
    /// It cannot work at all (native macOS build, game not installed).
    case unsupported
}

/// The result of looking at a game before installing an OnlineFix.
public struct FixCompatibilityCheck: Codable, Sendable {
    public let verdict: String
    public let title: String
    public let reason: String
    /// True when the player has to say yes before the install starts.
    public let needsConfirmation: Bool

    public init(verdict: FixCompatibilityVerdict, title: String, reason: String) {
        self.verdict = verdict.rawValue
        self.title = title
        self.reason = reason
        self.needsConfirmation = verdict != .works
    }
}

enum FixCompatibility {

    /// Photon ships these managed assemblies; a game folder with them runs its
    /// online play on Photon rather than Steam's own networking.
    static let photonAssemblies: Set<String> = [
        "photonrealtime.dll", "photonunitynetworking.dll", "photon3unity3d.dll",
        "photonvoice.dll", "photonchat.dll",
    ]

    /// The Microsoft Store (GDK) runtime's files. OnlineFix's only package for such a
    /// game is the GDK build, which needs the Xbox runtime and does not exist under
    /// Wine; LuaTools fixes patch Steam, not the game's GDK calls.
    static let gdkFiles: Set<String> = [
        "unity.microsoft.gdk.dll", "xgameruntime.dll", "gamingservices.dll",
        "gamingservicesnet.dll", "appxmanifest.xml", "gdk_helper.bat",
        "wdapp.exe", "xsapi.dll",
    ]

    /// Anti-cheat that OnlineFix and Wine cannot satisfy.
    static let antiCheatFiles: Set<String> = [
        "easyanticheat.exe", "easyanticheat_x64.dll", "easyanticheat.dll",
        "easyanticheat_eos.dll", "battleye.dll", "beservice.exe", "beclient.dll",
        "beclient_x64.dll",
    ]

    /// Deep enough for a managed assembly inside an engine tree.
    static let maxDepth = 6

    static func check(appID: Int, name: String, folder: URL?) -> FixCompatibilityCheck {
        guard let folder else {
            return FixCompatibilityCheck(
                verdict: .unsupported,
                title: "Install the game in Steam first",
                reason: "OnlineFix needs the game folder to put its files in.")
        }

        if let bundle = FixInstaller.nativeMacBundle(in: folder) {
            // A Mac build loads none of the fix's files, but the Photon app id it
            // connects to sits in its own data, and that is the part that makes a
            // Photon game meet other players. Where it can be read, the fix is
            // written into the bundle instead of copied beside it.
            let patch = MacBundlePatch.state(of: bundle)
            if patch.canPatch {
                return FixCompatibilityCheck(
                    verdict: .works,
                    title: "The fix goes into the Mac build's own files",
                    reason: "Steam installed the native macOS build of \(name) "
                        + "(\(bundle.lastPathComponent)). OnlineFix's Windows DLLs cannot load "
                        + "into it, but its Photon app id is in the bundle's data, so installing "
                        + "replaces that id with OnlineFix's and signs the game again. "
                        + patch.summary)
            }
            return FixCompatibilityCheck(
                verdict: .unsupported,
                title: "OnlineFix cannot work here",
                reason: "Steam installed the native macOS build of \(name) "
                    + "(\(bundle.lastPathComponent)), and OnlineFix only patches Windows game files. "
                    + "In Steam, open the game's Properties, Compatibility, force the Windows "
                    + "version, and try again.")
        }

        let found = markers(in: folder)

        if found.contains(where: { antiCheatFiles.contains($0) }) {
            return FixCompatibilityCheck(
                verdict: .risky,
                title: "OnlineFix may not work here",
                reason: "This game uses an anti-cheat that OnlineFix and Wine cannot satisfy "
                    + "(Easy Anti-Cheat or BattlEye). The fix can be installed, but joining a "
                    + "protected server will still be refused.")
        }

        if found.contains(where: { gdkFiles.contains($0) }) {
            return FixCompatibilityCheck(
                verdict: .unsupported,
                title: "This game is like one of the few that aint gonna connect, try if you want ig tho",
                reason: "\(name) ships the Microsoft Store (GDK) runtime. OnlineFix's only "
                    + "package for it needs the Xbox GDK runtime (xgameruntime.dll), which does "
                    + "not exist under Wine, and LuaTools patches Steam rather than the game's "
                    + "GDK calls. You can still download it, but it will not make the game run "
                    + "online here.")
        }

        if found.contains(where: { photonAssemblies.contains($0) }) {
            return FixCompatibilityCheck(
                verdict: .risky,
                title: "Heads up, this game runs on Photon",
                reason: "im pretty damn sure that onlinefix will work for this game, but it runs "
                    + "on photon so I dont really, know, just giving you this now, incase it "
                    + "doesnt work.")
        }

        return FixCompatibilityCheck(
            verdict: .works,
            title: "OnlineFix should work",
            reason: "The game is a Windows build and nothing in its files blocks the fix.")
    }

    /// True when the game ships the Microsoft Store (GDK) runtime.
    static func isGDK(folder: URL?) -> Bool {
        guard let folder else { return false }
        return !markers(in: folder).isDisjoint(with: gdkFiles)
    }

    /// Lowercased file names in the game folder, at the depth OnlineFix files live.
    private static func markers(in folder: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var names: Set<String> = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard photonAssemblies.contains(name) || antiCheatFiles.contains(name)
                || gdkFiles.contains(name) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.insert(name)
            }
        }
        return names
    }
}
