# 08 — Every number, and how to reproduce it

All measurements ran on the machine that built the app: Apple M5, 16 GB, macOS
26.5.2, Swift 6.3.2. Harnesses compile against the shipped source with `swiftc`
and need no project setup.

## Summary

| Measurement | Value | Where |
| --- | --- | --- |
| OCR character accuracy, code at 9pt | 100.0% | [T4](#t4--ocr-accuracy-on-ordinary-text) |
| OCR character accuracy, code at 11pt | 100.0% | T4 |
| OCR character accuracy, code at 13pt | 99.2% | T4 |
| Same, upscaled 2× first | 91.0% | T4 |
| Symbols Vision gets right unaided | 13.3% | [T6](#t6--glyph-repair-benchmark) |
| Symbol recovery, whole-word matcher | 55.0% | T6 |
| Symbol recovery, per-glyph segmenter | 85.7% | [T7](#t7--per-glyph-segmentation) |
| Symbol recovery, + even-pitch for mono | 100.0% | [T8](#t8--final) |
| Prose left untouched | 100% (64/64) | T6 |
| Repair time, 14 lines, cold cache | 427 ms | [T9](#t9--performance) |
| Repair time, warm cache | 30 ms | T9 |
| Template bank size | 560 | T7 |
| Gatekeeper assessment, unquarantined | allowed | [T10](#t10--gatekeeper) |
| Gatekeeper assessment, quarantined | rejected | T10 |

## T1 — Vision configuration sweep

Does any setting fix `⌘`?

```swift
func run(_ label: String, correction: Bool, revision: Int?) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = correction
    if let revision { request.revision = revision }
    try? VNImageRequestHandler(data: png, options: [:]).perform([request])
    ...
}
run("correction OFF", correction: false, revision: nil)
run("correction ON",  correction: true,  revision: nil)
run("newest revision", correction: false, revision: VNRecognizeTextRequest.supportedRevisions.max())
```

| Configuration | `Press ⌘C to copy` |
| --- | --- |
| Revisions 1, 2, 3, correction off | `Press HC to copy` |
| Correction on | `Press HC to copy` |
| macOS 26 `RecognizeTextRequest` | `Press HC to copy` |

No configuration changes the result.

## T2 — Character class coverage

Thirteen classes, isolated. Full table in
[06-ocr-research.md](06-ocr-research.md#test-2--how-wide-is-the-damage).

Pass: accented Latin only. Everything else fails when isolated.

## T3 — Context versus isolation

| Input | Result |
| --- | --- |
| `Total: €45.99 and £12.50 paid` | pass |
| `€ £ ¥` | fail |
| `where x ≤ 10 and y ≠ 0 gives ±3` | `≤` ok, `≠`→`#`, `±`→`=` |
| `≤ ≠ ±` | nothing returned |
| `{"id": 42, "tags": ["a","b"], "ok": true}` | pass (spacing only) |
| `drwxr-xr-x 3 sanoj staff 96 Aug 11 14:33 build/` | pass (spacing only) |

The same character passes in a sentence and fails alone.

## T4 — OCR accuracy on ordinary text

Ground truth, compared with Levenshtein distance:

```swift
let truth = """
let total = items.filter { $0.isActive }.count
print("Result: \\(total) of 128")
URL(string: "https://api.example.com/v2/users?id=42")
"""
```

| Size | As captured (2×) | Upscaled 2× more |
| --- | --- | --- |
| 9pt | 0 errors — 100.0% | 1 error — 99.2% |
| 11pt | 0 errors — 100.0% | 1 error — 99.2% |
| 13pt | 1 error — 99.2% | 12 errors — 91.0% |

Upscaling is a net loss. The capture already runs at Retina backing scale, so
there is no detail being thrown away.

## T5 — Per-character bounding boxes

```
line: Press HC to copy
   'H' box x=0.148 y=0.725 w=0.080 h=0.179
line: T&V pastes plain text
   'T' box x=0.033 y=0.527 w=0.120 h=0.176
   '&' box x=0.033 y=0.527 w=0.120 h=0.176
```

Identical boxes for different characters. `boundingBox(for:)` is word-level.

## T6 — Glyph repair benchmark

160 samples: 12 symbol strings and 8 prose strings, at 13/16/20/24pt, in system
and monospaced fonts. 120 symbol occurrences.

```swift
let symbolStrings = ["Press ⌘C to copy", "Use ⌘V to paste", "Hit ⌥⇧V for plain",
    "Try ⌃⌘F fullscreen", "Save with ⌘S now", "Undo is ⌘Z here",
    "Quit using ⌘Q please", "Open ⇧⌘P palette", "Find ⌘F in page",
    "Total: ¥300 paid", "Cost £45 today", "Price €20 net"]

let proseStrings = ["The HTTP Host header", "let m = items.map { $0.name }",
    "Press to copy and paste", "Total items for the table",
    "Options and settings here", "Take the fast path first",
    "Header Price Total Count", "func handle(_ x: Int) -> Bool"]
```

Prose strings are chosen to contain the letters most likely to be misfired on:
`H`, `T`, `t`, `o`, `a`, `P`, `E`, `x`, `f`.

```
symbol occurrences   : 120
  OCR alone got right: 16  (13.3%)
  after repair       : 66  (55.0%)
prose lines          : 64
  left untouched     : 64  (100.0%)
```

### The failed intermediate

Before the confidence gate, the same code on real captured terminal text:

```
"Press ... to copy and ... to paste"  →  "·ess sC · copy ⌘d sv · ₹ste"
"still wrong"                          →  "¢ill wron"
"the failure offline"                  →  "⎋e €£ilure offline"
```

The clean-text benchmark passed while this was happening. Rendered samples were
not representative of real captures.

## T7 — Per-glyph segmentation

Probes: `⌘C ⌘V ⌥⇧V ⌃⌘F ⌘S ⌘Z ⌘Q ⇧⌘P ¥300 £45 €20`, four sizes, two fonts.

```
template bank: 560
segmentation count matched glyph count: 79/88   (89.8%)
per-glyph symbol classification: 96/112 = 85.7%
```

Per symbol:

| Symbol | Score | |
| --- | --- | --- |
| £ | 8/8 | 100.0% |
| ¥ | 8/8 | 100.0% |
| € | 8/8 | 100.0% |
| ⌃ | 8/8 | 100.0% |
| ⌘ | 52/56 | 92.9% |
| ⌥ | 12/16 | 75.0% |
| ⇧ | 16/24 | 66.7% |

Confusions: `⌘→P` ×4, `⇧→⌘` ×4, `⇧→V` ×2, `⌥→]` ×2.

### Aspect ratio and font bank — no effect

| | Before | After |
| --- | --- | --- |
| ⌘ | 92.9% | 91.1% |
| ⌥ | 75.0% | 75.0% |
| ⇧ | 66.7% | 66.7% |

Confusions moved (`⌥→]` became `⌥→~`), totals did not. Both changes reverted as
load-bearing ideas.

### The split that mattered

| Size | Monospaced | System |
| --- | --- | --- |
| 13pt | 75.0% | **100.0%** |
| 16pt | 75.0% | **100.0%** |
| 20pt | 68.8% | **100.0%** |
| 24pt | 75.0% | **100.0%** |

System font perfect everywhere. All loss in monospaced.

## T8 — Final

Adding even-pitch segmentation for monospaced text:

```
£ 8/8  ¥ 8/8  € 8/8  ⌃ 8/8  ⌘ 56/56  ⌥ 16/16  ⇧ 24/24     all 100.0%

13pt mono 100%   16pt mono 100%   20pt mono 100%   24pt mono 100%
13pt sys  100%   16pt sys  100%   20pt sys  100%   24pt sys  100%
```

128/128.

## T9 — Performance

Fourteen lines of shortcut-heavy text, the worst case for suspect characters:

```
lines: 14
repair time: 427 ms for 14 lines
second pass (cache warm): 30 ms
sample line: Row 1: press ⌘1 or ⌥⇧F to toggle the HTTP Host header
```

427 ms is acceptable — a grab already involves screen capture plus OCR, and the
work runs off the main thread. The render cache brings repeat work to 30 ms.

That sample line is also the cleanest single result in the project: `⌘` and `⌥⇧`
recovered while `HTTP` and `Host` are left alone.

## T10 — Gatekeeper

```
$ spctl --assess --type execute -vv build/KlipKlik.app
build/KlipKlik.app: rejected

$ xcrun stapler validate build/KlipKlik.app
KlipKlik.app does not have a ticket stapled to it.
```

The distinction that matters is quarantine:

```
$ gktool scan KlipKlik.app                      # locally built
Scan completed and software is allowed by system policy.

$ xattr -w com.apple.quarantine "0083;00000000;Safari;" KlipKlik.app
$ gktool scan KlipKlik.app                      # as downloaded
Scan completed, but failed because the software is not signed by a
distributor that meets the system Gatekeeper requirements.
```

Same binary. Building locally never sets the quarantine flag; downloading always
does.

## T11 — Signature stability

```
before packaging: CDHash=96fe8bc510abe6b8d2ba26f3c5fd82f2298f6f6c
after packaging:  CDHash=96fe8bc510abe6b8d2ba26f3c5fd82f2298f6f6c
>>> IDENTICAL — Accessibility grant survives
```

Re-signing an unchanged binary reproduces the same hash. Any source change does
not:

```
CDHash=96fe8bc5...   →   CDHash=46d2af57...
```

## T12 — Foundation Models availability

```swift
let model = SystemLanguageModel.default
switch model.availability {
case .available: print("AVAILABLE")
case .unavailable(let reason): print("UNAVAILABLE — \(reason)")
}
```

```
UNAVAILABLE — appleIntelligenceNotEnabled
```

Framework present in the SDK and imports fine. Off at the system level.

## Method notes

**Rendered text is not captured text.** T4, T6, T7 and T8 render with
`NSAttributedString` into a bitmap context at 2×. Real captures come through
`SCScreenshotManager` with subpixel antialiasing and real backgrounds. The one
time I tested against genuinely captured pixels, the shipped code turned out to
be mangling prose while every rendered benchmark passed.

**Small samples early on.** "1 in 3" came from three cases. Building the 160-sample
harness is what turned impressions into a number worth acting on, and it moved
the estimate from 33% to 55%.

**Only the target symbols are scored.** Recovery counts `⌘ ⌥ ⇧ ⌃ ¥ £ €`. Vision's
handling of Latin is measured separately in T4.
