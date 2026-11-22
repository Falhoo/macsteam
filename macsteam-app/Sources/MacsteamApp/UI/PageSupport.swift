// Helpers shared by the SwiftUI pages.
import AppKit
import GlassUI
import SwiftUI

/// What the shell shows for a page: a SwiftUI page, or one of macSteam's view
/// controllers that hasn't been converted yet.
enum PageContent {
    case native(AnyView)
    case hosted(NSViewController)
}

/// Runs slow work off the main thread, then reports back on it. Same error handling as
/// `runBusy` in DesignSystem.swift: App Management permission gets its own alert.
@MainActor
func runInBackground(
    failureTitle: String = "Couldn't complete",
    _ work: @escaping @Sendable () throws -> Void,
    completion: @escaping @MainActor (_ succeeded: Bool) -> Void
) {
    DispatchQueue.global(qos: .userInitiated).async {
        let result: Result<Void, Error> = Result { try work() }
        Task { @MainActor in
            if case .failure(let error) = result {
                if error is SteamInstaller.PermissionDenied {
                    presentAppManagementAlert()
                } else {
                    presentAlert(failureTitle, error.localizedDescription, style: .warning)
                }
                completion(false)
            } else {
                completion(true)
            }
        }
    }
}

/// Asks a yes/no question with an NSAlert, as the AppKit pages did.
@MainActor
func confirm(_ message: String, _ informative: String,
             confirmTitle: String, style: NSAlert.Style = .warning) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informative
    alert.alertStyle = style
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

extension StatusTone {
    /// Symbol for the large glass status icon.
    var glassSymbol: String {
        switch self {
        case .ok: "checkmark"
        case .warn, .bad: "exclamationmark.triangle"
        case .neutral: "minus"
        }
    }

    var glassTint: Color? {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: nil
        }
    }
}
