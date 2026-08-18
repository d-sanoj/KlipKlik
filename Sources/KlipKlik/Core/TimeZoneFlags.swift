import CryptoKit
import Foundation

/// The flag emoji for a time zone's country.
///
/// Foundation has no zone → country mapping, but the tz database ships one:
/// `zone.tab`, alongside the zone files themselves. It covers only the
/// canonical zones, so the aliases people actually pick — `Asia/Calcutta`,
/// `US/Eastern`, `Japan` — are absent and need resolving a second way.
final class TimeZoneFlags {
    static let shared = TimeZoneFlags()

    /// Offset-only zones (`UTC`, `Etc/GMT+5`) belong to no country.
    static let noCountry = "🌐"

    private let root: String?
    private var cache: [String: String] = [:]
    /// zone.tab's canonical zone → ISO 3166 country code.
    private lazy var countryByZone: [String: String] = loadZoneTab()
    /// Zone files grouped by a digest of their contents, built only if an alias
    /// needs it. Keyed by the hash rather than the bytes: the bytes were the
    /// dictionary key, which meant holding every canonical zone file in memory
    /// for the life of the process to compare against.
    private lazy var zonesByContent: [Data: [String]] = groupZonesByContent()

    private init() {
        let candidates = ["/var/db/timezone/zoneinfo", "/usr/share/zoneinfo"]
        root = candidates.first { FileManager.default.fileExists(atPath: "\($0)/zone.tab") }
    }

    func flag(for identifier: String) -> String {
        if let cached = cache[identifier] { return cached }
        let result = countryCode(for: identifier).map(Self.emoji) ?? Self.noCountry
        cache[identifier] = result
        return result
    }

    private func countryCode(for identifier: String) -> String? {
        if let code = countryByZone[identifier] { return code }

        // An alias: its file is a byte-for-byte copy of the zone it points at,
        // so the country comes from whichever canonical zones share those bytes.
        guard let root, let data = FileManager.default.contents(atPath: "\(root)/\(identifier)"),
              let group = zonesByContent[Self.digest(data)]
        else { return nil }

        // Several countries can share one rule set — Oslo, Stockholm and Berlin
        // are the same bytes. Those are each listed in zone.tab and never reach
        // here; anything that does and is still ambiguous gets no flag rather
        // than a wrong one.
        let codes = Set(group.compactMap { countryByZone[$0] })
        return codes.count == 1 ? codes.first : nil
    }

    /// `IN\t+2232+08822\tAsia/Kolkata` — country, coordinates, zone.
    private func loadZoneTab() -> [String: String] {
        guard let root,
              let text = try? String(contentsOfFile: "\(root)/zone.tab", encoding: .utf8)
        else { return [:] }

        var map: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3 else { continue }
            map[String(fields[2])] = String(fields[0])
        }
        return map
    }

    private func groupZonesByContent() -> [Data: [String]] {
        guard let root, let walker = FileManager.default.enumerator(atPath: root) else { return [:] }

        var groups: [Data: [String]] = [:]
        for case let path as String in walker {
            // Only the canonical zones can contribute a country, so there is no
            // point reading anything zone.tab doesn't name.
            guard countryByZone[path] != nil,
                  let data = FileManager.default.contents(atPath: "\(root)/\(path)")
            else { continue }
            groups[Self.digest(data), default: []].append(path)
        }
        return groups
    }

    /// 32 bytes per zone instead of the whole file. Aliases are byte-for-byte
    /// copies, so a digest identifies them exactly as well as the contents did.
    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// "IN" → 🇮🇳, by offsetting each letter into the regional indicators.
    private static func emoji(_ code: String) -> String {
        let letters = code.uppercased().unicodeScalars
        guard code.count == 2, letters.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
            return noCountry
        }
        return String(String.UnicodeScalarView(letters.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
}
