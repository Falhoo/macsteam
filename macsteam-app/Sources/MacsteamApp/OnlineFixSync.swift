// Headless: write the OnlineFix Manager's list and toggles into config.yaml, then exit.
//
//   MacsteamApp --onlinefix-sync
//
// The app does the same at launch; this is here so a rebuild or a hand-edited
// games.json can be applied without opening the window.
import Darwin
import Foundation
import OnlineFixApp

enum OnlineFixSync {

    @MainActor
    static func run() -> Int32 {
        let store = ConfigStore()
        store.load()

        let entries = OnlineFixEmbed.routingEntries()
        var probe = store.config
        guard OnlineFixRoutingBridge.merge(entries, into: &probe) else {
            print("OnlineFix routing is already in step (\(entries.count) game(s)).")
            return EXIT_SUCCESS
        }

        do {
            try store.mutate { cfg in
                _ = OnlineFixRoutingBridge.merge(entries, into: &cfg)
            }
        } catch {
            FileHandle.standardError.write(
                Data("onlinefix sync: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("OnlineFix routing written for \(entries.count) game(s).")
        return EXIT_SUCCESS
    }
}
