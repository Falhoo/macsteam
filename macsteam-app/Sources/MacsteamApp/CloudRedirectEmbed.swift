// CloudRedirect's macOS app, hosted as a page in macSteam's sidebar.
//
// The UI, its native CLI helpers, OAuth and provider setup all come from the
// vendored cloudredirect-macos sources; macSteam only gives them a window to run
// in and installs the runtime beside its own dylib.

import AppKit
import CloudRedirectUI
import SwiftUI

@MainActor
enum CloudRedirectEmbed {
    static let store = BackendStore()
    private static var controller: NSViewController?
    private static var window: NSWindow?

    static func viewController() -> NSViewController {
        if let controller { return controller }
        let host = NSHostingController(rootView: ContentView(backend: store))
        // The hosting controller must not drive macSteam's window toolbar or size.
        host.sizingOptions = []
        controller = host
        return host
    }

    /// CloudRedirect's whole app in a window of its own: providers, sign-in,
    /// games, backups, migration and the runtime setup page.
    static func openWindow() {
        if window == nil {
            let root = ContentView(backend: store)
                .frame(minWidth: 960, minHeight: 660)
                .frame(idealWidth: 1120, idealHeight: 780)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            // Without a frame the hosting controller reports a tiny fitting size and
            // the window comes up a few pixels wide on first show.
            host.view.frame = NSRect(x: 0, y: 0, width: 1120, height: 780)

            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "Cloud Redirect"
            win.contentViewController = host
            win.contentMinSize = NSSize(width: 960, height: 660)
            win.setContentSize(NSSize(width: 1120, height: 780))
            win.isReleasedWhenClosed = false
            win.setFrameAutosaveName("CloudRedirectWindow.v1")
            if !win.setFrameUsingName("CloudRedirectWindow.v1") {
                win.center()
            }
            // A size saved while the window was tiny must not bring the problem back.
            if win.frame.width < 400 || win.frame.height < 300 {
                win.setContentSize(NSSize(width: 1120, height: 780))
                win.center()
            }
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
