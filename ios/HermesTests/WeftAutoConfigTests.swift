import Foundation
import Testing
@testable import Hermes

/// Weft auto-config (WeftAutoConfig.swift, relay/weft_config.py): decode, precedence, strip states.
@Suite struct WeftAutoConfigTests {
    let gateway = URL(string: "https://weft-gateway-preview.elier.ai")!

    @Test func decodesTheRelayResponse() throws {
        let json = #"{"url": "https://weft-gateway-preview.elier.ai", "token": "wft_x", "scope": "human", "principal": "john", "source": "hermes-host"}"#
        let c = try HermesClient.decoder.decode(WeftAutoConfig.self, from: Data(json.utf8))
        #expect(c == WeftAutoConfig(url: "https://weft-gateway-preview.elier.ai", token: "wft_x", scope: "human", principal: "john"))
        let observer = #"{"url": "https://weft.example", "token": "o", "scope": "observe", "principal": null}"#
        #expect(try HermesClient.decoder.decode(WeftAutoConfig.self, from: Data(observer.utf8)).principal == nil)
    }

    @Test func legacyKeychainItemsDecodeWithoutSource() throws {
        // Saved before auto-config: {baseURL, token} only.
        let old = try JSONEncoder().encode(["baseURL": gateway.absoluteString, "token": "t"])
        let c = try JSONDecoder().decode(WeftConfig.self, from: old)
        #expect(c.source == nil && c.scope == nil && c.token == "t" && !c.isAuto)
        let auto = WeftConfig(baseURL: gateway, token: "t", source: .auto, scope: "human")
        #expect(try JSONDecoder().decode(WeftConfig.self, from: JSONEncoder().encode(auto)) == auto)
    }

    @Test func manualConfigWinsOverAuto() {
        let offered = WeftAutoConfig(url: gateway.absoluteString, token: "auto", scope: "human", principal: "john")
        let manual = WeftConfig(baseURL: URL(string: "https://other.example")!, token: "typed", source: .manual)
        #expect(WeftAutoConfig.resolve(current: manual, offered: offered) == nil)
    }

    @Test func autoFillsAnEmptyKeychainAndFollowsTheHost() {
        let offered = WeftAutoConfig(url: gateway.absoluteString + "/", token: "auto", scope: "human", principal: "john")
        let saved = WeftAutoConfig.resolve(current: nil, offered: offered)
        #expect(saved == WeftConfig(baseURL: gateway, token: "auto", source: .auto, scope: "human"))
        // Same again: nothing to write.
        #expect(WeftAutoConfig.resolve(current: saved, offered: offered) == nil)
        // The host renewed the token: follow it.
        var renewed = offered
        renewed.token = "auto2"
        #expect(WeftAutoConfig.resolve(current: saved, offered: renewed)?.token == "auto2")
        // A legacy item (no source) is replaced by the host's.
        let legacy = WeftConfig(baseURL: gateway, token: "old", source: nil)
        #expect(WeftAutoConfig.resolve(current: legacy, offered: offered)?.source == .auto)
        // Garbage from the host never overwrites anything.
        #expect(WeftAutoConfig.resolve(current: nil, offered: WeftAutoConfig(url: "not a url", token: "x", scope: "human")) == nil)
        #expect(WeftAutoConfig.resolve(current: nil, offered: WeftAutoConfig(url: gateway.absoluteString, token: "", scope: "human")) == nil)
    }

    @Test func failuresNameTheReason() {
        #expect(WeftAutoFailure.from(URLError(.cannotConnectToHost)) == .hostUnreachable)
        #expect(WeftAutoFailure.from(URLError(.timedOut)) == .hostUnreachable)
        #expect(WeftAutoFailure.from(HermesError.http(503, "no Weft token on this Mac")) == .noToken)
        #expect(WeftAutoFailure.from(HermesError.http(502, "can't reach")) == .gatewayUnreachable)
        #expect(WeftAutoFailure.from(CompanionError.relayOutdated) == .relayOutdated)
        #expect(WeftAutoFailure.hostUnreachable.message == "Can't reach your Hermes host.")
        #expect(WeftAutoFailure.noToken.message == "Your Hermes host has no Weft token.")
    }

    @Test func stripStates() {
        let known: Set<String> = ["hermes-ios", "weft"]
        // Configured, repo on the gateway.
        #expect(WeftStripState.make(configured: true, auto: .ok(scope: "human"), repo: "hermes-ios",
                                    knownRepos: known, hasEvents: false) == .ready(repo: "hermes-ios"))
        // Repos not loaded yet: show the feed, not a false "not tracking".
        #expect(WeftStripState.make(configured: true, auto: .idle, repo: "potluck",
                                    knownRepos: nil, hasEvents: false) == .ready(repo: "potluck"))
        // Repo missing on the gateway: one quiet line, no connect prompt.
        #expect(WeftStripState.make(configured: true, auto: .ok(scope: "human"), repo: "potluck",
                                    knownRepos: known, hasEvents: false) == .notTracked(repo: "potluck"))
        // Records already held win over a stale repo list.
        #expect(WeftStripState.make(configured: true, auto: .ok(scope: "human"), repo: "potluck",
                                    knownRepos: known, hasEvents: true) == .ready(repo: "potluck"))
        // Host unreachable: Connect, with the reason.
        #expect(WeftStripState.make(configured: false, auto: .failed(.hostUnreachable), repo: "hermes-ios",
                                    knownRepos: nil, hasEvents: false) == .connect(reason: "Can't reach your Hermes host."))
        #expect(WeftStripState.make(configured: false, auto: .failed(.noToken), repo: "hermes-ios",
                                    knownRepos: nil, hasEvents: false) == .connect(reason: "Your Hermes host has no Weft token."))
        // Still asking: no prompt.
        #expect(WeftStripState.make(configured: false, auto: .fetching, repo: "hermes-ios",
                                    knownRepos: nil, hasEvents: false) == .connecting)
        #expect(WeftStripState.make(configured: false, auto: .idle, repo: "hermes-ios",
                                    knownRepos: nil, hasEvents: false) == .connecting)
        // A manual config that works ignores auto failures.
        #expect(WeftStripState.make(configured: true, auto: .failed(.hostUnreachable), repo: "hermes-ios",
                                    knownRepos: known, hasEvents: false) == .ready(repo: "hermes-ios"))
        #expect(WeftStripState.make(configured: true, auto: .idle, repo: nil, knownRepos: known, hasEvents: false) == .noFolder)
    }
}
