// Asking Photon whether an app id is alive, without the game.
//
// Every Photon client opens with the same handshake: two bytes of magic, an Init
// message holding the app id and the app version, and the server answers with an
// error code and the regions it serves. That is a conversation a few bytes can have,
// so the installer can check an app id while the game is open — or before it ever
// starts — instead of waiting for the game to walk its own menus and hoping.
import Foundation

enum PhotonProbe {

    struct Answer: Sendable, Equatable {
        var appID: String
        /// Photon's error code for the Init. 0 is "I know this app".
        var code: Int
        var message: String
        var regions: [String]
        var host: String

        var isKnownApp: Bool { code == 0 }
        var summary: String {
            if code == 0 {
                return "Photon knows \(appID)"
                    + (regions.isEmpty ? "" : " (regions: \(regions.joined(separator: ", ")))")
            }
            return "Photon answered \(code)\(message.isEmpty ? "" : " (\(message))") for \(appID)"
        }
    }

    /// The endpoints a Photon client opens: the nameserver every game starts at, and
    /// the relays the regions live on. Pinging them says whether the machine can reach
    /// Photon at all — the difference between "this game's patch is wrong" and "nothing
    /// gets out", which look identical in a game log.
    /// The nameserver's socket protocol and its websocket port, which is what any
    /// Photon build on this Mac opens before it can reach a region at all. The region
    /// relays themselves answer over UDP or websockets, so opening them with a TCP
    /// handshake proves less than it seems.
    static let endpoints: [(name: String, host: String, port: UInt16)] = [
        ("nameserver", "ns.photonengine.io", 4533),
        ("websocket", "ns.photonengine.io", 9093),
    ]

    struct Ping: Sendable, Equatable {
        var name: String
        var host: String
        /// Milliseconds to open a TCP connection, nil when it did not open.
        var milliseconds: Int?

        var isUp: Bool { milliseconds != nil }
    }

    /// Opens each endpoint in turn. A nil result for all of them means nothing on this
    /// machine reaches Photon, so no patch can connect and the report says so instead
    /// of blaming the auth type.
    static func ping(timeout: TimeInterval = 3) -> [Ping] {
        endpoints.map { endpoint in
            Ping(name: endpoint.name, host: endpoint.host,
                 milliseconds: connectMilliseconds(endpoint.host, endpoint.port,
                                                   timeout: timeout))
        }
    }

    static func summary(_ pings: [Ping]) -> String {
        let up = pings.filter(\.isUp)
        guard !up.isEmpty else {
            return "Photon is not reachable from this Mac at all: no endpoint opened."
        }
        let parts = up.map { "\($0.name) \($0.milliseconds ?? 0) ms" }
        let down = pings.filter { !$0.isUp }.map(\.name)
        return "Photon answers (\(parts.joined(separator: ", ")))"
            + (down.isEmpty ? "" : "; no answer from \(down.joined(separator: ", "))")
    }

    private static func connectMilliseconds(_ host: String, _ port: UInt16,
                                            timeout: TimeInterval) -> Int? {
        let started = Date()
        guard let fd = connect(HostPort(host: host, port: port), timeout: timeout) else {
            return nil
        }
        close(fd)
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    struct HostPort: Sendable { var host: String; var port: UInt16 }

    /// Kept for the handshake check: the Init packet a client opens with, when a
    /// nameserver bothers to answer one. Unused by the report; a nameserver that
    /// closes without a word is normal on some networks.
    static func ask(appID: String, version: String = "1.0",
                    timeout: TimeInterval = 4) -> Answer? {
        guard let fd = connect(HostPort(host: "ns.photonengine.io", port: 4533),
                               timeout: timeout) else { return nil }
        defer { close(fd) }
        guard sendInit(fd, appID: appID, version: version),
              let reply = readInit(fd, timeout: timeout) else { return nil }
        return Answer(appID: appID, code: reply.code, message: reply.message,
                      regions: reply.regions, host: "ns.photonengine.io")
    }

    // MARK: - Wire

    /// `F3 02` magic, `02` Init, then length-prefixed app id, app version, and the
    /// serializer byte. Photon's own clients send exactly this before anything else.
    static func sendInit(_ socket: Int32, appID: String, version: String) -> Bool {
        var packet = Data([0xf3, 0x02, 0x02])
        let idLength = UInt16(appID.utf8.count), versionLength = UInt16(version.utf8.count)
        packet.append(UInt8(idLength >> 8)); packet.append(UInt8(idLength & 0xff))
        packet.append(contentsOf: appID.utf8)
        packet.append(UInt8(versionLength >> 8)); packet.append(UInt8(versionLength & 0xff))
        packet.append(contentsOf: version.utf8)
        packet.append(0)            // serializer: protocol16
        packet.append(0)            // no region preference
        return packet.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let wrote = write(socket, buffer.baseAddress!.advanced(by: sent),
                                  buffer.count - sent)
                if wrote <= 0 { return false }
                sent += wrote
            }
            return true
        }
    }

    /// `F3 02 02 <code:2> <messageLen:2> <message>`; a success continues with the
    /// server's region list, which is only read for the report.
    static func readInit(_ socket: Int32, timeout: TimeInterval) -> (code: Int, message: String, regions: [String])? {
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var head = [UInt8](repeating: 0, count: 7)
        guard readFully(socket, &head) else { return nil }
        guard head[0] == 0xf3, head[1] == 0x02 else { return nil }
        let code = Int(head[3]) << 8 | Int(head[4])
        let length = Int(head[5]) << 8 | Int(head[6])
        var message = ""
        if length > 0, length < 4096 {
            var text = [UInt8](repeating: 0, count: length)
            if readFully(socket, &text) {
                message = String(decoding: text, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var regions: [String] = []
        if code == 0 {
            // Region blob: a byte count, then one entry per region made of a
            // length-prefixed host and a length-prefixed code. Anything unexpected
            // just means no regions are reported.
            var count = [UInt8](repeating: 0, count: 1)
            if readFully(socket, &count) {
                for _ in 0..<Int(count[0]) {
                    var lengthByte = [UInt8](repeating: 0, count: 1)
                    guard readFully(socket, &lengthByte) else { break }
                    var host = [UInt8](repeating: 0, count: Int(lengthByte[0]))
                    guard readFully(socket, &host) else { break }
                    guard readFully(socket, &lengthByte) else { break }
                    var regionCode = [UInt8](repeating: 0, count: Int(lengthByte[0]))
                    guard readFully(socket, &regionCode) else { break }
                    let code = String(decoding: regionCode, as: UTF8.self)
                    if !code.isEmpty { regions.append(code) }
                }
            }
        }
        return (code, message, regions)
    }

    // MARK: - Sockets

    private static func connect(_ target: HostPort, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &list) == 0,
              let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype,
                            current.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(fd, current.pointee.ai_addr,
                                  current.pointee.ai_addrlen) == 0 { return fd }
                close(fd)
            }
            node = current.pointee.ai_next
        }
        return nil
    }

    private static func readFully(_ socket: Int32, _ buffer: inout [UInt8]) -> Bool {
        var done = 0
        let total = buffer.count
        while done < total {
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(socket, raw.baseAddress!.advanced(by: done), total - done)
            }
            if got <= 0 { return false }
            done += got
        }
        return true
    }
}
