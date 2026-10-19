import SwiftUI
import UIKit

/// The message field. A UITextView instead of a SwiftUI TextField so the
/// standard iOS Paste (long-press → Paste, ⌘V) accepts images, like ChatGPT:
/// pasted images become attachments, pasted text is inserted as usual.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    /// A suggested reply ("Yes, deploy it") shown as the placeholder while the field is empty.
    /// → / Tab, a space-bar drag to the right, or a swipe right on the field fills it in.
    var suggestion: String? = nil
    var maxLines: Int = 6
    var acceptsImages: Bool
    /// Return on a hardware keyboard (iPad Magic Keyboard etc.). Shift+Return inserts a newline.
    var onSubmit: () -> Void = {}
    var onPasteImages: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PastingTextView {
        let tv = PastingTextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.onPasteImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onPasteImages(images)
        }
        tv.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        tv.onAcceptSuggestion = { [weak coordinator = context.coordinator, weak tv] in
            guard let tv else { return }
            coordinator?.textViewDidChange(tv)
        }
        return tv
    }

    func updateUIView(_ tv: PastingTextView, context: Context) {
        context.coordinator.parent = self
        // Don't stomp on in-progress keyboard dictation / IME (marked text),
        // except to clear the field after Send.
        if tv.text != text, tv.markedTextRange == nil || text.isEmpty {
            tv.text = text
        }
        let trimmed = suggestion?.trimmingCharacters(in: .whitespaces)
        let suggestion = (trimmed?.isEmpty ?? true) ? nil : trimmed
        tv.suggestion = suggestion
        if let suggestion {
            let shown = NSMutableAttributedString(string: suggestion, attributes: [.foregroundColor: UIColor.placeholderText])
            shown.append(NSAttributedString(string: "  →", attributes: [.foregroundColor: UIColor.tertiaryLabel]))
            tv.placeholderLabel.attributedText = shown
            tv.placeholderLabel.accessibilityLabel = "Suggested reply: \(suggestion). Swipe right to use it."
        } else {
            tv.placeholderLabel.attributedText = nil
            tv.placeholderLabel.textColor = .placeholderText
            tv.placeholderLabel.text = placeholder
            tv.placeholderLabel.accessibilityLabel = nil
        }
        tv.placeholderLabel.isHidden = !text.isEmpty
        tv.acceptsImages = acceptsImages
        if isFocused, !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isFocused, tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = uiView.font?.lineHeight ?? 20
        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maxHeight = ceil(line * CGFloat(maxLines) + inset)
        let scrolls = fit.height > maxHeight
        if uiView.isScrollEnabled != scrolls {
            DispatchQueue.main.async { uiView.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: min(ceil(fit.height), maxHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            if let p = tv as? PastingTextView {
                p.placeholderLabel.isHidden = !tv.text.isEmpty
                p.refreshSuggestionSwipe()
            }
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class PastingTextView: UITextView {
    var acceptsImages = true
    var onPasteImages: (([UIImage]) -> Void)?
    var onSubmit: (() -> Void)?
    /// Called after a suggested reply was put into the field (the coordinator syncs the binding).
    var onAcceptSuggestion: (() -> Void)?
    var suggestion: String? {
        didSet { refreshSuggestionSwipe() }
    }
    func refreshSuggestionSwipe() { suggestionSwipe.isEnabled = canAcceptSuggestion }
    let placeholderLabel = UILabel()
    private lazy var suggestionSwipe: UISwipeGestureRecognizer = {
        let g = UISwipeGestureRecognizer(target: self, action: #selector(acceptSuggestion))
        g.direction = .right
        g.cancelsTouchesInView = false
        return g
    }()
    private var floatStart: CGPoint?
    private var acceptedDuringFloat = false

    var canAcceptSuggestion: Bool { suggestion != nil && text.isEmpty && markedTextRange == nil }

    /// Fill the field with the suggested reply, caret at the end, ready to send.
    @objc func acceptSuggestion() {
        guard canAcceptSuggestion, let suggestion else { return }
        text = suggestion
        selectedRange = NSRange(location: (suggestion as NSString).length, length: 0)
        placeholderLabel.isHidden = true
        suggestionSwipe.isEnabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onAcceptSuggestion?()
    }

    // Space-bar trackpad (press and drag on the space bar): dragging right on an empty field
    // takes the suggestion, like → on a keyboard.
    override func beginFloatingCursor(at point: CGPoint) {
        super.beginFloatingCursor(at: point)
        floatStart = point
        acceptedDuringFloat = false
    }

    override func updateFloatingCursor(at point: CGPoint) {
        super.updateFloatingCursor(at: point)
        if let start = floatStart, canAcceptSuggestion, point.x - start.x > 18 {
            acceptSuggestion()
            acceptedDuringFloat = true
        }
    }

    override func endFloatingCursor() {
        super.endFloatingCursor()
        floatStart = nil
        if acceptedDuringFloat {
            acceptedDuringFloat = false
            // The drag keeps moving the caret inside the new text; leave it at the end.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectedRange = NSRange(location: (self.text as NSString).length, length: 0)
            }
        }
    }

    /// Hardware keyboards only (the on-screen keyboard's return key still adds a line, like ChatGPT/Claude):
    /// Return sends, Shift+Return (or Option+Return) inserts a newline; → or Tab takes the suggested reply.
    override var keyCommands: [UIKeyCommand]? {
        var extra: [UIKeyCommand] = []
        if canAcceptSuggestion {
            for input in [UIKeyCommand.inputRightArrow, "\t"] {
                let c = UIKeyCommand(input: input, modifierFlags: [], action: #selector(acceptSuggestion))
                c.wantsPriorityOverSystemBehavior = true
                c.discoverabilityTitle = "Use Suggested Reply"
                extra.append(c)
            }
        }
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed))
        send.wantsPriorityOverSystemBehavior = true
        send.discoverabilityTitle = "Send"
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertNewline))
        newline.wantsPriorityOverSystemBehavior = true
        newline.discoverabilityTitle = "New Line"
        let altNewline = UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(insertNewline))
        altNewline.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [send, newline, altNewline] + extra
    }

    @objc func returnPressed() {
        // Return confirms an in-progress IME composition (Japanese, Chinese…), it doesn't send.
        if markedTextRange != nil { unmarkText(); return }
        onSubmit?()
    }

    @objc func insertNewline() {
        insertText("\n")
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        addGestureRecognizer(suggestionSwipe)
        suggestionSwipe.isEnabled = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: frameLayoutGuide.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: 9),
        ])
        #if DEBUG
        NotificationCenter.default.addObserver(self, selector: #selector(debugPaste),
                                               name: Self.debugPasteNotification, object: nil)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Show "Paste" in the edit menu when the clipboard holds an image, not only text.
    /// (`hasImages` doesn't read the clipboard, so it never triggers the paste prompt.)
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), acceptsImages, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if acceptsImages, pb.hasImages {
            let images = pb.images ?? pb.image.map { [$0] } ?? []
            if !images.isEmpty {
                onPasteImages?(images)
                return
            }
        }
        super.paste(sender)
    }

    #if DEBUG
    static let debugPasteNotification = Notification.Name("ai.elier.hermes.debugPaste")

    @objc private func debugPaste() {
        NSLog("HERMESPASTE canPaste=%d", canPerformAction(#selector(paste(_:)), withSender: nil) ? 1 : 0)
        paste(nil)
    }
    #endif
}
