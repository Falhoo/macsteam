// Wine loads its own built-in DLL unless the prefix's registry prefers the native
// copy. OnlineFix's proxies (winmm.dll and friends) only run with that override,
// so the app has to write it for every fixed game, not only Photon ones.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct WineOverrideTests {

    private var overrideSection: String {
        "[Software\(String(repeating: "\\", count: 2))Wine"
            + "\(String(repeating: "\\", count: 2))DllOverrides]"
    }

    /// The override goes in the DllOverrides section, right after its header, and
    /// the rest of the registry is left alone.
    @Test
    func theOverrideGoesInItsSection() {
        let bs = String(repeating: "\\", count: 2)
        let reg = "\(overrideSection) 1795075230\n"
            + "#time=1dd77fc0bdebca6\n\n"
            + "[Software\(bs)Wine\(bs)Other] 1\n\"x\"=\"y\"\n"

        #expect(WineOverride.line(for: "winmm.dll", in: reg) == nil)

        let updated = WineOverride.adding(dll: "winmm.dll", to: reg)
        #expect(updated.contains("\"winmm.dll\"=\"native,builtin\""))
        #expect(WineOverride.line(for: "winmm.dll", in: updated)
            == "\"winmm.dll\"=\"native,builtin\"")
        #expect(updated.contains("[Software\(bs)Wine\(bs)Other]"))
        #expect(updated.contains("\"x\"=\"y\""))
    }

    /// A prefix Wine has not written a DllOverrides section into yet gets one.
    @Test
    func theOverrideCreatesItsSection() {
        let bs = String(repeating: "\\", count: 2)
        let reg = "[Software\(bs)Wine\(bs)Other] 1\n\"x\"=\"y\"\n"
        let updated = WineOverride.adding(dll: "version.dll", to: reg)
        #expect(updated.contains(overrideSection))
        #expect(WineOverride.line(for: "version.dll", in: updated)
            == "\"version.dll\"=\"native,builtin\"")
    }

    /// A value Wine wrote itself ("native,builtin" with no space, or the name
    /// without ".dll") counts as present.
    @Test
    func aWrittenOverrideIsReadBack() {
        for line in ["\"winmm\"=\"native,builtin\"", "\"winmm.dll\"=\"native\""] {
            let reg = "\(overrideSection)\n\(line)\n"
            #expect(WineOverride.line(for: "winmm.dll", in: reg) == line)
        }
    }

    /// One override does not answer for another DLL.
    @Test
    func overridesArePerDLL() {
        let reg = WineOverride.adding(dll: "winmm.dll", to: "")
        #expect(WineOverride.line(for: "winhttp.dll", in: reg) == nil)
        let both = WineOverride.adding(dll: "winhttp.dll", to: reg)
        #expect(WineOverride.line(for: "winmm.dll", in: both) != nil)
        #expect(WineOverride.line(for: "winhttp.dll", in: both) != nil)
    }

    /// The four proxies OnlineFix and BepInEx ship.
    @Test
    func theProxiesAreTheKnownLoaders() {
        #expect(WineOverride.proxies == ["winmm.dll", "winhttp.dll", "version.dll", "dinput8.dll"])
    }

    /// "Failed to get OnlineFix interface" comes from the loader being handed a
    /// copy of the emulator that is not the game folder's. Its DLLs are overridden
    /// native only, and every fixed game gets the whole set.
    @Test
    func theEmulatorsAreOverriddenNativeOnly() {
        #expect(WineOverride.fixDLLs.contains("onlinefix64.dll"))
        #expect(WineOverride.needsNative("onlinefix64.dll"))
        #expect(WineOverride.needsNative("steam_api64.dll"))
        #expect(!WineOverride.needsNative("winmm.dll"))

        let reg = WineOverride.adding(dll: "onlinefix64.dll", to: "", native: true)
        #expect(WineOverride.line(for: "onlinefix64.dll", in: reg)
            == "\"onlinefix64.dll\"=\"native\"")
        let plain = WineOverride.adding(dll: "winmm.dll", to: "")
        #expect(WineOverride.line(for: "winmm.dll", in: plain)
            == "\"winmm.dll\"=\"native,builtin\"")
    }
}
