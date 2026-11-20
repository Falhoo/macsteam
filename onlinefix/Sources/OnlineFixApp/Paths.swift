import Foundation
import CryptoKit
import Darwin

// MARK: - Paths

enum Paths {
    static let fm = FileManager.default
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let steamApp = URL(fileURLWithPath: "/Applications/Steam.app")

    static var steamSupport: URL {
        home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// The real Steam client bundle (the one that owns steamclient.dylib).
    static var steamClientBundle: URL {
        steamSupport.appendingPathComponent("Steam.AppBundle/Steam", isDirectory: true)
    }

    static var packageDir: URL {
        steamClientBundle.appendingPathComponent("Contents/MacOS/package", isDirectory: true)
    }

    static var steamApps: URL {
        steamSupport.appendingPathComponent("steamapps", isDirectory: true)
    }

    static var compatData: URL {
        steamApps.appendingPathComponent("compatdata", isDirectory: true)
    }

    static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/OnlineFixManager", isDirectory: true)
    }

    static var runtimeDir: URL { appSupport.appendingPathComponent("runtime", isDirectory: true) }
    static var gamesFile: URL { appSupport.appendingPathComponent("games.json") }
    static var logFile: URL { appSupport.appendingPathComponent("onlinefix.log") }
    static var installationFile: URL { appSupport.appendingPathComponent("installation.json") }
    static var backupDir: URL { appSupport.appendingPathComponent("backup", isDirectory: true) }

    static var installedDylib: URL {
        steamApp.appendingPathComponent("Contents/MacOS/onlinefix.dylib")
    }

    static var steamInfoPlist: URL {
        steamApp.appendingPathComponent("Contents/Info.plist")
    }

    static func ensureDir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Hashing

enum Hash {
    static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Process helper

enum Shell {
    struct Result {
        var code: Int32
        var out: String
        var err: String
        var timedOut: Bool
    }

    /// Runs a tool and waits for it. stdout and stderr are drained at the same
    /// time, so a tool that writes a lot to one of them cannot fill it and wait
    /// forever while we block on the other. Its input is /dev/null, so it can
    /// never sit waiting on a prompt nobody can answer. `progress` receives its
    /// output line by line as it arrives.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String],
                    timeout: TimeInterval? = 300,
                    progress: (@Sendable (String) -> Void)? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return Result(code: -1, out: "", err: error.localizedDescription,
                          timedOut: false)
        }

        let collector = Collector(progress: progress)
        let group = DispatchGroup()
        for (pipe, isError) in [(outPipe, false), (errPipe, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collector.append(chunk, isError: isError)
                }
                group.leave()
            }
        }

        var timedOut = false
        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                // A tool that ignores the signal is stopped the hard way.
                if group.wait(timeout: .now() + 5) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        group.wait()
        process.waitUntilExit()
        return collector.result(code: timedOut ? -2 : process.terminationStatus,
                                 timedOut: timedOut)
    }

    /// `run` off the calling thread. Extracting a large archive takes minutes,
    /// and the window that started it has to keep drawing and taking clicks.
    static func runAsync(_ launchPath: String, _ args: [String],
                         timeout: TimeInterval? = 300,
                         progress: (@Sendable (String) -> Void)? = nil) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(launchPath, args,
                                                   timeout: timeout, progress: progress))
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var pending = ""
        private let progress: (@Sendable (String) -> Void)?

        init(progress: (@Sendable (String) -> Void)?) { self.progress = progress }

        func append(_ chunk: Data, isError: Bool) {
            lock.lock()
            if isError { err.append(chunk) } else { out.append(chunk) }
            guard let progress else { lock.unlock(); return }
            // Whole lines only: a percentage can be split across two reads. Tools
            // redraw progress with a carriage return, so that ends a line too.
            pending += String(decoding: chunk, as: UTF8.self)
            var lines: [String] = []
            while let end = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                lines.append(String(pending[pending.startIndex..<end]))
                pending = String(pending[pending.index(after: end)...])
            }
            lock.unlock()
            for line in lines where !line.isEmpty { progress(line) }
        }

        func result(code: Int32, timedOut: Bool) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return Result(code: code,
                          out: String(decoding: out, as: UTF8.self),
                          err: String(decoding: err, as: UTF8.self),
                          timedOut: timedOut)
        }
    }
}

// MARK: - Errors

struct ManagerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}
