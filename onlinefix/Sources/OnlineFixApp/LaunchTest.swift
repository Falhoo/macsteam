// A bounded test launch after install: what the game did, what its logs said, and
// which failure it reached. It stops only the process this test started.
import AppKit
import CoreGraphics
import Darwin
import Foundation

enum LaunchTest {

    /// A cancellation flag shared with the UI. The launch runs on the main actor,
    /// but its sleeps do not block the window and the Cancel button stays live.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        func cancel() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    enum Outcome: String, Codable, Sendable {
        case launched, stoppedByUser, cancelled, failed, timedOut, launchRefused, alreadyRunning, unknown
    }

    enum Issue: String, Codable, Sendable {
        case drmStub, crashHandler, overlay, dllList, onlineFixInterface
        case missingDLL, missingRuntime, wrongBitness, gameCrash, online, none

        var title: String {
            switch self {
            case .drmStub: return "The game could not start with its DRM stub missing"
            case .crashHandler: return "Unity's crash reporter stopped the game"
            case .overlay: return "The Steam overlay could not load"
            case .dllList: return "The loader's dlllist did not load"
            case .onlineFixInterface: return "OnlineFix's interface did not load"
            case .missingDLL: return "A DLL the game needs is missing"
            case .missingRuntime: return "A Visual C++ or .NET runtime is missing"
            case .wrongBitness: return "The fix DLL does not match the game's architecture"
            case .gameCrash: return "The game crashed in its own code"
            case .online: return "OnlineFix loaded but the online service refused"
            case .none: return "No failure was identified"
            }
        }

        var repairable: Bool {
            switch self {
            case .drmStub, .crashHandler, .overlay, .dllList, .onlineFixInterface, .missingDLL:
                return true
            default: return false
            }
        }
    }

    struct OnlineEvidence: Codable, Sendable, Equatable {
        var hookActive = false
        var matchmaking = false
        var photonFailure: String?
        var line: String?

        /// The launch line carries keep-id=1 when the game intentionally starts as
        /// itself (for Steam's relay), so "OnlineFix launched" is not the same as
        /// "Spacewar confirmed".
        var startsAsSpacewar: Bool {
            guard hookActive else { return false }
            if let line, line.contains("keep-id=1") { return false }
            return true
        }

        var note: String {
            if startsAsSpacewar && matchmaking {
                return "Spacewar (480) confirmed: Steam started the game as AppID 480 and "
                    + "OnlineFix's networking loaded. Live online play is not confirmed by "
                    + "this test — enter an online lobby to check another player can join."
            }
            if let photonFailure { return "Photon reported: \(photonFailure)." }
            if matchmaking {
                return "OnlineFix's networking loaded, but this game keeps its own AppID, "
                    + "not Spacewar (480). Online play is not confirmed."
            }
            if startsAsSpacewar {
                return "Spacewar (480) confirmed: Steam started the game as AppID 480, but "
                    + "OnlineFix's matchmaking line was not seen. Online play is not confirmed."
            }
            return "Spacewar (480) could not be confirmed: no OnlineFix networking evidence "
                + "was written during the test."
        }
    }

    struct Result: Codable, Sendable, Equatable {
        var appID: Int
        var name: String
        var at: Date
        var outcome: Outcome
        var windowSeconds: Double?
        var runtimeSeconds: Double
        var exitStatus: Int32?
        var issue: Issue
        var issueDetail: String
        var evidence: [String]
        var logPaths: [String]
        var repairs: [String]
        var online: OnlineEvidence

        var opened: Bool { outcome == .launched }
        var message: String {
            switch outcome {
            case .launched:
                let seconds = windowSeconds.map { " after \(Int($0)) seconds" } ?? ""
                return "The game opened\(seconds). \(online.note)"
            case .cancelled:
                return "Test cancelled. The fix is installed; launch the game when ready."
            case .stoppedByUser:
                return "The game was closed before the check finished. The fix was left as it is."
            case .timedOut:
                return "No window appeared in \(Int(runtimeSeconds)) seconds. The game was still running, so the fix was not changed."
            case .alreadyRunning:
                return "The game was already running, so it was not started again."
            case .launchRefused:
                return "Steam would not start the game."
            case .failed, .unknown:
                let detail = issueDetail.isEmpty ? issue.title : issueDetail
                return "The test failed: \(detail)"
            }
        }
    }

    struct Window: Sendable, Equatable {
        var number: Int
        var pid: Int32
        var owner: String
        var name: String
        var width: Double
        var height: Double
    }

    static func resultFile(appID: Int) -> URL {
        Paths.appSupport.appendingPathComponent("launch-test-\(appID).json")
    }

    static func savedResult(appID: Int) -> Result? {
        guard let data = try? Data(contentsOf: resultFile(appID: appID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Result.self, from: data)
    }

    static func save(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? Paths.ensureDir(Paths.appSupport)
        try? encoder.encode(result).write(to: resultFile(appID: result.appID), options: .atomic)
    }

    static func run(appID: Int, name: String, exe: URL?,
                    timeout: Double = 120, settle: Double = 12,
                    cancel: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Result {
        let start = Date()
        let offsets = logOffsets(appID: appID)
        let beforeWindows = windows()
        let stem = exe?.deletingPathExtension().lastPathComponent.lowercased() ?? ""

        if gameProcesses(exe: exe, stem: stem, in: processes()) != nil {
            // The runner can take a moment to reap the previous test's process.
            // Give it that moment, but never kill a game the player already has
            // open: if it is still there, this test does not start.
            _ = await waitUntilStopped(exe: exe, stem: stem, timeout: 3)
        }
        if let existing = gameProcesses(exe: exe, stem: stem, in: processes()) {
            let result = Result(appID: appID, name: name, at: Date(), outcome: .alreadyRunning,
                                windowSeconds: nil, runtimeSeconds: 0, exitStatus: nil,
                                issue: .none, issueDetail: "\(name) was already running.",
                                evidence: existing.map { "\($0.pid) \($0.command)" },
                                logPaths: [], repairs: [], online: OnlineEvidence())
            save(result)
            return result
        }

        // A cancel that arrived while the fix was still being installed should
        // stop before Steam is asked to start anything.
        if cancel() {
            let result = Result(appID: appID, name: name, at: Date(), outcome: .cancelled,
                                windowSeconds: nil, runtimeSeconds: 0, exitStatus: nil,
                                issue: .none, issueDetail: "The test was cancelled before it started.",
                                evidence: [], logPaths: [], repairs: [], online: OnlineEvidence())
            save(result)
            return result
        }

        let marker = exe?.deletingLastPathComponent().appendingPathComponent(".macsteam-winelog")
        let markerExisted = marker.map { Paths.fm.fileExists(atPath: $0.path) } ?? false
        if let marker, !markerExisted { try? Data().write(to: marker) }
        defer {
            if let marker, !markerExisted { try? Paths.fm.removeItem(at: marker) }
        }

        progress("Starting Steam…")
        // LaunchServices opens the patched /Applications/Steam.app, which carries
        // DYLD_INSERT_LIBRARIES in its Info.plist. Running Steam.AppBundle's
        // steam_osx directly starts an unpatched second client with no licences.
        // open(1) returns quickly, so this does not block the main actor.
        let launched = SteamLaunch.run(appID: appID)

        var gamePIDs: Set<Int32> = []
        var found: Window?
        var foundAt: Double?
        while Date().timeIntervalSince(start) < timeout {
            if cancel() { return finish(appID: appID, name: name, start: start, exe: exe,
                                        outcome: .cancelled, window: found, windowAt: foundAt,
                                        pids: gamePIDs, offsets: offsets, repairs: []) }
            if let running = gameProcesses(exe: exe, stem: stem, in: processes()) {
                gamePIDs.formUnion(running.map(\.pid))
            }
            if let fresh = freshWindow(before: beforeWindows, pids: gamePIDs, stem: stem) {
                found = fresh
                foundAt = Date().timeIntervalSince(start)
                gamePIDs.insert(fresh.pid)
                break
            }
            if !launched && Date().timeIntervalSince(start) > 3 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        guard let window = found else {
            let alive = gamePIDs.contains { processAlive($0) }
            let outcome: Outcome = cancel() ? .cancelled : (!launched ? .launchRefused
                : (alive ? .timedOut : .failed))
            return finish(appID: appID, name: name, start: start, exe: exe,
                          outcome: outcome, window: nil, windowAt: nil,
                          pids: gamePIDs, offsets: offsets, repairs: [])
        }

        progress("Window appeared, checking stability…")
        let stableUntil = Date().addingTimeInterval(8)
        while Date() < stableUntil {
            if cancel() { return finish(appID: appID, name: name, start: start, exe: exe,
                                        outcome: .cancelled, window: window, windowAt: foundAt,
                                        pids: gamePIDs, offsets: offsets, repairs: []) }
            if !processAlive(window.pid) && !gamePIDs.contains(where: { processAlive($0) }) {
                return finish(appID: appID, name: name, start: start, exe: exe,
                              outcome: .stoppedByUser, window: window, windowAt: foundAt,
                              pids: gamePIDs, offsets: offsets, repairs: [])
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        progress("Reading the game's logs…")
        if settle > 0 {
            let end = Date().addingTimeInterval(settle)
            while Date() < end {
                if cancel() { return finish(appID: appID, name: name, start: start, exe: exe,
                                            outcome: .cancelled, window: window, windowAt: foundAt,
                                            pids: gamePIDs, offsets: offsets, repairs: []) }
                if !processAlive(window.pid) && !gamePIDs.contains(where: { processAlive($0) }) {
                    return finish(appID: appID, name: name, start: start, exe: exe,
                                  outcome: .failed, window: window, windowAt: foundAt,
                                  pids: gamePIDs, offsets: offsets, repairs: [])
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        return finish(appID: appID, name: name, start: start, exe: exe,
                      outcome: .launched, window: window, windowAt: foundAt,
                      pids: gamePIDs, offsets: offsets, repairs: [])
    }

    private static func finish(appID: Int, name: String, start: Date, exe: URL?,
                               outcome: Outcome, window: Window?, windowAt: Double?,
                               pids: Set<Int32>, offsets: [String: UInt64],
                               repairs: [String]) -> Result {
        let logs = logText(appID: appID, offsets: offsets)
        let status = exitStatus(appID: appID)
        let crash = logs.text.lowercased().contains("unitycrashhandler")
        var issue = classify(logs.text, sawCrashHandler: crash)
        if issue == .none, outcome == .failed, let status, status != 0 { issue = .gameCrash }
        // A stable window is proof the launch worked, even when the log names a DLL
        // the game only probes for. Keep Photon's answer for the online report.
        if outcome == .launched, issue != .online { issue = .none }
        let online = onlineEvidence(appID: appID, start: start, text: logs.text)
        let final = outcome
        var detail = issue.title
        if issue == .missingDLL,
           let line = logs.text.split(separator: "\n").first(where: { $0.lowercased().contains("import_dll") }) {
            detail = String(line).trimmingCharacters(in: .whitespaces)
        }
        stop(pids: pids)
        let result = Result(appID: appID, name: name, at: Date(), outcome: final,
                            windowSeconds: window == nil ? nil : windowAt,
                            runtimeSeconds: Date().timeIntervalSince(start), exitStatus: status,
                            issue: issue, issueDetail: detail, evidence: logs.evidence,
                            logPaths: logs.paths, repairs: repairs, online: online)
        save(result)
        return result
    }

    static func classify(_ text: String, sawCrashHandler: Bool = false) -> Issue {
        let lower = text.lowercased()
        if lower.contains("failed to get onlinefix interface") { return .onlineFixInterface }
        if lower.contains("application load error") { return .drmStub }
        if lower.contains("0xc000007b") || lower.contains("wrong architecture") { return .wrongBitness }
        if lower.contains("0xc0000135") || lower.contains("msvcp140") || lower.contains("vcruntime140") { return .missingRuntime }
        if sawCrashHandler || lower.contains("unitycrashhandler") { return .crashHandler }
        if lower.contains("error code: 126") || lower.contains("error 126")
            || (lower.contains("failed to load") && lower.contains("steamoverlay")) { return .overlay }
        if lower.contains("failed to load") && lower.contains("from the list") { return .dllList }
        if lower.contains("import_dll") && lower.contains("not found") { return .missingDLL }
        if lower.contains("failed to connect to photon") || (lower.contains("photon") && lower.contains("returncode")) { return .online }
        if lower.contains("unhandled exception") || lower.contains("err:seh:") { return .gameCrash }
        return .none
    }

    private static func onlineEvidence(appID: Int, start: Date, text: String) -> OnlineEvidence {
        var evidence = OnlineEvidence()
        let log = Paths.hostConfigFile.deletingLastPathComponent()
            .appendingPathComponent("macsteam.log")
        if let values = try? log.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate, modified >= start {
            let lines = text.split(separator: "\n").map(String.init)
            if let launch = lines.last(where: { $0.contains("[onlinefix] launch game=\(appID)") }) {
                evidence.hookActive = true
                evidence.line = launch
            }
            if lines.contains(where: { $0.contains("[onlinefix] networking active") }) {
                evidence.matchmaking = true
            }
        }
        if let folder = Store.gameFolder(for: appID) {
            let scan = GameScan.read(folder: folder, appID: appID, name: "")
            if let photon = PhotonLog.read(gameFolder: folder, prefix: scan.prefix),
               photon.isFailure,
               let modified = try? photon.source.resourceValues(
                   forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= start {
                evidence.photonFailure = photon.title
            }
        }
        return evidence
    }

    // MARK: - Processes and windows

    static func windows() -> [Window] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 1
            guard layer == 0 else { return nil }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return Window(number: window[kCGWindowNumber as String] as? Int ?? 0,
                          pid: window[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                          owner: window[kCGWindowOwnerName as String] as? String ?? "",
                          name: window[kCGWindowName as String] as? String ?? "",
                          width: bounds["Width"] as? Double ?? 0,
                          height: bounds["Height"] as? Double ?? 0)
        }
    }

    private static func freshWindow(before: [Window], pids: Set<Int32>, stem: String) -> Window? {
        let known = Set(before.map(\.number))
        return windows().first { window in
            guard !known.contains(window.number), window.width >= 320, window.height >= 240 else { return false }
            if pids.contains(window.pid) { return true }
            // The game's window belongs to a child process that ps did not match.
            // Match the executable against the window's title or owner, never
            // against Wine at large: an unrelated Wine app is not this game.
            guard !stem.isEmpty else { return false }
            return window.owner.lowercased().contains(stem)
                || window.name.lowercased().contains(stem)
        }
    }

    static func waitUntilStopped(exe: URL?, stem: String, timeout: Double) async -> Bool {
        guard exe != nil else { return true }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if gameProcesses(exe: exe, stem: stem, in: processes()) == nil { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return gameProcesses(exe: exe, stem: stem, in: processes()) == nil
    }

    struct ProcessInfo: Sendable { var pid: Int32; var command: String }

    static func processes() -> [ProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { return nil }
            guard let pid = Int32(trimmed[..<space]) else { return nil }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            return ProcessInfo(pid: pid, command: command)
        }
    }

    private static func gameProcesses(exe: URL?, stem: String, in list: [ProcessInfo]) -> [ProcessInfo]? {
        guard let exe else { return nil }
        let path = exe.path.lowercased()
        let found = list.filter { item in
            let command = item.command.lowercased()
            guard !command.contains("steam_osx"), !command.contains("notproton/run") else { return false }
            if command.contains(path) { return true }
            // Wine rewrites the game's Windows path to S:\..., so the full path
            // above does not appear in the process command. The executable name
            // does, and a .exe command cannot be the shell wrapper that is
            // excluded above.
            return !stem.isEmpty && command.contains(stem)
                && (command.contains("wine") || command.contains(".exe"))
        }
        return found.isEmpty ? nil : found
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private static func stop(pids: Set<Int32>) {
        for pid in pids where processAlive(pid) {
            if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
            kill(pid, SIGTERM)
        }
        let until = Date().addingTimeInterval(3)
        while Date() < until, pids.contains(where: { processAlive($0) }) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        for pid in pids where processAlive(pid) { kill(pid, SIGKILL) }
    }

    private static func exitStatus(appID: Int) -> Int32? {
        let log = Paths.compatData.appendingPathComponent("\(appID)/notproton-run.log")
        guard let text = tail(log, limit: 64 * 1024) else { return nil }
        let pattern = "game exited status=(-?[0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int32(text[range])
    }

    private struct Logs { var text = ""; var evidence: [String] = []; var paths: [String] = [] }

    private static func logURLs(appID: Int) -> [URL] {
        var urls: [URL] = [
            Paths.compatData.appendingPathComponent("\(appID)/notproton-run.log"),
            Paths.home.appendingPathComponent("Library/Application Support/notproton/launchers/\(appID)/notproton-wine.log"),
            Paths.hostConfigFile.deletingLastPathComponent()
                .appendingPathComponent("macsteam.log"),
        ]
        if let folder = Store.gameFolder(for: appID) {
            for name in ["Player.log", "Player-prev.log", "photondiag.log"] {
                urls.append(folder.appendingPathComponent(name))
            }
            let saved = folder.appendingPathComponent("Saved/Logs")
            if let files = try? Paths.fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: [.contentModificationDateKey]) {
                urls.append(contentsOf: files.filter { $0.pathExtension == "log" })
            }
        }
        return urls
    }

    private static func logOffsets(appID: Int) -> [String: UInt64] {
        var offsets: [String: UInt64] = [:]
        for url in logURLs(appID: appID) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            offsets[url.path] = UInt64(max(0, size))
        }
        return offsets
    }

    private static func logText(appID: Int, offsets: [String: UInt64]) -> Logs {
        var logs = Logs()
        var seen = Set<String>()
        for url in logURLs(appID: appID) where seen.insert(url.path).inserted {
            guard let text = tail(url, limit: 256 * 1024, from: offsets[url.path] ?? 0) else { continue }
            logs.paths.append(url.path)
            logs.text += "\n" + text
        }
        let ignored = ["verify_file invalid signature", "no kerberos support", "winebth", "rogetactivationfactory"]
        logs.evidence = logs.text.split(separator: "\n").map(String.init).filter { line in
            let lower = line.lowercased()
            if ignored.contains(where: { lower.contains($0) }) { return false }
            return lower.contains("err:module") || lower.contains("unhandled exception")
                || lower.contains("application load error") || lower.contains("onlinefix interface")
                || lower.contains("failed to load") || lower.contains("0xc0000")
                || lower.contains("photon") || lower.contains("unitycrashhandler")
        }.suffix(40).map { String($0.prefix(500)) }
        return logs
    }

    private static func tail(_ url: URL, limit: Int, from offset: UInt64 = 0) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let start = min(Int(min(offset, UInt64(data.count))), data.count)
        var slice = data.subdata(in: start..<data.count)
        if slice.count > limit { slice = slice.suffix(limit) }
        return String(decoding: slice, as: UTF8.self)
    }
}
