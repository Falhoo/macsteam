// Patching a native macOS game build the way an OnlineFix patches a Windows one.
//
// An OnlineFix for Windows is a set of PE DLLs the game's own process loads in place
// of its Steam API. They forge the Steam ticket, start the game as Spacewar (480), and
// point Photon at OnlineFix's shared app. A shipped macOS build is a signed Mach-O
// bundle that loads none of those files, so the fix has to be written into the
// bundle instead:
//
//  - the Steam half (identity, ticket, the 480 route) is supplied by macSteam's dylib
//    inside the Steam client, which every game Steam launches inherits. Nothing is
//    copied into the game for it.
//  - the Photon half is the game's own Photon app id, which lives in its serialized
//    assets or IL2CPP metadata. That is found and swapped here, generically, for any
//    Unity build whose id can be read.
//  - a game whose Windows fix also changes code in memory needs that change written
//    into its Mach-O binary. Those changes cannot be derived from the package, so
//    each is described per game by the bytes around the instruction; a build that
//    changed is refused rather than corrupted.
//
// Every file this writes keeps an untouched copy beside it, and the bundle is signed
// again (inner binary first, then the bundle) so macOS still runs it.
import Foundation

enum MacBundlePatch {

    /// One code change written into a Mach-O binary. The instruction is found by the
    /// bytes around it, because signing the binary again moves everything after the
    /// header by a whole number of pages.
    struct CodePatch: Sendable, Equatable {
        /// What the change does, for the message.
        let name: String
        /// Path inside the bundle.
        let file: String
        let before: [UInt8]
        let stock: [UInt8]
        let patched: [UInt8]
        let after: [UInt8]
    }

    /// Everything a particular game's Mac build needs beyond the Photon app id.
    struct Profile: Sendable {
        let bundleID: String
        /// Steam's AppID for the game, which is how the fix manager names it even
        /// when the bundle carries no readable Info.plist.
        let appIDs: [Int]
        let name: String
        /// Suffix for the untouched copies of the files this patches.
        let backupSuffix: String
        let codePatches: [CodePatch]
    }

    /// The games whose Mac build this knows beyond the Photon id. A game that is not
    /// here is still patched when its Photon id can be read: that is the whole fix for
    /// such a game, and the profile only adds code changes.
    static let profiles: [Profile] = [PicoPark2Patch.profile]

    // MARK: - What a build needs

    struct State: Sendable {
        /// The bundle this is about, or nil when there is no Mac build installed.
        var bundle: URL?
        /// True when the bundle carries OnlineFix's Photon app and nothing to replace.
        var isPatched = false
        /// True when the bundle carries a Photon app id, or a code change this knows.
        var canPatch = false
        /// What to say instead of the switch, when it cannot be used.
        var message: String?
        /// The Photon app ids read from the bundle, for a report.
        var photonIDs: [String] = []

        /// One line for a sheet or a diagnosis.
        var summary: String {
            if canPatch {
                return isPatched
                    ? "The Mac build carries OnlineFix's Photon app id."
                    : "The Mac build's Photon app id can be replaced with OnlineFix's."
            }
            return message ?? "This Mac build carries nothing the fix can change."
        }
    }

    /// The profile for a bundle, by its bundle identifier, or else by the code the
    /// profile changes: a build that carries that instruction is that game, and only
    /// that game.
    static func profile(for app: URL) -> Profile? {
        if let id = bundleIdentifier(of: app) {
            return profiles.first { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
        }
        return profiles.first { profile in
            profile.codePatches.contains { patch in
                guard let data = data(at: app.appendingPathComponent(patch.file)) else {
                    return false
                }
                return instructionOffset(in: data, patch: patch) != nil
            }
        }
    }

    /// The profile a game folder belongs to, by the AppID the manager knows it as.
    static func profile(appID: Int, bundle: URL?) -> Profile? {
        if let bundle, let profile = profile(for: bundle) { return profile }
        return profiles.first { $0.appIDs.contains(appID) }
    }

    private static func bundleIdentifier(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let id = object["CFBundleIdentifier"] as? String else { return nil }
        return id
    }

    /// What the switch should show for a game folder.
    static func state(in gameFolder: URL?) -> State? {
        guard let folder = gameFolder,
              let bundle = FixInstaller.nativeMacBundle(in: folder) else { return nil }
        return state(of: bundle)
    }

    /// What the switch should show for a bundle this is pointed at directly.
    static func state(of bundle: URL) -> State {
        let key = bundle.path
        if let cached = cachedState(key: key, bundle: bundle) { return cached }
        let state = readState(of: bundle)
        storeState(state, key: key, bundle: bundle)
        return state
    }

    /// True when this bundle can take a patch: a Photon app id to replace, or a code
    /// change that matches this build.
    static func canPatch(_ bundle: URL) -> Bool { state(of: bundle).canPatch }

    // MARK: - Reading

    private static func readState(of bundle: URL) -> State {
        let profile = profile(for: bundle)
        let scanned = PhotonPatch.scan(in: bundle)
        let plan = PhotonPatch.plan(for: scanned)
        let carried = carriedIDs(in: bundle)
        var state = State(bundle: bundle, photonIDs: (carried.own + carried.shared).sorted())

        // The bundle is patched when its ids are already the ones the fix points at,
        // which is what an empty change list with a readable id means. A scan that
        // could not place the id falls back to the plain byte search: OnlineFix's own
        // id present and the game's own absent.
        let settled = plan.skipped == nil && plan.changes.isEmpty && !scanned.isEmpty
        state.isPatched = settled || (carried.own.isEmpty && !carried.shared.isEmpty)
        state.canPatch = settled || !carried.own.isEmpty || !carried.shared.isEmpty

        if let profile, !profile.codePatches.isEmpty {
            var known = true
            var applied = true
            for patch in profile.codePatches {
                guard let data = data(at: bundle.appendingPathComponent(patch.file)),
                      let start = instructionOffset(in: data, patch: patch) else {
                    known = false
                    continue
                }
                if Array(data[start..<(start + patch.patched.count)]) != patch.patched {
                    applied = false
                }
            }
            state.canPatch = state.canPatch && known
            state.isPatched = state.isPatched && applied
            if !known {
                state.message = "This \(profile.name) build is not the one the fix was worked "
                    + "out against, so its files were not touched. A game update usually "
                    + "means this."
                return state
            }
        }

        if !state.canPatch {
            state.message = "This Mac build carries no Photon app id, so its online play does "
                + "not go through Photon and there is no id for the fix to point at its shared "
                + "app. It starts as itself and takes Steam's identity from macSteam, so the "
                + "bundle needs no change."
        }
        return state
    }

    /// The Photon app ids a bundle carries: the ones OnlineFix calls its own, and the
    /// game's own that would be replaced.
    ///
    /// Two readers, because two kinds of file carry an id. The scanner knows the
    /// shapes a Photon build uses (a `PhotonServerSettings` asset, an IL2CPP string
    /// literal, a known id). A plain byte search covers a build whose id sits glued to
    /// its neighbours, which is how an IL2CPP string table stores every literal.
    static func carriedIDs(in bundle: URL) -> (own: [String], shared: [String]) {
        var own = Set<String>()
        var shared = Set<String>()
        for candidate in PhotonPatch.scan(in: bundle) {
            if candidate.isOnlineFixShared { shared.insert(candidate.id) }
            else { own.insert(candidate.id) }
        }
        let sharedIDs = PhotonIDs.shared + [PhotonPatch.onlineFixQuantumID]
        for url in readableFiles(in: bundle) {
            guard let data = data(at: url) else { continue }
            for id in sharedIDs where data.range(of: Data(id.utf8)) != nil {
                shared.insert(id)
            }
            for id in PhotonPatch.knownStockIDs where data.range(of: Data(id.utf8)) != nil {
                own.insert(id)
            }
        }
        return (own.sorted(), shared.sorted())
    }

    // MARK: - Apply

    /// Turns the patch on or off, and reports the files written.
    ///
    /// `sign` is the re-signing step, so a test can run the file work without a real
    /// Mach-O bundle.
    /// `auth` writes the auth type as well, for a game whose own Steam ticket cannot
    /// be accepted. It is part of the same patch, so it is undone with it.
    @discardableResult
    static func setEnabled(_ on: Bool, app: URL, auth: PhotonAuth.Mode? = nil,
                           sign: (URL) throws -> Void = PhotonPatch.resign) throws -> [String] {
        on ? try applyAll(on: app, auth: auth, sign: sign)
           : try restoreAll(app: app, sign: sign)
    }

    private static func applyAll(on app: URL, auth: PhotonAuth.Mode?,
                                 sign: (URL) throws -> Void) throws -> [String] {
        let profile = profile(for: app)
        let carried = carriedIDs(in: app)
        var written: [String] = []

        if !carried.own.isEmpty {
            let plan = PhotonPatch.plan(for: PhotonPatch.scan(in: app))
            if let skipped = plan.skipped { throw ManagerError(skipped) }
            if !plan.changes.isEmpty {
                written += try PhotonPatch.apply(plan.changes, in: app, sign: sign)
            } else {
                // The scanner places the id; it does not when the id is glued to its
                // neighbours and there is no literal table to read. Replace every copy
                // in the files that carry it, which is the same change either way.
                for id in carried.own {
                    guard let kind = PhotonPatch.kind(of: id) else { continue }
                    let target = kind == .quantum ? PhotonPatch.onlineFixQuantumID
                                                  : PhotonIDs.realtime
                    guard target != id else { continue }
                    written += try PhotonPatch.applyEverywhere(
                        id, target, to: files(in: app, carrying: id), sign: sign)
                }
            }
        } else if carried.shared.isEmpty, let profile {
            throw ManagerError("This \(profile.name) build does not carry the Photon app id "
                + "the fix replaces, so nothing was changed.")
        }

        if let profile, !profile.codePatches.isEmpty {
            written += try applyCode(profile, in: app, sign: sign)
        }
        // An unowned game must not ask Photon for a ticket: no ticket Steam can sign
        // for its own app exists. The assembly is patched in place like anything else
        // in the bundle, and `applyCode` has already signed the binaries it wrote, so
        // the bundle is signed once more at the end.
        // Always tried, not only when this pass wrote something: the ids can already
        // be the target ones from an earlier install that had no auth to add.
        if let auth {
            let patched = try PhotonAuth.setEnabled(true, in: app, mode: auth)
            if !patched.isEmpty {
                for path in patched {
                    try sign(URL(fileURLWithPath: path))
                }
                written += patched
            }
        }
        invalidate(app)
        return Array(Set(written)).sorted()
    }

    private static func restoreAll(app: URL, sign: (URL) throws -> Void) throws -> [String] {
        var written = try PhotonPatch.restore(in: app, sign: sign)
        // The auth patch keeps its own copies in the same bundle; both suffixes are
        // restored here, so an undo leaves the bundle as Steam shipped it.
        do {
            let restored = try PhotonAuth.setEnabled(false, in: app)
            for path in restored { try sign(URL(fileURLWithPath: path)) }
            written += restored
        } catch {
            // A bundle with no auth patch of its own still undoes its ids above.
        }
        if let profile = profile(for: app) {
            for patch in profile.codePatches {
                if let restored = try? restoreCode(patch, profile: profile, in: app, sign: sign) {
                    written += restored
                }
            }
        }
        invalidate(app)
        return written
    }

    // MARK: - Code changes

    private static func applyCode(_ profile: Profile, in app: URL,
                                  sign: (URL) throws -> Void) throws -> [String] {
        var written: [String] = []
        for patch in profile.codePatches {
            let url = app.appendingPathComponent(patch.file)
            guard let data = data(at: url) else {
                throw ManagerError("The files \(profile.name)'s fix changes are missing from "
                    + "\(app.lastPathComponent). Reinstall the game in Steam and try again.")
            }
            guard let start = instructionOffset(in: data, patch: patch) else {
                throw ManagerError("This \(profile.name) build's code is not the one the fix "
                    + "was worked out against, so nothing was changed.")
            }
            if Array(data[start..<(start + patch.patched.count)]) == patch.patched { continue }
            try backUp(url, suffix: profile.backupSuffix)
            var patched = data
            patched.replaceSubrange(start..<(start + patch.stock.count), with: patch.patched)
            try write(patched, to: url)
            try sign(url)
            written.append(url.path)
        }
        if !written.isEmpty { try sign(app) }
        return written
    }

    private static func restoreCode(_ patch: CodePatch, profile: Profile, in app: URL,
                                    sign: (URL) throws -> Void) throws -> [String] {
        let url = app.appendingPathComponent(patch.file)
        let backup = URL(fileURLWithPath: url.path + profile.backupSuffix)
        guard Paths.fm.fileExists(atPath: backup.path),
              let original = data(at: backup) else { return [] }
        try write(original, to: url)
        try? Paths.fm.removeItem(at: backup)
        try sign(url)
        try sign(app)
        return [url.path]
    }

    /// Where the instruction sits in this copy of the binary, or nil when the code
    /// around it is not the one the patch was worked out against.
    static func instructionOffset(in data: Data, patch: CodePatch) -> Int? {
        guard !patch.before.isEmpty else { return nil }
        let found = data.range(of: Data(patch.before))
        guard let found else { return nil }
        let start = found.lowerBound + patch.before.count
        let end = start + patch.stock.count + patch.after.count
        guard end <= data.count,
              data.subdata(in: (start + patch.stock.count)..<end) == Data(patch.after),
              Array(data[start..<(start + patch.stock.count)]) == patch.stock
                || Array(data[start..<(start + patch.stock.count)]) == patch.patched
        else { return nil }
        return start
    }

    // MARK: - Files

    /// The files a Photon app id can live in: the serialized assets and the IL2CPP
    /// metadata, not the multi-megabyte streaming payloads beside them.
    static func readableFiles(in bundle: URL) -> [URL] {
        var out: [URL] = []
        guard let enumerator = Paths.fm.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > PhotonPatch.maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(PhotonPatch.backupSuffix)
                || name.hasSuffix(PicoPark2Patch.backupSuffix)
                || name.hasSuffix(PhotonAuth.backupSuffix) { continue }
            guard PhotonPatch.isReadable(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= PhotonPatch.maxFileSize,
                  PhotonPatch.sizeAllows(url, size: size)
            else { continue }
            out.append(url)
        }
        return out
    }

    private static func files(in bundle: URL, carrying id: String) -> [URL] {
        let bytes = Data(id.utf8)
        return readableFiles(in: bundle).filter { url in
            guard let data = data(at: url) else { return false }
            return data.range(of: bytes) != nil
        }
    }

    private static func data(at url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func backUp(_ url: URL, suffix: String) throws {
        let copy = URL(fileURLWithPath: url.path + suffix)
        guard !Paths.fm.fileExists(atPath: copy.path) else { return }
        try Paths.fm.copyItem(at: url, to: copy)
    }

    // MARK: - Cache

    // A sheet redraw reads the state again. Reading a bundle's assets costs a few
    // megabytes, so the answer is kept until one of the files it was read from
    // changes; signing the bundle again changes them, which is the usual edit.
    private static let cacheLock = NSLock()
    private static var cache: [String: (fingerprint: String, state: State)] = [:]

    private static func fingerprint(of bundle: URL) -> String {
        readableFiles(in: bundle).map { url -> String in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            return "\(url.path)|\(date)|\(size)"
        }.joined(separator: "\n")
    }

    private static func cachedState(key: String, bundle: URL) -> State? {
        let stamp = fingerprint(of: bundle)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key], entry.fingerprint == stamp else { return nil }
        return entry.state
    }

    private static func storeState(_ state: State, key: String, bundle: URL) {
        let stamp = fingerprint(of: bundle)
        cacheLock.lock()
        cache[key] = (stamp, state)
        cacheLock.unlock()
    }

    /// Drops the cached answer for a bundle this just changed.
    static func invalidate(_ bundle: URL) {
        cacheLock.lock()
        cache[bundle.path] = nil
        cacheLock.unlock()
    }
}
