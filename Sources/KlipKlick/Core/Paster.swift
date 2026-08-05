import AppKit
import Carbon.HIToolbox

/// Synthesises keystrokes into whichever app is frontmost.
enum Paster {
    /// ⌘V — ordinary paste.
    static func paste() {
        send(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    /// ⌥⌘V — Finder's "Move Item Here", which completes a cut-and-move.
    static func pasteMovingFiles() {
        send(keyCode: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand, .maskAlternate])
    }

    /// ⌘C — used to make Finder put the current selection on the pasteboard.
    static func copy() {
        send(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    static func send(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard AccessibilityPermission.isTrusted else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        // Without this, modifier keys the user is still physically holding can
        // bleed into the synthesised event and turn ⌘V into something else.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// Accessibility (`AXIsProcessTrusted`) gates the double-tap ⌘ trigger,
/// auto-paste, and Finder cut-and-move. Clipboard capture, the ⇧⌘C hot key,
/// and the UI all work without it.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt with the "Open System Settings" button.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettingsPane() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Clears this app's Accessibility approval and asks for it again.
    ///
    /// The grant is tied to the code signature, and an ad-hoc signature changes
    /// on every rebuild — which leaves a stale row in System Settings that looks
    /// enabled but no longer matches, and cannot be fixed by toggling it. Only
    /// clearing the entry and re-approving works.
    ///
    /// This only ever *revokes*; re-approval still goes through the system
    /// dialog, which is the only thing that can actually grant it.
    @discardableResult
    static func reset() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.sanoj.KlipKlick"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else { return false }

        // Ask again straight away, so the user gets the approval dialog rather
        // than having to go hunting for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            requestIfNeeded()
        }
        return true
    }
}
