import SwiftUI

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
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
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
                Text("Strip formatting when pasting").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.stripFormatting, palette: palette)
            }

            Caption(
                "Pastes text as plain text, like ⌘⇧V. Applied when pasting, not when copying — "
                    + "history keeps every original flavour, so turning this off restores full "
                    + "formatting. Hold ⌥⇧ while choosing an item to invert it just once. "
                    + "Images and files are unaffected.",
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
                Text("⌘X cuts files in Finder").prefLabel(palette)
            } trailing: {
                SwitchToggle(isOn: $settings.finderCutMove, palette: palette)
            }

            Caption(
                "Windows-style cut and move: ⌘X marks the selection, then ⌘V in another folder "
                    + "moves it instead of copying. Finder performs the move itself, so its "
                    + "conflict handling and undo still apply. Needs Accessibility.",
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

            MockupNote(
                text: "Launch at login is not wired up yet — it needs a login-item registration.",
                palette: palette
            )
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
                KeyChip(text: "⇧⌘C", palette: palette, muted: false, monospaced: true)
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Clear History").prefLabel(palette)
            } trailing: {
                KeyChip(text: "Not set", palette: palette, muted: true, monospaced: false)
            }

            PrefRow(palette: palette, showsDivider: true) {
                Text("Cut files in Finder").prefLabel(palette)
            } trailing: {
                KeyChip(text: "⌘X", palette: palette, muted: false, monospaced: true)
            }

            Text("Custom shortcut recording is coming in a future update.")
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

            accessibilitySection

            inPopupShortcuts
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCESSIBILITY PERMISSION")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.63)
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 20)

            HStack(spacing: 8) {
                Circle()
                    .fill(isTrusted ? Color(hex: 0x34C759) : palette.danger)
                    .frame(width: 8, height: 8)

                Text(isTrusted ? "Granted" : "Not granted")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)

                Spacer()

                Button("Open Settings…") { AccessibilityPermission.openSettingsPane() }
                    .font(.system(size: 12))

                Button("Reset permission") {
                    AccessibilityPermission.reset()
                }
                .font(.system(size: 12))
            }

            Text(
                isTrusted
                    ? "Double-tap ⌘, auto-paste, and ⌘X cut-and-move are active."
                    : "Double-tap ⌘, auto-paste, and ⌘X cut-and-move are all inactive "
                        + "until this is granted."
            )
            .font(.system(size: 11))
            .foregroundStyle(palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "The grant is tied to the app's code signature, which changes every time the app "
                    + "is rebuilt. That leaves a row in System Settings that looks enabled but no "
                    + "longer matches, and toggling it off and on does not fix it. "
                    + "“Reset permission” clears that stale entry and re-asks."
            )
            .font(.system(size: 11))
            .foregroundStyle(palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Polled rather than read once: the value changes outside the app, in
        // System Settings, so a static read would show a stale status.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            isTrusted = AccessibilityPermission.isTrusted
        }
        .onAppear { isTrusted = AccessibilityPermission.isTrusted }
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
        ("Invert strip formatting", "⌥⇧↩"),
        ("Paste nth item", "⌘1…⌘9"),
        ("Pin / unpin", "⌥P"),
        ("Delete item", "⌘⌫"),
        ("Clear history", "⌥⌘⌫"),
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
                "Fully clear is bare frosted glass — colour and light from behind still come "
                    + "through. Fully solid is an opaque panel. The backdrop is blurred past "
                    + "legibility at every setting, so whatever is behind the popup can never "
                    + "be read no matter where you put this.",
                palette: palette
            )

            Text("“Auto” follows your macOS appearance, including the automatic light/dark schedule.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    // MARK: Ignored Apps

    private var ignored: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copies from these apps won't be added to history.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .padding(.bottom, 10)

            ForEach(["1Password", "Terminal"], id: \.self) { name in
                HStack {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.searchBackground)
                            .frame(width: 20, height: 20)
                        Text(name).prefLabel(palette)
                    }
                    Spacer()
                    Text("×")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textTertiary)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.divider).frame(height: 1)
                }
            }

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
                .padding(.top, 12)

            MockupNote(
                text: "This list is a mockup. Password managers that mark the pasteboard as concealed are already ignored automatically.",
                palette: palette
            )
        }
    }

    // MARK: Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") stored")
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .padding(.bottom, 4)

            // The design says "on disk"; this build keeps history in memory only,
            // so the honest figure is the in-memory footprint.
            Text("Approx. \(formattedFootprint) in memory — nothing is written to disk.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .padding(.bottom, 18)

            Button {
                store.clearAll()
            } label: {
                Text("Clear All History")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.danger)
                    )
            }
            .buttonStyle(.plain)

            Text("History is also force-cleared daily at \(formattedPurgeHour), including after the Mac wakes from sleep.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 18)
        }
    }

    private var formattedFootprint: String {
        let bytes = store.items.reduce(0) { total, item in
            total + item.representations.reduce(0) { subtotal, bag in
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
        .padding(.vertical, 10)
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
            .padding(.bottom, 10)
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
final class PreferencesWindowController: NSWindowController {
    convenience init(store: HistoryStore) {
        let hosting = NSHostingController(rootView: PreferencesView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        // An accessory app has no Dock icon, so it must activate explicitly or
        // the preferences window opens behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
