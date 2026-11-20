// Steam.app installer
import Foundation

enum SteamInstaller {

    enum Status: Equatable {
        case notInstalled          // pristine Valve bundle
        case installed             // macsteam injected, runtime stripped
        case outdated(bundled: String, deployed: String) // dylib needs update
        case needsOnlineFix        // macSteam is in, its separate OnlineFix dylib is not
        case steamMissing          // /Applications/Steam.app absent
        case foreign               // patched by something else (unknown state)
    }

    struct PermissionDenied: Error {}

    // MARK: - Status

    static func status() -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.steamApp.path) else { return .steamMissing }

        let dylibPresent = fm.fileExists(atPath: Paths.steamAppInjectedDylib.path)
        let insertsUs = insertedLibraries().contains(Paths.steamAppInjectedDylib.path)

        if dylibPresent && insertsUs {
            let bundled = bundledDylibVersion()
            let deployed = deployedDylibVersion()
            if let bundled, let deployed, bundled != deployed {
                return .outdated(bundled: bundled, deployed: deployed)
            }
            // OnlineFix routing is part of macsteam.dylib, so a Steam.app from an
            // older build just needs Install run again.
            return .installed
        }
        if lsEnvironmentInsert() != nil { return .foreign }
        return .notInstalled
    }

    static func bundledDylibVersion() -> String? {
        guard let url = Bundle.main.url(forResource: "macsteam.dylib", withExtension: "version") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deployedDylibVersion() -> String? {
        let url = Paths.configDir.appendingPathComponent("dylib.version")
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func updateBlockEnabled() -> Bool {
        FileManager.default.fileExists(atPath: Paths.steamCfgRoot.path)
    }

    // MARK: - Install

    static func install(sourceDylib: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.steamApp.path) else {
            throw StepFailure(step: "Locate Steam", detail: "/Applications/Steam.app not found. Install Steam first.")
        }
        guard fm.fileExists(atPath: sourceDylib.path) else {
            throw StepFailure(step: "Locate payload", detail: "Bundled macsteam.dylib is missing.")
        }
        try ensureModifiable()

        Subprocess.killSteam()

        do {
            if fm.fileExists(atPath: Paths.steamAppInjectedDylib.path) {
                try fm.removeItem(at: Paths.steamAppInjectedDylib)
            }
            try fm.copyItem(at: sourceDylib, to: Paths.steamAppInjectedDylib)

            // Write the deployed version so update checks can compare against it.
            if let version = bundledDylibVersion() {
                try? Paths.ensureDir(Paths.configDir)
                let versionFile = Paths.configDir.appendingPathComponent("dylib.version")
                try? version.write(to: versionFile, atomically: true, encoding: .utf8)
            }
        } catch {
            throw StepFailure(step: "Copy payload", detail: error.localizedDescription)
        }

        try deploySignatures()
        try CloudRedirectRuntime.install()
        try deployOnlineFix()
        _ = CloudRedirect.configure()

        try plistSet(":LSEnvironment:DYLD_INSERT_LIBRARIES", mergedInsertList())
        try configureOnlineFixEnvironment()

        // Sign inner-to-outer so each seal covers the one below.
        try adhocSign(Paths.steamAppInjectedDylib)
        try adhocSign(Paths.steamAppExecutable)
        try adhocSign(Paths.steamApp)

        try writeUpdateBlock()

        registerBundle()
    }

    // MARK: - Update block (steam.cfg)

    static func writeUpdateBlock() throws {
        let body = "BootStrapperInhibitUpdateOnLaunch=enable\n"
        for url in [Paths.steamCfgRoot, Paths.steamCfgInner] {
            do {
                try Paths.ensureDir(url.deletingLastPathComponent())
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                if url == Paths.steamCfgRoot {
                    throw StepFailure(step: "Write steam.cfg", detail: error.localizedDescription)
                }
            }
        }
    }

    static func enableUpdateBlock() throws {
        try writeUpdateBlock()
    }

    static func disableUpdateBlock() throws {
        let fm = FileManager.default
        for url in [Paths.steamCfgRoot, Paths.steamCfgInner] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: - LSEnvironment read

    static func lsEnvironmentInsert() -> String? {
        let out = Subprocess.run("/usr/libexec/PlistBuddy",
                      ["-c", "Print :LSEnvironment:DYLD_INSERT_LIBRARIES", Paths.steamAppInfoPlist.path])
        guard out.code == 0 else { return nil }
        let v = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func insertedLibraries() -> [String] {
        lsEnvironmentInsert()?.split(separator: ":").map(String.init) ?? []
    }

    private static func mergedInsertList() -> String {
        // macSteam's dylib first, then CloudRedirect's runtime, then anything else
        // already in the list (NotProton's dylib, for the combined app).
        // onlinefix.dylib is deliberately not injected: its hook on Steam's launch
        // path did not survive alongside the other dylibs, so OnlineFix routing
        // lives inside macsteam.dylib again.
        let ours = [Paths.steamAppInjectedDylib,
                    Paths.steamAppCloudRedirectDylib]
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        let existing = insertedLibraries().filter {
            !ours.contains($0)
                && $0 != Paths.steamAppOnlineFixDylib.path
                && FileManager.default.fileExists(atPath: $0)
        }
        return (ours + existing).joined(separator: ":")
    }

    // MARK: - Shell primitives

    private static func plistSet(_ keyPath: String, _ value: String) throws {
        let set = Subprocess.run("/usr/libexec/PlistBuddy",
                      ["-c", "Set \(keyPath) \(value)", Paths.steamAppInfoPlist.path])
        if set.code != 0 {
            let add = Subprocess.run("/usr/libexec/PlistBuddy",
                          ["-c", "Add \(keyPath) string \(value)", Paths.steamAppInfoPlist.path])
            if add.code != 0 {
                throw StepFailure(step: "Patch Info.plist", detail: add.stderr.isEmpty ? set.stderr : add.stderr)
            }
        }
    }

    private static func adhocSign(_ url: URL) throws {
        let out = Subprocess.run("/usr/bin/codesign", ["-f", "-s", "-", url.path])
        if out.code != 0 {
            throw StepFailure(step: "Sign \(url.lastPathComponent)", detail: out.stderr)
        }
    }

    private static func registerBundle() {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        _ = Subprocess.run(lsregister, ["-f", Paths.steamApp.path])
    }

    /// OnlineFix's dylib and the per-build profiles it resolves its hooks from.
    /// Bundled by scripts/build-onlinefix.sh; absent in builds that skip it.
    static func bundledOnlineFixDylib() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("onlinefix.dylib")
    }

    private static func onlineFixInjected() -> Bool {
        FileManager.default.fileExists(atPath: Paths.steamAppOnlineFixDylib.path)
            && insertedLibraries().contains(Paths.steamAppOnlineFixDylib.path)
    }

    /// Puts OnlineFix's dylib in Steam.app beside macSteam's. It is a separate
    /// injection, not part of macsteam.dylib: it owns its own hooks, game list and
    /// signature profiles, and can be updated or removed on its own.
    static func deployOnlineFix() throws {
        let fm = FileManager.default
        guard let bundled = bundledOnlineFixDylib(),
              fm.fileExists(atPath: bundled.path) else { return }

        let dest = Paths.steamAppOnlineFixDylib
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: bundled, to: dest)
        try adhocSign(dest)
        try deployOnlineFixProfiles()
    }

    /// The runtime folder the dylib points at with ONLINEFIX_SIG, one JSON per
    /// Steam build it knows.
    private static func deployOnlineFixProfiles() throws {
        let fm = FileManager.default
        guard let resources = Bundle.main.resourceURL else { return }
        let source = resources.appendingPathComponent("runtime", isDirectory: true)
        let profiles = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        guard !profiles.isEmpty else { return }

        try Paths.ensureDir(Paths.onlineFixRuntimeDir)
        for profile in profiles {
            let target = Paths.onlineFixRuntimeDir.appendingPathComponent(profile.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: profile, to: target)
        }
    }

    /// ONLINEFIX_SIG/CONFIG/LOG travel to Steam in LSEnvironment, the same way the
    /// injection list does, so a Finder launch sees them too.
    private static func configureOnlineFixEnvironment() throws {
        guard bundledOnlineFixDylib() != nil else { return }
        try Paths.ensureDir(Paths.onlineFixSupportDir)
        try Paths.ensureDir(Paths.onlineFixRuntimeDir)
        // CONFIG is the routed subset, not the manager's whole list: a game set
        // to keep its real AppID must reach Steam as itself.
        OnlineFixRoutingFile.writeFromManager()
        try plistSet(":LSEnvironment:ONLINEFIX_SIG", Paths.onlineFixRuntimeDir.path)
        try plistSet(":LSEnvironment:ONLINEFIX_CONFIG", Paths.onlineFixRoutingFile.path)
        try plistSet(":LSEnvironment:ONLINEFIX_LOG", Paths.onlineFixLogFile.path)
    }

    // MARK: - Signatures


    private static func deploySignatures() throws {
        guard let bundledSigs = Bundle.main.url(forResource: "signatures", withExtension: nil) else {
            throw StepFailure(step: "Deploy signatures", detail: "Bundled signatures missing from app.")
        }
        let dest = Paths.signaturesDir
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try Paths.ensureDir(dest)
        let enumerator = fm.enumerator(at: bundledSigs, includingPropertiesForKeys: nil)
        while let src = enumerator?.nextObject() as? URL {
            guard src.hasDirectoryPath == false else { continue }
            let rel = src.path.replacingOccurrences(of: bundledSigs.path + "/", with: "")
            let target = dest.appendingPathComponent(rel)
            try Paths.ensureDir(target.deletingLastPathComponent())
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: src, to: target)
        }
    }

    // MARK: - Preflight

    static func ensureModifiable() throws {
        let probe = Paths.steamApp
            .appendingPathComponent("Contents/MacOS/.macsteam-write-probe")
        let fm = FileManager.default
        do {
            try Data().write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
        } catch let e as NSError
            where e.domain == NSCocoaErrorDomain
               && (e.code == NSFileWriteNoPermissionError || e.code == NSFileWriteVolumeReadOnlyError) {
            throw PermissionDenied()
        } catch {
            throw StepFailure(step: "Check Steam.app access", detail: error.localizedDescription)
        }
    }
}
