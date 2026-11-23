import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// Hover a Dock icon, see that app's windows, click one to bring it forward.
///
/// Three pieces, all public macOS API:
///
/// * A global mouse-moved monitor (no permission needed) notices the pointer
///   near the Dock's edge. Only then is anything else asked.
/// * Accessibility hit-tests the Dock at the pointer to learn which icon is
///   under it, and lists that app's windows and raises the one clicked.
/// * ScreenCaptureKit takes the thumbnails. Without Screen Recording the
///   previews fall back to the app's icon and each window's title.
///
/// ⌘Tab is not touched.
final class DockPreview {
    private var monitor: Any?
    private let panel = DockPreviewPanel()
    private var lastSample: TimeInterval = 0
    /// The Dock icon under the pointer, and since when.
    private var hovered: (pid: pid_t, frame: CGRect)?
    private var hoverStarted: TimeInterval = 0
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    private static let sampleInterval: TimeInterval = 0.06
    private static let dwell: TimeInterval = 0.35

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            if event.type == .leftMouseDown {
                // Clicking the icon is the Dock's business; get out of its way.
                self?.dismiss()
            } else {
                self?.pointerMoved()
            }
        }
        panel.onChoose = { [weak self] window in
            self?.dismiss()
            DockWindows.raise(window)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dismiss()
    }

    private func dismiss() {
        showWork?.cancel()
        hideWork?.cancel()
        hovered = nil
        panel.hide()
    }

    private func pointerMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= Self.sampleInterval else { return }
        lastSample = now

        let mouse = NSEvent.mouseLocation
        // Over the preview itself: keep it up.
        if panel.isVisible, panel.frame.insetBy(dx: -6, dy: -6).contains(mouse) {
            hideWork?.cancel()
            return
        }

        guard DockGeometry.isNearDock(mouse), AccessibilityPermission.isTrusted,
              let item = DockGeometry.appItem(at: mouse)
        else {
            scheduleHide()
            return
        }

        hideWork?.cancel()
        if hovered?.pid == item.pid { return }

        hovered = item
        hoverStarted = now
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(item) }
        showWork = work
        // The first icon waits a beat, so sweeping across the Dock does not
        // flash a preview per icon; moving between icons while one is open
        // switches at once.
        let delay = panel.isVisible ? 0.05 : Self.dwell
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleHide() {
        showWork?.cancel()
        guard hovered != nil || panel.isVisible else { return }
        // One pending hide is enough; every further move would only restart it.
        if let hideWork, !hideWork.isCancelled { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = nil
            self?.panel.hide()
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func show(_ item: (pid: pid_t, frame: CGRect)) {
        guard hovered?.pid == item.pid else { return }
        let windows = DockWindows.list(pid: item.pid)
        guard !windows.isEmpty else {
            panel.hide()
            return
        }
        let app = NSRunningApplication(processIdentifier: item.pid)
        panel.show(windows: windows, appName: app?.localizedName ?? "", appIcon: app?.icon,
                   iconFrame: item.frame)

        // Thumbnails arrive after the panel is up: titles first, pictures as
        // ScreenCaptureKit delivers them.
        guard CGPreflightScreenCaptureAccess() else { return }
        DockWindows.thumbnails(for: windows, pid: item.pid) { [weak self] images in
            guard let self, hovered?.pid == item.pid else { return }
            panel.update(thumbnails: images)
        }
    }
}

// MARK: - Finding the Dock icon

enum DockGeometry {
    enum Edge { case bottom, left, right }

    static var edge: Edge {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    /// Cheap first filter, so the Accessibility query only runs when the
    /// pointer is somewhere the Dock could be.
    static func isNearDock(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let frame = screen.frame
        let reach: CGFloat = 140
        switch edge {
        case .bottom: return point.y - frame.minY < reach
        case .left: return point.x - frame.minX < reach
        case .right: return frame.maxX - point.x < reach
        }
    }

    /// The running app whose Dock icon is under `point`, and that icon's
    /// frame in Cocoa screen coordinates.
    static func appItem(at point: NSPoint) -> (pid: pid_t, frame: CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures from the top-left of the primary display.
        let axPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &element)
                == .success,
              let element
        else { return nil }

        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)
        guard NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == "com.apple.dock",
              string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url = urlValue(element, kAXURLAttribute)
        else { return nil }

        let standardized = url.standardizedFileURL
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == standardized
        }) else { return nil }

        guard let position = pointValue(element, kAXPositionAttribute),
              let size = sizeValue(element, kAXSizeAttribute)
        else { return nil }
        let frame = CGRect(
            x: position.x, y: primary.frame.maxY - position.y - size.height,
            width: size.width, height: size.height
        )
        return (app.processIdentifier, frame)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func urlValue(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID()
        else { return nil }
        return (value as! CFURL) as URL
    }

    static func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

// MARK: - The app's windows

/// One window of the hovered app.
struct DockWindow: Identifiable {
    let id: Int
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
    /// Accessibility coordinates (top-left origin), for matching a capture.
    let frame: CGRect
}

enum DockWindows {
    /// The app's standard windows, as Accessibility lists them.
    static func list(pid: pid_t) -> [DockWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }

        return windows.enumerated().compactMap { index, window in
            guard DockGeometry.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  let position = DockGeometry.pointValue(window, kAXPositionAttribute),
                  let size = DockGeometry.sizeValue(window, kAXSizeAttribute),
                  size.width >= 80, size.height >= 60
            else { return nil }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            return DockWindow(
                id: index,
                element: window,
                title: DockGeometry.string(window, kAXTitleAttribute) ?? "",
                isMinimized: (minimized as? Bool) ?? false,
                frame: CGRect(origin: position, size: size)
            )
        }
    }

    /// Brings one window to the front, un-minimising it if needed.
    static func raise(_ window: DockWindow) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        AXUIElementGetPid(window.element, &pid)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Captures each on-screen window, matched to ScreenCaptureKit's list by
    /// position and size. Minimised windows have nothing to capture.
    static func thumbnails(for windows: [DockWindow], pid: pid_t,
                           completion: @escaping ([Int: NSImage]) -> Void) {
        Task {
            var images: [Int: NSImage] = [:]
            defer {
                let result = images
                DispatchQueue.main.async { completion(result) }
            }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            ) else { return }
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid }

            for window in windows where !window.isMinimized {
                guard let match = candidates.first(where: { close($0.frame, window.frame) }) else { continue }
                let config = SCStreamConfiguration()
                let scale = min(1, 480 / max(match.frame.width, 1))
                config.width = Int(match.frame.width * scale * 2)
                config.height = Int(match.frame.height * scale * 2)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: match)
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                ) {
                    images[window.id] = NSImage(cgImage: image, size: .zero)
                }
            }
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
            && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}

// MARK: - The preview panel

/// A hosting view that takes the first click, so a thumbnail works without the
/// panel being focused first.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DockPreviewPanel {
    var onChoose: ((DockWindow) -> Void)?

    private let panel: NSPanel
    private let model = DockPreviewModel()

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = DockPreviewView(model: model) { [weak self] window in self?.onChoose?(window) }
        panel.contentView = FirstClickHostingView(rootView: view)
    }

    func show(windows: [DockWindow], appName: String, appIcon: NSImage?, iconFrame: CGRect) {
        model.windows = windows
        model.appName = appName
        model.appIcon = appIcon
        model.thumbnails = [:]

        let size = DockPreviewView.size(for: windows.count)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, beside: iconFrame))
        panel.orderFrontRegardless()
    }

    func update(thumbnails: [Int: NSImage]) {
        model.thumbnails = thumbnails
    }

    func hide() {
        panel.orderOut(nil)
        model.windows = []
        model.thumbnails = [:]
    }

    private func origin(for size: CGSize, beside icon: CGRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        let visible = screen?.frame ?? .zero
        var origin: NSPoint
        switch DockGeometry.edge {
        case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: icon.maxY + 10)
        case .left: origin = NSPoint(x: icon.maxX + 10, y: icon.midY - size.height / 2)
        case .right: origin = NSPoint(x: icon.minX - 10 - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
        return origin
    }
}

final class DockPreviewModel: ObservableObject {
    @Published var windows: [DockWindow] = []
    @Published var thumbnails: [Int: NSImage] = [:]
    @Published var appName = ""
    @Published var appIcon: NSImage?
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    let onChoose: (DockWindow) -> Void

    private static let tile = CGSize(width: 200, height: 130)
    private static let maxColumns = 4

    static func size(for count: Int) -> CGSize {
        let columns = max(1, min(count, maxColumns))
        let rows = Int(ceil(Double(max(count, 1)) / Double(maxColumns)))
        return CGSize(
            width: CGFloat(columns) * (tile.width + 10) + 14,
            height: CGFloat(min(rows, 2)) * (tile.height + 30) + 40
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(model.appName).font(.system(size: 12, weight: .semibold))
            }
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.tile.width), spacing: 10),
                                   count: max(1, min(model.windows.count, Self.maxColumns))),
                    spacing: 10
                ) {
                    ForEach(model.windows) { window in
                        DockThumbnail(window: window, image: model.thumbnails[window.id],
                                      icon: model.appIcon, size: Self.tile) {
                            onChoose(window)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
    }
}

private struct DockThumbnail: View {
    let window: DockWindow
    let image: NSImage?
    let icon: NSImage?
    let size: CGSize
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
                    } else if let icon {
                        Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(0.8)
                    }
                    if window.isMinimized {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isHovering ? 0.9 : 0), lineWidth: 2)
                )
                Text(window.title.isEmpty ? "Untitled" : window.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size.width)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
