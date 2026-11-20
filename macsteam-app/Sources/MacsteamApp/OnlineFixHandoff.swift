// Hand-off into the OnlineFix pages from the Apps pane.
//
// The Apps pane's own OnlineFix dialog configures macSteam's Steam-side routing
// (config.yaml). The merged OnlineFix Manager keeps a separate game list for the
// game-file side, so its "Open in OnlineFix Manager…" button hands the game to
// that page through this notification, which MainViewController picks up.
import Foundation

enum OnlineFixHandoff {
    static let notification = Notification.Name("com.macsteam.openOnlineFixGame")
    static let appIDKey = "appID"
    static let nameKey = "name"
}
