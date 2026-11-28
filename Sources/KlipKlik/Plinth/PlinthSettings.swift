import Combine
import Foundation

/// When the bar shows itself under Finder.
enum PlinthPresence: String, CaseIterable, Identifiable {
    /// Docked under the front Finder window whenever Finder is in front.
    case always
    /// Only after ⌥⌘K, and gone again once a request finishes or on esc.
    case onShortcut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Under every Finder window"
        case .onShortcut: return "Only after ⌥⌘K"
        }
    }
}

/// Plinth's own settings, kept apart from `Settings` so the feature can be
/// dropped or moved without touching the rest of the app's preferences.
final class PlinthSettings: ObservableObject {
    static let shared = PlinthSettings()

    private enum Key {
        static let enabled = "plinth.enabled"
        static let presence = "plinth.presence"
        static let selectResults = "plinth.selectResults"
    }

    /// The command bar under Finder, and its ⌥⌘K key.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) }
    }

    @Published var presence: PlinthPresence {
        didSet { UserDefaults.standard.set(presence.rawValue, forKey: Key.presence) }
    }

    /// Select what a request made, in Finder, once it finishes.
    @Published var selectResults: Bool {
        didSet { UserDefaults.standard.set(selectResults, forKey: Key.selectResults) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.enabled: true,
            Key.presence: PlinthPresence.always.rawValue,
            Key.selectResults: true
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        presence = PlinthPresence(rawValue: defaults.string(forKey: Key.presence) ?? "") ?? .always
        selectResults = defaults.bool(forKey: Key.selectResults)
    }
}
