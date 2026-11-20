// CloudRedirect: the Steam-native cloud backend.
//
// Its dylib (vendor/cloudredirect, built by scripts/build-cloudredirect.sh and
// deployed by SteamInstaller) hooks the client's cloud RPCs and reads/writes the
// saves through the provider in its own config. macSteam ships and installs it,
// writes that configuration here, and turns its own save snapshots off so two
// systems never write the same files.

import Foundation

enum CloudRedirect {
    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CloudRedirect/config.json")
    }

    static var statusFile: URL {
        configFile.deletingLastPathComponent().appendingPathComponent("runtime-status.json")
    }

    // MARK: - Provider settings

    /// The runtime's provider: local, folder, gdrive, onedrive, r2 or s3.
    static func provider() -> String {
        config()["provider"] as? String ?? "local"
    }

    /// The folder a "folder" provider syncs to.
    static func syncFolder() -> String {
        let config = config()
        return config["sync_folder_path"] as? String ?? config["sync_path"] as? String ?? ""
    }

    static func setProvider(_ provider: String) {
        update { $0["provider"] = provider }
    }

    static func setSyncFolder(_ path: String) {
        update { $0["sync_folder_path"] = path }
    }

    private static func config() -> [String: Any] {
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func update(_ change: (inout [String: Any]) -> Void) {
        var object = config()
        change(&object)
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: configFile, options: .atomic)
    }

    /// Makes sure the runtime has a config, then stops macSteam's own snapshot
    /// journal. The Cloud Redirect page owns the provider setup from then on, so
    /// an existing config (Google Drive, OneDrive, R2, S3, folder) is left alone.
    @discardableResult
    static func configure() -> URL? {
        let fm = FileManager.default

        if !fm.fileExists(atPath: configFile.path) {
            var destination = CloudSettings.load().destination
            if destination.isEmpty {
                destination = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/macSteam Saves").path
            }
            let expanded = (destination as NSString).expandingTildeInPath
            try? fm.createDirectory(atPath: expanded, withIntermediateDirectories: true)

            let config: [String: Any] = [
                "enabled": true,
                "provider": "folder",
                "sync_path": expanded,
                "sync_luas": false,
                "manifest_pinning": false,
                "stats_sync_enabled": false,
                "sync_achievements": false,
                "sync_playtime": false,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: config,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? fm.createDirectory(at: configFile.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? data.write(to: configFile, options: .atomic)
            }
        }

        // One cloud system at a time: with CloudRedirect saving through Steam
        // itself, macSteam's own snapshots must stop.
        var settings = CloudSettings.load()
        if settings.enabled {
            settings.enabled = false
            try? settings.save()
        }
        return configFile
    }

    /// What the runtime said last time Steam started with it loaded.
    static func lastStatus() -> String? {
        guard let data = try? Data(contentsOf: statusFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let active = (object["active"] as? Bool) == true
        let message = object["message"] as? String ?? ""
        return "\(active ? "active" : "inactive")\(message.isEmpty ? "" : ": \(message)")"
    }
}
