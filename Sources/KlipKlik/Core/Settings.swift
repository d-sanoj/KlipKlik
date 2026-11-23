import AppKit
import Combine

enum ThemePreference: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Popup width, per the design's `popupWidth()`.
enum PopupSize: String, CaseIterable, Identifiable {
    case compact, regular

    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Regular" }
    var width: CGFloat { self == .compact ? 280 : 340 }
}

/// Where the popup appears, per the design's `anchorMode`.
enum AnchorMode: String, CaseIterable, Identifiable {
    case cursor, icon

    var id: String { rawValue }
    var label: String { self == .cursor ? "Mouse cursor" : "Menu bar icon" }
}

/// What summons a shelf.
enum ShelfTrigger: String, CaseIterable, Identifiable {
    /// A landing pad appears beside the pointer the moment any drag starts.
    case automatic
    /// The landing pad appears only when the pointer is shaken mid-drag.
    case shake
    /// Nothing appears on its own; shelves come from the menu or the hot key.
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Any drag"
        case .shake: return "Shake while dragging"
        case .manual: return "Menu or ⌥⌘S"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Pick up any file and a drop target appears beside the pointer. "
                + "It needs no permissions, and it goes away by itself if you drop elsewhere."
        case .shake:
            return "Drags stay quiet until you shake the pointer left and right a few times, "
                + "then the drop target appears. Needs no permissions."
        case .manual:
            return "Nothing appears while you drag. Open a shelf first, then drop into it."
        }
    }
}

/// What happens when a scrolling screenshot finishes.
enum ScrollCaptureAction: String, CaseIterable, Identifiable {
    case copy, save, copyAndSave, window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copy: return "Copy to Clipboard"
        case .save: return "Save to Desktop"
        case .copyAndSave: return "Copy and Save to Desktop"
        case .window: return "Show in a Window"
        }
    }
}

/// How long an unpinned item may stay in history, on top of the daily purge.
enum HistoryAge: Int, CaseIterable, Identifiable {
    case off = 0
    case fifteenMinutes = 900
    case oneHour = 3600
    case fourHours = 14400
    case twelveHours = 43200

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Until purge"
        case .fifteenMinutes: return "15 min"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .twelveHours: return "12 hours"
        }
    }

    var interval: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let theme = "theme"
        static let pasteAutomatically = "pasteAutomatically"
        static let doubleTapWindow = "doubleTapWindow"
        static let purgeHour = "purgeHour"
        static let popupSize = "popupSize"
        static let anchorMode = "anchorMode"
        static let historySize = "historySize"
        static let stripFormatting = "stripFormatting"
        static let finderCutMove = "finderCutMove"
        static let glassOpacity = "glassOpacity"
        static let menuBarTimeZone = "menuBarTimeZone"
        static let ignoredApps = "ignoredApps"
        static let shelvesEnabled = "shelvesEnabled"
        static let shelfTrigger = "shelfTrigger"
        static let shelvesPersist = "shelvesPersist"
        static let cleanLinks = "cleanLinks"
        static let colorFormat = "colorFormat"
        static let historyMaxAge = "historyMaxAge"
        static let showSourceIcons = "showSourceIcons"
        static let snippetsEnabled = "snippetsEnabled"
        static let finderRenameKey = "finderRenameKey"
        static let finderPasteImage = "finderPasteImage"
        static let shelfKeepAfterDrag = "shelfKeepAfterDrag"
        static let watchRemovedApps = "watchRemovedApps"
        static let brewAutoCheck = "brewAutoCheck"
        static let cacheCleanerSkipped = "cacheCleanerSkipped"
        static let scrollCaptureAction = "scrollCaptureAction"
    }

    @Published var theme: ThemePreference {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Key.theme)
            applyAppearance()
        }
    }

    /// Send ⌘V to the previously frontmost app after copying, rather than only
    /// leaving the item on the clipboard.
    @Published var pasteAutomatically: Bool {
        didSet { UserDefaults.standard.set(pasteAutomatically, forKey: Key.pasteAutomatically) }
    }

    /// Maximum gap between the two ⌘ taps, in seconds.
    @Published var doubleTapWindow: Double {
        didSet { UserDefaults.standard.set(doubleTapWindow, forKey: Key.doubleTapWindow) }
    }

    /// Hour of day (local time) at which history is force-cleared.
    @Published var purgeHour: Int {
        didSet { UserDefaults.standard.set(purgeHour, forKey: Key.purgeHour) }
    }

    @Published var popupSize: PopupSize {
        didSet { UserDefaults.standard.set(popupSize.rawValue, forKey: Key.popupSize) }
    }

    @Published var anchorMode: AnchorMode {
        didSet { UserDefaults.standard.set(anchorMode.rawValue, forKey: Key.anchorMode) }
    }

    /// Ceiling on the in-memory history. Still never written to disk.
    @Published var historySize: Int {
        didSet { UserDefaults.standard.set(historySize, forKey: Key.historySize) }
    }

    /// Backed by `SMAppService`, not by UserDefaults: macOS owns this record,
    /// and the user can revoke it in System Settings without telling us. A
    /// stored copy would drift, so the value is read back from the service.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            do {
                try LaunchAtLogin.set(launchAtLogin)
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = LaunchAtLogin.explain(error)
                // Put the switch back where it was: it reports the system's
                // state, and the system just refused to change.
                setLaunchAtLoginWithoutSyncing(oldValue)
            }
        }
    }

    /// Set when a registration attempt failed, for the preferences pane to show.
    @Published var launchAtLoginError: String?

    private var isSyncingLaunchAtLogin = false

    /// Re-reads the system's answer — call when the preferences window appears,
    /// since the switch may have been flipped in System Settings meanwhile.
    func refreshLaunchAtLogin() {
        setLaunchAtLoginWithoutSyncing(LaunchAtLogin.isEnabled)
    }

    private func setLaunchAtLoginWithoutSyncing(_ value: Bool) {
        isSyncingLaunchAtLogin = true
        launchAtLogin = value
        isSyncingLaunchAtLogin = false
    }

    /// Paste text as plain text, discarding fonts, colours, and links — the
    /// equivalent of ⌘⇧V. Applied when *pasting*: history still stores every
    /// original flavour, so turning this off restores full formatting.
    @Published var stripFormatting: Bool {
        didSet { UserDefaults.standard.set(stripFormatting, forKey: Key.stripFormatting) }
    }

    /// Windows-style ⌘X cut-and-move for files in Finder.
    @Published var finderCutMove: Bool {
        didSet { UserDefaults.standard.set(finderCutMove, forKey: Key.finderCutMove) }
    }

    /// How solid the popup is: 0 is bare Liquid Glass, 1 is a fully opaque panel.
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: Key.glassOpacity) }
    }

    /// Time zone the menu-bar clock reads in. Empty means follow the Mac's own,
    /// so the clock keeps working if a stored identifier ever disappears.
    @Published var menuBarTimeZone: String {
        didSet { UserDefaults.standard.set(menuBarTimeZone, forKey: Key.menuBarTimeZone) }
    }

    /// Bundle identifiers whose copies never reach history.
    @Published var ignoredApps: [String] {
        didSet { UserDefaults.standard.set(ignoredApps, forKey: Key.ignoredApps) }
    }

    /// Drag shelves: floating trays you drop files into and drag back out.
    @Published var shelvesEnabled: Bool {
        didSet { UserDefaults.standard.set(shelvesEnabled, forKey: Key.shelvesEnabled) }
    }

    @Published var shelfTrigger: ShelfTrigger {
        didSet { UserDefaults.standard.set(shelfTrigger.rawValue, forKey: Key.shelfTrigger) }
    }

    /// Whether shelves survive quitting.
    ///
    /// Off by default, and deliberately so. Everything else KlipKlik keeps
    /// between launches is either metadata or sealed, but a shelf's staged
    /// content has to be a real readable file for a drag out of it to work at
    /// all — so persistence means plain files on disk until the user clears
    /// them. That is a fair trade for a shelf you are still filling, and the
    /// wrong default for an app whose promise is that nothing outlives a session.
    @Published var shelvesPersist: Bool {
        didSet { UserDefaults.standard.set(shelvesPersist, forKey: Key.shelvesPersist) }
    }

    /// Strip tracking parameters from a copied link before it reaches history.
    @Published var cleanLinks: Bool {
        didSet { UserDefaults.standard.set(cleanLinks, forKey: Key.cleanLinks) }
    }

    /// What the eyedropper copies.
    @Published var colorFormat: ColorFormat {
        didSet { UserDefaults.standard.set(colorFormat.rawValue, forKey: Key.colorFormat) }
    }

    /// Unpinned items older than this leave history before the daily purge.
    @Published var historyMaxAge: HistoryAge {
        didSet { UserDefaults.standard.set(historyMaxAge.rawValue, forKey: Key.historyMaxAge) }
    }

    /// The copying app's icon at the start of each popup row.
    @Published var showSourceIcons: Bool {
        didSet { UserDefaults.standard.set(showSourceIcons, forKey: Key.showSourceIcons) }
    }

    /// Typed abbreviations expand into their saved text.
    @Published var snippetsEnabled: Bool {
        didSet { UserDefaults.standard.set(snippetsEnabled, forKey: Key.snippetsEnabled) }
    }

    /// F2 starts renaming the selected item in Finder.
    @Published var finderRenameKey: Bool {
        didSet { UserDefaults.standard.set(finderRenameKey, forKey: Key.finderRenameKey) }
    }

    /// ⌘V in Finder with a copied picture saves it as a PNG file there.
    @Published var finderPasteImage: Bool {
        didSet { UserDefaults.standard.set(finderPasteImage, forKey: Key.finderPasteImage) }
    }

    /// Leave items on a shelf after they are dragged out of it.
    @Published var shelfKeepAfterDrag: Bool {
        didSet { UserDefaults.standard.set(shelfKeepAfterDrag, forKey: Key.shelfKeepAfterDrag) }
    }

    /// Offer to clean up after an app disappears from Applications.
    @Published var watchRemovedApps: Bool {
        didSet { UserDefaults.standard.set(watchRemovedApps, forKey: Key.watchRemovedApps) }
    }

    /// Look for outdated Homebrew packages in the background twice a day.
    @Published var brewAutoCheck: Bool {
        didSet { UserDefaults.standard.set(brewAutoCheck, forKey: Key.brewAutoCheck) }
    }

    /// What a finished scrolling screenshot does: copied, by default.
    @Published var scrollCaptureAction: ScrollCaptureAction {
        didSet { UserDefaults.standard.set(scrollCaptureAction.rawValue, forKey: Key.scrollCaptureAction) }
    }

    /// Paths the cache cleaner must never offer again.
    @Published var cacheCleanerSkipped: [String] {
        didSet { UserDefaults.standard.set(cacheCleanerSkipped, forKey: Key.cacheCleanerSkipped) }
    }

    func isIgnored(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredApps.contains(bundleID)
    }

    /// Resolved zone for the clock: the chosen one, or the system's.
    var resolvedTimeZone: TimeZone {
        TimeZone(identifier: menuBarTimeZone) ?? .current
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.theme: ThemePreference.auto.rawValue,
            Key.pasteAutomatically: true,
            Key.doubleTapWindow: 0.35,
            Key.purgeHour: 5,
            Key.popupSize: PopupSize.regular.rawValue,
            Key.anchorMode: AnchorMode.cursor.rawValue,
            Key.historySize: 500,
            Key.stripFormatting: false,
            Key.finderCutMove: true,
            Key.glassOpacity: 0.30,
            Key.menuBarTimeZone: "",
            Key.ignoredApps: [String](),
            Key.shelvesEnabled: true,
            Key.shelfTrigger: ShelfTrigger.automatic.rawValue,
            Key.shelvesPersist: false,
            Key.cleanLinks: true,
            Key.colorFormat: ColorFormat.hex.rawValue,
            Key.historyMaxAge: HistoryAge.off.rawValue,
            Key.showSourceIcons: true,
            Key.snippetsEnabled: true,
            Key.finderRenameKey: true,
            Key.finderPasteImage: true,
            Key.shelfKeepAfterDrag: false,
            Key.watchRemovedApps: true,
            Key.brewAutoCheck: true,
            Key.cacheCleanerSkipped: [String](),
            Key.scrollCaptureAction: ScrollCaptureAction.copy.rawValue
        ])

        theme = ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .auto
        pasteAutomatically = defaults.bool(forKey: Key.pasteAutomatically)
        doubleTapWindow = defaults.double(forKey: Key.doubleTapWindow)
        purgeHour = defaults.integer(forKey: Key.purgeHour)
        popupSize = PopupSize(rawValue: defaults.string(forKey: Key.popupSize) ?? "") ?? .regular
        anchorMode = AnchorMode(rawValue: defaults.string(forKey: Key.anchorMode) ?? "") ?? .cursor
        historySize = defaults.integer(forKey: Key.historySize)
        launchAtLogin = LaunchAtLogin.isEnabled
        stripFormatting = defaults.bool(forKey: Key.stripFormatting)
        finderCutMove = defaults.bool(forKey: Key.finderCutMove)
        glassOpacity = defaults.double(forKey: Key.glassOpacity)
        menuBarTimeZone = defaults.string(forKey: Key.menuBarTimeZone) ?? ""
        ignoredApps = defaults.stringArray(forKey: Key.ignoredApps) ?? []
        shelvesEnabled = defaults.bool(forKey: Key.shelvesEnabled)
        shelfTrigger = ShelfTrigger(rawValue: defaults.string(forKey: Key.shelfTrigger) ?? "")
            ?? .automatic
        shelvesPersist = defaults.bool(forKey: Key.shelvesPersist)
        cleanLinks = defaults.bool(forKey: Key.cleanLinks)
        colorFormat = ColorFormat(rawValue: defaults.string(forKey: Key.colorFormat) ?? "") ?? .hex
        historyMaxAge = HistoryAge(rawValue: defaults.integer(forKey: Key.historyMaxAge)) ?? .off
        showSourceIcons = defaults.bool(forKey: Key.showSourceIcons)
        snippetsEnabled = defaults.bool(forKey: Key.snippetsEnabled)
        finderRenameKey = defaults.bool(forKey: Key.finderRenameKey)
        finderPasteImage = defaults.bool(forKey: Key.finderPasteImage)
        shelfKeepAfterDrag = defaults.bool(forKey: Key.shelfKeepAfterDrag)
        watchRemovedApps = defaults.bool(forKey: Key.watchRemovedApps)
        brewAutoCheck = defaults.bool(forKey: Key.brewAutoCheck)
        cacheCleanerSkipped = defaults.stringArray(forKey: Key.cacheCleanerSkipped) ?? []
        scrollCaptureAction = ScrollCaptureAction(
            rawValue: defaults.string(forKey: Key.scrollCaptureAction) ?? ""
        ) ?? .copy
    }

    func applyAppearance() {
        NSApp.appearance = theme.appearance
    }
}
