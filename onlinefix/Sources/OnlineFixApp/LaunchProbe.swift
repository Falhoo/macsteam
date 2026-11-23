// Starting a game the way Steam does, and watching for its window.
//
// Files in the right place are not proof that a game runs: a fix's loader can start
// and leave the process alive with no window, which is what a 32-bit .NET game does
// under this Wine. The probe launches the game through Steam, waits for a window to
// appear, stops it again, and writes down what it saw. `FixDiagnosis` reads that
// result, so the next scan knows whether the fix actually opened the game.
import AppKit
import CoreGraphics
import Foundation

enum LaunchProbe {

    struct Result: Codable, Sendable, Equatable {
        var appID: Int
        var name: String
        var at: Date
        /// Seconds until a window appeared, or nil when none did.
        var windowSeconds: Double?
        /// How long the probe waited.
        var waited: Double
        /// The process that owned the window, as macOS names it.
        var windowOwner: String?
        var note: String

        var opened: Bool { windowSeconds != nil }
    }

    static func resultFile(appID: Int) -> URL {
        Paths.appSupport.appendingPathComponent("probe-\(appID).json")
    }

    static func savedResult(appID: Int) -> Result? {
        guard let data = try? Data(contentsOf: resultFile(appID: appID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Result.self, from: data)
    }

    private static func save(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? Paths.ensureDir(Paths.appSupport)
        try? encoder.encode(result).write(to: resultFile(appID: result.appID), options: .atomic)
    }

    /// The owners of the on-screen windows that are big enough to be a game.
    static func gameWindows() -> Set<String> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var owners: Set<String> = []
        for window in info {
            let layer = window[kCGWindowLayer as String] as? Int ?? 1
            guard layer == 0 else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = bounds["Width"] as? Double ?? 0
            let height = bounds["Height"] as? Double ?? 0
            guard width >= 320, height >= 240 else { continue }
            owners.insert(window[kCGWindowOwnerName as String] as? String ?? "")
        }
        return owners
    }

    /// Launches the game through Steam, waits for its window, stops it, and records
    /// the result. `seconds` is how long to wait before calling it a failure.
    @discardableResult
    static func run(appID: Int, name: String, exe: URL?, seconds: Double = 75,
                    settle: Double = 0) -> Result {
        let before = gameWindows()
        let client = Paths.steamSupport
            .appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")

        var launched = false
        let process = Process()
        process.executableURL = client
        process.arguments = ["-applaunch", "\(appID)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            launched = true
            process.waitUntilExit()
        }

        let stem = exe?.deletingPathExtension().lastPathComponent.lowercased() ?? ""
        let start = Date()
        var foundOwner: String?
        var foundAt: Double?
        while Date().timeIntervalSince(start) < seconds {
            let fresh = gameWindows().subtracting(before)
            let match = fresh.first { owner in
                let lower = owner.lowercased()
                return lower.contains("wine") || (!stem.isEmpty && lower.contains(stem))
            }
            if let match {
                foundOwner = match
                foundAt = Date().timeIntervalSince(start)
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        let waited = Date().timeIntervalSince(start)
        // A game can show its window and only then reach the network, which is where
        // Photon answers. Settling keeps it running that much longer before it is
        // stopped, so the log has something to read.
        if foundAt != nil, settle > 0 { Thread.sleep(forTimeInterval: settle) }

        stop(exe: exe)

        var result = Result(appID: appID, name: name, at: Date(),
                            windowSeconds: foundAt, waited: waited,
                            windowOwner: foundOwner, note: "")
        if !launched {
            result.note = "Steam would not start the game."
        } else if let foundAt {
            result.note = "A window appeared after \(Int(foundAt))s (\(foundOwner ?? "unknown"))."
        } else {
            result.note = "No window appeared in \(Int(seconds))s."
        }
        save(result)
        return result
    }

    /// Stops what the probe started. The game process is named after its executable.
    static func stop(exe: URL?) {
        guard let exe else { return }
        let stem = exe.deletingPathExtension().lastPathComponent.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName?.lowercased() else { continue }
            if name == "\(stem).exe" || name == stem || name.contains(stem) {
                app.terminate()
            }
        }
    }
}
