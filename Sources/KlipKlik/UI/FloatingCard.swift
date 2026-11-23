import AppKit
import SwiftUI

/// Items floated on the screen: a picture or a piece of text kept above every
/// window as a reference card.
///
/// Called "Float" rather than "Pin" because pinning already means keeping an
/// item in history. A card can be dragged anywhere, resized from its edges,
/// copied back to the clipboard, and closed; it never takes focus from the
/// app being worked in.
final class FloatingCards {
    static let shared = FloatingCards()

    private var windows: [FloatingCardWindow] = []
    /// Reports clipboard writes, so a card's Copy is not recorded as new.
    var onDidWriteToPasteboard: ((Int) -> Void)?

    private init() {}

    /// Floats a history item. `item` must already be materialised — its
    /// picture lives in its representations.
    func float(_ item: ClipboardItem) {
        let content = PreviewContent(item: item)
        switch content.body {
        case .image(let image):
            show(.image(image), copy: { item.write(to: .general) })
        case .text(let text):
            show(.text(text), copy: { item.write(to: .general) })
        case .color(let components, let hex):
            show(.color(components, hex), copy: { item.write(to: .general) })
        case .files(let urls):
            if urls.count == 1, let image = NSImage(contentsOf: urls[0]) {
                show(.image(image), copy: { item.write(to: .general) })
            } else {
                show(.text(urls.map(\.path).joined(separator: "\n")), copy: { item.write(to: .general) })
            }
        case .nothing:
            NSSound.beep()
        }
    }

    /// Floats a picture that is not in history — a scrolling screenshot.
    func float(image: NSImage) {
        show(.image(image)) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            return pasteboard.changeCount
        }
    }

    func closeAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func show(_ content: FloatingCardView.Content, copy: @escaping () -> Int) {
        let window = FloatingCardWindow(content: content, copy: { [weak self] in
            self?.onDidWriteToPasteboard?(copy())
        })
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
        }
        // Each new card steps down and right from the last, so a second card
        // never lands exactly on top of the first.
        let offset = CGFloat(windows.count % 8) * 24
        window.place(offset: offset)
        windows.append(window)
        window.orderFrontRegardless()
    }
}

/// A borderless, resizable panel that floats above other windows on every
/// Space and never becomes the active app.
final class FloatingCardWindow: NSPanel {
    var onClose: (() -> Void)?

    init(content: FloatingCardView.Content, copy: @escaping () -> Void) {
        let size = FloatingCardView.idealSize(for: content)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 80, height: 60)
        if case .image = content { contentAspectRatio = size }

        contentView = NSHostingView(rootView: FloatingCardView(
            content: content,
            onCopy: copy,
            onClose: { [weak self] in self?.close() }
        ))
    }

    override var canBecomeKey: Bool { true }

    /// Top-right of the screen under the pointer, nudged by `offset`.
    func place(offset: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { center(); return }
        let origin = NSPoint(
            x: visible.maxX - frame.width - 24 - offset,
            y: visible.maxY - frame.height - 24 - offset
        )
        setFrameOrigin(origin)
    }

    override func close() {
        super.close()
        onClose?()
    }
}

struct FloatingCardView: View {
    enum Content {
        case image(NSImage)
        case text(String)
        case color(ColorFormat.Components, String)
    }

    let content: Content
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var copied = false

    /// A picture at its own size, up to a third of the screen; text at a
    /// comfortable reading width.
    static func idealSize(for content: Content) -> NSSize {
        let limit = (NSScreen.main?.visibleFrame.size).map {
            NSSize(width: $0.width / 3, height: $0.height / 2)
        } ?? NSSize(width: 480, height: 480)
        switch content {
        case .image(let image):
            let size = image.size
            guard size.width > 0, size.height > 0 else { return NSSize(width: 240, height: 180) }
            let scale = min(1, limit.width / size.width, limit.height / size.height)
            return NSSize(width: max(80, size.width * scale), height: max(60, size.height * scale))
        case .text(let text):
            let lines = min(14, max(2, text.split(separator: "\n", omittingEmptySubsequences: false).count))
            return NSSize(width: 340, height: CGFloat(lines) * 17 + 36)
        case .color:
            return NSSize(width: 220, height: 160)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card
            if isHovering { controls.padding(8).transition(.opacity) }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }

    @ViewBuilder
    private var card: some View {
        switch content {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        case .color(let components, let hex):
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.sRGB, red: components.red, green: components.green, blue: components.blue))
                Text(hex).font(.system(.callout, design: .monospaced))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help("Close")
        }
        .buttonStyle(FloatingControlStyle())
    }
}

private struct FloatingControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(.thickMaterial))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
