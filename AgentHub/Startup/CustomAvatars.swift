import AppKit
import Foundation

/// Avatars the founder picked or generated for a startup's agents, stored on this Mac:
/// ~/Library/Application Support/agentim/avatars/<startup id>/<agent key>.png
enum CustomAvatars {
    static var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("agentim/avatars", isDirectory: true)

    private static var cache: [String: NSImage] = [:]

    static func url(startup: String, key: String) -> URL {
        root.appendingPathComponent(safe(startup), isDirectory: true).appendingPathComponent("\(safe(key)).png")
    }

    static func image(startup: String?, key: String) -> NSImage? {
        guard let startup else { return nil }
        let url = url(startup: startup, key: key)
        if let hit = cache[url.path] { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = image
        return image
    }

    /// Saves `image` as a 512×512 center-cropped PNG.
    static func save(_ image: NSImage, startup: String, key: String) throws {
        let url = url(startup: startup, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let png = squarePNG(image) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        cache[url.path] = NSImage(data: png)
    }

    static func remove(startup: String, key: String) {
        let url = url(startup: startup, key: key)
        try? FileManager.default.removeItem(at: url)
        cache[url.path] = nil
    }

    /// Center-crops to a square and scales to `size`.
    static func squarePNG(_ image: NSImage, size: CGFloat = 512) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let square = cg.cropping(to: crop),
              let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    private static func safe(_ component: String) -> String {
        component.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
    }
}

extension Avatars {
    /// A startup agent's avatar: the founder's custom one if set, else the bundled one for the role.
    static func teamMember(_ key: String, startup: String?) -> NSImage? {
        CustomAvatars.image(startup: startup, key: key) ?? teamMember(key)
    }
}
