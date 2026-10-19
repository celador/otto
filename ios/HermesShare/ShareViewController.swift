import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet → Hermes: shows what was shared (an article link, text), lets you add a question,
/// then opens Hermes in a new chat with it. If iOS won't let the extension open the app, the chat
/// waits in the shared keychain and starts the next time Hermes comes to the foreground.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model,
                                                           onCancel: { [weak self] in self?.cancel() },
                                                           onSend: { [weak self] prompt in self?.send(prompt) }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        Task { await model.load(from: extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ai.elier.hermes.share", code: 0))
    }

    private func send(_ prompt: String) {
        if !model.images.isEmpty { sendWithImages(prompt); return }
        var c = URLComponents(string: "hermes://new")!
        c.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        guard let url = c.url else { return }
        if openContainingApp(url) {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            SharedVault.savePendingShare(prompt)
            model.savedForLater = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    /// Photos are too big for a URL, so the extension starts the chat on your Hermes itself
    /// (same gateway + key the app shared with its widgets), then opens Hermes on that chat
    /// with the run attached so the reply streams in.
    private func sendWithImages(_ prompt: String) {
        model.sending = true
        model.error = nil
        Task { @MainActor in
            do {
                guard let relay = SharedVault.relay(), let gateway = SharedVault.gateway() else {
                    throw ShareFailure("Open Otto once so it can connect, then share again.")
                }
                let lite = HermesLite(gateway: gateway, relay: relay.relay, apiKey: relay.apiKey, timeout: 60)
                let q = model.question.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = q.split(separator: " ").prefix(8).joined(separator: " ")
                let title = q.isEmpty ? (model.images.count == 1 ? "Shared photo" : "Shared photos") : String(words.prefix(48))
                let sid = try await lite.createSession(title: title)
                let run = try await lite.startRun(sessionID: sid, text: prompt, jpegs: model.images)
                SharedVault.savePendingPhotos(.init(sessionID: sid, text: prompt, jpegs: model.images.compactMap(ShareModel.small)))
                var c = URLComponents(string: "hermes://open")!
                c.queryItems = [URLQueryItem(name: "session", value: sid), URLQueryItem(name: "run", value: run)]
                if let url = c.url, openContainingApp(url) {
                    extensionContext?.completeRequest(returningItems: nil)
                } else {
                    model.savedForLater = true
                    model.doneMessage = "Sent. The chat is waiting in Otto."
                    try? await Task.sleep(for: .seconds(1.6))
                    extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                model.sending = false
                model.error = (error as? ShareFailure)?.message ?? "Couldn't reach your agent server. Is it running and reachable?"
            }
        }
    }

    /// Share extensions can't call UIApplication.open directly; find the app object on the responder
    /// chain and call -openURL:options:completionHandler: on it (the approach other share extensions use).
    private func openContainingApp(_ url: URL) -> Bool {
        guard let appClass = NSClassFromString("UIApplication") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.isKind(of: appClass), r.responds(to: selector) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                let fn = unsafeBitCast(r.method(for: selector), to: OpenFn.self)
                fn(r, selector, url, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

@MainActor
@Observable
final class ShareModel {
    var title: String?
    var link: URL?
    var text: String?
    var loading = true
    var savedForLater = false
    var doneMessage = "Saved. Open Otto to start the chat."
    /// Shared photos, downscaled to ≤2048 px JPEGs (share extensions have a tight memory limit).
    var images: [Data] = []
    var sending = false
    var error: String?
    var question = ""

    var hasContent: Bool { link != nil || !(text ?? "").isEmpty || !images.isEmpty }

    /// A ~1000 px copy for the app's own chat view (keychain hand-off, so keep it small).
    static func small(_ jpeg: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1000]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
    }

    /// Loads an image item (file URL, data or UIImage) and downscales it with ImageIO, which never
    /// decodes the full-size bitmap.
    static func jpeg(from provider: NSItemProvider) async -> Data? {
        let type = UTType.image.identifier
        let item = try? await provider.loadItem(forTypeIdentifier: type)
        var source: CGImageSource?
        if let url = item as? URL { source = CGImageSourceCreateWithURL(url as CFURL, nil) }
        else if let data = item as? Data { source = CGImageSourceCreateWithData(data as CFData, nil) }
        else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        if source == nil {
            let data: Data? = await withCheckedContinuation { c in
                _ = provider.loadDataRepresentation(for: .image) { d, _ in c.resume(returning: d) }
            }
            if let data { source = CGImageSourceCreateWithData(data as CFData, nil) }
        }
        guard let source else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 2048]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    func load(from items: [NSExtensionItem]) async {
        defer { loading = false }
        for item in items {
            if title == nil, let t = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                // Some apps put the page title here, others the whole shared text.
                if t.count < 200, !t.hasPrefix("http") { title = t } else if text == nil { text = t }
            }
            if title == nil, let t = item.attributedTitle?.string, !t.isEmpty { title = t }
            for provider in item.attachments ?? [] {
                if images.count < 4, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let jpeg = await Self.jpeg(from: provider) { images.append(jpeg) }
                    continue
                }
                if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   !url.isFileURL {
                    link = url
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if link == nil, let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
                        link = url
                    } else if text == nil || text!.isEmpty {
                        text = trimmed
                    }
                }
            }
        }
        // A shared text that ends with a link ("Great piece https://…") gives both.
        if link == nil, let t = text, let detected = Self.firstLink(in: t) {
            link = detected
            let rest = t.replacingOccurrences(of: detected.absoluteString, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            text = rest.isEmpty ? nil : rest
        }
        if let t = text, t == title { text = nil }
    }

    static func firstLink(in s: String) -> URL? {
        let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return d?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.url
    }

    /// What Hermes receives: the question, then the material.
    func prompt(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = !images.isEmpty && link == nil
            ? (images.count == 1 ? "Take a look at this image and tell me what you see." : "Take a look at these images and tell me what you see.")
            : link != nil ? "Let's discuss this article. Read it first, then give me a short summary and what stands out." : "Let's discuss this."
        var parts = [q.isEmpty ? fallback : q]
        var material: [String] = []
        if let title { material.append(title) }
        if let link { material.append(link.absoluteString) }
        if let text, !text.isEmpty { material.append(text.count > 6000 ? String(text.prefix(6000)) + "…" : text) }
        if !material.isEmpty { parts.append(material.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let onCancel: () -> Void
    let onSend: (String) -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        model.images.isEmpty || model.link != nil
            ? ["Summarize it", "What are the key takeaways?", "What's the strongest counterargument?", "Is this accurate?"]
            : ["What is this?", "Read the text in it", "Explain this", "What should I do about this?"]
    }

    private func go(_ q: String) {
        model.question = q
        onSend(model.prompt(question: q))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.savedForLater {
                        Label(model.doneMessage, systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else if model.loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        if !model.images.isEmpty { imageStrip }
                        if model.link != nil || !(model.text ?? "").isEmpty || model.images.isEmpty { sharedCard }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                        }
                        TextField("What do you want to discuss? (optional)", text: $question, axis: .vertical)
                            .lineLimit(2...6)
                            .focused($focused)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { go(s) }
                                        .font(.footnote)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Discuss in Otto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.sending {
                        ProgressView()
                    } else {
                        Button("Start chat") { go(question) }
                            .fontWeight(.semibold)
                            .disabled(model.loading || model.savedForLater || (!model.hasContent && question.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                }
            }
        }
        .tint(.primary)
        .onAppear { focused = false }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.images.enumerated()), id: \.offset) { _, data in
                    if let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: model.images.count == 1 ? 200 : 110, height: model.images.count == 1 ? 200 : 110)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var sharedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.link != nil ? "link" : "text.quote")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title ?? model.link?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? "Shared text")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                if let link = model.link {
                    Text(link.host(percentEncoded: false) ?? link.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let text = model.text, !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ShareFailure: Error { let message: String; init(_ m: String) { message = m } }
