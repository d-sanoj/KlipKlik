import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Writes a captured picture out — to the clipboard or to a file — at its full
/// sharpness.
///
/// A capture of a Retina screen has two pixels per point. Unless the file says
/// so, every app assumes the old 72 dpi, shows the picture at twice its size,
/// and stretches each pixel to fill the space: the blur. So the density goes in
/// with the pixels (144 dpi at 2×, as macOS's own screenshots carry), and the
/// picture opens at its real size and stays crisp.
enum ScreenshotOutput {
    /// The picture as `type`, tagged with `scale` pixels per point.
    static func encode(_ image: CGImage, as type: UTType, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * max(scale, 1)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        if type != .png { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Puts the picture on the clipboard as PNG — lossless, and far smaller
    /// than the TIFF AppKit would add, which for a tall page runs to hundreds
    /// of megabytes. Clipboard history records it like any copy.
    static func copy(_ image: CGImage, scale: CGFloat, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let png = encode(image, as: .png, scale: scale)
            DispatchQueue.main.async {
                guard let png else {
                    completion(false)
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(png, forType: .png)
                completion(true)
            }
        }
    }

    /// Saves a PNG to the Desktop, named like macOS's own screenshots.
    static func saveToDesktop(_ image: CGImage, scale: CGFloat, completion: @escaping (URL?) -> Void) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        save(image, scale: scale, to: uniqueURL(in: desktop, name: defaultName()), completion: completion)
    }

    static func save(_ image: CGImage, scale: CGFloat, to url: URL, completion: @escaping (URL?) -> Void) {
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        DispatchQueue.global(qos: .userInitiated).async {
            var saved: URL?
            if let data = encode(image, as: type, scale: scale), (try? data.write(to: url)) != nil {
                saved = url
            }
            DispatchQueue.main.async { completion(saved) }
        }
    }

    /// "Scrolling Screenshot 2026-11-23 at 18.04.11.png".
    static func defaultName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Scrolling Screenshot \(formatter.string(from: date)).png"
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(counter).png")
            counter += 1
        }
        return url
    }
}

/// A small note under the menu bar that says a capture finished, then fades.
/// It never takes a click or the focus.
enum CaptureToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, detail: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let size = NSSize(width: 300, height: 54)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let panel = NSPanel(
            contentRect: NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: CaptureToastView(title: title, detail: detail))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}

private struct CaptureToastView: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 300, height: 54)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
    }
}
