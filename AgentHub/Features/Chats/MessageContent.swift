import AppKit
import SwiftUI
import WebKit

/// A reply split into what it shows: text, code blocks, and designs (HTML/SVG mockups rendered live).
enum MessageSegment: Equatable {
    case text(String)
    /// `complete` is false while the block is still streaming in.
    case code(language: String, code: String, complete: Bool)
    case design(language: String, code: String)

    /// Fenced blocks (```lang … ```) become code; a finished HTML or SVG page becomes a design preview.
    static func parse(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [Substring] = []
        var fence: (language: String, lines: [Substring])?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(.text(joined)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if trimmed.hasPrefix("```") && trimmed.allSatisfy({ $0 == "`" }) {
                    segments.append(block(open.language, open.lines.joined(separator: "\n"), complete: true))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
            } else if trimmed.hasPrefix("```") {
                flushProse()
                fence = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased(), [])
            } else {
                prose.append(line)
            }
        }
        flushProse()
        if let open = fence { segments.append(block(open.language, open.lines.joined(separator: "\n"), complete: false)) }
        return segments
    }

    private static func block(_ language: String, _ code: String, complete: Bool) -> MessageSegment {
        if complete, isDesign(language: language, code: code) { return .design(language: language, code: code) }
        return .code(language: language, code: code, complete: complete)
    }

    /// A whole screen worth previewing, not a snippet: an HTML page or fragment with markup, or an SVG.
    static func isDesign(language: String, code: String) -> Bool {
        let lower = code.lowercased()
        switch language {
        case "html", "htm", "xhtml": return lower.contains("<html") || lower.contains("<body") || lower.contains("<div")
            || lower.contains("<section") || lower.contains("<main") || lower.contains("<header")
        case "svg", "xml": return lower.contains("<svg")
        default: return false
        }
    }
}

/// What a reply looks like: text in the bubble, code blocks and design previews as cards.
struct MessageContent: View {
    let text: String
    let isUser: Bool
    var mentionNames: [String] = []

    var body: some View {
        let segments = isUser ? [.text(text)] : MessageSegment.parse(text)
        VStack(alignment: .leading, spacing: Theme.s2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let prose):
                    Text(LocalizedStringKey(mentionNames.isEmpty ? prose : StartupDetail.boldMentions(prose, names: mentionNames)))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .tint(isUser ? .white : Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, segments.count == 1 ? 9 : 4)
                case .code(let language, let code, let complete):
                    CodeBlockView(language: language, code: code, complete: complete).padding(.horizontal, 6)
                case .design(let language, let code):
                    DesignPreview(language: language, code: code).padding(.horizontal, 6)
                }
            }
        }
        .padding(.vertical, segments.count == 1 ? 0 : 6)
    }
}

/// A code block: language, Copy, monospaced and scrollable (both ways for long lines and long files).
struct CodeBlockView: View {
    let language: String
    let code: String
    var complete = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s2) {
                Text(language.isEmpty ? "code" : language).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if !complete { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A designer's mockup, rendered live: Desktop / Tablet / Phone widths, the code, and Open in browser.
struct DesignPreview: View {
    let language: String
    let code: String
    @State private var device: Device = .desktop
    @State private var showsCode = false

    enum Device: String, CaseIterable, Identifiable {
        case desktop = "Desktop", tablet = "Tablet", phone = "Phone"
        var id: String { rawValue }
        var width: CGFloat? { switch self { case .desktop: nil; case .tablet: 768; case .phone: 390 } }
        var symbol: String { switch self { case .desktop: "desktopcomputer"; case .tablet: "ipad"; case .phone: "iphone" } }
    }

    /// Added to designers' instructions so their mockups render here.
    static let instruction = """
    ## Show the design
    When you design or redesign a screen, end your reply with ONE complete, self-contained HTML mockup of it in a \
    ```html code block: real copy (no lorem ipsum), inline <style> (or the Tailwind CDN script), system fonts, \
    accessible contrast, and the key states visible. It renders as a live preview in the chat, so make it look finished.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s2) {
                Label("Design preview", systemImage: "paintbrush.pointed").font(.callout.weight(.semibold))
                Spacer()
                Picker("Size", selection: $device) {
                    ForEach(Device.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Preview size")
                Button { showsCode.toggle() } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .help(showsCode ? "Hide the code" : "Show the code")
                .accessibilityLabel(showsCode ? "Hide the code" : "Show the code")
                Button { openInBrowser() } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open in your browser")
                    .accessibilityLabel("Open in browser")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            HStack {
                Spacer(minLength: 0)
                HTMLView(html: page)
                    .frame(width: device.width, height: device == .phone ? 640 : 460)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .animation(.easeOut(duration: 0.2), value: device)
                Spacer(minLength: 0)
            }
            .padding(device == .desktop ? 0 : 10)
            .background(Color.black.opacity(0.04))
            if showsCode {
                Divider()
                CodeBlockView(language: language, code: code).padding(8)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    /// SVGs and fragments get a page around them.
    private var page: String {
        let lower = code.lowercased()
        if lower.contains("<html") { return code }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{margin:0;font-family:-apple-system,system-ui,sans-serif}svg{max-width:100%;height:auto}</style></head>
        <body>\(code)</body></html>
        """
    }

    private func openInBrowser() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentim-design-\(abs(code.hashValue)).html")
        try? page.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
}

/// A sandboxed web view for design previews: nothing is stored, and links open in your browser.
struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// GitHub links in a reply (pull requests, issues, commits, files) as small cards you can open.
struct GitHubLinks: View {
    let text: String

    struct Item: Identifiable, Equatable {
        enum Kind { case pullRequest, issue, commit, file, repo }
        let url: URL
        let kind: Kind
        let title: String
        var id: URL { url }
        var symbol: String {
            switch kind {
            case .pullRequest: "arrow.triangle.pull"
            case .issue: "exclamationmark.circle"
            case .commit: "smallcircle.filled.circle"
            case .file: "doc.text"
            case .repo: "book.closed"
            }
        }
    }

    static func items(in text: String) -> [Item] {
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[^\s)\]>"'`]*)?"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let link = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            guard seen.insert(link).inserted, let url = URL(string: link) else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            let repo = parts.prefix(2).joined(separator: "/")
            switch parts.dropFirst(2).first {
            case "pull" where parts.count > 3: return Item(url: url, kind: .pullRequest, title: "\(repo) #\(parts[3])")
            case "issues" where parts.count > 3: return Item(url: url, kind: .issue, title: "\(repo) #\(parts[3])")
            case "commit" where parts.count > 3: return Item(url: url, kind: .commit, title: "\(repo) @ \(parts[3].prefix(7))")
            case "blob" where parts.count > 4, "tree" where parts.count > 4:
                return Item(url: url, kind: .file, title: "\(repo): \(parts.dropFirst(4).joined(separator: "/"))")
            case nil: return Item(url: url, kind: .repo, title: repo)
            default: return nil
            }
        }
    }

    var body: some View {
        let items = Self.items(in: text)
        if !items.isEmpty {
            FlowRow(items) { item in
                Link(destination: item.url) {
                    Label(item.title, systemImage: item.symbol)
                        .font(.caption.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .help(item.url.absoluteString)
            }
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowRow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    let content: (Data.Element) -> Content
    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(data) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in rows(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}
