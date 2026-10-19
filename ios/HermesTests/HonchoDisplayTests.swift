import Foundation
import Testing
@testable import Hermes

struct HonchoDisplayTests {
    @Test func capitalisesPeerName() {
        #expect(HonchoState.display("sam's sister is Alex Rivera.", peer: "sam") == "Sam's sister is Alex Rivera.")
        #expect(HonchoState.display("prefers johnny cakes; john agrees", peer: "john") == "Prefers johnny cakes; John agrees")
    }

    @Test func decodesRelayPayload() throws {
        let json = #"{"enabled":true,"peers":["john"],"peer":"john","card":[],"conclusions":[{"ids":["a","b"],"content":"john prefers cortados.","level":"deductive","created_at":"2026-10-06T04:32:44.239949Z"}]}"#
        let s = try HermesClient.decoder.decode(HonchoState.self, from: Data(json.utf8))
        #expect(s.conclusions.first?.ids == ["a", "b"])
        #expect(s.conclusions.first?.inferred == true)
        #expect(s.conclusions.first?.date != nil)
    }
}
