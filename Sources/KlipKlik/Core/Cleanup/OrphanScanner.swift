import Foundation

/// Files left behind by apps that are no longer installed.
///
/// Only names in reverse-DNS form are considered (`com.vendor.app`): they say
/// whose they are, so "nothing installed has this identifier" is a fact rather
/// than a guess. A folder called "Notes" says nothing, and is never offered.
///
/// Anything sharing a vendor with an installed app is skipped too —
/// `com.vendor.shared` may well be used by `com.vendor.app` without carrying
/// its name. That misses some real orphans, deliberately.
enum OrphanScanner {
    struct Group: Identifiable {
        /// The identifier the files are named after.
        let id: String
        var items: [Leftover]
        var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    }

    /// Never orphans even when nothing installed claims them: package managers
    /// and the system write files under these names with no app behind them.
    static let ignoredPrefixes = [
        "homebrew.", "org.macports.", "com.apple.", "group.com.apple.", "org.swift.",
        "org.python.", "org.nixos.", "com.openssh.", "org.openbsd.",
        // Apple's Shortcuts still files its data under its old name, Workflow.
        "is.workflow.",
        // Analytics and crash-reporting kits write under their own vendor's
        // name from inside other apps — they are nobody's leftovers.
        "com.amplitude.", "com.segment.", "com.mixpanel.", "io.sentry.", "com.crashlytics.",
        "com.google.firebase", "com.google.gtm", "com.braze.", "com.onesignal.",
        "com.appsflyer.", "com.facebook.sdk", "io.branch."
    ]

    private static var locations: [LeftoverScanner.Location] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        func user(_ path: String, _ place: LeftoverMatcher.Place = .perApp, measure: Bool = true)
            -> LeftoverScanner.Location {
            LeftoverScanner.Location(url: library.appendingPathComponent(path), place: place, measure: measure)
        }
        return [
            user("Application Support"),
            user("Application Scripts", measure: false),
            user("Caches"),
            user("Containers", measure: false),
            user("Group Containers", .groupContainers, measure: false),
            user("HTTPStorages"),
            user("Cookies"),
            user("Preferences"),
            user("Saved Application State"),
            user("Logs"),
            user("LaunchAgents"),
            user("WebKit")
        ]
    }

    static func scan(installed: Set<String>) -> [Group] {
        // Background jobs launchd has loaded are in use, app or not — a
        // command-line tool's agent has no bundle to be found by.
        let installed = installed.union(loadedJobLabels())
        let vendors = Set(installed.compactMap(vendor(of:)))
        var groups: [String: Group] = [:]

        for location in locations {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: location.url, includingPropertiesForKeys: nil
            ) else { continue }

            for entry in entries {
                guard let owner = orphanIdentifier(
                    entry.lastPathComponent, place: location.place,
                    installed: installed, vendors: vendors
                ) else { continue }

                let item = Leftover(
                    url: entry,
                    kind: location.url.lastPathComponent == "LaunchAgents" ? .launchAgent : .file,
                    strength: .related,
                    needsAdmin: !LeftoverScanner.isRemovable(entry),
                    size: location.measure ? LeftoverScanner.allocatedSize(of: entry) : nil
                )
                groups[owner, default: Group(id: owner, items: [])].items.append(item)
            }
        }

        return groups.values.sorted { $0.totalSize > $1.totalSize }
    }

    /// The identifier `name` is filed under when no installed app owns it, or
    /// nil when it is not an orphan.
    static func orphanIdentifier(
        _ name: String,
        place: LeftoverMatcher.Place,
        installed: Set<String>,
        vendors: Set<String>
    ) -> String? {
        // Hidden files are not named after anything.
        guard !name.hasPrefix(".") else { return nil }
        // Team and group prefixes are stripped wherever the name is found:
        // Application Scripts and Preferences use the same identifiers as
        // Group Containers. `place` is kept for callers' symmetry with the
        // matcher.
        let stem = withoutGroupPrefixes(LeftoverMatcher.stem(name))
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        // A real identifier starts with a domain: `com`, `net`, `io`, `ru`…
        guard parts.count >= 3, !parts.contains(where: \.isEmpty),
              let domain = parts.first, (2...6).contains(domain.count), domain.allSatisfy(\.isLetter),
              LeftoverMatcher.isReverseDNS(stem),
              !LeftoverMatcher.isAppleOwned(name),
              !ignoredPrefixes.contains(where: stem.hasPrefix),
              stem.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }

        for id in installed {
            if stem == id || stem.hasPrefix(id + ".") || id.hasPrefix(stem + ".") { return nil }
        }
        if let vendor = vendor(of: stem), vendors.contains(vendor) { return nil }

        return stem.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// `com.vendor` from `com.vendor.app`.
    static func vendor(of identifier: String) -> String? {
        let parts = identifier.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Labels of the jobs loaded in this login session.
    private static func loadedJobLabels() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // "PID  Status  Label" — the label is the last column.
        return Set(text.split(separator: "\n").dropFirst().compactMap {
            $0.split(separator: "\t").last.map { $0.lowercased() }
        })
    }

    /// `TEAMID.com.vendor.x` and `group.com.vendor.x` → `com.vendor.x`.
    static func withoutGroupPrefixes(_ stem: String) -> String {
        var result = stem
        if result.hasPrefix("group.") { result.removeFirst(6) }
        if let dot = result.firstIndex(of: "."),
           result.distance(from: result.startIndex, to: dot) == 10,
           result[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) {
            result = String(result[result.index(after: dot)...])
        }
        if result.hasPrefix("group.") { result.removeFirst(6) }
        return result
    }
}
