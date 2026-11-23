import Foundation
import Testing
@testable import KlipKlik

@Suite struct LsofParserTests {
    @Test func readsProcessesAndPorts() {
        let text = """
        p963
        crapportd
        Lsanoj
        f15
        n*:53564
        f16
        n*:53564
        p1191
        cControlCenter
        Lsanoj
        f11
        n127.0.0.1:7000
        f13
        n[::1]:5000
        """
        let ports = LsofParser.parse(text)
        #expect(ports.map(\.port) == [5000, 7000, 53564])
        #expect(ports.first?.command == "ControlCenter")
        #expect(ports.first?.address == "[::1]")
        #expect(ports.first?.isLocalOnly == true)
        #expect(ports.last?.pid == 963)
        #expect(ports.last?.isLocalOnly == false)
    }

    @Test func ignoresConnectionsAndJunk() {
        let ports = LsofParser.parse("p1\ncnode\nn127.0.0.1:1->127.0.0.1:2\nnnot-a-port\n")
        #expect(ports.isEmpty)
    }
}

@Suite struct BrewOutdatedParserTests {
    @Test func readsFormulaeAndCasks() throws {
        let json = """
        {
          "formulae": [
            {"name": "git", "installed_versions": ["2.44.0"], "current_version": "2.45.1",
             "pinned": false, "pinned_version": null},
            {"name": "node", "installed_versions": ["21.0.0", "22.1.0"], "current_version": "22.2.0",
             "pinned": true}
          ],
          "casks": [
            {"name": "firefox", "installed_versions": "125.0", "current_version": "126.0"}
          ]
        }
        """
        let packages = try #require(BrewOutdatedParser.parse(Data(json.utf8)))
        #expect(packages.map(\.name) == ["firefox", "git", "node"])
        let node = try #require(packages.first { $0.name == "node" })
        #expect(node.installed == "22.1.0")
        #expect(node.pinned)
        let firefox = try #require(packages.first { $0.name == "firefox" })
        #expect(firefox.isCask)
        #expect(firefox.installed == "125.0")
        #expect(firefox.latest == "126.0")
    }

    @Test func emptyAndBrokenOutput() {
        #expect(BrewOutdatedParser.parse(Data(#"{"formulae":[],"casks":[]}"#.utf8))?.isEmpty == true)
        #expect(BrewOutdatedParser.parse(Data("Error: no network".utf8)) == nil)
    }
}

@Suite struct AppRemoverScriptTests {
    @Test func quotesForTheShell() {
        #expect(AppRemover.quote("/Library/It's Here") == "'/Library/It'\\''s Here'")
        #expect(AppRemover.quote("$(rm -rf /)") == "'$(rm -rf /)'")
    }

    @Test func scriptMovesToTrashAndForgetsReceiptsOnce() {
        let items = [
            Leftover(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.helper.plist"),
                     kind: .launchDaemon, strength: .exact, needsAdmin: true, size: 1),
            Leftover(url: URL(fileURLWithPath: "/private/var/db/receipts/com.x.pkg.bom"),
                     kind: .receipt(packageID: "com.x.pkg"), strength: .exact, needsAdmin: true, size: 1),
            Leftover(url: URL(fileURLWithPath: "/private/var/db/receipts/com.x.pkg.plist"),
                     kind: .receipt(packageID: "com.x.pkg"), strength: .exact, needsAdmin: true, size: 1)
        ]
        let script = AppRemover.script(for: items)
        #expect(script.contains("launchctl bootout system '/Library/LaunchDaemons/com.x.helper.plist'"))
        #expect(script.components(separatedBy: "pkgutil --forget 'com.x.pkg'").count == 2)
        #expect(script.contains("/bin/mv -f '/Library/LaunchDaemons/com.x.helper.plist' '"))
        #expect(script.contains("/.Trash/"))
        #expect(!script.contains("rm "))
    }
}

@Suite struct BrewInstalledParserTests {
    private let json = """
    {
      "formulae": [
        {"name": "abseil", "desc": "C++ Common Libraries", "homepage": "https://abseil.io",
         "versions": {"stable": "20260817.0"}, "pinned": false, "outdated": false,
         "installed": [{"version": "20260817.0", "installed_on_request": false}]},
        {"name": "ffmpeg", "desc": "Play, record, convert media", "versions": {"stable": "9.1"},
         "pinned": false, "outdated": true,
         "installed": [{"version": "9.0.2_1", "installed_on_request": true}]}
      ],
      "casks": [
        {"token": "visual-studio-code", "name": ["Visual Studio Code"], "desc": "Code editor",
         "version": "1.99.0", "installed": "1.98.0", "outdated": true, "auto_updates": true}
      ]
    }
    """

    @Test func listsEverythingInstalled() throws {
        let outdated = [BrewPackage(name: "ffmpeg", displayName: "ffmpeg", isCask: false,
                                    installed: "9.0.2_1", latest: "9.1", isOutdated: true, pinned: false)]
        let packages = try #require(BrewInstalledParser.parse(Data(json.utf8), outdated: outdated))
        #expect(packages.map(\.name) == ["abseil", "ffmpeg", "visual-studio-code"])

        let abseil = try #require(packages.first { $0.name == "abseil" })
        #expect(!abseil.isOutdated)
        #expect(!abseil.installedOnRequest)
        #expect(abseil.summary == "C++ Common Libraries")
        #expect(abseil.homepage?.host == "abseil.io")

        let ffmpeg = try #require(packages.first { $0.name == "ffmpeg" })
        #expect(ffmpeg.isOutdated)
        #expect(ffmpeg.installed == "9.0.2_1")
        #expect(ffmpeg.latest == "9.1")
    }

    @Test func trustsBrewOutdatedOverTheInfoFlag() throws {
        // The cask says outdated in `brew info`, but it updates itself, so
        // `brew outdated` leaves it out — and so must the list.
        let packages = try #require(BrewInstalledParser.parse(Data(json.utf8), outdated: []))
        let code = try #require(packages.first { $0.isCask })
        #expect(code.displayName == "Visual Studio Code")
        #expect(!code.isOutdated)
        #expect(code.installed == "1.98.0")
    }

    @Test func brokenOutput() {
        #expect(BrewInstalledParser.parse(Data("Error".utf8), outdated: []) == nil)
    }
}

@Suite struct PrivacyRefusalTests {
    @Test func recognisesMacOSProtection() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(AppRemover.isPrivacyRefusal(cocoa))

        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        #expect(AppRemover.isPrivacyRefusal(wrapped))
    }

    @Test func otherFailuresAreNotProtection() {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(!AppRemover.isPrivacyRefusal(missing))
        let busy = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        #expect(!AppRemover.isPrivacyRefusal(busy))
    }
}

@Suite struct LsofFileParserTests {
    @Test func groupsFilesByProcess() {
        let text = """
        p501
        cPreview
        Lsanoj
        f4
        n/Volumes/Disk/photo.png
        f5
        n/Volumes/Disk/notes.txt
        f6
        n/Volumes/Disk/photo.png
        p77
        cmds_stores
        Lroot
        n/Volumes/Disk/.Spotlight-V100
        p999
        cKlipKlik
        n/Volumes/Disk
        """
        let holders = LsofFileParser.parse(text, excluding: 999)
        #expect(holders.map(\.pid) == [501, 77])
        #expect(holders[0].command == "Preview")
        #expect(holders[0].files == ["/Volumes/Disk/photo.png", "/Volumes/Disk/notes.txt"])
        #expect(holders[1].user == "root")
    }
}
