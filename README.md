<div align="center">

<img src="Resources/AppIcon.png" width="120" alt="KlipKlik" />

# KlipKlik

**A fast, keyboard-first clipboard manager that lives in the macOS menu bar.**

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)](#install)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)

</div>

---

No Dock icon, no ⌘Tab entry. Double-tap ⌘ and a popup opens wherever your
pointer is — type to search, ↩ to paste.

## Features

- **Clipboard history** — text, rich text, links, colours, images, and files, with search and pinning.
- **Keyboard-first** — double-tap ⌘ to open, arrows to move, ↩ to paste, ⌘ 1…9 to grab the *n*th item.
- **Drag shelves** — pick up any file and the notch opens into a Copy / Move tray; park files there, select them like Finder, then drag them back out.
- **Strip formatting** — paste as plain text, with a one-off override while choosing.
- **Colour picker** — sample any pixel on screen, get `#RRGGBB` on the clipboard.
- **Screen text grab** — drag a box over anything readable and copy the *text*, indentation and blank lines intact.
- **⌘ X in Finder** — Windows-style cut and move for files.
- **Plinth command bar** — a bar docked under Finder: type “convert to 1080p mp4” or “rename to trip-{n}” and it acts on the selection, after showing you what it will do. [More below](#plinth-command-bar).
- **Menu bar clock** — the time in any zone in the world, with its country's flag.
- **Ignored apps** — per-app opt-out; password managers are skipped automatically.
- **Pinned items persist** — kept encrypted on disk until you clear them; everything else is wiped on quit.
- **Light on memory** — items move to encrypted files five minutes after being copied, so a day of screenshots doesn't sit in RAM.

## Install

### Download

Grab the `.dmg` from the [latest release](https://github.com/d-sanoj/KlipKlik/releases/latest),
open it, and drag KlipKlik to Applications.

KlipKlik is ad-hoc signed rather than notarised, so macOS quarantines it on
download and refuses to launch it — usually claiming the app *"is damaged and
can't be opened"*. It is not damaged; that is Gatekeeper reacting to the absent
Developer ID. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/KlipKlik.app
```

Then open it normally. It appears in the menu bar, not the Dock — a welcome
window on first launch says so, and offers the two permissions up front.

### Build from source

Requires macOS 14+ and the Xcode Command Line Tools — Xcode itself is not needed.

```bash
git clone https://github.com/d-sanoj/KlipKlik.git
cd KlipKlik
./Scripts/build_app.sh release
```

The result is `build/KlipKlik.app`. A locally built app is not quarantined, so
it launches without the `xattr` step.

### Uninstall

**Settings ▸ History & Data ▸ Uninstall KlipKlik…** revokes both permissions, removes
the login item, and deletes every stored setting, then offers to move the app to
the Trash. Dragging the app to the Trash on its own leaves the privacy grants
behind, and macOS matches those by bundle identifier — so a later reinstall
inherits them.

### Tinkering

| | |
| --- | --- |
| `./Scripts/build_app.sh` | Debug build, faster to compile |
| `./Scripts/make_dmg.sh` | Package a disk image |
| `./Scripts/make_icon.sh` | Rebuild the icon after editing `Resources/AppIcon.png` |
| `./Scripts/make_signing_cert.sh` | Once per Mac: a local signing certificate, so permissions survive rebuilds |
| `./Scripts/test.sh` | Run the unit tests |
| `KLIPKLIK_ICON_RADIUS=0.12` | Tighter icon corners (default `0.18`) |
| `KLIPKLIK_SIGN_IDENTITY="…"` | Sign with a real identity so permissions survive rebuilds |
| `KLIPKLIK_DEBUG=1` | Log every clipboard capture to stderr |

Ad-hoc signatures change on every rebuild, and macOS ties Accessibility and
Screen Recording to the signature — so those grants lapse each time you build
unless you set a signing identity.

## Drag shelves

Start dragging any file and the camera notch itself expands into a black tray,
split **Copy** on the left and **Move** on the right. Let go and it becomes a
shelf — a floating window that stays above everything and follows you across
spaces. Fill it from anywhere — Finder, a web page, Mail — then drag the
contents back out where you actually want them.

The target is the notch every time, not wherever the pointer happened to be. A
fixed target can be learned, and it sits against the top of the screen, so
you can throw the pointer at it rather than aim. On a Mac with no notch — an
external display, a Mac mini — the same tray appears in the same place, centred
under the menu bar.

**Copy** (left) parks a reference. The original stays on disk, always. Shelving
a 4 GB video costs a string and no extra bytes.

**Move** (right) also parks a reference — Finder is not asked to delete
anything on the way in. The cut completes only when you drag that file *out* of
the Move shelf. Closing the shelf, emptying it, or clicking × leaves the
original where it was.

Only content with no file behind it — an image dragged out of a browser, a text
selection, a promised file from Photos or Mail — is written to disk, because
there is nothing else to point at. A dragged link becomes a `.webloc`, as it
would on the Desktop.

The shelf sizes itself to the files: one row for 1–4, two for 5–8, three for
9 or more, then it scrolls. Hovering shows the action buttons without resizing
the window. Removing the last file closes the shelf.

| | |
| --- | --- |
| Drop on Copy (left half) | New Copy shelf, opening out of the notch |
| Drop on Move (right half) | New Move shelf; originals stay until dragged out |
| `⌥ ⌘ S` | New empty Copy shelf |
| Click a file | Select it |
| ⌘-click / Shift-click | Toggle / range, as in Finder |
| Drag across files or empty space | Paint-select / rubber-band |
| Click empty space, or `esc` | Deselect |
| `⌘ A` | Select all files on that shelf |
| Drag selected files out | They leave together |
| Click × on a file | Remove it from the shelf (does not trash the original) |
| Double-click | Open |
| Right-click | Open With, Reveal, Copy, Copy Path, Remove |
| Double-click the title | Rename |
| Hover the shelf | Actions fade in — move to the front Finder window, copy, Quick Look, reveal, zip, share |

**Move to the front Finder window** is the ⌘X trick from cut-and-move: the files
go on the pasteboard and Finder is sent ⌥⌘V, so Finder's own conflict handling,
progress sheet, and undo do the work. It is the one part of the shelf that needs
Accessibility. Everything else — including the drop target appearing on a drag —
needs no permission at all.

Shelves are **not** kept after quitting unless you turn that on in
**Settings ▸ Shelf**. The reason is in the next section.

## Storage and privacy

Clipboard content is held in memory for five minutes after being copied, then
written to an **AES-GCM encrypted** file and dropped from RAM — an image can be
several megabytes, and holding every one resident is what this avoids. Metadata
stays in memory, so the list still renders and searches without touching disk.

Two tiers, with deliberately different lifetimes:

| | Where | Lifetime |
| --- | --- | --- |
| **Pinned** | `Application Support/KlipKlik` | Until you clear them — survives quit and reboot |
| **Everything else** | `Caches/KlipKlik` | Deleted on quit and at the daily purge |

The key is a `0600` file, deliberately not the Keychain: the Keychain gates
access on the code signature, and an ad-hoc signature changes with every build,
so macOS would fall back to asking for your login password — once per access.
Both directories are excluded from Time Machine and Spotlight, and uninstalling
shreds the key, which makes anything missed permanently unreadable.

Honestly scoped: this makes the blobs useless in a backup, in a copied folder,
or to anything grepping the disk for readable text. It does not protect against
a process already running as your user, which can read the key as easily as the
app can. Only a signed build with a real Keychain entitlement would.

Shelves are the one exception to the encryption rule, and it is worth being
plain about why. A shelf's *structure* — names, tints, positions, and the paths
of referenced files — is sealed like everything else. Its **staged bytes are
not**: dragging an item off a shelf hands another application a real `file://`
URL, and a sealed blob is not a file any other app can open. Decrypting to a
temporary file at drag time would put the same plaintext on the same disk a
moment later and buy nothing.

So staged content is as private as the folder it sits in, which is why shelves
do not survive quitting by default, and why anything dragged in from Finder is
referenced rather than copied — the case that would stage bytes is the
uncommon one.

**Settings ▸ History & Data** shows all four figures — memory, cache, archive, and
bytes staged for shelves — and clears each independently.

## Plinth command bar

A bar that sits under the front Finder window and does things to the selected
files when you say what: *convert to 1080p mp4*, *half size*, *zip as Photos*,
*replace IMG_ with Rome*, *combine into one pdf*.

- **⌥ ⌘ K** in Finder puts the cursor in the bar; **esc** gives the keyboard back.
- **Zip, JPG, PNG, PDF** are one-tap chips that run without any AI.
- Everything else goes to Apple's **on-device model** (Foundation Models,
  macOS 26, Apple Intelligence on). Nothing leaves the Mac.
- Before anything runs you see what will be **created, renamed or moved to the
  Trash**, and the exact commands. Renames and trashing originals need a
  second yes (**⌘ ↩**). Nothing is ever overwritten.
- Video needs **ffmpeg**. If it's missing, Plinth offers to run
  `brew install ffmpeg` and shows you that command first. It never installs
  Homebrew itself.

**Settings ▸ Plinth Command Bar** turns it on or off, chooses between "under
every Finder window" and "only after ⌥⌘K", and shows whether Apple
Intelligence, ffmpeg and Finder access are ready.

### What it can do (v0.1)

| Ask for | Runs |
| --- | --- |
| Convert video to MP4, MOV, WebM, MKV, GIF; audio to MP3, M4A, WAV; at 480p…4K | `ffmpeg` |
| Compress video (HEVC), optionally to a height | `ffmpeg` |
| Convert pictures to JPEG, PNG, HEIC, TIFF, GIF, BMP, PDF | `sips` |
| Resize by percent, longest side, width or height; compress pictures | `sips` |
| Zip, unzip | `zip`, `ditto` |
| Rename: `{name}`, `{n}`, `{date}`, find and replace, prefix, suffix, case | Foundation |
| Merge PDFs in Finder's order | PDFKit |

### How it stays safe

The model never writes a command. It fills in a typed `@Generable` struct —
an action from a fixed list plus a few optional fields — and
`PlinthIntentValidator` checks every field again (known formats only, numbers
in range, file names that are file names). `PlinthCommandBuilder` then builds
each program's argument list itself; programs are started directly by path,
never through a shell, so no file name or request can become a command.

If Apple Intelligence is off, not supported or still downloading, the bar
says so and the instant chips keep working. Other back ends (Ollama, an API)
can slot in behind `PlinthInterpreter` later.

### Status

v0.1, on the `claude/plinth-command-bar-626mko` branch. The command builders,
validator, renamer and placement are unit tested; the Finder tracking, the
panel and the Foundation Models calls need a run on a Mac with macOS 26.

### Tests and the prompt eval

```
./Scripts/test.sh                                        # unit tests, any Mac
PLINTH_EVAL=1 swift test --filter PlinthLiveEval         # 56 requests against the real model
```

The eval (`Tests/KlipKlikTests/Plinth/PlinthEvalCases.swift`) is a list of
requests, selections and the commands that count as right, refusals
included. Without `PLINTH_EVAL=1` it still checks that every expected answer
is one the builder can carry out.

### Distribution

Plinth is why KlipKlik stays outside the Mac App Store: it asks Finder for
its selection over Apple Events and starts `ffmpeg`, `sips`, `zip` and
`ditto`, none of which a sandboxed app may do for arbitrary files. The app is
not sandboxed; it is signed with the hardened runtime and the one Apple
Events entitlement it already had.

To ship it to other Macs, sign with a **Developer ID Application**
certificate and notarize:

```
KLIPKLIK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build_app.sh
ditto -c -k --keepParent build/KlipKlik.app KlipKlik.zip
xcrun notarytool submit KlipKlik.zip --keychain-profile notary --wait
xcrun stapler staple build/KlipKlik.app
```

Notarization also wants a secure timestamp: add `--timestamp` to the
`codesign` flags in `build_app.sh` for release builds. Store the notary
credentials once with `xcrun notarytool store-credentials notary`.

## Shortcuts

| | |
| --- | --- |
| `⌘ ⌘` | Open / close the popup |
| `⇧ ⌘ C` | Same, without needing Accessibility |
| `↑` `↓` | Move through history |
| `↩` | Paste the selected item |
| `⌥ ⇧ ↩` | Invert "Strip Format" for one paste |
| `⌘ 1…9` | Paste the *n*th item |
| `⌥ P` | Pin / unpin |
| `⌥ S` | Put the selected item's files on a shelf |
| `⌥ ⌘ S` | New shelf |
| `⌥ ⌘ K` | In Finder: the Plinth command bar |
| `⌘ A` | Select all files on the focused shelf |
| `⌘ ⌫` | Delete item |
| `⌥ ⌘ ⌫` | Clear history (keeps pinned) |
| `⌘ ,` | Settings |
| `esc` | Close popup, or deselect on a shelf |

## Permissions

| Feature | Needs |
| --- | --- |
| History, search, pinning, the popup | — |
| `⇧ ⌘ C` | — |
| Double-tap ⌘, auto-paste, ⌘ X cut-and-move | Accessibility |
| Shelf "Move to Front Finder Window" | Accessibility |
| Shelves, the drop target, drag in and out | — |
| Screen text grab | Screen Recording |
| Plinth command bar | Automation for Finder (asked once); Accessibility only makes it follow windows faster |

Grant them in **System Settings ▸ Privacy & Security**.

**Settings ▸ Shortcuts** shows both permissions with a live status dot, and gives
each one its own **Open Settings…** and **Reset permission** button.

> **Note**
> Without a Developer ID certificate the app is ad-hoc signed, and macOS ties
> permissions to the code signature — which changes on every rebuild, silently
> invalidating the grant. The entry in System Settings still looks enabled but
> no longer matches, and toggling it off and on will not fix it; only a reset
> will. Run `./Scripts/make_signing_cert.sh` once to create a local signing
> certificate — `build_app.sh` then signs every build with it, so grants
> survive rebuilds — or set `KLIPKLIK_SIGN_IDENTITY` to a real signing
> identity. Screen Recording additionally needs a relaunch to take effect.
>
> Every build is signed with the hardened runtime and
> `Resources/KlipKlik.entitlements`, as notarization requires. The one
> entitlement lets KlipKlik send Apple Events to Finder.

## Development

```
Sources/KlipKlik/
  AppDelegate.swift    Menu bar item, clock, status menu
  Core/                Clipboard monitor, history, capture tools, settings
  Plinth/              The Finder command bar: Core (actions, validation, builders), AI, Run, Finder, UI
  Core/Shelf/          Drag detection, shelf model, storage, file actions
  UI/                  Popup, preferences, theme
  UI/Shelf/            Shelf windows, drop target, tiles, drag source
  Models/              Clipboard item capture and classification
Scripts/
  build_app.sh         Compile and assemble the .app
  make_icon.sh         Resources/AppIcon.png -> AppIcon.icns
```

Built with SwiftPM and SwiftUI over a non-activating `NSPanel`, rendered on
macOS 26 Liquid Glass with a graceful fallback to `NSVisualEffectView`.

Contributions welcome — open an issue or a pull request.

## License

[MIT](LICENSE) © Sanoj Doddapaneni
