import Testing
@testable import Hermes

/// Mirrors the desktop's model-visibility rules (apps/desktop/src/store/model-visibility.ts).
struct ModelCatalogTests {
    typealias P = ModelCatalog.Provider

    @Test func collapsesFastAndDatePinned() {
        let f = ModelCatalog.collapse(["claude-opus-5", "claude-opus-5-fast", "claude-haiku-4-5",
                                       "claude-haiku-4-5-20251001", "solo-fast"])
        #expect(f == [.init(id: "claude-opus-5", fastId: "claude-opus-5-fast"),
                      .init(id: "claude-haiku-4-5", fastId: nil),
                      .init(id: "solo-fast", fastId: nil)])
    }

    @Test func showsExactlyTheCuratedShortlist() {
        let providers = [P(slug: "anthropic", name: "Anthropic", models: ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5"]),
                         P(slug: "nous", name: "Nous Portal", models: ["a/x", "b/y"])]
        let vis = DesktopModelVisibility(visible: ["anthropic::claude-opus-5-5", "nous::"],
                                         known: ["anthropic::claude-opus-5-5", "anthropic::claude-opus-5",
                                                 "anthropic::claude-sonnet-5", "nous::a/x", "nous::b/y"])
        let p = ModelCatalog.picker(providers: providers, visibility: vis, current: nil, search: "")
        #expect(p.groups.map(\.provider.slug) == ["anthropic"])  // provider hidden outright on the desktop
        #expect(p.groups[0].families.map(\.id) == ["claude-opus-5-5"])
    }

    @Test func newModelsAndUncuratedProvidersFollowDefaults() {
        let providers = [P(slug: "anthropic", name: "Anthropic", models: ["claude-opus-6", "claude-opus-5-5", "claude-opus-5"]),
                         P(slug: "openrouter", name: "OpenRouter", models: ["x/a", "y/b", "z/c"], featured: ["y/b"])]
        let vis = DesktopModelVisibility(visible: ["anthropic::claude-opus-5-5"],
                                         known: ["anthropic::claude-opus-5-5", "anthropic::claude-opus-5"])
        let p = ModelCatalog.picker(providers: providers, visibility: vis, current: nil, search: "")
        #expect(p.groups[0].families.map(\.id) == ["claude-opus-6", "claude-opus-5-5"])  // 6 arrived later
        #expect(p.groups[1].families.map(\.id) == ["y/b"])  // featured shortlist
    }

    @Test func keepsCurrentChoiceFavoritesAndSearch() {
        let providers = [P(slug: "openai-codex", name: "ChatGPT", models: ["gpt-6-sol", "gpt-6-luna", "gpt-5.5"]),
                         P(slug: "anthropic", name: "Anthropic", models: ["claude-opus-5-5"])]
        let vis = DesktopModelVisibility(visible: ["openai-codex::gpt-6-sol", "anthropic::claude-opus-5-5"],
                                         known: nil, favorites: ["anthropic::claude-opus-5-5"],
                                         custom: [.init(provider: "openai-codex", model: "gpt-7")])
        let current = ModelChoice(provider: "openai-codex", model: "gpt-5.5")
        let p = ModelCatalog.picker(providers: providers, visibility: vis, current: current, search: "")
        #expect(p.favorites.map { $0.families.map(\.id) } == [["claude-opus-5-5"]])
        #expect(p.groups.map(\.provider.slug) == ["openai-codex"])  // Anthropic's only row is a favorite
        #expect(p.groups[0].families.map(\.id) == ["gpt-6-sol", "gpt-5.5"])

        let s = ModelCatalog.picker(providers: providers, visibility: vis, current: current, search: "gpt-")
        #expect(s.favorites.isEmpty)
        #expect(s.groups[0].families.map(\.id) == ["gpt-6-sol", "gpt-6-luna", "gpt-5.5", "gpt-7"])
    }

    @Test func noDesktopDataUsesDesktopDefaults() {
        let models = (0..<60).map { "m\($0)" }
        let p = ModelCatalog.picker(providers: [P(slug: "x", name: "X", models: models)],
                                    visibility: nil, current: nil, search: "")
        #expect(p.groups[0].families.count == 50)
    }
}
