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
