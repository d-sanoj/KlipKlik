# Drag shelves — noticing a drag without asking for permission

The brief was Dropover: pick up files, park them somewhere floating, carry on,
drop them where you meant to. The interesting part is not the tray. It is the
trigger — knowing that a drag is happening at all, in someone else's
application, without the user granting anything first.

## The problem

A shelf you have to open *before* you start dragging is a shelf nobody uses. By
the time you want one, your hand is already holding the files. So the app has to
notice the drag itself.

Two obvious routes, both dead ends:

**`CGEventTap` on mouse events.** Works, and it is what most shelf apps do. It
also needs Accessibility, which [05-permissions.md](05-permissions.md) already
establishes is the most fragile thing in this project: the grant is tied to the
code signature, an ad-hoc signature changes on every build, and every rebuild
silently revokes it. A headline feature that is inert on first launch and dead
again after every update is not a feature.

**`NSEvent.addGlobalMonitorForEvents`.** Needs no permission for mouse events —
but it does not observe the modal tracking loop the *source* application runs for
the entire duration of a drag. That loop is precisely the window we care about.

## What actually works

Three global queries, none of them events, none of them gated:

| Query | Answers | Cost |
| --- | --- | --- |
| `NSEvent.pressedMouseButtons` | Is a button down right now? | Window-server state read |
| `NSPasteboard(name: .drag).changeCount` | Did a drag session just open? | Counter read |
| `NSEvent.mouseLocation` | Where to put the pad | Free |

The mechanism is the drag pasteboard. `NSDraggingSession` is created from the
shared `.drag` pasteboard, so the source application writes the dragged items to
it when the session opens — and a *shared* pasteboard is readable from any
process. Snapshot `changeCount` on mouse-down; a change while the button is
still held is a drag that just started, and the pasteboard itself says what is
in it.

The polling loop only touches the pasteboard on the tick where the count moves.
Every other tick is one integer comparison at 25 Hz.

## Measuring it

The assumption worth testing is not "can I read the drag pasteboard" — it is
"does a write in one process show up in another". Two copies of the same binary,
one writing and one polling at the real 40 ms interval:

```swift
// writer
let pasteboard = NSPasteboard(name: .drag)
pasteboard.clearContents()
pasteboard.writeObjects([URL(fileURLWithPath: "/etc/hosts") as NSURL])

// watcher — polls exactly as DragWatcher does
var baseline = pasteboard.changeCount
while ticks < 100 {
    usleep(40_000)
    if pasteboard.changeCount != baseline { /* read it */ }
}
```

```
watcher: baseline changeCount = 22
writer:  changeCount 22 -> 23
watcher: SAW CHANGE at tick 34: 22 -> 23
watcher: types = ["public.file-url", "NSFilenamesPboardType",
                  "Apple URL pasteboard type", ...]
watcher: fileURLs = ["/etc/hosts"]
```

Cross-process, full type list, file URLs read back — from an unsigned command
line binary holding no TCC grants at all.

An earlier run caught something better by accident. Before the writer had run,
the watcher picked up a change carrying `com.apple.finder.node` and
`/Applications/Antigravity.app` — a genuine Finder drag payload, from a process
nobody had arranged to cooperate. That is the real case, observed rather than
simulated.

## What the trigger costs elsewhere

Because detection needs nothing, the shelf is the only major feature in the app
that survives a denied or lapsed Accessibility grant. Only one shelf action needs
the permission — "Move to Front Finder Window", and only because it synthesises
⌥⌘V.

## Docking the target to the notch

The first version put the drop pad beside the pointer. It worked, and it was
wrong: the target appeared somewhere different on every drag, so there was
nothing to learn and every drop needed aiming from scratch.

The notch fixes both. It never moves, and it is against the top edge of the
screen — you can throw the pointer at it instead of aiming, which is the whole
of Fitts's law working in your favour despite the target being further away.

### Finding it

`safeAreaInsets.top` gives the height. For the width, the two menu bar areas
either side of the housing are what you actually get:

```
screen frame=(0.0, 0.0, 1512.0, 982.0)
safeAreaInsets.top = 32.0
auxTopLeft  = (0.0, 950.0, 665.0, 32.0)
auxTopRight = (850.0, 950.0, 662.0, 32.0)
gap between aux rects = 185.0
frame.width - left.width - right.width = 185.0
```

Both derivations agree at 185pt, but they are not interchangeable. The gap's
centre is 757.5 against a screen `midX` of 756 — **the housing is not perfectly
centred**, so assuming symmetry puts the shape 1.5pt off. The gap is used
directly, with the centred version kept only as a fallback in case the auxiliary
rects ever turn out to be in a coordinate space other than `frame`'s.

### Two things that have to be right, and were not

**Window level.** The pad started at `.modalPanel`, which is 8. The menu bar is
`.mainMenu`, which is 24. A pad at the notch was therefore *behind* the menu bar
it is supposed to grow out of. It now sits at `.statusBar + 1`.

**The safe area.** A window overlapping the notch is handed a 32pt top safe-area
inset — exactly the height the shape is trying to line up with. Combined with an
explicit `.padding(.top, notchHeight)` on the container, the shape was drawn a
full housing-height below the real housing. Measuring the panel frame said
`y = 0`, which is what sent me looking at the view instead of the window: the
window was flush, the shape inside it was not. Fixed by putting no padding on the
container at all, `.ignoresSafeArea()`, and `hosting.safeAreaRegions = []`.

The lesson is the same one as [11-what-i-got-wrong.md](11-what-i-got-wrong.md):
the frame was right and the drawing was wrong, and checking only the frame said
everything was fine.

### The shape

Square top corners, and the first 32pt are exactly the housing's width so the
menu bar either side is never painted over. Below that it flares to full width
through two *concave* shoulders — control point on the corner being cut away —
and finishes with ordinary rounded bottom corners.

Pure black rather than the Liquid Glass every other panel uses. The housing is a
hole in the display and is always black; matching it is the only way to look like
part of it, and glass here reads unmistakably as a window parked near the notch.

Measured after the fix: waiting state at `x=665, y=0, 185×47` against a housing
at `x=665, width=185`. Flush, aligned, and the only visible part is a 15pt lip.

## Reusing the cut-and-move trick

That action is [`FinderCutMove`](../Sources/KlipKlik/Core/FinderCutMove.swift)
again: put the files on the pasteboard, send Finder ⌥⌘V, let Finder do both
halves. Conflict resolution, the progress sheet, and undo already exist and are
Apple's. Copying the files and unlinking the originals would mean reimplementing
all three, badly, and putting the user's data behind our error handling instead.

## The move problem on the way out

Dragging *out* is where this could quietly destroy data, and the honest answer
was to stop guessing.

A drag session advertising `[.copy, .move]` can end with `operation == .move`
meaning two different things: Finder already performed the move, or the
destination copied and expects the source to delete the original. Assume the
first and you leave duplicates. Assume the second and you delete the user's only
copy when the destination already moved it.

So the shelf asks the filesystem instead. After a `.move` it re-checks whether
each file still exists: gone means the move happened and the row goes; still
there means it did not and the row stays. Self-correcting, and it never deletes
anything itself.

## Encryption, and the one place it does not apply

Everything else KlipKlik writes is AES-GCM sealed. Shelves are split:

* **The index** — names, tints, window positions, referenced paths — is sealed
  like the pinned archive.
* **Staged bytes** are not, and cannot be. Dragging an item off a shelf hands
  another application a real `file://` URL. A sealed blob is not a file any other
  app can open, and decrypting to a temporary file at drag time puts the same
  plaintext on the same disk a moment later for no gain.

Two things follow. Anything dragged in from Finder is referenced by path and
never copied, so the staging case is the uncommon one — only content with no
file behind it (a browser image, a text selection, a promised file) is ever
written. And persistence is **off by default**, because "nothing outlives a
session" is a promise this one tier cannot keep.

## What I would check next

The probe proves the mechanism. What it does not exercise is the part needing a
hand on the mouse: whether a window ordered in mid-drag reliably becomes a valid
drop destination across every source application. AppKit re-hit-tests windows
throughout a drag and `orderFrontRegardless` covers the background-app case, but
individual applications with unusual drag implementations are worth a pass —
Photos, Mail, and Safari especially, since those are the promise-based sources.
