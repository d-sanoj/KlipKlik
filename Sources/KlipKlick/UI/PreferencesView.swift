import SwiftUI
import UniformTypeIdentifiers

enum PrefsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, appearance, ignored, storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .appearance: return "Appearance"
        case .ignored: return "Ignored Apps"
        case .storage: return "Storage"
        }
    }
}

/// One entry in the ignored list: the app's real icon and name, resolved from
/// its bundle identifier.
private struct IgnoredAppRow: View {
    let bundleID: String
    let palette: Palette
    let onRemove: () -> Void

    @State private var isHovering = false

    /// nil once an app is uninstalled — the rule stays, it just cannot be
    /// prettified, so the identifier is shown instead of dropping the row.
    private var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The bundle's own display name, not the filename — `displayName(atPath:)`
    /// keeps the ".app" when the user has "show all extensions" turned on.
    private var name: String {
        guard let url else { return bundleID }
        let info = Bundle(url: url)?.infoDictionary
        let declared = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String
        return declared ?? url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.searchBackground)
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name).prefLabel(palette)
                    if url == nil {
                        Text("Not installed")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textTertiary)
                    }
                }
            }

            Spacer()

            Button(action: onRemove) {
                Text("×")
                    .font(.system(size: 15))
                    .foregroundStyle(isHovering ? palette.danger : palette.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Stop ignoring \(name)")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }
}

/// One privacy permission: what it gates, whether it is granted, and the two
/// things you can do about it.
private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let grantedNote: String
    let deniedNote: String
    let palette: Palette
    let openSettings: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.63)
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 14)

            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? Color(hex: 0x34C759) : palette.danger)
                    .frame(width: 8, height: 8)

                Text(granted ? "Granted" : "Not granted")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)

                Spacer()

                Button("Open Settings…", action: openSettings)
                    .font(.system(size: 12))
                Button("Reset permission", action: reset)
                    .font(.system(size: 12))
            }

            Text(granted ? grantedNote : deniedNote)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preferences, following the design's pill tab bar and row layout.
///
/// The design draws a simulated title bar with traffic lights because it is an
/// HTML prototype on a fake desktop; here the real `NSWindow` provides that, so
/// only the content below it is reproduced.
struct PreferencesView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject var store: HistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: PrefsTab = .general
    @State private var isTrusted = AccessibilityPermission.isTrusted
    @State private var canRecordScreen = TextGrab.isPermitted
    @State private var storageTick = 0

    private var palette: Palette { .resolve(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(palette.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: general
                    case .shortcuts: shortcuts
                    case .appearance: appearance
                    case .ignored: ignored
                    case .storage: storage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 560, height: 420)
        // `.regular` rather than `.clear` here: this window is dense text, and
        // the more transparent glass makes a settings form hard to read.
        .background(
            LiquidGlassBackground(
                style: .regular,
                tint: palette.glassTint,
                cornerRadius: 0,
                fallbackMaterial: .windowBackground
            )
        )
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(PrefsTab.allCases) { candidate in
                TabPill(label: candidate.label, isActive: tab == candidate, palette: palette) {
                    tab = candidate
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: General

    private var general: some View {
        VStack(spacing: 0) {
            pastingSection
            behaviourSection
            historySection
        }
    }

    private var pastingSection: some View {
        VStack(spacing: 0) {
            PrefRow(palette: palette, showsDivider: false) {
                Text("Strip Format when pasting").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.stripFormatting, palette: palette)
            }

            Caption(
                "Plain text, like ⌘ ⇧ V. Hold ⌥ ⇧ to invert it for one paste.",
                palette: palette,
                dividing: true
            )

            PrefRow(palette: palette, showsDivider: true) {
                Text("Paste automatically after selecting").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.pasteAutomatically, palette: palette)
            }
        }
    }

    private var behaviourSection: some View {
        VStack(spacing: 0) {
            PrefRow(palette: palette, showsDivider: false) {
                Text("⌘ X cuts files in Finder").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.finderCutMove, palette: palette)
            }

            Caption(
                "⌘ X marks, ⌘ V moves. Needs Accessibility.",
                palette: palette,
                dividing: true
            )
        }
    }

    private var historySection: some View {
        VStack(spacing: 0) {
            PrefRow(palette: palette, showsDivider: true) {
                Text("History size").prefLabel(palette)
            } trailing: {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.historySize) },
                            set: { settings.historySize = Int($0) }
                        ),
                        in: 50...1000,
                        step: 50
                    )
                    .frame(width: 150)
                    Text("\(settings.historySize) items")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 70, alignment: .leading)
                }
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Open popup at").prefLabel(palette)
            } trailing: {
                SegmentedPicker(selection: $settings.anchorMode, palette: palette) { $0.label }
            }

            PrefRow(palette: palette, showsDivider: false) {
                Text("Launch at login").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.launchAtLogin, palette: palette)
            }

            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else if settings.launchAtLogin, LaunchAtLogin.needsApproval {
                HStack(spacing: 8) {
                    Text("Waiting for your approval in System Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                    Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                        .font(.system(size: 11))
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        VStack(spacing: 0) {
            PrefRow(palette: palette, showsDivider: true) {
                Text("Open Clipboard History").prefLabel(palette)
            } trailing: {
                KeyChip(text: "⌘ ⌘", palette: palette, muted: false, monospaced: true)
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Alternate shortcut").prefLabel(palette)
            } trailing: {
                KeyChip(text: "⇧ ⌘ C", palette: palette, muted: false, monospaced: true)
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Clear History").prefLabel(palette)
            } trailing: {
                KeyChip(text: "Not set", palette: palette, muted: true, monospaced: false)
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Cut files in Finder").prefLabel(palette)
            } trailing: {
                KeyChip(text: "⌘ X", palette: palette, muted: false, monospaced: true)
            }

            Text("Custom shortcuts coming later.")
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

            permissionsSection

            inPopupShortcuts
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionRow(
                title: "ACCESSIBILITY",
                granted: isTrusted,
                grantedNote: "Double-tap ⌘, auto-paste, and ⌘ X cut-and-move are active.",
                deniedNote: "Double-tap ⌘, auto-paste, and ⌘ X cut-and-move need this.",
                palette: palette,
                openSettings: AccessibilityPermission.openSettingsPane,
                reset: { AccessibilityPermission.reset() }
            )

            PermissionRow(
                title: "SCREEN RECORDING",
                granted: canRecordScreen,
                grantedNote: "Screen text grab is active.",
                deniedNote: "Screen text grab needs this. The colour picker does not.",
                palette: palette,
                openSettings: TextGrab.openSettingsPane,
                reset: { TextGrab.resetPermission() }
            )

            Text("Both are tied to the code signature, so rebuilding stales them. "
                + "Reset clears the stale entry; Screen Recording also needs a relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Polled rather than read once: these change outside the app, in System
        // Settings, so a static read would show a stale status.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            isTrusted = AccessibilityPermission.isTrusted
            canRecordScreen = TextGrab.isPermitted
        }
        .onAppear {
            isTrusted = AccessibilityPermission.isTrusted
            canRecordScreen = TextGrab.isPermitted
        }
    }

    private var inPopupShortcuts: some View {
        VStack(spacing: 0) {
            Text("IN THE POPUP")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.63)
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .padding(.bottom, 6)

            ForEach(Self.popupShortcuts, id: \.0) { title, keys in
                PrefRow(palette: palette, showsDivider: title != Self.popupShortcuts.last?.0) {
                    Text(title).prefLabel(palette)
                } trailing: {
                    Text(keys)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }

    private static let popupShortcuts: [(String, String)] = [
        ("Navigate", "↑ ↓"),
        ("Paste selected", "↩"),
        ("Invert strip formatting", "⌥ ⇧ ↩"),
        ("Paste nth item", "⌘ 1 … ⌘ 9"),
        ("Pin / unpin", "⌥ P"),
        ("Delete item", "⌘ ⌫"),
        ("Clear history", "⌥ ⌘ ⌫"),
        ("Close", "esc")
    ]

    // MARK: Appearance

    private var appearance: some View {
        VStack(spacing: 0) {
            PrefRow(palette: palette, showsDivider: true) {
                Text("Theme").prefLabel(palette)
            } trailing: {
                SegmentedPicker(selection: $settings.theme, palette: palette) { $0.label }
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Popup size").prefLabel(palette)
            } trailing: {
                SegmentedPicker(selection: $settings.popupSize, palette: palette) { $0.label }
            }

            PrefRow(palette: palette, showsDivider: false) {
                Text("Popup background").prefLabel(palette)
            } trailing: {
                HStack(spacing: 8) {
                    Slider(value: $settings.glassOpacity, in: 0...1, step: 0.05) {
                        Text("Popup background")
                    } minimumValueLabel: {
                        Text("Clear").font(.system(size: 11))
                            .foregroundStyle(palette.textTertiary)
                    } maximumValueLabel: {
                        Text("Solid").font(.system(size: 11))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .labelsHidden()
                    .frame(width: 170)

                    Text("\(Int((settings.glassOpacity * 100).rounded()))%")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Caption(
                "Frosted glass to opaque. The backdrop stays unreadable throughout.",
                palette: palette
            )

        }
    }

    // MARK: Ignored Apps

    private var ignored: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copies from these apps are never recorded.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .padding(.bottom, 10)

            if settings.ignoredApps.isEmpty {
                Text("No apps ignored.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.vertical, 10)
            }

            ForEach(settings.ignoredApps, id: \.self) { bundleID in
                IgnoredAppRow(bundleID: bundleID, palette: palette) {
                    settings.ignoredApps.removeAll { $0 == bundleID }
                }
            }

            Button(action: addIgnoredApps) {
                Text("+ Add Application…")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                palette.divider,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            Caption(
                "Password managers are already skipped automatically.",
                palette: palette,
                dividing: false
            )
            .padding(.top, 4)
        }
    }

    /// Picks one or more apps and records their bundle identifiers. Identifiers
    /// rather than names, so a rename or a second copy in another folder cannot
    /// quietly stop the rule from matching.
    private func addIgnoredApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        panel.message = "Choose apps whose copies should never be recorded."

        // An accessory app has no windows of its own to bring forward, so the
        // panel would open behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !settings.ignoredApps.contains(bundleID)
            else { continue }
            settings.ignoredApps.append(bundleID)
        }
    }

    // MARK: Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") — "
                + "\(store.pinned.count) pinned")
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .padding(.bottom, 4)

            Text("\(formattedFootprint) in memory · \(formattedCache) cached · "
                + "\(formattedArchive) pinned on disk")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .padding(.bottom, 4)

            Caption(
                "Items move to encrypted files five minutes after being copied, to keep memory "
                    + "small. Cached files go when you quit; pinned ones stay until you clear them.",
                palette: palette
            )
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                dangerButton("Clear History") { store.clearAll() }
                plainButton("Clear Cached Files") {
                    DiskStore.shared.clearCache()
                    storageTick += 1
                }
            }

            Text("Also cleared daily at \(formattedPurgeHour). Neither touches pinned items.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 12)

            Divider().padding(.vertical, 16)

            Text("PINNED ITEMS")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.63)
                .foregroundStyle(palette.textTertiary)
                .padding(.bottom, 6)

            Text("Unpin one at a time from the popup's Pinned shelf, or drop all "
                + "\(store.pinned.count) here.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .padding(.bottom, 10)

            dangerButton("Clear Pinned Items") { confirmClearPinned() }

            Divider().padding(.vertical, 16)

            Text("UNINSTALL")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.63)
                .foregroundStyle(palette.textTertiary)
                .padding(.bottom, 6)

            Text("Revokes both permissions, removes the login item, deletes every setting "
                + "and every stored item. Optionally moves the app to the Trash.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            outlineButton("Uninstall KlipKlick…", action: confirmUninstall)
        }
        // Bumped after a clear, so the byte counts refresh.
        .id(storageTick)
    }

    private func dangerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.danger)
                )
        }
        .buttonStyle(.plain)
    }

    private func plainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.searchBackground)
                )
        }
        .buttonStyle(.plain)
    }

    private func outlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.danger)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.danger.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Pinned items are the one thing in the app that survives a reboot, so
    /// dropping the lot asks first.
    private func confirmClearPinned() {
        let count = store.pinned.count
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(count) pinned item\(count == 1 ? "" : "s")?"
        alert.informativeText = "Pinned items are the only history kept between launches. "
            + "This cannot be undone."
        alert.addButton(withTitle: "Clear Pinned")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.clearPinned()
        storageTick += 1
    }

    /// Two-step on purpose: the second question is the destructive one, and it
    /// is asked separately so "clean up after yourself" and "delete the app"
    /// cannot be answered with a single click.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall KlipKlick?"
        alert.informativeText = "Revokes Accessibility and Screen Recording, removes the "
            + "login item, and deletes every setting. Clipboard history is in memory and "
            + "goes when the app quits."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Uninstaller.tearDown()
        DiskStore.shared.destroyEverything()

        let trash = NSAlert()
        trash.alertStyle = .warning
        trash.messageText = "Move KlipKlick to the Trash?"
        trash.informativeText = "Everything else has been undone. The app itself can stay "
            + "if you would rather remove it yourself."
        trash.addButton(withTitle: "Move to Trash")
        trash.addButton(withTitle: "Keep the App")
        if trash.runModal() == .alertFirstButtonReturn {
            Uninstaller.moveToTrash { _ in NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    private var formattedCache: String { Self.bytes(DiskStore.shared.bytes(pinned: false)) }
    private var formattedArchive: String { Self.bytes(DiskStore.shared.bytes(pinned: true)) }

    private static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    private var formattedFootprint: String {
        let bytes = store.items.reduce(0) { total, item in
            total + (item.representations ?? []).reduce(0) { subtotal, bag in
                subtotal + bag.values.reduce(0) { $0 + $1.count }
            }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var formattedPurgeHour: String {
        var components = DateComponents()
        components.hour = settings.purgeHour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Pieces

private extension Text {
    func prefLabel(_ palette: Palette) -> some View {
        font(.system(size: 13)).foregroundStyle(palette.textPrimary)
    }
}

private struct PrefRow<Leading: View, Trailing: View>: View {
    let palette: Palette
    let showsDivider: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(palette.divider).frame(height: 1)
            }
        }
    }
}

private struct TabPill: View {
    let label: String
    let isActive: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? palette.accent : palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? palette.rowSelected : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

/// The design's inline segmented control: a filled track with a pill per option.
private struct SegmentedPicker<Value>: View
where Value: Identifiable & Hashable & CaseIterable, Value.AllCases: RandomAccessCollection {
    @Binding var selection: Value
    let palette: Palette
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Value.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12))
                        .foregroundStyle(selection == option ? .white : palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option ? palette.accent : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.searchBackground)
        )
    }
}

/// The design's custom 38×22 pill switch.
private struct SwitchToggle: View {
    @Binding var isOn: Bool
    let palette: Palette

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isOn ? palette.accent : palette.searchBackground)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .blackAlpha(0.3), radius: 1, y: 1)
                        .frame(width: 18, height: 18)
                        .padding(.horizontal, 2)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

private struct KeyChip: View {
    let text: String
    let palette: Palette
    let muted: Bool
    let monospaced: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(muted ? palette.textTertiary : palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.searchBackground)
            )
    }
}

/// Explanatory text under a settings row, optionally closing the row's group.
private struct Caption: View {
    let text: String
    let palette: Palette
    let dividing: Bool

    init(_ text: String, palette: Palette, dividing: Bool = false) {
        self.text = text
        self.palette = palette
        self.dividing = dividing
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                if dividing {
                    Rectangle().fill(palette.divider).frame(height: 1)
                }
            }
    }
}

private struct MockupNote: View {
    let text: String
    let palette: Palette

    var body: some View {
        Label(text, systemImage: "hammer")
            .font(.system(size: 11))
            .foregroundStyle(palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
    }
}

/// Hosts `PreferencesView` in a normal titled window.
/// Owns the Preferences window, and the app's Dock presence along with it.
///
/// KlipKlick runs as an accessory so it has no Dock icon and no ⌘Tab entry. That
/// is right for a menu-bar app but wrong for a settings window: a window with no
/// Dock icon cannot be found again once it slips behind something. So the policy
/// is switched to `.regular` for exactly as long as this window is open, and
/// back to `.accessory` when it closes.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    convenience init(store: HistoryStore) {
        let hosting = NSHostingController(rootView: PreferencesView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        // The login item can be revoked in System Settings while the window is
        // closed, so re-read it rather than trusting what the switch last showed.
        Settings.shared.refreshLaunchAtLogin()

        // Dock icon first: activating before the policy change leaves the app
        // frontmost with no icon, and the window can end up behind again.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only. Deferred, because dropping the policy while
        // the close is still in flight leaves the Dock tile behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
