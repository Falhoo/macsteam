// Google Drive: the linked-account mode, signed in with the user's own Google
// account and no desktop sync app involved.
//
// The sign-in is the standard desktop OAuth flow, done with PKCE so no client
// secret ships in the app: the app opens Google's page in the browser, Google
// redirects back to a listener this file opens on 127.0.0.1, and the code is
// exchanged for an access token and a long-lived refresh token. The refresh
// token is kept in the login keychain and is what the headless helper uses, so
// syncing works without the window being open.
//
// The client ID is the app's own identity (not the user's) and is public. A
// build either ships one in `builtInClientID`, or the user pastes one in the
// Cloud Saves pane.

import AppKit
import CryptoKit
import Foundation
import Security

struct GoogleDriveConfig {
    var clientID = ""
    var folderName = "macSteam"

    var isUsable: Bool { !clientID.isEmpty }
}

enum GoogleDrive {
    /// Filled in when macSteam ships with its own Google app registration.
    /// Empty means the pane asks for a client ID.
    static let builtInClientID = ""

    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let keychainService = "com.macsteam.google"
    private static let folderMime = "application/vnd.google-apps.folder"

    enum Failure: LocalizedError {
        case noClientID
        case notSignedIn
        case cancelled
        case timedOut
        case http(Int, String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .noClientID: return "No Google client ID yet."
            case .notSignedIn: return "Not signed in to Google Drive."
            case .cancelled: return "Sign-in was cancelled."
            case .timedOut: return "Google did not answer in time."
            case .http(let code, let what): return "Google answered \(code) for \(what)."
            case .badReply(let text): return "Unexpected answer from Google: \(text)"
            }
        }
    }

    // MARK: - Sign in and tokens

    static func isSignedIn() -> Bool {
        KeychainStore.read(account: "refresh", service: keychainService) != nil
    }

    static func signOut() {
        for account in ["refresh", "access", "expiry", "email"] {
            try? KeychainStore.delete(account: account, service: keychainService)
        }
    }

    /// The account name last used, for the pane.
    static func account() -> String? {
        KeychainStore.read(account: "email", service: keychainService)
    }

    /// Opens the browser, waits for Google's redirect and keeps the tokens.
    /// Returns the account's email when Google offers it.
    static func signIn(clientID: String) throws -> String {
        guard !clientID.isEmpty else { throw Failure.noClientID }

        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let listener = try LoopbackListener()
        let redirect = "http://127.0.0.1:\(listener.port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        guard let url = components.url else { throw Failure.badReply("auth url") }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }

        let code = try listener.waitForCode(timeout: 300)

        let tokens = try exchange(code: code, verifier: verifier, redirect: redirect, clientID: clientID)
        try KeychainStore.write(tokens.refresh, account: "refresh", service: keychainService)
        try KeychainStore.write(tokens.access, account: "access", service: keychainService)
        try KeychainStore.write(String(tokens.expiry), account: "expiry", service: keychainService)

        let email = (try? emailAddress(token: tokens.access)) ?? "Google Drive"
        try? KeychainStore.write(email, account: "email", service: keychainService)
        return email
    }

    private struct Tokens {
        let access: String
        let refresh: String
        let expiry: TimeInterval
    }

    private static func exchange(code: String, verifier: String, redirect: String,
                                 clientID: String) throws -> Tokens {
        let body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ].map { "\($0.key)=\(percent($0.value))" }.joined(separator: "&")

        let json = try post("https://oauth2.googleapis.com/token", body: body)
        guard let access = json["access_token"] as? String else {
            throw Failure.badReply(String(describing: json))
        }
        let refresh = (json["refresh_token"] as? String) ?? (currentRefreshToken() ?? "")
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Tokens(access: access, refresh: refresh, expiry: Date().timeIntervalSince1970 + expiresIn - 60)
    }

    static func currentRefreshToken() -> String? {
        KeychainStore.read(account: "refresh", service: keychainService)
    }

    /// A usable access token, refreshed if the cached one has expired.
    static func accessToken(clientID: String) throws -> String {
        let cached = KeychainStore.read(account: "access", service: keychainService)
        let expiry = Double(KeychainStore.read(account: "expiry", service: keychainService) ?? "") ?? 0
        if let cached, !cached.isEmpty, expiry > Date().timeIntervalSince1970 {
            return cached
        }
        guard let refresh = currentRefreshToken() else { throw Failure.notSignedIn }
        guard !clientID.isEmpty else { throw Failure.noClientID }

        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ].map { "\($0.key)=\(percent($0.value))" }.joined(separator: "&")

        let json = try post("https://oauth2.googleapis.com/token", body: body)
        guard let access = json["access_token"] as? String else {
            throw Failure.badReply(String(describing: json))
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let nextExpiry = Date().timeIntervalSince1970 + expiresIn - 60
        try? KeychainStore.write(access, account: "access", service: keychainService)
        try? KeychainStore.write(String(nextExpiry), account: "expiry", service: keychainService)
        return access
    }

    private static func emailAddress(token: String) throws -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    // MARK: - Drive

    static func push(from root: URL, config: GoogleDriveConfig) throws -> Int {
        let token = try accessToken(clientID: config.clientID)
        let parent = try folderID(named: config.folderName, parent: "root", token: token, config: config)
        var sent = 0
        try uploadTree(root, parent: parent, token: token, config: config, rootPath: root.path, sent: &sent)
        return sent
    }

    static func pull(into root: URL, config: GoogleDriveConfig) throws -> Int {
        let token = try accessToken(clientID: config.clientID)
        let parent = try folderID(named: config.folderName, parent: "root", token: token, config: config)
        var fetched = 0
        try downloadTree(parent, local: root, token: token, fetched: &fetched)
        return fetched
    }

    static func test(_ config: GoogleDriveConfig) throws -> String {
        let token = try accessToken(clientID: config.clientID)
        let parent = try folderID(named: config.folderName, parent: "root", token: token, config: config)
        let children = try list(parent: parent, token: token)
        let where_ = account().map { "Signed in as \($0). " } ?? ""
        return where_ + "Reached the folder — \(children.count) entr"
            + (children.count == 1 ? "y." : "ies.")
    }

    private struct Item {
        let id: String
        let name: String
        let isFolder: Bool
    }

    private static func uploadTree(_ dir: URL, parent: String, token: String,
                                   config: GoogleDriveConfig, rootPath: String,
                                   sent: inout Int) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() {
            if name.hasPrefix(".") || name.hasSuffix(".part") { continue }
            if dir.path == rootPath && name == "dumps" { continue }

            let local = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let child = try folderID(named: name, parent: parent, token: token, config: config)
                try uploadTree(local, parent: child, token: token, config: config, rootPath: rootPath, sent: &sent)
            } else {
                let data = try Data(contentsOf: local)
                try upload(data, name: name, parent: parent, token: token)
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

    /// Finds the folder of this name under `parent`, creating it when missing.
    private static func folderID(named name: String, parent: String, token: String,
                                 config: GoogleDriveConfig) throws -> String {
        let query = "name='\(escape(name))' and mimeType='\(folderMime)' and '\(parent)' in parents and trashed=false"
        if let existing = try list(query: query, token: token).first { return existing.id }

        let metadata: [String: Any] = ["name": name, "mimeType": folderMime, "parents": [parent]]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (reply, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let id = json["id"] as? String else {
            throw Failure.http(response.statusCode, "creating folder \(name)")
        }
        return id
    }

    private static func list(parent: String, token: String) throws -> [Item] {
        try list(query: "'\(parent)' in parents and trashed=false", token: token)
    }

    private static func list(query: String, token: String) throws -> [Item] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType)"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            throw Failure.http(response.statusCode, "listing files")
        }
        return files.compactMap { file in
            guard let id = file["id"] as? String, let name = file["name"] as? String else { return nil }
            let mime = file["mimeType"] as? String ?? ""
            return Item(id: id, name: name, isFolder: mime == folderMime)
        }
    }

    private static func upload(_ data: Data, name: String, parent: String, token: String) throws {
        let metadata: [String: Any] = ["name": name, "parents": [parent]]
        let metaData = try JSONSerialization.data(withJSONObject: metadata)

        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!,
                               timeoutInterval: 60)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("resumable", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = metaData

        let (_, response) = try send(start)
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location) else {
            throw Failure.http(response.statusCode, "starting upload of \(name)")
        }

        var put = URLRequest(url: target, timeoutInterval: 300)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        put.httpBody = data
        let (_, done) = try send(put)
        guard (200..<300).contains(done.statusCode) else {
            throw Failure.http(done.statusCode, "uploading \(name)")
        }
    }

    private static func download(_ id: String, token: String) throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!,
                                 timeoutInterval: 300)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(response.statusCode, "downloading a file")
        }
        return data
    }

    // MARK: - HTTP

    private static func post(_ address: String, body: String) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badReply(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        if response.statusCode >= 400 {
            let message = (json["error_description"] as? String)
                ?? (json["error"] as? String) ?? "HTTP \(response.statusCode)"
            throw Failure.badReply(message)
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

    // MARK: - Small helpers

    private static func percent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
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

// MARK: - Loopback listener

/// Receives Google's redirect on 127.0.0.1 and hands back the `code`.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleDrive.Failure.badReply("socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw GoogleDrive.Failure.badReply("binding 127.0.0.1")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        port = UInt16(bigEndian: actual.sin_port)
        socketFD = fd
    }

    deinit { close(socketFD) }

    /// Blocks until Google redirects, then returns the code.
    func waitForCode(timeout: TimeInterval) throws -> String {
        var ready = fd_set()
        fdZero(&ready)
        fdSet(socketFD, &ready)
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)

        let selected = select(socketFD + 1, &ready, nil, nil, &wait)
        guard selected > 0 else { throw GoogleDrive.Failure.timedOut }

        let client = accept(socketFD, nil, nil)
        guard client >= 0 else { throw GoogleDrive.Failure.cancelled }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let read = recv(client, &buffer, buffer.count, 0)
        guard read > 0, let request = String(bytes: buffer[0..<read], encoding: .utf8) else {
            throw GoogleDrive.Failure.cancelled
        }

        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let target = firstLine.components(separatedBy: " ").dropFirst().first ?? ""
        let query = target.components(separatedBy: "?").dropFirst().first ?? ""

        let page = Data("""
        <html><body style="font-family:-apple-system;padding:40px">
        <h2>macSteam</h2><p>Signed in to Google Drive. You can close this tab.</p>
        </body></html>
        """.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(page.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { write(client, $0, strlen($0)) }
        _ = page.withUnsafeBytes { write(client, $0.baseAddress, page.count) }

        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            if parts[0] == "code" { return parts[1].removingPercentEncoding ?? parts[1] }
            if parts[0] == "error" { throw GoogleDrive.Failure.cancelled }
        }
        throw GoogleDrive.Failure.cancelled
    }

    private func fdZero(_ set: inout fd_set) {
        withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    private func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let offset = Int(fd / 32)
        let bit = Int32(1) << (fd % 32)
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { $0[offset] |= bit }
        }
    }
}
