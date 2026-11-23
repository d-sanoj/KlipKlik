import SwiftUI

/// Every page of the KlipKlik window, settings and Mac tools alike.
///
/// One window with a sidebar rather than a settings window plus a separate
/// tools window: everything the app does is then one click from the menu and
/// one glance down the sidebar, which is where people look for it.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, snippets, ignored, storage
    case shelf, finderDock
    case uninstall, leftovers, cache, homebrew, ports
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
        case .shelf, .finderDock: return .workspace
        case .uninstall, .leftovers, .cache, .homebrew, .ports: return .tools
        case .appearance, .shortcuts: return .app
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .snippets: return "Snippets"
        case .ignored: return "Ignored Apps"
        case .storage: return "Storage"
        case .shelf: return "Shelf"
        case .finderDock: return "Finder & Dock"
        case .uninstall: return "Uninstall Cleaner"
        case .leftovers: return "Leftover Files"
        case .cache: return "Cache Cleaner"
        case .homebrew: return "Homebrew Updates"
        case .ports: return "Ports"
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
        case .storage: return "What KlipKlik keeps, where, and how to clear it."
        case .shelf: return "Floating trays you drop files into and drag back out."
        case .finderDock: return "Extra keys for Finder, window previews in the Dock."
        case .uninstall, .leftovers, .cache, .homebrew, .ports: return ""
        case .appearance: return "How the popup looks."
        case .shortcuts: return "Every key KlipKlik answers to, and the permissions behind them."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .snippets: return "text.badge.plus"
        case .ignored: return "eye.slash.fill"
        case .storage: return "internaldrive.fill"
        case .shelf: return "tray.2.fill"
        case .finderDock: return "dock.rectangle"
        case .uninstall: return "trash.fill"
        case .leftovers: return "doc.badge.ellipsis"
        case .cache: return "sparkles"
        case .homebrew: return "shippingbox.fill"
        case .ports: return "network"
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
        case .finderDock: return Color(hex: 0x30B0C7)
        case .uninstall: return Color(hex: 0xFF3B30)
        case .leftovers: return Color(hex: 0xFF9F0A)
        case .cache: return Color(hex: 0x34C759)
        case .homebrew: return Color(hex: 0xA2845E)
        case .ports: return Color(hex: 0x32ADE6)
        case .appearance: return Color(hex: 0xFF2D55)
        case .shortcuts: return Color(hex: 0x5856D6)
        }
    }

    /// Tool pages bring their own header and fill the whole pane.
    var isTool: Bool { group == .tools }
}

/// Which page the window shows. Owned by the window controller, so the menu
/// can open the window straight onto a page.
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
    /// The tool pages' scans, kept while the window is closed.
    let tools = ToolsModel()
}

/// The window's sidebar.
struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var homebrew = Homebrew.shared
    let palette: Palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsPage.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(palette.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 3)
                        ForEach(group.pages) { page in row(page) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .frame(width: 244)
    }

    private func row(_ page: SettingsPage) -> some View {
        let isSelected = navigation.page == page
        return Button {
            navigation.page = page
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(page.tint.gradient)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: page.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if page == .homebrew, !homebrew.outdated.isEmpty {
                    Text("\(homebrew.outdated.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(hex: 0xFF3B30)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? palette.rowSelected : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
