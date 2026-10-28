import AppKit
import SwiftUI

/// A multi-line text box where Return submits and Shift/Option+Return inserts a new line.
/// (SwiftUI's vertical TextField on macOS doesn't reliably hand Return to the app.) It grows with
/// the text between `minHeight` and `maxHeight`, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 72
    var maxHeight: CGFloat = 260
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize + 2)
    var focusOnAppear = true
    var onSubmit: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.string = text
        textView.setAccessibilityLabel(placeholder)
        scroll.documentView = textView

        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SubmitTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        textView.placeholder = placeholder
        context.coordinator.recalculateHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true  // placeholder
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

/// NSTextView that turns plain Return into "submit".
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return, keypad Enter
        if isReturn, !hasMarkedText(), SubmitTextView.shouldSubmit(event.modifierFlags) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Return (or Cmd+Return) submits; Shift/Option/Control+Return add a new line.
    static func shouldSubmit(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .option, .control]).isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
