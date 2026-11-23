import AppKit
import SwiftUI

/// What a preview has to show, worked out once from the item so the view does
/// no decoding of its own.
struct PreviewContent {
    enum Body {
        case text(String)
        case image(NSImage)
        case files([URL])
        case color(ColorFormat.Components, hex: String)
        case nothing
    }

    let title: String
    let subtitle: String
    let body: Body

    /// `item` must already be materialised — the image bytes live in its
    /// representations, which are nil once offloaded.
    init(item: ClipboardItem) {
        title = item.kind.label
        subtitle = [item.sourceApp, item.absoluteTime()].compactMap(\.self).joined(separator: " · ")

        let urls = Self.fileURLs(in: item)
        if let hex = item.colorHex, let components = ColorFormat.components(fromHex: hex) {
            body = .color(components, hex: hex)
        } else if urls.count == 1, ClipKind(file: urls[0]) == .image,
                  let image = NSImage(contentsOf: urls[0]) {
            body = .image(image)
        } else if !urls.isEmpty {
            body = .files(urls)
        } else if let image = Self.image(in: item) {
            body = .image(image)
        } else if let text = item.plainText, !text.isEmpty {
            // A very long copy is cut rather than laid out whole: the preview
            // is a glance, and SwiftUI lays out every character it is given.
            body = .text(text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text)
        } else {
            body = .nothing
        }
    }

    private static func fileURLs(in item: ClipboardItem) -> [URL] {
        let key = NSPasteboard.PasteboardType.fileURL.rawValue
        return (item.representations ?? []).compactMap { bag in
            guard let data = bag[key], let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    private static func image(in item: ClipboardItem) -> NSImage? {
        let keys = [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.jpeg",
            "com.compuserve.gif",
            NSPasteboard.PasteboardType.pdf.rawValue
        ]
        for bag in item.representations ?? [] {
            for key in keys {
                if let data = bag[key], let image = NSImage(data: data) { return image }
            }
        }
        return nil
    }
}

/// The Space-bar preview: the whole of an item, not just its one-line title.
struct PreviewView: View {
    let content: PreviewContent

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Palette { .resolve(colorScheme) }

    static let size = CGSize(width: 380, height: 300)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(content.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }

            bodyView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private var bodyView: some View {
        switch content.body {
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .files(let urls):
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .color(let components, let hex):
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.sRGB, red: components.red, green: components.green,
                                blue: components.blue))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(hex).font(.system(size: 12, design: .monospaced))
                    ForEach(ColorFormat.allCases.filter { $0 != .hex }) { format in
                        Text(format.string(for: components))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .foregroundStyle(palette.textPrimary)
            }
        case .nothing:
            Text("Nothing to preview")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
        }
    }
}

/// Hosts `PreviewView` beside the popup.
///
/// Like the detail card, a child window that can never become key: the popup
/// closes when it loses key status, so a preview that took focus would close
/// the list it is previewing. It does take the pointer, though, so a long text
/// can be scrolled.
final class PreviewWindow {
    private static let gap: CGFloat = 8

    private let panel: NSPanel
    private var attachedTo: NSWindow?
    private(set) var itemID: UUID?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PreviewView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    func show(item: ClipboardItem, beside parent: NSWindow) {
        itemID = item.id
        panel.contentView = NSHostingView(rootView: PreviewView(content: PreviewContent(item: item)))
        panel.setContentSize(PreviewView.size)
        panel.setFrameOrigin(origin(beside: parent))

        if attachedTo !== parent {
            attachedTo?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            attachedTo = parent
        }
        panel.orderFront(nil)
    }

    func hide() {
        itemID = nil
        attachedTo?.removeChildWindow(panel)
        attachedTo = nil
        panel.orderOut(nil)
        // The hosted view holds a decoded image; let it go with the window.
        panel.contentView = nil
    }

    /// Left of the popup, its top level with the popup's; flips right when the
    /// left side has no room.
    private func origin(beside parent: NSWindow) -> NSPoint {
        let size = PreviewView.size
        let frame = parent.frame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = frame.minX - size.width - Self.gap
        if x < visible.minX + 4 { x = frame.maxX + Self.gap }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)

        var y = frame.maxY - size.height
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }
}
