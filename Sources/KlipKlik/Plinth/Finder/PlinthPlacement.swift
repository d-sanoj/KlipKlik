import CoreGraphics

/// Where the bar goes relative to a Finder window. Pure geometry, so it is
/// tested without a screen.
enum PlinthPlacement {
    static let gap: CGFloat = 8
    static let inset: CGFloat = 12
    static let minWidth: CGFloat = 420
    static let maxWidth: CGFloat = 680

    /// - Parameters:
    ///   - window: the Finder window in Quartz coordinates — origin at the top
    ///     left of the main display, y growing downward — as both the window
    ///     server and Accessibility report it.
    ///   - height: the bar's current height; it grows when a preview shows.
    ///   - mainDisplayHeight: the height of the display with the menu bar,
    ///     which Cocoa's flipped y is measured from.
    ///   - visibleFrames: every screen's visible frame in Cocoa coordinates.
    /// - Returns: the bar's frame in Cocoa coordinates. Below the window when
    ///   it fits there, otherwise inside the window's bottom edge, so a
    ///   maximised window still gets a bar. Always kept on screen.
    static func frame(below window: CGRect, height: CGFloat, mainDisplayHeight: CGFloat,
                      visibleFrames: [CGRect]) -> CGRect {
        let cocoaWindow = CGRect(x: window.minX, y: mainDisplayHeight - window.maxY,
                                 width: window.width, height: window.height)
        let center = CGPoint(x: cocoaWindow.midX, y: cocoaWindow.midY)
        let screen = visibleFrames.first { $0.contains(center) }
            ?? visibleFrames.max { overlap($0, cocoaWindow) < overlap($1, cocoaWindow) }
            ?? cocoaWindow

        let width = min(max(cocoaWindow.width - 2 * inset, minWidth), maxWidth, screen.width - 2 * inset)
        var x = cocoaWindow.midX - width / 2
        x = min(max(x, screen.minX + inset), screen.maxX - inset - width)

        let below = cocoaWindow.minY - gap - height
        let y: CGFloat
        if below >= screen.minY + gap {
            y = below
        } else {
            y = max(cocoaWindow.minY + inset, screen.minY + gap)
        }
        return CGRect(x: x, y: min(y, screen.maxY - height), width: width, height: height)
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
