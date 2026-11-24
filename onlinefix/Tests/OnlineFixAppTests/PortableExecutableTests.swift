import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct PortableExecutableTests {

    private var vendor: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OnlineFixAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // onlinefix
            .appendingPathComponent("vendor/photon", isDirectory: true)
    }

    /// The bundled winmm proxy is a real x64 DLL that exports OnlineFix. This is
    /// the file the audit looks for when it decides whether a package DLL is a
    /// doorway or just a library.
    @Test
    func aRealProxyIsReadAsAnX64Doorway() throws {
        let url = vendor.appendingPathComponent("winmm.dll")
        let pe = try #require(PortableExecutable.read(url))
        #expect(pe.architecture == .x64)
        #expect(pe.is64BitNative)
        #expect(!pe.is32BitNative)
        #expect(pe.isDLL)
        #expect(!pe.isManaged)
        #expect(pe.exportsOnlineFix)
        #expect(pe.imports.contains("kernel32.dll"))
    }

    /// BepInEx and the OnlineFix plugin are managed assemblies. The parser has to
    /// call them managed so the audit does not compare their headers to the game's
    /// bitness.
    @Test
    func managedAssembliesAreNotNative() throws {
        for relative in ["Custom.dll", "BepInEx/core/BepInEx.Preloader.dll"] {
            let pe = try #require(PortableExecutable.read(vendor.appendingPathComponent(relative)))
            #expect(pe.isManaged)
            #expect(!pe.is64BitNative)
            #expect(!pe.is32BitNative)
            #expect(pe.architecture == .anyCPU || pe.architecture == .x86)
        }
    }

    /// A byte blob that only starts with MZ is not a PE. The fallback may still
    /// find a name in it, but the parser itself must refuse it.
    @Test
    func aMalformedHeaderIsRefused() {
        #expect(PortableExecutable.read(Data("MZ...".utf8)) == nil)
        #expect(PortableExecutable.read(Data()) == nil)
    }
}
