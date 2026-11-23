import AppKit
import Combine

/// A typed abbreviation and the text it turns into.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String

    /// Two characters at least: a one-key trigger would fire on ordinary typing.
    static let minimumTriggerLength = 2

    var isUsable: Bool {
        trigger.count >= Self.minimumTriggerLength
            && !trigger.contains(where: \.isNewline)
            && !text.isEmpty
    }
}

/// The saved snippets. Plain text in UserDefaults: a snippet is something the
/// user chose to type often, not clipboard content, so it gets none of the
/// history's sealing.
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published var snippets: [Snippet] {
        didSet { save() }
    }

    private static let key = "snippets"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        } else {
            snippets = []
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// The matching and filling-in, kept free of events and the pasteboard so it
/// can be tested on its own.
enum SnippetMatcher {
    /// Longest characters remembered. Longer than any sensible trigger, short
    /// enough that a stray keystroke history is not held for long.
    static let bufferLimit = 64

    /// The snippet whose trigger the typed text ends with. The longest wins,
    /// so `;addr2` is not shadowed by `;addr`.
    static func match(_ typed: String, in snippets: [Snippet]) -> Snippet? {
        snippets
            .filter { $0.isUsable && typed.hasSuffix($0.trigger) }
            .max { $0.trigger.count < $1.trigger.count }
    }

    /// Fills `{date}`, `{time}` and `{clipboard}`. Unknown braces stay as typed.
    static func expand(_ text: String, now: Date, clipboard: String?) -> String {
        guard text.contains("{") else { return text }
        let date = DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .none)
        let time = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        return text
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }

    /// Appends typed characters, keeping only the most recent ones.
    static func append(_ characters: String, to buffer: String) -> String {
        let joined = buffer + characters
        return joined.count > bufferLimit ? String(joined.suffix(bufferLimit)) : joined
    }
}
