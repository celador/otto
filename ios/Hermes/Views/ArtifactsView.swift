import ImageIO
import QuickLook
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One item on the Artifacts page: same records as the desktop app
/// (relay `GET /hermes/artifacts`, indexed from the 30 most recent sessions).
struct Artifact: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case image, file, link }

    let id: String
    let kind: Kind
    let value: String
    let label: String
    let sessionId: String
    let profile: String?
    let sessionTitle: String
    let timestamp: Double
    let exists: Bool?
    let size: Int?

    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var isRemote: Bool { value.hasPrefix("http://") || value.hasPrefix("https://") }
    /// A local file on the Mac that's gone (deleted or moved since the chat).
    var isMissing: Bool { !isRemote && exists == false }
    var isDefaultProfile: Bool { (profile ?? "default") == "default" }

    /// Folder for files, host + path for links.
    var location: String {
        if isRemote, let u = URL(string: value) {
            let path = u.path == "/" ? "" : u.path
            return (u.host ?? value) + path
        }
        let folder = (value as NSString).deletingLastPathComponent
        return folder.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }
}

struct ArtifactsResponse: Codable, Sendable {
    let artifacts: [Artifact]
    let sessionsFailed: Int?
}

extension CompanionClient {
    func artifacts(refresh: Bool = false) async throws -> ArtifactsResponse {
        let data = try await rawRequest("GET", "/hermes/artifacts", query: refresh ? ["refresh": "1"] : [:])
        return try HermesClient.decoder.decode(ArtifactsResponse.self, from: data)
    }

    /// Bytes of a file on the Mac (only files in the artifacts index are served).
    func artifactFile(_ value: String) async throws -> Data {
        try await rawRequest("GET", "/hermes/artifacts/file", query: ["value": value])
    }
}

/// Pure filtering/counting, kept off the View so it's testable.
enum ArtifactFilter: String, CaseIterable, Sendable {
    case all = "All", image = "Images", file = "Files", link = "Links"

    func matches(_ a: Artifact) -> Bool {
        switch self {
        case .all: true
        case .image: a.kind == .image
        case .file: a.kind == .file
        case .link: a.kind == .link
        }
    }

    nonisolated static func visible(_ items: [Artifact], filter: ArtifactFilter, query: String) -> [Artifact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { a in
            filter.matches(a) && (q.isEmpty || a.label.lowercased().contains(q)
                                  || a.value.lowercased().contains(q) || a.sessionTitle.lowercased().contains(q))
        }
    }
}

/// Thumbnails and full images: http(s) directly, Mac files through the relay. Downscaled with ImageIO.
actor ArtifactImages {
    static let shared = ArtifactImages()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(_ a: Artifact, maxPixel: Int, client: CompanionClient?) async -> UIImage? {
        let key = "\(maxPixel):\(a.value)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let t = inFlight[key as String] { return await t.value }
        let task = Task<UIImage?, Never> {
            let data: Data?
            if a.isRemote, let url = URL(string: a.value) {
                data = try? await URLSession.shared.data(from: url).0
            } else {
                data = try? await client?.artifactFile(a.value)
            }
            guard let data else { return nil }
            return Self.downscale(data, maxPixel: maxPixel)
        }
        inFlight[key as String] = task
        let img = await task.value
        inFlight[key as String] = nil
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    nonisolated static func downscale(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

struct ArtifactsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let onOpenChat: (String, String) -> Void

    @State private var items: [Artifact] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var note: String?
    @State private var filter: ArtifactFilter = .all
    @State private var query = ""
    @State private var viewing: Artifact?
    @State private var previewURL: URL?
    @State private var opening: String?

    private var visible: [Artifact] { ArtifactFilter.visible(items, filter: filter, query: query) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let errorMessage { ErrorBanner(message: errorMessage).padding(.horizontal) }
                    Picker("Show", selection: $filter) {
                        ForEach(ArtifactFilter.allCases, id: \.self) { f in
                            Text(loaded ? "\(f.rawValue) \(count(f))" : f.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    let list = visible
                    let images = list.filter { $0.kind == .image }
                    let others = list.filter { $0.kind != .image }
                    if !images.isEmpty { imageGrid(images) }
                    if !others.isEmpty { rows(others) }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }
            .overlay { overlay }
            .searchable(text: $query, prompt: "Search artifacts")
            .refreshable { await load(refresh: true) }
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .task {
                #if DEBUG
                if let f = UserDefaults.standard.string(forKey: "artifacts.filter"), let v = ArtifactFilter(rawValue: f) { filter = v }
                #endif
                if !loaded { await load(refresh: false) }
            }
            .fullScreenCover(item: $viewing) { a in
                ArtifactImageViewer(artifact: a, client: app.companionClient,
                                    onOpenChat: a.isDefaultProfile ? { viewing = nil; onOpenChat(a.sessionId, a.sessionTitle) } : nil)
            }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder private var overlay: some View {
        if !loaded && loading {
            ProgressView("Finding artifacts…")
        } else if loaded && visible.isEmpty {
            if !query.isEmpty { ContentUnavailableView.search(text: query) }
            else {
                ContentUnavailableView("No artifacts", systemImage: "square.on.square",
                                       description: Text("Images, files and links from your recent chats show up here."))
            }
        }
    }

    private func count(_ f: ArtifactFilter) -> Int { items.filter(f.matches).count }

    // MARK: Images

    private func imageGrid(_ images: [Artifact]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
            ForEach(images) { a in
                Button { viewing = a } label: { ArtifactThumb(artifact: a, client: app.companionClient) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(a) }
                    .accessibilityLabel(a.label)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Files and links

    private func rows(_ list: [Artifact]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { a in
                Button { Task { await open(a) } } label: { ArtifactRow(artifact: a, busy: opening == a.id) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(a) }
                Divider().padding(.leading, 52)
            }
        }
    }

    @ViewBuilder private func menu(_ a: Artifact) -> some View {
        if a.isDefaultProfile {
            Button { onOpenChat(a.sessionId, a.sessionTitle) } label: { Label("Open chat", systemImage: "bubble.left") }
        }
        Button { UIPasteboard.general.string = a.value } label: {
            Label(a.kind == .link ? "Copy link" : "Copy path", systemImage: "doc.on.doc")
        }
        if a.isRemote, let u = URL(string: a.value) {
            ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    // MARK: Actions

    private func open(_ a: Artifact) async {
        if a.isRemote, let u = URL(string: a.value) { openURL(u); return }
        if a.kind == .image { viewing = a; return }
        guard !a.isMissing else { errorMessage = "\(a.label) no longer exists on your Mac."; return }
        guard let c = app.companionClient, opening == nil else { return }
        opening = a.id
        defer { opening = nil }
        do {
            let data = try await c.artifactFile(a.value)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(a.label.isEmpty ? "file" : a.label)
            try data.write(to: url, options: .atomic)
            previewURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(refresh: Bool) async {
        guard let c = app.companionClient else {
            errorMessage = "Connect the relay in Settings to see artifacts."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let r = try await c.artifacts(refresh: refresh)
            items = r.artifacts
            note = (r.sessionsFailed ?? 0) > 0 ? "Skipped \(r.sessionsFailed!) recent chats that couldn't be read." : nil
            errorMessage = nil
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            loaded = true
        }
    }
}

private struct ArtifactThumb: View {
    let artifact: Artifact
    let client: CompanionClient?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed || artifact.isMissing {
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.title3)
                        Text(artifact.label).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).padding(6)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: artifact.value) {
                guard image == nil, !artifact.isMissing else { return }
                image = await ArtifactImages.shared.image(artifact, maxPixel: 360, client: client)
                failed = image == nil
            }
    }
}

private struct ArtifactRow: View {
    let artifact: Artifact
    let busy: Bool

    private var icon: String {
        switch artifact.kind {
        case .link: "link"
        case .image: "photo"
        case .file:
            switch (artifact.label as NSString).pathExtension.lowercased() {
            case "pdf": "doc.richtext"
            case "md", "txt": "doc.text"
            case "csv", "xlsx", "xls": "tablecells"
            case "mp3", "m4a", "wav", "ogg", "opus", "flac": "waveform"
            case "mp4", "mov", "webm", "mkv": "film"
            case "zip", "gz", "tar": "doc.zipper"
            case "json", "html": "chevron.left.forwardslash.chevron.right"
            default: "doc"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.label).font(.body).lineLimit(1)
                    .foregroundStyle(artifact.isMissing ? .secondary : .primary)
                Text(artifact.isMissing ? "No longer on your Mac" : artifact.location)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("\(artifact.sessionTitle) · \(artifact.date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct ArtifactImageViewer: View {
    let artifact: Artifact
    let client: CompanionClient?
    let onOpenChat: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if failed {
                    ContentUnavailableView("Couldn't load the image", systemImage: "photo",
                                           description: Text(artifact.isMissing ? "It no longer exists on your Mac." : artifact.label))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(artifact.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let onOpenChat {
                        Button(action: onOpenChat) { Image(systemName: "bubble.left") }.accessibilityLabel("Open chat")
                    }
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(artifact.label, image: Image(uiImage: image)))
                    }
                }
            }
            .task {
                image = await ArtifactImages.shared.image(artifact, maxPixel: 2400, client: client)
                failed = image == nil
            }
        }
    }
}
