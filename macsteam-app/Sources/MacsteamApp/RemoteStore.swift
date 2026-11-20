// Talks to a WebDAV server: the account mode, where the saves live online rather
// than in a folder some desktop client keeps in sync.
//
// WebDAV is what most services speak without an app registration of their own:
// Nextcloud, ownCloud, Box, pCloud, a NAS, or a server of your own. OneDrive,
// Google Drive and Dropbox each need an OAuth app registered for macSteam before
// the app can talk to them directly, which is a separate piece of work.
//
// Foundation only, so this runs both in the config app and in the headless helper
// (--cloud-sync push|pull).

import Foundation

struct RemoteConfig {
    var url = ""
    var user = ""
    var password = ""

    var isUsable: Bool {
        guard let url = URL(string: url), url.host != nil else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}

enum RemoteStore {
    enum Failure: LocalizedError {
        case badAddress(String)
        case status(Int, String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .badAddress(let text):
                return "That address is not usable: \(text)"
            case .status(let code, let what):
                return "The server answered \(code) for \(what)."
            case .timedOut:
                return "The server did not answer in time."
            }
        }
    }

    // MARK: - Public

    /// Sends every file under `source` to the account, making folders as needed.
    static func upload(from source: URL, config: RemoteConfig) throws -> Int {
        let base = try baseURL(config)
        var count = 0
        try uploadTree(source, base: base, config: config, relative: [], count: &count)
        return count
    }

    /// Copies every file the account holds into `destination`, skipping files
    /// that are already there. Returns how many were fetched.
    static func download(into destination: URL, config: RemoteConfig) throws -> Int {
        let base = try baseURL(config)
        var count = 0
        try downloadTree(base, local: destination, remote: config, count: &count)
        return count
    }

    /// Says whether the account answers, and what its top folder holds.
    static func test(_ config: RemoteConfig) throws -> String {
        let entries = try list(try baseURL(config), config: config)
        let files = entries.filter { !$0.isCollection }.count
        let folders = entries.count - files
        return "Connected — \(folders) folder\(folders == 1 ? "" : "s"), "
            + "\(files) file\(files == 1 ? "" : "s")."
    }

    // MARK: - Walking

    private struct Entry {
        let name: String
        let url: URL
        let isCollection: Bool
    }

    private static func uploadTree(_ dir: URL, base: URL, config: RemoteConfig,
                                   relative: [String], count: inout Int) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() {
            if name.hasPrefix(".") || name.hasSuffix(".part") { continue }
            if relative.isEmpty && name == "dumps" { continue }   // diagnostics, not saves

            let local = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else { continue }

            let path = relative + [name]
            if isDirectory.boolValue {
                try makeCollection(url(base, path), remote: config)
                try uploadTree(local, base: base, config: config, relative: path, count: &count)
            } else {
                var request = try signed(url(base, path), method: "PUT", remote: config)
                request.httpBody = try Data(contentsOf: local)
                let (_, response) = try perform(request)
                guard (200..<300).contains(response.statusCode) else {
                    throw Failure.status(response.statusCode, path.joined(separator: "/"))
                }
                count += 1
            }
        }
    }

    private static func downloadTree(_ remoteURL: URL, local: URL, remote: RemoteConfig,
                                     count: inout Int) throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for entry in try list(remoteURL, config: remote) {
            let child = local.appendingPathComponent(entry.name, isDirectory: entry.isCollection)
            if entry.isCollection {
                try downloadTree(entry.url, local: child, remote: remote, count: &count)
            } else {
                if FileManager.default.fileExists(atPath: child.path) { continue }
                let (data, response) = try perform(try signed(entry.url, method: "GET", remote: remote))
                guard (200..<300).contains(response.statusCode) else {
                    throw Failure.status(response.statusCode, entry.name)
                }
                try data.write(to: child)
                count += 1
            }
        }
    }

    // MARK: - WebDAV verbs

    private static func list(_ dir: URL, config: RemoteConfig) throws -> [Entry] {
        var request = try signed(dir, method: "PROPFIND", remote: config)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
        """.utf8)

        let (data, response) = try perform(request)
        guard response.statusCode == 207 || (200..<300).contains(response.statusCode) else {
            throw Failure.status(response.statusCode, dir.lastPathComponent.isEmpty ? "/" : dir.lastPathComponent)
        }
        return parse(data, base: dir)
    }

    private static func makeCollection(_ dir: URL, remote: RemoteConfig) throws {
        let (_, response) = try perform(try signed(dir, method: "MKCOL", remote: remote))
        // 405 means it is already there, which is what was wanted.
        guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
            throw Failure.status(response.statusCode, dir.lastPathComponent)
        }
    }

    private static func signed(_ url: URL, method: String, remote: RemoteConfig) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        if !remote.user.isEmpty || !remote.password.isEmpty {
            let token = Data("\(remote.user):\(remote.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.result = .failure(Failure.badAddress("no answer"))
                return
            }
            box.result = .success((data ?? Data(), http))
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 90) == .timedOut {
            task.cancel()
            throw Failure.timedOut
        }
        guard let result = box.result else { throw Failure.timedOut }
        return try result.get()
    }

    // MARK: - Addresses and XML

    private static func baseURL(_ config: RemoteConfig) throws -> URL {
        guard let url = URL(string: config.url), url.host != nil else {
            throw Failure.badAddress(config.url)
        }
        return url
    }

    private static func url(_ base: URL, _ parts: [String]) throws -> URL {
        var text = base.absoluteString
        for part in parts {
            let piece = part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? part
            if !text.hasSuffix("/") { text += "/" }
            text += piece
        }
        guard let url = URL(string: text) else { throw Failure.badAddress(text) }
        return url
    }

    private static func parse(_ data: Data, base: URL) -> [Entry] {
        guard let document = try? XMLDocument(data: data) else { return [] }
        let responses = (try? document.nodes(forXPath: "//*[local-name()='response']")) as? [XMLNode] ?? []
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"

        var entries: [Entry] = []
        for node in responses {
            guard let href = firstValue(node, "href"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }

            let isCollection = firstNode(node, "collection") != nil
            var name = url.path
            if name.hasPrefix(basePath) {
                name = String(name.dropFirst(basePath.count))
            } else if name == base.path {
                name = ""
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if name.isEmpty || name.contains("/") { continue }
            entries.append(Entry(name: name, url: url, isCollection: isCollection))
        }
        return entries
    }

    private static func firstNode(_ node: XMLNode, _ localName: String) -> XMLNode? {
        let found = (try? node.nodes(forXPath: "descendant::*[local-name()='\(localName)']")) as? [XMLNode]
        return found?.first
    }

    private static func firstValue(_ node: XMLNode, _ localName: String) -> String? {
        firstNode(node, localName)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class Box: @unchecked Sendable {
        var result: Result<(Data, HTTPURLResponse), Error>?
    }
}
