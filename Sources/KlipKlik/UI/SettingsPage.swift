import SwiftUI

/// Every page of the KlipKlik window, settings and Mac tools alike.
///
/// One window with a sidebar rather than a settings window plus a separate
/// tools window: everything the app does is then one click from the menu and
/// one glance down the sidebar, which is where people look for it.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, snippets, ignored, storage
    case shelf, finder, plinth
    case uninstall, leftovers, cache, homebrew, ports, fileUsage
    case appearance, shortcuts

    enum Group: String, CaseIterable, Identifiable {
        case clipboard = "Clipboard"
        case workspace = "Files & Windows"
        case tools = "Mac Tools"
        case app = "KlipKlik"

        var id: String { rawValue }

        var pages: [SettingsPage] { SettingsPage.allCases.filter { $0.group == self } }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .general, .snippets, .ignored, .storage: return .clipboard
        case .shelf, .finder, .plinth: return .workspace
        case .uninstall, .leftovers, .cache, .homebrew, .ports, .fileUsage: return .tools
        case .appearance, .shortcuts: return .app
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .snippets: return "Snippets"
        case .ignored: return "Ignored Apps"
        case .storage: return "History & Data"
        case .shelf: return "Shelf"
        case .finder: return "Finder"
        case .plinth: return "Plinth Command Bar"
        case .uninstall: return "Uninstall Cleaner"
        case .leftovers: return "Leftover Files"
        case .cache: return "Cache Cleaner"
        case .homebrew: return "Homebrew"
        case .ports: return "Ports"
        case .fileUsage: return "What's Using It"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts & Permissions"
        }
    }

    /// The line under the page title.
    var subtitle: String {
        switch self {
        case .general: return "How copying and pasting behave, and how long history is kept."
        case .snippets: return "Short abbreviations that expand into text you type often."
        case .ignored: return "Apps whose copies are never recorded."
        case .storage: return "Your clipboard history: what KlipKlik keeps, where, and clearing it. Not your Mac's disk space — that is Cache Cleaner."
        case .shelf: return "Floating trays you drop files into and drag back out."
        case .finder: return "Extra keys for Finder."
        case .plinth: return "Say what to do with the selected files, under every Finder window."
        case .uninstall, .leftovers, .cache, .homebrew, .ports, .fileUsage: return ""
        case .appearance: return "How the popup looks."
        case .shortcuts: return "Every key KlipKlik answers to, and the permissions behind them."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .snippets: return "text.badge.plus"
        case .ignored: return "eye.slash.fill"
        case .storage: return "clock.arrow.circlepath"
        case .shelf: return "tray.2.fill"
        case .finder: return "folder.fill"
        case .plinth: return "command.square.fill"
        case .uninstall: return "trash.fill"
        case .leftovers: return "doc.badge.ellipsis"
        case .cache: return "sparkles"
        case .homebrew: return "shippingbox.fill"
        case .ports: return "network"
        case .fileUsage: return "lock.doc.fill"
        case .appearance: return "paintpalette.fill"
        case .shortcuts: return "keyboard.fill"
        }
    }

    /// The colour of the icon tile in the sidebar, System Settings style.
    var tint: Color {
        switch self {
        case .general: return Color(hex: 0x8E8E93)
        case .snippets: return Color(hex: 0xFF9500)
        case .ignored: return Color(hex: 0x5E5CE6)
        case .storage: return Color(hex: 0x636366)
        case .shelf: return Color(hex: 0x0A84FF)
        case .finder: return Color(hex: 0x30B0C7)
        case .plinth: return Color(hex: 0xBF5AF2)
        case .uninstall: return Color(hex: 0xFF3B30)
        case .leftovers: return Color(hex: 0xFF9F0A)
        case .cache: return Color(hex: 0x34C759)
        case .homebrew: return Color(hex: 0xA2845E)
        case .ports: return Color(hex: 0x32ADE6)
        case .fileUsage: return Color(hex: 0xAF52DE)
        case .appearance: return Color(hex: 0xFF2D55)
        case .shortcuts: return Color(hex: 0x5856D6)
        }
    }

    /// Tool pages bring their own layout and toolbar; settings pages are forms.
    var isTool: Bool { group == .tools }

    /// Extra words the sidebar search matches, so "password" finds the page
    /// that mentions password managers.
    var keywords: [String] {
        switch self {
        case .general: return ["paste", "strip", "format", "link", "tracking", "history", "login", "purge"]
        case .snippets: return ["expand", "abbreviation", "text", "typing"]
        case .ignored: return ["password", "exclude", "private"]
        case .storage: return ["storage", "clear", "pinned", "history", "data", "memory", "uninstall klipklik"]
        case .shelf: return ["drag", "drop", "shake", "tray", "files"]
        case .finder: return ["cut", "rename", "f2", "picture", "png", "paste"]
        case .plinth: return ["command", "convert", "resize", "compress", "zip", "video", "ffmpeg", "ai", "apple intelligence"]
        case .uninstall: return ["remove", "delete", "app", "trash", "removed", "leftover"]
        case .leftovers: return ["orphan", "removed", "junk"]
        case .cache: return ["clean", "space", "disk", "chatgpt", "claude", "xcode", "npm"]
        case .homebrew: return ["brew", "update", "upgrade", "cask", "formula", "uninstall", "packages"]
        case .ports: return ["port", "kill", "process", "server", "localhost"]
        case .fileUsage: return ["eject", "busy", "in use", "open", "lock", "disk", "volume", "file", "delete"]
        case .appearance: return ["theme", "dark", "light", "glass", "colour", "color", "icons"]
        case .shortcuts: return ["keys", "hotkey", "accessibility", "screen recording", "permission"]
        }
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmed)
            || keywords.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// Which page the window shows. Owned by the window controller, so the menu
/// can open the window straight onto a page.
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general {
        didSet {
            guard !isStepping, page != oldValue else { return }
            back.append(oldValue)
            forward.removeAll()
        }
    }
    /// Pages visited, for the toolbar's back and forward buttons — the same
    /// pair System Settings has.
    @Published private(set) var back: [SettingsPage] = []
    @Published private(set) var forward: [SettingsPage] = []
    private var isStepping = false

    func goBack() { step(from: &back, to: &forward) }
    func goForward() { step(from: &forward, to: &back) }

    private func step(from source: inout [SettingsPage], to destination: inout [SettingsPage]) {
        guard let next = source.popLast() else { return }
        destination.append(page)
        isStepping = true
        page = next
        isStepping = false
    }
    /// The tools' state, shared with the menu bar submenus.
    let tools = ToolsModel.shared
}
