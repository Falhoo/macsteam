import AppKit
import Foundation
import Darwin
import OnlineFixApp

/// CDP's runtime binding carries only app IDs and results. Hubcap credentials stay native.
@MainActor
final class HubcapStoreBridge {
    private let installer = HubcapStoreInstaller()
    private let session: URLSession
    private var pages: [String: HubcapStorePage] = [:]
    private var lockFD: Int32 = -1

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    /// Where the running helper's pid and start time are kept, so the next
    /// launch can recognise it.
    private static var helperPidFile: URL {
        Paths.configDir.appendingPathComponent("hubcap-bridge.pid")
    }

    /// When a process started, in microseconds, or nil when there is no such
    /// process. Together with the pid it identifies one process for good, which
    /// a bare pid does not.
    private static func processStart(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
    }

    /// A helper from an earlier launch keeps the bridge lock and serves Store
    /// pages with its own, older code — a newer card's requests are then
    /// silently dropped, and the Store keeps showing the old advice and the old
    /// OnlineFix state. The helper may live under another bundle path (a Sparkle
    /// backup such as macSteam.app.previous, or a copy kept beside the app), so
    /// match it by the command it runs, not by this app's executable path.
    static func stopStaleHelper() {
        try? FileManager.default.removeItem(at: helperPidFile)
        let me = getpid()
        let exe = Bundle.main.executableURL?.lastPathComponent ?? "MacsteamApp"
        // pgrep matches the whole command line, which is what tells a helper apart
        // from the windowed app (same executable, no argument).
        let found = Subprocess.run("/usr/bin/pgrep",
                                   ["-f", "/\(exe) --hubcap-store-bridge"])
        guard found.code == 0 else { return }
        for token in found.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
            guard let pid = Int32(token), pid != me else { continue }
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if processStart(pid: pid) == nil { break }
                usleep(100_000)
            }
            if processStart(pid: pid) != nil { kill(pid, SIGKILL) }
        }
    }

    static func registerExecutable() {
        guard let executable = Bundle.main.executableURL else { return }
        do {
            try Paths.ensureDir(Paths.configDir)
            try executable.path.write(to: Paths.configDir.appendingPathComponent("hubcap-bridge.path"),
                                      atomically: true, encoding: .utf8)
            try enableCEFDebugging(in: Paths.innerClientMacOS)
            stopStaleHelper()
            let helper = Process()
            helper.executableURL = executable
            helper.arguments = ["--hubcap-store-bridge"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            environment.removeValue(forKey: "STEAM_APP_BUNDLE_PATH")
            helper.environment = environment
            try helper.run()
            let started = Self.processStart(pid: helper.processIdentifier) ?? 0
            try? "\(helper.processIdentifier) \(started)"
                .write(to: Self.helperPidFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Hubcap Store integration could not start: %@", error.localizedDescription)
        }
    }

    static func enableCEFDebugging(in clientDirectory: URL) throws {
        // Steam resolves this marker relative to the unbundled client's working
        // directory, not its Application Support data root.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clientDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let flag = clientDirectory.appendingPathComponent(".cef-enable-remote-debugging")
        if !FileManager.default.fileExists(atPath: flag.path) {
            try Data().write(to: flag, options: .atomic)
        }
    }

    func run() async {
        do { try Paths.ensureDir(Paths.configDir) } catch { return }
        lockFD = open(Paths.configDir.appendingPathComponent("hubcap-bridge.lock").path,
                      O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return }
        defer { close(lockFD); session.invalidateAndCancel() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
        var missed = 0
        while !Task.isCancelled {
            do {
                let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:8080/json/list")!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let targets = try JSONDecoder().decode([Target].self, from: data)
                missed = 0
                let live = Set(targets.map(\.id))
                for id in pages.keys where !live.contains(id) || pages[id]?.closed == true {
                    pages.removeValue(forKey: id)?.close()
                }
                for target in targets where target.type == "page" && Self.isStoreURL(target.url) {
                    guard pages[target.id] == nil, let endpoint = target.webSocketDebuggerUrl,
                          let url = URL(string: endpoint), url.scheme == "ws", url.port == 8080,
                          ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
                          url.path.hasPrefix("/devtools/page/") else { continue }
                    let page = HubcapStorePage(socket: session.webSocketTask(with: url), installer: installer)
                    pages[target.id] = page
                    page.start()
                }
            } catch {
                missed += 1
                // Exit when Steam closes, with enough grace for its startup/relaunch. A slow
                // or restarting debug port is not a reason to quit while Steam is still running.
                if missed >= 60 {
                    if Self.steamIsRunning() || SteamRestarter.isRestarting { missed = 0 } else { break }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        pages.values.forEach { $0.close() }
    }

    nonisolated static func steamIsRunning() -> Bool {
        Subprocess.run("/usr/bin/pgrep", ["-x", "steam_osx"]).code == 0
    }

    static func isStoreURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "store.steampowered.com" && (url.port == nil || url.port == 443)
    }

    static func storeAppID(_ value: String) -> Int? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "store.steampowered.com",
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "app", let id = Int(parts[1]), id > 0, id <= Int32.max else { return nil }
        return id
    }

    /// Ask Steam through its normal IPC API so activation runs on its pipe-owning
    /// thread, without navigating or refreshing the Store document.
    static func querySubscription(_ appID: Int) async throws {
        guard appID > 0, appID <= Int32.max else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:8080/json/list")!)
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard let target = targets.first(where: {
            guard let url = URL(string: $0.url) else { return false }
            return $0.type == "page" && url.scheme == "https" && url.host == "steamloopback.host"
                && url.path == "/index.html"
        }), let endpoint = target.webSocketDebuggerUrl, let url = URL(string: endpoint),
            url.scheme == "ws", url.host == "127.0.0.1", url.port == 8080,
            url.path.hasPrefix("/devtools/page/") else { throw URLError(.cannotConnectToHost) }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        let command: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": [
            "expression": "SteamClient.Apps.GetIsSubscribedApp(\(appID))", "awaitPromise": true,
            "returnByValue": true]]
        let encoded = try JSONSerialization.data(withJSONObject: command)
        try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
        _ = try await socket.receive()
    }

    private struct Target: Decodable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: String?
    }
}

@MainActor
private final class HubcapStorePage {
    private let socket: URLSessionWebSocketTask
    private let installer: HubcapStoreInstaller
    private let fixes = HubcapStoreFixes()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var contexts: [Int: String] = [:]
    private var topFrame = ""
    private var reader: Task<Void, Never>?
    private(set) var closed = false

    init(socket: URLSessionWebSocketTask, installer: HubcapStoreInstaller) {
        self.socket = socket
        self.installer = installer
    }

    func start() {
        socket.resume()
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    received(object)
                }
            } catch { close() }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await call("Page.enable")
                let tree = try await call("Page.getFrameTree")
                topFrame = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String ?? ""
                _ = try await call("Runtime.enable")
                _ = try await call("Runtime.addBinding", ["name": "macsteamHubcap"])
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("MacsteamApp_MacsteamApp.bundle/hubcap-store.js")
                var file = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? Bundle.main.url(forResource: "hubcap-store", withExtension: "js")
                #if SWIFT_PACKAGE
                if file == nil { file = Bundle.module.url(forResource: "hubcap-store", withExtension: "js") }
                #endif
                guard let file else { throw HubcapStoreError(message: "Hubcap Store script is missing from the app.") }
                let source = try String(contentsOf: file, encoding: .utf8)
                _ = try await call("Page.addScriptToEvaluateOnNewDocument", ["source": source])
                let result = try await call("Runtime.evaluate", ["expression": source])
                if result["exceptionDetails"] != nil {
                    throw HubcapStoreError(message: "Steam rejected the Hubcap Store script.")
                }
            } catch {
                NSLog("Hubcap Store page could not attach: %@", error.localizedDescription)
                close()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        reader?.cancel()
        let pending = waiting
        waiting.removeAll()
        pending.values.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    private func call(_ method: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw URLError(.networkConnectionLost) }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": parameters])
        let text = String(decoding: data, as: UTF8.self)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task {
                do { try await socket.send(.string(text)) }
                catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                waiting.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
            }
        }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    }

    private func received(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                waiting.removeValue(forKey: id)?.resume(throwing: HubcapStoreError(
                    message: error["message"] as? String ?? "Steam browser rejected the request."))
            } else {
                let data = (try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                waiting.removeValue(forKey: id)?.resume(returning: data)
            }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "Page.frameNavigated":
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil {
                topFrame = frame["id"] as? String ?? ""
            }
        case "Runtime.executionContextCreated":
            if let context = params["context"] as? [String: Any], let id = context["id"] as? Int,
               context["origin"] as? String == "https://store.steampowered.com",
               let aux = context["auxData"] as? [String: Any], aux["isDefault"] as? Bool == true {
                contexts[id] = aux["frameId"] as? String
            }
        case "Runtime.executionContextDestroyed":
            if let id = params["executionContextId"] as? Int { contexts.removeValue(forKey: id) }
        case "Runtime.executionContextsCleared": contexts.removeAll()
        case "Runtime.bindingCalled":
            guard params["name"] as? String == "macsteamHubcap",
                  let context = params["executionContextId"] as? Int, !topFrame.isEmpty,
                  contexts[context] == topFrame, let text = params["payload"] as? String,
                  text.utf8.count <= 1024, let data = text.data(using: .utf8),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  request.appID > 0, request.appID <= Int32.max, request.id.count <= 80,
                  (request.fixID?.count ?? 0) <= 80,
                  (request.name?.count ?? 0) <= 200,
                  Request.actions.contains(request.action) else { return }
            Task { await handle(request, context: context) }
        default: break
        }
    }

    private func handle(_ request: Request, context: Int) async {
        var response: [String: Any]
        var restartMode: String?
        do {
            // Revalidate the live top frame, including AppID, before any mutation.
            let location = try await call("Runtime.evaluate", ["expression": "location.href", "contextId": context])
            let value = (location["result"] as? [String: Any])?["value"] as? String ?? ""
            guard HubcapStoreBridge.storeAppID(value) == request.appID, contexts[context] == topFrame else {
                // Answer anyway: a request nobody replies to leaves the card's
                // button dead until it times out, which looks like a lost click.
                let reply: [Any] = [request.id, ["error": "The page changed. Try again."]]
                if let data = try? JSONSerialization.data(withJSONObject: reply),
                   let json = String(data: data, encoding: .utf8) {
                    _ = try? await call("Runtime.evaluate", ["contextId": context,
                        "expression": "window.__macsteamHubcap?.reply(...\(json))"])
                }
                return
            }
            switch request.action {
            case "fixes":
                response = await fixes.list(appID: request.appID)
            case "fix-permissions":
                response = fixes.openPrivacyPane(request.fixID ?? "")
            case "fix-manifest", "fix-install", "fix-undo", "fix-open":
                guard let fixID = request.fixID, !fixID.isEmpty else { return }
                response = await fixes.perform(request.action, appID: request.appID, fixID: fixID)
            case "onlinefix-uninstall":
                response = try Self.encode(OnlineFixEmbed.storeUninstall(appID: request.appID))
                // The game left My Games, so its AppID 480 routing has to leave
                // config.yaml too, or Steam keeps starting it as Spacewar.
                syncOnlineFixRouting()
            case "onlinefix-windows":
                // Switch a native game to NotProton the way Steam's own Compatibility
                // settings do: `SteamClient.Apps.SpecifyCompatTool` runs in Steam's UI
                // realm, not in this store page, so the bridge asks it over CDP.
                let tool = OnlineFixEmbed.notProtonTool()
                var switched = false
                if let tool {
                    switched = await SteamUICompat.specifyCompatTool(
                        appID: request.appID, tool: tool)
                }
                // Steam refuses the setting from outside its UI, so the next best is
                // its own Properties dialog, which the user can change.
                var opened = false
                if !switched {
                    opened = await SteamUICompat.openProperties(appID: request.appID)
                }
                response = [
                    "switched": switched,
                    "opened": opened,
                    "compatTool": tool ?? "",
                    "error": switched ? ""
                        : (tool == nil ? "NotProton is not installed for Steam."
                            : "Steam only takes this setting from its own UI."),
                ]
            case "onlinefix-probe":
                // Before an install: does online-fix.me have a fix, and is it the GDK
                // package that cannot run here?
                let probe = await OnlineFixEmbed.probeFix(name: request.name ?? "")
                response = ["available": probe.available, "gdk": probe.gdk,
                            "folder": probe.folder ?? ""]
            case "onlinefix-route":
                // "still route my game through spacewar": no files, just the identity
                // Steam starts it with. Works for a game that has no OnlineFix at all.
                let host = OnlineFixEmbed.storeRouteAsSpacewar(
                    appID: request.appID,
                    name: request.name ?? "",
                    on: request.confirmed ?? true)
                syncOnlineFixRouting()
                var reply = try Self.encode(host)
                reply["message"] = host.inList
                    ? "This game now starts as Spacewar (480). Restart Steam and launch it again."
                    : "The game could not be added to My Games."
                response = reply
            case "onlinefix-status":
                var status = try Self.encode(OnlineFixEmbed.storeStatus(appID: request.appID))
                // A game that went back to a native launch keeps NotProton's
                // `NAME=value` prefix, which Steam's macOS client cannot run: it
                // fails with "Failed to start process ... OS error 260". Clear it
                // through Steam so the change sticks.
                if let stale = LaunchOptions.stale(appID: request.appID) {
                    let clean = LaunchOptions.stripped(stale)
                    var fixed = await SteamUICompat.setLaunchOptions(appID: request.appID,
                                                                    options: clean)
                    // Steam's own UI is the way that sticks, but it does not always
                    // answer. With the client closed the file can be written directly,
                    // which is what macSteam does at its start when it finds one.
                    if !fixed, !HubcapStoreBridge.steamIsRunning() {
                        fixed = !LaunchOptions.clear([request.appID]).isEmpty
                    }
                    let log = "\(Date()) stale=\(stale) clean=\(clean) ok=\(fixed)\n"
                    let debug = Paths.steamRoot.appendingPathComponent("logs/launchoptions-debug.txt")
                    if let data = log.data(using: .utf8),
                       let handle = try? FileHandle(forWritingTo: debug) {
                        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
                    } else {
                        try? log.data(using: .utf8)?.write(to: debug)
                    }
                    if fixed { status["launchOptionsFixed"] = true }
                }
                response = status
            case "onlinefix-keep-id", "onlinefix-spacewar":
                // A game without an OnlineFix gets Steam's relay only as its own
                // AppID, so the card offers this instead of leaving it waiting.
                let keep = request.action == "onlinefix-keep-id"
                let changed = OnlineFixEmbed.storeKeepRealAppID(
                    appID: request.appID, name: request.name ?? "", keep: keep)
                syncOnlineFixRouting()
                var reply = try Self.encode(OnlineFixEmbed.storeStatus(appID: request.appID))
                reply["message"] = changed
                    ? (keep
                        ? "This game now starts as its own AppID. Restart Steam and launch it again."
                        : "This game now starts as Spacewar (480) again. Restart Steam and launch it again.")
                    : "That is not a Steam AppID macSteam can route."
                response = reply
            case "onlinefix-test":
                let message = await OnlineFixEmbed.storeTest(
                    appID: request.appID, name: request.name ?? "") { @Sendable text in
                    Task { await self.pushOnlineFixProgress(text, context: context) }
                }
                response = ["message": message]
            case "onlinefix-test-cancel":
                OnlineFixEmbed.storeCancelTest()
                response = ["stopping": true]
            case "onlinefix-install":
                let outcome = await OnlineFixEmbed.storeInstall(
                    appID: request.appID,
                    name: request.name ?? "",
                    folderName: request.folder,
                    confirmed: request.confirmed ?? false,
                    progress: { @Sendable text in
                        Task { await self.pushOnlineFixProgress(text, context: context) }
                    })
                syncOnlineFixRouting()
                // A Mac build's fix lives in the bundle, but Steam still starts the
                // Windows build while the game is forced to NotProton, so the patch
                // would never be what runs. Take the force off once it is installed.
                var reply = try Self.encode(outcome)
                if outcome.installed,
                   OnlineFixEmbed.hasPatchableMacBuild(appID: request.appID),
                   LaunchOptions.isMappedToCompatTool(appID: request.appID) {
                    if await SteamUICompat.clearCompatTool(appID: request.appID) {
                        reply["macLaunch"] = true
                    }
                }
                response = reply
            case "remove":
                // Take the game out of macSteam's config, with its DLC, depot keys
                // and name, exactly as the macSteam app's Remove does. Steam drops
                // it from the library on the refresh the store notifies it of.
                let store = ConfigStore()
                store.load()
                try store.removeApps([request.appID])
                // A re-add should download its manifest again rather than reuse
                // the receipt of the copy that was just removed.
                try? FileManager.default.removeItem(
                    at: Paths.configDir.appendingPathComponent("hubcap-lua")
                        .appendingPathComponent("\(request.appID).lua"))
                response = installer.status(appID: request.appID, name: request.name ?? "")
            case "restart":
                // Steam is about to go away and take this page with it, so the
                // reply has to leave first; the restart itself runs afterwards.
                response = ["restarting": true]
                restartMode = "achievements"
            case "restart-plain":
                // A plain quit and start, with no page loaded and no achievement
                // wait: this is what makes Steam drop a removed game.
                response = ["restarting": true]
                restartMode = "plain"
            default:
                if request.action == "add" {
                    try await installer.install(appID: request.appID, name: request.name ?? "")
                    // Steam fetches a store game's achievements as its page is
                    // shown, so the schema is usually there already: write the
                    // library cache entry now, and the restart that follows shows
                    // the achievements on its first start instead of its second.
                    AchievCache.syncNow(appID: request.appID)
                }
                response = installer.status(appID: request.appID, name: request.name ?? "")
            }
        } catch { response = ["error": error.localizedDescription] }
        guard let data = try? JSONSerialization.data(withJSONObject: [request.id, response]) else { return }
        let arguments = String(decoding: data, as: UTF8.self)
        _ = try? await call("Runtime.evaluate", ["contextId": context,
            "expression": "window.__macsteamHubcap?.reply(...\(arguments))"])
        if let restartMode {
            let appID = request.appID
            Task.detached(priority: .userInitiated) {
                if restartMode == "plain" {
                    await SteamRestarter.restartOnly()
                } else {
                    await SteamRestarter.restart(appID: appID)
                }
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Shows a download/install step on the store card while it runs.
    private func pushOnlineFixProgress(_ text: String, context: Int) async {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await call("Runtime.evaluate", [
            "contextId": context,
            "expression": "window.__macsteamOnlineFix?.progress((\(json))[0])"
        ])
    }

    /// The OnlineFix Manager owns config.yaml's routing; write it after a store add.
    private func syncOnlineFixRouting() {
        let store = ConfigStore()
        store.load()
        let entries = OnlineFixEmbed.routingEntries()
        var probe = store.config
        guard OnlineFixRoutingBridge.merge(entries, into: &probe) else { return }
        try? store.mutate { cfg in
            _ = OnlineFixRoutingBridge.merge(entries, into: &cfg)
        }
    }

    private struct Request: Decodable {
        let id: String
        let appID: Int
        let action: String
        let fixID: String?

        let name: String?
        /// Which similar uploads folder the player picked on the store page.
        let folder: String?
        /// True when the player said to install a fix that may not work.
        let confirmed: Bool?

        static let actions: Set<String> = ["status", "add", "remove", "restart", "restart-plain", "fixes", "fix-manifest",
                                           "fix-install", "fix-undo", "fix-open",
                                           "fix-permissions",
                                           "onlinefix-probe",
                                           "onlinefix-route", "onlinefix-windows",
                                           "onlinefix-status", "onlinefix-install",
                                           "onlinefix-test", "onlinefix-test-cancel",
                                           "onlinefix-uninstall", "onlinefix-keep-id",
                                           "onlinefix-spacewar"]
    }
}
