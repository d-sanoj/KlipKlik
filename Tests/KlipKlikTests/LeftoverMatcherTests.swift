import Testing
@testable import KlipKlik

@Suite struct LeftoverMatcherTests {
    private let slack = LeftoverMatcher.Identity(
        bundleID: "com.tinyspeck.slackmacgap",
        names: ["Slack", "Slack", "Slack"],
        teamID: "BQR82RBBHL"
    )
    private let code = LeftoverMatcher.Identity(
        bundleID: "com.microsoft.VSCode",
        names: ["Visual Studio Code", "Code", "Electron"],
        teamID: "UBF8T346G9"
    )

    private func match(_ name: String, _ app: LeftoverMatcher.Identity,
                       _ place: LeftoverMatcher.Place = .perApp,
                       others: Set<String> = []) -> LeftoverMatcher.Strength? {
        LeftoverMatcher.match(name, in: place, app: app, otherBundleIDs: others)
    }

    @Test func bundleIDNamesAreExact() {
        #expect(match("com.tinyspeck.slackmacgap", slack) == .exact)
        #expect(match("com.tinyspeck.slackmacgap.plist", slack) == .exact)
        #expect(match("com.tinyspeck.slackmacgap.savedState", slack) == .exact)
        #expect(match("com.tinyspeck.slackmacgap.ShipIt", slack) == .exact)
        #expect(match("com.tinyspeck.slackmacgap.binarycookies", slack) == .exact)
    }

    @Test func appNamedFoldersAreExact() {
        #expect(match("Slack", slack) == .exact)
        #expect(match("Visual Studio Code", code) == .exact)
    }

    @Test func ordinaryWordNamesAreOnlyRelated() {
        // VS Code keeps its data in a folder called just "Code".
        #expect(match("Code", code) == .related)
    }

    @Test func frameworkAndRoleNamesNeverMatch() {
        #expect(match("Electron", code) == nil)
        #expect(match("Helper", slack) == nil)
        #expect(match("Google", slack) == nil)
    }

    @Test func longerNamesStartingWithTheAppAreRelated() {
        #expect(match("Slack Helper", slack) == .related)
        #expect(match("SlackDesktop", slack) == .related)
    }

    @Test func unrelatedNamesDoNotMatch() {
        #expect(match("Slacker", slack) == .related) // shares the prefix: offered, unticked
        #expect(match("Discord", slack) == nil)
        #expect(match("com.hnc.Discord", slack) == nil)
    }

    @Test func appleNamesAreNeverOffered() {
        let notes = LeftoverMatcher.Identity(bundleID: "com.example.notes", names: ["Notes"], teamID: nil)
        #expect(match("com.apple.Notes", notes) == nil)
        #expect(match("AddressBook", notes) == nil)
    }

    @Test func anotherInstalledAppKeepsItsFiles() {
        let base = LeftoverMatcher.Identity(bundleID: "com.vendor.app", names: ["Vendor App"], teamID: nil)
        let others: Set<String> = ["com.vendor.app.pro"]
        #expect(match("com.vendor.app.pro", base, others: others) == nil)
        #expect(match("com.vendor.app.pro.plist", base, others: others) == nil)
        #expect(match("com.vendor.app.helper", base, others: others) == .exact)
    }

    @Test func groupContainers() {
        #expect(match("BQR82RBBHL.com.tinyspeck.slackmacgap", slack, .groupContainers) == .exact)
        #expect(match("group.com.tinyspeck.slackmacgap", slack, .groupContainers) == .exact)
        // Same team, shared with other apps from that vendor: unticked.
        #expect(match("UBF8T346G9.Office", code, .groupContainers) == .related)
        #expect(match("UBF8T346G9.Office", slack, .groupContainers) == nil)
    }

    @Test func crashReportsMatchTheProcessName() {
        #expect(match("Slack-2026-11-02-101010.ips", slack, .crashReports) == .exact)
        #expect(match("Slack_2026-11-02-101010_mac.crash", slack, .crashReports) == .exact)
        #expect(match("Slacker-2026-11-02-101010.ips", slack, .crashReports) == nil)
    }

    @Test func sameVendorFilesMentioningTheAppAreRelated() {
        #expect(match("com.tinyspeck.SlackHelper", slack) == .related)
        #expect(match("com.tinyspeck.other", slack) == nil)
    }
}

@Suite struct OrphanScannerTests {
    private let installed: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.vscode"]

    private func orphan(_ name: String, _ place: LeftoverMatcher.Place = .perApp) -> String? {
        let vendors = Set(installed.compactMap(OrphanScanner.vendor(of:)))
        return OrphanScanner.orphanIdentifier(name, place: place, installed: installed, vendors: vendors)
    }

    @Test func uninstalledAppIdentifiersAreOrphans() {
        #expect(orphan("com.hnc.Discord") == "com.hnc.discord")
        #expect(orphan("com.hnc.Discord.plist") == "com.hnc.discord")
        #expect(orphan("com.hnc.Discord.ShipIt") == "com.hnc.discord")
    }

    @Test func installedAppsAndTheirChildrenAreNot() {
        #expect(orphan("com.tinyspeck.slackmacgap") == nil)
        #expect(orphan("com.tinyspeck.slackmacgap.ShipIt") == nil)
        #expect(orphan("com.microsoft.VSCode.plist") == nil)
    }

    @Test func sameVendorAsAnInstalledAppIsNot() {
        #expect(orphan("com.microsoft.autoupdate2") == nil)
    }

    @Test func plainNamesAndSystemNamesAreNot() {
        #expect(orphan("Discord") == nil)
        #expect(orphan("com.apple.Safari") == nil)
        #expect(orphan("homebrew.mxcl.postgresql.plist") == nil)
        #expect(orphan(".GlobalPreferences.plist") == nil)
    }

    @Test func groupContainerPrefixesAreStripped() {
        #expect(orphan("6N38VWS5BX.ru.keepcoder.Telegram", .groupContainers) == "ru.keepcoder.telegram")
        #expect(orphan("group.com.hnc.Discord", .groupContainers) == "com.hnc.discord")
    }

    @Test func falsePositivesFoundOnARealMac() {
        // Hidden cache files are not identifiers.
        #expect(orphan(".cache12513273677268744624.dat") == nil)
        // A team prefix outside Group Containers is still stripped.
        #expect(orphan("8T2DC9NRXS.group.com.tinyspeck.slackmacgap") == nil)
        // Two-part group names are not identifiers once the prefix is gone.
        #expect(orphan("group.wipr2.rules") == nil)
        // Analytics kits write under their own names from inside other apps.
        #expect(orphan("com.amplitude.storage.plist") == nil)
        #expect(orphan("com.segment.storage.abc") == nil)
        // A domain has to look like one.
        #expect(orphan("cache-v2.x.y") == nil)
    }
}
