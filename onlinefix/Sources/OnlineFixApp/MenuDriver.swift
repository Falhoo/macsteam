// Driving the game's menus so it tries to go online by itself.
//
// Photon only says which auth type it wants after the game has asked, and asking
// means the player walking to the multiplayer screen. Most of these games open on a
// menu whose online entry is one Enter away, so the installer presses the keys
// instead of asking: the answer lands in the log either way, and the player does not
// have to know that a log is what decides the patch.
import AppKit
import CoreGraphics

enum MenuDriver {

    /// One pass over the shapes a menu takes: a click past the splash, Enter where a
    /// "press any key" is expected, a click low in the window where the Play button
    /// lives, then walking a list with the arrow keys and pressing what is highlighted.
    /// Two passes, because the first one often only gets through a logo or a title.
    private static let steps: [(name: String, key: CGKeyCode?, clickAt: Double?)] = [
        ("splash", nil, 0.50), ("key", 36, nil), ("key", 36, nil),
        ("play", nil, 0.72), ("play", nil, 0.60), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        // No Escape: it backs out of the online screen the earlier steps reached.
        // The tail walks deeper instead, pressing what each step highlights.
        ("play", nil, 0.72), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
        ("down", 125, nil), ("key", 36, nil),
    ]

    /// True when macOS lets this process post input to other apps.
    static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Asks for that permission once; the first run prompts, the window shows a tick.
    @discardableResult
    static func requestPermission() -> Bool {
        canPostEvents() || CGRequestPostEventAccess()
    }

    /// Walks the menu until the log shows a Photon attempt, the steps run out, or the
    /// player cancels. Returns true when an attempt was seen.
    static func attemptOnline(appID: Int, window: LaunchTest.Window,
                              cancel: () -> Bool,
                              progress: @Sendable (String) -> Void,
                              attemptSeen: () -> Bool) async -> Bool {
        guard canPostEvents() || requestPermission() else {
            progress("macOS has not allowed macSteam to press keys in other apps, so open the "
                + "online screen yourself and try to connect once.")
            return false
        }
        NSRunningApplication(processIdentifier: pid_t(window.pid))?
            .activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(700))

        progress("Trying the game's online menu for you…")
        // Menus animate and the first screen is often a logo: give the game a moment
        // before the first press, then try every shape a menu takes.
        try? await Task.sleep(for: .milliseconds(1200))
        for step in steps {
            if cancel() || attemptSeen() { return attemptSeen() }
            if let key = step.key {
                post(key: key, window: window)
            } else if let fraction = step.clickAt {
                postClick(window: window, at: fraction)
            }
            try? await Task.sleep(for: .milliseconds(step.key == nil ? 1500 : 1200))
        }
        // A lobby list can take a while to answer: hold on it before giving up, since
        // the answer being waited for is the failure line, not a menu.
        for _ in 0..<10 {
            if cancel() || attemptSeen() { return attemptSeen() }
            try? await Task.sleep(for: .milliseconds(900))
        }
        if attemptSeen() { return true }
        progress("Could not reach the online screen by itself — open it and try to "
            + "connect once, then repair the fix.")
        return false
    }

    // MARK: - Input

    private static func frame(of window: LaunchTest.Window) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowNumber as String] as? Int) == window.number {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    private static func postClick(window: LaunchTest.Window, at fraction: Double) {
        // Down a fraction of the window: 0.5 is a "click to continue" splash, 0.72
        // sits on the row a menu usually puts its Play button in.
        let centre = CGPoint(x: window.width / 2, y: window.height * fraction)
        guard let rect = frame(of: window) else {
            // Without a frame, aim at the middle of the main screen.
            let screen = CGDisplayBounds(CGMainDisplayID())
            click(CGPoint(x: screen.midX, y: screen.midY))
            return
        }
        click(CGPoint(x: rect.origin.x + centre.x, y: rect.origin.y + centre.y))
    }

    private static func click(_ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Wine games hover-highlight before they accept a click, so the pointer is
        // moved there first and left to settle.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            usleep(180_000)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                continue
            }
            event.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    private static func post(key: CGKeyCode, window: LaunchTest.Window) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
    }
}
