// Hand-off into the Fixes pane from outside the window.
//
// The Steam store card runs in the headless store bridge (a separate process with no
// window), so it cannot show the Discord sign-in, the macOS folder-permission prompts
// or the backup records a fix install needs. It asks the config app for the game
// instead, through a request file the app picks up when it next becomes active.
import AppKit
import Darwin
import Foundation

enum FixesHandoff {
    static let notification = Notification.Name("com.macsteam.openFixes")
    static let appIDKey = "appID"
    /// A request this old is not worth acting on: the person has moved on.
    private static let maxAge: TimeInterval = 120

    private static var requestFile: URL {
        Paths.configDir.appendingPathComponent("fixes-request.json")
    }

    /// Ask macSteam Config to show the Fixes pane for `appID`, launching it if needed.
    @MainActor
    static func open(appID: Int) {
        guard appID > 0 else { return }
        write(appID: appID)
        // Covers an app that is already running: tryBecomeActive was no use if it never
        // lost focus, and the notification arrives without one.
        DistributedNotificationCenter.default.post(
            name: notification, object: nil, userInfo: [appIDKey: appID])
        if let running = runningApp(), running.activate(options: [.activateAllWindows]) {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration,
                                           completionHandler: nil)
    }

    /// The request `open(appID:)` left behind, taken once and only while it is fresh.
    static func takeRequest() -> Int? {
        guard let data = try? Data(contentsOf: requestFile) else { return nil }
        try? FileManager.default.removeItem(at: requestFile)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appID = object[appIDKey] as? Int, appID > 0 else { return nil }
        if let stamp = object["at"] as? Double,
           Date().timeIntervalSince1970 - stamp > maxAge { return nil }
        return appID
    }

    private static func write(appID: Int) {
        try? Paths.ensureDir(Paths.configDir)
        let object: [String: Any] = [appIDKey: appID, "at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: requestFile, options: .atomic)
    }

    /// The window's process: the helper's parent is the app, and unlike a bundle-ID lookup
    /// that cannot pick the helper itself or a stale Launch Services record of it.
    @MainActor
    private static func runningApp() -> NSRunningApplication? {
        let parent = getppid()
        if parent > 1,
           let app = NSRunningApplication(processIdentifier: parent),
           app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return app
        }
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        // macSteam Config and this app share a bundle identifier, so match on the bundle
        // too: activating the other one would show nothing.
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first {
                $0.processIdentifier != getpid() && $0.activationPolicy == .regular &&
                    $0.bundleURL?.standardizedFileURL == bundle
            }
    }
}
