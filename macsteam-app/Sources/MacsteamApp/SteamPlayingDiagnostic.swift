// Read-only probe: asks the running Steam client what it reports as "currently
// playing", so the profile/games-played path can be worked on with real data
// instead of guesses. Nothing here changes what Steam sends.
import Foundation

enum SteamPlayingDiagnostic {

    /// Runs the probe, prints what it found, appends it to macsteam.log.
    static func run() async -> Int32 {
        var report = "Steam playing-state probe\n"
        report += "== Steam UI (CDP)\n"
        report += await steamUIReport()
        report += "\n== Steam console log (recent process lines)\n"
        report += consoleLogReport()
        print(report)
        AppLog.write(report, category: "diagnose-playing")
        return EXIT_SUCCESS
    }

    // MARK: - Steam UI

    /// What the client's own UI exposes about the running game. Everything is
    /// wrapped in try/catch on the JS side, so a missing API is reported, not fatal.
    private static let script = """
    (function() {
      var out = {};
      function safe(name, f) {
        try { out[name] = f(); } catch (e) { out[name] = 'error: ' + e; }
      }
      safe('keys', function() { return Object.keys(window.SteamClient || {}); });
      safe('steamid', function() {
        return SteamClient.User.GetSteamID().ConvertTo64BitString();
      });
      safe('sessions', function() {
        return Object.keys(SteamClient.GameSessions || {});
      });
      safe('friends', function() {
        return Object.keys(SteamClient.Friends || {});
      });
      safe('user', function() {
        return Object.keys(SteamClient.User || {});
      });
      safe('playing', function() {
        var s = SteamClient.GameSessions || {};
        var names = ['GetPlayingAppIds', 'GetRunningAppIds', 'GetAppID'];
        for (var i = 0; i < names.length; i++) {
          if (typeof s[names[i]] === 'function') {
            return names[i] + '=' + JSON.stringify(s[names[i]]());
          }
        }
        return 'none';
      });
      return JSON.stringify(out);
    })()
    """

    private static func steamUIReport() async -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:8080/json/list")!)
            let targets = try JSONDecoder().decode([Target].self, from: data)
            guard let target = targets.first(where: {
                guard let url = URL(string: $0.url) else { return false }
                return $0.type == "page" && url.scheme == "https" && url.host == "steamloopback.host"
                    && url.path == "/index.html"
            }), let endpoint = target.webSocketDebuggerUrl, let url = URL(string: endpoint),
                url.scheme == "ws", url.host == "127.0.0.1", url.port == 8080,
                url.path.hasPrefix("/devtools/page/") else {
                return "Steam's UI page is not there. Start Steam and try again.\n"
            }
            let socket = session.webSocketTask(with: url)
            socket.resume()
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
            let command: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": [
                "expression": script, "awaitPromise": true, "returnByValue": true]]
            let encoded = try JSONSerialization.data(withJSONObject: command)
            try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
            let message = try await socket.receive()
            let text: String
            switch message {
            case .string(let value): text = value
            case .data(let bytes): text = String(decoding: bytes, as: UTF8.self)
            @unknown default: return "Steam's UI sent something unexpected.\n"
            }
            return describe(text) + "\n"
        } catch {
            return "Could not reach Steam's UI: \(error.localizedDescription)\n"
        }
    }

    /// Pulls the evaluated value out of a CDP reply, with its exception if any.
    private static func describe(_ reply: String) -> String {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return reply }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let text = (exception["text"] as? String) ?? "exception"
            return "Steam's page threw: \(text)"
        }
        let value = (result["result"] as? [String: Any])?["value"] as? String ?? "(no value)"
        return value
    }

    private struct Target: Decodable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: String?
    }

    // MARK: - Steam log

    /// The lines the client wrote about running games: its own view of the
    /// process (AppID and the name it carries, empty when it has none).
    private static func consoleLogReport() -> String {
        let log = Paths.steamRoot.appendingPathComponent("logs/console_log.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else {
            return "Steam's console log is not there.\n"
        }
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        let interesting = lines.suffix(4000).filter {
            $0.contains("Game process ") || $0.contains("GameOverlay: started")
        }
        guard !interesting.isEmpty else { return "No running-game lines in the last part of the log.\n" }
        return interesting.suffix(20).map { String($0) }.joined(separator: "\n") + "\n"
    }
}
