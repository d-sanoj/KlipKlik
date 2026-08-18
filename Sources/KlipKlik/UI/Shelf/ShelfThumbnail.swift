import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Thumbnails for shelf tiles, generated once and kept.
///
/// `QLThumbnailGenerator` produces the same preview Finder shows — a frame from
/// a video, the first page of a PDF, the image itself — which is the difference
/// between a shelf you can read at a glance and a row of identical document
/// icons. It is also slow enough that regenerating on every SwiftUI redraw would
/// be visible, hence the cache.
///
/// The generic file icon is returned immediately and replaced when the real
/// thumbnail arrives, so a tile never renders empty.
final class ShelfThumbnails: ObservableObject {
    static let shared = ShelfThumbnails()

    /// Keyed by item id rather than path: a staged file can be replaced under
    /// the same name, and two shelves can reference one path.
    @Published private var cache: [UUID: NSImage] = [:]
    private var inFlight: Set<UUID> = []

    private static let size = CGSize(width: 96, height: 96)

    func image(for item: ShelfItem) -> NSImage {
        if let cached = cache[item.id] { return cached }
        request(item)
        return NSWorkspace.shared.icon(forFile: item.url.path)
    }

    private func request(_ item: ShelfItem) {
        guard !inFlight.contains(item.id), item.stillExists else { return }
        inFlight.insert(item.id)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: Self.size,
            scale: scale,
            // `.all` lets the generator fall back to the icon when a file has no
            // real preview, so the completion always carries something usable.
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = NSImage(cgImage: rep.cgImage, size: Self.size)
            DispatchQueue.main.async {
                self?.inFlight.remove(item.id)
                self?.cache[item.id] = image
            }
        }
    }

    func forget(_ id: UUID) {
        cache[id] = nil
        inFlight.remove(id)
    }
}
