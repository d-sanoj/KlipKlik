import SwiftUI

/// Layout constants, taken from the `Clipboard Manager.dc.html` design.
enum Metrics {
    static let cornerRadius: CGFloat = 12
    static let maxPopupHeight: CGFloat = 440

    static let headerPadding: CGFloat = 8
    static let searchCornerRadius: CGFloat = 7

    static let listPadding: CGFloat = 6
    static let listMinHeight: CGFloat = 120

    /// 22pt hover-action buttons + 3pt vertical padding either side. Rows carry
    /// no leading icon, so nothing taller than those buttons sets the floor.
    static let rowHeight: CGFloat = 28
    static let rowCornerRadius: CGFloat = 6
    static let rowHorizontalPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 8

    /// Fixed-width trailing slot the timestamp and the hover actions share.
    static let trailingSlotWidth: CGFloat = 52

    static let headerHeight: CGFloat = 45
    static let footerHeight: CGFloat = 36

    static var maxListHeight: CGFloat {
        maxPopupHeight - headerHeight - footerHeight
    }

}

/// The design's `LIGHT_VARS` / `DARK_VARS` CSS custom properties.
///
/// The design's opaque `--popup-bg` / `--popup-border` are absent: Liquid Glass
/// provides the surface and its own edge, so a painted background and hairline
/// would only sit on top of it.
struct Palette {
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let rowHover: Color
    let rowSelected: Color
    let divider: Color
    let accent: Color
    let searchBackground: Color
    let searchBorder: Color
    let danger: Color
    /// Fully opaque panel colour. Laid over the glass at `Settings.glassOpacity`,
    /// so the slider spans clear glass at 0 through a solid surface at 1.
    let surface: Color
    /// Fixed wash for the Preferences window, which does not follow the slider.
    let glassTint: NSColor

    static let light = Palette(
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: .blackAlpha(0.55),
        textTertiary: .blackAlpha(0.35),
        rowHover: .blackAlpha(0.05),
        rowSelected: Color(hex: 0x0A84FF, opacity: 0.12),
        divider: .blackAlpha(0.08),
        accent: Color(hex: 0x007AFF),
        searchBackground: .blackAlpha(0.05),
        searchBorder: .blackAlpha(0.09),
        danger: Color(hex: 0xFF3B30),
        surface: Color(hex: 0xF6F6F6),
        glassTint: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.30)
    )

    static let dark = Palette(
        textPrimary: Color(hex: 0xF5F5F7),
        textSecondary: .whiteAlpha(0.55),
        textTertiary: .whiteAlpha(0.38),
        rowHover: .whiteAlpha(0.07),
        rowSelected: Color(hex: 0x0A84FF, opacity: 0.25),
        divider: .whiteAlpha(0.09),
        accent: Color(hex: 0x0A84FF),
        searchBackground: .whiteAlpha(0.09),
        searchBorder: .whiteAlpha(0.13),
        danger: Color(hex: 0xFF453A),
        surface: Color(hex: 0x2A2A2D),
        glassTint: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.30)
    )

    static func resolve(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    // Not named `black`/`white`: those already exist as static properties, and
    // a same-named function makes `.black(0.5)` parse as calling the property.
    static func blackAlpha(_ opacity: Double) -> Color { Color(hex: 0x000000, opacity: opacity) }
    static func whiteAlpha(_ opacity: Double) -> Color { Color(hex: 0xFFFFFF, opacity: opacity) }
}

/// A real gaussian blur of whatever sits behind the window.
///
/// This is the layer that makes the backdrop *illegible*: Liquid Glass in its
/// `.clear` style tints but does not blur, so text behind it stays sharp and
/// readable. `NSVisualEffectView` with `behindWindow` blending reduces the
/// backdrop to colour and shape, which is what frosted glass actually does.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The popup's full glass stack: blur, Liquid Glass refraction, user tint, and a
/// specular sheen. Composed in that order so the blur always sits underneath and
/// the backdrop can never be read.
struct GlassSurface: View {
    let palette: Palette
    /// 0 is bare frosted glass, 1 is a fully opaque panel.
    let opacity: Double
    var cornerRadius: CGFloat = Metrics.cornerRadius

    var body: some View {
        ZStack {
            VisualEffectBackdrop(material: .hudWindow)

            // Liquid Glass adds edge refraction and dispersion on macOS 26. It
            // sits above the blur, so it refracts an already-illegible backdrop.
            if #available(macOS 26.0, *) {
                LiquidGlassBackground(style: .clear, tint: nil, cornerRadius: cornerRadius)
            }

            palette.surface.opacity(opacity)

            sheen
        }
    }

    /// Light catching the top edge and falling off — reads as a reflection and
    /// lifts the panel away from whatever is behind it.
    private var sheen: some View {
        LinearGradient(
            stops: [
                .init(color: .whiteAlpha(0.18), location: 0),
                .init(color: .whiteAlpha(0.05), location: 0.12),
                .init(color: .clear, location: 0.4),
                .init(color: .blackAlpha(0.05), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// macOS 26 Liquid Glass, with a blur fallback on older systems.
///
/// `NSGlassEffectView` is the real material — it refracts and reacts to whatever
/// is behind the window, which a `NSVisualEffectView` blur cannot do. The `.clear`
/// style is the most transparent of the two, so the desktop genuinely reads
/// through the panel rather than being frosted away.
struct LiquidGlassBackground: NSViewRepresentable {
    enum Style {
        /// Most transparent — used for the popup.
        case clear
        /// Slightly more substantial, for windows holding a lot of text.
        case regular
    }

    var style: Style = .clear
    var tint: NSColor?
    var cornerRadius: CGFloat = Metrics.cornerRadius
    /// Material used only on macOS 25 and earlier.
    var fallbackMaterial: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            apply(to: view)
            return view
        }

        let view = NSVisualEffectView()
        view.material = fallbackMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            apply(to: glass)
        } else if let blur = view as? NSVisualEffectView {
            blur.material = fallbackMaterial
            blur.layer?.cornerRadius = cornerRadius
        }
    }

    @available(macOS 26.0, *)
    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.style = style == .clear ? .clear : .regular
        view.tintColor = tint
    }
}
