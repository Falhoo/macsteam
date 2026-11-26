import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct LaunchTestTests {

    @Test
    func missingFixFilesHaveASafeRepair() {
        #expect(LaunchTest.classify("err:module:import_dll Library OnlineFix64.dll not found") == .missingDLL)
        #expect(LaunchTest.classify("Failed to get OnlineFix interface") == .onlineFixInterface)
        #expect(LaunchTest.classify("Application load error 3:0000065432") == .drmStub)
        #expect(LaunchTest.classify("failed to load steamoverlay64.dll, error code: 126") == .overlay)
        #expect(LaunchTest.classify("Failed to load \u{201c} from the list") == .dllList)
        #expect(LaunchTest.classify("UnityCrashHandler64.exe started") == .crashHandler)
    }

    @Test
    func baseGameFailuresAreNotRepairable() {
        #expect(LaunchTest.classify("Unhandled exception at 0x1234") == .gameCrash)
        #expect(LaunchTest.classify("0xc000007b") == .wrongBitness)
        #expect(LaunchTest.classify("err:module:import_dll Library msvcp140.dll not found") == .missingRuntime)
        #expect(!LaunchTest.Issue.gameCrash.repairable)
        #expect(!LaunchTest.Issue.wrongBitness.repairable)
        #expect(!LaunchTest.Issue.missingRuntime.repairable)
        #expect(LaunchTest.Issue.overlay.repairable)
    }

    @Test
    func benignWineNoiseIsNotAFailure() {
        #expect(LaunchTest.classify("err:cxcompatdb:verify_file invalid signature") == .none)
        #expect(LaunchTest.classify("err:kerberos:no Kerberos support") == .none)
        #expect(LaunchTest.classify("") == .none)
    }

    @Test
    func aStableWindowIsReportedAsOpened() {
        let result = LaunchTest.Result(
            appID: 1, name: "Game", at: Date(), outcome: .launched,
            windowSeconds: 18, runtimeSeconds: 38, exitStatus: nil, issue: .none,
            issueDetail: "", evidence: [], logPaths: [], repairs: [],
            online: LaunchTest.OnlineEvidence(hookActive: true, matchmaking: true,
                                              photonFailure: nil, line: "launch"))
        #expect(result.opened)
        #expect(result.message.contains("18 seconds"))
        #expect(result.message.contains("Spacewar (480) confirmed"))
        #expect(result.message.contains("Live online play is not confirmed"))
    }

    @Test
    func keepRealAppIDIsNotReportedAsSpacewar() {
        let result = LaunchTest.Result(
            appID: 1, name: "Game", at: Date(), outcome: .launched,
            windowSeconds: 18, runtimeSeconds: 38, exitStatus: nil, issue: .none,
            issueDetail: "", evidence: [], logPaths: [], repairs: [],
            online: LaunchTest.OnlineEvidence(hookActive: true, matchmaking: true,
                                              photonFailure: nil,
                                              line: "launch game=1 session=480 keep-id=1"))
        #expect(!result.message.contains("Spacewar (480) confirmed"))
        #expect(result.message.contains("keeps its own AppID"))
    }

    @Test
    func oldRecipesWithoutATestStillDecode() throws {
        let recipe = FixRecipe(appID: 1, name: "Game", installedAt: Date(), packageName: "p",
                               findings: [], entries: [], removed: [], keepRealAppID: false,
                               photonSwap: false, picoPark2: false, wineDLLs: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recipe)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "launchTest")
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FixRecipe.self, from: older)
        #expect(decoded.launchTest == nil)
    }

    @Test
    func aTestResultSurvivesTheRecipe() throws {
        let result = LaunchTest.Result(
            appID: 2, name: "Game", at: Date(), outcome: .failed,
            windowSeconds: nil, runtimeSeconds: 120, exitStatus: 1, issue: .drmStub,
            issueDetail: "Application load error", evidence: ["line"], logPaths: ["/tmp/log"],
            repairs: ["Restored StubDRM64.dll"],
            online: LaunchTest.OnlineEvidence(hookActive: false, matchmaking: false,
                                              photonFailure: nil, line: nil))
        var recipe = FixRecipe(appID: 2, name: "Game", installedAt: Date(), packageName: "p",
                               findings: [], entries: [], removed: [], keepRealAppID: false,
                               photonSwap: false, picoPark2: false, wineDLLs: [])
        recipe.launchTest = result
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FixRecipe.self, from: encoder.encode(recipe))
        #expect(decoded.launchTest?.issue == .drmStub)
        #expect(decoded.launchTest?.outcome == .failed)
    }
}
