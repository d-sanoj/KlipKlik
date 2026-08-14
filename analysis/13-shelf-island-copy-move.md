# 13 — Notch island, Copy vs Move, and making the shelf behave like Finder

This is the session after [12-drag-shelf.md](12-drag-shelf.md). The trigger
(noticing a drag without Accessibility) and the first notch pad were already
shipped. What was left was everything the user actually *does* with it: how the
island looks, whether dropping means copy or move, how files get selected, how
the window sizes itself, and a pile of pointer-handling bugs that only show up
once there is more than one file on a shelf.

The work looks like UI polish from the outside. Most of the time was spent
discovering that SwiftUI and AppKit do not share a hit-testing model, that
Finder will delete the original if a drop destination returns `.move`, and that
a window which grows 32pt on hover is a bounce even when the animation is an
ease-in-out.

## What was asked for, in order

The requests arrived one at a time, each in response to the previous build:

1. The drop target should *be* the notch, then expand out of it — not a bar
   sliding down from the top of the screen.
2. It should be solid black, flush with the housing, a bit wider than the
   camera, with the label inset from the bottom and appearing only after the
   expand has settled.
3. Hovering the island should not bounce it. Waiting and targeted are the same
   size.
4. There should be an explicit Copy vs Move choice. The first attempt put that
   choice on the shelf while dragging *out*. That was the wrong moment.
5. Copy means the original stays on disk, always. Move does **not** delete the
   original when the file lands on the shelf. Move only completes when the file
   is dragged *out* of a Move shelf.
6. Closing a shelf, or clicking × on a tile, must never trash the original.
7. Multiple files should be selectable, the way Finder's icon view is.
8. Clicking empty space should deselect. ⌘A should select all.
9. The window should size itself to the number of files, not sit at a
   three-row minimum with two files rattling around inside it.
10. Hovering the shelf should show the action buttons without resizing the
    window. The bounce on pointer-enter / pointer-leave was the bug.
11. The × on a tile has to actually remove that file.
12. Removing the last file should close the shelf.

Each of those sounded small. Several of them required throwing away the previous
attempt rather than patching it.

## The island is an AppKit view inside a motionless window

The first pad was a SwiftUI shape in a panel whose *frame* animated. Two
problems showed up immediately.

**Animating the panel frame stutters.** The window-server is compositing a
transparent, borderless, high-level panel against the camera housing, and every
frame of an `NSWindow.setFrame` animation is a round-trip through that. On a
ProMotion display it was not smooth; it was a black rectangle catching up. The
fix is that the panel never moves. It is a large transparent `NSPanel` parked
over the top of the screen. The *shape* springs inside it.

**SwiftUI layout does not lock to the camera.** `NotchGeometry.dock` is correct
in screen coordinates. SwiftUI then laid the shape out in the hosting view, and
the hosting view is not the screen. The island drifted left of the housing by a
few points — sometimes more, depending on safe-area insets — which is fatal for
a thing whose entire job is to look like the notch itself growing. The shape is
now `NotchIslandView`, an `NSView` that converts the dock rect with
`convertFromScreen` every draw. The housing and the blob share a coordinate
space, so they cannot disagree.

The spring is a `CASpringAnimation` on `blobWidth` / `blobHeight` / `blobRadius`
via `defaultAnimation(forKey:)`:

```
mass       0.65
stiffness  260
damping    30
```

That is fast and overdamped. Earlier springs had bounce, and bounce on the
notch looks like the camera is wobbling. Waiting and targeted use the same
resting size so hovering a file over the island does not re-spring it.

The expanded width is `max(notchWidth * 1.5, notchWidth + 80)` — the housing
plus about 20% on each side, with a floor so a small notch still has two
tappable halves. Bottom corners are rounded; the top is flush with the screen
edge, drawn by extending the rounded rect *up* by `radius` so the top of the
circle is clipped off-screen. That is what makes it read as "the notch got
taller" rather than "a pill appeared under the notch."

The "Drop files" / "Copy" / "Move" labels wait until the spring has mostly
settled, then fade in, inset ~22pt from the bottom. Showing them during the
expand made the type swim.

On a successful drop the island holds for a beat, then eases back into the
housing while the shelf is born underneath (`handoffToShelf()`). The two
motions have to overlap or they read as two unrelated windows.

## The shelf has to grow out of the island, not pop nearby

`ShelfAppearance.Entrance.fromNotch` scales the SwiftUI body from the top
(`hiddenScaleX ≈ 0.9`, `hiddenScaleY ≈ 0.36`) with `dampingFraction: 1.0`. The
window itself does not slide. `animationBehavior = .none` is load-bearing: the
utility-window animation interpolates from the panel's birth rect, which is
`(0, 0)` at the bottom-left of the screen, so a new shelf used to crawl up from
there. Top-left is pinned across resizes the same way the clipboard popup is,
because SwiftUI grows a window from the bottom-left.

## Copy vs Move, and the time we almost deleted the user's files

### The overlay on the way out was the wrong UI

The first Copy/Move control was a split overlay *on the shelf* that appeared
while dragging a tile out. It fought the destination. Finder, a browser, another
shelf — each of those already has an opinion about copy vs move, advertised
through the drag operation and the modifier keys. Putting a second chooser on
the source meant the user was answering a question the destination was about to
answer again, and the two answers disagreed.

That overlay (`ShelfDragPolicy`) was deleted. The choice belongs at *intake*,
when the files first land.

### The expanded notch is the chooser

Left half **Copy**, right half **Move**. Hover fills that half at 10% white.
The shelf that is created is tagged `Shelf.Intake.copy` or `.move`, shown as a
small capsule in the header.

Split detection has to use the **pad window's** midline (`bounds.midX` in
window coordinates), not the island view's flipped local coordinates. The
island is flipped (`isFlipped = true`) so it draws from the top. Using its
local `midX` after converting a drag location into that space made both halves
report the same side — every drop was Copy, or every drop was Move, depending
on which way the conversion was wrong. Recomputing the side in
`performDragOperation` from the window, not the view, is what made the two
halves actually differ.

### Returning `.move` from the pad is how Finder deletes the original

This was the dangerous one.

A drop destination that returns `.move` is telling the *source* that it may
remove the original. Finder, as the source of a file drag, takes that at face
value and puts the file in the Trash (or unlinks it). The first Move
implementation returned `.move` from the pad so that "Move onto the shelf"
would cut the file out of the folder it came from.

That is not what was wanted, and it is not recoverable if the user did not
notice. The pad **always returns `.copy`**, even for the Move half. Finder
leaves the original alone. The shelf records `intake: .move` and otherwise
stores a reference, the same as Copy (`addMoving` is `add(urls:)`).

The cut happens later, and only then:

- Dragging a file *out* of a **Copy** shelf advertises `[.copy, .generic]`.
  The original stays on disk. A successful drop (non-empty operation) removes
  the row from the shelf because the file has gone where it was going.
- Dragging a file *out* of a **Move** shelf advertises `[.move, .copy, .generic]`.
  If Finder (or whoever) did not already take the original, a leftover at the
  source path is trashed ~0.35s later. That delay is so the destination has
  time to finish; checking immediately races the move.
- Cancelling the drag keeps the row.
- Closing the shelf, emptying it, or clicking × **does not** trash originals.
  `removeShelf` discards *staged* bytes (browser images, promised files) because
  those exist only for the shelf. Referenced Finder files are not ours.

The header badge exists so you can tell a Copy shelf from a Move shelf after
the notch has gone. Old saved shelves without the field decode as Copy, unless
every item was staged, in which case they infer Move.

## Selection, or: SwiftUI does not own the pointer on this window

A shelf tile is a SwiftUI drawing with an `NSView` laid over it
(`FileDragSourceView`). That view has to exist because a real file drag out of
the app is an `NSDraggingSession`, not a SwiftUI `.onDrag`. Once that view is
in the hierarchy it wins hit-testing against everything SwiftUI draws, including
buttons, taps, and hover. Mixing the two — SwiftUI `onTapGesture` for click,
AppKit for drag — produced buttons that only sometimes responded. One view owns
every pointer gesture on the tile. That decision is still correct. It is also
why every subsequent selection feature was harder than it looked.

### What the user gets now

| Gesture | Result |
| --- | --- |
| Click a file | Select it (replaces the selection) |
| Double-click | Open |
| ⌘-click | Toggle that file |
| Shift-click | Range from the anchor |
| Drag across tiles | Paint-select |
| Drag a selected file out of the grid | All selected files go with it |
| Click empty space | Deselect |
| Drag empty space | Rubber-band |
| ⌘A | Select all |
| Escape | Deselect |
| Hover a file, click × | Remove that file |
| Remove / drag out the last file | The shelf closes |

Action-bar operations use the selection if there is one, otherwise every file.

### Bugs that had to be found by using it

**⌘-click appeared to do nothing.** Modifiers were applied on mouse-down *and*
mouse-up. A ⌘-click toggled the tile on, then toggled it off. Modifiers now
apply on mouse-down only; mouse-up collapse is an unmodified click.

**A SwiftUI `onTapGesture` on the grid cleared the selection** whenever a tile
was clicked, because the tap fired on the container as well. Removed.

**Clicking empty space did not deselect.** The first canvas sat *behind* the
`LazyVGrid` in a `ZStack`. SwiftUI's grid fills its layout bounds for
hit-testing, so clicks on padding, gaps, and leftover rows never reached the
canvas. Putting the canvas on top fixed empty-space clicks and broke
everything else.

**Returning `nil` from the canvas `hitTest` over a tile** was supposed to let
AppKit keep searching until it found `FileDragSourceView`. The canvas is an
`NSViewRepresentable`. If the representable's view declines the hit, the
*wrapper* claims it, and the tile underneath never sees the click. The canvas
must never return nil for a point inside its bounds: it either handles the
event (empty space) or forwards it to the tile by calling `mouseDown` on the
`FileDragSourceView` it found by walking frames.

Walking frames, not `contentView.hitTest`, is required for the same reason: the
canvas is in front, so `hitTest` would recurse into itself.

**⌘A did not compile as `.onKeyPress(KeyEquivalent("a"), modifiers: .command)`.**
The SwiftUI overloads on this SDK want `keys: Set<KeyEquivalent>` or a
character set, not that pair. Even after switching to `keyDown` on the canvas,
⌘A still went to Finder, because the shelf panel's `canBecomeKey` was `wantsKey`,
and `wantsKey` was only raised for renaming. A click on a tile called
`makeFirstResponder` *before* `wantsKey` was set, so first-responder failed,
and AppKit delivered ⌘A as `selectAll:` to a hosting view that did not
implement it.

The panel can now become key after a click (`canBecomeKey` is `true`). A local
key monitor on the window controller consumes ⌘A / Escape while that panel is
key, and does *not* consume them while a text field is first responder, so
rename still selects the name. `selectAll(_:)` and `performKeyEquivalent` on
the AppKit views are backup.

**The × badge was a SwiftUI `Button` under the drag overlay**, with a hole
punched in `FileDragSourceView.hitTest` so the click could fall through. Two
failures: SwiftUI `onHover` never fires under an AppKit overlay, so the badge
often did not appear; and when the canvas sat on top, the hole's `nil` hit
went to the representable wrapper rather than the button. The badge is now
drawn in `FileDragSourceView.draw`, hover is driven by the canvas's tracking
area, and a click in the top-right 24pt calls `onRemove` directly.

## The click you should not have to make

Reported after living with it: with a shelf full of files, clicking a folder in
Finder and then reaching back to drag a file *out* took two gestures. A click to
wake the shelf, then the drag. Every time.

The instinct is to read that as a focus problem — the shelf went inactive, so
make it active again, perhaps on hover. That is the wrong layer. AppKit
**swallows the first click on a non-key window** to make it key, and does not
deliver it to the view underneath, unless that view says otherwise:

```swift
override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
```

Three views need it, and which three follows from the hit-testing above:
`ShelfCanvasView`, because its `hitTest` claims every point in the shelf and it
is therefore the view AppKit actually asks; `FileDragSourceView`, which is where
the drag session begins; and `WindowDragHandleView`, so moving the shelf costs
the same one gesture as dragging out of it.

**Hover-to-activate would have been the wrong fix.** A shelf floats above
everything and joins all spaces, so activating on hover means the pointer merely
*crossing* it steals keyboard focus from whatever is being typed in. It trades a
spare click for a much worse interruption. `acceptsFirstMouse` changes nothing
else: `mouseDown` still makes the window key, the click simply is not eaten on
the way in.

This is the same lesson as the `hitTest` returning `nil` above — when a click
goes missing on this window, the question is which view AppKit asked, not which
view drew the pixel.

**Noticed while testing, not yet fixed:** a shelf restored from
`shelves-index` can come back off-screen — one landed at y=1017 on a 982pt
display and was unreachable. `place()` clamps through `keepOnScreen()`, but a
restored position appears not to be re-clamped against the *current* display
arrangement. Unplugging an external monitor should reproduce it.

## Sizing and the hover bounce

The grid was hard-coded to three rows:

```
3 × (tile + caption) + 2 × spacing + padding
```

One file sat in a box built for twelve. Height is now `ceil(count / 4)` rows,
capped at three, then it scrolls. One to four files is one row; five to eight
is two; nine or more is three.

The bounce on hover was the action bar being *inserted into the `VStack`* when
`isHoveringShelf` became true, and removed when it became false, with
`.animation(..., value: isHoveringShelf)` on the whole body. The window's
`preferredContentSize` changed by 32pt, SwiftUI eased it, the window-server
pinned top-left — and the shelf pulsed.

An overlay of the buttons on the bottom of the grid would not have changed the
window size, and would not have received clicks, because `FileDragSourceView`
and the canvas are real NSViews in front of SwiftUI. The footer is therefore
always in the layout when the shelf has files. Hover only fades the buttons
and the hairline. The window does not move. The cost is 32pt of empty glass
along the bottom when the pointer is elsewhere. That is the right trade: a
stable rectangle beats a bouncing one, and the buttons have to work.

## Closing the last file

`takeOut` (a successful drag out) already called `removeShelf` when the last
row left. Clicking × (`remove(item:)`) and **Empty Shelf** (`removeAllItems`)
did not. An empty shelf is a box with a header and a "Drop files here" state,
which is not what anyone meant by "clear this." All three paths now go through
`closeIfEmpty`. Originals on disk are still not touched — `removeShelf`
discards staged bytes only.

## What did not work, collected

| Attempt | Why it failed |
| --- | --- |
| Animate the pad window's frame | Stutter; the shape has to move, not the window |
| Draw the island in SwiftUI | Drifted off the camera housing |
| Spring with bounce | The camera appeared to wobble |
| Different size for "targeted" | Hovering the island re-sprang it |
| Copy/Move overlay on the way *out* | Fought the destination; deleted |
| Return `.move` from the pad | Finder deleted the original on intake |
| Split-hit using the island's flipped coords | Both halves were the same half |
| SwiftUI `onTapGesture` on the grid | Cleared selection when clicking a tile |
| Apply ⌘/⇧ on mouse-up as well as mouse-down | ⌘-click toggled twice |
| Canvas *behind* the grid | Empty clicks never arrived |
| Canvas `hitTest` returning nil over tiles | Representable wrapper ate the click |
| `.onKeyPress` for ⌘A | No matching overload; also never key |
| `canBecomeKey` only while renaming | ⌘A went to Finder |
| SwiftUI × button + hit-test hole | Hover dead, click stolen |
| Insert action bar on hover | Window resized; looked like bounce |
| Overlay action bar on the grid | AppKit views stole the clicks |
| Leave an empty shelf after × | A box with nothing in it |
| Activate the shelf on hover | Steals keyboard focus by pointing at it |

## What I would still change

**The footer still reserves 32pt.** A collection-view-style overlay that is
itself an `NSView` (so it can sit in front of the tiles and receive clicks)
would let the window be exactly as tall as the files. That is the same pattern
as the canvas, applied to the toolbar.

**A SwiftUI `LazyVGrid` plus two `NSViewRepresentable` overlays is the wrong
host for icon-view interaction.** Finder's icon view is one NSView. Every
workaround in this session — frame walking, event forwarding, drawing the × in
AppKit, reserving footer space — is a consequence of that split. An
`NSCollectionView` (or a single custom `NSView`) for the body of the shelf
would collapse most of it. The SwiftUI chrome (header, glass, badge) can stay.

**Selection state lives in `@State` on `ShelfView`.** Keyboard commands reach
it through `NotificationCenter` because the window controller cannot see the
struct. An `ObservableObject` owned by `ShelfWindowController` would make ⌘A,
Escape, and rubber-band all talk to one place without notifications.

**Arrow keys do not move the selection.** Finder does. Easy to add once
selection is an object rather than view state.

**There are no automated tests for intake.** The Move-must-not-delete-on-drop
rule is the one that can destroy data, and it is currently enforced by a
comment and a return value. A unit test that the pad destination mask is
always `.copy`, and that `takeOut` on a Move shelf is the only path that
trashes a leftover, would have caught the first implementation.

**Promise-based sources (Photos, Mail, Safari) still need a hand on the
mouse.** Analysis 12 already flagged this. Nothing in this session exercised
them.

## Files

| File | Role in this session |
| --- | --- |
| `UI/Shelf/ShelfDropPad.swift` | `NotchIslandView`, spring, Copy/Move halves, handoff |
| `UI/Shelf/ShelfDropView.swift` | Split midline, always `.copy` on the pad, `onDropMovingFiles` |
| `UI/Shelf/ShelfWindow.swift` | fromNotch birth, key window, ⌘A monitor, top-left pin |
| `UI/Shelf/ShelfView.swift` | Selection, auto-height, reserved hover footer |
| `UI/Shelf/ShelfTile.swift` | Drawing only; pointer is the overlay |
| `UI/Shelf/FileDragSourceView.swift` | Drag out, paint-select, ×, canvas, event forwarding |
| `UI/Shelf/ShelfManager.swift` | Pad creates a shelf with `intake:` |
| `Core/Shelf/Shelf.swift` | `Intake`, Codable with `decodeIfPresent` |
| `Core/Shelf/ShelfStore.swift` | `addMoving` = add urls; `takeOut`; `closeIfEmpty` |
| `Core/Shelf/NotchGeometry.swift` | Snap the dock rect so the island cannot sit on a half-pixel |
