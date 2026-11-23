import Foundation

/// Decides whether a file or folder in a Library location belongs to an app.
///
/// Pure: names in, a verdict out. Everything that reads the disk lives in
/// `LeftoverScanner`; keeping the rules here means they can be tested against
/// the exact names that make uninstallers go wrong.
///
/// The rules lean towards leaving things behind. A leftover that survives
/// costs some disk space; a folder belonging to another app that gets deleted
/// costs that app's data. So:
///
/// * **Exact** matches — named after the bundle identifier, or after the app's
///   full name — are offered ticked.
/// * **Related** matches — a longer name that starts with the app's, or a file
///   from the same vendor that mentions it — are offered unticked.
/// * A name that belongs to another installed app is never offered.
/// * Generic words ("Helper", "Updater", "Music") never match on their own, and
///   Apple's own names are never matched at all.
enum LeftoverMatcher {
    enum Strength: Int, Comparable {
        case related = 1
        case exact = 2

        static func < (lhs: Strength, rhs: Strength) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What is known about the app being removed.
    struct Identity: Equatable {
        /// Lowercased.
        let bundleID: String
        /// Normalised names: bundle name, display name, file name, executable.
        let names: Set<String>
        /// Names that are also ordinary words ("Code", "Notes"). A folder with
        /// exactly that name is offered, but unticked.
        let weakNames: Set<String>
        /// Lowercased signing team, when the app is signed by one.
        let teamID: String?

        init(bundleID: String, names: [String], teamID: String?) {
            self.bundleID = bundleID.lowercased()
            let normalized = names.map(LeftoverMatcher.normalize).filter { $0.count >= 3 }
            self.names = Set(normalized.filter {
                !LeftoverMatcher.neverNames.contains($0) && !LeftoverMatcher.weakWords.contains($0)
            })
            self.weakNames = Set(normalized.filter { LeftoverMatcher.weakWords.contains($0) })
            self.teamID = teamID?.lowercased()
        }
    }

    /// Where a candidate sits. Some rules only make sense in some places.
    enum Place {
        /// Folders named after the app or its bundle ID (Application Support,
        /// Caches, Logs, …).
        case perApp
        /// Crash reports: `AppName-2026-01-01-101010.ips`.
        case crashReports
        /// App group containers: `TEAMID.com.vendor.shared`, `group.com.vendor.x`.
        case groupContainers
    }

    /// Lowercased, letters and digits only: "Visual Studio Code" → "visualstudiocode".
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(Character.init))
    }

    /// Words that name a role, a framework or a vendor, never an app. A folder
    /// called "Helper", "Electron" or "Google" could belong to anything, so
    /// these never match at all — not even unticked.
    static let neverNames: Set<String> = [
        "app", "apps", "application", "helper", "helpers", "agent", "daemon", "service",
        "services", "update", "updater", "updates", "launcher", "installer", "uninstaller",
        "setup", "plugin", "plugins", "extension", "extensions", "support", "data", "cache",
        "caches", "logs", "log", "user", "users", "library", "shared", "common", "config",
        "settings", "preferences", "prefs", "default", "temp", "tmp", "backup", "backups",
        "google", "microsoft", "adobe", "apple", "mozilla", "crashreporter", "sentry",
        "squirrel", "sparkle", "electron", "chromium", "webkit", "keychain", "keychains",
        "files", "documents", "downloads", "desktop", "mac", "macos", "osx"
    ]

    /// Ordinary words that are also real app names ("Code", "Notes", "Steam").
    /// An exact folder of that name is offered unticked; nothing longer matches.
    static let weakWords: Set<String> = [
        "pro", "lite", "free", "client", "server", "web", "browser", "editor", "player",
        "studio", "manager", "tools", "tool", "utility", "utilities", "chat", "code",
        "notes", "music", "photos", "mail", "calendar", "messages", "contacts", "reminders",
        "maps", "news", "books", "podcasts", "preview", "terminal", "steam", "game", "games",
        "video", "audio"
    ]

    /// Suffixes that mark a file *about* a name rather than a different name.
    private static let strippedExtensions: Set<String> = [
        "plist", "savedstate", "binarycookies", "log", "bom", "db", "sqlite", "txt", "ips",
        "crash", "diag", "hang", "spin", "json", "lockfile", "lock"
    ]

    /// The name with a known extension taken off, lowercased.
    static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        guard let dot = lower.lastIndex(of: "."),
              strippedExtensions.contains(String(lower[lower.index(after: dot)...]))
        else { return lower }
        return String(lower[..<dot])
    }

    /// Reverse-DNS: at least two dots and no spaces — `com.vendor.app`.
    static func isReverseDNS(_ text: String) -> Bool {
        !text.contains(" ") && text.filter { $0 == "." }.count >= 2
    }

    /// Apple's own files are never anyone else's leftovers.
    static func isAppleOwned(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.")
            || lower.contains(".com.apple.") || appleFolderNames.contains(lower)
    }

    /// Apple folders in the Library roots that do not carry a bundle ID.
    /// Several are privacy-protected, so they are also never descended into.
    static let appleFolderNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "knowledge", "mobilesync",
        "fileprovider", "clouddocs", "dock", "icloud", "animoji", "accessibilitybundles",
        "crashreporter", "syncservices", "safari", "mail", "messages", "photos", "calendars",
        "homekit", "sharedfilelist", "diskimages", "networkserviceproxy", "familysettings",
        "assistant", "siri", "spotlight", "quicklook", "coreparsec", "geoservices", "metadata",
        "applemediaservices", "storeassets", "keychains", "accounts", "containermanager",
        "dictionaries", "fonts", "trial", "biome", "duetexpertcenter", "ubiquity",
        "com.apple.sharedfilelist", "diagnosticreports", "group containers", "containers",
        "apple", "mobile documents", "cloudstorage", "suggestions", "identityservices",
        "sharing", "callservices", "studentmanagement", "screentime"
    ]

    /// How strongly `name`, found in `place`, belongs to `app`.
    ///
    /// - Parameter otherBundleIDs: bundle IDs of every *other* installed app,
    ///   lowercased. A name that is, or extends, one of those is theirs.
    static func match(
        _ name: String,
        in place: Place,
        app: Identity,
        otherBundleIDs: Set<String>
    ) -> Strength? {
        guard !isAppleOwned(name) else { return nil }
        let stem = Self.stem(name)
        guard !stem.isEmpty else { return nil }

        if belongsToAnotherApp(stem, app: app, others: otherBundleIDs) { return nil }

        // 1. The bundle identifier, or something under it.
        var bundleCandidate = stem
        if place == .groupContainers {
            bundleCandidate = strippedGroupPrefixes(stem, teamID: app.teamID)
        }
        if bundleCandidate == app.bundleID || bundleCandidate.hasPrefix(app.bundleID + ".") {
            return .exact
        }

        // 2. A vendor's shared group container: same team, different suffix.
        if place == .groupContainers, let team = app.teamID, stem.hasPrefix(team + ".") {
            return .related
        }

        let normalized = normalize(stem)

        // 3. Crash reports are named after the process, then a date.
        if place == .crashReports {
            let process = stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            return app.names.contains(normalize(process)) ? .exact : nil
        }

        // 4. Named after the app.
        if !isReverseDNS(stem) {
            if app.names.contains(normalized) { return .exact }
            if app.weakNames.contains(normalized) { return .related }
            // "Slack Helper", "IntelliJIdea2024.3": longer, but plainly the app's.
            // Only for real names, never short ones, which prefix too much.
            if app.names.contains(where: { $0.count >= 5 && normalized.hasPrefix($0) }) {
                return .related
            }
            return nil
        }

        // 5. Same vendor, and the name mentions the app: `com.vendor.AppHelper`.
        let parts = app.bundleID.split(separator: ".")
        if parts.count >= 3 {
            let vendor = parts.prefix(2).joined(separator: ".")
            if stem.hasPrefix(vendor + "."),
               app.names.contains(where: { $0.count >= 4 && normalized.contains($0) }) {
                return .related
            }
        }
        return nil
    }

    /// `TEAMID.com.vendor.app` and `group.com.vendor.app` → `com.vendor.app`.
    private static func strippedGroupPrefixes(_ stem: String, teamID: String?) -> String {
        var result = stem
        if result.hasPrefix("group.") { result.removeFirst("group.".count) }
        if let teamID, result.hasPrefix(teamID + ".") {
            result.removeFirst(teamID.count + 1)
        } else if let dot = result.firstIndex(of: "."),
                  result.distance(from: result.startIndex, to: dot) == 10,
                  result[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) {
            // Someone else's ten-character team prefix: still compare the rest.
            result = String(result[result.index(after: dot)...])
        }
        if result.hasPrefix("group.") { result.removeFirst("group.".count) }
        return result
    }

    /// True when the name is another installed app's bundle ID, or sits under
    /// one more specific than ours: removing `com.vendor.app` must not take
    /// `com.vendor.app.pro`'s files when that is installed too.
    private static func belongsToAnotherApp(_ stem: String, app: Identity, others: Set<String>) -> Bool {
        for other in others where other != app.bundleID {
            if stem == other { return true }
            if stem.hasPrefix(other + "."), other.count > app.bundleID.count || !stem.hasPrefix(app.bundleID) {
                return true
            }
        }
        return false
    }
}
