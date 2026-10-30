import AppKit
import XCTest
@testable import AgentHub

/// Folders (codebases), documents, images to models that see them, and pasting.
final class UploadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ChatAttachment.storeDirectory = dir.appendingPathComponent("saved-images")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func pngData() -> Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
    }

    // MARK: Folders

    func testCodebaseIsReadWithoutDependenciesBuildOutputOrSecrets() throws {
        let repo = dir.appendingPathComponent("shop")
        try write("README.md", "# Shop", in: repo)
        try write("package.json", "{\"name\": \"shop\"}", in: repo)
        try write("src/app.ts", "export const app = 1", in: repo)
        try write("src/generated/schema.ts", "generated", in: repo)
        try write(".gitignore", "src/generated/\n*.log\n", in: repo)
        try write("debug.log", "noise", in: repo)
        try write("node_modules/react/index.js", "dependency", in: repo)
        try write(".git/config", "[core]", in: repo)
        try write("dist/bundle.js", "built", in: repo)
        try write(".env", "SECRET=1", in: repo)
        try write("certs/server.pem", "-----BEGIN PRIVATE KEY-----", in: repo)
        try write("package-lock.json", "{}", in: repo)
        try write(".github/workflows/ci.yml", "on: push", in: repo)

        let folder = try ChatAttachment.load(repo)
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.name, "shop/")
        let text = try XCTUnwrap(folder.text)
        for kept in ["README.md", "package.json", "src/app.ts", ".github/workflows/ci.yml", ".gitignore"] {
            XCTAssertTrue(text.contains("<file path=\"\(kept)\""), kept)
        }
        for skipped in ["path=\"src/generated", "path=\"debug.log", "dependency", "[core]", "built", "SECRET", "PRIVATE KEY", "package-lock"] {
            XCTAssertFalse(text.contains(skipped), skipped)
        }
        // Key files first, the tree on top.
        XCTAssertTrue(text.hasPrefix("<tree>"))
        let readme = try XCTUnwrap(text.range(of: "path=\"README.md\"")), app = try XCTUnwrap(text.range(of: "path=\"src/app.ts\""))
        XCTAssertLessThan(readme.lowerBound, app.lowerBound)
        XCTAssertEqual(folder.filesRead, 5)
        XCTAssertFalse(folder.truncated)
        XCTAssertTrue(folder.promptBlock().hasPrefix("<folder name=\"shop/\" files_read=\"5\""))
        XCTAssertEqual(folder.sizeLabel, "5 files")
    }

    func testBigCodebaseStaysWithinTheBudget() throws {
        let repo = dir.appendingPathComponent("big")
        for i in 0..<12 { try write("src/file\(i).swift", String(repeating: "let x = \(i)\n", count: 400), in: repo) }
        let folder = try ChatAttachment.loadFolder(repo, budget: 10_000)
        XCTAssertTrue(folder.truncated)
        XCTAssertLessThan(folder.filesRead ?? 0, 12)
        XCTAssertEqual(folder.filesTotal, 12)
        XCTAssertTrue(folder.text?.contains("src/file11.swift") ?? false, "the tree still lists every file")
    }

    func testGitIgnoreRules() throws {
        try "build/\n/secret.txt\n*.tmp\n# comment\n!keep.tmp\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let ignore = GitIgnore(root: dir)
        XCTAssertTrue(ignore.ignores("build", folder: true))
        XCTAssertFalse(ignore.ignores("build", folder: false), "build/ only matches folders")
        XCTAssertTrue(ignore.ignores("secret.txt", folder: false))
        XCTAssertFalse(ignore.ignores("docs/secret.txt", folder: false), "/secret.txt is anchored to the root")
        XCTAssertTrue(ignore.ignores("a/b/c.tmp", folder: false))
        XCTAssertFalse(ignore.ignores("main.swift", folder: false))
    }

    // MARK: Documents

    func testWordAndRichTextDocumentsAreRead() throws {
        let text = NSAttributedString(string: "Launch plan: ship on Friday")
        let rtf = try text.data(from: NSRange(location: 0, length: text.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfURL = dir.appendingPathComponent("plan.rtf")
        try rtf.write(to: rtfURL)
        let docx = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let docxURL = dir.appendingPathComponent("plan.docx")
        try docx.write(to: docxURL)

        for url in [rtfURL, docxURL] {
            let document = try ChatAttachment.load(url)
            XCTAssertEqual(document.kind, .document, url.lastPathComponent)
            XCTAssertTrue(document.text?.contains("ship on Friday") ?? false, url.lastPathComponent)
        }
    }

    // MARK: Images to models

    func testImagesGoOnlyToModelsThatSeeThemAndOnlyRecentOnes() throws {
        let url = dir.appendingPathComponent("screen.png")
        try pngData().write(to: url)
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(ChatMessage(role: .user, content: "look \(i)", attachments: [try ChatAttachment.load(url)]))
            messages.append(ChatMessage(role: .assistant, content: "ok"))
        }

        let blind = ChatRequest(model: "m", system: "", messages: messages).wireMessages()
        XCTAssertTrue(blind.allSatisfy { $0.images.isEmpty })
        XCTAssertTrue(blind[0].text.contains("Attached image \"screen.png\""))

        let seeing = ChatRequest(model: "m", system: "", messages: messages, sendImages: true).wireMessages()
        XCTAssertEqual(seeing.filter { !$0.images.isEmpty }.count, ChatRequest.imageMessages, "only the latest few carry images")
        XCTAssertTrue(seeing.last { $0.role == .user }!.text.contains("[Image \"screen.png\" attached.]"))
        XCTAssertTrue(seeing[0].images.isEmpty, "older images are named only")
        XCTAssertNotNil(Data(base64Encoded: seeing.last { $0.role == .user }!.images[0]))
    }

    func testWhichModelsSeeImages() {
        let sees = { (model: AIModel) in model.canSeeImages }
        XCTAssertTrue(sees(AIModel.cloudCatalog.first { $0.alias == "sonnet" }!))
        XCTAssertTrue(sees(AIModel.cloudCatalog.first { $0.alias == "gemini" }!))
        XCTAssertTrue(sees(AIModel.cloudCatalog.first { $0.alias == "gpt5" }!))
        XCTAssertTrue(sees(AIModel.cloudCatalog.first { $0.alias == "qwen35" }!))
        XCTAssertFalse(sees(AIModel.cloudCatalog.first { $0.alias == "deepseek" }!))
        XCTAssertFalse(sees(AIModel.cloudCatalog.first { $0.alias == "llama70" }!))

        let server = LocalServer(name: "Docker", baseURL: URL(string: "http://localhost:8765")!)
        func onServer(_ id: String, kind: String? = nil) -> AIModel {
            AIModel.server(ServerModelInfo(id: id, kind: kind, size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
        }
        XCTAssertTrue(sees(onServer("hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M")))
        XCTAssertTrue(sees(onServer("hf.co/unsloth/gemma-3-12b-it-GGUF:Q4_K_M")))
        XCTAssertTrue(sees(onServer("hf.co/stefans71/frontend-design-expert-8b:Q4_K_M")))
        XCTAssertFalse(sees(onServer("hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M")))
        XCTAssertFalse(sees(onServer("hf.co/unsloth/gemma-3-1b-it-GGUF:Q4_K_M")))
        XCTAssertFalse(sees(onServer("claude/sonnet", kind: "claude")), "Claude through the login is a text prompt")
        XCTAssertFalse(sees(onServer("chatgpt/default", kind: "chatgpt")))
        XCTAssertFalse(sees(AIModel.suggestedLocal[0]), "on-device MLX models are text-only")
    }

    // MARK: Paste

    func testPastingAScreenshotOrFiles() throws {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }

        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertNil(ChatComposer.paste(board, to: []), "text pastes as text")

        board.clearContents()
        board.setData(pngData(), forType: .png)
        let pasted = try XCTUnwrap(ChatComposer.paste(board, to: []))
        XCTAssertEqual(pasted.attachments.map(\.name), ["Pasted image 1.jpg"])
        XCTAssertNotNil(pasted.attachments[0].imageURL)
        XCTAssertEqual(ChatComposer.paste(board, to: pasted.attachments)?.attachments.last?.name, "Pasted image 2.jpg")

        let notes = dir.appendingPathComponent("notes.md")
        try "# Notes".write(to: notes, atomically: true, encoding: .utf8)
        board.clearContents()
        board.writeObjects([notes as NSURL])
        XCTAssertEqual(ChatComposer.paste(board, to: [])?.attachments.first?.text, "# Notes")
    }
}
