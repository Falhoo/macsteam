// The one thing that decides whether an unowned Photon game can connect: the auth
// type it sends.
//
// Photon applications are registered per game and tied to the game's own Steam
// AppID, so a Steam ticket is only accepted by the app Steam issued it for. An
// account that does not own the game never gets that ticket, which is why an
// unowned Photon game answers `32755 (Failed(2): error response from Steam)`.
//
// OnlineFix's own apps are the way round it: they are registered for custom auth,
// which asks Photon nothing about Steam. The client has to say so, and that is a
// property on the Photon assembly the game ships:
//
//     Photon.Realtime.AuthenticationValues.AuthType
//
// Its getter is `ldarg.0; ldfld AuthType; ret` and its setter is
// `ldarg.0; ldarg.1; stfld AuthType; ret`. Rewriting the getter to return
// `CustomAuthenticationType.Custom` makes every connection the game opens ask for
// custom auth, whatever its own code chose, and the length stays the same so no
// other IL moves. The IL is identical for every game on the same Photon build, so
// this is one patch for all of them, not per game.
//
// OnlineFix's own chain (`winmm` -> `OnlineFix64.dll` -> `Custom.dll`) does the same
// job on Windows, but its loader does not start under every Wine build and BepInEx 5
// does not survive Unity 6. This needs neither.
import Foundation

enum PhotonAuth {

    /// The suffix for the untouched copy of a patched assembly.
    static let backupSuffix = ".onlinefix-photonauth-backup"

    /// Which auth type the patch writes.
    ///
    /// `steam` is what OnlineFix's own applications are registered for: Photon has
    /// Steam check a ticket. Their app is registered for Spacewar (480), so the ticket
    /// that passes is the one Steam signs for the 480 route — an unowned account can
    /// always get that one, and can never get a ticket Steam vouches for on the game's
    /// own AppID. `custom` suits an app registered for custom auth. `none` strips auth
    /// altogether, for an app with it switched off; that also stops Photon reading the
    /// auth values, which is a second, shape-matched change.
    enum Mode: String, Sendable {
        case steam
        case custom
        case none

        var title: String {
            switch self {
            case .steam: return "CustomAuthenticationType.Steam"
            case .custom: return "CustomAuthenticationType.Custom"
            case .none: return "no auth at all"
            }
        }
    }

    /// What one assembly says about the property.
    struct Info: Sendable {
        var file: URL
        /// The enum the property is typed with, e.g. `CustomAuthenticationType`.
        var enumName: String
        /// Its members, in declaration order.
        var members: [(name: String, value: Int32)]
        /// The value that asks for OnlineFix's custom auth.
        var custom: Int32?
        /// The value that asks Photon to have Steam check a ticket.
        var steam: Int32?
        /// What the getter returns now, when that can be read.
        var current: Int32?
        var getterShape: Shape
        var setterShape: Shape
        /// True when the assembly has the method that builds the authenticate
        /// operation, which is what the no-auth mode edits.
        var canReachAuthenticate = false
        var patched: Bool
        /// True when Photon's read of the auth values is already stopped.
        var nonePatched = false
        var problem: String?

        enum Shape: String, Sendable {
            /// `ldarg.0; ldfld <field>; ret`, or already a constant.
            case simple
            /// A body this does not recognise, left alone.
            case unknown
            case missing
        }

        /// The value this assembly should send for a mode, when its enum has one.
        func value(for mode: Mode) -> Int32? {
            switch mode {
            case .steam: return steam
            case .custom: return custom
            case .none: return -1
            }
        }

        /// True when this assembly can take the patch.
        var canPatch: Bool {
            custom != nil && getterShape != .missing && getterShape != .unknown
        }

        /// True when this assembly can also take the no-auth change.
        var canStripAuth: Bool { canPatch && canReachAuthenticate }

        var summary: String {
            if let problem { return problem }
            guard let custom else {
                return "\(file.lastPathComponent): no custom auth member in \(enumName)"
            }
            let name = members.first { $0.value == custom }?.name ?? "\(custom)"
            if patched {
                return "\(file.lastPathComponent): auth type is \(name) (\(custom)); "
                    + "the app, not Steam, is asked"
            }
            let now = current.flatMap { value in
                members.first { $0.value == value }.map { "\($0.name) (\(value))" }
                    ?? "\(value)"
            } ?? "unreadable"
            return "\(file.lastPathComponent): auth type is \(now), would become "
                + "\(name) (\(custom))"
        }
    }

    // MARK: - Reading

    /// Every managed assembly in a game that carries Photon's `AuthenticationValues`.
    static func inspect(gameFolder: URL) -> [Info] {
        candidates(in: gameFolder).compactMap { inspect(file: $0) }
    }

    /// What one assembly says, or nil when it does not carry the property.
    static func inspect(file: URL) -> Info? {
        guard let assembly = ManagedAssembly(file),
              let type = assembly.type(named: "AuthenticationValues", namespace: "Photon.Realtime")
        else { return nil }
        let fields = assembly.fields(of: type)
        // Photon names the field `authType` and the property `AuthType`.
        guard let authType = fields.first(where: {
            $0.name.caseInsensitiveCompare("AuthType") == .orderedSame
        }) else { return nil }

        var info = Info(file: file, enumName: "CustomAuthenticationType", members: [],
                        custom: nil, steam: nil, current: nil, getterShape: .missing,
                        setterShape: .missing, patched: false, problem: nil)

        // The enum the property is typed with, and its members.
        if let token = assembly.signatureTypeToken(authType.signature) {
            if token.table == 0x02, let enumType = assembly.types.first(where: { $0.row == token.row }) {
                info.enumName = enumType.name
                for member in assembly.fields(of: enumType) {
                    guard let value = assembly.enumValue(of: member) else { continue }
                    info.members.append((member.name, value))
                }
                info.custom = info.members.first { $0.name == "Custom" }?.value
                info.steam = info.members.first { $0.name == "Steam" }?.value
            }
        }

        let methods = assembly.methods(of: type)
        if let getter = methods.first(where: { $0.name == "get_AuthType" }),
           let body = assembly.ilBody(rva: getter.rva) {
            let code = Array(assembly.data[body.code])
            info.getterShape = isGetter(code) ? .simple : .unknown
            info.current = read(code)
        }
        if let setter = methods.first(where: { $0.name == "set_AuthType" }),
           let body = assembly.ilBody(rva: setter.rva) {
            let code = Array(assembly.data[body.code])
            info.setterShape = isSimpleSetter(code) ? .simple : .unknown
        }

        // The method that builds the authenticate operation, for the no-auth mode.
        if let site = authenticateSite(in: assembly) {
            info.canReachAuthenticate = true
            info.nonePatched = site.nulled
        }

        // A build whose enum has no Custom member cannot use OnlineFix's apps.
        if info.custom == nil, info.getterShape != .missing {
            info.problem = "\(file.lastPathComponent): \(info.enumName) has no Custom member"
        }
        if info.getterShape == .unknown {
            info.problem = "\(file.lastPathComponent): get_AuthType is not the shape this "
                + "patch knows, so it was left alone."
        }
        // "Patched" is what the getter returns, not that a backup exists: a Steam
        // verify puts the stock assembly back and leaves the backup behind, so a
        // backup on its own said "already done" and the repair skipped it. The backup
        // only decides when the getter cannot be read at all, and then only if the
        // file actually differs from it.
        if info.custom != nil {
            if let current = info.current {
                info.patched = current == info.custom
            } else {
                info.patched = readsConstant(file: file, custom: info.custom!)
                    || differsFromBackup(file)
            }
        }
        return info
    }

    // MARK: - Applying

    /// The mode an unowned Photon game should use. OnlineFix's own apps are
    /// registered for Steam auth against Spacewar (480), and every account can get a
    /// 480 ticket, so `steam` is the one that fits them. An assembly whose enum has no
    /// Steam member is left with custom auth.
    static func unlicensedMode(in gameFolder: URL) -> Mode? {
        let infos = inspect(gameFolder: gameFolder).filter(\.canPatch)
        if infos.contains(where: { $0.steam != nil }) { return .steam }
        return infos.isEmpty ? nil : .custom
    }

    /// Turns the auth-type patch on or off. Returns the files written.
    @discardableResult
    static func setEnabled(_ on: Bool, in gameFolder: URL, mode: Mode = .custom) throws -> [String] {
        on ? try apply(to: gameFolder, mode: mode) : try restore(in: gameFolder)
    }

    private static func apply(to gameFolder: URL, mode: Mode) throws -> [String] {
        var written: [String] = []
        for info in inspect(gameFolder: gameFolder) where info.canPatch {
            guard let custom = info.custom, let assembly = ManagedAssembly(info.file) else {
                continue
            }
            guard let type = assembly.type(named: "AuthenticationValues",
                                           namespace: "Photon.Realtime"),
                  let getter = assembly.methods(of: type).first(where: {
                      $0.name == "get_AuthType"
                  }),
                  let body = assembly.ilBody(rva: getter.rva) else { continue }
            // The value comes from the assembly's own enum, and so does the check for
            // whether the work is already done: the getter returns a constant only
            // when it was patched, and a stock one reads the field (nil here).
            guard let wanted = info.value(for: mode) else { continue }
            if info.current == wanted, !info.nonePatched { continue }
            if mode == .none, info.nonePatched { continue }

            var data = assembly.data
            do {
                let code = Array(data[body.code])
                // The body is checked by its shape, not by its last byte: an already
                // patched body ends in padding nops, so `ret` is not last there and a
                // second pass (none after custom, or custom after a strip) would bail.
                guard info.getterShape == .simple, code.count >= 2,
                      let constant = ldc(wanted, length: code.count - 1) else { continue }
                var patched = constant
                patched.append(0x2A)
                while patched.count < code.count { patched.append(0x00) } // nop
                data.replaceSubrange(body.code, with: patched)

                // The setter, when the constant fits the room the body already has: the
                // argument load becomes the constant. The getter alone is enough for
                // Photon's own read of `AuthType`, so a setter that does not fit is left
                // alone rather than grown (growing moves every method after it).
                if let setter = assembly.methods(of: type).first(where: {
                    $0.name == "set_AuthType"
                }),
                   let setterBody = assembly.ilBody(rva: setter.rva) {
                    let setterCode = Array(data[setterBody.code])
                    if isSimpleSetter(setterCode),
                       let one = ldc(wanted, length: setterCode.count - 7), one.count == 1 {
                        var replacement: [UInt8] = [0x02]                  // ldarg.0
                        replacement.append(contentsOf: one)                // the constant
                        replacement.append(contentsOf: setterCode.suffix(from: 2)) // stfld, ret
                        if replacement.count == setterCode.count {
                            data.replaceSubrange(setterBody.code, with: replacement)
                        }
                    }
                }
            }

            // No-auth mode: stop Photon reading the auth values, so nothing about
            // authentication reaches the server. An app with auth switched off
            // refuses every type it is sent, and accepts a client that sends none.
            // The read it replaces is in the backup, so it can be put back.
            if mode == .none, let site = authenticateSite(in: assembly) {
                data.replaceSubrange(site.offset..<(site.offset + 6),
                                     with: [0x14, 0, 0, 0, 0, 0])
            } else if mode != .none, info.nonePatched, let site = authenticateSite(in: assembly),
                      let read = stockRead(file: info.file, at: site.offset) {
                data.replaceSubrange(site.offset..<(site.offset + 6), with: read)
            }

            let backup = URL(fileURLWithPath: info.file.path + backupSuffix)
            if !Paths.fm.fileExists(atPath: backup.path) {
                try Paths.fm.copyItem(at: info.file, to: backup)
            }
            try data.write(to: info.file, options: .atomic)
            written.append(info.file.path)
        }
        invalidate()
        return written
    }

    private static func restore(in gameFolder: URL) throws -> [String] {
        var restored: [String] = []
        guard let enumerator = Paths.fm.enumerator(
            at: gameFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(backupSuffix) else { continue }
            let original = URL(fileURLWithPath: String(url.path.dropLast(backupSuffix.count)))
            guard Paths.fm.fileExists(atPath: original.path) else {
                try? Paths.fm.removeItem(at: url)
                continue
            }
            try? Paths.fm.removeItem(at: original)
            try Paths.fm.copyItem(at: url, to: original)
            try? Paths.fm.removeItem(at: url)
            restored.append(original.path)
        }
        invalidate()
        return restored
    }

    // MARK: - Reading a body

    /// True when a getter body has the shape this knows: `ldarg.0; ldfld; ret`, or the
    /// constant it was patched into.
    private static func isGetter(_ code: [UInt8]) -> Bool {
        if constantValue(code) != nil { return true }
        return code.count >= 7 && code[0] == 0x02 && code[1] == 0x7B && code[6] == 0x2A
    }

    /// What a getter body returns now: the constant, when it is one, otherwise nil
    /// (it reads the field, and the field's value is only known to the game).
    private static func read(_ code: [UInt8]) -> Int32? { constantValue(code) }

    /// The value of a body that only loads a constant, when it is one.
    private static func constantValue(_ code: [UInt8]) -> Int32? {
        guard let first = code.first else { return nil }
        if first >= 0x16, first <= 0x1E {
            let value = Int32(first - 0x16)
            return code.dropFirst().allSatisfy { $0 == 0x00 || $0 == 0x2A } ? value : nil
        }
        if first == 0x15 {
            return code.dropFirst().allSatisfy { $0 == 0x00 || $0 == 0x2A } ? -1 : nil
        }
        if first == 0x1F, code.count >= 3 {
            return Int32(Int8(bitPattern: code[1]))
        }
        if first == 0x20, code.count >= 5 {
            let bytes = Array(code[1..<5])
            return Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                         | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        }
        return nil
    }

    /// `ldarg.0; ldarg.1; stfld <field>; ret`, or that already patched to load a
    /// constant instead of the argument.
    private static func isSimpleSetter(_ code: [UInt8]) -> Bool {
        guard code.count == 8, code[0] == 0x02, code[2] == 0x7D, code[7] == 0x2A else {
            return false
        }
        return code[1] == 0x03 || (code[1] >= 0x15 && code[1] <= 0x1E)
    }

    /// A `ldc.i4` for a value, padded or sized to `length` bytes.
    private static func ldc(_ value: Int32, length: Int) -> [UInt8]? {
        let small = value >= 0 && value <= 8 ? [UInt8(0x16 + value)] : nil
        let one = value >= -1 && value <= 8 ? (small ?? [0x15]) : nil
        let bytes = value >= -128 && value <= 127
            ? [0x1F, UInt8(bitPattern: Int8(value))]
            : [0x20, UInt8(UInt32(bitPattern: value) & 0xFF),
               UInt8((UInt32(bitPattern: value) >> 8) & 0xFF),
               UInt8((UInt32(bitPattern: value) >> 16) & 0xFF),
               UInt8((UInt32(bitPattern: value) >> 24) & 0xFF)]
        if let one, one.count <= length { return one }
        return bytes.count <= length ? bytes : nil
    }

    /// The six bytes of the read that `authenticateSite` replaces, taken from the
    /// untouched copy at the same place. Nil when the copy is gone or has moved.
    private static func stockRead(file: URL, at offset: Int) -> [UInt8]? {
        let backup = URL(fileURLWithPath: file.path + backupSuffix)
        guard Paths.fm.fileExists(atPath: backup.path),
              let data = try? Data(contentsOf: backup, options: [.mappedIfSafe]),
              offset >= 0, offset + 6 <= data.count else { return nil }
        let bytes = Array(data[offset..<(offset + 6)])
        // `ldarg.0; ldfld <token>`: the shape the site was found by.
        guard bytes[0] == 0x02, bytes[1] == 0x7B else { return nil }
        return bytes
    }

    // MARK: - Stopping the read

    /// The place in `CallAuthenticate` that decides whether to authenticate at all:
    /// it reads one of the client's own fields and branches on it. Replacing the six
    /// bytes of that read with `ldnull` makes the branch fall through to Photon's own
    /// "no auth" path, and the field itself stays intact for the game's code. Six
    /// bytes in, six bytes out, so no other instruction moves.
    private static func authenticateSite(in assembly: ManagedAssembly) -> (offset: Int,
                                                                          nulled: Bool)? {
        guard let client = assembly.type(named: "LoadBalancingClient",
                                         namespace: "Photon.Realtime"),
              let method = assembly.methods(of: client).first(where: {
                  $0.name.lowercased().contains("callauthenticate")
              }),
              let body = assembly.ilBody(rva: method.rva) else { return nil }
        let bytes = [UInt8](assembly.data[body.code])
        var index = 0
        while index + 7 < bytes.count {
            let branch = bytes[index + 6]
            guard branch == 0x2D || branch == 0x2C else {
                index += 1
                continue
            }
            // The stock read: `ldarg.0; ldfld <field>; br…`
            if bytes[index] == 0x02, bytes[index + 1] == 0x7B, bytes[index + 5] == 0x04 {
                return (body.code.lowerBound + index, false)
            }
            // The same place after this patch: `ldnull; nop…; br…`
            if bytes[index] == 0x14, bytes[index + 1] == 0x00, bytes[index + 2] == 0x00 {
                return (body.code.lowerBound + index, true)
            }
            index += 1
        }
        return nil
    }

    // MARK: - Where to look

    /// The assemblies that can carry Photon's client: `PhotonRealtime.dll` beside the
    /// game, inside a Mac bundle's Managed folder, or merged into the game's own.
    private static func candidates(in folder: URL) -> [URL] {
        guard let enumerator = Paths.fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "dll" else { continue }
            let name = url.lastPathComponent.lowercased()
            guard name.contains("photon") || name.contains("assembly-csharp") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size > 1024 else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A cheap check, for a bundle the manager has already patched.
    private static func readsConstant(file: URL, custom: Int32) -> Bool {
        guard let assembly = ManagedAssembly(file),
              let type = assembly.type(named: "AuthenticationValues",
                                       namespace: "Photon.Realtime"),
              let getter = assembly.methods(of: type).first(where: { $0.name == "get_AuthType" }),
              let body = assembly.ilBody(rva: getter.rva) else { return false }
        return constantValue(Array(assembly.data[body.code])) == custom
    }

    private static func hasBackup(_ file: URL) -> Bool {
        Paths.fm.fileExists(atPath: file.path + backupSuffix)
    }

    /// True when the assembly no longer matches its untouched copy, which is the
    /// question a backup is really being asked.
    private static func differsFromBackup(_ file: URL) -> Bool {
        let backup = URL(fileURLWithPath: file.path + backupSuffix)
        guard let current = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              let original = try? Data(contentsOf: backup, options: [.mappedIfSafe]) else {
            return false
        }
        return current != original
    }

    // MARK: - Cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Info]] = [:]

    /// The state for a game folder, cached until the files change.
    static func state(in gameFolder: URL?) -> [Info] {
        guard let gameFolder else { return [] }
        let key = gameFolder.path
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        let infos = inspect(gameFolder: gameFolder)
        lock.lock()
        cache[key] = infos
        lock.unlock()
        return infos
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

// MARK: - Learning which auth a Photon app wants

extension PhotonAuth {

    /// The mode the assemblies are sending right now, when it can be told.
    static func observedMode(in gameFolder: URL) -> Mode? {
        let infos = inspect(gameFolder: gameFolder).filter(\.canPatch)
        for info in infos {
            guard let current = info.current else { continue }
            if current == info.custom { return .custom }
            if current == info.steam { return .steam }
        }
        return nil
    }

    /// The modes this game's assemblies could send, best first, `none` last.
    static func modes(in gameFolder: URL) -> [Mode] {
        let infos = inspect(gameFolder: gameFolder).filter(\.canPatch)
        guard !infos.isEmpty else { return [] }
        var modes: [Mode] = []
        if infos.contains(where: { $0.steam != nil }) { modes.append(.steam) }
        if infos.contains(where: { $0.custom != nil }) { modes.append(.custom) }
        if infos.contains(where: \.canStripAuth) { modes.append(.none) }
        return modes
    }

    /// Which mode to try after Photon turned one down.
    ///
    /// No game tells the fix which auth its Photon app is registered for, and the
    /// answer is not the same for every app: one refuses the type outright, the next
    /// accepts the type and refuses the Steam ticket it carries. Both answers are in
    /// the game's own log, so the patch follows them instead of guessing: a refused
    /// type moves to the other type, and a refused ticket moves from Steam's to the
    /// app's own auth, which carries no ticket to refuse.
    static func nextMode(after failure: PhotonLog.Evidence.Failure, current: Mode?,
                         in gameFolder: URL) -> Mode? {
        let all = modes(in: gameFolder)
        let usable = all.filter { $0 != current }
        switch failure {
        case .authTypeRefused:
            // The type itself is wrong: take the other one.
            return usable.first { $0 != .none }
        case .ticketRejected:
            // The credentials were refused. Whichever auth type is in use, the other one
            // is the retry: Steam's ticket is refused by an app that wants its own auth,
            // and a custom login is refused by an app that wants Steam's. The caller
            // keeps a set of what has been tried, so this cannot ping-pong.
            return usable.first { $0 == (current == .steam ? .custom : .steam) }
                ?? usable.first { $0 != .none }
        case .appIDRefused:
            return nil
        case .authRefused:
            // Nothing more specific: only change the type if it has not been tried.
            return current == nil ? all.first : nil
        case .none:
            return nil
        }
    }
}
