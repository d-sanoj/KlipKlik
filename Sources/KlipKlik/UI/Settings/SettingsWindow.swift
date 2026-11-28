import AppKit
import SwiftUI

/// The KlipKlik window: settings and Mac tools behind one sidebar.
///
/// Built entirely from the system's own pieces — `NavigationSplitView`, a
/// sidebar `List`, grouped `Form`s, the real toolbar — so it looks, scrolls,
/// resizes, follows the accent colour and answers VoiceOver exactly as System
/// Settings does, instead of approximating it with hand-drawn controls.
struct SettingsView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var homebrew = Homebrew.shared
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { Settings.shared.refreshLaunchAtLogin() }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { navigation.page },
            set: { if let page = $0 { navigation.page = page } }
        )) {
            ForEach(SettingsPage.Group.allCases) { group in
                let pages = group.pages.filter { $0.matches(search) }
                if !pages.isEmpty {
                    Section(group.rawValue) {
                        ForEach(pages) { page in
                            SidebarRow(page: page, badge: badge(for: page))
                                .tag(page)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
    }

    private func badge(for page: SettingsPage) -> Int {
        page == .homebrew ? homebrew.outdated.count : 0
    }

    @ViewBuilder
    private var detail: some View {
        let tools = navigation.tools
        Group {
            switch navigation.page {
            case .general: GeneralPane()
            case .snippets: SnippetsPane()
            case .ignored: IgnoredAppsPane()
            case .storage: StoragePane(store: store)
            case .shelf: ShelfPane()
            case .finder: FinderPane()
            case .plinth: PlinthPane()
            case .appearance: AppearancePane()
            case .shortcuts: ShortcutsPane()
            case .uninstall: UninstallView(model: tools.uninstall)
            case .leftovers: OrphanView(model: tools.leftovers)
            case .cache: CacheView(model: tools.cache)
            case .homebrew: HomebrewView()
            case .ports: PortsView(model: tools.ports)
            case .fileUsage: FileUsageView(model: tools.fileUsage)
            }
        }
        .navigationTitle(navigation.page.title)
        .toolbar {
            // Every page has them, so the toolbar is the same height on every
            // page and the window's top edge never jumps as you move around.
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    navigation.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(navigation.back.isEmpty)
                .keyboardShortcut("[", modifiers: .command)

                Button {
                    navigation.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(navigation.forward.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
            }
        }
    }
}

/// A sidebar row: the page's symbol in its colour, at the sidebar's own
/// size, and a count badge where there is something waiting.
private struct SidebarRow: View {
    let page: SettingsPage
    let badge: Int

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol)
                .foregroundStyle(page.tint)
        }
        .badge(badge)
    }
}

// MARK: - Window

/// Owns the KlipKlik window, and the app's Dock presence along with it.
///
/// KlipKlik runs as an accessory, with no Dock icon and no ⌘Tab entry. That is
/// right for a menu-bar app but wrong for a window: one with no Dock icon
/// cannot be found again once it slips behind something. So the policy is
/// `.regular` for exactly as long as this window is open.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    /// Which page is showing; the menu sets it to open the window on a page.
    let pages: SettingsNavigation

    /// True between `show()` and `windowWillClose`, so an already-open window
    /// re-shown from the menu doesn't start the permission watch twice.
    private var isWatchingPermissions = false

    init(store: HistoryStore) {
        let pages = SettingsNavigation()
        self.pages = pages

        let hosting = NSHostingController(rootView: SettingsView(store: store, navigation: pages))
        // Lets `.navigationTitle` and `.toolbar` in the SwiftUI views reach
        // this AppKit window's real title bar and toolbar.
        hosting.sceneBridgingOptions = [.title, .toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setContentSize(NSSize(width: 920, height: 640))
        window.setFrameAutosaveName("KlipKlikSettings")
        window.isReleasedWhenClosed = false
        if window.frame.origin == .zero { window.center() }

        super.init(window: window)
        window.delegate = self
        // Confirmations on the tool pages are sheets on this window.
        ToolsAlert.window = window
    }

    required init?(coder: NSCoder) { nil }

    /// Opens the window, on `page` when given.
    func show(_ page: SettingsPage? = nil) {
        if let page { pages.page = page }
        // The login item can be revoked in System Settings while the window is
        // closed, so re-read it rather than trusting what the switch last showed.
        Settings.shared.refreshLaunchAtLogin()

        if !isWatchingPermissions {
            isWatchingPermissions = true
            PermissionStatus.shared.begin()
        }

        // Dock icon first: activating before the policy change leaves the app
        // frontmost with no icon, and the window can end up behind again.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if isWatchingPermissions {
            isWatchingPermissions = false
            PermissionStatus.shared.end()
        }
        // Deferred, because dropping the policy while the close is still in
        // flight leaves the Dock tile behind.
        DispatchQueue.main.async { [weak self] in
            dropDockIconUnlessWindowsRemain(except: self?.window)
        }
    }
}

// MARK: - Shared pieces for the panes

/// Keys drawn as keycaps, the way System Settings lists shortcuts.
struct KeyCaps: View {
    let keys: [String]

    init(_ keys: String) {
        self.keys = keys.split(separator: " ").map(String.init)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
            }
        }
    }
}

/// "Granted" with a green check, or "Not granted" with an orange warning.
struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(
            granted ? "Granted" : "Not granted",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        )
        .labelStyle(.titleAndIcon)
        .foregroundStyle(granted ? .green : .orange)
        .font(.callout)
    }
}

/// An app's icon and name from its bundle identifier.
struct AppIdentityLabel: View {
    let bundleID: String

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    private var name: String {
        guard let url else { return bundleID }
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                if url == nil {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
