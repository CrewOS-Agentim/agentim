import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A file added to a chat message (dragged in, pasted or picked with +). Text, code, PDFs and documents
/// (Word, RTF, HTML) are read into the prompt; a folder becomes its file tree plus the code inside;
/// images go to models that can see them. Anything else is mentioned by name.
struct ChatAttachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case text, pdf, image, other, document, folder }

    var id = UUID()
    var name: String
    var kind: Kind
    var byteCount: Int
    /// What the model reads; nil when the file can't be read as text.
    var text: String?
    var truncated = false
    /// Images: the copy saved with agentim (a file name in `storeDirectory`), sent to models that see images.
    var imageFile: String?
    /// Folders: how many files were read, and how many there were in total.
    var filesRead: Int?
    var filesTotal: Int?

    static let maxFiles = 10
    static let maxFileBytes = 20_000_000
    static let maxTextCharacters = 100_000
    /// A folder (codebase) may send more, spread over its files.
    static let maxFolderCharacters = 240_000
    static let maxFolderFileCharacters = 30_000
    /// Images are scaled down to this many pixels on the long side (what vision models use anyway).
    static let maxImagePixels = 1568

    /// Where image copies are kept (tests point this at a temporary folder).
    nonisolated(unsafe) static var storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("agentim/attachments", isDirectory: true)

    var symbol: String {
        switch kind {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .document: "doc.text.fill"
        case .image: "photo"
        case .folder: "folder"
        case .other: "doc"
        }
    }

    var sizeLabel: String {
        if kind == .folder, let filesRead { return "\(filesRead) file\(filesRead == 1 ? "" : "s")" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Whether the model gets the contents (shown on the chip before sending).
    var isReadable: Bool { text != nil || imageFile != nil }

    var imageURL: URL? { imageFile.map { Self.storeDirectory.appendingPathComponent($0) } }

    /// How the file appears in the prompt. `withImage`: the image itself goes along with the text.
    func promptBlock(withImage: Bool = false) -> String {
        if kind == .image, withImage, imageFile != nil { return "[Image \"\(name)\" attached.]" }
        guard let text else {
            return "[Attached \(kind == .image ? "image" : "file") \"\(name)\" (\(sizeLabel)); its contents can't be read as text.]"
        }
        if kind == .folder {
            return "<folder name=\"\(name)\" files_read=\"\(filesRead ?? 0)\" files_total=\"\(filesTotal ?? 0)\"\(truncated ? " truncated=\"true\"" : "")>\n\(text)\n</folder>"
        }
        return "<file name=\"\(name)\"\(truncated ? " truncated=\"true\"" : "")>\n\(text)\n</file>"
    }

    /// The saved image as base64 JPEG, for the request.
    func imageBase64() -> String? {
        guard let imageURL, let data = try? Data(contentsOf: imageURL) else { return nil }
        return data.base64EncodedString()
    }

    enum LoadError: LocalizedError {
        case tooBig(String), unreadable(String), emptyFolder(String)

        var errorDescription: String? {
            switch self {
            case .tooBig(let name): "\(name) is over 20 MB."
            case .unreadable(let name): "Couldn't read \(name)."
            case .emptyFolder(let name): "\(name) has no text or code files to read."
            }
        }
    }

    static func load(_ url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        // A folder (or codebase); an .rtfd document is a folder too, but reads as a document.
        if values?.isDirectory == true && type?.conforms(to: .rtfd) != true { return try loadFolder(url) }
        let size = values?.fileSize ?? 0
        if size > maxFileBytes { throw LoadError.tooBig(name) }

        var attachment = ChatAttachment(name: name, kind: .other, byteCount: size)
        if type?.conforms(to: .pdf) == true {
            attachment.kind = .pdf
            if let text = PDFDocument(url: url)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachment.setText(text)
            }
            return attachment
        }
        if type?.conforms(to: .image) == true {
            attachment.kind = .image
            attachment.imageFile = saveImage(url)
            return attachment
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true { return attachment }
        if isDocument(url, type: type) {
            attachment.kind = .document
            if let text = documentText(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachment.setText(text)
            }
            return attachment
        }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
        if let text = decodeText(data, declaredText: type?.conforms(to: .text) == true) {
            attachment.kind = .text
            attachment.setText(text)
        }
        return attachment
    }

    /// An image from the clipboard (a pasted screenshot).
    static func image(_ data: Data, name: String) -> ChatAttachment? {
        guard let file = saveImage(data: data) else { return nil }
        return ChatAttachment(name: name, kind: .image, byteCount: data.count, imageFile: file)
    }

    // MARK: Documents

    private static let documentExtensions: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "webarchive", "wordml"]

    static func isDocument(_ url: URL, type: UTType?) -> Bool {
        if documentExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type else { return false }
        return type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .html) || type.conforms(to: .webArchive)
    }

    /// Word, OpenDocument, RTF and HTML through the system's text importers.
    static func documentText(_ url: URL) -> String? {
        (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    // MARK: Images

    /// Scales the image down and saves it as JPEG with agentim; returns the file name.
    private static func saveImage(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return saveImage(source: source)
    }

    private static func saveImage(data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return saveImage(source: source)
    }

    private static func saveImage(source: CGImageSource) -> String? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let file = "\(UUID().uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            try jpeg.write(to: storeDirectory.appendingPathComponent(file))
            return file
        } catch {
            return nil
        }
    }

    // MARK: Folders (a codebase)

    /// Folders that are never worth reading: dependencies, build output, caches, version control.
    static let skippedFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "bower_components", ".build", "build", "DerivedData", "dist", "out",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".venv", "venv", "env", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".tox", "Pods", "Carthage", ".gradle", "target", "vendor", "coverage", ".cache", ".terraform",
        ".idea", ".vscode", ".codegraph", ".swiftpm", "xcuserdata", ".expo",
    ]
    /// Files skipped for being secrets, lock files or generated.
    static func isSkippedFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".env") || lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") { return true }
        if ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "podfile.lock", "cargo.lock", "poetry.lock",
            "composer.lock", "gemfile.lock", "package.resolved", ".ds_store", "credentials", "credentials.json",
            ".npmrc", ".pypirc", ".netrc"].contains(lower) { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".mobileprovision", ".min.js", ".min.css", ".map",
                ".lock"].contains { lower.hasSuffix($0) }
    }
    /// Read first: what explains a project.
    private static let keyFiles: [String] = [
        "readme.md", "readme", "readme.txt", "claude.md", "agents.md", "package.json", "package.swift", "project.yml",
        "pyproject.toml", "requirements.txt", "setup.py", "cargo.toml", "go.mod", "gemfile", "build.gradle",
        "build.gradle.kts", "pom.xml", "makefile", "dockerfile", "docker-compose.yml", "docker-compose.yaml",
        "tsconfig.json", "next.config.js", "vite.config.ts",
    ]

    /// The folder's tree and the contents of its text and code files, key files first, within a budget.
    static func loadFolder(_ root: URL, budget: Int = maxFolderCharacters) throws -> ChatAttachment {
        let ignore = GitIgnore(root: root)
        var files: [(path: String, url: URL, size: Int)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        let rootPath = root.standardizedFileURL.path
        while let url = enumerator?.nextObject() as? URL {
            let path = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedFolders.contains(name) || (name.hasPrefix(".") && name != ".github") || ignore.ignores(path, folder: true) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, !isSkippedFile(name), !ignore.ignores(path, folder: false) else { continue }
            files.append((path, url, values?.fileSize ?? 0))
            if files.count >= 5_000 { break }
        }

        func priority(_ path: String) -> (Int, Int, String) {
            let name = (path as NSString).lastPathComponent.lowercased()
            let depth = path.split(separator: "/").count
            let key = keyFiles.firstIndex(of: name).map { depth == 1 ? $0 : 100 + $0 } ?? 1_000
            return (key, depth, path)
        }
        files.sort { priority($0.path) < priority($1.path) }

        var sections: [String] = []
        var used = 0, read = 0, size = 0
        var cut = false
        for file in files where file.size <= 2_000_000 {
            guard used < budget else { cut = true; break }
            guard let data = try? Data(contentsOf: file.url),
                  let text = decodeText(data, declaredText: false), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let room = min(maxFolderFileCharacters, budget - used)
            let body = text.count > room ? String(text.prefix(room)) : text
            let clipped = body.count < text.count
            sections.append("<file path=\"\(file.path)\"\(clipped ? " truncated=\"true\"" : "")>\n\(body)\n</file>")
            used += body.count
            read += 1
            size += data.count
            if clipped { cut = true }
        }
        guard read > 0 else { throw LoadError.emptyFolder(root.lastPathComponent) }

        let listed = files.map(\.path).sorted()
        let tree = listed.prefix(400).joined(separator: "\n") + (listed.count > 400 ? "\n… and \(listed.count - 400) more files" : "")
        var attachment = ChatAttachment(name: root.lastPathComponent + "/", kind: .folder, byteCount: size)
        attachment.text = "<tree>\n\(tree)\n</tree>\n\n" + sections.joined(separator: "\n\n")
        attachment.truncated = cut || read < files.count
        attachment.filesRead = read
        attachment.filesTotal = files.count
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

/// The folder's top-level .gitignore, simplified: names and globs, with a trailing "/" for folders only.
struct GitIgnore {
    private var patterns: [(glob: String, folderOnly: Bool, anchored: Bool)] = []

    init(root: URL) {
        guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            let folderOnly = line.hasSuffix("/")
            if folderOnly { line.removeLast() }
            let anchored = line.hasPrefix("/") || line.dropFirst().contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            if !line.isEmpty { patterns.append((line, folderOnly, anchored)) }
        }
    }

    func ignores(_ path: String, folder: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        return patterns.contains { pattern in
            if pattern.folderOnly && !folder { return false }
            return pattern.anchored ? Self.match(pattern.glob, path) : Self.match(pattern.glob, name)
        }
    }

    private static func match(_ glob: String, _ text: String) -> Bool {
        fnmatch(glob, text, 0) == 0
    }
}
