// Asking Steam itself to change a game's compatibility tool.
//
// `SteamClient.Apps.SpecifyCompatTool` only exists in Steam's own UI realm (the
// `steamloopback.host` pages), not in the store page our card is injected into.
// Two ways in are tried: a direct DevTools socket to that realm, and, when Steam
// refuses that, attaching to the realm from the store page's session with
// `Target.attachToTarget`. If Steam refuses both, the caller falls back to opening
// the game's page so the player can set it in Properties.
import Foundation

enum SteamUICompat {

    /// True when Steam accepted the tool for the app.
    static func specifyCompatTool(appID: Int, tool: String) async -> Bool {
        let expression = "SteamClient.Apps.SpecifyCompatTool(\(appID), \(jsString(tool))); true"
        return await evaluate(expression)
    }

    /// Takes a forced compatibility tool off a game, so Steam starts its native
    /// build again. Steam's own Compatibility setting does this with an empty tool.
    static func clearCompatTool(appID: Int) async -> Bool {
        await specifyCompatTool(appID: appID, tool: "")
    }

    /// Replaces a game's launch options. Steam on macOS has no shell, so the
    /// `NAME=value` prefixes NotProton writes cannot run once a game is launched
    /// natively; this clears them through Steam itself, so the change survives.
    static func setLaunchOptions(appID: Int, options: String) async -> Bool {
        let expression = "SteamClient.Apps.SetAppLaunchOptions(\(appID), \(jsString(options))); true"
        return await evaluate(expression)
    }

    /// Asks Steam's own UI to open the game's Properties, on the Compatibility page
    /// when it can. That dialog has no `steam://` URL: the library page opens it
    /// through an internal message the UI listens for.
    static func openProperties(appID: Int) async -> Bool {
        let expression = "SteamClient.Messaging.PostMessage('AppProperties', '\(appID)', "
            + "'compatibility'); true"
        if await evaluate(expression) { return true }
        let plain = "SteamClient.Messaging.PostMessage('AppProperties', '\(appID)', ''); true"
        return await evaluate(plain)
    }

    private static func evaluate(_ expression: String) async -> Bool {
        if await evaluateDirect(expression) { return true }
        return await evaluateAttached(expression)
    }

    // MARK: - Direct socket

    private static func evaluateDirect(_ expression: String) async -> Bool {
        guard let target = await uiTarget(), let endpoint = target.endpoint else { return false }
        guard let reply = await roundTrip(endpoint, payload: evaluatePayload(expression)) else {
            return false
        }
        return succeeded(reply)
    }

    // MARK: - Attach through a page Steam already lets us talk to

    private static func evaluateAttached(_ expression: String) async -> Bool {
        let targets = await allTargets()
        guard let ui = targets.first(where: { isUIRealm($0) }),
              let anchor = targets.first(where: { $0.isAttachablePage }),
              let endpoint = anchor.endpoint else { return false }

        guard let socket = makeSocket(endpoint) else { return false }
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let attach: [String: Any] = [
            "id": 1,
            "method": "Target.attachToTarget",
            "params": ["targetId": ui.id, "flatten": true],
        ]
        guard await send(attach, on: socket),
              let reply = await receive(matching: 1, on: socket),
              let result = reply["result"] as? [String: Any],
              let session = result["sessionId"] as? String else { return false }

        var payload = evaluatePayload(expression)
        payload["sessionId"] = session
        guard await send(payload, on: socket),
              let answer = await receive(matching: 2, on: socket) else { return false }
        return succeeded(answer)
    }

    // MARK: - CDP plumbing

    private static func evaluatePayload(_ expression: String) -> [String: Any] {
        ["id": 2, "method": "Runtime.evaluate",
         "params": ["expression": expression, "returnByValue": true]]
    }

    private static func succeeded(_ reply: [String: Any]) -> Bool {
        if reply["error"] != nil { return false }
        let result = reply["result"] as? [String: Any] ?? [:]
        return result["exceptionDetails"] == nil
    }

    private static func makeSocket(_ endpoint: URL) -> URLSessionWebSocketTask? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4
        let socket = URLSession(configuration: configuration).webSocketTask(with: endpoint)
        socket.resume()
        return socket
    }

    private static func send(_ payload: [String: Any], on socket: URLSessionWebSocketTask) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return (try? await socket.send(.data(data))) != nil
    }

    private static func roundTrip(_ endpoint: URL, payload: [String: Any]) async -> [String: Any]? {
        guard let socket = makeSocket(endpoint) else { return nil }
        defer { socket.cancel(with: .goingAway, reason: nil) }
        guard await send(payload, on: socket) else { return nil }
        return await receive(matching: payload["id"] as? Int ?? 2, on: socket)
    }

    private static func receive(matching id: Int,
                                on socket: URLSessionWebSocketTask) async -> [String: Any]? {
        for _ in 0..<20 {
            guard let message = try? await socket.receive() else { return nil }
            guard case .data(let data) = message,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let replyID = object["id"] as? Int, replyID == id else { continue }
            return object
        }
        return nil
    }

    // MARK: - Targets

    private struct Target {
        let id: String
        let title: String
        let url: String
        let endpoint: URL?

        var isStorePage: Bool { url.contains("store.steampowered.com") }
        var isAttachablePage: Bool { url.hasPrefix("http") && endpoint != nil && !isUIRealm(self) }
    }

    private static func isUIRealm(_ target: Target) -> Bool {
        target.url.contains("steamloopback.host/index.html") || target.title == "Steam"
    }

    private static func uiTarget() async -> Target? {
        let targets = await allTargets()
        return targets.first { $0.url.contains("steamloopback.host/index.html") && $0.endpoint != nil }
            ?? targets.first { $0.title == "Steam" && $0.endpoint != nil }
    }

    private static func allTargets() async -> [Target] {
        guard let url = URL(string: "http://127.0.0.1:8080/json/list") else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        guard let (data, _) = try? await URLSession(configuration: configuration).data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { node in
            guard (node["type"] as? String) == "page",
                  let id = node["id"] as? String else { return nil }
            let socket = node["webSocketDebuggerUrl"] as? String
            return Target(id: id,
                          title: node["title"] as? String ?? "",
                          url: node["url"] as? String ?? "",
                          endpoint: socket.flatMap(URL.init(string:)))
        }
    }

    private static func jsString(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.append(character)
            }
        }
        return out + "\""
    }
}
