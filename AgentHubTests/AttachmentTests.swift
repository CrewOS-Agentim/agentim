import AppKit
import PDFKit
import XCTest
@testable import AgentHub

final class AttachmentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ChatAttachment.storeDirectory = dir.appendingPathComponent("saved-images")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testTextAndCodeFilesAreRead() throws {
        let swift = try ChatAttachment.load(file("main.swift", Data("print(\"hi\")".utf8)))
        XCTAssertEqual(swift.kind, .text)
        XCTAssertEqual(swift.text, "print(\"hi\")")
        XCTAssertEqual(swift.promptBlock(), "<file name=\"main.swift\">\nprint(\"hi\")\n</file>")
        let csv = try ChatAttachment.load(file("data.csv", Data("a,b\n1,2".utf8)))
        XCTAssertTrue(csv.isReadable)
    }

    func testLongFilesAreTruncated() throws {
        let long = String(repeating: "x", count: ChatAttachment.maxTextCharacters + 10)
        let attachment = try ChatAttachment.load(file("big.txt", Data(long.utf8)))
        XCTAssertTrue(attachment.truncated)
        XCTAssertEqual(attachment.text?.count, ChatAttachment.maxTextCharacters)
        XCTAssertTrue(attachment.promptBlock().contains("truncated=\"true\""))
    }

    func testBinaryFilesAreNamedOnlyAndImagesAreSaved() throws {
        let binary = try ChatAttachment.load(file("blob.bin", Data([0x00, 0x01, 0xFF, 0x00])))
        XCTAssertFalse(binary.isReadable)
        XCTAssertTrue(binary.promptBlock().contains("blob.bin"))
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let image = try ChatAttachment.load(file("cat.png", png))
        XCTAssertEqual(image.kind, .image)
        // Text-only models get the name; models that see get the image with a short note.
        XCTAssertTrue(image.promptBlock().contains("Attached image \"cat.png\""))
        XCTAssertEqual(image.promptBlock(withImage: true), "[Image \"cat.png\" attached.]")
        XCTAssertTrue(image.isReadable)
        XCTAssertNotNil(image.imageBase64())
        XCTAssertEqual(image.imageURL?.pathExtension, "jpg")
    }

    func testPDFTextIsExtracted() throws {
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "Quarterly revenue grew").draw(at: CGPoint(x: 20, y: 100))
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
        let pdf = try ChatAttachment.load(file("report.pdf", pdfData as Data))
        XCTAssertEqual(pdf.kind, .pdf)
        XCTAssertTrue(pdf.text?.contains("Quarterly revenue") ?? false)
    }

    func testEmptyFoldersAndHugeFilesAreRejected() throws {
        XCTAssertThrowsError(try ChatAttachment.load(dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no text or code files"))
        }
        let big = dir.appendingPathComponent("huge.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ChatAttachment.maxFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try ChatAttachment.load(big)) { error in
            XCTAssertTrue(error.localizedDescription.contains("20 MB"))
        }
    }

    func testModelContentIncludesFiles() {
        var message = ChatMessage(role: .user, content: "Review this")
        XCTAssertEqual(message.modelContent, "Review this")
        var file = ChatAttachment(name: "a.py", kind: .text, byteCount: 5)
        file.setText("x = 1")
        message.attachments = [file]
        XCTAssertEqual(message.modelContent, "Review this\n\n<file name=\"a.py\">\nx = 1\n</file>")
        message.content = ""
        XCTAssertEqual(message.modelContent, "<file name=\"a.py\">\nx = 1\n</file>")
    }

    func testOldSavedMessagesStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","content":"hi","createdAt":0,"isError":false}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.attachments)
        XCTAssertEqual(message.modelContent, "hi")
    }

    func testComposerRules() throws {
        XCTAssertFalse(ChatComposer.canSend(draft: "  \n", attachments: []))
        XCTAssertTrue(ChatComposer.canSend(draft: "hi", attachments: []))
        let url = try file("notes.md", Data("# Notes".utf8))
        let added = ChatComposer.add([url, url], to: [])
        XCTAssertEqual(added.attachments.count, 1, "the same file isn't added twice")
        XCTAssertTrue(ChatComposer.canSend(draft: "", attachments: added.attachments), "files alone can be sent")
        let full = Array(repeating: ChatAttachment(name: "x", kind: .text, byteCount: 1), count: ChatAttachment.maxFiles)
        XCTAssertNotNil(ChatComposer.add([url], to: full).error)
        let folder = ChatComposer.add([dir, dir], to: [])
        XCTAssertEqual(folder.attachments.map(\.kind), [.folder], "a folder attaches once, as a codebase")
    }
}
