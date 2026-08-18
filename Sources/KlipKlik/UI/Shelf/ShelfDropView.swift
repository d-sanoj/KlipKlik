import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The view that actually receives drops, sitting behind a shelf's SwiftUI body.
///
/// SwiftUI's own `onDrop` was not enough for this. It hands back `NSItemProvider`s,
/// which covers files and raw data but not `NSFilePromiseReceiver` — and promises
/// are the case that matters most, because Photos, Mail, and every browser hand
/// over a promise rather than a path. A shelf that ignored them would look broken
/// in exactly the applications people drag out of.
///
/// Three shapes of payload arrive here, and they are tried in order of how much
/// they cost:
///
/// 1. **File URLs** — already on disk. Shelved by reference; nothing is copied.
/// 2. **Promises** — the source will write the file if asked. Received into a
///    scratch directory, then staged, because the scratch is reclaimed the moment
///    the drag ends.
/// 3. **Raw data** — an image or a text selection with no file anywhere. Written
///    into staging under an invented name.
final class ShelfDropView: NSView {
    /// Files that already exist and should be referenced (copy) or staged (move).
    var onDropFiles: (([URL]) -> Void)?
    /// Same payload as `onDropFiles`, used when the drop landed on the Move half.
    var onDropMovingFiles: (([URL]) -> Void)?
    /// A file received from a promise or written from raw data. Called once per
    /// item, on the main queue, and the URL is a scratch file the receiver is
    /// expected to take ownership of.
    var onDropStagedFile: ((URL) -> Void)?
    /// Highlight state, so the shelf can show it is a live target.
    var onTargetingChanged: ((Bool) -> Void)?
    /// When set, the pad splits into Copy (left) and Move (right).
    var splitMidX: (() -> CGFloat)?
    /// `true` for Move, `false` for Copy, `nil` when the drag leaves.
    var onHoverMove: ((Bool?) -> Void)?

    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.sanoj.KlipKlik.filepromise"
        return queue
    }()

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static var acceptedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .URL, .png, .tiff, .pdf, .rtf, .string, .fileContents
        ]
        types += NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType(rawValue: $0)
        }
        return types
    }

    private var hoverMove = false

    // MARK: Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !(sender.draggingSource is FileDragSourceView) else { return [] }
        onTargetingChanged?(true)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !(sender.draggingSource is FileDragSourceView) else { return [] }
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hoverMove = false
        onHoverMove?(nil)
        onTargetingChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hoverMove = false
        onHoverMove?(nil)
        onTargetingChanged?(false)
    }

    /// Copy vs Move only chooses what the shelf *will* do later. The drop itself
    /// is always a copy, so the original stays in place until the file is
    /// dragged out of a Move shelf.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let move = isOnMoveSide(sender)
        if hoverMove != move {
            hoverMove = move
            onHoverMove?(move)
        }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    /// The pad window *is* the island, so the split is the view's own midline.
    /// Converting through the island's flipped coordinates was landing every
    /// drop on the same half, which is why Copy and Move used to do the same thing.
    private func isOnMoveSide(_ sender: NSDraggingInfo) -> Bool {
        guard splitMidX != nil else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        return x >= bounds.midX
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetingChanged?(false)
        let pasteboard = sender.draggingPasteboard

        // 1. Real files. The common case, and the cheapest — a path each.
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        if !urls.isEmpty {
            let files = urls.map(\.standardizedFileURL)
            // Recompute from this event — don't trust `hoverMove`, which can be
            // stale if `draggingEnded` ran first on some system versions.
            if isOnMoveSide(sender) {
                onDropMovingFiles?(files)
            } else {
                onDropFiles?(files)
            }
            return true
        }

        // 2. Promises.
        if receivePromises(sender) { return true }

        // 3. Raw data with no file behind it.
        return stageRawContent(pasteboard)
    }

    // MARK: Promises

    /// Asks the source to write its promised files, then hands each one on.
    ///
    /// The destination has to be a directory that outlives the drag, and it must
    /// not be the shelf's own staging tree: the receiver writes with whatever
    /// name the source chooses, and two sources can easily choose the same one.
    /// A per-drag scratch directory keeps them apart, and staging copies out of
    /// it under an id.
    private func receivePromises(_ sender: NSDraggingInfo) -> Bool {
        var receivers: [NSFilePromiseReceiver] = []
        sender.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSFilePromiseReceiver.self],
            searchOptions: [:]
        ) { item, _, _ in
            if let receiver = item.item as? NSFilePromiseReceiver { receivers.append(receiver) }
        }

        guard !receivers.isEmpty else { return false }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlipKlik-drop-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )) != nil else { return false }

        // One receiver can promise several files, and each completes separately,
        // so the scratch directory is only removed once every receiver is done.
        let group = DispatchGroup()
        for receiver in receivers {
            // A receiver promising nothing never calls back, so entering the
            // group for it would leave the scratch directory on disk forever.
            guard !receiver.fileNames.isEmpty else { continue }

            group.enter()
            var pending = receiver.fileNames.count
            let lock = NSLock()

            receiver.receivePromisedFiles(
                atDestination: scratch,
                options: [:],
                operationQueue: promiseQueue
            ) { url, error in
                if error == nil {
                    DispatchQueue.main.async { self.onDropStagedFile?(url) }
                }
                lock.lock()
                pending -= 1
                let finished = pending <= 0
                lock.unlock()
                if finished { group.leave() }
            }
        }

        group.notify(queue: .main) {
            try? FileManager.default.removeItem(at: scratch)
        }
        return true
    }

    // MARK: Raw content

    /// Writes a dragged image, snippet, or link into a scratch file so it can be
    /// staged like anything else.
    private func stageRawContent(_ pasteboard: NSPasteboard) -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlipKlik-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        guard let (data, name) = Self.rawContent(pasteboard) else {
            try? FileManager.default.removeItem(at: scratch)
            return false
        }

        let url = scratch.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: scratch)
            return false
        }

        onDropStagedFile?(url)
        // The handler copies out of here synchronously on the main queue, so the
        // scratch can go as soon as the next turn of the loop.
        DispatchQueue.main.async { try? FileManager.default.removeItem(at: scratch) }
        return true
    }

    /// Bytes and a filename for whatever flavour is richest, in that order.
    private static func rawContent(_ pasteboard: NSPasteboard) -> (Data, String)? {
        let stamp = filenameStamp()

        if let data = pasteboard.data(forType: .png) {
            return (data, "Image \(stamp).png")
        }
        // TIFF is what most apps put on the pasteboard for an image; PNG is a
        // far more useful thing to have on disk, so it is re-encoded rather than
        // written out as a 20 MB TIFF nobody asked for.
        if let data = pasteboard.data(forType: .tiff) {
            let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            return ((png ?? data), "Image \(stamp).\(png == nil ? "tiff" : "png")")
        }
        if let data = pasteboard.data(forType: .pdf) {
            return (data, "Document \(stamp).pdf")
        }

        let text = pasteboard.string(forType: .string)

        // A dragged link becomes a .webloc, which is the file Finder makes when
        // you drag a URL to the desktop — double-clicking it opens the page.
        if let text, let webloc = weblocData(for: text) {
            return (webloc, "\(weblocName(for: text)).webloc")
        }
        if let data = pasteboard.data(forType: .rtf) {
            return (data, "Text \(stamp).rtf")
        }
        if let text, !text.isEmpty, let data = text.data(using: .utf8) {
            return (data, "Text \(stamp).txt")
        }
        return nil
    }

    private static func weblocData(for text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }

        return try? PropertyListSerialization.data(
            fromPropertyList: ["URL": trimmed], format: .xml, options: 0
        )
    }

    /// "github.com" rather than the whole URL — a filename made of a query string
    /// is unreadable and often too long for the filesystem.
    private static func weblocName(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed)?.host ?? "Link"
        return host.replacingOccurrences(of: "/", with: "-")
    }

    private static func filenameStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// Puts a `ShelfDropView` behind a SwiftUI shelf body.
struct ShelfDropCatcher: NSViewRepresentable {
    let onFiles: ([URL]) -> Void
    let onStagedFile: (URL) -> Void
    let onTargeting: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfDropView {
        let view = ShelfDropView()
        view.onDropFiles = onFiles
        view.onDropStagedFile = onStagedFile
        view.onTargetingChanged = onTargeting
        return view
    }

    func updateNSView(_ view: ShelfDropView, context: Context) {
        view.onDropFiles = onFiles
        view.onDropStagedFile = onStagedFile
        view.onTargetingChanged = onTargeting
    }
}
