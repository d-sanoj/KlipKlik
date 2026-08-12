# KlipKlick — build analysis

This folder is the working record of how KlipKlick got built: what I tried, what
the numbers said, and where I was wrong. It is not a tidy retrospective written
after the fact. The measurements are the ones I actually ran, and several of them
contradict decisions made earlier in the same session.

Two things drove most of the effort, and neither was the clipboard manager
itself. The first was macOS permissions, where a signing detail quietly
invalidated hours of testing. The second was OCR, where Apple's text recogniser
turns out to be excellent at text and completely blind to `⌘`.

## Start here

If you only read two files, read [05-permissions.md](05-permissions.md) and
[07-glyph-repair.md](07-glyph-repair.md). Those are where the real problems were.

| File | What's in it |
| --- | --- |
| [01-brief-and-constraints.md](01-brief-and-constraints.md) | What was asked for, and what the machine could actually do |
| [02-architecture.md](02-architecture.md) | How the app is put together, with diagrams |
| [03-design-implementation.md](03-design-implementation.md) | Translating the Claude Design file into AppKit/SwiftUI |
| [04-liquid-glass.md](04-liquid-glass.md) | macOS 26 glass, and why the first two attempts failed |
| [05-permissions.md](05-permissions.md) | TCC, ad-hoc signing, and the bug that faked every test result |
| [06-ocr-research.md](06-ocr-research.md) | What Vision can and cannot read, measured |
| [07-glyph-repair.md](07-glyph-repair.md) | Getting `⌘` back: 55% → 100%, and the two dead ends |
| [08-benchmarks.md](08-benchmarks.md) | Every number in one place, with the code that produced it |
| [09-distribution.md](09-distribution.md) | Gatekeeper, notarization, Homebrew, DMG |
| [10-decisions.md](10-decisions.md) | Decision log — what was chosen and what it cost |
| [11-what-i-got-wrong.md](11-what-i-got-wrong.md) | The mistakes, including two that shipped |

## The short version

KlipKlick is a menu-bar clipboard manager for macOS 14+. No Dock icon, history
in memory only, double-tap `⌘` to open. Built with SwiftPM and a hand-assembled
`.app` bundle because this machine has Command Line Tools and no Xcode.

Three findings worth carrying to another project:

**Permissions are tied to the code signature, and ad-hoc signatures change on
every build.** Every rebuild silently revoked Accessibility. Worse, a binary
launched from an already-trusted terminal inherits that trust, so my tests passed
while the real app did nothing. I reported a feature as working twice before
catching it.

**Apple's Vision framework has no `⌘` in its vocabulary.** Not a settings
problem. All three revisions and the new macOS 26 API produce byte-identical
output, and no other offline OCR engine knows these glyphs either.

**Diagnosing by the wrong axis costs hours.** Symbol recovery sat at 86% and the
per-symbol breakdown said `⇧` and `⌥` were weak, which sent me tuning shapes.
Splitting the same data by *font* showed system text was already at 100% and
every single loss was monospaced. Different problem entirely.

## Reproducing the measurements

The benchmark harnesses live in [08-benchmarks.md](08-benchmarks.md) as complete
Swift files. They compile against the shipped source with `swiftc` and need no
project setup:

```bash
swiftc -O -o /tmp/bench Sources/KlipKlick/Core/GlyphRepair.swift bench.swift
/tmp/bench
```

Nothing in this folder is generated. If a number here disagrees with the code,
the code changed after I wrote it down.
