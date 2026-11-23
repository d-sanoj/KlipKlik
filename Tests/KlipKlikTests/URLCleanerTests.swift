import Testing
@testable import KlipKlik

@Suite struct URLCleanerTests {
    @Test func removesUTMAndClickIDs() {
        let result = URLCleaner.clean("https://example.com/a?utm_source=x&id=7&fbclid=abc&utm_medium=y")
        #expect(result?.url == "https://example.com/a?id=7")
        #expect(result?.removed == ["utm_source", "fbclid", "utm_medium"])
    }

    @Test func dropsTheQuestionMarkWhenNothingIsLeft() {
        #expect(URLCleaner.clean("https://example.com/?gclid=1")?.url == "https://example.com/")
    }

    @Test func keepsTheFragment() {
        #expect(URLCleaner.clean("https://example.com/p?utm_source=a&b=2#section")?.url
            == "https://example.com/p?b=2#section")
        #expect(URLCleaner.clean("https://example.com/p?utm_source=a#top")?.url
            == "https://example.com/p#top")
    }

    @Test func leavesCleanLinksAlone() {
        #expect(URLCleaner.clean("https://example.com/p?q=hello%20world&page=2") == nil)
        #expect(URLCleaner.clean("https://example.com/") == nil)
    }

    @Test func keepsEncodingOfSurvivingParameters() {
        let result = URLCleaner.clean("https://example.com/s?q=a%2Bb%20c&utm_campaign=z&x=%E2%9C%93")
        #expect(result?.url == "https://example.com/s?q=a%2Bb%20c&x=%E2%9C%93")
    }

    @Test func youtubeKeepsVideoAndTimeButDropsShareTracker() {
        #expect(URLCleaner.clean("https://youtu.be/dQw4w9WgXcQ?si=abc123&t=42")?.url
            == "https://youtu.be/dQw4w9WgXcQ?t=42")
        #expect(URLCleaner.clean("https://www.youtube.com/watch?v=abc&pp=xyz&t=10s")?.url
            == "https://www.youtube.com/watch?v=abc&t=10s")
    }

    @Test func siteRulesDoNotLeakToOtherHosts() {
        // `si` is a tracker on YouTube and Spotify only.
        #expect(URLCleaner.clean("https://example.com/?si=keep") == nil)
        // A look-alike host is not a subdomain.
        #expect(URLCleaner.clean("https://notyoutube.com/?si=keep") == nil)
    }

    @Test func amazonCountryDomainsShareRules() {
        #expect(URLCleaner.clean("https://www.amazon.de/dp/B0?ref_=nav&psc=1")?.url
            == "https://www.amazon.de/dp/B0?psc=1")
    }

    @Test func ignoresNonWebAndMultiWordText() {
        #expect(URLCleaner.clean("mailto:a@b.c?utm_source=x") == nil)
        #expect(URLCleaner.clean("see https://example.com/?utm_source=x") == nil)
        #expect(URLCleaner.clean("ftp://example.com/?utm_source=x") == nil)
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(URLCleaner.clean("  https://example.com/?utm_source=x&a=1\n")?.url
            == "https://example.com/?a=1")
    }

    @Test func matchesNamesCaseInsensitively() {
        #expect(URLCleaner.clean("https://example.com/?UTM_Source=x&FBCLID=y&a=1")?.url
            == "https://example.com/?a=1")
    }

    @Test func keepsEmptyAndValuelessPairsThatAreNotTrackers() {
        #expect(URLCleaner.clean("https://example.com/?flag&utm_source=x&&b=")?.url
            == "https://example.com/?flag&&b=")
    }
}

@Suite struct ColorFormatTests {
    private let orange = ColorFormat.Components(red: 1, green: 0.5, blue: 0)

    @Test func formats() {
        #expect(ColorFormat.hex.string(for: orange) == "#FF8000")
        #expect(ColorFormat.rgb.string(for: orange) == "rgb(255, 128, 0)")
        #expect(ColorFormat.hsl.string(for: orange) == "hsl(30, 100%, 50%)")
        #expect(ColorFormat.swiftUI.string(for: orange) == "Color(red: 1, green: 0.5, blue: 0)")
    }

    @Test func greyHasNoHue() {
        let grey = ColorFormat.Components(red: 0.5, green: 0.5, blue: 0.5)
        #expect(ColorFormat.hsl.string(for: grey) == "hsl(0, 0%, 50%)")
    }

    @Test func parsesHex() {
        #expect(ColorFormat.components(fromHex: "#FFF") == .init(red: 1, green: 1, blue: 1))
        #expect(ColorFormat.components(fromHex: "00ff0080")?.green == 1)
        #expect(ColorFormat.components(fromHex: "#12") == nil)
    }

    @Test func blueHue() {
        let blue = ColorFormat.Components(red: 0, green: 0, blue: 1)
        #expect(ColorFormat.hsl.string(for: blue) == "hsl(240, 100%, 50%)")
    }
}
