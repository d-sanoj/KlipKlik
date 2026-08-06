# KlipKlick

A lightweight status-bar clipboard manager for macOS. Keyboard-first, native, no fluff.

It lives in the menu bar only — no Dock icon, no ⌘Tab entry. Double-tap ⌘ and a
popup opens wherever your pointer is; type to search, ↩ to paste.

The menu bar item is a clock, showing the country's flag and the time in
whichever zone you pick, in 12-hour format. Clicking it opens a short menu —
**Clipboard**, **Settings**, **Timezone**, **Quit** — rather than the history
itself; the history is on double-tap ⌘, ⇧⌘C, or the Clipboard item.

The UI implements the `Clipboard Manager.dc.html` design: a 340pt popup, hover
actions, and a five-tab preferences window — rendered on macOS 26
Liquid Glass. The design's per-type chip glyphs are deliberately dropped: rows
are text-only, which keeps the list tight, and a hover card carries the detail
the glyphs used to.

## Liquid Glass

The popup surface is a four-layer stack, composed in this order:

1. **`NSVisualEffectView`** (`behindWindow`, `.hudWindow`) — a real gaussian blur
   of the backdrop. This is the layer that makes what's behind *illegible*.
2. **`NSGlassEffectView`** (macOS 26+, `.clear`) — Liquid Glass edge refraction
   and dispersion, applied over an already-blurred backdrop.
3. **Tint** — the opaque surface colour at the user's chosen opacity.
4. **Specular sheen** — a top-edge light falloff, so the panel catches light and
   lifts off whatever is behind it.

The order matters. Liquid Glass in its `.clear` style *tints but does not blur*,
so used alone it leaves text behind the popup perfectly readable. The blur has to
sit underneath it. There is no hairline border — the glass edge and the sheen
define the boundary.

**Preferences ▸ Appearance ▸ Popup background** is a slider from *Clear* to
*Solid*, defaulting to 30%. At 0% the popup is bare frosted glass — colour and
light still come through; at 100% it is a fully opaque panel.

Only layer 3 changes as the slider moves. The blur underneath is constant, so the
backdrop is illegible at **every** setting — the slider trades how much colour
bleeds through, never whether text behind can be read.

The Preferences window does not follow the slider; it uses the more substantial
`.regular` glass, because a dense settings form is unreadable on clear glass.

On macOS 25 and earlier this degrades to an `NSVisualEffectView` blur.

## Build

Requires the Xcode Command Line Tools (Xcode itself is not needed) and macOS 14+.

```bash
./Scripts/build_app.sh release
```

The result is `build/KlipKlick.app`. Drag it to `/Applications` and launch it.

To package a disk image instead:

```bash
./Scripts/make_dmg.sh
```

That produces `build/KlipKlick-<version>.dmg` with the app and an `Applications`
symlink to drag it onto.

## Permissions

| Feature | Needs Accessibility? |
| --- | --- |
| Clipboard capture, search, pinning, the popup UI | No |
| ⇧⌘C shortcut | No |
| **Double-tap ⌘ shortcut** | **Yes** |
| **Auto-paste after selecting** | **Yes** |
| **⌘X cut-and-move in Finder** | **Yes** |

macOS has no way to watch for a bare modifier key, drive another app's menus, or
synthesise keystrokes without Accessibility permission. Grant it in
**System Settings ▸ Privacy & Security ▸ Accessibility**. ⇧⌘C works immediately
and is there as a fallback.

### Granting it

**Preferences ▸ Shortcuts ▸ Accessibility permission** shows a live status dot
and two buttons:

* **Open Settings…** — jumps to the Accessibility pane.
* **Reset permission** — clears KlipKlick's entry and re-asks.

Use *Reset permission* whenever the status says "Not granted" but System Settings
shows KlipKlick already enabled. That combination means the row is stale, and
toggling it off and on will not fix it.

> **Why it goes stale:** there is no Developer ID certificate on this machine, so
> the app is ad-hoc signed. macOS ties the permission to the code signature, and
> an ad-hoc signature is derived from the binary's contents — so it changes on
> every rebuild and the old grant stops matching. Set `KLIPKLICK_SIGN_IDENTITY`
> to a real code-signing identity before running the build script to make the
> grant survive rebuilds.

> **Beware when testing:** a binary launched from a terminal that already has
> Accessibility **inherits that grant**, so it will work while the same app
> launched from Finder does nothing. Always verify with the app launched normally;
> `/tmp/klipklick-trust.txt` records which state the running instance is in.

## Shortcuts

| | |
| --- | --- |
| Double-tap ⌘ | Open / close the popup |
| ⇧⌘C | Same, without needing Accessibility |
| ↑ ↓ | Move through history |
| ↩ | Paste the selected item |
| ⌥⇧↩ | Invert "Strip formatting" for this one paste |
| ⌘1…⌘9 | Paste the *n*th item directly |
| ⌥P | Pin / unpin the selected item |
| ⌘⌫ | Delete the selected item |
| ⌥⌘⌫ | Clear history (keeps pinned) |
| ⌘, | Preferences |
| esc | Close |
| ⌘X | Cut files in Finder (see below) |

Hovering a row swaps its timestamp for a pin button; a pinned row shows its pin
all the time, so one click unpins it. Deleting is ⌘⌫ — there is no per-row
button for it. Nothing is selected when the popup opens: the first ↑ or ↓ (or
the pointer) picks a row, and ↩ pastes the top item either way.

Linger on a row and a small card appears beside the popup with the item's type,
the app it was copied from, and the time. It follows the arrow keys as well as
the pointer, so it works without a mouse.

Pinned items are not mixed into the list. **Pinned** on the right of the footer
swaps the list for the pinned shelf and back — plain text that lights up accent
on hover, the way **Clear** on the left turns red. The eyedropper between them
picks a colour off the screen, and the one beside it grabs text out of it.
Preferences are not in the footer: they are **Settings** in the menu bar menu,
or ⌘, with the popup open.

## Features

### Menu bar clock

The status item shows the country's flag and the current time in 12-hour
format, forced with a POSIX locale so it stays 12-hour on a Mac set to a
24-hour clock. **Timezone** in the menu lists every zone on the system — pick
one anywhere in the world and the clock follows it. The choice persists across
launches; an identifier that no longer exists falls back to the system zone
rather than breaking the clock.

The list is built from the zoneinfo tree, not `TimeZone.knownTimeZoneIdentifiers`
— 562 zones against 443. The API drops the tz database's *links*, which are the
names people actually look for: it lists India only as `Asia/Calcutta` with no
Kolkata, and omits `US/Eastern`, `Japan` and `Poland` entirely. The canonical
list is unioned in, so a change to the directory layout can never leave the
picker empty.

The `Etc` region is deliberately left out. Its 35 entries are fixed offsets with
no place attached, and their names run backwards by the POSIX convention —
`Etc/GMT+5` is UTC−5 — so the name contradicts the offset shown beside it.
Nothing is lost: the zero-offset members duplicate the plain `UTC` and `GMT`
under **Other**, and the numeric ones are whole hours only, so they could never
express a zone like India's UTC+5:30 anyway.

Flags come from the tz database's own `zone.tab`, which maps canonical zones to
ISO 3166 country codes; the code is then offset into the regional indicator
letters. `zone.tab` names only canonical zones, so an alias is matched by
content instead — an alias file is a byte-for-byte copy of the zone it points
at, which is how `Asia/Calcutta` resolves to 🇮🇳 and `US/Eastern` to 🇺🇸. Where
one rule set is shared across countries the borrowed code would be a guess, so
those get the 🌐 globe rather than a wrong flag, as do the placeless zones like
`UTC` and `GMT`. 526 of the 562 zones carry a flag.

Zones are grouped by region, and regions over 40 entries are split into
alphabetical runs that break on a change of initial letter — never mid-letter,
so there is no guessing whether *Kolkata* is under "D – K" or "K – S". Each
entry carries its current UTC offset, and the top of the menu names the zone in
force so the selection is readable without hunting for the checkmark.

The clock ticks every 5 seconds and only redraws when the displayed minute
actually changes.

### Pick a colour from the screen

The eyedropper in the footer opens the system loupe — the same magnifier the
colour well uses, so the pixel grid and escape-to-cancel come with it. Click a
pixel and its hex lands on the clipboard as `#RRGGBB`.

The popup hides first and comes back after. That is not cosmetic: the popup sits
under the pointer, so a loupe opened over it would sample the popup's own glass.
Reopening afterwards puts the new swatch at the top of history, which is the only
sign the pick worked.

The write is deliberately *not* registered as one of KlipKlick's own, so
`ClipboardMonitor` captures it and the colour joins history like any other copy.

Colours come back through sRGB, so a wide-gamut screen still yields the hex you
would paste into CSS: sampling a `#FF0000` div on a Display P3 screen gives
`#FF0000`, not the `#EA3323` the panel is physically driving.

### Grab text off the screen

The second footer icon dims the screen and lets you drag a box round anything
readable — a screenshot someone sent you, a video still, a window you cannot
select text in. What lands on the clipboard is the **text**, not the picture.
Escape, or a click without a drag, cancels.

Recognition is Vision's, with **language correction turned off**. It is tuned
for prose and rewrites anything that is not a dictionary word — identifiers,
flags, hex, punctuation runs — which is precisely what you grab a screen of code
for.

**Layout is reconstructed**, because Vision returns an unordered bag of text
fragments with bounding boxes: join the strings and you keep the words but lose
the shape. Instead a median character width is measured from the longer
fragments, and everything else is sized against it — indentation from each row's
distance to the leftmost fragment, inter-word gaps from the space between
boxes, blank lines from a row gap wider than the median line pitch. Fragments
are grouped into rows by vertical overlap rather than exact baseline, so a pixel
of jitter cannot stack two words. Grabbing an eight-line indented Swift function
returns it byte-for-byte, blank line included.

Two guards: a gap is capped at 60 spaces, so one far-right fragment in a wide
selection cannot emit a line of hundreds of them, and blank runs are capped at
three. The reconstruction is visual, so indentation always comes back as spaces
— tab-indented source returns space-indented.

This needs **Screen Recording**: reading text off the screen means reading its
pixels, and that is what the permission gates. Shelling out to
`/usr/sbin/screencapture` does not dodge it — TCC attributes the capture to the
app that spawned it — so the capture is ScreenCaptureKit, taken at the display's
real backing scale, which is what makes small text legible to the recogniser.
The permission is checked *before* the screen dims, so a missing grant does not
waste the gesture, and macOS's own prompt is left to speak for itself the first
time rather than being buried under an alert of ours.

> Screen Recording goes stale on every rebuild for the same reason Accessibility
> does — see the ad-hoc signing note above — and only takes effect on a fresh
> launch.

### Launch at login

**Preferences ▸ General ▸ Launch at login** registers the app with
`SMAppService.mainApp` — the app registers itself, macOS owns the record, and it
shows up in **System Settings ▸ General ▸ Login Items** like any other.

macOS is the source of truth, not a preference of ours. A stored copy would
drift the moment someone revoked the item in System Settings, so the switch
reads its state back from `SMAppService.status` — on launch, when the window
appears, and every time it is reopened. If registration fails the switch returns
to where it was, because it reports the system's state and the system just
refused to change it, and the reason is shown underneath.

macOS may accept a registration but hold it pending approval. That shows as
*Waiting for your approval in System Settings*, with a button that jumps
straight to Login Items.

> Ad-hoc signing bites here too: the login item records the bundle it was
> registered from, so rebuilding leaves a stale entry pointing at the old
> binary. Toggle it off before a rebuild, or re-register afterwards.

### Ignored apps

**Preferences ▸ Ignored Apps** holds a list of apps whose copies never reach
history. Add them with a file picker; each row shows the app's real icon and
name, and an × removes it.

Apps are stored by **bundle identifier**, not by name or path, so renaming an
app or keeping a second copy in another folder cannot quietly stop the rule
matching. An entry whose app is no longer installed keeps working and shows the
identifier marked *Not installed*, rather than vanishing from the list.

This is separate from, and on top of, the automatic skip: anything marking the
pasteboard as concealed — which most password managers do — is dropped whether
or not it is listed. The list is for everything else, like terminals and note
apps.

The check has one wrinkle worth knowing. Because detection is polled, the
frontmost app is read up to 0.4s after the ⌘C, so someone who copies and
immediately switches away would have the copy attributed to the app they
switched *to*. The ignore check therefore looks at the previous tick as well,
and drops the item if **either** app is on the list. A fast switch loses a
clipboard entry, which is the right way to be wrong about a password manager.

### Strip formatting when pasting

A toggle in **Preferences ▸ General**. When on, text pastes as plain text — the
equivalent of ⌘⇧V.

This is applied when **pasting**, not when copying. History always stores every
original flavour the source app provided (RTF, HTML, plain text), so turning the
toggle back off restores full formatting on items already captured. Hold ⌥⇧ while
choosing an item to invert the setting for that one paste, in either direction.
Images and files have no plain-text flavour and are always restored in full.

### ⌘X cut-and-move in Finder

Windows-style file cutting. macOS deliberately has no ⌘X for files — you copy
with ⌘C and then move with ⌥⌘V ("Move Item Here"). This bridges the two:

* ⌘X in Finder synthesises ⌘C, so **Finder itself** puts the selection on the
  pasteboard, and arms cut mode.
* ⌘V while armed is consumed and replaced with ⌥⌘V, so **Finder** performs the
  move — keeping its own conflict handling, progress UI, and undo.

Both keys are **Carbon hot keys**, which consume the keystroke. That is essential
for ⌘X: Finder has no Cut command for files, so a ⌘X that reaches Finder makes it
play the "not allowed" alert sound. Merely observing the key with an
`NSEvent` monitor is not enough — the key has to be swallowed before Finder sees
it. Both keys are held only while Finder is frontmost, so neither is affected in
any other app, and ⌘V is additionally only held while a cut is actually pending.

⌘X during an inline rename or in the search field is still a normal text cut: the
hot key is released, the keystroke re-posted so Finder handles it, and the key
taken back afterwards.

Copying something else cancels a pending move. If the selection isn't files, cut
mode does not arm at all, rather than arming a ⌘V interception that would do
nothing.

While a cut is pending a **scissors** glyph appears next to the menu-bar clock.
Finder gives
no indication of its own — the file does not dim the way Windows Explorer dims a
cut file — so without this the feature is invisible and reads as broken even when
it armed correctly.

Two things to know:

* Paste into a **different** folder. ⌥⌘V into the folder the files already live
  in is a no-op, so nothing appears to happen.
* Press plain **⌘V**, not ⌥⌘V. KlipKlick turns your ⌘V into the move.

## History

History is **memory only** — it is never written to disk. It is lost when
KlipKlick quits or the Mac restarts, and it is force-cleared daily at 5:00 AM.

The daily clear is not a plain timer: timers don't fire while the machine is
asleep, so a Mac closed overnight would sail straight past 5 AM. Instead, every
check recomputes the most recent 5 AM boundary that has passed and clears if that
boundary hasn't been handled yet. Waking from sleep and opening the popup both
trigger a check, so a laptop opened at 9 AM clears on wake.

The daily clear removes **everything, including pinned items** — it is a
force-clear. The footer's "Clear" keeps pinned items; Storage ▸ "Clear
All History" does not.

Content marked with the [nspasteboard.org](http://nspasteboard.org) concealed or
transient types — what password managers use — is ignored and never recorded.

## Item types

Each row carries a chip for what it holds, following the design:

| Chip | Meaning |
| --- | --- |
| serif **T** | Plain text |
| italic **Aa** | Rich text (RTF/HTML) |
| two rings | Links — shown with the scheme stripped |
| colour swatch | Hex colours such as `#0A84FF` |
| camera | Images and video |
| music note | Audio |
| document | Everything else (PDF, DOC, archives…) |

Entries keep every flavour the source app put on the pasteboard, so pasting
restores the original rather than a text-only approximation.

## Project layout

```
Sources/KlipKlick/
  main.swift              NSApplication entry point (.accessory policy)
  AppDelegate.swift       Wiring: status item, triggers, lifecycle
  Models/
    ClipboardItem.swift   Capture, classification, and restore
  Core/
    ClipboardMonitor.swift      changeCount polling
    HistoryStore.swift          In-memory ring buffer, pinning
    DailyPurge.swift            Sleep-aware 5 AM clear
    DoubleTapCommandMonitor.swift
    CarbonHotKey.swift          Permission-free hot keys
    FinderCutMove.swift         ⌘X cut-and-move
    ColorSampler.swift          Screen colour pick -> hex
    RegionSelector.swift        Dimming drag-to-select overlay
    TextGrab.swift              Region capture, OCR, layout rebuild
    TimeZoneFlags.swift         Zone -> country flag, via zone.tab
    Paster.swift                Synthesised keystrokes + permission helpers
    Settings.swift              UserDefaults-backed preferences
  UI/
    PopupController.swift  The NSPanel, positioning, key handling
    PopupView.swift        Popup layout
    ItemRow.swift          Row, hover actions, focus reporting
    HoverDetailCard.swift  Type/app/time card, in its own child window
    PopupViewModel.swift   Filtering, selection, actions
    PreferencesView.swift  Five-tab preferences window
    Theme.swift            Design tokens, metrics, vibrancy backing
```

## Status

Everything in Preferences is wired up. Nothing is a mockup any more.

### Known characteristics

Pasteboard change detection is polled every 0.4s, so two copies inside the same
window can coalesce and only the later one is recorded. This is inherent to
`NSPasteboard` — there is no change notification — and human copying is far
slower than the poll.

### Development

`KLIPKLICK_DEBUG=1` logs each capture to stderr. A running instance also responds
to three distributed notifications, which is how the UI is driven in testing
without synthesising keystrokes (which would itself need Accessibility):

```
com.sanoj.KlipKlick.show
com.sanoj.KlipKlick.preferences
com.sanoj.KlipKlick.pinNewest
```
