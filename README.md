# KlipKlick

A lightweight status-bar clipboard manager for macOS. Keyboard-first, native, no fluff.

It lives in the menu bar only — no Dock icon, no ⌘Tab entry. Double-tap ⌘ and a
popup opens wherever your pointer is; type to search, ↩ to paste.

The menu bar item is a clock, showing the time in whichever zone you pick, in
12-hour format. Clicking it opens a short menu — **Clipboard**, **Settings**,
**Timezone**, **Quit** — rather than the history itself; the history is on
double-tap ⌘, ⇧⌘C, or the Clipboard item.

The UI implements the `Clipboard Manager.dc.html` Claude Design project: a 340pt
popup, hover actions, and a five-tab preferences window — rendered on macOS 26
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

Pinned items are not mixed into the list. The footer's **Pinned** button swaps
the list for the pinned shelf and back.

## Features

### Menu bar clock

The status item shows the current time in 12-hour format, forced with a POSIX
locale so it stays 12-hour on a Mac set to a 24-hour clock. **Timezone** in the
menu lists every zone on the system — pick one anywhere in the world and the
clock follows it. The choice persists across launches; an identifier that no
longer exists falls back to the system zone rather than breaking the clock.

The list is built from the zoneinfo tree, not `TimeZone.knownTimeZoneIdentifiers`
— 597 zones against 443. The API drops the tz database's *links*, which are the
names people actually look for: it lists India only as `Asia/Calcutta` with no
Kolkata, and omits `US/Eastern` and the explicit `Etc/GMT±N` offsets entirely.
The canonical list is unioned in, so a change to the directory layout can never
leave the picker empty.

Zones are grouped by region, and regions over 40 entries are split into
alphabetical runs that break on a change of initial letter — never mid-letter,
so there is no guessing whether *Kolkata* is under "D – K" or "K – S". Each
entry carries its current UTC offset, and the top of the menu names the zone in
force so the selection is readable without hunting for the checkmark.

The clock ticks every 5 seconds and only redraws when the displayed minute
actually changes.

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
force-clear. The footer's "Clear History" keeps pinned items; Storage ▸ "Clear
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

Wired up: strip formatting, auto-paste, Finder cut-and-move, theme, popup size,
popup anchor, history size, pinning, search, the daily purge.

Still mockups: **Launch at login** (needs `SMAppService` registration) and the
**Ignored Apps** list (password managers that mark the pasteboard as concealed
are already ignored automatically).

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
