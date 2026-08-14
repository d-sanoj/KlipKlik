import AppKit

/// Fills a submenu the first time it is opened, and refreshes it on every open
/// after that.
///
/// Exists for the timezone picker, which is ~600 zones deep. Building all of it
/// up front meant walking the whole zoneinfo tree and allocating every
/// `NSMenuItem` at launch — for a menu most people open once, into one region.
/// Menus are only ever displayed one level at a time, so nothing below the level
/// being shown has to exist yet.
final class LazyMenu: NSObject, NSMenuDelegate {
    private let build: (NSMenu) -> Void
    private let refresh: (NSMenu) -> Void
    private var isBuilt = false

    init(build: @escaping (NSMenu) -> Void, refresh: @escaping (NSMenu) -> Void = { _ in }) {
        self.build = build
        self.refresh = refresh
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if !isBuilt {
            isBuilt = true
            build(menu)
        }
        refresh(menu)
    }
}
