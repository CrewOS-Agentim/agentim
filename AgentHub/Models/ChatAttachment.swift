import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A file added to a chat message (dragged in or picked with 📎). Text files and PDFs are read
/// into the prompt; images and other binaries are mentioned by name (the chat models are text-only).
struct ChatAttachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case text, pdf, image, other }

    var id = UUID()
    var name: String
    var kind: Kind
    var byteCount: Int
    /// What the model reads; nil when the file can't be read as text.
    var text: String?
    var truncated = false

    static let maxFiles = 10
    static let maxFileBytes = 20_000_000
    static let maxTextCharacters = 100_000

    var symbol: String {
        switch kind {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .other: "doc"
        }
    }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }

    /// Whether the model gets the contents (shown on the chip before sending).
    var isReadable: Bool { text != nil }

    /// How the file appears in the prompt.
    var promptBlock: String {
        guard let text else {
            return "[Attached \(kind == .image ? "image" : "file") \"\(name)\" (\(sizeLabel)); its contents can't be read as text.]"
        }
        return "<file name=\"\(name)\"\(truncated ? " truncated=\"true\"" : "")>\n\(text)\n</file>"
    }

    enum LoadError: LocalizedError {
        case folder(String), tooBig(String), unreadable(String)

        var errorDescription: String? {
            switch self {
            case .folder(let name): "\(name) is a folder. Drop the files inside it instead."
            case .tooBig(let name): "\(name) is over 20 MB."
            case .unreadable(let name): "Couldn't read \(name)."
            }
        }
    }

    static func load(_ url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true { throw LoadError.folder(name) }
        let size = values?.fileSize ?? 0
        if size > maxFileBytes { throw LoadError.tooBig(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)

        var attachment = ChatAttachment(name: name, kind: .other, byteCount: size)
        if type?.conforms(to: .pdf) == true {
            attachment.kind = .pdf
            if let text = PDFDocument(url: url)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachment.setText(text)
            }
            return attachment
        }
        if type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true {
            attachment.kind = type?.conforms(to: .image) == true ? .image : .other
            return attachment
        }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
        if let text = decodeText(data, declaredText: type?.conforms(to: .text) == true) {
            attachment.kind = .text
            attachment.setText(text)
        }
        return attachment
    }

    /// UTF-8 text without NUL bytes (binary files often decode as "valid" UTF-8 otherwise).
    static func decodeText(_ data: Data, declaredText: Bool) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return declaredText ? String(data: data, encoding: .isoLatin1) : nil
    }

    mutating func setText(_ value: String) {
        truncated = value.count > Self.maxTextCharacters
        text = truncated ? String(value.prefix(Self.maxTextCharacters)) : value
    }
}
