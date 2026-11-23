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
    private var shelves: ShelfManager!
    private var fallbackHotKey: CarbonHotKey?
    private var pasteStackHotKey: CarbonHotKey?
    private var pasteStack: PasteStack!
    private let snippets = SnippetExpander()
    private let finderExtras = FinderExtras()
    private let removalWatcher = AppRemovalWatcher()
    private var statusItem: NSStatusItem!
    /// Built on first use. Constructing it eagerly cost a window, an
    /// `NSHostingController` and the whole SwiftUI view graph at launch — for a
    /// window most people open once, and many never open at all.
    private var preferences: PreferencesWindowController?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    private var clockTimer: Timer?
    /// Last string written to the status item, so a tick that changes nothing
    /// doesn't relayout the menu bar.
    private var lastClockTitle: String?
    private var cutPending = false
    /// Delegates for the lazily-built timezone submenus. `NSMenu.delegate` is a
    /// weak reference, so these have to be held somewhere.
    private var lazyMenus: [LazyMenu] = []
    /// The "System default" row, the one zone item that lives above the regions.
    private var systemZoneItem: NSMenuItem?
    private var timeZoneMenuItem: NSMenuItem!
    private var stripFormattingItem: NSMenuItem!
    private var newShelfItem: NSMenuItem!
    private var pasteStackItem: NSMenuItem!
    private var restoreLinkItem: NSMenuItem!
    private var homebrewItem: NSMenuItem!
    /// Disabled row at the top of the Timezone submenu naming the current zone.
    private var selectedZoneHeader: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.applyAppearance()

        monitor = ClipboardMonitor(store: store)
        purge = DailyPurge(store: store)
        popup = PopupController(store: store)

        popup.onOpenPreferences = { [weak self] in self?.showPreferences() }
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

        // Shortening the age limit applies at once, like the size limit.
        Settings.shared.$historyMaxAge
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.store.pruneExpired() }
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
            .write(toFile: "/tmp/klipklik-trust.txt", atomically: true, encoding: .utf8)

        monitor.start()
        purge.start()

        // Started after the monitor, so its own pasteboard writes have something
        // to report to.
        shelves = ShelfManager()
        shelves.onDidWriteToPasteboard = { [weak self] changeCount in
            self?.monitor.ignoreChangeCount(changeCount)
        }
        popup.onAddToShelf = { [weak self] item in
            guard let self else { return false }
            return shelves.addToShelf(item, from: store)
        }
        popup.canAddToShelf = { [weak self] item in
            guard let self, Settings.shared.shelvesEnabled else { return false }
            return ShelfManager.canShelve(item, from: store)
        }
        shelves.start()

        finderCutMove = FinderCutMove()
        finderCutMove.onArmedChanged = { [weak self] armed in
            self?.setStatusIcon(cutPending: armed)
        }
        finderCutMove.start()

        startExtras()

        // First run is otherwise silent — no Dock icon, no window, just a new
        // clock in the menu bar that nobody asked about. Say hello once, and let
        // that window ask for the permissions.
        //
        // On later launches, surface the same window whenever Accessibility is
        // missing rather than staying quiet: the signature changes on every
        // update, which silently revokes the grant and leaves the ⌘⌘ trigger,
        // auto-paste and cut-and-move inert with no explanation.
        //
        // Deliberately not the bare `AXIsProcessTrustedWithOptions` alert — it
        // arrives with no icon and no account of what it unlocks, which reads
        // as something the app did wrong.
        if !OnboardingWindowController.hasBeenSeen {
            showOnboarding(mode: .welcome)
        } else if !AccessibilityPermission.isTrusted {
            showOnboarding(mode: .permissions)
        }
    }

    /// The features added alongside the clipboard: paste stack, snippets,
    /// Finder keys, the removal watcher and Homebrew checks.
    /// Each reports its own pasteboard writes to the monitor, like the popup
    /// and the shelves do, so none of them shows up in history as a copy.
    private func startExtras() {
        let ignore: (Int) -> Void = { [weak self] changeCount in
            self?.monitor.ignoreChangeCount(changeCount)
        }

        pasteStack = PasteStack(store: store)
        pasteStack.onDidWriteToPasteboard = ignore
        pasteStack.$isActive
            .combineLatest(pasteStack.$queue)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshStatusIcon() }
            .store(in: &cancellables)
        monitor.onCapture = { [weak self] item in self?.pasteStack.collect(item) }
        // ⌃⌥⌘C: start or stop collecting. Carbon, so it needs no permission.
        pasteStackHotKey = CarbonHotKey(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) { [weak self] in
            self?.togglePasteStack()
        }

        snippets.onDidWriteToPasteboard = ignore
        snippets.start()

        finderExtras.onAddToShelf = { [weak self] urls in self?.shelves.addFiles(urls) }
        finderExtras.start()
        monitor.onPasteboardChange = { [weak self] in self?.finderExtras.update() }
        Settings.shared.$finderRenameKey.map { _ in () }
            .merge(with: Settings.shared.$finderPasteImage.map { _ in () },
                   Settings.shared.$shelvesEnabled.map { _ in () })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.finderExtras.update() }
            .store(in: &cancellables)

        removalWatcher.onAppRemoved = { [weak self] removed in self?.offerCleanup(after: removed) }
        Settings.shared.$watchRemovedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in on ? self?.removalWatcher.start() : self?.removalWatcher.stop() }
            .store(in: &cancellables)

        Homebrew.shared.start()
    }

    private func togglePasteStack() {
        if !pasteStack.isActive, !AccessibilityPermission.isTrusted {
            let alert = NSAlert()
            alert.messageText = "Paste stack needs Accessibility"
            alert.informativeText = "Each ⌘V is handed back to the app you are pasting into, "
                + "which needs Accessibility. Turn it on for KlipKlik, then start the stack again."
            alert.addButton(withTitle: "Open Settings…")
            alert.addButton(withTitle: "Later")
            if FloatingAlert.run(alert) == .alertFirstButtonReturn { AccessibilityPermission.allow() }
            return
        }
        pasteStack.toggle()
    }

    /// An app left Applications and left files behind: offer to clear them.
    private func offerCleanup(after removed: AppRemovalWatcher.RemovedApp) {
        let total = removed.leftovers.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let alert = NSAlert()
        alert.messageText = "\(removed.name) left \(removed.leftovers.count) "
            + "item\(removed.leftovers.count == 1 ? "" : "s") behind"
        alert.informativeText = "Its settings, caches and support files (\(formattedBytes(total))) "
            + "are still on this Mac. Review them before anything is removed."
        alert.addButton(withTitle: "Review…")
        alert.addButton(withTitle: "Not Now")
        guard FloatingAlert.run(alert) == .alertFirstButtonReturn else { return }
        showPreferences(.uninstall)
        preferences?.pages.tools.uninstall.show(removed: removed)
    }

    private func showOnboarding(mode: OnboardingView.Mode) {
        let controller = OnboardingWindowController(mode: mode)
        // Held only while it is on screen. Keeping it after the close kept its
        // SwiftUI view graph — and everything that view had subscribed to —
        // alive for the rest of the session.
        controller.onClose = { [weak self] in self?.onboarding = nil }
        onboarding = controller
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        doubleTap.stop()
        finderCutMove.stop()
        finderExtras.stop()
        snippets.stop()
        removalWatcher.stop()
        pasteStack?.stop()
        shelves.stop()
        clockTimer?.invalidate()
        // Pinned items are an archive and stay; everything else, including its
        // encrypted swap on disk, goes with the session.
        store.endSession()
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
        if cutPending {
            button.toolTip = "Cut pending — press ⌘ V in another folder to move"
        } else if let stack = pasteStack, stack.isActive {
            button.toolTip = "Paste stack — \(stack.queue.count) waiting. ⌃⌥⌘C stops it."
        } else {
            button.toolTip = "KlipKlik — \(zone.identifier.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// Scissors while a Finder cut is waiting to be pasted, so an armed cut is
    /// visible rather than silent. No glyph otherwise: the time is the item.
    private func setStatusIcon(cutPending: Bool) {
        self.cutPending = cutPending
        refreshStatusIcon()
    }

    /// Scissors win over the stack: a pending cut is the more urgent thing to
    /// know about, and it clears itself on the next paste.
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if cutPending {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut pending")
        } else if pasteStack?.isActive == true {
            button.image = NSImage(
                systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Paste stack on"
            )
        } else {
            button.image = nil
        }
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

    /// The menu behind the clock.
    ///
    /// Grouped under headings, with a symbol on every row so the eye can find
    /// a row by its picture: what you use while copying first, then the Mac
    /// tools — each one a row of its own, not a submenu to hunt through — then
    /// the app itself.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Offsets move with DST and the selection can change elsewhere, so the
        // titles are refreshed each time the menu is about to open.
        menu.delegate = self

        menu.addItem(.sectionHeader(title: "Clipboard"))

        addItem(to: menu, "Clipboard History", symbol: "doc.on.clipboard",
                action: #selector(openPopup), key: "c", modifiers: [.shift, .command])

        newShelfItem = addItem(to: menu, "New Shelf", symbol: "tray.2",
                               action: #selector(newShelf), key: "s", modifiers: [.option, .command])

        pasteStackItem = addItem(to: menu, "Start Paste Stack", symbol: "square.stack.3d.up",
                                 action: #selector(togglePasteStackFromMenu),
                                 key: "c", modifiers: [.control, .option, .command])

        // Same wording as the Preferences row, and the same underlying setting:
        // this is that switch, not a second one that could disagree with it.
        stripFormattingItem = addItem(to: menu, "Strip Format when pasting", symbol: "textformat",
                                      action: #selector(toggleStripFormatting))

        // Shown only while the clipboard holds a link this cleaned.
        restoreLinkItem = addItem(to: menu, "Restore Original Link", symbol: "link.badge.plus",
                                  action: #selector(restoreOriginalLink))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Mac Tools"))

        for page in SettingsPage.Group.tools.pages {
            let item = addItem(to: menu, page.title + "…", symbol: page.symbol,
                               action: #selector(openSettingsPage(_:)))
            item.representedObject = page.rawValue
            if page == .homebrew { homebrewItem = item }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "KlipKlik"))

        timeZoneMenuItem = addItem(to: menu, "Timezone", symbol: "globe", action: nil)
        timeZoneMenuItem.submenu = buildTimeZoneMenu()

        addItem(to: menu, "Settings…", symbol: "gearshape", action: #selector(openPreferences),
                key: ",", modifiers: [.command])

        menu.addItem(.separator())

        // Routed through our own selector rather than `terminate:`, so the
        // symbol is ours and matches the rest of the menu.
        addItem(to: menu, "Quit KlipKlik", symbol: "power", action: #selector(quitApp),
                key: "q", modifiers: [.command])

        return menu
    }

    /// One row: title, symbol, and the key it shows. The key is shown for the
    /// shortcuts that also work outside the menu, so the menu teaches them.
    @discardableResult
    private func addItem(
        to menu: NSMenu,
        _ title: String,
        symbol: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = action == nil ? nil : self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// Every zone on the system, grouped by region:
    /// `America/Argentina/Buenos_Aires` becomes *America ▸ Argentina – Buenos Aires*.
    ///
    /// The top of the menu names the zone in force, so the current setting is
    /// readable without hunting through submenus for the checkmark.
    /// Built on first open, not at launch. Populating this eagerly meant walking
    /// the whole zoneinfo tree and allocating ~600 `NSMenuItem`s before the app
    /// had shown anything, then keeping every one of them for the session.
    private func buildTimeZoneMenu() -> NSMenu {
        let menu = NSMenu()
        let lazyMenu = LazyMenu(
            build: { [weak self] menu in self?.populateTimeZoneMenu(menu) },
            refresh: { [weak self] menu in self?.refreshTimeZoneRoot(menu) }
        )
        menu.delegate = lazyMenu
        lazyMenus.append(lazyMenu)
        return menu
    }

    /// The regions, and the two rows above them. One item per region — the zones
    /// inside are left to `regionMenu`, which builds them when that region is
    /// actually opened.
    private func populateTimeZoneMenu(_ menu: NSMenu) {
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
        systemZoneItem = system

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

            let submenu = NSMenu()
            let lazyMenu = LazyMenu(
                build: { [weak self] menu in
                    self?.populateRegionMenu(menu, identifiers: identifiers, region: region)
                },
                refresh: { [weak self] menu in self?.refreshZoneItems(in: menu) }
            )
            submenu.delegate = lazyMenu
            lazyMenus.append(lazyMenu)
            regionItem.submenu = submenu
        }
    }

    /// A region's zones, split into alphabetical runs once the list grows past
    /// what fits on screen — a 100-entry scrolling menu is unusable, and Asia
    /// alone is well past that.
    private func populateRegionMenu(_ menu: NSMenu, identifiers: [String], region: String) {
        guard identifiers.count > Self.chunkThreshold else {
            for identifier in identifiers { menu.addItem(zoneItem(identifier, region: region)) }
            return
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

    /// The one line the status menu itself shows. Cheap enough to run every time
    /// that menu opens, which is the point: the ~600 zone rows are no longer
    /// touched here, only when the region holding them is opened.
    private func refreshTimeZoneMenu() {
        let zone = Settings.shared.resolvedTimeZone
        timeZoneMenuItem?.title = "Timezone: \(TimeZoneFlags.shared.flag(for: zone.identifier)) "
            + "\(label(for: zone.identifier))"
    }

    /// The two rows above the regions, refreshed when the timezone submenu opens.
    private func refreshTimeZoneRoot(_ menu: NSMenu) {
        let flags = TimeZoneFlags.shared
        let selected = Settings.shared.menuBarTimeZone
        let zone = Settings.shared.resolvedTimeZone
        let following = selected.isEmpty ? " (system)" : ""

        selectedZoneHeader?.title = "\(flags.flag(for: zone.identifier))  "
            + "\(label(for: zone.identifier)) — \(Self.offsetLabel(zone))\(following)"
        systemZoneItem?.title = "\(flags.flag(for: TimeZone.current.identifier))  "
            + "System default — \(label(for: TimeZone.current.identifier))"
        systemZoneItem?.state = selected.isEmpty ? .on : .off
    }

    /// Checkmark and offset for the zones in one opened region. Offsets shift
    /// with DST, so they are written on open rather than only at build.
    private func refreshZoneItems(in menu: NSMenu) {
        let selected = Settings.shared.menuBarTimeZone
        let flags = TimeZoneFlags.shared

        for item in menu.items {
            // Chunked regions ("A – F") hold their zones a level down. Those
            // submenus have no delegate, so they are refreshed from here.
            if let submenu = item.submenu {
                refreshZoneItems(in: submenu)
                continue
            }
            guard let identifier = item.representedObject as? String,
                  !identifier.isEmpty,
                  let zone = TimeZone(identifier: identifier)
            else { continue }

            item.state = identifier == selected ? .on : .off
            let region = identifier.split(separator: "/").first.map(String.init)
            item.title = "\(flags.flag(for: identifier))  "
                + "\(label(for: identifier, region: region)) — \(Self.offsetLabel(zone))"
        }
    }

    private static func offsetLabel(_ zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let minutes = abs(seconds) / 60
        return String(
            format: "GMT%@%d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60
        )
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func toggleStripFormatting() {
        Settings.shared.stripFormatting.toggle()
    }

    @objc private func selectTimeZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        Settings.shared.menuBarTimeZone = identifier
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTimeZoneMenu()
        // Preferences may have moved it since this menu was last opened.
        stripFormattingItem?.state = Settings.shared.stripFormatting ? .on : .off
        // Hidden rather than disabled: a permanently greyed row for a feature you
        // turned off is just clutter explaining itself.
        newShelfItem?.isHidden = !Settings.shared.shelvesEnabled

        if let stack = pasteStack {
            pasteStackItem?.title = stack.isActive
                ? "Stop Paste Stack (\(stack.queue.count) waiting)"
                : "Start Paste Stack"
        }
        restoreLinkItem?.isHidden = !monitor.linkCleaner.canRestore

        let outdated = Homebrew.shared.outdated.count
        homebrewItem?.title = outdated > 0
            ? "\(SettingsPage.homebrew.title) (\(outdated))…"
            : SettingsPage.homebrew.title + "…"
    }

    @objc private func togglePasteStackFromMenu() { togglePasteStack() }

    @objc private func restoreOriginalLink() { monitor.linkCleaner.restoreOriginal() }

    @objc private func openSettingsPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let page = SettingsPage(rawValue: raw)
        else { return }
        showPreferences(page)
    }

    @objc private func openPopup() { popup.show() }

    @objc private func newShelf() { shelves.newShelf() }

    @objc private func openPreferences() { showPreferences() }

    private func showPreferences(_ page: SettingsPage? = nil) {
        if preferences == nil {
            preferences = PreferencesWindowController(store: store)
        }
        preferences?.show(page)
    }

    // MARK: Triggers

    private func setUpTriggers() {
        doubleTap = DoubleTapCommandMonitor()
        doubleTap.onTrigger = { [weak self] in self?.popup.toggle() }
        doubleTap.start()

        // Secondary trigger. Carbon hot keys need no Accessibility permission, so
        // this keeps KlipKlik reachable before the user grants it.
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
            forName: Notification.Name("com.sanoj.KlipKlik.show"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.popup.show()
        }
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlik.preferences"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.showPreferences((note.object as? String).flatMap(SettingsPage.init(rawValue:)))
        }
        // Opens a shelf, and fills it with whatever paths the notification
        // carries. The shelf is a drag target, and a drag is the one gesture
        // that cannot be synthesised without Accessibility — so this is the only
        // way to exercise the window itself during development.
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlik.newShelf"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let shelf = shelves.store.addShelf()
            if let paths = note.object as? String, !paths.isEmpty {
                let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
                shelves.store.add(urls: urls, to: shelf.id)
            }
        }

        // Opens the KlipKlik window at a page ("uninstall", "cache", "shelf"…),
        // for driving it from scripts during development.
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlik.tools"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let page = (note.object as? String).flatMap(SettingsPage.init(rawValue:)) ?? .uninstall
            self?.showPreferences(page)
        }

        // Shows the notch drop pad. A drag cannot be synthesised at all — it is a
        // modal tracking loop in another process — so this is the only way to
        // look at the pad during development. Object "targeted" shows the
        // expanded state, anything else the waiting one, and "off" hides it.
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlik.showPad"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let mode = note.object as? String ?? ""
            mode == "off"
                ? self?.shelves.dismissPad()
                : self?.shelves.previewPad(targeted: mode == "targeted")
        }

        // Pins the newest two entries, so the PINNED section can be exercised
        // without a mouse or keyboard.
        center.addObserver(
            forName: Notification.Name("com.sanoj.KlipKlik.pinNewest"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for item in store.items.prefix(2) { store.togglePin(item) }
        }
    }
}
