import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Getting images into a Mac chat: ⌘V, drag onto the message field, or drag anywhere on the chat.
/// Handles screenshots (⌘⌃⇧4), "Copy Image" from Safari/Chrome/Preview/Photos (PNG, TIFF, JPEG,
/// HEIC, GIF, WebP data, even when a URL or file name rides along as text), and image files from
/// Finder or the screenshot thumbnail. A copied text selection still pastes as text.
enum MacImageInput {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
    ]

    /// Images on the pasteboard, or nil when it should paste as text.
    static func images(on pb: NSPasteboard) -> [NSImage]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let imgs = urls.filter(isImageFile).compactMap(NSImage.init(contentsOf:))
            return imgs.isEmpty ? nil : imgs
        }
        guard pb.availableType(from: imageTypes) != nil else { return nil }
        // A text selection from a web page or document (rich text + real text) stays text.
        if pb.availableType(from: [.rtf, .rtfd, .html]) != nil,
           let text = pb.string(forType: .string), !isLabel(text) {
            return nil
        }
        var out: [NSImage] = []
        for item in pb.pasteboardItems ?? [] {
            for type in imageTypes {
                if let data = item.data(forType: type), let img = NSImage(data: data) { out.append(img); break }
            }
        }
        if out.isEmpty, let img = NSImage(pasteboard: pb) { out.append(img) }
        return out.isEmpty ? nil : out
    }

    /// Images from a SwiftUI drop (files or image data), delivered on the main actor.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([NSImage]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, NSImage)] = []
        func add(_ i: Int, _ img: NSImage?) {
            guard let img else { return }
            lock.lock(); found.append((i, img)); lock.unlock()
        }
        for (i, p) in providers.enumerated() {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, isImageFile(url) { add(i, NSImage(contentsOf: url)) }
                    group.leave()
                }
            } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    add(i, data.flatMap(NSImage.init(data:)))
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let images = found.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(images) }
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.conforms(to: .image) }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// A URL or file name that came along with a copied image, not a text selection.
    private static func isLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (!t.contains("\n") && t.count < 300 && (t.contains("://") || !t.contains(" ")))
    }
}

/// Drop images anywhere on the chat: an outline shows while dragging over it.
struct MacImageDrop: ViewModifier {
    let enabled: Bool
    let onImages: ([Data]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                MacImageInput.load(providers) { images in
                    onImages(images.compactMap { ImageEncoder.jpeg(from: $0) })
                }
                return true
            }
            .overlay {
                if targeted && enabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            Label("Drop images to attach", systemImage: "photo.badge.plus")
                                .font(.headline).foregroundStyle(Theme.accent)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }
}
