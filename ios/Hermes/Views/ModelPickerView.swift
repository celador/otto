import SwiftUI

/// Picks a provider/model for a chat from `GET /api/model/options`.
struct ModelPickerView: View {
    @Binding var selection: ModelChoice?
    /// Off for an agent's own model, where "Gateway default" has no meaning.
    var allowDefault = true
    var title = "Model"
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if allowDefault { Section {
                    Button {
                        selection = nil
                        dismiss()
                    } label: {
                        row(title: "Gateway default",
                            subtitle: defaultLabel,
                            selected: selection == nil)
                    }
                } }
                if let options = app.modelOptions {
                    let picker = picker(options)
                    if !picker.favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(picker.favorites, id: \.provider.slug) { group in
                                familyRows(group, showProvider: picker.favorites.count > 1)
                            }
                        }
                    }
                    ForEach(picker.groups, id: \.provider.slug) { group in
                        Section(group.provider.name) { familyRows(group, showProvider: false) }
                    }
                    // Mixture-of-Agents presets: their own section, after the catalog (as on the desktop).
                    if let moa = options.usable.first(where: { $0.slug.lowercased() == "moa" }) {
                        let presets = filtered(moa.models ?? [])
                        if !presets.isEmpty {
                            Section(moa.name) {
                                ForEach(presets, id: \.self) { model in
                                    let choice = ModelChoice(provider: moa.slug, model: model)
                                    Button {
                                        selection = choice
                                        dismiss()
                                    } label: {
                                        row(title: model, subtitle: nil, selected: selection == choice)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await app.loadModelOptions() }
            .refreshable { await app.loadModelOptions(force: true) }
        }
    }

    /// Same rows as the desktop's model menu: its Edit Models shortlist, favorites and custom models.
    private func picker(_ options: ModelOptions) -> ModelCatalog.Picker {
        let providers = options.usable
            .filter { $0.slug.lowercased() != "moa" }
            .map { ModelCatalog.Provider(slug: $0.slug, name: $0.name, models: $0.models ?? [],
                                         featured: $0.featuredModels ?? []) }
        return ModelCatalog.picker(providers: providers, visibility: app.modelVisibility,
                                   current: selection, search: search)
    }

    @ViewBuilder
    private func familyRows(_ group: ModelCatalog.Group, showProvider: Bool) -> some View {
        ForEach(group.families, id: \.self) { family in
            let choice = ModelChoice(provider: group.provider.slug, model: family.id)
            let selected = selection?.provider == group.provider.slug
                && (selection?.model == family.id || selection?.model == family.fastId)
            Button {
                selection = choice
                dismiss()
            } label: {
                row(title: family.id, subtitle: showProvider ? group.provider.name : nil, selected: selected)
            }
        }
    }

    private var defaultLabel: String? {
        guard let o = app.modelOptions, let model = o.model else { return nil }
        return [o.provider, model].compactMap { $0 }.joined(separator: " · ")
    }

    private func filtered(_ models: [String]) -> [String] {
        let q = search.trimmed.lowercased()
        return q.isEmpty ? models : models.filter { $0.lowercased().contains(q) }
    }

    private func row(title: String, subtitle: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
    }
}
