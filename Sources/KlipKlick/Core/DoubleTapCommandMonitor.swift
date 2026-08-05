import AppKit

/// Fires when ⌘ is tapped twice in quick succession, with nothing else pressed.
///
/// A bare modifier can't be registered as a system hot key, so this watches
/// `.flagsChanged` directly. macOS gates keyboard event monitoring behind
/// Accessibility permission, which is why this trigger is inert until the user
/// grants it — see `AccessibilityPermission`.
///
/// The tricky part is not detecting two taps, it's *rejecting* everything that
/// merely involves ⌘: ⌘C, ⌘Tab, ⌘ held down while reaching for another key, or
/// ⇧⌘ combos. A tap only counts when ⌘ went down and back up on its own, quickly.
final class DoubleTapCommandMonitor {
    var onTrigger: (() -> Void)?

    /// Longer than this and it was a hold, not a tap.
    private let maxHoldDuration: TimeInterval = 0.4

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var commandDownAt: Date?
    private var lastCleanTapAt: Date?
    /// Set when anything else joins the ⌘ press, disqualifying it as a clean tap.
    private var contaminated = false

    func start() {
        stop()

        // Global: keystrokes going to other apps. Local: keystrokes going to us,
        // so a second double-tap can dismiss the panel while it has focus.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    private func reset() {
        commandDownAt = nil
        lastCleanTapAt = nil
        contaminated = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // A real key pressed during the ⌘ press means this is a shortcut.
            if commandDownAt != nil { contaminated = true }
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandHeld = flags.contains(.command)
        let otherModifiersHeld = !flags.intersection([.shift, .control, .option]).isEmpty
        let now = Date()

        if commandHeld {
            if commandDownAt == nil {
                // ⌘ going down. If it arrives alongside another modifier it's a combo.
                commandDownAt = now
                contaminated = otherModifiersHeld
            } else if otherModifiersHeld {
                // Another modifier joined mid-press.
                contaminated = true
            }
            return
        }

        // ⌘ released.
        guard let downAt = commandDownAt else { return }
        commandDownAt = nil

        let wasCleanTap = !contaminated && now.timeIntervalSince(downAt) < maxHoldDuration
        contaminated = false

        guard wasCleanTap else {
            // A contaminated press breaks any pending sequence.
            lastCleanTapAt = nil
            return
        }

        if let previous = lastCleanTapAt,
           now.timeIntervalSince(previous) <= Settings.shared.doubleTapWindow {
            lastCleanTapAt = nil
            onTrigger?()
        } else {
            lastCleanTapAt = now
        }
    }
}
