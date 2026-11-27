import Foundation
import Testing
@testable import OnlineFixApp

/// The client's own log is the only place a licence is recorded, and a ticket is
/// worthless without one, so reading it has to be exact.
@Suite struct PhotonOwnershipTests {
    private let log = """
        17:08:30 [macsteam] INF CheckAppOwnership: SPOOFING appid 3241660 (orig=0, acctId=0)
        17:08:31 [macsteam] INF CheckAppOwnership: SPOOFING appid 480 (orig=1, acctId=7)
        """

    @Test func spoofedMeansNoLicence() {
        #expect(PhotonLog.ownership(inClientLog: log, appID: 3241660) == false)
    }

    @Test func aLicenceIsOwnership() {
        #expect(PhotonLog.ownership(inClientLog: log, appID: 480) == true)
    }

    @Test func unmentionedIsUnknown() {
        // An app the client never spoofed was owned: the hook only logs a spoof.
        #expect(PhotonLog.ownership(inClientLog: log, appID: 4001890) == nil)
    }

    @Test func theLatestWordWins() {
        // A licence bought while the client runs must not be overruled by the older
        // line, and the longer AppID must not match a shorter one's prefix.
        let later = log + "\n17:09:00 [macsteam] INF CheckAppOwnership: SPOOFING appid 3241660 (orig=1, acctId=7)"
        #expect(PhotonLog.ownership(inClientLog: later, appID: 3241660) == true)
        #expect(PhotonLog.ownership(inClientLog: later, appID: 324166) == nil)
    }
}
