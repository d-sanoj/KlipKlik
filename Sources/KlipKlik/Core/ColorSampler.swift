import AppKit

/// Picks a colour off the screen and puts it on the clipboard, written in the
/// notation chosen in Preferences (HEX by default).
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
            guard let color, let text = string(for: color, as: Settings.shared.colorFormat) else {
                completion(nil)
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Left for ClipboardMonitor to notice: a picked colour belongs in
            // history like any other copy, so this write is deliberately not
            // registered as one of ours to ignore.
            completion(text)
        }
    }

    /// The colour in the chosen notation, converted through sRGB first.
    static func string(for color: NSColor, as format: ColorFormat) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return format.string(for: ColorFormat.Components(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        ))
    }
}
