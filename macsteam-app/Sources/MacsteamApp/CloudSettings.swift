// The save-backup settings the dylib reads from cloud.yaml.
//
// The file is shared: macSteam writes to it too (finding a game's save folder
// adds a line under Folders), so this only ever rewrites the keys it owns and
// keeps every other line as it was.

import Foundation

struct CloudSettings {
    enum Provider: String, CaseIterable {
        case macSteam
        case iCloud
        case oneDrive
        case googleDrive
        case dropbox
        case custom

        var title: String {
            switch self {
            case .macSteam: return "macSteam folder"
            case .iCloud: return "iCloud Drive"
            case .oneDrive: return "OneDrive"
            case .googleDrive: return "Google Drive"
            case .dropbox: return "Dropbox"
            case .custom: return "Another folder…"
            }
        }

        /// Where this provider's folder is on this Mac, or nil when it is not
        /// installed (or, for macSteam, when its own folder is meant).
        var folder: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .macSteam, .custom:
                return nil
            case .iCloud:
                let root = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                                       isDirectory: true)
                guard FileManager.default.fileExists(atPath: root.path) else { return nil }
                return root.appendingPathComponent("macSteam Saves", isDirectory: true)
            case .oneDrive:
                if let match = Self.firstChild(of: home.appendingPathComponent("Library/CloudStorage",
                                                                                isDirectory: true),
                                               prefix: "OneDrive")
                { return match.appendingPathComponent("macSteam Saves", isDirectory: true) }
                let legacy = home.appendingPathComponent("OneDrive", isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    return legacy.appendingPathComponent("macSteam Saves", isDirectory: true)
                }
                return nil
            case .googleDrive:
                guard let match = Self.firstChild(of: home.appendingPathComponent("Library/CloudStorage",
                                                                                  isDirectory: true),
                                                  prefix: "GoogleDrive") else { return nil }
                return match.appendingPathComponent("My Drive/macSteam Saves", isDirectory: true)
            case .dropbox:
                let root = home.appendingPathComponent("Dropbox", isDirectory: true)
                guard FileManager.default.fileExists(atPath: root.path) else { return nil }
                return root.appendingPathComponent("macSteam Saves", isDirectory: true)
            }
        }

        var isInstalled: Bool {
            switch self {
            case .macSteam, .custom: return true
            default: return folder != nil
            }
        }

        private static func firstChild(of dir: URL, prefix: String) -> URL? {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard let name = names.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            return dir.appendingPathComponent(name, isDirectory: true)
        }
    }

    var enabled = false
    var autoDetect = true
    var restoreAll = true
    /// Empty means the macSteam folder; otherwise the exact folder to keep
    /// backups in. The dylib only reads this one.
    var destination = ""
    var provider: Provider = .macSteam
    var folders: [Int: String] = [:]
    /// Top-level lines the dylib owns and this pane does not, kept verbatim.
    var extras: [String] = []

    /// When set, the backups are pushed to and fetched from an account instead
    /// of staying in a folder on this Mac.
    var remoteKind = ""        // "", "webdav" or "google"
    var remoteURL = ""
    var remoteUser = ""
    var googleClientID = ""
    var oneDriveClientID = ""

    static var fileURL: URL {
        Paths.configDir.appendingPathComponent("cloud.yaml")
    }

    /// The folder every backup ends up in, matching what the dylib computes.
    var storeRoot: URL {
        // The backups always live in the local folder; an online service is an
        // extra copy of that same folder, not a replacement for it.
        if !destination.isEmpty, let url = Self.url(forPath: destination) { return url }
        if let url = provider.folder { return url }
        return Paths.configDir.appendingPathComponent("cloud", isDirectory: true)
    }

    var usesRemote: Bool {
        remoteKind == "webdav" || remoteKind == "google" || remoteKind == "onedrive"
    }

    var usesGoogle: Bool { remoteKind == "google" }

    /// The client ID to sign in with: the one in cloud.yaml, or the one the
    /// build ships with.
    var clientID: String { googleClientID.isEmpty ? GoogleDrive.builtInClientID : googleClientID }

    var googleConfig: GoogleDriveConfig {
        GoogleDriveConfig(clientID: clientID)
    }

    var usesOneDrive: Bool { remoteKind == "onedrive" }

    var oneDriveClientIDValue: String {
        oneDriveClientID.isEmpty ? OneDrive.builtInClientID : oneDriveClientID
    }

    var oneDriveConfig: OneDriveConfig {
        OneDriveConfig(clientID: oneDriveClientIDValue)
    }

    var remoteConfig: RemoteConfig {
        RemoteConfig(url: remoteURL, user: remoteUser, password: CloudSettings.remotePassword())
    }

    static let remoteKeychainService = "com.macsteam.cloud"
    static let remoteKeychainAccount = "webdav"

    static func remotePassword() -> String {
        KeychainStore.read(account: remoteKeychainAccount, service: remoteKeychainService) ?? ""
    }

    static func saveRemotePassword(_ value: String) throws {
        if value.isEmpty {
            try KeychainStore.delete(account: remoteKeychainAccount, service: remoteKeychainService)
        } else {
            try KeychainStore.write(value, account: remoteKeychainAccount, service: remoteKeychainService)
        }
    }

    func folderIsWritable() -> Bool {
        let manager = FileManager.default
        let root = storeRoot
        if manager.fileExists(atPath: root.path) {
            return manager.isWritableFile(atPath: root.path)
        }
        let parent = root.deletingLastPathComponent()
        return manager.isWritableFile(atPath: parent.path)
    }

    // MARK: - Disk

    static func load() -> CloudSettings {
        var settings = CloudSettings()
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return settings
        }

        var inFolders = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if inFolders {
                if line.first == " " || line.first == "\t" {
                    if let (id, path) = folderLine(trimmed) { settings.folders[id] = path }
                    continue
                }
                inFolders = false
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "Enabled": settings.enabled = isOn(value)
            case "Cloud": settings.enabled = isOn(value)      // the older key
            case "AutoDetect": settings.autoDetect = isOn(value)
            case "RestoreAll": settings.restoreAll = isOn(value)
            case "Destination": settings.destination = unquoted(value)
            case "Provider": settings.provider = Provider(rawValue: unquoted(value)) ?? .macSteam
            case "Remote": settings.remoteKind = unquoted(value).lowercased()
            case "RemoteURL": settings.remoteURL = unquoted(value)
            case "RemoteUser": settings.remoteUser = unquoted(value)
            case "GoogleClientID": settings.googleClientID = unquoted(value)
            case "OneDriveClientID": settings.oneDriveClientID = unquoted(value)
            case "Folders": inFolders = true
            case "Helper":
                // save() writes this from the running executable. Left as an
                // unknown line it would be carried forward, and since the dylib
                // reads only the first one, an app that moved (or was renamed)
                // would keep calling its old location forever.
                continue
            case "Restore", "CloudRestore":
                settings.extras.append("\(key): \(value)")
            default:
                settings.extras.append("\(key): \(value)")
            }
        }
        return settings
    }

    func save() throws {
        var out = """
        # macSteam save backups
        #
        # Read by macSteam inside Steam. Folders is filled in automatically when a
        # game's save folder is found; lines this app does not know are kept.

        """
        out += "Enabled: \(enabled ? "yes" : "no")\n"
        out += "AutoDetect: \(autoDetect ? "yes" : "no")\n"
        out += "RestoreAll: \(restoreAll ? "yes" : "no")\n"
        if !destination.isEmpty {
            out += "Destination: \(destination)\n"
        }
        out += "Provider: \(provider.rawValue)\n"
        if let executable = Bundle.main.executablePath {
            out += "Helper: \(executable)\n"
        }
        if usesRemote {
            out += "Remote: \(remoteKind)\n"
            if usesGoogle {
                out += "GoogleClientID: \(googleClientID)\n"
            } else if usesOneDrive {
                out += "OneDriveClientID: \(oneDriveClientID)\n"
            } else {
                out += "RemoteURL: \(remoteURL)\n"
                out += "RemoteUser: \(remoteUser)\n"
            }
        }
        for line in extras where !line.isEmpty {
            out += line + "\n"
        }
        if !folders.isEmpty {
            out += "Folders:\n"
            for (id, path) in folders.sorted(by: { $0.key < $1.key }) {
                out += "  \(id): \(path)\n"
            }
        }

        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Usage

    struct Usage {
        var apps = 0
        var files = 0
        var bytes: Int64 = 0

        var sizeText: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }

    func usage() -> Usage {
        var result = Usage()
        let manager = FileManager.default
        guard let apps = try? manager.contentsOfDirectory(at: storeRoot,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else {
            return result
        }

        for app in apps {
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue else { continue }
            var counted = false
            let walker = manager.enumerator(at: app,
                                            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                            options: [.skipsHiddenFiles])
            while let entry = walker?.nextObject() as? URL {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                result.files += 1
                result.bytes += Int64(values?.fileSize ?? 0)
                counted = true
            }
            if counted { result.apps += 1 }
        }
        return result
    }

    // MARK: - Helpers

    static func url(forPath path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func isOn(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasPrefix("y") || v == "1" || v.hasPrefix("true")
    }

    private static func unquoted(_ value: String) -> String {
        var v = value
        if v.count >= 2, (v.hasPrefix("\"") || v.hasPrefix("'")), v.hasSuffix(String(v.first!)) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func folderLine(_ line: String) -> (Int, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let idText = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard let id = Int(idText), id > 0 else { return nil }
        let path = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : (id, path)
    }
}
