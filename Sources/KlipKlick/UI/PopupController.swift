import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app,
/// so the app you were typing in stays frontmost and ready to receive the paste.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the popup window: showing it at the configured anchor, keyboard handling,
/// and handing the chosen item back to the app you came from.
final class PopupController: NSObject, NSWindowDelegate {
    let viewModel: PopupViewModel

    private let panel: PopupPanel
    private let detailCard = DetailCardWindow()
    /// Pending first appearance of the detail card, cancelled if focus moves on.
    private var detailDelay: DispatchWorkItem?
    private var detailItemID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// Where the panel's top-left corner should stay as its height changes.
    private var anchorTopLeft: NSPoint = .zero

    var onOpenPreferences: (() -> Void)?
    /// Reports the pasteboard change count we produced, so the monitor can skip it.
    var onDidWriteToPasteboard: ((Int) -> Void)?
    /// Chance to run housekeeping (the daily purge check) just before showing.
    var onWillShow: (() -> Void)?
    /// Screen frame of the status-bar item, for `AnchorMode.icon`.
    var iconScreenFrame: (() -> NSRect?)?

    var isVisible: Bool { panel.isVisible }

    init(store: HistoryStore) {
        viewModel = PopupViewModel(store: store)
        panel = PopupPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Settings.shared.popupSize.width,
                height: Metrics.maxPopupHeight
            ),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        wireViewModel()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // Follow the user across spaces and appear over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let hosting = NSHostingController(rootView: PopupView(viewModel: viewModel))
        // Let SwiftUI's ideal size drive the window as the list filters down.
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
    }

    private func wireViewModel() {
        viewModel.onActivate = { [weak self] item, invertFormatting in
            self?.activate(item, invertFormatting: invertFormatting)
        }
        viewModel.onClose = { [weak self] in self?.hide() }
        viewModel.onOpenPreferences = { [weak self] in self?.onOpenPreferences?() }

        // The list reports the focused row's position; the card follows it,
        // whether focus moved by pointer or by arrow key.
        viewModel.$focusedRow
            .sink { [weak self] row in
                // Out of the SwiftUI update that produced it before touching windows.
                DispatchQueue.main.async { self?.updateDetailCard(row) }
            }
            .store(in: &cancellables)
    }

    // MARK: Detail card

    private func updateDetailCard(_ row: FocusedRow?) {
        guard panel.isVisible,
              let row,
              let item = viewModel.flatItems.first(where: { $0.id == row.id })
        else {
            dismissDetailCard()
            return
        }

        // Already up: retarget it at once. Re-arming the delay on every arrow
        // key would leave the card blinking its way down the list.
        if detailCard.isVisible {
            detailDelay?.cancel()
            detailItemID = row.id
            detailCard.show(item: item, now: viewModel.now, rowFrame: row.frame, parent: panel)
            return
        }

        // Same row, card not up yet — the row only moved (a scroll, a resize).
        guard detailItemID != row.id else { return }

        detailDelay?.cancel()
        detailItemID = row.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.detailCard.show(
                item: item, now: self.viewModel.now, rowFrame: row.frame, parent: self.panel
            )
        }
        detailDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func dismissDetailCard() {
        detailDelay?.cancel()
        detailDelay = nil
        detailItemID = nil
        detailCard.hide()
    }

    // MARK: Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        onWillShow?()

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        viewModel.resetForShow()
        panel.layoutIfNeeded()
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()

        // Re-arm the card from the last reported row. Reopening on an unchanged
        // list produces no new preference, so waiting for one would mean no card
        // until the user moved the selection.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateDetailCard(viewModel.focusedRow)
        }
    }

    func hide() {
        removeKeyMonitor()
        dismissDetailCard()
        panel.orderOut(nil)
    }

    /// Places the panel at the configured anchor, then pulls it back onto the
    /// screen it landed on if it would overhang.
    private func position() {
        let size = panel.frame.size
        let target: NSPoint
        let screen: NSScreen

        switch Settings.shared.anchorMode {
        case .icon:
            if let icon = iconScreenFrame?() {
                // Hang from the menu bar, right edge aligned with the icon.
                target = NSPoint(x: icon.maxX - size.width, y: icon.minY - 6)
                screen = Self.screen(containing: NSPoint(x: icon.midX, y: icon.midY))
            } else {
                let mouse = NSEvent.mouseLocation
                target = NSPoint(x: mouse.x - 12, y: mouse.y + 12)
                screen = Self.screen(containing: mouse)
            }
        case .cursor:
            let mouse = NSEvent.mouseLocation
            target = NSPoint(x: mouse.x - 12, y: mouse.y + 12)
            screen = Self.screen(containing: mouse)
        }

        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var topLeft = target

        if topLeft.x + size.width > visible.maxX - margin {
            topLeft.x = visible.maxX - size.width - margin
        }
        topLeft.x = max(topLeft.x, visible.minX + margin)

        if topLeft.y > visible.maxY - margin {
            topLeft.y = visible.maxY - margin
        }
        if topLeft.y - size.height < visible.minY + margin {
            topLeft.y = min(visible.minY + margin + size.height, visible.maxY - margin)
        }

        anchorTopLeft = topLeft
        panel.setFrameTopLeftPoint(topLeft)
    }

    private static func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidResize(_ notification: Notification) {
        // SwiftUI resizes from the bottom-left; re-pin so the top edge stays put
        // instead of the panel crawling up the screen as you type a search.
        guard panel.isVisible else { return }
        let current = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if abs(current.y - anchorTopLeft.y) > 0.5 || abs(current.x - anchorTopLeft.x) > 0.5 {
            panel.setFrameTopLeftPoint(anchorTopLeft)
        }
    }

    // MARK: Activation

    private func activate(_ item: ClipboardItem, invertFormatting: Bool) {
        let target = previousApp
        hide()

        // The "Strip formatting" setting decides the default; ⌥⇧ inverts it, so
        // there is a one-off escape hatch in whichever direction you need.
        // Non-text items have no plain flavour and are always restored in full.
        let stripFormatting = Settings.shared.stripFormatting != invertFormatting
        let changeCount = item.write(to: .general, plainTextOnly: stripFormatting)
        onDidWriteToPasteboard?(changeCount)

        guard Settings.shared.pasteAutomatically, AccessibilityPermission.isTrusted else { return }

        target?.activate()
        // Give the target app a moment to take focus before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paster.paste()
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed and should not reach the search field.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
            return true

        case kVK_DownArrow:
            viewModel.moveSelection(by: 1)
            return true

        case kVK_UpArrow:
            viewModel.moveSelection(by: -1)
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            // ⌥⇧↩ inverts the "Strip formatting" setting for this one paste.
            viewModel.activateSelected(invertFormatting: option && shift)
            return true

        case kVK_ANSI_P where option:
            viewModel.togglePinSelected()
            return true

        case kVK_Delete where command && option:
            viewModel.clearHistory()
            return true

        case kVK_Delete where command:
            viewModel.deleteSelected()
            return true

        case kVK_ANSI_Comma where command:
            hide()
            onOpenPreferences?()
            return true

        case kVK_ANSI_Q where command:
            NSApp.terminate(nil)
            return true

        default:
            break
        }

        // ⌘1…⌘9 jump straight to a row and paste it.
        if command, !option, let index = Self.digitIndex(for: event.keyCode) {
            viewModel.select(index: index)
            viewModel.activateSelected()
            return true
        }

        return false
    }

    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    private static func digitIndex(for keyCode: UInt16) -> Int? {
        digitKeyCodes.firstIndex(of: Int(keyCode))
    }
}
