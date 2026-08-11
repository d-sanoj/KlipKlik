import AppKit
import SwiftUI

/// Shown on the first launch, and again whenever a permission has lapsed.
///
/// KlipKlick lives in the menu bar with no Dock icon, so a first run is
/// otherwise completely silent — nothing appears, and the two permissions that
/// unlock most of the app are never mentioned. This says where it went and
/// offers the grants up front, rather than waiting for a feature to fail.
///
/// It also stands in for the bare `AXIsProcessTrustedWithOptions` alert, which
/// arrives with no icon, no explanation of what it unlocks, and no way back to
/// it once dismissed.
struct OnboardingView: View {
    enum Mode {
        /// First launch: introduce the app, then ask.
        case welcome
        /// A later launch with something missing: just the grants.
        case permissions
    }

    var mode: Mode = .welcome
    let onFinish: () -> Void
    let onRestart: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTrusted = AccessibilityPermission.isTrusted
    @State private var canRecordScreen = TextGrab.isPermitted

    /// What was granted when this window opened, so a grant made *while it is
    /// open* can be told apart from one that was already there.
    @State private var trustedAtOpen = AccessibilityPermission.isTrusted
    @State private var couldRecordAtOpen = TextGrab.isPermitted

    private var palette: Palette { .resolve(colorScheme) }

    /// Set once the user has asked for a grant from this window.
    @State private var didAttemptGrant = false

    /// Whether to offer a restart rather than a plain dismiss.
    ///
    /// This deliberately keys off the user having *asked*, not off a confirmed
    /// change: `CGPreflightScreenCaptureAccess` caches its answer for the life
    /// of the process, so a Screen Recording grant made a second ago still
    /// reads as denied in here. Waiting for the observed flip means the button
    /// never changes for the one permission that most needs the restart.
    ///
    /// The observed cases are still checked, to catch a grant made directly in
    /// System Settings without touching Allow.
    private var needsRestart: Bool {
        didAttemptGrant
            || (isTrusted && !trustedAtOpen)
            || (canRecordScreen && !couldRecordAtOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(introText)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            grant(
                title: "Accessibility",
                detail: "Double-tap ⌘, auto-paste, ⌘ X cut-and-move",
                granted: isTrusted,
                action: {
                    didAttemptGrant = true
                    AccessibilityPermission.allow()
                }
            )

            grant(
                title: "Screen Recording",
                detail: "Grab text off the screen",
                granted: canRecordScreen,
                action: {
                    didAttemptGrant = true
                    TextGrab.allow()
                }
            )

            Text("Screen Recording asks right here. Accessibility can only be "
                + "switched on by you in System Settings — macOS gives apps no way "
                + "to grant it. Both take effect after a relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack {
                Spacer()
                Button(action: needsRestart ? onRestart : onFinish) {
                    Text(primaryButtonTitle)
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
            .padding(.top, 18)
        }
        .padding(24)
        // Width fixed, height intrinsic: the two modes have different amounts of
        // copy, and a hardcoded height clips whichever one grows.
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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

    private var primaryButtonTitle: String {
        if needsRestart { return "Restart and use KlipKlik" }
        return mode == .welcome ? "Start Using KlipKlik" : "Done"
    }

    private var introText: String {
        switch mode {
        case .welcome:
            return "Two permissions unlock the rest. You can skip them and grant "
                + "them later in Settings."
        case .permissions:
            return "macOS ties each grant to the app's code signature, so updating "
                + "KlipKlick can quietly retire it. Nothing else is wrong."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
            }

            Text(mode == .welcome ? "Welcome to KlipKlick" : "KlipKlick needs permission")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(
                mode == .welcome
                    ? "It lives in the menu bar — look for the clock. Double-tap ⌘ or "
                        + "press ⇧ ⌘ C to open your clipboard history."
                    : "It's running in the menu bar, but the features that need system "
                        + "access are switched off until these are granted."
            )
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
                Button("Allow", action: action)
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

    convenience init(mode: OnboardingView.Mode = .welcome) {
        // Placeholder root; the real one needs a reference to the controller.
        let window = NSWindow(contentViewController: NSHostingController(rootView: EmptyView()))
        window.title = mode == .welcome ? "Welcome" : "Permissions"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let hosting = NSHostingController(
            rootView: OnboardingView(
                mode: mode,
                onFinish: { [weak self] in self?.finish() },
                onRestart: { [weak self] in self?.restart() }
            )
        )
        // Let SwiftUI's measured height drive the window, so neither mode clips.
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
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

    private func restart() {
        // Record the visit first: the relaunched copy must not open this window
        // a second time and ask again for what was just granted.
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        UserDefaults.standard.synchronize()
        Relauncher.relaunch()
    }
}
