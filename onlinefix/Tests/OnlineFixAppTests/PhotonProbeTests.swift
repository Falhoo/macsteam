import Foundation
import Testing
@testable import OnlineFixApp

/// Photon's own reachability, which the report needs to tell "the patch is wrong"
/// apart from "nothing gets out of this Mac".
@Suite struct PhotonProbeTests {

    @Test func theEndpointsAreTheOnesPhotonUses() {
        let names = PhotonProbe.endpoints.map(\.name)
        #expect(names.contains("nameserver"))
        #expect(PhotonProbe.endpoints.allSatisfy { !$0.host.isEmpty && $0.port > 0 })
    }

    @Test func aPingSaysItIsUpOrDown() throws {
        let pings = PhotonProbe.ping(timeout: 3)
        #expect(pings.count == PhotonProbe.endpoints.count)
        for ping in pings {
            // Either it opened in some number of milliseconds, or it did not open.
            if let ms = ping.milliseconds { #expect(ms >= 0) } else { #expect(!ping.isUp) }
        }
        // The summary never claims reachability it did not measure.
        let summary = PhotonProbe.summary(pings)
        if pings.allSatisfy({ !$0.isUp }) {
            #expect(summary.contains("not reachable"))
        } else {
            #expect(summary.contains("Photon answers"))
        }
    }
}
