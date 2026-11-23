import AppKit
import Dispatch
import Darwin
import NotProtonApp
import OnlineFixApp

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

// Takes OnlineFix out and leaves macSteam and NotProton in place: its manager state,
// its section in config.yaml, its dylib and environment keys, and the files and
// Photon patches it put in the games' folders. --keep-gamefiles leaves those files so
// another attempt needs no download. This is what scripts/onlinefix-lab.sh calls.
if CommandLine.arguments.contains("--uninstall-onlinefix") {
    exit(OnlineFixCommand.uninstall(
        keepGameFiles: CommandLine.arguments.contains("--keep-gamefiles")))
}

// Installs the OnlineFix fix for one AppID without the window, for the lab:
// --onlinefix-install <appid> [--name <name>].
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-install"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var name = ""
    if let nameIndex = CommandLine.arguments.firstIndex(of: "--name"),
       CommandLine.arguments.count > nameIndex + 1 {
        name = CommandLine.arguments[nameIndex + 1]
    }
    Task { @MainActor in
        let code = await OnlineFixCommand.install(appID: appID, name: name)
        // The window writes the routing into config.yaml after an install; do the same
        // here, so a script's game launches routed on its first try.
        if code == 0 { _ = OnlineFixSync.run() }
        exit(code)
    }
    dispatchMain()
}

// Reads the Photon app ids a game carries and says what the automatic patch would do
// with them, writing nothing: --photon-ids <appid> [--name <name>]. This is the lab's
// read-only check, so a game whose id is not found shows up before a fix is installed.
if let index = CommandLine.arguments.firstIndex(of: "--photon-ids"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var name = ""
    if let nameIndex = CommandLine.arguments.firstIndex(of: "--name"),
       CommandLine.arguments.count > nameIndex + 1 {
        name = CommandLine.arguments[nameIndex + 1]
    }
    exit(OnlineFixCommand.photonIDs(appID: appID, name: name))
}

// Reports what a game and a fix package need, writing nothing:
// --onlinefix-diagnose <appid> [--name <name>].
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-diagnose"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var name = ""
    if let nameIndex = CommandLine.arguments.firstIndex(of: "--name"),
       CommandLine.arguments.count > nameIndex + 1 {
        name = CommandLine.arguments[nameIndex + 1]
    }
    exit(OnlineFixCommand.diagnose(appID: appID, name: name))
}

// Keeps a game's own Steam API and relies on the routing, for a game whose fix loader
// never opens it: --onlinefix-routing-only <appid>.
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-routing-only"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    exit(OnlineFixCommand.routingOnly(appID: appID))
}

// Launches a game through Steam and reports whether its window appeared, which is the
// only proof that a fix actually runs it: --onlinefix-probe <appid> [--seconds N].
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-probe"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var seconds: Double = 75
    if let secondsIndex = CommandLine.arguments.firstIndex(of: "--seconds"),
       CommandLine.arguments.count > secondsIndex + 1,
       let value = Double(CommandLine.arguments[secondsIndex + 1]) {
        seconds = value
    }
    var settle: Double = 0
    if let settleIndex = CommandLine.arguments.firstIndex(of: "--settle"),
       CommandLine.arguments.count > settleIndex + 1,
       let value = Double(CommandLine.arguments[settleIndex + 1]) {
        settle = value
    }
    exit(OnlineFixCommand.probe(appID: appID, seconds: seconds, settle: settle))
}

// Reads the game's own log and says what Photon made of its last connection:
// --onlinefix-photon <appid> [--name <name>]. Read only.
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-photon"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var name = ""
    if let nameIndex = CommandLine.arguments.firstIndex(of: "--name"),
       CommandLine.arguments.count > nameIndex + 1 {
        name = CommandLine.arguments[nameIndex + 1]
    }
    exit(OnlineFixCommand.photon(appID: appID, name: name))
}

// Puts the complete BepInEx chain into a Photon game that already has its fix:
// --onlinefix-photon-chain <appid> [--name <name>].
if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-photon-chain"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var name = ""
    if let nameIndex = CommandLine.arguments.firstIndex(of: "--name"),
       CommandLine.arguments.count > nameIndex + 1 {
        name = CommandLine.arguments[nameIndex + 1]
    }
    exit(OnlineFixCommand.photonChain(appID: appID, name: name))
}

// Replaces the Photon app id a game carries with OnlineFix's, so it meets the other
// copies on OnlineFix's Photon app: --photon-swap <appid> [--id <guid>].
if let index = CommandLine.arguments.firstIndex(of: "--photon-swap"),
   CommandLine.arguments.count > index + 1,
   let appID = Int(CommandLine.arguments[index + 1]) {
    var id = ""
    if let idIndex = CommandLine.arguments.firstIndex(of: "--id"),
       CommandLine.arguments.count > idIndex + 1 {
        id = CommandLine.arguments[idIndex + 1]
    }
    exit(OnlineFixCommand.photonSwap(appID: appID, id: id))
}

// Puts back whatever a fix pack says has changed, for one game or all of them:
// --onlinefix-repair <appid> | --onlinefix-repair --all.
if CommandLine.arguments.contains("--onlinefix-repair") {
    if CommandLine.arguments.contains("--all") {
        exit(OnlineFixCommand.repair())
    }
    if let index = CommandLine.arguments.firstIndex(of: "--onlinefix-repair"),
       CommandLine.arguments.count > index + 1,
       let appID = Int(CommandLine.arguments[index + 1]) {
        exit(OnlineFixCommand.repair(appID: appID))
    }
    exit(OnlineFixCommand.repair())
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
