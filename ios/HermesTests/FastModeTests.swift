import Foundation
import Testing
@testable import Hermes

struct FastModeTests {
    let json = #"""
    {"model":"claude-opus-5-5","provider":"anthropic","providers":[
      {"slug":"anthropic","name":"Anthropic","authenticated":true,"models":["claude-opus-5-5","claude-sonnet-5"],
       "capabilities":{"claude-opus-5-5":{"fast":true,"reasoning":true},"claude-sonnet-5":{"fast":false}}},
      {"slug":"weird","name":"Weird","authenticated":true,"models":["my_model"],"capabilities":{"my_model":{"fast":true}}},
      {"slug":"broken","name":"Broken","authenticated":true,"models":["x"],"capabilities":["not","a","dict"]}
    ]}
    """#

    @Test func knowsWhichModelsHaveFastMode() throws {
        let o = try HermesClient.decoder.decode(ModelOptions.self, from: Data(json.utf8))
        #expect(o.supportsFast(nil))  // gateway default = Opus 5.5
        #expect(!o.supportsFast(ModelChoice(provider: "anthropic", model: "claude-sonnet-5")))
        #expect(o.supportsFast(ModelChoice(provider: "weird", model: "my_model")))
        #expect(!o.supportsFast(ModelChoice(provider: "broken", model: "x")))
        #expect(o.providers.count == 3)
    }

    @Test func runBodyCarriesFastOnlyWhenSet() {
        let off = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: nil)
        #expect(off["model_options"] == nil)
        let on = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: nil, fast: true)
        #expect((on["model_options"] as? [String: Bool])?["fast"] == true)
    }
}
