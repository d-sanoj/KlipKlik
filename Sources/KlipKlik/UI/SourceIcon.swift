import AppKit
import SwiftUI

/// App icons by bundle identifier, looked up once each.
///
/// Resolving a bundle identifier to an icon goes to LaunchServices, and a
/// popup row is redrawn often — every hover, every keystroke in the search.
/// A few dozen distinct apps feed a clipboard history, so caching them all,
/// misses included, costs a few kilobytes and saves every repeat lookup.
final class AppIconCache {
    static let shared = AppIconCache()

    private var icons: [String: NSImage] = [:]
    private var misses: Set<String> = []

    func icon(for bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard !misses.contains(bundleID) else { return nil }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // Drawn at 16 pt; asking for that size up front keeps AppKit from
        // rasterising the 1024 px representation for every row.
        icon.size = NSSize(width: 32, height: 32)
        icons[bundleID] = icon
        return icon
    }
}

/// The leading mark on a popup row: the copying app's icon, or a symbol for
/// the item's kind when the app is unknown.
struct SourceIcon: View {
    let item: ClipboardItem
    let palette: Palette

    static let size: CGFloat = 16

    var body: some View {
        Group {
            if let bundleID = item.sourceBundleID,
               let icon = AppIconCache.shared.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: Self.symbol(for: item.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    static func symbol(for kind: ClipKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .rich: return "textformat"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
}
