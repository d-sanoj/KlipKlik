import AppKit
import SwiftUI

/// The tools' state — scans, lists, work in progress. One copy for the whole
/// app, shared by the Settings pages and the menu bar submenus, so a scan
/// started in one shows in the other and they can never disagree.
final class ToolsModel: ObservableObject {
    static let shared = ToolsModel()

    let uninstall = UninstallModel()
    let leftovers = OrphanModel()
    let cache = CacheModel()
    let ports = PortsModel()
    let fileUsage = FileUsageModel()
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

extension View {
    /// Takes all the room between a tool page's top and bottom bars, whatever
    /// is showing — a table, a progress spinner or an empty state. Without
    /// it, a short empty state lets the whole column shrink and centre, and
    /// the filter bar above it jumps to the middle of the window.
    func fillsToolArea() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
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

extension ToolsAlert {
    /// Any number of buttons; `handler` gets which was chosen.
    static func ask(_ alert: NSAlert, handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(FloatingAlert.run(alert))
        }
    }

    /// Reports how an action started from the menu bar went — the menu has
    /// closed by then, so there is nowhere else to say it.
    static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        ask(alert) { _ in }
    }
}

/// Stops a process the user picked, the same way everywhere: ask first, ask it
/// to quit, offer to force it if it lingers, and offer the administrator route
/// when it belongs to someone else. Shared by Ports and What's Using It.
enum ProcessStopper {
    /// - Parameter done: a line describing the outcome, and whether the
    ///   process is gone.
    static func stop(pid: Int32, name: String, reason: String, stoppedMessage: String,
                     done: @escaping (String, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Stop \(name) (PID \(pid))?"
        alert.informativeText = reason + " Unsaved work in it may be lost."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { confirmed in
            if confirmed { send(pid: pid, name: name, force: false, stoppedMessage: stoppedMessage, done: done) }
        }
    }

    private static func send(pid: Int32, name: String, force: Bool, stoppedMessage: String,
                             done: @escaping (String, Bool) -> Void) {
        Ports.stop(pid: pid, force: force) { result in
            handle(result, pid: pid, name: name, wasForced: force, stoppedMessage: stoppedMessage, done: done)
        }
    }

    private static func handle(_ result: Ports.StopResult, pid: Int32, name: String, wasForced: Bool,
                               stoppedMessage: String, done: @escaping (String, Bool) -> Void) {
        switch result {
        case .stopped:
            done(stoppedMessage, true)
        case .stillRunning:
            guard !wasForced else {
                done("\(name) is still running.", false)
                return
            }
            let alert = NSAlert()
            alert.messageText = "\(name) did not stop"
            alert.informativeText = "Force it to quit? It gets no chance to clean up."
            alert.addButton(withTitle: "Force Quit")
            alert.addButton(withTitle: "Cancel")
            ToolsAlert.confirm(alert) { confirmed in
                if confirmed {
                    send(pid: pid, name: name, force: true, stoppedMessage: stoppedMessage, done: done)
                }
            }
        case .notPermitted:
            let alert = NSAlert()
            alert.messageText = "\(name) belongs to another user"
            alert.informativeText = "Stopping it needs an administrator password."
            alert.addButton(withTitle: "Stop as Administrator")
            alert.addButton(withTitle: "Cancel")
            ToolsAlert.confirm(alert) { confirmed in
                guard confirmed else { return }
                Ports.stopAsAdministrator(pid: pid) { result in
                    if case .notPermitted = result {
                        done("Not stopped: no password given.", false)
                    } else {
                        handle(result, pid: pid, name: name, wasForced: true,
                               stoppedMessage: stoppedMessage, done: done)
                    }
                }
            }
        case .failed(let text):
            done(text, false)
        }
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

extension ToolsAlert {
    /// Explains items macOS would not let go, and offers the two ways past
    /// it: Full Disk Access for KlipKlik, or removing them by hand in Finder.
    ///
    /// There is no "force" beyond this. macOS's protection of other apps'
    /// data applies to administrators too, so a password prompt would only
    /// fail the same way.
    static func explainProtected(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = urls.count == 1
            ? "macOS protected 1 item"
            : "macOS protected \(urls.count) items"
        alert.informativeText = "They are in folders macOS keeps for other apps' data, like Group "
            + "Containers and Application Scripts. Not even an administrator password gets past "
            + "that.\n\nmacOS never asks for Full Disk Access on its own: KlipKlik has to be added "
            + "by hand. Open Full Disk Access shows the list and KlipKlik in Finder — drag it into "
            + "the list (or press + and choose it), switch it on, then quit and reopen KlipKlik."
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Not Now")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: FullDiskAccess.requestByHand()
            case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting(urls)
            default: break
            }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(FloatingAlert.run(alert))
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
