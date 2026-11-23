import AppKit
import SwiftUI

/// The tool pages' state, kept by the window controller so a scan survives
/// switching pages and closing the window — until the next scan.
final class ToolsModel: ObservableObject {
    let uninstall = UninstallModel()
    let leftovers = OrphanModel()
    let cache = CacheModel()
    let ports = PortsModel()
}

// MARK: - Shared pieces

/// "12.4 MB", or "—" when not measured.
func formattedBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    // "0 KB", not "Zero KB": a column of figures should stay figures.
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: bytes)
}

/// The strip along the bottom of a tool page: what is selected, and the one
/// action that acts on it. Sits on the window's bar material, like the
/// bottom bar of Finder or Mail.
struct ToolActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A message line under a tool, shown after an action finishes.
struct ToolMessage: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// "Scanning…" in the middle of the page.
struct ToolProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small rounded tag: "Maybe", "System", "Open now".
struct ToolTag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Asks a question without ever losing it off screen.
///
/// `runModal()` was the first version, and it hung the window: since
/// macOS 14 an app cannot force itself to the front, so the alert could open
/// behind other apps while the window sat waiting on it with nothing visible
/// to answer. A sheet is attached to the KlipKlik window itself, so it is
/// wherever that window is.
enum ToolsAlert {
    /// The KlipKlik window, set when it is built.
    static weak var window: NSWindow?

    /// Calls `handler(true)` when the first (confirming) button is chosen.
    static func confirm(_ alert: NSAlert, handler: @escaping (Bool) -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { response in
                handler(response == .alertFirstButtonReturn)
            }
        } else {
            handler(FloatingAlert.run(alert) == .alertFirstButtonReturn)
        }
    }
}

/// An alert raised while KlipKlik has no window of its own up — after a
/// keystroke or from a background check. Floated above other apps, since a
/// menu-bar app can no longer bring itself forward and a plain alert would
/// open behind whatever is in front.
enum FloatingAlert {
    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = .floating
        return alert.runModal()
    }
}

/// Back to menu-bar-only, unless another titled window (Preferences, Tools)
/// is still open and needs the Dock icon to be found again.
func dropDockIconUnlessWindowsRemain(except closing: NSWindow?) {
    let others = NSApp.windows.contains {
        $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
    }
    if !others { NSApp.setActivationPolicy(.accessory) }
}

/// Reveals a path in Finder.
func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
