import AppKit

/// Notices that a drag has started anywhere on the system, without asking for a
/// single permission.
///
/// The two obvious routes are both dead ends here. A `CGEventTap` on mouse
/// events needs Accessibility, which would make the shelf inert on first launch
/// and dead again after every rebuild — the exact failure mode documented for
/// `⌘⌘` and cut-and-move. `NSEvent.addGlobalMonitorForEvents` needs no
/// permission for mouse events, but it does not observe the modal tracking loop
/// the *source* application runs for the whole duration of a drag, which is
/// precisely the window we care about.
///
/// Polling three free global queries does the entire job:
///
/// * `NSEvent.pressedMouseButtons` — is a button down right now? A window-server
///   state query rather than an event, so nothing gates it.
/// * `NSPasteboard(name: .drag)` — the source application writes the dragged
///   items to the shared drag pasteboard when it opens a session. A change to its
///   `changeCount` while the button is held means a drag just began, and the
///   pasteboard itself says what is in it.
/// * `NSEvent.mouseLocation` — where to put the landing pad.
///
/// The cost is one timer holding one integer comparison. The pasteboard is read
/// once per drag, on the tick where the count moves, not on every tick.
final class DragWatcher {
    /// What the drag is carrying, as far as a shelf cares.
    struct Payload {
        /// Real files already on disk. Shelved by reference, never copied.
        let fileURLs: [URL]
        /// True when the drag carries something with no file behind it — an
        /// image from a web page, a text selection, a promised file. Those have
        /// to be staged, and only on drop, so they are not read here.
        let hasStageableContent: Bool

        var isEmpty: Bool { fileURLs.isEmpty && !hasStageableContent }
    }

    /// A drag started. Fired once per session, with the pointer at that moment.
    var onDragBegan: ((Payload, NSPoint) -> Void)?
    /// The mouse button came up, whatever happened in between.
    var onDragEnded: (() -> Void)?

    /// 25 Hz. Fast enough that the pad is up before the pointer has travelled
    /// far, slow enough to be free — the per-tick cost is one `CGEvent` state
    /// read, and the pasteboard is only touched when that read says to.
    private static let interval: TimeInterval = 0.04

    private var timer: Timer?
    private var wasButtonDown = false
    private var baselineChangeCount = 0
    private var sessionReported = false
    /// Set while a shelf is itself the drag source, so dragging an item *off* a
    /// shelf does not immediately offer to put it on another one.
    private var suppressionDepth = 0

    var isSuppressed: Bool { suppressionDepth > 0 }

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common, or polling stops the moment any menu or tracking loop opens —
        // which includes the drag loop this exists to observe.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        wasButtonDown = false
        sessionReported = false
    }

    deinit { stop() }

    /// Call around a drag KlipKlick itself starts. Balanced, because a drag from
    /// one shelf onto another nests.
    func beginSuppression() { suppressionDepth += 1 }
    func endSuppression() { suppressionDepth = max(0, suppressionDepth - 1) }

    // MARK: Polling

    private func poll() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0

        if isDown, !wasButtonDown {
            // Snapshot before anything is dragged, so the next change to the
            // count is unambiguously this drag and not the last one's residue.
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            sessionReported = false
        }

        if !isDown, wasButtonDown {
            if sessionReported { onDragEnded?() }
            sessionReported = false
        }

        wasButtonDown = isDown
        // Once reported there is nothing left to watch for until the button
        // comes up: the pad does not follow the pointer, deliberately.
        guard isDown, !isSuppressed, !sessionReported else { return }

        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount else { return }

        // The count moved, so a session is open. Read it once; if the source has
        // written the count but not yet the contents, leave the baseline where
        // it is and the next tick will look again.
        let payload = Self.read(pasteboard)
        guard !payload.isEmpty else { return }

        sessionReported = true
        onDragBegan?(payload, NSEvent.mouseLocation)
    }

    /// What is on the drag pasteboard, classified into "already a file" and
    /// "will need staging".
    private static func read(_ pasteboard: NSPasteboard) -> Payload {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        let types = pasteboard.types ?? []
        // File promises are the case that matters most: Photos, Mail and every
        // browser hand over a promise rather than a path, and a shelf that
        // ignored them would look broken in exactly the apps people drag from.
        let stageable: [NSPasteboard.PasteboardType] = [
            .fileContents, .tiff, .png, .rtf, .string, .URL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        ]

        return Payload(
            fileURLs: urls.map(\.standardizedFileURL),
            hasStageableContent: types.contains(where: stageable.contains)
        )
    }
}
