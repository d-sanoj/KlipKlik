import Foundation
import Testing
@testable import KlipKlik

@Suite struct SnippetTests {
    private let snippets = [
        Snippet(trigger: ";addr", text: "1 Infinite Loop"),
        Snippet(trigger: ";addr2", text: "Second address"),
        Snippet(trigger: "x", text: "too short"),
        Snippet(trigger: ";empty", text: "")
    ]

    @Test func matchesTheTriggerAtTheEnd() {
        #expect(SnippetMatcher.match("hello ;addr", in: snippets)?.text == "1 Infinite Loop")
        #expect(SnippetMatcher.match(";add", in: snippets) == nil)
    }

    @Test func longestTriggerWins() {
        #expect(SnippetMatcher.match("see ;addr2", in: snippets)?.text == "Second address")
    }

    @Test func unusableSnippetsNeverFire() {
        #expect(SnippetMatcher.match("x", in: snippets) == nil)
        #expect(SnippetMatcher.match(";empty", in: snippets) == nil)
    }

    @Test func fillsPlaceholders() {
        let filled = SnippetMatcher.expand("Hi {clipboard}! {nope}", now: Date(), clipboard: "Sam")
        #expect(filled == "Hi Sam! {nope}")
        #expect(SnippetMatcher.expand("{clipboard}", now: Date(), clipboard: nil) == "")
        #expect(!SnippetMatcher.expand("{date}", now: Date(), clipboard: nil).contains("{"))
    }

    @Test func bufferKeepsOnlyRecentCharacters() {
        let long = String(repeating: "a", count: 100)
        let buffer = SnippetMatcher.append("bc", to: long)
        #expect(buffer.count == SnippetMatcher.bufferLimit)
        #expect(buffer.hasSuffix("abc"))
    }
}
