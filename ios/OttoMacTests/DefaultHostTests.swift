import Foundation
import Testing
@testable import Otto

/// The Tailscale shortcut comes only from the build-time host (Config/Local.xcconfig); no host, no button.
struct DefaultHostTests {
    @Test func tailscaleURLFromHost() {
        #expect(LocalServer.tailscaleURL(host: "my-mac.example.ts.net") == "https://my-mac.example.ts.net:8642")
        #expect(LocalServer.tailscaleURL(host: " my-mac.example.ts.net\n") == "https://my-mac.example.ts.net:8642")
    }

    @Test func noHostMeansNoTailscaleShortcut() {
        #expect(LocalServer.tailscaleURL(host: nil) == nil)
        #expect(LocalServer.tailscaleURL(host: "") == nil)
        #expect(LocalServer.tailscaleURL(host: "  ") == nil)
        #expect(LocalServer.tailscaleURL(host: "$(OTTO_DEFAULT_HOST)") == nil)
    }
}
