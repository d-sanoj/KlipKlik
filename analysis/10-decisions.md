# 10 — Decision log

Each entry: what was chosen, what it ruled out, and whether it held up.

---

## D1 · Double-tap `⌘` as the primary shortcut

**Options:** `⌥V`, `⌥C`, `⇧⌘C`, `⌃⌘V`, double-tap `⌘`.

**Chosen:** double-tap `⌘`, with `⇧⌘C` kept as a second trigger.

**Cost:** a bare modifier cannot be a system hot key. It needs a global keyboard
monitor, which macOS gates behind Accessibility. That single choice made
Accessibility a hard dependency, which made ad-hoc signing a real problem, which
produced the longest debugging detour in the project.

`⇧⌘C` was kept precisely because Carbon hot keys need no permission, so the app
is never completely dead while permissions are missing.

**Held up.** The detection logic rejects everything that merely *involves* `⌘` —
`⌘C`, `⌘Tab`, `⌘` held while reaching for another key, `⇧⌘` combos. A tap only
counts when `⌘` went down and back up alone, inside 400 ms.

---

## D2 · History in memory only

**Chosen:** nothing written to disk, cleared at quit and forced at 5 AM daily.

**Cost:** no history across restarts. Stated in the UI rather than hidden.

**Consequence:** `DiskStore` exists anyway, for offloading large items so RAM does
not balloon, destroyed at session end. Pinned items are the deliberate exception.

**Related failure:** `SecretBox` originally kept its key in the Keychain. The
Keychain gates on the code signature, so with ad-hoc signing macOS fell back to
asking for the login password every few minutes. An app that repeatedly asks for
your password trains you to type it into anything that asks. Moved to a `0600`
file.

---

## D3 · The 5 AM purge is not a timer

**Chosen:** recompute the most recent boundary on every check, rather than
scheduling a fire.

**Why:** timers do not fire while the machine sleeps. A laptop closed overnight
sails past 5 AM and nothing happens.

**Held up.** Wake notification, a 5-minute sweep, and opening the popup all
trigger the same idempotent check.

---

## D4 · Every pasteboard flavour is stored

**Chosen:** keep RTF, HTML, plain text, file URLs, TIFF — all of it.

**Consequence:** strip-formatting becomes a choice at *paste* time rather than a
lossy decision at capture time. Turning the setting off restores full formatting
on items already in history.

**Refinement:** the setting is an XOR with the `⌥⇧` modifier, so there is a
one-off override in whichever direction is needed:

```swift
let stripFormatting = Settings.shared.stripFormatting != invertFormatting
```

---

## D5 · Auto-quit uses polling with two safeguards

**Chosen:** poll each regular app's Accessibility window list about once a second.

**Rejected:** `AXObserver` per app. More correct in principle, much more plumbing,
and the polling cost is a counter read.

**Safeguards, because this quits other people's apps:**

1. A failed or timed-out AX read reports *unknown*, never zero. An app that cannot
   be inspected is never mistaken for one with no windows.
2. An app is only quit after **two consecutive** zero readings, and only if it was
   previously seen *with* windows. That rules out transient zeroes while a
   document is swapped, and apps that were already windowless.

Finder, Dock, Control Center, Notification Center, KlipKlick itself and all
menu-bar-only apps are exempt. Quitting is graceful, so apps still prompt about
unsaved work.

---

## D6 · `⌘X` cut-and-move drives Finder rather than moving files

**Chosen:** `⌘X` synthesises `⌘C` so Finder puts the selection on the pasteboard;
`⌘V` is intercepted and replaced with `⌥⌘V` so Finder performs the move.

**Rejected:** moving files with `FileManager`. Letting Finder do both halves means
its conflict handling, progress UI and undo all still work, and it needs no
Automation permission.

**Correction made later:** the keys were originally observed with an `NSEvent`
monitor, which cannot consume events. Finder has no Cut for files, so the
unconsumed `⌘X` reached Finder and it played the "not allowed" alert sound. Both
keys became Carbon hot keys, which swallow the keystroke. Both are held only
while Finder is frontmost.

**Handled:** `⌘X` during an inline rename is still a text cut — the hot key is
released, the keystroke re-posted, and the key taken back afterwards.

---

## D7 · Liquid Glass over a real blur

**Chosen:** four layers — `NSVisualEffectView` blur, then `NSGlassEffectView`
`.clear`, then the user's tint, then a specular sheen.

**Rejected:** `.clear` glass alone (backdrop stays readable) and `.regular` glass
alone (effectively opaque).

**Why the order matters:** `.clear` Liquid Glass tints but does not blur. Put it
over sharp content and it refracts sharp content. The blur has to sit underneath.

**Slider design:** one glass style across the whole range, with only the tint
changing. Switching styles partway would make the control jump instead of sweep.

---

## D8 · Preferences does not follow the opacity slider

**Chosen:** Preferences uses `.regular` glass, fixed.

**Why:** a dense settings form on clear glass is unreadable, and if the slider
controlled it, dragging toward Clear would make the very slider you are using
illegible.

---

## D9 · Permissions get a window, not the system alert

**Chosen:** KlipKlick's own window with live status, one Allow button per
permission, Reset, and Restart.

**Why:** the bare `AXIsProcessTrustedWithOptions` alert has no icon, no account of
what it unlocks, and no way back once dismissed.

**Honest limit stated in the UI:** Accessibility cannot be granted by an app.
There is no API, by design. Allow registers the app and opens the pane; the
window says so rather than letting the button imply more than it does.

---

## D10 · Restart keys off intent, not observation

**Chosen:** offer the restart when the user has *asked* for a grant, not when a
change is detected.

**Why:** `CGPreflightScreenCaptureAccess()` caches its answer for the life of the
process. Waiting for the observed flip meant the button never appeared for the
one permission that most needs a restart.

---

## D11 · Abandoned the self-signed certificate

**Tried:** self-signed code-signing certificate so the Accessibility grant would
survive rebuilds.

**Result:** `errSecInternalComponent` from `codesign`, persisting after
`set-key-partition-list`. Abandoned, and the certificate removed from the
keychain.

**Instead:** a Reset permission button, since the churn could not be eliminated.

---

## D12 · Kept Vision, did not swap OCR engine

**Rejected:** PaddleOCR, Tesseract, RapidOCR.

**Why:**

- They do not know `⌘` either. It is not in anyone's training corpus.
- Character accuracy on code is already ~100%, so there is no gap to close.
- Indentation is geometry over bounding boxes, not an OCR feature.
- ~50 MB added to a 2.6 MB app.

**Not measured.** This is reasoning from what the models are trained on, not a
head-to-head benchmark. Running one would have meant installing PaddleOCR.

---

## D13 · Fix symbols with shape matching, not the on-device LLM

**Options:** template matching, or Apple's Foundation Models reading `Press HC to
copy` and restoring `⌘C` from context.

**Chosen:** shape matching.

**Why:** for shortcut glyphs you want a definite answer. An LLM "fixing" `H` to
`⌘` in a document that genuinely said `H` is worse than the original bug. Shape
matching also works with Apple Intelligence switched off — which it is on this
machine.

**Where the LLM is still the better tool:** structural cleanup that pixel matching
cannot do — hyphenation, broken line wrapping, a screenshot of a table into a real
table.

---

## D14 · Measure each idea separately

Not a product decision, but it changed the outcome.

Aspect-ratio scoring and a wider font bank both sounded reasonable and both
measured as **zero improvement**. Bundling them with the changes that did work
would have credited the wrong thing.

The measurement that actually solved it came from slicing the same data by font
instead of by symbol. Per-symbol numbers said "`⇧` and `⌥` are weak" and sent me
tuning shapes. Per-font numbers said system text was already at 100% and every
loss was monospaced. Different problem, and invisible on the first axis.
