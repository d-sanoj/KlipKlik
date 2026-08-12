# 03 — Translating the design file

## What arrived

A Claude Design project, `Clipboard Manager.dc.html`. It is a React prototype
using a small template runtime (`x-dc`, `sc-if`, `sc-for`, `DCLogic`) with the
whole component in one HTML file, plus `support.js` which is the generated
runtime and contains no design information.

The useful parts were the inline styles and two CSS variable blocks,
`LIGHT_VARS` and `DARK_VARS`. Those are the actual design tokens.

## What the design specified

| | Value |
| --- | --- |
| Popup width | 340 (regular) / 280 (compact) |
| Max height | 440 |
| Corner radius | 12 |
| Row height | 34 (22pt chip + 6pt padding each side) |
| Chip | 22×22, radius 6, background `#f2f1ec`, glyph `#1a1a1a` |
| Trailing slot | 52 wide — timestamp and hover actions share it |
| Section header | 10.5px, weight 700, letter-spacing .06em |
| Accent | `#007aff` light / `#0a84ff` dark |

The chip colours are hardcoded in the design rather than themed. That is
deliberate: the chips stay the same warm off-white in dark mode, which gives the
glyphs a sticker look against either background. I kept it.

## Ported tokens

`LIGHT_VARS`/`DARK_VARS` became a `Palette` struct resolved from
`@Environment(\.colorScheme)`:

```swift
static let dark = Palette(
    textPrimary: Color(hex: 0xF5F5F7),
    textSecondary: .whiteAlpha(0.55),
    textTertiary: .whiteAlpha(0.38),
    rowHover: .whiteAlpha(0.07),
    rowSelected: Color(hex: 0x0A84FF, opacity: 0.25),
    divider: .whiteAlpha(0.09),
    accent: Color(hex: 0x0A84FF),
    ...
)
```

One naming trap. `Color.black` and `Color.white` already exist as static
properties, so adding `static func black(_ opacity: Double)` makes `.black(0.5)`
parse as *calling the property*:

```
error: cannot call value of non-function type 'Color'
```

Renamed to `blackAlpha` / `whiteAlpha`, with a comment so nobody "fixes" it back.

## The chip glyphs

The design draws its icons as inline SVG, not SF Symbols. Reproducing them with
SF Symbols would have been quicker and wrong. The shapes are specific.

I redrew them as `Canvas` paths in the same viewBox coordinates. The camera, for
example, is three shapes with the lens punched out in the *chip* colour rather
than left transparent:

```swift
context.fill(Path(roundedRect: CGRect(x: 9*sx, y: 5*sy, width: 6*sx, height: 3*sy),
                  cornerRadius: 1*sx), with: .color(Metrics.chipGlyph))
context.fill(Path(roundedRect: CGRect(x: 4*sx, y: 7*sy, width: 16*sx, height: 12*sy),
                  cornerRadius: 2*sx), with: .color(Metrics.chipGlyph))
// Lens is punched out in the chip colour, not the glyph colour.
context.fill(Path(ellipseIn: CGRect(x: (12-3.2)*sx, y: (13-3.2)*sy,
                                    width: 6.4*sx, height: 6.4*sy)),
             with: .color(Metrics.chipBackground))
```

A `GlyphCanvas` helper maps an SVG viewBox to a rendered size so the numbers in
the code match the numbers in the design file. Text and rich text are drawn as
literal characters, a serif `T` and an italic `Aa`, because that is what the
design shows.

## The bug that hid the whole redesign

The first build looked right and was completely wrong. Every row displayed the
same item:

```
• T  https://github.com/p0deje/Maccy      ⌘1
  T  https://github.com/p0deje/Maccy      ⌘2
  T  https://github.com/p0deje/Maccy      ⌘3
```

The capture layer was fine. Debug logging proved it:

```
capture #2699 kind=media title=Finder.icns
capture #2700 kind=text  title=The quick brown fox jumps over the lazy dog...
capture #2702 kind=media title=Image — 3840 × 2160
capture #2703 kind=text  title=KlipKlick — lightweight clipboard manager
capture #2704 kind=attachment title=com.apple.dock.plist
```

The bug was one line of SwiftUI:

```swift
ForEach(Array(viewModel.visibleItems.enumerated()), id: \.element.id) { index, item in
    ItemRow(item: item, ...)
        .id(index)          // ← this
}
```

`ForEach` was told identity is `item.id`. Then `.id(index)` **overrode** that
with the row position. In a `LazyVStack` SwiftUI then reuses rows by position,
and the content goes stale. The `.id()` was there so `ScrollViewReader` could
scroll to a selection.

Fix: give the row the same identity `ForEach` uses, and scroll to that instead.

```swift
.id(item.id)
...
.onChange(of: viewModel.scrollTick) { _, _ in
    guard let id = viewModel.selectedItem?.id else { return }
    proxy.scrollTo(id, anchor: .center)
}
```

Worth remembering: `.id()` is not a label you attach for scrolling. It *is* the
view's identity, and setting it inside a `ForEach` silently replaces what
`ForEach` established.

## Preferences

The design draws its own title bar with traffic lights, because it is an HTML
prototype sitting on a fake desktop. In a real app that chrome comes from
`NSWindow`, so I reproduced only the content below it: the centred pill tab bar
and the panes.

Five tabs — General, Shortcuts, Appearance, Ignored Apps, Storage.

One measured detail. An unconstrained `TabView` in an `NSHostingController`
collapses to zero height, so the window opens invisible. I confirmed it by
launching and finding the process alive with no window on screen. The size has to
be pinned to fit the tallest tab.

The onboarding window has the opposite fix. A fixed 420×380 clipped its own
button when the copy grew, so that one is `frame(width:)` plus
`fixedSize(horizontal: false, vertical: true)` and sizes to content. Both windows
are SwiftUI in a hosting controller; which approach works depends on whether a
`TabView` is involved.

## Where I deviated

**Storage tab wording.** The design says "Approx. 4.2 MB on disk". History is
memory-only, so the honest figure is the in-memory footprint. It reads
"Approx. X in memory — nothing is written to disk."

**Keyboard navigation kept.** The design's rows show no shortcut hints. I kept
arrows, Return, `⌘1`–`⌘9` and `⌥P` working anyway, since removing them from a
keyboard-first tool to match a static mock would be following the picture over
the point.

**Row dimming raised from 0.7 to 0.9.** The design dims un-hovered rows to 0.7,
which is fine over an opaque panel. On clear glass that dimming fights whatever
shows through and the text becomes hard to read. See
[04-liquid-glass.md](04-liquid-glass.md).
