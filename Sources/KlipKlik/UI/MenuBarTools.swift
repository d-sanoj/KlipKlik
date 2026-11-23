import AppKit
import Combine

/// The Mac tools as live submenus of the menu bar menu.
///
/// Each submenu fills itself when it opens and keeps itself current while it
/// is open: a scan that finishes, a port that appears, an update that lands
/// all show up without reopening it. The everyday action is one click — clear
/// the safe caches, update a package, stop a port, uninstall an app — and
/// anything that needs a closer look hands over to the matching Settings page.
///
/// Everything goes through `ToolsModel.shared`, the same state the Settings
/// pages show, so a scan started here is the one waiting there.
final class MenuBarTools: NSObject, NSMenuDelegate {
    /// Opens the KlipKlik window on a page.
    var openPage: ((SettingsPage) -> Void)?

    private let tools = ToolsModel.shared
    private let homebrew = Homebrew.shared

    private let uninstallMenu = NSMenu()
    private let cacheMenu = NSMenu()
    private let homebrewMenu = NSMenu()
    private let portsMenu = NSMenu()
    private let usageMenu = NSMenu()
    private var homebrewItem: NSMenuItem?
    /// Submenus on screen right now, so changes rebuild only what is visible.
    private var openMenus = Set<ObjectIdentifier>()
    private var cancellables = Set<AnyCancellable>()

    private static let rowFont = NSFont.menuFont(ofSize: 0)

    override init() {
        super.init()
        for menu in [uninstallMenu, cacheMenu, homebrewMenu, portsMenu, usageMenu] {
            menu.delegate = self
            menu.autoenablesItems = false
        }

        // Rebuild an open submenu when what it shows changes. Hopped to the
        // next turn: `objectWillChange` fires before the value has actually
        // changed. On the main *dispatch queue*, not `RunLoop.main`: the run
        // loop scheduler only runs in the default mode, and an open menu runs
        // the event-tracking mode — so the menu you are looking at never
        // updated.
        let changes: [AnyPublisher<Void, Never>] = [
            tools.uninstall.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tools.cache.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tools.ports.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            tools.fileUsage.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            homebrew.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildOpenMenus() }
            .store(in: &cancellables)
    }

    /// Adds the Mac Tools rows to `menu`.
    func install(into menu: NSMenu) {
        add("Uninstall App", symbol: "trash", submenu: uninstallMenu, to: menu)
        add("Clear Caches", symbol: "sparkles", submenu: cacheMenu, to: menu)
        homebrewItem = add("Homebrew", symbol: "shippingbox", submenu: homebrewMenu, to: menu)
        add("Ports", symbol: "network", submenu: portsMenu, to: menu)
        add("What's Using It", symbol: "lock.doc", submenu: usageMenu, to: menu)

        let leftovers = ActionItem(title: "Leftover Files…", symbol: "doc.badge.ellipsis") { [weak self] in
            self?.openPage?(.leftovers)
        }
        menu.addItem(leftovers)
    }

    /// The parent row's title, with the number of updates waiting. Called as
    /// the top-level menu opens.
    func refreshTitles() {
        let count = homebrew.outdated.count
        homebrewItem?.title = count > 0 ? "Homebrew (\(count) update\(count == 1 ? "" : "s"))" : "Homebrew"
    }

    @discardableResult
    private func add(_ title: String, symbol: String, submenu: NSMenu, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    /// Pops one submenu up on its own at `point`, and closes it after a few
    /// seconds — for looking at a submenu from a script during development,
    /// where opening the real menu would need a click.
    func popUpForPreview(_ name: String, at point: NSPoint) {
        let menus = ["uninstall": uninstallMenu, "cache": cacheMenu, "homebrew": homebrewMenu,
                     "ports": portsMenu, "usage": usageMenu]
        guard let menu = menus[name] else { return }
        // A timer in the common modes, which run while the menu tracks.
        let close = Timer(timeInterval: 16, repeats: false) { _ in menu.cancelTracking() }
        RunLoop.main.add(close, forMode: .common)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        openMenus.insert(ObjectIdentifier(menu))
        // Starting work is done here, once per opening, not on every rebuild.
        switch menu {
        case uninstallMenu: tools.uninstall.loadAppsIfNeeded()
        case cacheMenu: tools.cache.scanIfStale()
        case homebrewMenu:
            if homebrew.installed.isEmpty, Homebrew.isInstalled { homebrew.check(refresh: false) }
        case portsMenu: tools.ports.refresh()
        case usageMenu: tools.fileUsage.refreshVolumes()
        default: break
        }
        rebuild(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenus.remove(ObjectIdentifier(menu))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuildOpenMenus() {
        for menu in [uninstallMenu, cacheMenu, homebrewMenu, portsMenu, usageMenu]
        where openMenus.contains(ObjectIdentifier(menu)) {
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu {
        case uninstallMenu: buildUninstall(menu)
        case cacheMenu: buildCaches(menu)
        case homebrewMenu: buildHomebrew(menu)
        case portsMenu: buildPorts(menu)
        case usageMenu: buildUsage(menu)
        default: break
        }
    }

    // MARK: What's using it

    private func buildUsage(_ menu: NSMenu) {
        let model = tools.fileUsage
        if model.volumes.isEmpty {
            menu.addItem(note("No disks to eject"))
        } else {
            for volume in model.volumes {
                let name = FileManager.default.displayName(atPath: volume.path)
                let item = ActionItem(
                    title: "Eject \(name)", image: Self.small(NSWorkspace.shared.icon(forFile: volume.path))
                ) { [weak self] in
                    model.ejectFromMenu(volume) { self?.openPage?(.fileUsage) }
                }
                item.toolTip = "Ejects it, or says which programs are keeping it busy"
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Check a File or Folder…") { [weak self] in
            self?.openPage?(.fileUsage)
            model.chooseAndCheck()
        })
        menu.addItem(ActionItem(title: "Open What's Using It…") { [weak self] in self?.openPage?(.fileUsage) })
    }

    // MARK: Uninstall

    private func buildUninstall(_ menu: NSMenu) {
        let model = tools.uninstall
        if model.isRemoving || (model.isScanning && model.target != nil) {
            menu.addItem(note("Working on \(model.target?.name ?? "it")…"))
            menu.addItem(.separator())
        }

        if model.isLoadingApps, model.apps.isEmpty {
            menu.addItem(note("Finding apps…"))
        } else if model.apps.isEmpty {
            menu.addItem(note("No apps found"))
        } else {
            for app in model.apps {
                let item = ActionItem(title: app.name, image: Self.small(app.icon)) { [weak self] in
                    model.uninstallFromMenu(app) { self?.openPage?(.uninstall) }
                }
                if let size = model.appSizes[app.id] {
                    item.attributedTitle = Self.row(app.name, trailing: formattedBytes(size))
                }
                item.isEnabled = !model.isRemoving
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Review in Settings…") { [weak self] in self?.openPage?(.uninstall) })
    }

    // MARK: Caches

    private func buildCaches(_ menu: NSMenu) {
        let model = tools.cache
        if model.isCleaning {
            menu.addItem(note("Clearing…"))
        } else if model.isScanning || !model.hasScanned {
            menu.addItem(note("Measuring caches…"))
        } else if model.safeBytes > 0 {
            menu.addItem(ActionItem(
                title: "Clear Safe Caches — \(formattedBytes(model.safeBytes))", symbol: "sparkles"
            ) {
                model.cleanSafe()
            })
            menu.addItem(.separator())
            // What that click would clear, by kind, so it is not a leap of faith.
            for category in CacheItem.Category.allCases {
                let size = model.safeItems.filter { $0.category == category }.reduce(0) { $0 + $1.size }
                guard size > 0 else { continue }
                let item = note("")
                item.attributedTitle = Self.row(category.title, trailing: formattedBytes(size), dim: true)
                menu.addItem(item)
            }
        } else {
            menu.addItem(note("Nothing worth clearing"))
        }

        menu.addItem(.separator())
        // Stays open: the whole point is to watch the answer come in.
        menu.addItem(KeepOpenItem(
            title: model.isScanning ? "Scanning…" : "Scan Again",
            symbol: "arrow.clockwise",
            isEnabled: !model.isScanning && !model.isCleaning
        ) {
            model.scan()
        })
        menu.addItem(ActionItem(title: "Review in Settings…") { [weak self] in self?.openPage?(.cache) })
    }

    // MARK: Homebrew

    private func buildHomebrew(_ menu: NSMenu) {
        guard Homebrew.isInstalled else {
            menu.addItem(note("Homebrew is not installed"))
            return
        }

        if homebrew.isChecking, homebrew.outdated.isEmpty {
            menu.addItem(note("Checking for updates…"))
        } else if homebrew.outdated.isEmpty {
            menu.addItem(note("Everything is up to date"))
        } else {
            let updatingAll = homebrew.busy.contains(Homebrew.allID)
            for package in homebrew.outdated {
                let busy = updatingAll || homebrew.busy.contains(package.id)
                let item = ActionItem(
                    title: package.name,
                    symbol: package.isCask ? "macwindow" : "terminal"
                ) { [weak self] in
                    self?.homebrew.upgrade([package])
                }
                item.attributedTitle = Self.row(
                    busy ? "Updating \(package.name)…" : package.name,
                    trailing: "\(package.installed) → \(package.latest)"
                )
                item.isEnabled = !busy && !package.pinned
                item.toolTip = package.pinned ? "Pinned in Homebrew" : "Update \(package.name)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let all = ActionItem(title: "Update All (\(homebrew.outdated.count))") { [weak self] in
                self?.homebrew.upgrade()
            }
            all.isEnabled = !homebrew.isWorking && !homebrew.isChecking
            menu.addItem(all)
        }

        if let result = homebrew.lastResult {
            menu.addItem(.separator())
            menu.addItem(note(result))
        }

        menu.addItem(.separator())
        menu.addItem(KeepOpenItem(
            title: homebrew.isChecking ? "Checking…" : "Check for Updates",
            symbol: "arrow.clockwise",
            isEnabled: !homebrew.isChecking && !homebrew.isWorking
        ) { [weak self] in
            self?.homebrew.check(refresh: true)
        })
        menu.addItem(ActionItem(title: "Open Homebrew…") { [weak self] in self?.openPage?(.homebrew) })
    }

    // MARK: Ports

    private func buildPorts(_ menu: NSMenu) {
        let model = tools.ports
        if model.isLoading, model.ports.isEmpty {
            menu.addItem(note("Listing ports…"))
        } else if model.ports.isEmpty {
            menu.addItem(note("Nothing is listening"))
        } else {
            for port in model.ports.prefix(30) {
                let item = ActionItem(title: port.command, image: Self.processIcon(port.pid)) {
                    model.stop(port)
                }
                // Port and program in fixed columns, so "5000" and "51008"
                // put the program name in the same place.
                item.attributedTitle = Self.row(
                    String(port.port), port.command,
                    trailing: port.isLocalOnly ? "This Mac" : "Network"
                )
                item.toolTip = "Stop \(port.command) (PID \(port.pid)) to free port \(port.port)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(note("Choose one to stop it"))
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Open Ports…") { [weak self] in self?.openPage?(.ports) })
    }

    // MARK: Pieces

    /// A greyed-out line of information.
    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A row with a right-aligned last column: "Claude ……… 688 MB". With a
    /// `middle`, the first column is a fixed-width one (a port number) and
    /// the middle starts at the same place on every row.
    private static func row(
        _ leading: String, _ middle: String? = nil, trailing: String, dim: Bool = false
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        var stops = [NSTextTab(textAlignment: .right, location: 300)]
        if middle != nil { stops.insert(NSTextTab(textAlignment: .left, location: 58), at: 0) }
        style.tabStops = stops
        let first = middle.map { leading + "\t" + $0 } ?? leading
        let text = NSMutableAttributedString(
            string: first + "\t",
            attributes: [
                .font: rowFont,
                .paragraphStyle: style,
                .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]
        )
        text.append(NSAttributedString(
            string: trailing,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: rowFont.pointSize, weight: .regular),
                .paragraphStyle: style,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        if middle != nil {
            // Digits of equal width, so the numbers line up as a column too.
            text.addAttribute(
                .font,
                value: NSFont.monospacedDigitSystemFont(ofSize: rowFont.pointSize, weight: .regular),
                range: NSRange(location: 0, length: (leading as NSString).length)
            )
        }
        return text
    }

    /// The app's icon when the process is an app, otherwise a terminal symbol
    /// at the same size — every row gets an icon, so every title starts in
    /// the same place.
    private static func processIcon(_ pid: Int32) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleURL?.pathExtension == "app",
           let icon = app.icon {
            return small(icon)
        }
        return symbolIcon("terminal")
    }

    /// An SF Symbol drawn into a 16 × 16 template image, the size app icons
    /// get in these menus.
    static func symbolIcon(_ name: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        else { return NSImage(size: size) }
        let image = NSImage(size: size, flipped: false) { rect in
            let fit = symbol.size
            let origin = NSPoint(x: (rect.width - fit.width) / 2, y: (rect.height - fit.height) / 2)
            symbol.draw(in: NSRect(origin: origin, size: fit))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// An app icon at menu size, copied so the shared image keeps its size.
    private static func small(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A menu row that runs a closure — the menu's rows come and go with the data,
/// and a selector per row would need somewhere to keep each row's payload.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.image = image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        // After the menu has closed, so an alert it raises is not fighting
        // the menu's own tracking.
        DispatchQueue.main.async { [handler] in handler() }
    }
}

/// A menu row that does its work *without* closing the menu.
///
/// Ordinary menu rows close the menu when chosen. For "Scan Again" and "Check
/// for Updates" that throws away the very thing being waited for, so these are
/// drawn as a view — macOS leaves the menu open when a row's own view handles
/// the click — and the menu rebuilds in place as the answer arrives.
final class KeepOpenItem: NSMenuItem {
    init(title: String, symbol: String, isEnabled: Bool, action: @escaping () -> Void) {
        super.init(title: title, action: nil, keyEquivalent: "")
        self.isEnabled = isEnabled
        view = KeepOpenRowView(title: title, symbol: symbol, isEnabled: isEnabled, action: action)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private final class KeepOpenRowView: NSView {
    private let title: String
    private let symbolName: String
    private let isEnabled: Bool
    private let action: () -> Void

    /// Where the system draws a row's image and title, measured off real
    /// menus: titles sit at `imageX` in a menu without images, and move to
    /// `titleX` once rows carry them.
    private static let imageX: CGFloat = 16
    private static let titleX: CGFloat = 38
    private static let height: CGFloat = 24

    init(title: String, symbol: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbol
        self.isEnabled = isEnabled
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    private var isHighlighted: Bool { isEnabled && enclosingMenuItem?.isHighlighted == true }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = !isEnabled
            ? .disabledControlTextColor
            : isHighlighted ? .selectedMenuItemTextColor : .labelColor

        // Match the neighbours: an icon column only when the other rows
        // have one, otherwise the title starts where theirs do.
        let siblingsHaveImages = enclosingMenuItem?.menu?.items.contains { $0.image != nil } ?? false
        var textX = Self.imageX
        if siblingsHaveImages,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
               .withSymbolConfiguration(
                   NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                       .applying(.init(paletteColors: [color]))
               ) {
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: Self.imageX + (16 - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            ))
            textX = Self.titleX
        }

        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(
            at: NSPoint(x: textX, y: (bounds.height - textHeight) / 2),
            withAttributes: attributes
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        action()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
