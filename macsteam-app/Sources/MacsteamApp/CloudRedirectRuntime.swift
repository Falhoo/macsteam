// CloudRedirect's runtime, installed with macSteam's own Install.
//
// Uses CloudRedirect's upstream installer so the dylib, credential helper,
// injection list and Steam signature are handled exactly as their app does.

import CloudRedirectSupport
import Foundation

enum CloudRedirectRuntime {
    static var isBundled: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let runtime = resources.appendingPathComponent("runtime/cloud_redirect.dylib")
        return FileManager.default.fileExists(atPath: runtime.path)
    }

    static var isInstalled: Bool { (try? RuntimeContent.current()) == true }

    static func install() throws {
        guard isBundled else { return }
        // macSteam kills Steam just before this; give it a moment to leave the
        // running-applications list, or CloudRedirect's installer refuses.
        let deadline = Date().addingTimeInterval(3)
        while RuntimeInstaller.isSteamRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        try RuntimeInstaller.install(true)
    }

    static func remove() throws {
        try RuntimeInstaller.install(false)
    }
}
