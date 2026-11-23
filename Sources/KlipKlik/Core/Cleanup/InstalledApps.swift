import AppKit
import Security

/// One application bundle, read once from its Info.plist and signature.
struct AppBundle: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    let executable: String?
    let teamID: String?

    var id: String { url.path }

    init?(url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        self.url = url
        self.bundleID = bundleID
        self.name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        self.version = info["CFBundleShortVersionString"] as? String
        self.executable = info["CFBundleExecutable"] as? String
        self.teamID = Self.teamIdentifier(of: url)
    }

    /// Every name the app could have left files under.
    var nameVariants: [String] {
        var names = [name, url.deletingPathExtension().lastPathComponent]
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        if let bundleName = info["CFBundleName"] as? String { names.append(bundleName) }
        if let executable { names.append(executable) }
        return names
    }

    var identity: LeftoverMatcher.Identity {
        LeftoverMatcher.Identity(bundleID: bundleID, names: nameVariants, teamID: teamID)
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// The ten-character team that signed the app, if any.
    private static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The apps on this Mac, as far as an uninstaller should see them.
enum InstalledApps {
    /// Folders users install into, one level deep plus vendor sub-folders
    /// (`/Applications/Setapp/…`, `/Applications/Utilities/…`).
    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications")
        ]
    }

    /// Removable apps, sorted by name. Apple's and KlipKlik itself are left out
    /// — see `refusal(for:)`.
    static func list() -> [AppBundle] {
        var seen = Set<String>()
        return appURLs(in: roots, depth: 2)
            .compactMap(AppBundle.init(url:))
            .filter { refusal(for: $0) == nil && seen.insert($0.url.path).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Why an app cannot be removed here, or nil when it can.
    static func refusal(for app: AppBundle) -> String? {
        let path = app.url.resolvingSymlinksInPath().path
        if path.hasPrefix("/System/") { return "\(app.name) is part of macOS." }
        if app.bundleID.lowercased().hasPrefix("com.apple.") {
            return "\(app.name) comes with macOS. Remove Apple apps from Finder or System Settings."
        }
        if app.bundleID == Bundle.main.bundleIdentifier {
            return "Use Settings ▸ Storage ▸ Uninstall KlipKlik to remove KlipKlik itself."
        }
        if (try? app.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return "\(app.name) is a link to an app somewhere else."
        }
        // An app inside another app is part of that app, not a thing of its own.
        if app.url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") }) {
            return "\(app.name) is part of another app."
        }
        return nil
    }

    /// Bundle IDs of everything installed, helpers and extensions included —
    /// the orphan finder's "who still owns this" list, and the matcher's
    /// "whose is this" list. Lowercased.
    static func allBundleIDs() -> Set<String> {
        // The user's own Application Support is deliberately not searched: it
        // holds privacy-protected folders, and walking into one raises a
        // permission prompt. Helpers kept there are caught by the running-app
        // check below and by the vendor-prefix rule.
        let searched = roots + [
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/Library/Application Support")
        ]
        var ids = Set<String>()
        for url in appURLs(in: searched, depth: 3) {
            // Helpers, login items, extensions and XPC services ship their own
            // identifiers, and leave files under them.
            for bundle in [url] + nestedBundles(in: url) {
                if let id = Bundle(url: bundle)?.bundleIdentifier { ids.insert(id.lowercased()) }
                // Shared containers are named by app group, not bundle ID, and
                // a group can belong to a different vendor's name entirely —
                // WhatsApp uses `group.com.facebook.family`. The signature
                // says which groups each app claims.
                for group in appGroups(of: bundle) {
                    ids.insert(group.lowercased())
                    ids.insert(OrphanScanner.withoutGroupPrefixes(group.lowercased()))
                }
            }
        }
        // Running processes count as installed too: an app launched from a
        // disk image or the Downloads folder still owns its files.
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        return ids
    }

    /// The app groups a bundle's signature claims.
    static func appGroups(of url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private static func nestedBundles(in app: URL) -> [URL] {
        let contents = app.appendingPathComponent("Contents")
        let folders = ["Library/LoginItems", "PlugIns", "Helpers", "XPCServices",
                       "Library/LaunchServices", "Frameworks"]
        var found: [URL] = []
        for folder in folders {
            let dir = contents.appendingPathComponent(folder)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            found += entries.filter { ["app", "appex", "xpc", "bundle"].contains($0.pathExtension) }
            // Electron puts its helper apps inside its framework.
            if folder == "Frameworks" {
                for framework in entries where framework.pathExtension == "framework" {
                    let helpers = framework.appendingPathComponent("Versions/A/Helpers")
                    let inner = (try? FileManager.default.contentsOfDirectory(
                        at: helpers, includingPropertiesForKeys: nil
                    )) ?? []
                    found += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return found
    }

    /// `.app` bundles under `roots`, descending into plain folders only.
    private static func appURLs(in roots: [URL], depth: Int) -> [URL] {
        var result: [URL] = []
        for root in roots {
            collect(in: root, depth: depth, into: &result)
        }
        return result
    }

    private static func collect(in folder: URL, depth: Int, into result: inout [URL]) {
        guard depth > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                  options: [.skipsHiddenFiles]
              )
        else { return }
        for entry in entries {
            if entry.pathExtension == "app" {
                result.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !LeftoverMatcher.isAppleOwned(entry.lastPathComponent) {
                collect(in: entry, depth: depth - 1, into: &result)
            }
        }
    }
}
