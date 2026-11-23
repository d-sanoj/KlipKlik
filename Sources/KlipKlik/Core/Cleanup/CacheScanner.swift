import Foundation

/// One thing the cache cleaner can empty.
struct CacheItem: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case appCaches
        case webCaches
        case logs
        case developer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appCaches: return "App caches"
            case .webCaches: return "Web & AI app caches"
            case .logs: return "Logs & crash reports"
            case .developer: return "Developer caches"
            }
        }

        var detail: String {
            switch self {
            case .appCaches:
                return "Files apps keep to start faster. They are rebuilt as needed."
            case .webCaches:
                return "Downloaded page, code and GPU caches inside Electron and Chromium apps — "
                    + "ChatGPT, Claude, Slack, Discord, VS Code, Chrome. Logins, cookies and "
                    + "local data sit next to these and are never touched."
            case .logs:
                return "Diagnostic logs and crash reports. Nothing reads them once written."
            case .developer:
                return "Build products and package downloads. Safe, but rebuilding them takes "
                    + "time and network, so none is ticked to start with."
            }
        }
    }

    let url: URL
    let category: Category
    /// Who it belongs to, for display: "Slack", "com.spotify.client".
    let owner: String
    let size: Int64
    /// Ticked when the scan finishes.
    let preselected: Bool
    /// Why it is unticked, when it is.
    let note: String?

    var id: String { url.path }
}

/// Finds caches that are safe to delete, and nothing else.
///
/// "Safe" is narrow on purpose. A cache here is something its app rebuilds
/// without the user noticing anything but a slower first launch. What keeps
/// someone signed in — cookies, Local Storage, IndexedDB, session storage, the
/// keychain — lives right beside those caches in Chromium and Electron apps,
/// and is never listed: the walk does not even descend into it.
///
/// That also means an AI app's chats are not deleted here, deleted or not.
/// ChatGPT and Claude keep conversations on their servers and their local
/// state in the same storage as the login, so the only part that can be
/// cleared safely is the download cache, which is what this offers.
enum CacheScanner {
    /// Smaller than this is not worth a row.
    static let minimumSize: Int64 = 256 * 1024

    /// Folder names Chromium and Electron use for disposable data.
    static let chromiumCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "GrShaderCache", "ShaderCache", "CachedData", "Crashpad"
    ]

    /// Never descended into: these hold logins, sessions and user data.
    static let protectedFolderNames: Set<String> = [
        "Local Storage", "Session Storage", "IndexedDB", "WebStorage", "Cookies",
        "databases", "Extensions", "Local Extension Settings", "Extension State",
        "Sync Data", "Sync Extension Settings", "blob_storage", "File System",
        "Login Data", "Network", "shared_proto_db", "Accounts", "Storage",
        "Default/Storage", "Managed Extension Settings", "Web Applications"
    ]

    /// Apps whose data must never be offered, whatever the folder is called.
    /// Password managers above all, and Spotify, whose offline downloads live
    /// in what looks like a cache.
    static let protectedOwners: [String] = [
        "1password", "agilebits", "bitwarden", "dashlane", "lastpass", "keepass", "enpass",
        "protonpass", "proton pass", "keeper", "nordpass", "spotify", "klipklik",
        "com.sanoj.klipklik", "cloudkit", "keychain"
    ]

    /// Caches that are package downloads or build output: listed under
    /// Developer, unticked, and kept out of the general App caches list.
    static let developerCacheNames: Set<String> = [
        "Homebrew", "pip", "Yarn", "go-build", "CocoaPods", "org.swift.swiftpm",
        "JetBrains", "node-gyp", "pnpm", "typescript", "com.apple.dt.Xcode"
    ]

    /// Never listed at all: these are tools that live in Caches but are not
    /// caches — deleting them means a large re-download for no gain.
    static let notCaches: Set<String> = ["ms-playwright", "Cypress", "puppeteer", "electron"]

    static func isProtectedOwner(_ name: String) -> Bool {
        let lower = name.lowercased()
        return protectedOwners.contains { lower.contains($0) }
    }

    struct Context {
        /// Paths the user said never to offer again.
        var skipped: Set<String> = []
        /// Normalised names and lowercased bundle IDs of running apps.
        var running: Set<String> = []
    }

    static func scan(_ context: Context) -> [CacheItem] {
        var items: [CacheItem] = []
        items += appCaches(context)
        items += webCaches(context)
        items += logs(context)
        items += developerCaches(context)
        return items
            .filter { !context.skipped.contains($0.url.path) && $0.size >= minimumSize }
            .sorted { $0.size > $1.size }
    }

    private static var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    }

    // MARK: Categories

    private static func appCaches(_ context: Context) -> [CacheItem] {
        let caches = library.appendingPathComponent("Caches")
        return children(of: caches).compactMap { url in
            let name = url.lastPathComponent
            guard !LeftoverMatcher.isAppleOwned(name), !isProtectedOwner(name),
                  !developerCacheNames.contains(name), !notCaches.contains(name),
                  isDirectory(url)
            else { return nil }
            let running = isRunning(name, context)
            return CacheItem(
                url: url, category: .appCaches, owner: name,
                size: LeftoverScanner.allocatedSize(of: url),
                preselected: !running, note: running ? "Open now — quit it first" : nil
            )
        }
    }

    private static func webCaches(_ context: Context) -> [CacheItem] {
        let support = library.appendingPathComponent("Application Support")
        var found: [CacheItem] = []
        for top in children(of: support) where isDirectory(top) {
            let owner = top.lastPathComponent
            guard !LeftoverMatcher.isAppleOwned(owner), !isProtectedOwner(owner) else { continue }
            let running = isRunning(owner, context)
            walk(top, depth: 4) { cache in
                found.append(CacheItem(
                    url: cache, category: .webCaches,
                    owner: ownerLabel(for: cache, under: support),
                    size: LeftoverScanner.allocatedSize(of: cache),
                    preselected: !running, note: running ? "Open now — quit it first" : nil
                ))
            }
        }
        return found
    }

    /// Descends plain folders looking for Chromium cache folders, never into
    /// the ones that hold logins or user data.
    private static func walk(_ folder: URL, depth: Int, found: (URL) -> Void) {
        guard depth > 0 else { return }
        for child in children(of: folder) where isDirectory(child) {
            let name = child.lastPathComponent
            if protectedFolderNames.contains(name) || isProtectedOwner(name) { continue }
            if name == "Service Worker" {
                for inner in ["CacheStorage", "ScriptCache"] {
                    let url = child.appendingPathComponent(inner)
                    if isDirectory(url) { found(url) }
                }
                continue
            }
            if name == "Crashpad" {
                // Only the reports already sent; `pending` may still go out.
                let completed = child.appendingPathComponent("completed")
                if isDirectory(completed) { found(completed) }
                continue
            }
            if chromiumCacheNames.contains(name) {
                found(child)
                continue
            }
            walk(child, depth: depth - 1, found: found)
        }
    }

    private static func logs(_ context: Context) -> [CacheItem] {
        let logs = library.appendingPathComponent("Logs")
        return children(of: logs).compactMap { url in
            let name = url.lastPathComponent
            guard !LeftoverMatcher.isAppleOwned(name) || name == "DiagnosticReports",
                  !isProtectedOwner(name)
            else { return nil }
            return CacheItem(
                url: url, category: .logs,
                owner: name == "DiagnosticReports" ? "Crash reports" : name,
                size: LeftoverScanner.allocatedSize(of: url),
                preselected: true, note: nil
            )
        }
    }

    private static func developerCaches(_ context: Context) -> [CacheItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known: [(String, String)] = [
            ("Library/Developer/Xcode/DerivedData", "Xcode build data"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "Xcode iOS device support"),
            ("Library/Developer/Xcode/watchOS DeviceSupport", "Xcode watchOS device support"),
            ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
            ("Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
            ("Library/Caches/Homebrew", "Homebrew downloads"),
            ("Library/Caches/pip", "pip"),
            ("Library/Caches/Yarn", "Yarn"),
            ("Library/Caches/go-build", "Go build cache"),
            ("Library/Caches/CocoaPods", "CocoaPods"),
            ("Library/Caches/org.swift.swiftpm", "Swift Package Manager"),
            ("Library/Caches/JetBrains", "JetBrains IDEs"),
            ("Library/Caches/node-gyp", "node-gyp"),
            (".npm/_cacache", "npm"),
            (".gradle/caches", "Gradle")
        ]
        let xcodeRunning = context.running.contains("xcode")
        return known.compactMap { path, label in
            let url = home.appendingPathComponent(path)
            guard isDirectory(url) else { return nil }
            let usesXcode = path.contains("Xcode") || path.contains("CoreSimulator")
            return CacheItem(
                url: url, category: .developer, owner: label,
                size: LeftoverScanner.allocatedSize(of: url),
                preselected: false,
                note: usesXcode && xcodeRunning ? "Xcode is open — quit it first" : nil
            )
        }
    }

    // MARK: Cleaning

    struct Report {
        var freedBytes: Int64 = 0
        var cleaned = 0
        var failures: [String] = []
    }

    /// Empties each item: its contents go, the folder itself stays so the app
    /// finds it where it expects it. Permanent — the Trash would only move the
    /// space, not free it — which is why the window asks first.
    static func clean(_ items: [CacheItem], completion: @escaping (Report) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report = Report()
            for item in items {
                // Re-checked at the last moment, in case the scan is stale.
                guard !isProtectedOwner(item.url.lastPathComponent) else { continue }
                var failed = false
                for child in children(of: item.url, includeHidden: true) {
                    do {
                        try FileManager.default.removeItem(at: child)
                    } catch {
                        failed = true
                    }
                }
                let remaining = LeftoverScanner.allocatedSize(of: item.url)
                report.freedBytes += max(0, item.size - remaining)
                report.cleaned += 1
                if failed { report.failures.append(item.owner) }
            }
            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: Helpers

    private static func children(of url: URL, includeHidden: Bool = false) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRunning(_ owner: String, _ context: Context) -> Bool {
        let normalized = LeftoverMatcher.normalize(owner)
        if context.running.contains(owner.lowercased()) || context.running.contains(normalized) {
            return true
        }
        // A vendor folder ("Google") belongs to whichever of its apps is open
        // ("Google Chrome").
        return normalized.count >= 4
            && context.running.contains { $0.count > normalized.count && $0.hasPrefix(normalized) }
    }

    /// What `Context.running` expects, from the apps open right now.
    static func runningKeys(_ apps: [(name: String?, bundleID: String?)]) -> Set<String> {
        var keys = Set<String>()
        for app in apps {
            if let name = app.name { keys.insert(LeftoverMatcher.normalize(name)) }
            if let id = app.bundleID { keys.insert(id.lowercased()) }
        }
        return keys
    }

    /// "Claude", or "Google Chrome — Profile 1" for a cache a level deeper.
    private static func ownerLabel(for cache: URL, under support: URL) -> String {
        let relative = cache.path.dropFirst(support.path.count + 1)
        let parts = relative.split(separator: "/").map(String.init)
        guard let top = parts.first else { return cache.lastPathComponent }
        let middle = parts.dropFirst().dropLast().filter { $0 != "Default" && $0 != "Partitions" }
        return ([top] + middle.prefix(1)).joined(separator: " — ")
    }
}
