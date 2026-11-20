// Headless mode: `MacsteamApp --cloud-sync push|pull`.
//
// The dylib inside Steam runs this after a game closes, and again when Steam
// starts, so the account copy stays current without the config window being
// open. Nothing here touches AppKit.

import Foundation

enum CloudSync {
    static func run(direction: String) -> Int32 {
        let settings = CloudSettings.load()

        guard settings.enabled, settings.usesRemote else {
            message("the online account is off")
            return 1
        }
        let config = settings.remoteConfig
        guard config.isUsable else {
            message("the account address is missing or not a web address")
            return 1
        }

        let root = settings.storeRoot
        let google = settings.usesGoogle
        let oneDrive = settings.usesOneDrive
        if google {
            guard settings.googleConfig.isUsable else {
                message("no Google client ID")
                return 1
            }
            guard GoogleDrive.isSignedIn() else {
                message("not signed in to Google Drive")
                return 1
            }
        }
        if oneDrive {
            guard settings.oneDriveConfig.isUsable else {
                message("no Microsoft client ID")
                return 1
            }
            guard OneDrive.isSignedIn() else {
                message("not signed in to OneDrive")
                return 1
            }
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let count: Int
            if direction == "pull" {
                if google {
                    count = try GoogleDrive.pull(into: root, config: settings.googleConfig)
                } else if oneDrive {
                    count = try OneDrive.pull(into: root, config: settings.oneDriveConfig)
                } else {
                    count = try RemoteStore.download(into: root, config: config)
                }
            } else {
                if google {
                    count = try GoogleDrive.push(from: root, config: settings.googleConfig)
                } else if oneDrive {
                    count = try OneDrive.push(from: root, config: settings.oneDriveConfig)
                } else {
                    count = try RemoteStore.upload(from: root, config: config)
                }
            }
            print("cloud-sync: \(direction == "pull" ? "pulled" : "pushed") \(count) file(s)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("cloud-sync: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func message(_ text: String) {
        FileHandle.standardError.write(Data("cloud-sync: \(text)\n".utf8))
    }
}
