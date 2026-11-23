import Foundation

/// One file or folder an app left behind.
struct Leftover: Identifiable, Hashable {
    enum Kind: Hashable {
        case appBundle
        case launchAgent
        case launchDaemon
        /// An installer receipt in /private/var/db/receipts, forgotten with
        /// `pkgutil --forget` rather than moved.
        case receipt(packageID: String)
        case file
    }

    let url: URL
    let kind: Kind
    let strength: LeftoverMatcher.Strength
    /// Root-owned, or in a folder only an administrator can change.
    let needsAdmin: Bool
    /// Bytes on disk. Nil when it was not measured — other apps' containers,
    /// whose contents macOS guards behind a permission prompt.
    let size: Int64?

    var id: String { url.path }

    /// Where it sits, shortened for display: `~/Library/Caches`.
    var displayFolder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = url.deletingLastPathComponent().path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// Finds an app's leftovers across the Library folders.
///
/// Reads names only, except to measure sizes. Nothing here deletes; see
/// `AppRemover`.
enum LeftoverScanner {
    struct Location {
        let url: URL
        let place: LeftoverMatcher.Place
        /// 2 also looks one level inside vendor folders
        /// (`Application Support/JetBrains/IntelliJIdea2025.1`).
        var depth = 1
        /// False where looking inside would raise a privacy prompt.
        var measure = true
    }

    static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        func user(_ path: String, _ place: LeftoverMatcher.Place = .perApp,
                  depth: Int = 1, measure: Bool = true) -> Location {
            Location(url: library.appendingPathComponent(path), place: place, depth: depth, measure: measure)
        }
        func system(_ path: String, _ place: LeftoverMatcher.Place = .perApp, depth: Int = 1) -> Location {
            Location(url: URL(fileURLWithPath: path), place: place, depth: depth)
        }
        return [
            user("Application Support", depth: 2),
            // Named like group containers: `TEAMID.com.vendor.app`.
            user("Application Scripts", .groupContainers, measure: false),
            user("Caches"),
            user("Containers", measure: false),
            user("Group Containers", .groupContainers, measure: false),
            user("HTTPStorages"),
            user("Cookies"),
            user("Preferences"),
            user("Preferences/ByHost"),
            user("Saved Application State"),
            user("Logs"),
            user("Logs/DiagnosticReports", .crashReports),
            user("LaunchAgents"),
            user("WebKit"),
            user("Internet Plug-Ins"),
            user("PreferencePanes"),
            user("Application Support/CrashReporter", .crashReports),
            system("/Library/Application Support", depth: 2),
            system("/Library/Caches"),
            system("/Library/Preferences"),
            system("/Library/LaunchAgents"),
            system("/Library/LaunchDaemons"),
            system("/Library/PrivilegedHelperTools"),
            system("/Library/Logs"),
            system("/Library/Logs/DiagnosticReports", .crashReports),
            system("/Library/Internet Plug-Ins"),
            system("/Library/PreferencePanes"),
            // Not Services: people keep their own Automator workflows there,
            // named after whatever app they drive.
            system("/private/var/db/receipts")
        ]
    }

    /// Everything that looks like `app`'s, strongest first, then by size.
    ///
    /// - Parameters:
    ///   - bundleURL: the app itself, listed first. Nil when the app is already
    ///     gone (the removal watcher and orphan finder).
    ///   - others: every other installed bundle ID, lowercased.
    static func scan(
        app: LeftoverMatcher.Identity,
        bundleURL: URL?,
        others: Set<String>
    ) -> [Leftover] {
        var found: [Leftover] = []
        var seen = Set<String>()

        if let bundleURL {
            found.append(Leftover(
                url: bundleURL, kind: .appBundle, strength: .exact,
                needsAdmin: !isRemovable(bundleURL), size: allocatedSize(of: bundleURL)
            ))
            seen.insert(bundleURL.path)
        }

        for location in locations {
            visit(location.url, location: location, depth: location.depth,
                  app: app, others: others, found: &found, seen: &seen)
        }

        return found.sorted {
            if $0.kind == .appBundle { return true }
            if $1.kind == .appBundle { return false }
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            return ($0.size ?? 0) > ($1.size ?? 0)
        }
    }

    private static func visit(
        _ folder: URL,
        location: Location,
        depth: Int,
        app: LeftoverMatcher.Identity,
        others: Set<String>,
        found: inout [Leftover],
        seen: inout Set<String>
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard !seen.contains(entry.path) else { continue }

            if let strength = LeftoverMatcher.match(name, in: location.place, app: app, otherBundleIDs: others) {
                seen.insert(entry.path)
                found.append(Leftover(
                    url: entry,
                    kind: kind(of: entry),
                    strength: strength,
                    needsAdmin: !isRemovable(entry),
                    size: location.measure ? allocatedSize(of: entry) : nil
                ))
                continue
            }

            // One level into vendor folders. Never into Apple's, which include
            // privacy-protected ones that prompt when listed.
            guard depth > 1, !LeftoverMatcher.isAppleOwned(name),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { continue }
            visit(entry, location: location, depth: depth - 1,
                  app: app, others: others, found: &found, seen: &seen)
        }
    }

    private static func kind(of url: URL) -> Leftover.Kind {
        let folder = url.deletingLastPathComponent().lastPathComponent
        if folder == "LaunchAgents" { return .launchAgent }
        if folder == "LaunchDaemons" { return .launchDaemon }
        if url.path.hasPrefix("/private/var/db/receipts/") {
            let stem = url.deletingPathExtension().lastPathComponent
            return .receipt(packageID: stem)
        }
        return .file
    }

    /// Moving to the Trash needs write access to the folder holding the item.
    static func isRemovable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// Bytes allocated on disk, which is what removing it gives back.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        )
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
