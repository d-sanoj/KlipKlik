import AppKit
import Quartz
import UniformTypeIdentifiers

/// What a shelf can do with its contents besides being dragged out of.
///
/// Everything here operates on plain file URLs, so it works the same for a
/// referenced file and a staged one.
enum ShelfActions {
    /// Called with the change count of every pasteboard write made here.
    ///
    /// `ShelfManager` sets it and forwards to `ClipboardMonitor`. A stored hook
    /// rather than a parameter threaded through five layers of SwiftUI: the
    /// views calling `copyToClipboard` have no business knowing the monitor
    /// exists, and there is exactly one monitor to tell.
    static var onPasteboardWrite: ((Int) -> Void)?

    // MARK: Finder

    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// Applications that claim the first item, for an "Open With" submenu.
    static func openers(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    static func open(_ urls: [URL], withApplicationAt application: URL) {
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: Pasteboard

    /// Puts the files on the clipboard, exactly as a Finder ⌘C would.
    ///
    /// Returns the change count so `ClipboardMonitor` can be told this was our
    /// own write — otherwise every "Copy" here reappears as a new history entry.
    @discardableResult
    static func copyToClipboard(_ urls: [URL]) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        onPasteboardWrite?(pasteboard.changeCount)
        return pasteboard.changeCount
    }

    @discardableResult
    static func copyPaths(_ urls: [URL]) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        onPasteboardWrite?(pasteboard.changeCount)
        return pasteboard.changeCount
    }

    // MARK: Move into the front Finder window

    /// Whether "Move to Front Finder Window" can run right now.
    static var canMoveToFrontFinderWindow: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
            && AccessibilityPermission.isTrusted
    }

    /// Moves the shelf's files into whatever folder Finder is showing.
    ///
    /// This is the same trick `FinderCutMove` uses for ⌘X, and for the same
    /// reason: Finder's own "Move Item Here" already has conflict resolution, a
    /// progress sheet, and undo. Copying the files ourselves and unlinking the
    /// originals would mean reimplementing all three, badly, and would put the
    /// user's data behind our error handling instead of Apple's.
    ///
    /// So the files go on the pasteboard and Finder is sent ⌥⌘V. It needs
    /// Accessibility for the synthesised keystroke — the one place in the shelf
    /// that does.
    ///
    /// `completion` reports whether the keystroke was sent, not whether the move
    /// succeeded: only Finder knows that, and it tells the user directly.
    static func moveToFrontFinderWindow(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        guard canMoveToFrontFinderWindow, !urls.isEmpty else {
            completion(false)
            return
        }

        copyToClipboard(urls)

        // Finder needs the pasteboard settled before the keystroke lands, the
        // same 0.3s beat cut-and-move waits for its copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Paster.pasteMovingFiles()
            completion(true)
        }
    }

    // MARK: Quick Look

    /// Previews the files in the system Quick Look panel.
    static func quickLook(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        QuickLookSource.shared.urls = urls
        panel.dataSource = QuickLookSource.shared
        panel.delegate = QuickLookSource.shared
        // The panel is a real window and will not show over a background app, so
        // this is the one action that has to bring KlipKlik forward.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Compress

    /// Zips the shelf into one archive next to the first item, or on the Desktop
    /// when the items are staged and have no meaningful "next to".
    ///
    /// Shells out to `ditto` rather than using `NSFileCoordinator`'s zip service:
    /// `ditto -c -k --sequesterRsrc --keepParent` is what Finder's own "Compress"
    /// runs, so the archive is byte-for-byte the kind of zip users expect,
    /// resource forks and all.
    static func compress(_ urls: [URL], named name: String, completion: @escaping (URL?) -> Void) {
        guard !urls.isEmpty else {
            completion(nil)
            return
        }

        let directory = destinationDirectory(for: urls)
        let archive = uniqueURL(in: directory, name: name, extension: "zip")

        // A staging directory as the parent would put our uuid path components
        // in the archive, so everything is gathered under a clean folder first.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlipKlik-zip-\(UUID().uuidString)", isDirectory: true)
        let payload = scratch.appendingPathComponent(name, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                try FileManager.default.createDirectory(
                    at: payload, withIntermediateDirectories: true
                )
                for url in urls {
                    let link = payload.appendingPathComponent(url.lastPathComponent)
                    // Hard-links where possible: a 4 GB video should not be
                    // duplicated on disk just to be read by ditto a moment later.
                    if (try? FileManager.default.linkItem(at: url, to: link)) == nil {
                        try FileManager.default.copyItem(at: url, to: link)
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            task.arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, archive.path
            ]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let ok = task.terminationStatus == 0
            DispatchQueue.main.async { completion(ok ? archive : nil) }
        }
    }

    /// Where a derived file should land: beside the originals when they are the
    /// user's own files, on the Desktop when they only exist inside staging.
    private static func destinationDirectory(for urls: [URL]) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        guard let first = urls.first else { return desktop }
        let parent = first.deletingLastPathComponent()

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("KlipKlik", isDirectory: true)

        return parent.path.hasPrefix(support.path) ? desktop : parent
    }

    /// "Archive.zip", then "Archive 2.zip" — never an overwrite.
    private static func uniqueURL(in directory: URL, name: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: Share

    /// The system share sheet, anchored to the view the action came from.
    static func share(_ urls: [URL], from view: NSView) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Feeds the shared Quick Look panel. A singleton because `QLPreviewPanel` is
/// itself a singleton and holds its data source weakly — anything shorter-lived
/// is deallocated before the panel reads from it, and the preview comes up empty.
final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookSource()

    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
