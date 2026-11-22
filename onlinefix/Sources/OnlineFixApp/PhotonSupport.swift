// OnlineFix's Photon patch, for games whose fix does not carry it.
//
// Photon games (R.E.P.O., PEAK and others) only accept OnlineFix's auth when its
// in-game patch runs. That patch is a BepInEx plugin ("Custom.dll") started by the
// fix's winmm doorway, so a fix that stops at the Steam API DLL leaves the game
// answering "CustomAuthenticationError". The chain is the same for every Photon
// game, so the app carries a copy and adds it where it is missing.
import Foundation

enum PhotonSupport {

    /// The chain, as the fix archive names it: a doorstop beside the executable,
    /// BepInEx's preloader and the plugin.
    static let pieces: [(relative: String, source: String)] = [
        ("winmm.dll", "winmm.dll"),
        ("BepInEx/core/BepInEx.Preloader.dll", "BepInEx/core/BepInEx.Preloader.dll"),
        ("Custom.dll", "Custom.dll"),
    ]

    /// The bundled chain: app Resources/photon, else vendor/photon when running
    /// from a build directory.
    static func bundled() -> URL? {
        if let res = Bundle.main.resourceURL {
            let dir = res.appendingPathComponent("photon", isDirectory: true)
            if Paths.fm.fileExists(atPath: dir.appendingPathComponent("Custom.dll").path) {
                return dir
            }
        }
        let dev = URL(fileURLWithPath: Paths.fm.currentDirectoryPath)
            .appendingPathComponent("vendor/photon", isDirectory: true)
        if Paths.fm.fileExists(atPath: dev.appendingPathComponent("Custom.dll").path) {
            return dev
        }
        return nil
    }

    /// Installs the chain into a Photon game that has an OnlineFix but no patch.
    ///
    /// Only the files that are missing are written, so a fix that already ships the
    /// chain (R.E.P.O.'s does) is left exactly as it is. `OnlineFix.ini` gets
    /// `PhotonIntegration=true` because OnlineFix only runs the patch when it is.
    /// Returns the files written.
    @discardableResult
    static func install(appID: Int, gameFolder: URL, fixFiles: [String],
                        progress: (String) -> Void = { _ in }) -> [String] {
        guard let source = bundled(),
              PhotonFix.isPhotonGame(in: gameFolder)
        else { return [] }
        let loader = FixInstaller.launchFolder(in: gameFolder) ?? gameFolder

        var written: [String] = []
        var announced = false
        for piece in pieces {
            let destination = loader.appendingPathComponent(piece.relative)
            if Paths.fm.fileExists(atPath: destination.path) { continue }
            let file = source.appendingPathComponent(piece.source)
            guard Paths.fm.fileExists(atPath: file.path) else { continue }
            try? Paths.ensureDir(destination.deletingLastPathComponent())
            if !announced {
                progress("Installing OnlineFix's Photon patch…")
                announced = true
            }
            if (try? Paths.fm.copyItem(at: file, to: destination)) != nil {
                written.append(destination.path)
            }
        }

        // The existing game file wins over a copy that is already there.
        _ = WineOverride.ensure(appID: appID, dll: "winmm.dll")
        let ini = loader.appendingPathComponent("OnlineFix.ini")
        if enablePhotonIntegration(at: ini) { written.append(ini.path) }
        // The loader only starts what dlllist.txt names.
        let list = loader.appendingPathComponent("dlllist.txt")
        if addCustomToDLLList(at: list), !written.contains(list.path) { written.append(list.path) }
        return written
    }

    /// Adds `Custom.net` to the fix's loader list, which is how OnlineFix64 learns
    /// to start the Photon patch. Returns true when the list changed.
    @discardableResult
    static func addCustomToDLLList(at url: URL) -> Bool {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        if lines.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "custom.net"
        }) { return false }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "Custom.net\n"
        return (try? text.data(using: .utf8)?.write(to: url, options: .atomic)) != nil
    }

    /// `[Misc] PhotonIntegration=true`, leaving everything else in the ini alone.
    @discardableResult
    static func enablePhotonIntegration(at url: URL) -> Bool {
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              !hasPhotonIntegration(text) else { return false }
        var lines = text.components(separatedBy: "\n")
        let line = "PhotonIntegration=true"
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[misc]"
        }) {
            lines.insert(line, at: index + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[Misc]")
            lines.append(line)
        }
        text = lines.joined(separator: "\n")
        return (try? text.data(using: .utf8)?.write(to: url, options: .atomic)) != nil
    }

    /// An ini that already turns the patch on, in any spelling Wine or OnlineFix
    /// accept.
    private static func hasPhotonIntegration(_ text: String) -> Bool {
        let wanted = ["true", "yes", "1"]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("photonintegration") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return wanted.contains(value)
        }
        return false
    }
}
