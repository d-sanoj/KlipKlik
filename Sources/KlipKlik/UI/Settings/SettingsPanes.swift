import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The settings pages. Each is a grouped `Form`: the system lays out the rows,
// draws the switches and pop-up menus, and puts a second line of text under a
// title as its description, exactly as System Settings does.

/// A grouped form with switches, the house style for every settings page.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: $settings.stripFormatting) {
                    Text("Paste as plain text")
                    Text("Like ⌘⇧V. Hold ⌥⇧ while choosing an item to do the opposite once.")
                }
                Toggle(isOn: $settings.pasteAutomatically) {
                    Text("Paste after choosing an item")
                    Text("Otherwise the item is only put on the clipboard.")
                }
                Picker("Open the popup at", selection: $settings.anchorMode) {
                    ForEach(AnchorMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Pasting")
            }

            Section {
                Toggle(isOn: $settings.cleanLinks) {
                    Text("Remove tracking from copied links")
                    Text("Strips utm_source, fbclid, YouTube's si= and similar. "
                        + "Restore Original Link in the menu bar puts the full link back.")
                }
            } header: {
                Text("Links")
            }

            Section {
                LabeledContent("Keep up to") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.historySize) },
                                set: { settings.historySize = Int($0) }
                            ),
                            in: 50...1000,
                            step: 50
                        )
                        .frame(width: 180)
                        Text("\(settings.historySize) items")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                Picker(selection: $settings.historyMaxAge) {
                    ForEach(HistoryAge.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Forget items after")
                    Text("History is also cleared every day at \(Self.purgeTime(settings.purgeHour)). "
                        + "Pinned items are always kept.")
                }
            } header: {
                Text("History")
            }

            Section {
                Picker(selection: $settings.scrollCaptureAction) {
                    ForEach(ScrollCaptureAction.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("When a scrolling screenshot finishes")
                    Text("Always full sharpness. Copied pictures stay in clipboard history, "
                        + "so an earlier one is never lost.")
                }
            } header: {
                Text("Screenshots")
            }

            Section {
                Toggle("Open KlipKlik at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else if settings.launchAtLogin, LaunchAtLogin.needsApproval {
                    LabeledContent("Waiting for your approval in System Settings") {
                        Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
            } header: {
                Text("Startup")
            }
        }
    }

    static func purgeTime(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Snippets

struct SnippetsPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = SnippetStore.shared

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: $settings.snippetsEnabled) {
                    Text("Expand snippets as you type")
                    Text("Type an abbreviation anywhere and it turns into the saved text. "
                        + "{date}, {time} and {clipboard} are filled in. Password fields are never watched.")
                }
            }

            Section {
                if store.snippets.isEmpty {
                    Text("No snippets yet. Start abbreviations with a symbol, like ;sig, "
                        + "so they never fire in the middle of a word.")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.snippets) { $snippet in
                    SnippetEditor(snippet: $snippet) {
                        store.snippets.removeAll { $0.id == snippet.id }
                    }
                }
            } header: {
                HStack {
                    Text("Snippets")
                    Spacer()
                    Button {
                        store.snippets.append(Snippet(trigger: ";", text: ""))
                    } label: {
                        Label("Add Snippet", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .disabled(!settings.snippetsEnabled)
        }
    }
}

private struct SnippetEditor: View {
    @Binding var snippet: Snippet
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("Abbreviation", text: $snippet.trigger)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Expands to", text: $snippet.text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete this snippet")
        }
        .padding(.vertical, 2)
    }

    private var problem: String? {
        if snippet.trigger.count < Snippet.minimumTriggerLength {
            return "Abbreviations need at least two characters."
        }
        if snippet.text.isEmpty { return "Add the text it should expand to." }
        return nil
    }
}

// MARK: - Ignored apps

struct IgnoredAppsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane {
            Section {
                if settings.ignoredApps.isEmpty {
                    Text("No apps ignored.").foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredApps, id: \.self) { bundleID in
                    HStack {
                        AppIdentityLabel(bundleID: bundleID)
                        Spacer()
                        Button {
                            settings.ignoredApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop ignoring this app")
                    }
                }
            } header: {
                HStack {
                    Text("Copies from these apps are never recorded")
                    Spacer()
                    Button {
                        addApps()
                    } label: {
                        Label("Add App…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                Text("Password managers are skipped automatically: they mark what they copy as private.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Records bundle identifiers rather than names, so a rename or a second
    /// copy in another folder cannot quietly stop the rule from matching.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        panel.message = "Choose apps whose copies should never be recorded."
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !settings.ignoredApps.contains(bundleID)
            else { continue }
            settings.ignoredApps.append(bundleID)
        }
    }
}

// MARK: - History & Data

struct StoragePane: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject private var settings = Settings.shared
    /// Bumped after a clear, so the byte counts re-read.
    @State private var tick = 0

    var body: some View {
        Pane {
            Section {
                LabeledContent(
                    "Items",
                    value: "\(store.items.count) item\(store.items.count == 1 ? "" : "s"), "
                        + "\(store.pinned.count) pinned"
                )
                LabeledContent("In memory", value: formattedBytes(Int64(footprint)))
                LabeledContent("Encrypted on disk", value: formattedBytes(Int64(DiskStore.shared.bytes(pinned: false))))
                LabeledContent("Pinned archive", value: formattedBytes(Int64(DiskStore.shared.bytes(pinned: true))))
                LabeledContent("Staged for shelves", value: formattedBytes(Int64(ShelfStorage.stagedBytes())))
            } header: {
                Text("History")
            } footer: {
                Text("Items move to encrypted files five minutes after they are copied. Those files "
                    + "go when you quit, and history is cleared every day at "
                    + "\(GeneralPane.purgeTime(settings.purgeHour)). Pinned items stay until you clear them.")
                    .foregroundStyle(.secondary)
            }
            .id(tick)

            Section {
                LabeledContent {
                    Button("Clear History", role: .destructive) {
                        store.clearAll()
                        tick += 1
                    }
                } label: {
                    Text("Clear history")
                    Text("Everything except pinned items.")
                }
                LabeledContent {
                    Button("Clear Files") {
                        DiskStore.shared.clearCache()
                        tick += 1
                    }
                } label: {
                    Text("Clear cached files")
                    Text("Encrypted copies of recent items.")
                }
                LabeledContent {
                    Button("Clear Pinned…", role: .destructive) { confirmClearPinned() }
                        .disabled(store.pinned.isEmpty)
                } label: {
                    Text("Clear pinned items")
                    Text("The only history kept between launches.")
                }
            } header: {
                Text("Clear")
            }

            Section {
                LabeledContent {
                    Button("Uninstall…", role: .destructive) { confirmUninstall() }
                } label: {
                    Text("Uninstall KlipKlik")
                    Text("Revokes its permissions, removes the login item and deletes every setting "
                        + "and stored item. Moving the app to the Trash is asked separately.")
                }
            } header: {
                Text("Uninstall")
            }
        }
    }

    private var footprint: Int {
        store.items.reduce(0) { total, item in
            total + (item.representations ?? []).reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        }
    }

    private func confirmClearPinned() {
        let count = store.pinned.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(count) pinned item\(count == 1 ? "" : "s")?"
        alert.informativeText = "Pinned items are the only history kept between launches. This cannot be undone."
        alert.addButton(withTitle: "Clear Pinned")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { confirmed in
            guard confirmed else { return }
            store.clearPinned()
            tick += 1
        }
    }

    /// Two questions on purpose: "clean up after yourself" and "delete the
    /// app" cannot be answered with a single click.
    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall KlipKlik?"
        alert.informativeText = "Revokes Accessibility and Screen Recording, removes the login item, "
            + "and deletes every setting. Clipboard history is in memory and goes when the app quits."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { confirmed in
            guard confirmed else { return }
            Uninstaller.tearDown()
            DiskStore.shared.destroyEverything()

            let trash = NSAlert()
            trash.alertStyle = .warning
            trash.messageText = "Move KlipKlik to the Trash?"
            trash.informativeText = "Everything else has been undone. The app itself can stay "
                + "if you would rather remove it yourself."
            trash.addButton(withTitle: "Move to Trash")
            trash.addButton(withTitle: "Keep the App")
            ToolsAlert.confirm(trash) { moveToTrash in
                if moveToTrash {
                    Uninstaller.moveToTrash { _ in NSApp.terminate(nil) }
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

// MARK: - Shelf

struct ShelfPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: $settings.shelvesEnabled) {
                    Text("Drag shelves")
                    Text("Floating trays you drop files into and drag back out. ⌥⌘S opens an empty one.")
                }
            }

            Section {
                Picker("Show a drop target", selection: $settings.shelfTrigger) {
                    ForEach(ShelfTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.shelfTrigger.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Opening")
            }
            .disabled(!settings.shelvesEnabled)

            Section {
                Toggle(isOn: $settings.shelfKeepAfterDrag) {
                    Text("Keep items after dragging them out")
                    Text("So the same files can be dropped in several places. Move shelves always empty.")
                }
                Toggle(isOn: $settings.shelvesPersist) {
                    Text("Keep shelves after quitting")
                    Text("Files from Finder are only referenced. Anything with no file behind it — a "
                        + "picture from a web page, a text snippet — is saved as a plain readable file "
                        + "so it can be dragged out again. Off by default for that reason.")
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("In Finder, ⇧⌥⌘S sends the selected files to a shelf.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.shelvesEnabled)
        }
    }
}

// MARK: - Finder

struct FinderPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: $settings.finderCutMove) {
                    Text("Cut and paste files with ⌘X")
                    Text("⌘X marks the selection, ⌘V in another folder moves it.")
                }
                Toggle(isOn: $settings.finderRenameKey) {
                    Text("Rename with F2")
                    Text("As on Windows. Return still works too.")
                }
                Toggle(isOn: $settings.finderPasteImage) {
                    Text("Paste pictures as files")
                    Text("⌘V with a copied picture saves it into the open folder as a PNG. "
                        + "macOS asks once whether KlipKlik may talk to Finder.")
                }
            } header: {
                Text("Finder")
            }
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane {
            Section {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $settings.popupSize) {
                    ForEach(PopupSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Background") {
                    HStack(spacing: 10) {
                        Text("Glass").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.glassOpacity, in: 0...1, step: 0.05)
                            .frame(width: 170)
                        Text("Solid").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show the app each item came from", isOn: $settings.showSourceIcons)
            } header: {
                Text("Popup")
            }

            Section {
                Picker(selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Copy picked colours as")
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(Color(.sRGB, red: 0.04, green: 0.52, blue: 1))
                            .frame(width: 10, height: 10)
                        Text(ColorFormat.Components(red: 0.04, green: 0.52, blue: 1)
                            .formatted(settings.colorFormat))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            } header: {
                Text("Colour picker")
            }
        }
    }
}

private extension ColorFormat.Components {
    func formatted(_ format: ColorFormat) -> String { format.string(for: self) }
}

// MARK: - Shortcuts & permissions

struct ShortcutsPane: View {
    @ObservedObject private var permissions = PermissionStatus.shared
    /// Re-read whenever KlipKlik comes back to the front — the grant is made
    /// in System Settings.
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    private static let global: [(String, String)] = [
        ("Clipboard history", "⌘ ⌘"),
        ("Clipboard history, alternate", "⇧ ⌘ C"),
        ("New shelf", "⌥ ⌘ S"),
        ("Start or stop the paste stack", "⌃ ⌥ ⌘ C"),
        ("Stop a scrolling screenshot", "esc")
    ]

    private static let finder: [(String, String)] = [
        ("Cut files", "⌘ X"),
        ("Rename", "F2"),
        ("Send selection to a shelf", "⇧ ⌥ ⌘ S")
    ]

    private static let popup: [(String, String)] = [
        ("Move through the list", "↑ ↓"),
        ("Paste the selected item", "↩"),
        ("Paste with the opposite formatting", "⌥ ⇧ ↩"),
        ("Paste item 1 to 9", "⌘ 1…9"),
        ("Preview the whole item", "Space"),
        ("Float on screen", "⌥ F"),
        ("Filter by type", "⇥"),
        ("Pin or unpin", "⌥ P"),
        ("Add files to a shelf", "⌥ S"),
        ("Delete the item", "⌘ ⌫"),
        ("Clear history", "⌥ ⌘ ⌫"),
        ("Close", "esc")
    ]

    var body: some View {
        Pane {
            Section("Anywhere") { rows(Self.global) }
            Section("In Finder") { rows(Self.finder) }
            Section("In the popup") { rows(Self.popup) }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        PermissionBadge(granted: permissions.isTrusted)
                        if !permissions.isTrusted {
                            Button("Allow…") { AccessibilityPermission.allow() }
                        }
                        Button("Reset") { AccessibilityPermission.reset() }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Double-tap ⌘, auto-paste, cut and paste in Finder, the paste stack, "
                        + "snippets and the Finder keys.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        PermissionBadge(granted: permissions.canRecordScreen)
                        if !permissions.canRecordScreen {
                            Button("Allow…") { TextGrab.allow() }
                        }
                        Button("Reset") { TextGrab.resetPermission() }
                    }
                } label: {
                    Text("Screen Recording")
                    Text("Reading text and QR codes off the screen. "
                        + "The colour picker does not need it.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        PermissionBadge(granted: hasFullDiskAccess)
                        if !hasFullDiskAccess {
                            Button("Allow…") { FullDiskAccess.requestByHand() }
                        }
                    }
                } label: {
                    Text("Full Disk Access")
                    Text("Optional. Only needed to remove leftovers in other apps' protected "
                        + "folders. macOS never asks for it: Allow opens the list and shows "
                        + "KlipKlik in Finder — drag it in, switch it on, then reopen KlipKlik.")
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Permissions are tied to the app's signature. A rebuilt or updated KlipKlik "
                    + "can leave an entry in System Settings that looks on but no longer counts. "
                    + "Reset clears it; then switch it on again.")
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    @ViewBuilder
    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.0) { title, keys in
            LabeledContent(title) { KeyCaps(keys) }
        }
    }
}
