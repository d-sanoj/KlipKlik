import AppKit

/// Where the drop pad docks: the camera housing on a MacBook, a stand-in of the
/// same shape everywhere else.
///
/// The pad used to appear beside the pointer, which meant it appeared somewhere
/// different every time. A fixed target is easier to hit even when it is further
/// away — it can be learned, and it sits against the top edge of the screen,
/// which you can reach by throwing the pointer at it rather than aiming.
enum NotchGeometry {
    /// The camera housing's rect in global screen coordinates, if there is one.
    static func notchRect(on screen: NSScreen) -> NSRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }

        // The gap between the two menu bar areas *is* the housing. Measured on a
        // 14-inch: left ends at 665, right starts at 850, so 185pt wide — and its
        // centre is 757.5 against a screen midX of 756. It is not perfectly
        // centred, so the gap is used directly rather than assuming symmetry.
        let width = right.minX - left.maxX
        guard width > 0, width < screen.frame.width else {
            // Widths are unambiguous even if the origins ever turn out to be in
            // some other coordinate space; fall back to a centred housing.
            let derived = screen.frame.width - left.width - right.width
            guard derived > 0 else { return nil }
            return snap(
                NSRect(
                    x: screen.frame.midX - derived / 2,
                    y: screen.frame.maxY - inset,
                    width: derived,
                    height: inset
                ),
                on: screen
            )
        }

        return snap(
            NSRect(
                x: left.maxX,
                y: screen.frame.maxY - inset,
                width: width,
                height: inset
            ),
            on: screen
        )
    }

    /// Height of the menu bar on a screen without a notch.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    /// What the pad docks to on any screen.
    ///
    /// External displays and non-notch Macs get a housing-shaped rectangle in the
    /// same place a notch would be, so the gesture is identical everywhere and
    /// nothing has to explain itself when you plug a monitor in.
    static func dock(on screen: NSScreen) -> NSRect {
        if let notch = notchRect(on: screen) { return notch }

        let height = menuBarHeight(on: screen)
        let width: CGFloat = 180
        return snap(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            on: screen
        )
    }

    /// Round a rect onto the screen's backing pixels so a 1px seam cannot open
    /// between the island and the real housing.
    static func snap(_ rect: NSRect, on screen: NSScreen) -> NSRect {
        let scale = max(screen.backingScaleFactor, 1)
        func up(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        func nearest(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = up(rect.minX)
        let maxX = nearest(rect.maxX)
        let maxY = nearest(rect.maxY)
        let minY = nearest(rect.minY)
        return NSRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    static func snap(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        let scale = max(screen.backingScaleFactor, 1)
        return (value * scale).rounded() / scale
    }

    /// The screen a point falls on, with the usual fallbacks.
    static func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
