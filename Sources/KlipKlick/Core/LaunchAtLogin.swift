import AppKit
import ServiceManagement

/// Registers KlipKlick to start when you log in.
///
/// `SMAppService.mainApp` rather than a helper target or a `LaunchAgents` plist:
/// the app registers *itself*, macOS owns the record, and the user can revoke it
/// from System Settings without the app being involved.
///
/// The system is the source of truth here, not a preference of ours. Storing our
/// own copy would drift the moment someone flipped the switch in **System
/// Settings ▸ General ▸ Login Items**, so the state is always read back from
/// `status`.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// macOS accepted the registration but the user has not approved it yet.
    /// The app will not actually launch until they do.
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Why a registration failed, in terms that suggest what to do about it.
    static func explain(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case 1:  // kSMErrorInternalFailure / not found
            return "macOS could not find the app bundle to register. Move KlipKlick to "
                + "/Applications and try again."
        default:
            return (error as NSError).localizedDescription
        }
    }
}
