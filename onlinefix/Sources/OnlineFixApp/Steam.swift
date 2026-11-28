import AppKit
import Foundation

/// Steam client discovery, build detection, profile deployment and
/// dylib install/uninstall.
enum Steam {

    static let bundleIdentifier = "com.valvesoftware.steam"

    // MARK: - Status

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func steamAppExists() -> Bool {
        Paths.fm.fileExists(atPath: Paths.steamApp.path)
    }

    static func detectBuild() -> (build: String?, manifest: URL?) {
        let names = [
            "steam_client_signed-2_osx.manifest",
            "steam_client_signed_osx.manifest",
            "steam_client_osx.manifest",
        ]
        for name in names {
            let url = Paths.packageDir.appendingPathComponent(name)
            guard Paths.fm.fileExists(atPath: url.path) else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let v = parseVersion(text) {
                return (v, url)
            }
        }
        if let entries = try? Paths.fm.contentsOfDirectory(atPath: Paths.packageDir.path) {
            for entry in entries where entry.hasPrefix("steam_client_") && entry.hasSuffix(".manifest") {
                let url = Paths.packageDir.appendingPathComponent(entry)
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let v = parseVersion(text) {
                    return (v, url)
                }
            }
        }
        return (nil, nil)
    }

    static func parseVersion(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"version\"") else { continue }
            let parts = trimmed.split(separator: "\"").map(String.init)
            if let value = parts.last(where: {
                !$0.isEmpty && $0 != "version" && !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The compatibility tool a game is pinned to, if any, read from Steam's own
    /// config. A pinned tool is how Steam runs the Windows build, so it outranks the
    /// folder: a game that ships both builds keeps the Mac one on disk underneath.
    static func forcedCompatTool(appID: Int) -> String? {
        let users = (try? Paths.fm.contentsOfDirectory(
            at: Paths.steamSupport.appendingPathComponent("userdata", isDirectory: true),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for user in users {
            let file = user.appendingPathComponent("config/localconfig.vdf")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let mapping = text.range(of: "\"CompatToolMapping\"") else { continue }
            let rest = text[mapping.upperBound...]
            guard let block = rest.range(of: "\"\\(appID)\"") else { continue }
            let body = rest[block.upperBound...].prefix(400)
            guard let name = body.range(of: "\"name\""),
                  let value = body[name.upperBound...].range(of: "\"[^\"]*\"") else { continue }
            let tool = body[name.upperBound...][value].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !tool.isEmpty { return tool }
        }
        return nil
    }

    /// The newest NotProton compatibility tool installed for Steam, e.g.
    /// "notproton-26.3". Empty when NotProton is not installed.
    static func notProtonTool() -> String? {
        let dir = Paths.steamSupport.appendingPathComponent("compatibilitytools.d", isDirectory: true)
        let names = (try? Paths.fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { name in
                name.lowercased().hasPrefix("notproton")
                    && Paths.fm.fileExists(atPath: dir.appendingPathComponent(name).path)
            }
            .sorted()
            .last
    }

    // MARK: - Resources

    static func bundledResource(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           Paths.fm.fileExists(atPath: url.path) {
            return url
        }
        if let res = Bundle.main.resourceURL {
            let url = res.appendingPathComponent(name)
            if Paths.fm.fileExists(atPath: url.path) { return url }
        }
        // Running from a plain build directory: look in ./vendor next to the package.
        let packageRoot = URL(fileURLWithPath: Paths.fm.currentDirectoryPath)
        let dev = packageRoot.appendingPathComponent("vendor").appendingPathComponent(name)
        if Paths.fm.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    static func bundledRuntimeProfiles() -> [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("runtime"))
        }
        dirs.append(URL(fileURLWithPath: Paths.fm.currentDirectoryPath)
            .appendingPathComponent("vendor/runtime"))
        for dir in dirs {
            guard let items = try? Paths.fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let json = items.filter { $0.pathExtension == "json" }
            if !json.isEmpty { return json.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        }
        return []
    }

    /// Copies bundled profiles into the runtime folder without overwriting existing ones,
    /// so the installed dylib always finds a profile for the running build.
    @discardableResult
    static func deployProfiles() throws -> [String] {
        try Paths.ensureDir(Paths.runtimeDir)
        var deployed: [String] = []
        for src in bundledRuntimeProfiles() {
            let dst = Paths.runtimeDir.appendingPathComponent(src.lastPathComponent)
            if !Paths.fm.fileExists(atPath: dst.path) {
                try Paths.fm.copyItem(at: src, to: dst)
                deployed.append(src.lastPathComponent)
            }
        }
        return deployed
    }

    static func runtimeProfiles() -> [String] {
        guard let items = try? Paths.fm.contentsOfDirectory(atPath: Paths.runtimeDir.path) else { return [] }
        return items.filter { $0.hasSuffix(".json") }.sorted()
    }

    static func profileStatus() -> ProfileStatus {
        let (build, _) = detectBuild()
        var runtimeHas = false
        if let build {
            runtimeHas = Paths.fm.fileExists(
                atPath: Paths.runtimeDir.appendingPathComponent("\(build).json").path
            )
        }
        let bundled = bundledRuntimeProfiles().map { $0.lastPathComponent }
        let note: String
        switch (build, runtimeHas) {
        case (.none, _):
            note = "Steam client build could not be read. Start Steam once so it finishes setting up."
        case (let b?, true):
            note = "A compatibility profile for build \(b) is installed."
        case (let b?, false):
            note = "No profile for build \(b). Click “Deploy profiles” to install the bundled ones."
        }
        return ProfileStatus(detectedBuild: build, bundledProfiles: bundled, runtimeProfile: runtimeHas, note: note)
    }

    // MARK: - Install state

    static func loadInstallRecord() -> InstallRecord? {
        guard let data = try? Data(contentsOf: Paths.installationFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let rec = try? decoder.decode(InstallRecord.self, from: data) { return rec }
        // Tolerate the original app's record (no installedAt).
        return try? JSONDecoder().decode(InstallRecord.self, from: data)
    }

    static func saveInstallRecord(_ record: InstallRecord) throws {
        try Paths.ensureDir(Paths.appSupport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: Paths.installationFile, options: .atomic)
    }

    static func installPhase() -> InstallPhase {
        guard let record = loadInstallRecord() else {
            // No record: if a dylib is lying around from an older attempt, installing repairs it.
            return .notInstalled
        }
        guard Paths.fm.fileExists(atPath: record.appPath) else {
            return .broken("Steam.app is missing at \(record.appPath)")
        }
        // A leftover record whose dylib is gone (Steam was restored or updated) is not a
        // dead end — installing again repairs it, so treat it as "not installed".
        guard Paths.fm.fileExists(atPath: Paths.installedDylib.path) else { return .notInstalled }
        guard let plist = try? readPlist(Paths.steamInfoPlist),
              let env = plist["LSEnvironment"] as? [String: Any],
              let insert = env["DYLD_INSERT_LIBRARIES"] as? String,
              insert.contains(Paths.installedDylib.path)
        else {
            return .incomplete("The patch is present but Steam isn't loading it yet")
        }
        return .installed
    }

    // MARK: - Plist helpers

    static func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ManagerError("\(url.lastPathComponent) is not a property list dictionary.")
        }
        return object
    }

    static func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Install / uninstall

    static func install(progress: (String) -> Void) throws {
        guard steamAppExists() else { throw ManagerError("Steam.app was not found at \(Paths.steamApp.path).") }
        guard !isRunning() else { throw ManagerError("Steam is running. Quit Steam and try again.") }
        guard let dylibSource = bundledResource("onlinefix.dylib") else {
            throw ManagerError("onlinefix.dylib is missing from this app’s resources.")
        }

        try Paths.ensureDir(Paths.appSupport)
        try deployProfiles()

        progress("Backing up Steam.app…")
        let backup = Paths.backupDir.appendingPathComponent("Steam.app")
        if !Paths.fm.fileExists(atPath: backup.path) {
            try Paths.ensureDir(Paths.backupDir)
            try Paths.fm.copyItem(at: Paths.steamApp, to: backup)
        }

        progress("Installing onlinefix.dylib…")
        let originalHash = Hash.sha256(Paths.steamInfoPlist) ?? ""
        if Paths.fm.fileExists(atPath: Paths.installedDylib.path) {
            try Paths.fm.removeItem(at: Paths.installedDylib)
        }
        try Paths.fm.copyItem(at: dylibSource, to: Paths.installedDylib)

        progress("Configuring Steam environment…")
        var plist = try readPlist(Paths.steamInfoPlist)
        var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        var insert = env["DYLD_INSERT_LIBRARIES"] as? String ?? ""
        if !insert.contains(Paths.installedDylib.path) {
            insert = insert.isEmpty ? Paths.installedDylib.path : insert + ":" + Paths.installedDylib.path
        }
        env["DYLD_INSERT_LIBRARIES"] = insert
        env["ONLINEFIX_SIG"] = Paths.runtimeDir.path
        env["ONLINEFIX_CONFIG"] = Paths.gamesFile.path
        env["ONLINEFIX_LOG"] = Paths.logFile.path
        plist["LSEnvironment"] = env
        try writePlist(plist, to: Paths.steamInfoPlist)

        progress("Re-signing Steam.app (ad-hoc)…")
        try codesign(Paths.steamApp)

        let installedHash = Hash.sha256(Paths.steamInfoPlist) ?? ""
        try saveInstallRecord(InstallRecord(
            appPath: Paths.steamApp.path,
            originalHash: originalHash,
            installedHash: installedHash
        ))
        progress("Done.")
    }

    static func uninstall(progress: (String) -> Void) throws {
        guard !isRunning() else { throw ManagerError("Steam is running. Quit Steam and try again.") }
        progress("Removing onlinefix.dylib…")
        if Paths.fm.fileExists(atPath: Paths.installedDylib.path) {
            try Paths.fm.removeItem(at: Paths.installedDylib)
        }

        progress("Restoring Steam.app from backup…")
        let backup = Paths.backupDir.appendingPathComponent("Steam.app")
        if Paths.fm.fileExists(atPath: backup.path) {
            if Paths.fm.fileExists(atPath: Paths.steamApp.path) {
                try Paths.fm.removeItem(at: Paths.steamApp)
            }
            try Paths.fm.copyItem(at: backup, to: Paths.steamApp)
        } else {
            // No backup: strip the environment entries from the current bundle.
            if Paths.fm.fileExists(atPath: Paths.steamInfoPlist.path) {
                var plist = try readPlist(Paths.steamInfoPlist)
                if var env = plist["LSEnvironment"] as? [String: Any] {
                    let kept = (env["DYLD_INSERT_LIBRARIES"] as? String ?? "")
                        .split(separator: ":")
                        .map(String.init)
                        .filter { $0 != Paths.installedDylib.path }
                    if kept.isEmpty { env.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
                    else { env["DYLD_INSERT_LIBRARIES"] = kept.joined(separator: ":") }
                    env.removeValue(forKey: "ONLINEFIX_SIG")
                    env.removeValue(forKey: "ONLINEFIX_CONFIG")
                    env.removeValue(forKey: "ONLINEFIX_LOG")
                    plist["LSEnvironment"] = env
                    try writePlist(plist, to: Paths.steamInfoPlist)
                }
            }
            try codesign(Paths.steamApp)
        }

        try? Paths.fm.removeItem(at: Paths.installationFile)
        progress("Done.")
    }

    static func codesign(_ url: URL) throws {
        let result = Shell.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", url.path])
        guard result.code == 0 else {
            throw ManagerError("codesign failed: \(result.err.isEmpty ? result.out : result.err)")
        }
        let verify = Shell.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        guard verify.code == 0 else {
            throw ManagerError("Steam.app failed signature verification: \(verify.err.isEmpty ? verify.out : verify.err)")
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
