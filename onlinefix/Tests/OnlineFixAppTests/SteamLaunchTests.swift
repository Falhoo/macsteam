import XCTest
@testable import OnlineFixApp

final class SteamLaunchTests: XCTestCase {

    /// A launch goes through the patched /Applications bundle, never through
    /// Steam.AppBundle's own executable: the latter has no Info.plist environment
    /// and starts an unpatched second client with no licences.
    func testBundleIsThePatchedSteamApp() {
        XCTAssertEqual(SteamLaunch.bundle.path, "/Applications/Steam.app")
        XCTAssertFalse(SteamLaunch.bundle.path.contains("Steam.AppBundle"))
        XCTAssertTrue(SteamLaunch.unpatchedClient.path.contains("Steam.AppBundle"))
    }

    func testRunURL() {
        XCTAssertEqual(SteamLaunch.url(appID: 3241660).absoluteString,
                       "steam://run/3241660")
    }
}