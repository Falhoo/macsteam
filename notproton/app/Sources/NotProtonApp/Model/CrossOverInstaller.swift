// Runs the bundled CrossOver installer with administrator rights

import AppKit
import Foundation

/// Downloads CrossOver from CodeWeavers and installs it into /Applications by
/// running the bundle's crossover-install.sh. The script does the download, the
/// signature check and the install; the only thing asked of the user is the
/// administrator password macOS shows for `do shell script … with administrator
/// privileges`.
enum CrossOverInstaller {

    /// The release the Install button asks for: the newest 26.3.x. The script
    /// resolves the exact build from CodeWeavers' change log.
    static let defaultVersion = "26.3"

    static let target = URL(filePath: "/Applications/CrossOver.app", directoryHint: .isDirectory)

    private static let resourceName = "crossover-install"

    struct Failure: LocalizedError {
        let detail: String

        var errorDescription: String? { detail }
    }

    enum Outcome: Sendable {
        case installed
        case cancelled
    }

    static func install(
        version: String = defaultVersion,
        phase: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        guard let script = Bundle.module.url(forResource: resourceName, withExtension: "sh") else {
            throw Failure(detail: String(localized: "The CrossOver installer script is missing from the app."))
        }

        let files = FileManager.default
        let work = files.temporaryDirectory
            .appending(path: "NotProton-CrossOver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }

        let scriptCopy = work.appending(path: "crossover-install.sh")
        try files.copyItem(at: script, to: scriptCopy)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptCopy.path(percentEncoded: false))

        // The script keeps its download here instead of ~/cracks, so a run that
        // fails halfway leaves nothing behind outside this folder.
        let downloads = work.appending(path: "downloads", directoryHint: .isDirectory)
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)

        let log = work.appending(path: "install.log")
        _ = files.createFile(atPath: log.path(percentEncoded: false), contents: Data())

        // The script ends by opening CrossOver, and it runs as root: left alone
        // that starts CrossOver as root and leaves root-owned bottles behind, so
        // an `open` that does nothing goes first on PATH. The app is opened as
        // the signed-in user once it is installed.
        let shim = work.appending(path: "bin", directoryHint: .isDirectory)
        try files.createDirectory(at: shim, withIntermediateDirectories: true)
        let stub = shim.appending(path: "open")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: stub)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))

        let runner = work.appending(path: "run.sh")
        let body = launcher(
            home: files.homeDirectoryForCurrentUser.path(percentEncoded: false),
            shim: shim.path(percentEncoded: false),
            script: scriptCopy.path(percentEncoded: false),
            downloads: downloads.path(percentEncoded: false),
            version: version,
            log: log.path(percentEncoded: false),
            owner: Int(getuid())
        )
        try Data(body.utf8).write(to: runner)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path(percentEncoded: false))

        // The download is close to a gigabyte, so the log the script writes is
        // read while it runs and each stage becomes the Status view's activity.
        let monitor = Task.detached {
            var reported: String?
            while !Task.isCancelled {
                if let label = phaseLabel(log: log), label != reported {
                    reported = label
                    phase(label)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let result: CommandResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try Shell.run(
                    "/usr/bin/osascript",
                    ["-e", applescript(runner: runner.path(percentEncoded: false))]
                )
            }.value
        } catch {
            monitor.cancel()
            throw error
        }
        monitor.cancel()

        if result.status != 0 {
            let said = (result.stderr + logText(log)).lowercased()
            if said.contains("user canceled") || said.contains("-128") {
                return .cancelled
            }
            throw Failure(detail: detail(from: result, log: log))
        }

        guard files.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw Failure(detail: String(localized: "The installer finished but /Applications/CrossOver.app is not there."))
        }
        return .installed
    }

    // MARK: - Shell

    /// `do shell script` gives up after two minutes by default, and the
    /// download alone can take longer than that, so the command runs inside a
    /// `with timeout` block.
    private static func applescript(runner: String) -> String {
        [
            "with timeout of 3600 seconds",
            "do shell script \"'\(runner)'\" with administrator privileges",
            "end timeout",
        ].joined(separator: "\n")
    }

    /// The shell osascript runs as root, with the home folder and the PATH a
    /// terminal would give the script.
    private static func launcher(
        home: String,
        shim: String,
        script: String,
        downloads: String,
        version: String,
        log: String,
        owner: Int
    ) -> String {
        let license = #"$HOME/Library/Preferences/com.codeweavers.CrossOver.license"#
        let signature = #"$HOME/Library/Preferences/com.codeweavers.CrossOver.sha256"#

        let lines = [
            "#!/bin/bash",
            "# Started by osascript as root: put back the home folder and the PATH",
            "# the script expects from a terminal.",
            "export HOME=\(quote(home))",
            "export PATH=\(quote(shim)):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "export CROSSOVER_DIR=\(quote(downloads))",
            "",
            "/bin/bash \(quote(script)) -v \(quote(version)) >>\(quote(log)) 2>&1",
            "status=$?",
            "",
            "# The script writes these as root; hand them back to the user so",
            "# CrossOver can rewrite its own licence afterwards.",
            "chown -h \(owner) \"\(license)\" 2>/dev/null || true",
            "chown -h \(owner) \"\(signature)\" 2>/dev/null || true",
            "",
            "exit $status",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Reading the script's progress

    private static func logText(_ log: URL) -> String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// The last stage the script announced, in the order they happen.
    private static func phaseLabel(log: URL) -> String? {
        let text = logText(log)
        if text.contains("Installing into /Applications") {
            return String(localized: "Copying CrossOver into /Applications…")
        }
        if text.contains("Verifying the code signature") {
            return String(localized: "Checking CrossOver's signature…")
        }
        if text.contains("Extracting…") {
            return String(localized: "Unpacking CrossOver…")
        }
        if text.contains("Downloading http") {
            return String(localized: "Downloading CrossOver…")
        }
        return nil
    }

    /// The script's own message for a failed run, else what osascript said.
    private static func detail(from result: CommandResult, log: URL) -> String {
        let lines = logText(log)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let failure = lines.last(where: { $0.hasPrefix("error:") }) {
            return String(failure.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
        }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { return reason }
        return String(localized: "The CrossOver install failed.")
    }
}
