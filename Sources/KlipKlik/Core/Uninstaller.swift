import AppKit
import ServiceManagement

/// Undoes everything KlipKlik left on the machine.
///
/// A menu-bar app scatters more than its bundle: two privacy grants, a login
/// item, and a preferences domain. Dragging the app to the Trash leaves all of
/// them behind — the TCC rows in particular linger and confuse the next install,
/// because macOS matches them by bundle identifier.
enum Uninstaller {
    struct Report {
        var revokedAccessibility = false
        var revokedScreenRecording = false
        var removedLoginItem = false
        var clearedPreferences = false
    }

    /// Revokes, unregisters and forgets. Does not touch the app bundle — see
    /// `moveToTrash()`, which the caller runs last and only if asked.
    @discardableResult
    static func tearDown() -> Report {
        var report = Report()

        report.revokedAccessibility = TCC.reset("Accessibility")
        report.revokedScreenRecording = TCC.reset("ScreenCapture")

        // Leaving this behind means macOS tries to launch a deleted app at every
        // login, which surfaces as a broken login item the user has to hunt down.
        if SMAppService.mainApp.status == .enabled {
            report.removedLoginItem = (try? SMAppService.mainApp.unregister()) != nil
        } else {
            report.removedLoginItem = true
        }

        if let domain = Bundle.main.bundleIdentifier {
            let defaults = UserDefaults.standard
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
            report.clearedPreferences = true
        }

        return report
    }

    /// Moves the running app to the Trash. Separate from `tearDown()` because it
    /// is the one step that cannot be undone from inside the app.
    static func moveToTrash(completion: @escaping (Bool) -> Void) {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
}
