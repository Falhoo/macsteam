// OneDrive: the same linked-account idea as Google Drive, against Microsoft Graph.
//
// Microsoft's equivalent of Google's `drive.file` is the app folder
// (`Files.ReadWrite.AppFolder`): macSteam gets one folder of its own in the
// user's OneDrive and can see nothing else. Sign-in is OAuth with PKCE, through
// the browser, with the same loopback listener Google uses.
//
// The client ID belongs to the app, not the user, and is public. It comes from
// an app registration in the Azure portal; a build can ship one, otherwise the
// pane takes one.

import AppKit
import CryptoKit
import Foundation
import Security

struct OneDriveConfig {
    var clientID = ""

    var isUsable: Bool { !clientID.isEmpty }
}

enum OneDrive {
    /// Filled in when macSteam ships with its own Azure app registration.
    static let builtInClientID = ""

    static let scope = "Files.ReadWrite.AppFolder offline_access"
    static let keychainService = "com.macsteam.onedrive"
    private static let graph = "https://graph.microsoft.com/v1.0"
    private static let authorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

    enum Failure: LocalizedError {
        case noClientID
        case notSignedIn
        case cancelled
        case timedOut
        case http(Int, String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .noClientID: return "No Microsoft client ID yet."
            case .notSignedIn: return "Not signed in to OneDrive."
            case .cancelled: return "Sign-in was cancelled."
            case .timedOut: return "Microsoft did not answer in time."
            case .http(let code, let what): return "OneDrive answered \(code) for \(what)."
            case .badReply(let text): return "Unexpected answer from OneDrive: \(text)"
            }
        }
    }

    // MARK: - Sign in

    static func isSignedIn() -> Bool {
        KeychainStore.read(account: "refresh", service: keychainService) != nil
    }

    static func signOut() {
        for account in ["refresh", "access", "expiry", "email"] {
            try? KeychainStore.delete(account: account, service: keychainService)
        }
    }

    static func account() -> String? {
        KeychainStore.read(account: "email", service: keychainService)
    }

    static func signIn(clientID: String) throws -> String {
        guard !clientID.isEmpty else { throw Failure.noClientID }

        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let listener = try LoopbackListener()
        // Microsoft registers "http://localhost" with any port for desktop apps.
        let redirect = "http://localhost:\(listener.port)"

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components.url else { throw Failure.badReply("auth url") }

        DispatchQueue.main.async { NSWorkspace.shared.open(url) }

        let code = try listener.waitForCode(timeout: 300)
        let tokens = try exchange(code: code, verifier: verifier, redirect: redirect, clientID: clientID)

        try KeychainStore.write(tokens.refresh, account: "refresh", service: keychainService)
        try KeychainStore.write(tokens.access, account: "access", service: keychainService)
        try KeychainStore.write(String(tokens.expiry), account: "expiry", service: keychainService)

        let who = (try? displayName(token: tokens.access)) ?? "OneDrive"
        try? KeychainStore.write(who, account: "email", service: keychainService)
        return who
    }

    private struct Tokens {
        let access: String
        let refresh: String
        let expiry: TimeInterval
    }

    private static func exchange(code: String, verifier: String, redirect: String,
                                 clientID: String) throws -> Tokens {
        let json = try post(tokenURL, form: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ])
        guard let access = json["access_token"] as? String else {
            throw Failure.badReply(String(describing: json))
        }
        let refresh = (json["refresh_token"] as? String) ?? (refreshToken() ?? "")
        let expires = (json["expires_in"] as? Double) ?? 3600
        return Tokens(access: access, refresh: refresh,
                      expiry: Date().timeIntervalSince1970 + expires - 60)
    }

    static func refreshToken() -> String? {
        KeychainStore.read(account: "refresh", service: keychainService)
    }

    static func accessToken(clientID: String) throws -> String {
        let cached = KeychainStore.read(account: "access", service: keychainService)
        let expiry = Double(KeychainStore.read(account: "expiry", service: keychainService) ?? "") ?? 0
        if let cached, !cached.isEmpty, expiry > Date().timeIntervalSince1970 {
            return cached
        }
        guard let refresh = refreshToken() else { throw Failure.notSignedIn }
        guard !clientID.isEmpty else { throw Failure.noClientID }

        let json = try post(tokenURL, form: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": scope,
        ])
        guard let access = json["access_token"] as? String else {
            throw Failure.badReply(String(describing: json))
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        let next = Date().timeIntervalSince1970 + expires - 60
        try? KeychainStore.write(access, account: "access", service: keychainService)
        try? KeychainStore.write(String(next), account: "expiry", service: keychainService)
        return access
    }

    private static func displayName(token: String) throws -> String? {
        var request = URLRequest(url: URL(string: "\(graph)/me")!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let mail = json["mail"] as? String, !mail.isEmpty { return mail }
        if let name = json["displayName"] as? String, !name.isEmpty { return name }
        return json["userPrincipalName"] as? String
    }

    // MARK: - Files

    static func push(from root: URL, config: OneDriveConfig) throws -> Int {
        let token = try accessToken(clientID: config.clientID)
        let appFolder = try appFolderID(token: token)
        var sent = 0
        try uploadTree(root, parent: appFolder, token: token, rootPath: root.path, sent: &sent)
        return sent
    }

    static func pull(into root: URL, config: OneDriveConfig) throws -> Int {
        let token = try accessToken(clientID: config.clientID)
        let appFolder = try appFolderID(token: token)
        var fetched = 0
        try downloadTree(appFolder, local: root, token: token, fetched: &fetched)
        return fetched
    }

    static func test(_ config: OneDriveConfig) throws -> String {
        let token = try accessToken(clientID: config.clientID)
        let appFolder = try appFolderID(token: token)
        let entries = try list(parent: appFolder, token: token)
        let who = account().map { "Signed in as \($0). " } ?? ""
        return who + "Reached the app folder — \(entries.count) entr"
            + (entries.count == 1 ? "y." : "ies.")
    }

    private struct Item {
        let id: String
        let name: String
        let isFolder: Bool
    }

    /// The app folder is created by Microsoft on first use.
    private static func appFolderID(token: String) throws -> String {
        var request = URLRequest(url: URL(string: "\(graph)/me/drive/special/approot")!,
                                 timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw Failure.http(response.statusCode, "opening the app folder")
        }
        return id
    }

    private static func list(parent: String, token: String) throws -> [Item] {
        var request = URLRequest(
            url: URL(string: "\(graph)/me/drive/items/\(parent)/children?$select=id,name,folder,file")!,
            timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw Failure.http(response.statusCode, "listing the app folder")
        }
        return values.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return Item(id: id, name: name, isFolder: item["folder"] != nil)
        }
    }

    private static func uploadTree(_ dir: URL, parent: String, token: String,
                                   rootPath: String, sent: inout Int) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() {
            if name.hasPrefix(".") || name.hasSuffix(".part") { continue }
            if dir.path == rootPath && name == "dumps" { continue }

            let local = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let child = try folderID(named: name, parent: parent, token: token)
                try uploadTree(local, parent: child, token: token, rootPath: rootPath, sent: &sent)
            } else {
                try upload(try Data(contentsOf: local), name: name, parent: parent, token: token)
                sent += 1
            }
        }
    }

    private static func downloadTree(_ parent: String, local: URL, token: String,
                                     fetched: inout Int) throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for item in try list(parent: parent, token: token) {
            let child = local.appendingPathComponent(item.name, isDirectory: item.isFolder)
            if item.isFolder {
                try downloadTree(item.id, local: child, token: token, fetched: &fetched)
            } else {
                if FileManager.default.fileExists(atPath: child.path) { continue }
                let data = try download(item.id, token: token)
                try data.write(to: child)
                fetched += 1
            }
        }
    }

    private static func folderID(named name: String, parent: String, token: String) throws -> String {
        for item in try list(parent: parent, token: token) where item.isFolder && item.name == name {
            return item.id
        }

        var request = URLRequest(url: URL(string: "\(graph)/me/drive/items/\(parent)/children")!,
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "folder": [:],
            "@microsoft.graph.conflictBehavior": "fail",
        ])
        let (data, response) = try send(request)
        guard response.statusCode == 201 || response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw Failure.http(response.statusCode, "creating the folder \(name)")
        }
        return id
    }

    private static func upload(_ data: Data, name: String, parent: String, token: String) throws {
        // Simple upload: fine up to 250 MB, which covers save files.
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(
            url: URL(string: "\(graph)/me/drive/items/\(parent):/\(escaped):/content")!,
            timeoutInterval: 300)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(response.statusCode, "uploading \(name)")
        }
    }

    private static func download(_ id: String, token: String) throws -> Data {
        var request = URLRequest(url: URL(string: "\(graph)/me/drive/items/\(id)/content")!,
                                 timeoutInterval: 300)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(response.statusCode, "downloading a file")
        }
        return data
    }

    // MARK: - HTTP

    private static func post(_ address: String, form: [String: String]) throws -> [String: Any] {
        let body = form.map { "\($0.key)=\(percent($0.value))" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badReply(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        if response.statusCode >= 400 {
            let description = ((json["error_description"] as? String) ?? "")
                .components(separatedBy: "\r\n").first ?? "HTTP \(response.statusCode)"
            throw Failure.badReply(description)
        }
        return json
    }

    private static func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.result = .failure(Failure.badReply("no answer"))
                return
            }
            box.result = .success((data ?? Data(), http))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            task.cancel()
            throw Failure.timedOut
        }
        guard let result = box.result else { throw Failure.timedOut }
        return try result.get()
    }

    private static func percent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private final class Box: @unchecked Sendable {
        var result: Result<(Data, HTTPURLResponse), Error>?
    }
}
