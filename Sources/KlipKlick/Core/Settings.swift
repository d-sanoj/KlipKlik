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
        static let launchAtLogin = "launchAtLogin"
        static let stripFormatting = "stripFormatting"
        static let finderCutMove = "finderCutMove"
        static let glassOpacity = "glassOpacity"
        static let menuBarTimeZone = "menuBarTimeZone"
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

    /// Mockup only — wiring this needs `SMAppService` registration.
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin) }
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
            Key.launchAtLogin: false,
            Key.stripFormatting: false,
            Key.finderCutMove: true,
            Key.glassOpacity: 0.30,
            Key.menuBarTimeZone: ""
        ])

        theme = ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .auto
        pasteAutomatically = defaults.bool(forKey: Key.pasteAutomatically)
        doubleTapWindow = defaults.double(forKey: Key.doubleTapWindow)
        purgeHour = defaults.integer(forKey: Key.purgeHour)
        popupSize = PopupSize(rawValue: defaults.string(forKey: Key.popupSize) ?? "") ?? .regular
        anchorMode = AnchorMode(rawValue: defaults.string(forKey: Key.anchorMode) ?? "") ?? .cursor
        historySize = defaults.integer(forKey: Key.historySize)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        stripFormatting = defaults.bool(forKey: Key.stripFormatting)
        finderCutMove = defaults.bool(forKey: Key.finderCutMove)
        glassOpacity = defaults.double(forKey: Key.glassOpacity)
        menuBarTimeZone = defaults.string(forKey: Key.menuBarTimeZone) ?? ""
    }

    func applyAppearance() {
        NSApp.appearance = theme.appearance
    }
}
