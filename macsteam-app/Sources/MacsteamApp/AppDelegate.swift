import AppKit
import NotProtonApp
import OnlineFixApp

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appName = "macSteam"
    let store = ConfigStore()
    private let updaterManager = UpdaterManager.shared
    var window: NSWindow!
    var mainVC: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if enforceSingleInstance() { return }

        store.load()
        installOnlineFixRouting()
        HubcapStoreBridge.registerExecutable()
        updaterManager.start()
        NotProtonEmbed.start()

        buildMenu()
        observeFixesHandoff()
        observeOnlineFixHandoff()

        mainVC = MainViewController(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = appName
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.contentViewController = mainVC

        window.isRestorable = false
        window.contentMinSize = NSSize(width: 720, height: 480)

        window.autorecalculatesKeyViewLoop = true
        window.identifier = NSUserInterfaceItemIdentifier("MacsteamMainWindow")

        let toolbar = NSToolbar(identifier: "MacsteamMainToolbar")
        toolbar.delegate = mainVC
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setFrameAutosaveName("MacsteamMainWindow.v2")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.setContentSize(NSSize(width: 820, height: 560))
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        consumeFixesRequest()
    }

    /// The Steam store page cannot install a fix (it runs in a windowless helper), so it
    /// leaves a request for the game here; see FixesHandoff.
    private func observeFixesHandoff() {
        DistributedNotificationCenter.default.addObserver(
            forName: FixesHandoff.notification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.consumeFixesRequest() }
        }
    }

    /// The OnlineFix Manager owns the routing macSteam's dylib applies at a game's
    /// launch: its list and toggles are copied into config.yaml whenever they change.
    private func installOnlineFixRouting() {
        OnlineFixRouting.didChange = { [weak self] entries in
            guard let self else { return }
            var probe = self.store.config
            guard OnlineFixRoutingBridge.merge(entries, into: &probe) else { return }
            try? self.store.mutate { cfg in
                _ = OnlineFixRoutingBridge.merge(entries, into: &cfg)
            }
        }
        OnlineFixEmbed.pushRouting()
    }

    /// The Apps pane's OnlineFix item opens the merged OnlineFix Manager page;
    /// see OnlineFixHandoff.
    private func observeOnlineFixHandoff() {
        NotificationCenter.default.addObserver(
            forName: OnlineFixHandoff.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let appID = note.userInfo?[OnlineFixHandoff.appIDKey] as? Int else { return }
            Task { @MainActor in self?.mainVC?.openOnlineFix(appID: appID) }
        }
    }

    private func consumeFixesRequest() {
        guard let appID = FixesHandoff.takeRequest() else { return }
        // After this run-loop turn, so a window that is still being shown does not then
        // fall back to the default pane.
        DispatchQueue.main.async { [weak self] in
            self?.mainVC?.openFixes(appID: appID)
        }
    }

    @objc private func checkForUpdatesMenu() {
        updaterManager.checkForUpdates()
    }

    private func enforceSingleInstance() -> Bool {
        guard let me = Bundle.main.bundleIdentifier else { return false }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me && $0.processIdentifier != getpid() &&
                $0.activationPolicy == .regular
        }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdatesMenu),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu()
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Import Zip…",
                         action: #selector(MainViewController.importZip), keyEquivalent: "i").target = nil
        fileMenu.addItem(.separator())
        let removeItem = fileMenu.addItem(withTitle: "Remove",
                         action: Selector(("removeApps:")), keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!))
        removeItem.keyEquivalentModifierMask = [.command]
        removeItem.target = nil
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}
