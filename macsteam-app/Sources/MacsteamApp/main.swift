import AppKit
import Dispatch
import Darwin
import NotProtonApp

// NotProton can be started by Steam with command-line flags (rebuild a game's prefix, remove
// everything). This handles those and exits; for a normal launch it returns straight away.
NotProtonLaunch.handleCommandLineModes()

// Headless save sync, run by macSteam inside Steam: --cloud-sync push|pull.
if let index = CommandLine.arguments.firstIndex(of: "--cloud-sync") {
    let direction = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "push"
    exit(CloudSync.run(direction: direction))
}

// Writes the OnlineFix Manager's list and toggles into config.yaml, then exits.
if CommandLine.arguments.contains("--onlinefix-sync") {
    exit(OnlineFixSync.run())
}

// Installs (or updates) CloudRedirect's runtime in Steam and exits.
if CommandLine.arguments.contains("--install-cloud-redirect") {
    do {
        try CloudRedirectRuntime.install()
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

// Runs the same install the Install page does, without the window: deploy the
// bundled dylib, CloudRedirect and OnlineFix, write the injection list. Steam is
// restarted by the installer.
if CommandLine.arguments.contains("--install") {
    guard let dylib = Bundle.main.url(forResource: "macsteam", withExtension: "dylib") else {
        FileHandle.standardError.write(Data("macsteam.dylib is missing from this app.\n".utf8))
        exit(EXIT_FAILURE)
    }
    do {
        try SteamInstaller.install(sourceDylib: dylib)
        print("Installed macSteam into /Applications/Steam.app")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--hubcap-store-bridge") {
    // Do not create NSApplication here: registering the invisible helper with
    // Launch Services makes it look like the config window is already open.
    let bridge = HubcapStoreBridge()
    Task { await bridge.run(); exit(EXIT_SUCCESS) }
    dispatchMain()
} else if CommandLine.arguments.contains("--diagnose-playing") {
    // Read-only: what does Steam report as the running game, and under what name?
    Task { exit(await SteamPlayingDiagnostic.run()) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    if #available(macOS 14, *) {
        app.activate()
    } else {
        app.activate(ignoringOtherApps: true)
    }
    app.run()
}
