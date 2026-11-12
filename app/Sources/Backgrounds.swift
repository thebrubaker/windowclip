// Backgrounds — the user's saved backgrounds and which one recordings use (DIG-2643).
//
// A folder, not a library: images under `Backgrounds/`, one level of subfolders
// as groups (a brand, a project), so adding one is a Finder drag as much as a
// menu item. The choice lives in `background.json` beside the recents, for the
// same reason they do: the file is what a test reads back.
//
// The CLI's --headless path reads this same folder and file (src/cli.ts), so
// the listing rules below have a twin there.

import AppKit
import ImageIO

struct Background: Equatable {
    /// Path relative to the folder ("Onlook/1B-eclipse.png"); "default" for the bundled one.
    let id: String
    let name: String
    let group: String?
    let url: URL

    static let defaultID = "default"
    var isDefault: Bool { id == Self.defaultID }
}

@MainActor
final class Backgrounds {
    static let shared = Backgrounds()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"]

    let folder: URL
    private let selectionURL: URL
    private let thumbnails = ThumbnailCache()

    init(root: URL = AppSupport.directory) {
        folder = root.appendingPathComponent("Backgrounds", isDirectory: true)
        selectionURL = root.appendingPathComponent("background.json")
    }

    var bundledDefault: Background? {
        Recorder.defaultBackgroundURL.map {
            Background(id: Background.defaultID, name: "Big Sur", group: nil, url: $0)
        }
    }

    /// Loose files first, then each group; names in Finder order within each.
    func saved() -> [Background] {
        let fm = FileManager.default
        var loose: [Background] = []
        var grouped: [String: [Background]] = [:]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let top = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: options
        )) ?? []
        for entry in top {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let group = entry.lastPathComponent
                let files = (try? fm.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: options
                )) ?? []
                grouped[group] = files.compactMap { background(at: $0, group: group) }
            } else if let item = background(at: entry, group: nil) {
                loose.append(item)
            }
        }
        let byName: (Background, Background) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var result = loose.sorted(by: byName)
        for group in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            result += grouped[group]!.sorted(by: byName)
        }
        return result
    }

    private func background(at url: URL, group: String?) -> Background? {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let file = url.lastPathComponent
        return Background(
            id: group.map { "\($0)/\(file)" } ?? file,
            name: url.deletingPathExtension().lastPathComponent,
            group: group,
            url: url
        )
    }

    /// The saved choice, or the bundled default when nothing is chosen or the
    /// chosen file has gone.
    var current: Background? {
        if let id = selectedID, let chosen = saved().first(where: { $0.id == id }) {
            return chosen
        }
        return bundledDefault
    }

    func select(_ background: Background) {
        let body = background.isDefault ? [String: String]() : ["selected": background.id]
        do {
            try FileManager.default.createDirectory(
                at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: selectionURL, options: .atomic)
            note("background → \(background.id)")
        } catch {
            note("could not save the background choice: \(error.localizedDescription)")
        }
    }

    private var selectedID: String? {
        guard let data = try? Data(contentsOf: selectionURL),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return body["selected"] as? String
    }

    /// A per-recording request: "default", a saved id or name, or a path to an image.
    func resolve(_ request: String) -> Background? {
        if request == Background.defaultID { return bundledDefault }
        let all = saved()
        if let byID = all.first(where: { $0.id == request }) { return byID }
        if let byName = all.first(where: {
            $0.name.caseInsensitiveCompare(request) == .orderedSame
                || $0.url.lastPathComponent.caseInsensitiveCompare(request) == .orderedSame
        }) { return byName }
        let path = URL(fileURLWithPath: (request as NSString).expandingTildeInPath)
        guard path.path.hasPrefix("/"),
              Self.imageExtensions.contains(path.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: path.path)
        else { return nil }
        return Background(id: path.path, name: path.deletingPathExtension().lastPathComponent, group: nil, url: path)
    }

    // MARK: - Adding

    /// Copies each image into the folder, byte for byte. Anything that doesn't
    /// decode as an image is skipped, so the recorder can never be handed a file
    /// it would silently replace with its fallback gradient.
    func importFiles(_ urls: [URL]) -> [Background] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [Background] = []
        for source in urls {
            guard Self.imageExtensions.contains(source.pathExtension.lowercased()),
                  let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetCount(image) > 0
            else {
                note("not an image, skipped: \(source.path)")
                continue
            }
            let destination = uniqueDestination(for: source)
            do {
                try fm.copyItem(at: source, to: destination)
                if let item = background(at: destination, group: nil) { added.append(item) }
            } catch {
                note("could not add \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return added
    }

    private func uniqueDestination(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: - Thumbnails

    /// Never decodes on the caller's thread: a 17 MB PNG takes ~200 ms. Missing
    /// thumbnails come back as a swatch and are made in the background.
    func thumbnail(for background: Background) -> NSImage {
        thumbnails.image(for: background.url)
    }

    func warmThumbnails() {
        for item in [bundledDefault].compactMap({ $0 }) + saved() {
            _ = thumbnails.image(for: item.url)
        }
    }

    func payload() -> [String: Any] {
        let current = self.current
        let items = ([bundledDefault].compactMap { $0 } + saved()).map { item -> [String: Any] in
            var entry: [String: Any] = [
                "id": item.id, "name": item.name, "path": item.url.path,
                "current": item.id == current?.id,
            ]
            if let group = item.group { entry["group"] = group }
            return entry
        }
        return ["ok": true, "current": current?.id ?? NSNull(), "folder": folder.path, "items": items]
    }
}

/// Menu-sized, centre-cropped to the recording's 16:9, so each row previews
/// what a recording will actually show.
@MainActor
final class ThumbnailCache {
    nonisolated static let size = NSSize(width: 48, height: 27)

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let bytes: Int?
    }

    private var images: [Key: NSImage] = [:]
    private var inFlight: Set<Key> = []
    private let queue = DispatchQueue(label: "backgrounds.thumbnails", qos: .utility)

    func image(for url: URL) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(path: url.path, modified: values?.contentModificationDate, bytes: values?.fileSize)
        if let ready = images[key] { return ready }
        if !inFlight.contains(key) {
            inFlight.insert(key)
            queue.async {
                let cg = Self.render(url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.inFlight.remove(key)
                        if let cg { self.images[key] = NSImage(cgImage: cg, size: Self.size) }
                    }
                }
            }
        }
        return Self.swatch
    }

    private nonisolated static func render(_ url: URL) -> CGImage? {
        let pixelW = Int(size.width * 2)
        let pixelH = Int(size.height * 2)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelW * 4,
              ] as CFDictionary)
        else { return nil }
        let w = CGFloat(decoded.width)
        let h = CGFloat(decoded.height)
        let target = CGFloat(16) / 9
        let crop = w / h > target
            ? CGRect(x: (w - h * target) / 2, y: 0, width: h * target, height: h)
            : CGRect(x: 0, y: (h - w / target) / 2, width: w, height: w / target)
        guard let cropped = decoded.cropping(to: crop.integral),
              let context = CGContext(
                  data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        context.draw(cropped, in: bounds)
        return context.makeImage()
    }

    private static let swatch: NSImage = {
        NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }()
}
