import Foundation

/// Clears one of this app's privacy approvals.
///
/// Needed because grants are tied to the code signature, and an ad-hoc
/// signature changes on every rebuild. That leaves a row in System Settings
/// that looks enabled but no longer matches the running app, and toggling it
/// off and on does not fix it — only clearing the entry and re-approving does.
///
/// This can only ever *revoke*. Re-approval still goes through the system,
/// which is the only thing that can actually grant a permission.
enum TCC {
    /// `Accessibility`, `ScreenCapture`, … — the service names `tccutil` takes.
    @discardableResult
    static func reset(_ service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", service, Bundle.main.bundleIdentifier ?? "com.sanoj.KlipKlik"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }
}
