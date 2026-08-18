import AppKit

/// Picks a colour off the screen and puts its hex on the clipboard.
///
/// `NSColorSampler` is the system loupe — the same one the colour well uses — so
/// the magnifier, the pixel grid and the escape-to-cancel all come for free, and
/// no screen-recording permission is involved: the sampling happens outside this
/// process.
enum ColorSampler {
    /// Shows the loupe. `completion` gets the hex that was written, or nil if
    /// the user cancelled.
    static func pick(completion: @escaping (String?) -> Void) {
        NSColorSampler().show { color in
            guard let color, let hex = hexString(for: color) else {
                completion(nil)
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            // Left for ClipboardMonitor to notice: a picked colour belongs in
            // history like any other copy, so this write is deliberately not
            // registered as one of ours to ignore.
            completion(hex)
        }
    }

    /// `#RRGGBB`, converted through sRGB so a wide-gamut screen still yields the
    /// hex people expect to paste into CSS.
    static func hexString(for color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }
}
