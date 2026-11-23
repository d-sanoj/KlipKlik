import AppKit
import Carbon.HIToolbox
import Combine

/// Watches typing for a snippet trigger and swaps it for the snippet's text.
///
/// Uses the same global key monitor as Finder cut-and-move, so it needs
/// Accessibility and nothing more. It sees nothing in password fields: macOS
/// turns on secure input there, and global monitors receive no keystrokes
/// while it is on.
///
/// The monitor only runs while there is at least one usable snippet and the
/// feature is on — with nothing to expand there is no reason to watch keys.
/// What it remembers is the last few dozen characters, in memory only, cleared
/// on any click, app switch or navigation key.
final class SnippetExpander {
    /// Reports pasteboard writes, so the monitor ignores a long snippet's
    /// temporary trip through the clipboard.
    var onDidWriteToPasteboard: ((Int) -> Void)?

    private let store = SnippetStore.shared
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: Any?
    private var buffer = ""
    /// Set while our own keystrokes are being posted, which the global monitor
    /// also sees — they must not feed the buffer or re-trigger.
    private var isExpanding = false
    private var cancellables = Set<AnyCancellable>()

    /// Longer than this, or with a line break, goes through the clipboard:
    /// typing it character by character is slow, and a typed Return can send a
    /// chat message half-way through.
    private static let typeLimit = 200

    func start() {
        Settings.shared.$snippetsEnabled
            .combineLatest(store.$snippets)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, snippets in
                let wanted = enabled && snippets.contains(where: \.isUsable)
                wanted ? self?.installMonitors() : self?.removeMonitors()
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        removeMonitors()
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        // A click can move the insertion point, so what was typed before it is
        // no longer what sits in front of the cursor.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.buffer = ""
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.buffer = ""
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        keyMonitor = nil
        mouseMonitor = nil
        activationObserver = nil
        buffer = ""
    }

    private static let resettingKeys: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
    ]

    private func handle(_ event: NSEvent) {
        guard !isExpanding else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            buffer = ""
            return
        }

        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Delete {
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        if Self.resettingKeys.contains(keyCode) {
            buffer = ""
            return
        }

        guard let characters = event.characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return }

        buffer = SnippetMatcher.append(characters, to: buffer)
        guard let snippet = SnippetMatcher.match(buffer, in: store.snippets) else { return }
        buffer = ""
        expand(snippet)
    }

    private func expand(_ snippet: Snippet) {
        guard AccessibilityPermission.isTrusted else { return }
        isExpanding = true

        let text = SnippetMatcher.expand(
            snippet.text,
            now: Date(),
            clipboard: NSPasteboard.general.string(forType: .string)
        )

        // The trigger's last key is still on its way to the app. A beat lets it
        // land before it is deleted along with the rest of the trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            for _ in 0..<snippet.trigger.count {
                Paster.send(keyCode: CGKeyCode(kVK_Delete), flags: [])
            }

            if text.count > Self.typeLimit || text.contains(where: \.isNewline) {
                pasteThroughClipboard(text)
            } else {
                Paster.type(text)
                finishExpanding(after: 0.2)
            }
        }
    }

    /// Writes the text to the clipboard, pastes it, then puts back whatever
    /// the clipboard held before.
    private func pasteThroughClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onDidWriteToPasteboard?(pasteboard.changeCount)
        Paster.paste()

        // Long enough for the app to read the clipboard for its paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            Self.restore(saved, to: pasteboard)
            onDidWriteToPasteboard?(pasteboard.changeCount)
            finishExpanding(after: 0)
        }
    }

    private func finishExpanding(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isExpanding = false
            self?.buffer = ""
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var bag: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { bag[type] = data }
            }
            return bag
        }
    }

    private static func restore(_ bags: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !bags.isEmpty else { return }
        let items = bags.map { bag -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in bag { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
