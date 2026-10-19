import AppKit
import SwiftUI

// Small macOS shims so the shared iOS SwiftUI code compiles unchanged where the Mac has a
// close equivalent. Only compiled into the Mac target (ios/OttoMac). iOS-only behaviour
// with no Mac meaning (camera, Live Activities, haptics) is guarded with #if os(iOS) instead.

// MARK: UIKit names → AppKit

typealias UIImage = NSImage
typealias UIColor = NSColor

extension NSImage {
    /// PNG/JPEG data like UIImage.jpegData.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// The bits of UIPasteboard the shared code uses (string + image), on NSPasteboard.
@MainActor
final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
    var image: NSImage? {
        get { NSImage(pasteboard: NSPasteboard.general) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.writeObjects([newValue]) }
        }
    }
    var url: URL? {
        get { NSPasteboard.general.string(forType: .string).flatMap(URL.init(string:)) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.writeObjects([newValue as NSURL]) }
        }
    }
    var hasStrings: Bool { NSPasteboard.general.string(forType: .string) != nil }
    var hasImages: Bool { NSImage.canInit(with: NSPasteboard.general) }
}

extension NSColor {
    /// Light/dark pair, like the iOS system colours (NSColor's own grays are tuned for AppKit chrome).
    private static func pair(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? c(dark) : c(light) }
    }

    static var systemBackground: NSColor { pair(0xFDFCFA, 0x1F1E1D) }
    static var secondarySystemBackground: NSColor { pair(0xF4F1EE, 0x2A2826) }
    static var tertiarySystemBackground: NSColor { pair(0xFFFFFF, 0x3A3A3C) }
    static var systemGroupedBackground: NSColor { pair(0xF2F2F5, 0x1A1A1A) }
    static var secondarySystemGroupedBackground: NSColor { pair(0xFFFFFF, 0x2C2C2E) }
    static var tertiarySystemGroupedBackground: NSColor { pair(0xF2F2F5, 0x3A3A3C) }
    static var systemFill: NSColor { pair(0x787880, 0x787880, alpha: 0.2) }
    static var secondarySystemFill: NSColor { pair(0x787880, 0x787880, alpha: 0.16) }
    static var tertiarySystemFill: NSColor { pair(0x767680, 0x767680, alpha: 0.12) }
    static var quaternarySystemFill: NSColor { pair(0x747480, 0x747480, alpha: 0.08) }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var systemGray2: NSColor { pair(0xAEAEB2, 0x636366) }
    static var systemGray3: NSColor { pair(0xC7C7CC, 0x48484A) }
    static var systemGray4: NSColor { pair(0xD1D1D6, 0x3A3A3C) }
    static var systemGray5: NSColor { pair(0xE5E5EA, 0x2C2C2E) }
    static var systemGray6: NSColor { pair(0xF2F2F7, 0x1C1C1E) }
}

// MARK: iOS-only SwiftUI modifiers → no-ops / Mac equivalents

enum MacTitleDisplayMode { case automatic, inline, large }
enum MacAutocapitalization { case never, sentences, words, characters }
enum MacKeyboardType { case `default`, URL, asciiCapable, numberPad, decimalPad, emailAddress, webSearch, phonePad }

extension View {
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }
    func textInputAutocapitalization(_ mode: MacAutocapitalization?) -> some View { self }
    func keyboardType(_ type: MacKeyboardType) -> some View { self }
    func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View { self }
    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                             @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var bottomBar: ToolbarItemPlacement { .automatic }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

extension ListStyle where Self == PlainListStyle {
    static var grouped: PlainListStyle { .plain }
}

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}
