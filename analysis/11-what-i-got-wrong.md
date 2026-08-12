# 11 — What I got wrong

Kept because the mistakes were more instructive than the parts that worked, and
two of them shipped.

---

## 1 · Reported `⌘X` as working twice when it never had

**What happened:** ran an end-to-end test, watched the file move from Downloads to
Documents, saw clean logs, said it worked. Twice.

```
cutmove: armed files=1 changeCount=2986
cutmove: ⌘V intercepted armed=true stale=false move=true
→ Downloads: GONE   Documents: moveme.txt
```

**Why it was wrong:** I launched the app from the shell to read its stderr. A
binary launched from an already-trusted terminal **inherits that terminal's
Accessibility grant**. The instance I tested was privileged. The one the user
launched from Finder was not.

```
launched via `open`   (how the user runs it):  trusted=false
launched from my shell (how I tested):         trusted=true
```

**The lesson:** the convenience *was* the confound. Testing an app the way it is
launched is not a nicety. When a permission is involved, launch context is part
of the system under test.

---

## 2 · Said "only eight Apple symbols" after testing eight Apple symbols

**What I said:** the failures are `⌘ ⌥ ⇧ ⌃` and a few relatives. "Not eight
characters that Apple's model was never taught, not OCR being unreliable."

**What a wider test found:** Greek turns into Cyrillic, emoji vanish, box-drawing
vanishes, arrows fail, `©` becomes `•`, `≠` becomes `#`.

**Why it was wrong:** I generalised from the easy case. My first accuracy test used
clean code and scored 100%, so I concluded ordinary text was fine and only Apple
glyphs broke. Both claims were too strong.

**The correction:** context decides. The same `≤` reads correctly in a sentence and
returns nothing on its own. That reconciles the results, and it is more useful
than either of the confident claims.

---

## 3 · Shipped a repair that destroyed English prose

The worst one.

`GlyphRepair` went out with a suspect list containing `t o a x f P E` and a
relative-only confidence gate. On clean rendered text it scored 55% with 64/64
prose lines untouched.

On real captured terminal text:

```
"Press ... to copy and ... to paste"  →  "·ess sC · copy ⌘d sv · ₹ste"
"still wrong"                          →  "¢ill wron"
"the failure offline"                  →  "⎋e €£ilure offline"
```

**Why the benchmark missed it:** every guard case was rendered directly with
`NSAttributedString` at 2×: clean, large, high contrast. Real captures have
subpixel antialiasing and lower effective contrast, so nothing matches any
template well and the "closest" one wins by noise.

**How I found it:** by accident. I captured a screen region to iterate offline and
happened to catch my own terminal output.

**The fix:** an absolute confidence floor, not just a relative margin.

```swift
private static let minimumConfidence = 0.86
```

**The lesson:** a benchmark built from synthetic inputs measures the synthesiser.
The one measurement that mattered came from real captured pixels, and I only ran
it late and by chance.

---

## 4 · Widened the suspect set and broke what was working

Trying to catch more symbols, I added `V C F M J L K` to the suspect list.

```
before:  Use ⌥⇧V for plain text, ⌃⌘F for fullscreen   PASS
after:   Use T&V for plain text, ^&F for fullscreen   FAIL
```

Adding suspects pushed words past the two-suspect cap, so they were skipped
entirely, and a legitimate `V` got rewritten to `⌃`.

**The lesson:** the cap and the suspect set are coupled. Widening one silently
disables the other. Reverted within one iteration because the benchmark caught it.

---

## 5 · Tuned the wrong axis for several iterations

Symbol recovery sat at 85.7%. The per-symbol breakdown said `⇧` (66.7%) and `⌥`
(75%) were weak, with confusions like `⌥→]` that look like proportion errors.

So I added aspect-ratio scoring and widened the font bank. Both measured as
**zero improvement** — the confusions simply moved to `⌥→~`.

The answer came from slicing the same data by font instead:

```
13pt mono  75.0%      13pt sys  100.0%
20pt mono  68.8%      20pt sys  100.0%
```

System font was already perfect. Every loss was monospaced, because mono fonts
have no `⌘` and macOS drops a fallback into a fixed-width cell.

**The lesson:** when a fix does nothing, the diagnosis is probably wrong, not the
fix. Re-cutting the data by a different variable was worth more than two more
attempts along the first one.

---

## 6 · Clobbered a commit message

Ran an ill-considered second command that replaced a detailed commit body with
`Bump to 1.0.4`. Amended before pushing, so what is on GitHub is correct.

Small, but it is the kind of thing that quietly loses the reasoning behind a
change.

---

## 7 · Rebuilt repeatedly while asking the user to grant permissions

Each rebuild changes the ad-hoc signature and revokes the grant. I did this
several times across the session, each time asking the user to re-grant, before
recognising the pattern and committing to stop rebuilding until they had tested.

The right move, establishing signature stability first or batching changes,
was available from the moment `0 valid identities found` appeared.

---

## What I would keep

The measurement discipline, once it started. The 160-sample benchmark turned "1 in
3" into 55%, caught the suspect-set regression within one iteration, and proved
two plausible ideas did nothing.

What was missing early was **testing against real inputs rather than generated
ones**. Every serious error above (the inherited trust, the prose mangling, the
over-broad claim about symbols) came from a test environment that was cleaner
than reality.
