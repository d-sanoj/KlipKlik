import Foundation

/// The text a picked colour is copied as.
enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, hsl, swiftUI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .swiftUI: return "SwiftUI"
        }
    }

    /// sRGB components in 0…1.
    struct Components: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    func string(for color: Components) -> String {
        let r = Self.byte(color.red), g = Self.byte(color.green), b = Self.byte(color.blue)
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let (h, s, l) = Self.hsl(color)
            return "hsl(\(h), \(s)%, \(l)%)"
        case .swiftUI:
            return "Color(red: \(Self.unit(color.red)), green: \(Self.unit(color.green)), "
                + "blue: \(Self.unit(color.blue)))"
        }
    }

    /// Reads `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` optional), as the
    /// history recognises colours.
    static func components(fromHex text: String) -> Components? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex.prefix(6), radix: 16)
        else { return nil }
        return Components(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Three decimals: enough to round-trip an 8-bit channel exactly.
    private static func unit(_ value: Double) -> String {
        let rounded = (min(max(value, 0), 1) * 1000).rounded() / 1000
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Hue in degrees, saturation and lightness in whole percent.
    private static func hsl(_ color: Components) -> (Int, Int, Int) {
        // Computed from the 8-bit values, so the HSL agrees with the HEX and
        // RGB strings for the same pick rather than with sub-byte noise.
        let r = Double(byte(color.red)) / 255
        let g = Double(byte(color.green)) / 255
        let b = Double(byte(color.blue)) / 255
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue

        guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maxValue {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        return (
            Int(hue.rounded()) % 360,
            Int((saturation * 100).rounded()),
            Int((lightness * 100).rounded())
        )
    }
}
