# 06 — What Vision can and cannot read

## Where this started

Screen text grab was returning `H` where the screenshot said `⌘`.

```
Press ⌘C to copy   →   Press HC to copy
```

The obvious first move is to check the recogniser's settings. Both of the
settings that would have helped were already correct:

```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
```

Language correction being off matters. It is tuned for prose and rewrites
anything that is not a word, which is exactly what you grab a screen of code for.
Leaving it on would make symbol garbling worse, not better.

So the easy answers were gone before I started.

## Test 1 — is it a configuration problem?

Rendered a sample and ran it through every configuration Vision offers.

```
supported revisions: [1, 2, 3]

[correction OFF (current)]
    Press HC to copy
    T&V pastes plain text
    ^HQlocks • 4H3 shot

[correction ON]
    Press HC to copy
    I &V pastes plain text
    ^HQ locks - 4H3 shot

[newest revision 3, correction OFF]
    Press HC to copy
    T&V pastes plain text
    ^HQlocks • 4H3 shot
```

All three revisions identical. Correction on is slightly worse.

Then macOS 26's new Vision Swift API, in case it uses a newer model:

```
[new Vision Swift API — RecognizeTextRequest]
    Press HC to copy
    T&V pastes plain text
    ^HQlocks • 4H3 shot
```

**Byte-identical.** Same model underneath. Not a configuration problem, not an
API-version problem.

## Test 2 — how wide is the damage?

I had been assuming this was a handful of Apple glyphs. I tested thirteen
character classes to find out.

| Class | Input | Output | |
| --- | --- | --- | --- |
| Mac modifiers | `⌘ ⌥ ⇧ ⌃` | *(nothing)* | fail |
| Mac keys | `⏎ ⌫ ⇥ ⎋ ⇪` | *(nothing)* | fail |
| Arrows | `← → ↑ ↓` | `< →PV` | fail |
| **Accented** | `café niño über çà åö` | `café niño über çà åö` | **pass** |
| Greek | `α β γ δ λ π Ω` | `авублПЯ` | fail |
| Math | `± × ÷ ≈ ≠ ≤ ≥ ∞ √ ∑` | `1×÷=‡≤≥∞/{` | fail |
| Currency | `€ £ ¥ ₹ ¢ $` | `$Ф₴*}·` | fail |
| Typography | `© ® ™ § ¶ † • … – —` | `...--` | fail |
| Smart quotes | `"quoted" and 'single'` | `"quoted" and 'single'` | fail (straightened) |
| Code punctuation | `~ \` ^ \| \ _ { } [ ] < > /` | `~'^11_{1]<1` | fail |
| Box drawing | `┌─┬─┐ │ ├─┼─┤ └─┴─┘` | `PHHL` | fail |
| Emoji | `✅ ⚠️ 🚀 ❌` | `X` | fail |
| Mixed shortcut | `Press ⌘⇧P then Enter` | `Press 86&P then Enter` | fail |

Only accented Latin survived. That looked catastrophic, and I had already told
the user it was "only eight Apple symbols". Wrong.

## Test 3 — but these were isolated symbols

Every failing case above was a row of symbols with no words around them. Vision
reads *words*. Isolated glyphs are its worst case, and an earlier test of realistic
code had scored 100%.

So I ran the same characters in context against the same characters alone:

| | Result |
| --- | --- |
| `Total: €45.99 and £12.50 paid` | **pass** |
| `€ £ ¥` | fail → `€ f ·` |
| `where x ≤ 10 and y ≠ 0 gives ±3` | `≤` correct, `≠`→`#`, `±`→`=` |
| `≤ ≠ ±` | *(nothing)* |
| `{"id": 42, "tags": ["a","b"], "ok": true}` | correct, only spacing differs |
| `drwxr-xr-x  3 sanoj staff  96 Aug 11 14:33 build/` | correct, only spacing differs |
| `Press ⌘⇧P then Enter` | fail → `Press HaP then Enter` |

**Context decides.** `≤` read correctly inside a sentence and produced nothing on
its own. Currency was perfect in `Total: €45.99` and wrong as `€ £ ¥`.

That reconciles the two results, and it also means the practical damage is much
narrower than Test 2 suggested. For real screenshots — code, terminal output,
documents — Vision is close to perfect. What genuinely breaks is Mac keyboard
symbols, emoji, box drawing, arrows and Greek, where the character either
disappears or becomes something else.

## Test 4 — how good is it on ordinary text?

Rendered code, quotes, URLs and numbers at realistic UI sizes and compared
character by character with edit distance.

```
9pt   as captured (2x)   errors=0   accuracy=100.0%
11pt  as captured (2x)   errors=0   accuracy=100.0%
13pt  as captured (2x)   errors=1   accuracy= 99.2%
```

Essentially perfect. There is no general accuracy problem to fix.

I also tested the standard trick of enlarging the image before recognition:

```
9pt   upscaled 2x more   errors= 1   accuracy=99.2%
11pt  upscaled 2x more   errors= 1   accuracy=99.2%
13pt  upscaled 2x more   errors=12   accuracy=91.0%
```

**Upscaling makes it worse.** Notably worse at 13pt. Good thing to measure rather
than assume, because it is the first thing most advice suggests.

The capture path was already grabbing at full Retina backing scale, so there was
no lost detail to recover either:

```swift
let scale = backingScale(for: display)     // 2 on this machine
config.width  = Int(rect.width  * scale)
config.height = Int(rect.height * scale)
```

## Test 5 — can per-character positions be recovered?

If Vision reports `H` where `⌘` was, the fix needs the pixels of that one
character. `VNRecognizedText.boundingBox(for:)` takes a range, so in principle
you can ask for one character's box.

```
line: Press HC to copy
   'H' box x=0.148 y=0.725 w=0.080 h=0.179
line: T&V pastes plain text
   'T' box x=0.033 y=0.527 w=0.120 h=0.176
   '&' box x=0.033 y=0.527 w=0.120 h=0.176     ← identical to 'T'
```

Every character in a word returns the **same word-level box**. `139x48` px for a
single character at that size is a whole word.

That killed per-character matching as designed and forced the whole-word approach
in [07-glyph-repair.md](07-glyph-repair.md) — which later had to be replaced by
segmenting the word myself.

## Are other OCR engines better?

Short answer, no, and not for a reason that tuning fixes.

`⌘ ⌥ ⇧` are Apple-specific glyphs that do not appear in the text corpora these
models are trained on. PaddleOCR, Tesseract and RapidOCR have the same gap. They
would produce a different set of wrong guesses.

Three more considerations against swapping:

- **Character accuracy is already ~100%** on code and terminal output. There is
  no gap to close.
- **Indentation is not an OCR problem.** Every engine returns text plus boxes;
  turning positions back into indentation is geometry you write yourself. The app
  already does this in `layOut()`. A different engine returns the same boxes.
- **Size.** ONNX Runtime plus detection, recognition and table models is roughly
  50 MB added to a 2.6 MB app.

The one thing a different engine would genuinely add is **table structure**.
PaddleOCR's PP-Structure detects rows and columns explicitly; Vision does not.
Even there, x-position clustering over the boxes Vision already returns gets most
of the way in pure Swift at zero size cost.

I did not benchmark PaddleOCR head to head. That would have meant installing it,
so the comparison above is reasoning from what the models are trained on, not
measurement. Worth stating plainly.

## The better answer for on-screen text

For text that is currently on screen, OCR is the wrong tool. The text is already
text — the Accessibility API returns the exact string, `⌘` intact, with no
recognition step. It is what VoiceOver uses, and KlipKlik already holds the
permission it needs.

| Source | Exact text available? |
| --- | --- |
| Native macOS apps | yes |
| Safari / Chrome page content | yes, via the AX tree |
| PDFs in Preview | better still, use PDFKit |
| Electron apps | usually, quality varies |
| Terminals, canvas-drawn UI, games | often not |
| An actual image of text | never |

The right shape is a hybrid: try AX for the selected region, fall back to Vision
when it comes back empty. The real work is that a grab is a *rectangle*, so you
need every AX element intersecting it, ordered by position — roughly what
`layOut()` already does for OCR observations, but over AX nodes.

**Not verified.** My probe needs Accessibility and the shell reported
`AXIsProcessTrusted() → false` at the time — the same inherited-trust trap from
[05-permissions.md](05-permissions.md), which is exactly why I am flagging it
rather than asserting it works.
