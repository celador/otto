import Foundation

/// The desktop app's model shortlist (Edit Models, favorites, custom models) as stored in its
/// localStorage, served by the relay at `GET /hermes/model-visibility`.
struct DesktopModelVisibility: Codable, Sendable, Equatable {
    struct Custom: Codable, Sendable, Equatable { let provider: String; let model: String }
    var available: Bool
    /// `provider::model` keys, nil = never customized (desktop defaults apply).
    var visible: [String]?
    var known: [String]?
    var favorites: [String]
    var custom: [Custom]

    enum CodingKeys: String, CodingKey { case available, visible, known, favorites, custom }

    init(available: Bool = true, visible: [String]? = nil, known: [String]? = nil,
         favorites: [String] = [], custom: [Custom] = []) {
        self.available = available
        self.visible = visible
        self.known = known
        self.favorites = favorites
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        visible = try? c.decodeIfPresent([String].self, forKey: .visible)
        known = try? c.decodeIfPresent([String].self, forKey: .known)
        favorites = (try? c.decodeIfPresent([String].self, forKey: .favorites)) ?? []
        custom = (try? c.decodeIfPresent([Custom].self, forKey: .custom)) ?? []
    }

    private static let defaultsKey = "hermes.desktopModelVisibility"

    static var saved: DesktopModelVisibility? {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() {
        guard available, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// Builds the model picker the way the Hermes desktop app's model menu does
/// (`apps/desktop/src/store/model-visibility.ts` + `groupModels` in `model-catalog-menu.tsx`),
/// so the phone offers exactly the models John chose under Edit Models on the desktop.
enum ModelCatalog {
    struct Provider: Equatable, Sendable {
        var slug: String
        var name: String
        var models: [String]
        var featured: [String] = []
    }

    /// A model and its optional `…-fast` sibling, shown as one row.
    struct Family: Equatable, Sendable, Hashable {
        var id: String
        var fastId: String?
    }

    struct Group: Equatable, Sendable {
        var provider: Provider
        var families: [Family]
    }

    struct Picker: Equatable, Sendable {
        var favorites: [Group]
        var groups: [Group]
    }

    nonisolated static let defaultVisiblePerProvider = 50

    nonisolated static func key(_ provider: String, _ model: String) -> String { "\(provider)::\(model)" }

    nonisolated static func isSentinel(_ key: String) -> Bool { key.hasSuffix("::") }

    /// Base + `-fast` collapse into one family; a date-pinned snapshot with a rolling alias is dropped.
    nonisolated static func collapse(_ models: [String]) -> [Family] {
        let present = Set(models)
        var consumed = Set<String>()
        var out: [Family] = []
        for m in models where !consumed.contains(m) {
            if m.lowercased().hasSuffix("-fast"), present.contains(String(m.dropLast(5))) { continue }
            if let base = dateStripped(m), present.contains(base) { continue }
            let fast = m + "-fast"
            let hasFast = present.contains(fast)
            out.append(Family(id: m, fastId: hasFast ? fast : nil))
            consumed.insert(m)
            if hasFast { consumed.insert(fast) }
        }
        return out
    }

    private nonisolated static func dateStripped(_ m: String) -> String? {
        guard m.count > 9 else { return nil }
        let tail = m.suffix(9)
        guard tail.first == "-", tail.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(m.dropLast(9))
    }

    nonisolated static func withCustom(_ providers: [Provider], _ custom: [DesktopModelVisibility.Custom]) -> [Provider] {
        providers.map { p in
            var p = p
            for c in custom where c.provider == p.slug && !p.models.contains(c.model) { p.models.append(c.model) }
            return p
        }
    }

    private nonisolated static func addDefaults(_ p: Provider, into target: inout Set<String>,
                                                admit: (String) -> Bool = { _ in true }) {
        let families = collapse(p.models)
        let defaults = p.featured.isEmpty
            ? Array(families.prefix(defaultVisiblePerProvider))
            : families.filter { p.featured.contains($0.id) }
        for f in defaults {
            let k = key(p.slug, f.id)
            if admit(k) { target.insert(k) }
        }
    }

    /// `effectiveVisibleKeys`: stored keys + desktop defaults for providers never curated, plus
    /// models that appeared after the last curation (absent from `known`); sentinels stripped.
    nonisolated static func effectiveKeys(stored: [String]?, known: [String]?, providers: [Provider]) -> Set<String> {
        var next = Set<String>()
        if let stored {
            guard !stored.isEmpty else { return [] }
            next = Set(stored)
            let knownSet = known.map { Set($0) }
            for p in providers {
                if next.contains(key(p.slug, "")) { continue }
                let prefix = p.slug + "::"
                let curated = stored.contains { $0.hasPrefix(prefix) && !isSentinel($0) }
                if !curated {
                    addDefaults(p, into: &next)
                } else if let knownSet {
                    addDefaults(p, into: &next) { !knownSet.contains($0) }
                }
            }
        } else {
            for p in providers { addDefaults(p, into: &next) }
        }
        return next.filter { !isSentinel($0) }
    }

    /// The picker: a Favorites section (starred order, ignores the shortlist) and provider groups
    /// sorted by name, each showing only shortlisted families plus the chat's current model.
    /// A search spans every family and turns Favorites off, as on the desktop.
    nonisolated static func picker(providers raw: [Provider], visibility: DesktopModelVisibility?,
                                   current: ModelChoice?, search: String) -> Picker {
        let vis = visibility?.available == true ? visibility : nil
        let providers = withCustom(raw, vis?.custom ?? [])
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shownKeys = effectiveKeys(stored: vis?.visible, known: vis?.known, providers: providers)

        var favorites: [Group] = []
        let favoriteKeys = q.isEmpty ? (vis?.favorites ?? []) : []
        if !favoriteKeys.isEmpty {
            var byKey: [String: (Provider, Family)] = [:]
            for p in providers { for f in collapse(p.models) { byKey[key(p.slug, f.id)] = (p, f) } }
            for k in favoriteKeys {
                guard let (p, f) = byKey[k] else { continue }
                if let i = favorites.firstIndex(where: { $0.provider.slug == p.slug }) {
                    favorites[i].families.append(f)
                } else {
                    favorites.append(Group(provider: p, families: [f]))
                }
            }
        }
        let favoriteSet = Set(favoriteKeys)

        var groups: [Group] = []
        for p in providers {
            let all = collapse(p.models)
            guard !all.isEmpty else { continue }
            let activeId = q.isEmpty && current?.provider == p.slug
                ? all.first(where: { $0.id == current?.model || $0.fastId == current?.model })?.id : nil
            let families = all.filter { f in
                let shown: Bool
                if !q.isEmpty {
                    shown = "\(f.id) \(f.fastId ?? "") \(p.name) \(p.slug)".lowercased().contains(q)
                } else {
                    shown = shownKeys.contains(key(p.slug, f.id))
                }
                return (shown || f.id == activeId) && !favoriteSet.contains(key(p.slug, f.id))
            }
            if !families.isEmpty { groups.append(Group(provider: p, families: families)) }
        }
        groups.sort { $0.provider.name.localizedCompare($1.provider.name) == .orderedAscending }
        return Picker(favorites: favorites, groups: groups)
    }
}
