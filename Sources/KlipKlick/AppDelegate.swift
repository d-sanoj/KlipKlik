import AppKit
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = HistoryStore()

    private var monitor: ClipboardMonitor!
    private var purge: DailyPurge!
    private var popup: PopupController!
    private var doubleTap: DoubleTapCommandMonitor!
    private var finderCutMove: FinderCutMove!
    private var fallbackHotKey: CarbonHotKey?
    private var statusItem: NSStatusItem!
    private var preferences: PreferencesWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.applyAppearance()

        monitor = ClipboardMonitor(store: store)
        purge = DailyPurge(store: store)
        popup = PopupController(store: store)
        preferences = PreferencesWindowController(store: store)

        popup.onOpenPreferences = { [weak self] in self?.preferences.show() }
        popup.onDidWriteToPasteboard = { [weak self] changeCount in
            self?.monitor.ignoreChangeCount(changeCount)
        }
        // Catch the overnight purge the moment the user reaches for their history.
        popup.onWillShow = { [weak self] in self?.purge.checkAndPurge() }
        popup.iconScreenFrame = { [weak self] in self?.statusItemScreenFrame() }

        setUpStatusItem()
        setUpTriggers()
        setUpScriptedTrigger()

        // Lowering the history size in Preferences should trim right away, not
        // wait until the next copy.
        Settings.shared.$historySize
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.store.applyLimit() }
            }
            .store(in: &cancellables)

        Settings.shared.$finderCutMove
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.finderCutMove.settingDidChange() }
            }
            .store(in: &cancellables)

        // Diagnostic: the permission state differs by launch context (a binary
        // started from an already-trusted terminal inherits that trust, an app
        // launched from Finder does not), and this file is the only way to see
        // which one you are actually looking at.
        try? "trusted=\(AccessibilityPermission.isTrusted) pid=\(getpid())\n"
            .write(toFile: "/tmp/klipklick-trust.txt", atomically: true, encoding: .utf8)

        monitor.start()
        purge.start()

        finderCutMove = FinderCutMove()
        finderCutMove.onArmedChanged = { [weak self] armed in
            self?.setStatusIcon(cutPending: armed)
        }
        finderCutMove.start()

        // Nothing that needs Accessibility works without it — the ⌘⌘ trigger,
        // auto-paste, and Finder cut-and-move are all inert. Prompt
        // whenever it is missing rather than only once: the ad-hoc signature
        // changes on every rebuild, which silently revokes the grant, and a
        // one-shot prompt leaves the app looking broken with no explanation.
        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        doubleTap.stop()
        finderCutMove.stop()
        // Memory-only history: nothing to flush, it goes with the process.
        store.clearAll()
    }

    // MARK: Status bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        setStatusIcon(cutPending: false)
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Swaps the menu-bar glyph to scissors while a Finder cut is waiting to be
    /// pasted, so an armed cut is visible rather than silent.
    private func setStatusIcon(cutPending: Bool) {
        guard let button = statusItem?.button else { return }
        // Placeholder marks until the real logo is designed.
        let name = cutPending ? "scissors" : "list.clipboard"
        button.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: cutPending ? "KlipKlick — cut pending" : "KlipKlick"
        )
        button.image?.isTemplate = true
        button.toolTip = cutPending
            ? "Cut pending — press ⌘V in another folder to move"
            : "KlipKlick"
    }

    /// Screen-space frame of the menu bar icon, for `AnchorMode.icon`.
    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        isRightClick ? showStatusMenu() : popup.toggle()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open KlipKlick",
            action: #selector(openPopup),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: "About KlipKlick",
            action: #selector(openAbout),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit KlipKlick",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach again so the next left-click reaches our action instead of the menu.
        statusItem.menu = nil
    }

    @objc private func openPopup() { popup.show() }

    @objc private func openPreferences() { preferences.show() }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: Triggers

    private func setUpTriggers() {
        doubleTap = DoubleTapCommandMonitor()
        doubleTap.onTrigger = { [weak self] in self?.popup.toggle() }
        doubleTap.start()

        // Secondary trigger. Carbon hot keys need no Accessibility permission, so
        // this keeps KlipKlick reachable before the user grants it.
        fallbackHotKey = CarbonHotKey(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.popup.toggle()
        }
    }

    /// Opens the popup or preferences on a distributed notification. Used to drive
    /// the UI from scripts during development, where synthesising a keystroke
    /// would itself need Accessibility permission.
    private func setUpScriptedTrigger() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlick.show"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.popup.show()
        }
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlick.preferences"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.preferences.show()
        }
        // Pins the newest two entries, so the PINNED section can be exercised
        // without a mouse or keyboard.
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlick.pinNewest"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for item in store.items.prefix(2) { store.togglePin(item) }
        }
    }
}
