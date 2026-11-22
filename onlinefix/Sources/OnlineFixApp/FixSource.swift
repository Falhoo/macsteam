import Foundation

/// Finds and downloads a game's fix package from online-fix.me's file server.
///
/// The site publishes each game under
/// `https://uploads.online-fix.me:2053/uploads/<Game name>/`
/// with a `Fix Repair/` subfolder holding the small fix archive (the full game
/// archives live beside it and are never downloaded here).
enum FixSource {

    static let indexBase = URL(string: "https://uploads.online-fix.me:2053/uploads/")!
    static let defaultPassword = "online-fix.me"
    static let siteURL = URL(string: "https://online-fix.me/")!

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    struct Entry {
        let name: String
        let url: URL
        var isDirectory: Bool { name.hasSuffix("/") || url.absoluteString.hasSuffix("/") }
    }

    // MARK: - HTTP

    /// One session for every request, so the `online_fix_auth` cookie the upload
    /// server hands out with a folder listing is still there for the download.
    /// Without it the server answers file requests with 403.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    private static func attachCookies(to request: inout URLRequest, for url: URL) {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return }
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        for (name, value) in fields { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(url.deletingLastPathComponent().absoluteString, forHTTPHeaderField: "Referer")
    }

    /// A plain GET whose only purpose is to make the server issue its auth cookie
    /// for that folder. The body is not used.
    private static func primeCookies(for folder: URL) async {
        var request = URLRequest(url: folder)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        _ = try? await session.data(for: request)
    }

    static func html(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        attachCookies(to: &request, for: url)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ManagerError("online-fix.me returned HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func entries(in html: String, base: URL) -> [Entry] {
        let pattern = "<a href=\"([^\"]+)\">([^<]*)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var result: [Entry] = []
        for match in regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html)
            else { continue }
            let href = String(html[hrefRange])
            if href.hasPrefix("..") || href.hasPrefix("?") || href.hasPrefix("#") { continue }
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let name = String(html[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Entry(name: name.isEmpty ? url.lastPathComponent : name, url: url))
        }
        return result
    }

    // MARK: - Folder resolution

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func encodedPathComponent(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func folderURL(named name: String) -> URL {
        indexBase.appendingPathComponent(name, isDirectory: true)
    }

    /// Folder names the site uses for a display name: the name itself, it without
    /// trailing ?/!/: (titles carry those, folder names do not — "RV There Yet?" is
    /// uploaded as "RV There Yet"), its ™/®/’ removed, and the usual space/colon
    /// separators as dots or underscores.
    static func nameVariants(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cleaned = trimmed
            .replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")

        var bases: [String] = []
        func addBase(_ value: String) {
            let base = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, !bases.contains(base) else { return }
            bases.append(base)

            let withoutEnd = base.trimmingCharacters(
                in: CharacterSet(charactersIn: "?!"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutEnd != base, !withoutEnd.isEmpty { addBase(withoutEnd) }
        }
        addBase(trimmed)
        addBase(cleaned)

        var variants: [String] = []
        func add(_ value: String) {
            let variant = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !variant.isEmpty, !variants.contains(variant) else { return }
            variants.append(variant)
        }
        for base in bases {
            add(base)
            add(base.replacingOccurrences(of: " ", with: "."))
            add(base.replacingOccurrences(of: " ", with: "_"))
            add(base.replacingOccurrences(of: ":", with: "."))
            add(base.replacingOccurrences(of: ":", with: ".")
                .replacingOccurrences(of: " ", with: "."))
        }
        return variants
    }

    /// Finds the uploads folder for a game. The server's root index needs
    /// authorization, so only name variants are tried; the message says plainly
    /// when the game has no folder there.
    static func resolveFolder(for gameName: String,
                              progress: @escaping @Sendable (String) -> Void) async throws -> (url: URL, displayName: String) {
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagerError("Enter a game name first.") }

        let matches = await findFolders(for: trimmed, progress: progress)
        if let best = matches.first, best.isExact || matches.count == 1 {
            return (best.url, best.name)
        }
        if matches.count > 1 {
            throw ManagerError(
                "Several games on online-fix.me match “\(trimmed)”: "
                + matches.map(\.name).joined(separator: ", ")
                + ". Pick the right one to continue.")
        }
        throw ManagerError(
            "No OnlineFix upload folder for “\(trimmed)” on online-fix.me. "
            + "Not every game has one (single-player games often do not). "
            + "Download the fix from online-fix.me and install it with “Choose archive…”.")
    }

    // MARK: - Similar names

    /// One uploads folder that could be the game's. `isExact` is only true when
    /// the folder is named the game itself (case aside); anything found by
    /// searching — an edition, a subtitle, another title — gets asked about.
    struct FolderMatch: Identifiable, Hashable, Sendable {
        let name: String
        let url: URL
        let score: Double
        let isExact: Bool

        var id: String { name }
        var percent: Int { Int((score * 100).rounded()) }
    }

    /// Lowercased letters and numbers only, so "RV There Yet?" and "RV There Yet"
    /// are the same string.
    static func normalizedName(_ text: String) -> String {
        normalize(text)
    }

    /// Bigram Dice coefficient, 0…1. Enough to rank "RV There Yet Deluxe" above
    /// "RV There Yet Soundtrack" without pulling in a dependency.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a))
        let y = Array(normalize(b))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        if x == y { return 1 }
        guard x.count > 1, y.count > 1 else { return 0 }

        var counts: [String: Int] = [:]
        for i in 0..<(x.count - 1) {
            counts[String(x[i...i + 1]), default: 0] += 1
        }
        var overlap = 0
        for i in 0..<(y.count - 1) {
            let bigram = String(y[i...i + 1])
            if let n = counts[bigram], n > 0 {
                overlap += 1
                counts[bigram] = n - 1
            }
        }
        return 2.0 * Double(overlap) / Double((x.count - 1) + (y.count - 1))
    }

    /// Edition words the site leaves out of its folder names.
    private static let editionWords: [String] = [
        "game of the year", "goty", "definitive edition", "deluxe edition",
        "ultimate edition", "complete edition", "enhanced edition", "gold edition",
        "premium edition", "collector s edition", "director s cut",
        "anniversary edition", "remastered", "soundtrack", "original soundtrack",
        "ost", "demo", "playtest", "beta", "early access", "dlc", "season pass",
    ]

    /// Names to look for when the game's own name has no folder: the title cut
    /// before its subtitle or edition, without a year, without a leading "The",
    /// and with the usual punctuation variations. The site tends to name a folder
    /// after the plain title.
    /// One step simpler than the given name: no parenthetical, no subtitle, no
    /// year, no edition words, no leading "The", and "&" spelled either way. Each
    /// step only shortens or rewrites the name, so walking them always ends.
    static func simplerNames(_ value: String) -> [String] {
        var out: [String] = []
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return out }
        func push(_ candidate: String) {
            let result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, normalize(result) != normalize(trimmed) else { return }
            out.append(result)
        }

        // "Game (2024)" / "Game [Special Edition]" → "Game"
        for (open, close) in [("(", ")"), ("[", "]")] {
            if let o = trimmed.range(of: open, options: .backwards),
               let c = trimmed.range(of: close, options: .backwards),
               o.lowerBound < c.lowerBound, c.upperBound == trimmed.endIndex {
                push(String(trimmed[trimmed.startIndex..<o.lowerBound]))
            }
        }

        // "Game - Subtitle" / "Game: Subtitle" → "Game"
        for separator in [" - ", " – ", " — ", ": "] {
            if let range = trimmed.range(of: separator) {
                push(String(trimmed[trimmed.startIndex..<range.lowerBound]))
            }
        }

        // "Game 2024" → "Game"
        var words = trimmed.split(separator: " ").map(String.init)
        if let last = words.last, last.count == 4, last.allSatisfy(\.isNumber),
           let year = Int(last), (1950...2100).contains(year) {
            words.removeLast()
            push(words.joined(separator: " "))
        }

        // "Game Deluxe Edition", "Game Soundtrack", "Game GOTY" → "Game"
        let lowered = normalizedName(trimmed)
        for edition in editionWords where lowered.hasSuffix(normalize(edition)) {
            let spelled = edition.replacingOccurrences(of: " s ", with: "'s ")
            for word in [spelled, edition] {
                push(trimmed.replacingOccurrences(of: word, with: "",
                                                  options: [.caseInsensitive]))
            }
        }

        // "The Game" → "Game"
        if lowered.hasPrefix("the"), trimmed.count > 4 {
            push(String(trimmed.dropFirst(4)))
        }

        push(trimmed.replacingOccurrences(of: "&", with: "and"))
        push(trimmed.replacingOccurrences(of: " and ", with: " & "))
        return out
    }

    /// Names to look for when the game's own name has no folder: the title cut
    /// before its subtitle or edition, without a year, without a leading "The",
    /// and with the usual punctuation variations. The site tends to name a folder
    /// after the plain title.
    static func similarNameCandidates(_ name: String) -> [String] {
        let start = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !start.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()
        var queue: [(value: String, depth: Int)] = [(start, 0)]
        var head = 0

        while head < queue.count, results.count < 40 {
            let (value, depth) = queue[head]
            head += 1
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(normalize(trimmed)).inserted else { continue }
            results.append(trimmed)

            guard depth < 3 else { continue }
            for next in simplerNames(trimmed) {
                queue.append((next, depth + 1))
            }
        }
        return results
    }

    // MARK: - Folder search

    /// Every uploads folder that could be the game: the exact name variants first,
    /// then similar titles. Sorted best first; an exact match ends the search.
    static func findFolders(for gameName: String,
                            progress: @escaping @Sendable (String) -> Void) async -> [FolderMatch] {
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        progress("Looking for \(trimmed) on online-fix.me…")

        var tried = Set<String>()
        var matches: [FolderMatch] = []
        var requests = 0
        // Each candidate costs one request when the site has never heard of it, so
        // an obscure title with no folder gives up after a few dozen instead of
        // hammering the server.
        let requestBudget = 40

        func probe(_ name: String) async {
            for variant in nameVariants(name) {
                guard tried.insert(variant).inserted else { continue }
                guard requests < requestBudget else { return }
                requests += 1
                let url = folderURL(named: variant)
                guard let body = try? await html(url),
                      !entries(in: body, base: url).isEmpty else { continue }
                if !matches.contains(where: { $0.name == variant }) {
                    let exact = variant.compare(trimmed, options: [.caseInsensitive,
                                                                   .diacriticInsensitive]) == .orderedSame
                    matches.append(FolderMatch(name: variant, url: url,
                                               score: similarity(variant, trimmed),
                                               isExact: exact))
                }
                return
            }
        }

        await probe(trimmed)
        if let exact = matches.first(where: \.isExact) { return [exact] }

        if matches.isEmpty {
            progress("Nothing under “\(trimmed)”; looking for similar names…")
        }

        let similar = similarNameCandidates(trimmed)
            .filter { normalize($0) != normalize(trimmed) }
        for candidate in similar {
            guard requests < requestBudget, matches.count < 8 else { break }
            await probe(candidate)
            if let exact = matches.first(where: \.isExact) { return [exact] }
        }

        let unique = Dictionary(matches.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = unique.values.sorted {
            $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score
        }
        if let exact = sorted.first(where: \.isExact) {
            return [exact]
        }
        return Array(sorted.prefix(8))
    }

    // MARK: - Probe

    /// What a store page can know about a game before anything is installed: whether
    /// online-fix.me has a fix for it, and whether that fix is the Microsoft Store
    /// (GDK) build, which cannot run under Wine. One or two requests, cached by name.
    struct Probe: Sendable {
        let available: Bool
        let gdk: Bool
        let folder: String?
    }

    private static var probes: [String: Probe] = [:]

    static func probe(name: String) async -> Probe {
        let key = normalize(name)
        if let known = probes[key] { return known }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Probe(available: false, gdk: false, folder: nil) }

        for variant in nameVariants(trimmed) {
            let url = folderURL(named: variant)
            guard let body = try? await html(url),
                  let listing = Optional(entries(in: body, base: url)), !listing.isEmpty else { continue }
            var archives: [Entry] = []
            if let fixFolder = listing.first(where: {
                $0.isDirectory && normalize($0.name).contains("fix")
            }), let innerHTML = try? await html(fixFolder.url) {
                archives = entries(in: innerHTML, base: fixFolder.url)
            }
            archives += listing.filter {
                !$0.isDirectory && normalize($0.name).contains("fix")
            }
            let result = Probe(available: !archives.isEmpty,
                               gdk: archives.contains { $0.name.lowercased().contains("gdk") },
                               folder: variant)
            probes[key] = result
            return result
        }
        let empty = Probe(available: false, gdk: false, folder: nil)
        probes[key] = empty
        return empty
    }

    // MARK: - Archives

    static func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".rar") || lower.hasSuffix(".zip") || lower.hasSuffix(".7z")
            || lower.hasSuffix(".001") || lower.hasSuffix(".tar")
    }

    /// Returns the archive files that make up the fix (never the multi-gigabyte game parts).
    static func fixArchives(inFolder folder: URL,
                            progress: @escaping @Sendable (String) -> Void) async throws -> [URL] {
        let folderHTML = try await html(folder)
        let listing = entries(in: folderHTML, base: folder)

        // Prefer a "Fix …" subfolder.
        if let fixFolder = listing.first(where: {
            $0.isDirectory && normalize($0.name).contains("fix")
        }) {
            progress("Reading \(fixFolder.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")))…")
            let innerHTML = try await html(fixFolder.url)
            let inner = entries(in: innerHTML, base: fixFolder.url)
            let files = inner.filter { !$0.isDirectory && isArchive($0.name) }
            if !files.isEmpty { return files.map(\.url) }
        }

        // Otherwise any archive whose name mentions "fix".
        let named = listing.filter {
            !$0.isDirectory && isArchive($0.name) && normalize($0.name).contains("fix")
        }
        if !named.isEmpty { return named.map(\.url) }

        throw ManagerError("No fix archive found in that folder. The page may only host the full game.")
    }

    // MARK: - Download

    static let maxArchiveBytes: Int64 = 600 * 1024 * 1024

    static func download(_ url: URL, to destination: URL,
                         progress: @escaping @Sendable (String) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        attachCookies(to: &request, for: url)

        progress("Downloading \(url.lastPathComponent)…")
        var (temp, response) = try await session.download(for: request)

        // First try of a session: the folder listing that issued the auth cookie
        // may have expired (or never been read). Fetch it once and try again.
        if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 401 {
            try? FileManager.default.removeItem(at: temp)
            await primeCookies(for: url.deletingLastPathComponent())
            attachCookies(to: &request, for: url)
            (temp, response) = try await session.download(for: request)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ManagerError("Download failed (HTTP \(http.statusCode)) for \(url.lastPathComponent)")
        }
        let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size > maxArchiveBytes {
            throw ManagerError("\(url.lastPathComponent) is \(size / 1_048_576) MB — that looks like the game, not the fix. Pick the “Fix Repair” archive manually.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
