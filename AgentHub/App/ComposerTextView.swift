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
    /// Names shown bold (and in the accent color) after "@" while typing, e.g. ["Sam", "Nina"].
    var mentions: [String] = []
    var onSubmit: () -> Void
    @Binding var height: CGFloat
    /// Tab: return true when handled (e.g. a mention was completed); otherwise Tab behaves normally.
    var onTab: (() -> Bool)? = nil
    /// Paste: return true when the clipboard was taken as attachments (a screenshot, copied files).
    var onPaste: ((NSPasteboard) -> Bool)? = nil

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
        textView.onTab = { context.coordinator.parent.onTab?() ?? false }
        textView.onPaste = { context.coordinator.parent.onPaste?($0) ?? false }
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
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }
        textView.placeholder = placeholder
        context.coordinator.highlightMentions(textView)
        context.coordinator.recalculateHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true  // placeholder
            highlightMentions(textView)
            recalculateHeight(textView)
        }

        /// Bold + accent color on "@Name" for the agents in `mentions`; plain text everywhere else.
        func highlightMentions(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let font = parent.font
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
            for range in ComposerTextView.mentionRanges(in: storage.string, names: parent.mentions) {
                storage.addAttributes([.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                                       .foregroundColor: NSColor.controlAccentColor], range: range)
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
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

extension ComposerTextView {
    /// Ranges of "@Name" (case-insensitive, whole word) for the given names.
    static func mentionRanges(in text: String, names: [String]) -> [NSRange] {
        let words = names.filter { !$0.isEmpty }.map(NSRegularExpression.escapedPattern(for:))
        guard !words.isEmpty,
              let regex = try? NSRegularExpression(pattern: "(?<![\\w@])@(\(words.joined(separator: "|")))\\b",
                                                   options: .caseInsensitive)
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}

/// NSTextView that turns plain Return into "submit" (and lets the owner handle Tab).
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onTab: (() -> Bool)?
    var onPaste: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if onPaste?(.general) == true { return }
        super.paste(sender)
    }

    override func insertTab(_ sender: Any?) {
        if onTab?() == true { return }
        super.insertTab(sender)
    }
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
