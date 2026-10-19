import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Mac message field: an NSTextView so Return sends, Shift/Option-Return adds a line,
/// ⌘V of an image adds an attachment, and the field grows up to `maxLines` before scrolling.
/// Same API as the iOS ComposerTextView (ios/Hermes/Views/ComposerTextView.swift).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    /// Suggested reply shown as the placeholder while empty; → or Tab fills it in.
    var suggestion: String? = nil
    var maxLines: Int = 10
    var acceptsImages: Bool
    var onSubmit: () -> Void = {}
    var onPasteImages: ([NSImage]) -> Void

    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let inset = NSSize(width: 0, height: 8)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none

        let tv = PastingTextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = Self.inset
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.setAccessibilityLabel("Message")
        tv.onPasteImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onPasteImages(images)
        }
        tv.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        tv.onAcceptSuggestion = { [weak coordinator = context.coordinator, weak tv] in
            guard let c = coordinator, let tv else { return }
            c.parent.text = tv.string
            tv.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        tv.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let c = coordinator, c.parent.isFocused != focused else { return }
            DispatchQueue.main.async { c.parent.isFocused = focused }
        }
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? PastingTextView else { return }
        if tv.string != text, !tv.hasMarkedText() || text.isEmpty {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        tv.placeholder = placeholder
        let s = suggestion?.trimmingCharacters(in: .whitespaces)
        tv.suggestion = (s?.isEmpty ?? true) ? nil : s
        tv.acceptsImages = acceptsImages
        tv.needsDisplay = true
        let isFirst = tv.window?.firstResponder === tv
        if isFocused, !isFirst {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let width = max(40, proposal.width ?? 400)
        // Measure without touching the views (changing frames here loops AppKit layout).
        let line = (tv.layoutManager?.defaultLineHeight(for: Self.font)) ?? 17
        let measured = (tv.string.isEmpty ? " " : tv.string + (tv.string.hasSuffix("\n") ? " " : "")) as NSString
        let used = measured.boundingRect(with: NSSize(width: width - 2 * (tc.lineFragmentPadding), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: Self.font]).height
        _ = lm
        let content = max(used, line) + Self.inset.height * 2
        let maxHeight = ceil(line * CGFloat(maxLines) + Self.inset.height * 2)
        return CGSize(width: width, height: min(ceil(content), maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            tv.needsDisplay = true
            tv.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}

/// Keeps the text view as wide as the visible area (it starts at zero width otherwise and
/// lays the text out in a zero-width container, so nothing shows).
final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? NSTextView else { return }
        let w = contentSize.width
        if w > 0, abs(tv.frame.width - w) > 0.5 {
            tv.setFrameSize(NSSize(width: w, height: tv.frame.height))
        }
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let h = max(contentSize.height, lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            if abs(tv.frame.height - h) > 0.5 { tv.setFrameSize(NSSize(width: tv.frame.width, height: h)) }
        }
    }
}

final class PastingTextView: NSTextView {
    var acceptsImages = true
    var placeholder = ""
    var suggestion: String?
    var onAcceptSuggestion: (() -> Void)?
    var onPasteImages: (([NSImage]) -> Void)?
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var canAcceptSuggestion: Bool { suggestion != nil && string.isEmpty && !hasMarkedText() }

    /// Fill the field with the suggested reply, caret at the end, ready to send.
    func acceptSuggestion() {
        guard canAcceptSuggestion, let suggestion else { return }
        string = suggestion
        setSelectedRange(NSRange(location: (suggestion as NSString).length, length: 0))
        needsDisplay = true
        onAcceptSuggestion?()
    }

    override func keyDown(with event: NSEvent) {
        // → or Tab on an empty field takes the suggested reply.
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if canAcceptSuggestion, mods.isEmpty, event.keyCode == 124 || event.keyCode == 48 {
            acceptSuggestion()
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if hasMarkedText() { super.keyDown(with: event); return }  // confirm IME composition
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if mods.isEmpty || mods == [.numericPad] || mods == [.function] {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        acceptsImages ? super.readablePasteboardTypes + MacImageInput.imageTypes + [.fileURL] : super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if acceptsImages, let images = Self.images(on: .general), !images.isEmpty {
            onPasteImages?(images)
            return
        }
        pasteAsPlainText(sender)
    }

    /// Images dropped from Finder or another app also become attachments.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if acceptsImages, let images = Self.images(on: sender.draggingPasteboard), !images.isEmpty {
            onPasteImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func images(on pb: NSPasteboard) -> [NSImage]? { MacImageInput.images(on: pb) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shown = suggestion ?? placeholder
        guard string.isEmpty, !shown.isEmpty else { return }
        let f = font ?? ComposerTextView.font
        let text = NSMutableAttributedString(string: shown, attributes: [.font: f, .foregroundColor: NSColor.placeholderTextColor])
        if suggestion != nil {
            text.append(NSAttributedString(string: "  → to use", attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        text.draw(at: origin)
    }
}
