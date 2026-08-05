import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Windows-style ⌘X cut-and-move for files in Finder.
///
/// macOS deliberately has no ⌘X for files — you copy with ⌘C and then move with
/// ⌥⌘V ("Move Item Here"). This bridges the two:
///
/// * ⌘X in Finder synthesises ⌘C, so Finder itself puts the selection on the
///   pasteboard, and arms cut mode.
/// * ⌘V while armed is consumed and replaced with ⌥⌘V, so Finder performs the
///   move — with its own conflict handling, progress UI, and undo.
///
/// Letting Finder do both halves of the work is why this needs no file
/// manipulation of its own, and no Automation permission.
///
/// Both hot keys are Carbon hot keys, which *consume* the keystroke. That matters
/// for ⌘X specifically: Finder has no Cut command for files, so an unconsumed ⌘X
/// reaches Finder and it plays the "not allowed" alert sound. Registering the key
/// swallows it before Finder ever sees it. Both are held only while Finder is
/// frontmost, so neither key is affected in any other app.
final class FinderCutMove {
    private static let finderBundleID = "com.apple.finder"

    /// Reports whether a cut is pending, so the UI can show it. Without this the
    /// feature is invisible — ⌘X changes nothing on screen, which reads as broken
    /// even when the cut armed correctly.
    var onArmedChanged: ((Bool) -> Void)?

    private var copyMonitor: Any?
    private var cutHotKey: CarbonHotKey?
    private var pasteHotKey: CarbonHotKey?
    private var isArmed = false {
        didSet {
            guard isArmed != oldValue else { return }
            onArmedChanged?(isArmed)
        }
    }
    /// Pasteboard generation at the moment cut mode was armed. If it has moved
    /// on, something else was copied and the pending move is stale.
    private var armedChangeCount: Int?

    func start() {
        stop()

        // ⌘C is only observed, never consumed — Finder's own copy must still run.
        copyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCopyKey(event)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Finder may already be frontmost at launch.
        updateHotKeys()
    }

    func stop() {
        if let copyMonitor { NSEvent.removeMonitor(copyMonitor) }
        copyMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cutHotKey = nil
        disarm()
    }

    deinit { stop() }

    // MARK: Hot keys

    @objc private func appActivated() {
        updateHotKeys()
    }

    /// Call when the `finderCutMove` setting is toggled, so the ⌘X key is taken
    /// or released immediately rather than at the next app switch.
    func settingDidChange() {
        updateHotKeys()
    }

    private func updateHotKeys() {
        let active = Settings.shared.finderCutMove && Self.isFinderFrontmost

        if active {
            if cutHotKey == nil {
                cutHotKey = CarbonHotKey(
                    keyCode: UInt32(kVK_ANSI_X),
                    modifiers: UInt32(cmdKey)
                ) { [weak self] in
                    self?.handleCut()
                }
                Self.log("cut hot key registered = \(cutHotKey != nil)")
            }
        } else {
            cutHotKey = nil
        }

        // The paste key is only held while there is actually a move pending.
        if active, isArmed {
            if pasteHotKey == nil {
                pasteHotKey = CarbonHotKey(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: UInt32(cmdKey)
                ) { [weak self] in
                    self?.performPaste()
                }
            }
        } else {
            pasteHotKey = nil
        }
    }

    // MARK: Cut

    private func handleCut() {
        // Inline rename and the search field need a genuine text cut. The hot key
        // has already swallowed the keystroke, so hand it back by releasing the
        // key, re-posting it, and taking it again.
        if Self.focusedElementIsTextInput() {
            Self.log("⌘X in a text field — replaying as a text cut")
            cutHotKey = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                Paster.send(keyCode: CGKeyCode(kVK_ANSI_X), flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.updateHotKeys()
                }
            }
            return
        }

        arm()
    }

    private func arm() {
        // Finder has no ⌘X for files, so ask it to copy the selection instead.
        Paster.copy()

        // Finder needs a moment to write the pasteboard before we inspect it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }

            let fileCount = Self.pasteboardFileCount()
            guard fileCount > 0 else {
                // Nothing selected, or the selection isn't files — there is no
                // move to make, so leave cut mode off rather than arming a
                // ⌘V interception that would do nothing.
                Self.log("arm aborted — no file URLs on the pasteboard")
                return
            }

            isArmed = true
            armedChangeCount = NSPasteboard.general.changeCount
            updateHotKeys()
            Self.log("armed files=\(fileCount) changeCount=\(armedChangeCount ?? -1)"
                + " pasteHotKey=\(pasteHotKey != nil)")
        }
    }

    private func disarm() {
        isArmed = false
        armedChangeCount = nil
        pasteHotKey = nil
    }

    private func handleCopyKey(_ event: NSEvent) {
        guard Settings.shared.finderCutMove, Self.isFinderFrontmost else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPlainCommand = flags.subtracting(.command).isEmpty && flags.contains(.command)
        // A plain copy replaces any pending move.
        if isPlainCommand, Int(event.keyCode) == kVK_ANSI_C {
            disarm()
        }
    }

    // MARK: Paste

    private func performPaste() {
        let stale = armedChangeCount != NSPasteboard.general.changeCount
        let shouldMove = isArmed && !stale && Self.isFinderFrontmost
        Self.log("⌘V intercepted armed=\(isArmed) stale=\(stale) move=\(shouldMove)")

        disarm()
        updateHotKeys()

        // The hot key consumed the keystroke, so one has to be put back either
        // way: a move if the cut is still valid, an ordinary paste otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            shouldMove ? Paster.pasteMovingFiles() : Paster.paste()
        }
    }

    // MARK: Helpers

    private static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleID
    }

    /// How many file URLs the pasteboard currently holds.
    private static func pasteboardFileCount() -> Int {
        let key = NSPasteboard.PasteboardType.fileURL
        return NSPasteboard.general.pasteboardItems?
            .filter { $0.string(forType: key) != nil }
            .count ?? 0
    }

    /// True when the keyboard focus is in an editable text field — Finder's
    /// inline rename, or the search box.
    private static func focusedElementIsTextInput() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
            let focusedValue = focused,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String
        else { return false }

        return roleName == kAXTextFieldRole || roleName == kAXTextAreaRole
    }

    static var debugEnabled: Bool {
        ProcessInfo.processInfo.environment["KLIPKLICK_DEBUG"] != nil
    }

    static func log(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write("cutmove: \(message)\n".data(using: .utf8)!)
    }
}
