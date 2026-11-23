import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The panel shown while capturing

final class ScrollCaptureHUD {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let model = ScrollCaptureHUDModel()
    private var panel: NSPanel?

    func show(near rect: CGRect) {
        model.shots = 1
        model.height = 0
        let size = NSSize(width: 330, height: 52)
        let area = NSRect(
            x: rect.minX,
            y: (NSScreen.screens.first?.frame.maxY ?? rect.maxY) - rect.maxY,
            width: rect.width, height: rect.height
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? area
        // Below the area if there is room, else above it, else inside its top.
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 12)
        if origin.y < visible.minY { origin.y = area.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = area.maxY - size.height - 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ScrollCaptureHUDView(
            model: model,
            onDone: { [weak self] in self?.onDone?() },
            onCancel: { [weak self] in self?.onCancel?() }
        ))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(shots: Int, height: Int) {
        model.shots = shots
        model.height = height
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class ScrollCaptureHUDModel: ObservableObject {
    @Published var shots = 1
    @Published var height = 0
}

private struct ScrollCaptureHUDView: View {
    @ObservedObject var model: ScrollCaptureHUDModel
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scrolling capture").font(.system(size: 12, weight: .semibold))
                Text(model.height > 0
                     ? "\(model.shots) shots · \(model.height.formatted()) px · Esc to cancel"
                     : "Starting… · Esc to cancel")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            Button("Cancel", action: onCancel).controlSize(.small)
            Button("Done", action: onDone).controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .frame(width: 330, height: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
    }
}

// MARK: - The result

/// Shows a finished scrolling screenshot, already on the clipboard, with Save,
/// Copy and Float.
final class ScrollResultWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ScrollResultWindow] = []

    private let image: CGImage

    static func show(_ image: CGImage) {
        let controller = ScrollResultWindow(image: image)
        open.append(controller)
        controller.copyToClipboard()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(image: CGImage) {
        self.image = image
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Scrolling Screenshot"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingController(rootView: ScrollResultView(
            image: image,
            onCopy: { [weak self] in self?.copyToClipboard() },
            onSave: { [weak self] in self?.save() },
            onFloat: { [weak self] in self?.float() }
        ))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 640, height: 720))
    }

    required init?(coder: NSCoder) { nil }

    /// At the screen's own scale, so a Retina capture floats at its real size.
    private var nsImage: NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                     height: CGFloat(image.height) / scale))
    }

    /// As PNG only: a TIFF of a picture this tall would be hundreds of
    /// megabytes. History records it like any other copy.
    func copyToClipboard() {
        let image = image
        DispatchQueue.global(qos: .userInitiated).async {
            let png = Self.encode(image, as: .png)
            DispatchQueue.main.async {
                guard let png else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(png, forType: .png)
            }
        }
    }

    private func save() {
        guard let window else { return }
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Scrolling Screenshot \(formatter.string(from: Date())).png"
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [image] response in
            guard response == .OK, let url = panel.url else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .png
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = Self.encode(image, as: type) else { return }
                try? data.write(to: url)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private func float() {
        FloatingCards.shared.float(image: nsImage)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        DispatchQueue.main.async { [weak self] in
            dropDockIconUnlessWindowsRemain(except: self?.window)
        }
    }
}

private struct ScrollResultView: View {
    let image: CGImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onFloat: () -> Void

    @State private var copied = true

    var body: some View {
        ScrollView([.vertical]) {
            Image(decorative: image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle("Scrolling Screenshot")
        .navigationSubtitle("\(image.width) × \(image.height) px · copied to the clipboard")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onFloat) { Label("Float", systemImage: "pin") }
                    .help("Float it on the screen")
                Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy to the clipboard")
                Button(action: onSave) { Label("Save…", systemImage: "square.and.arrow.down") }
                    .help("Save as PNG, JPEG or HEIC")
            }
        }
    }
}
