import AppKit
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    private var clockTimer: Timer?
    /// Last string written to the status item, so a tick that changes nothing
    /// doesn't relayout the menu bar.
    private var lastClockTitle: String?
    private var cutPending = false
    /// Every zone menu item by identifier, for moving the checkmark.
    private var timeZoneItems: [String: NSMenuItem] = [:]
    private var timeZoneMenuItem: NSMenuItem!
    /// Disabled row at the top of the Timezone submenu naming the current zone.
    private var selectedZoneHeader: NSMenuItem!

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
        clockTimer?.invalidate()
        // Memory-only history: nothing to flush, it goes with the process.
        store.clearAll()
    }

    // MARK: Status bar

    private func setUpStatusItem() {
        // Variable length: the item is a clock now, not a fixed-size glyph.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildStatusMenu()
        refreshClock()

        // A whole second of drift is invisible on a minute-resolution clock, but
        // a 5s tick keeps the change within a few seconds of the real minute
        // without redrawing the menu bar 60 times a minute.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer

        Settings.shared.$menuBarTimeZone
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.lastClockTitle = nil
                    self?.refreshClock()
                    self?.refreshTimeZoneMenu()
                }
            }
            .store(in: &cancellables)
    }

    /// 12-hour wall clock in the chosen zone. Forced to 12-hour with a POSIX
    /// locale, so it reads the same on a Mac set to a 24-hour clock.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private func refreshClock() {
        guard let button = statusItem?.button else { return }
        let zone = Settings.shared.resolvedTimeZone
        Self.clockFormatter.timeZone = zone
        let title = "\(TimeZoneFlags.shared.flag(for: zone.identifier))  "
            + Self.clockFormatter.string(from: Date())

        // Setting the title unconditionally relayouts the menu bar every tick.
        guard title != lastClockTitle else { return }
        lastClockTitle = title
        button.title = title
        button.toolTip = cutPending
            ? "Cut pending — press ⌘ V in another folder to move"
            : "KlipKlick — \(zone.identifier.replacingOccurrences(of: "_", with: " "))"
    }

    /// Scissors while a Finder cut is waiting to be pasted, so an armed cut is
    /// visible rather than silent. No glyph otherwise: the time is the item.
    private func setStatusIcon(cutPending: Bool) {
        self.cutPending = cutPending
        guard let button = statusItem?.button else { return }
        button.image = cutPending
            ? NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut pending")
            : nil
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        lastClockTitle = nil
        refreshClock()
    }

    /// Screen-space frame of the menu bar icon, for `AnchorMode.icon`.
    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Offsets move with DST and the selection can change elsewhere, so the
        // titles are refreshed each time the menu is about to open.
        menu.delegate = self

        menu.addItem(
            withTitle: "Clipboard",
            action: #selector(openPopup),
            keyEquivalent: ""
        ).target = self

        menu.addItem(
            withTitle: "Settings",
            action: #selector(openPreferences),
            keyEquivalent: ","
        ).target = self

        timeZoneMenuItem = menu.addItem(withTitle: "Timezone", action: nil, keyEquivalent: "")
        timeZoneMenuItem.submenu = buildTimeZoneMenu()

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    /// Every zone on the system, grouped by region:
    /// `America/Argentina/Buenos_Aires` becomes *America ▸ Argentina – Buenos Aires*.
    ///
    /// The top of the menu names the zone in force, so the current setting is
    /// readable without hunting through submenus for the checkmark.
    private func buildTimeZoneMenu() -> NSMenu {
        let menu = NSMenu()

        selectedZoneHeader = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        selectedZoneHeader.isEnabled = false

        menu.addItem(.separator())

        let system = menu.addItem(
            withTitle: "System default",
            action: #selector(selectTimeZone(_:)),
            keyEquivalent: ""
        )
        system.target = self
        system.representedObject = ""
        timeZoneItems[""] = system

        menu.addItem(.separator())

        var byRegion: [String: [String]] = [:]
        for identifier in Self.allTimeZoneIdentifiers() {
            let parts = identifier.split(separator: "/", maxSplits: 1)
            // Bare identifiers like "UTC" have no region to file them under.
            let region = parts.count > 1 ? String(parts[0]) : "Other"
            byRegion[region, default: []].append(identifier)
        }

        for region in byRegion.keys.sorted() {
            let regionItem = menu.addItem(withTitle: region, action: nil, keyEquivalent: "")
            let identifiers = byRegion[region]!.sorted { label(for: $0) < label(for: $1) }
            regionItem.submenu = regionMenu(identifiers, region: region)
        }

        refreshTimeZoneMenu()
        return menu
    }

    /// A region's zones, split into alphabetical runs once the list grows past
    /// what fits on screen — a 100-entry scrolling menu is unusable, and Asia
    /// alone is well past that.
    private func regionMenu(_ identifiers: [String], region: String) -> NSMenu {
        let menu = NSMenu()

        guard identifiers.count > Self.chunkThreshold else {
            for identifier in identifiers { menu.addItem(zoneItem(identifier, region: region)) }
            return menu
        }

        // Groups break on a change of initial letter, never mid-letter: a
        // "D – K" next to a "K – S" leaves you guessing which one holds Kolkata.
        let target = min(max(identifiers.count / 4, 1), 30)
        var groups: [[String]] = []
        var current: [String] = []

        for (index, identifier) in identifiers.enumerated() {
            current.append(identifier)
            let thisInitial = initial(of: identifier, region: region)
            let nextInitial = index + 1 < identifiers.count
                ? initial(of: identifiers[index + 1], region: region)
                : nil
            if current.count >= target, nextInitial != thisInitial {
                groups.append(current)
                current = []
            }
        }
        // Only a stub tail folds into the previous group; a substantial one
        // stands alone, or the last group ends up twice the size of the others.
        if !current.isEmpty {
            if groups.isEmpty || current.count >= max(target / 2, 1) {
                groups.append(current)
            } else {
                groups[groups.count - 1] += current
            }
        }

        for group in groups {
            let first = initial(of: group.first!, region: region)
            let last = initial(of: group.last!, region: region)

            let item = menu.addItem(
                withTitle: first == last ? first : "\(first) – \(last)",
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            for identifier in group { submenu.addItem(zoneItem(identifier, region: region)) }
            item.submenu = submenu
        }

        return menu
    }

    private func initial(of identifier: String, region: String) -> String {
        String(label(for: identifier, region: region).prefix(1)).uppercased()
    }

    private static let chunkThreshold = 40

    private func zoneItem(_ identifier: String, region: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: label(for: identifier, region: region),
            action: #selector(selectTimeZone(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = identifier
        timeZoneItems[identifier] = item
        return item
    }

    /// "Asia/Kolkata" in region "Asia" reads as "Kolkata"; the region prefix is
    /// already the submenu's own title.
    private func label(for identifier: String, region: String? = nil) -> String {
        let drop = (region == nil || region == "Other") ? 0 : 1
        let text = identifier
            .split(separator: "/")
            .dropFirst(drop)
            .joined(separator: " – ")
            .replacingOccurrences(of: "_", with: " ")
        return text.isEmpty ? identifier : text
    }

    /// Everything in the system's zoneinfo tree, not just the canonical names.
    ///
    /// `TimeZone.knownTimeZoneIdentifiers` drops the tz database's *links* — the
    /// aliases most people actually search for. It lists India as
    /// `Asia/Calcutta` with no Kolkata, and omits `US/Eastern` and the explicit
    /// `Etc/GMT±N` offsets entirely. Reading the directory recovers all of them,
    /// and the canonical list is unioned in so a layout change can never leave
    /// the picker empty.
    private static func allTimeZoneIdentifiers() -> [String] {
        var names = Set(TimeZone.knownTimeZoneIdentifiers.filter { !$0.hasPrefix("Etc/") })

        // Not zones: POSIX/right variants duplicate the tree, the rest are data
        // files that happen to live alongside it.
        //
        // Etc is dropped too, though its entries are real. They are fixed
        // offsets with no place attached, and their names run backwards by the
        // POSIX convention — Etc/GMT+5 is UTC-5 — which puts the name at odds
        // with the offset shown beside it. Nothing is lost: the zero-offset
        // members duplicate the plain UTC and GMT under "Other", and picking a
        // raw offset is not what a clock that names a place is for.
        let excludedRoots: Set<String> = ["posix", "right", "Factory", "SystemV", "Etc"]
        let roots = ["/var/db/timezone/zoneinfo", "/usr/share/zoneinfo"]

        for root in roots {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            for case let path as String in walker {
                let head = path.split(separator: "/").first.map(String.init) ?? path
                guard !excludedRoots.contains(head), !path.hasSuffix(".tab") else { continue }
                // Only real zones survive: directories and stray data files don't
                // resolve to a TimeZone.
                if TimeZone(identifier: path) != nil { names.insert(path) }
            }
            break
        }

        return names.sorted()
    }

    /// Moves the checkmark and refreshes the offsets, which shift with DST.
    private func refreshTimeZoneMenu() {
        let selected = Settings.shared.menuBarTimeZone

        let flags = TimeZoneFlags.shared

        for (identifier, item) in timeZoneItems {
            item.state = identifier == selected ? .on : .off
            guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else { continue }
            let region = identifier.split(separator: "/").first.map(String.init)
            item.title = "\(flags.flag(for: identifier))  "
                + "\(label(for: identifier, region: region)) — \(Self.offsetLabel(zone))"
        }

        let zone = Settings.shared.resolvedTimeZone
        let name = label(for: zone.identifier)
        let flag = flags.flag(for: zone.identifier)
        let following = selected.isEmpty ? " (system)" : ""
        selectedZoneHeader?.title = "\(flag)  \(name) — \(Self.offsetLabel(zone))\(following)"
        timeZoneItems[""]?.title = "\(flags.flag(for: TimeZone.current.identifier))  "
            + "System default — \(label(for: TimeZone.current.identifier))"
        timeZoneMenuItem?.title = "Timezone: \(flag) \(name)"
    }

    private static func offsetLabel(_ zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let minutes = abs(seconds) / 60
        return String(
            format: "GMT%@%d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60
        )
    }

    @objc private func selectTimeZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        Settings.shared.menuBarTimeZone = identifier
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTimeZoneMenu()
    }

    @objc private func openPopup() { popup.show() }

    @objc private func openPreferences() { preferences.show() }

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
