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
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Section heading with a line of explanation beneath it.
struct ToolsHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }
}

extension ToolsHeader where Trailing == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// A message centred in an empty area.
struct ToolsPlaceholder: View {
    let symbol: String
    let text: String
    var busy = false

    var body: some View {
        VStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
