import AppKit
import SwiftUI

/// Shown once, on the first launch.
///
/// KlipKlick lives in the menu bar with no Dock icon, so a first run is
/// otherwise completely silent — nothing appears, and the two permissions that
/// unlock most of the app are never mentioned. This says where it went and
/// offers the grants up front, rather than waiting for a feature to fail.
struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTrusted = AccessibilityPermission.isTrusted
    @State private var canRecordScreen = TextGrab.isPermitted

    private var palette: Palette { .resolve(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text("Two permissions unlock the rest. You can skip them and grant "
                + "them later in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            grant(
                title: "Accessibility",
                detail: "Double-tap ⌘, auto-paste, ⌘ X cut-and-move",
                granted: isTrusted
            ) {
                AccessibilityPermission.requestIfNeeded()
                AccessibilityPermission.openSettingsPane()
            }

            grant(
                title: "Screen Recording",
                detail: "Grab text off the screen",
                granted: canRecordScreen
            ) {
                _ = TextGrab.promptIfNeverAsked()
                TextGrab.openSettingsPane()
            }

            Text("Granting these needs a relaunch to take effect.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 10)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button(action: onFinish) {
                    Text("Start Using KlipKlick")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.accent)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .background(
            LiquidGlassBackground(
                style: .regular,
                tint: palette.glassTint,
                cornerRadius: 0,
                fallbackMaterial: .windowBackground
            )
        )
        // The status changes in System Settings, outside this window.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            isTrusted = AccessibilityPermission.isTrusted
            canRecordScreen = TextGrab.isPermitted
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
            }

            Text("Welcome to KlipKlick")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text("It lives in the menu bar — look for the clock. Double-tap ⌘ or "
                + "press ⇧ ⌘ C to open your clipboard history.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 16)
    }

    private func grant(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? Color(hex: 0x34C759) : palette.divider)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textTertiary)
            } else {
                Button("Grant…", action: action)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }
}

/// Hosts `OnboardingView`, and remembers that it has been seen.
final class OnboardingWindowController: NSWindowController {
    private static let seenKey = "didCompleteOnboarding"

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    convenience init() {
        // Placeholder root; the real one needs a reference to the controller.
        let window = NSWindow(contentViewController: NSHostingController(rootView: EmptyView()))
        window.title = "Welcome"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: OnboardingView { [weak self] in self?.finish() }
        )
    }

    func show() {
        // Regular policy so the window has a Dock icon while it is up, matching
        // Preferences — a welcome window that cannot be found again is worse
        // than no welcome window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        window?.close()
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
