# 14 — Making it idle quietly

The app worked. It also woke `tccd` 86,400 times a day, asked LaunchServices who
was frontmost two and a half times a second, and built six hundred menu items at
launch for a menu most people open once.

None of that was visible. The whole point of a menu bar app is that it sits
there, and this one sat there at 0.9% CPU and 32 MB looking perfectly fine. It
took a sampler to find out why.

All measurements on the machine that built it: Apple M5, 16 GB, macOS 26.6.1,
Swift 6.3.2. Harnesses are in [code/perf-bench.swift](code/perf-bench.swift) and
[code/image-roundtrip.swift](code/image-roundtrip.swift).

## Where it ended up

| | Before | After |
| --- | --- | --- |
| Idle CPU, no window open | 0.93% | **0.05%** |
| Idle memory | 32 MB | **20 MB** |
| Idle wakeups, shelves on | 11.1/sec | **3.5/sec** |
| Live heap after 3 image copies | 71.3 MB | **31.8 MB** |
| Binary | 2.63 MB | **1.09 MB** |
| Blob on disk, per 1.8 MB image | 2,435 KB | **1,790 KB** |

Thirteen commits, `c13069a`..`31cbe8c`.

## The nine

| # | What it was | Commit |
| --- | --- | --- |
| 1 | A 1 Hz TCC poll that outlived its window | `8580165` |
| 2 | Frontmost app read from LaunchServices every tick | `c13069a`, `c4f0716` |
| 3 | ~600 menu items built at launch, re-titled on every open | `8258fab`, `42aa7ba` |
| 4 | Offload encrypting on the main thread, in the worst format | `a758a71`, `725592e` |
| 5 | Uncompressed TIFF held in RAM per image copy | `0e53323` |
| 6 | Preferences window built whether or not it is opened | `900db1c` |
| 7 | 25 Hz mouse poll, all day, for a gesture that is rare | `33c6ff9` |
| 8 | Half the binary was symbols nothing reads | `31cbe8c` |
| 9 | Dedupe keyed on a hash that changes every launch | `997cf94` |

---

## 1 · A timer that outlived its window

**Found by:** `sample` on an instance that had been up 19 hours.

```
OnboardingView.body.getter → SLSTCCService::TCCAccessCheck → TCCAccessRequest → xpc
```

The welcome window had been closed hours earlier. Its SwiftUI subscription had
not: `OnboardingView` subscribed a 1-second timer from inside its `body`, the
controller was retained on `AppDelegate`, and the window was
`isReleasedWhenClosed = false`. Nothing ever cancelled it.

Each tick called `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`.

**What that cost — and why I had it backwards.** I called this the biggest win in
the app. It is not, and the split is the reason:

```
AXIsProcessTrusted()                   0.00 ms   (sub-microsecond)
CGPreflightScreenCaptureAccess()       5.83 ms wall, 0.06 ms CPU, 5.78 ms blocked
  at the leaked 1 Hz: 0.58% of the main thread, 0.01% CPU
```

**99% of it is blocked on an XPC round trip to `tccd`, not spent on CPU.** So it
cost about 0.01% CPU — invisible in Activity Monitor, which is exactly why it
survived. What it actually did was stall the main thread 0.6% of all wall time,
forever, and wake a system daemon 86,400 times a day. Real, but not the CPU story
I claimed. #2 was the CPU story.

**Fix.** `PermissionStatus`, refreshed on `NSApplication.didBecomeActive` — both
grants are made in System Settings, so coming back to the app *is* the signal.
Started and stopped by the window controllers, not by SwiftUI's
`onAppear`/`onDisappear`: a window ordering out is a fact the controller already
has, and inferring it is what leaked in the first place.

A 2-second poll runs alongside for a grant made without ever reactivating the
app, but only while a window is up, and only for accessibility. The screen
recording answer **cannot change within a process** — which is why `needsRestart`
exists in the onboarding flow — so polling it was 5.8 ms of blocking for a value
guaranteed not to have moved.

**Also fixed in passing:** `OnboardingWindowController` had no window delegate.
Closing it with the red button never restored `.accessory` activation policy, so
the Dock icon stayed for the rest of the session; only the Done button cleaned
up. Both exits now run through `windowWillClose`.

---

## 2 · Asking LaunchServices who is frontmost, 2.5 times a second

The clipboard poll is defended in the source as cheap, and `changeCount` is. But
`poll()` also called `frontmostApp()` on **every** tick, before checking whether
the count had even moved. The sampler caught what that actually is:

```
NSRunningApplication.bundleIdentifier → _LSCopyApplicationInformation
  → LSClientToServerConnection::sendWithReply → xpc_connection_send_message_with_reply_sync
```

A synchronous cross-process call, 2.5 times a second, forever, for a value that
changes a few dozen times an hour.

**Fix.** `FrontmostWatcher` reads the app out of
`didActivateApplicationNotification`, which carries the `NSRunningApplication`
already, and keeps the two fields as plain strings. The tick is now a counter
read and a comparison.

The subtle part is the ignore-list lookback. A copy is spotted up to one interval
*after* the ⌘C, so someone who copies from a password manager and immediately
switches away would have it recorded against the app they switched *to*. The old
code checked the previous tick's frontmost. Notification tracking has no ticks,
so a naive port would have kept "previous" forever — and an app left hours ago
would go on suppressing copies for the life of the process. It is bounded by a
timestamp instead, reproducing the one-tick window.

`FinderCutMove` had the same shape: it re-queried `NSWorkspace` from inside the
activation handler, whose `userInfo` already held the answer.

**Measured**, 120 s, no window open:

| | Idle CPU | Threads |
| --- | --- | --- |
| Before | 0.93% | 5 |
| After | **0.20%** | 4 |

---

## 3 · Six hundred menu items, built at launch

`buildTimeZoneMenu` walked the whole zoneinfo tree and materialised every zone as
an `NSMenuItem` inside nested submenus, at launch, retained for the session.

The refresh was worse than the build. `menuNeedsUpdate` on the status menu called
`refreshTimeZoneMenu`, which iterated all ~600 items and rebuilt each title —
flag lookup and offset string — **every time the clock was clicked**, to update
submenus that were mostly never opened.

**Fix.** [`LazyMenu`](../Sources/KlipKlick/UI/LazyMenu.swift): an `NSMenuDelegate`
that builds on first open and refreshes on every one after. Menus are only ever
displayed one level at a time, so nothing below the level being shown has to
exist. The status menu now refreshes one line; a region refreshes its own zones
when it is the thing being opened.

`TimeZoneFlags` had a related retention: aliases are resolved by grouping zone
files that are byte-identical, and **the whole file was the dictionary key**, so
every canonical zone file stayed in memory to compare against. Now keyed by
SHA-256 — 32 bytes.

Alias resolution is the only path that touches it, so it is the thing to test:

```
ok   Asia/Calcutta -> 🇮🇳      ok   US/Eastern -> 🇺🇸      ok   Europe/London -> 🇬🇧
ok   Asia/Kolkata  -> 🇮🇳      ok   Japan      -> 🇯🇵      ok   UTC           -> 🌐
```

---

## 4 · Encrypting megabytes on the thread that draws the popup

Two problems, one function.

**The format.** JSON cannot hold bytes, so every `Data` went out as base64, and
the whole inflated string had to be built in memory before it could be encrypted.

```
payload 1790.2 KB
JSON  encodes to 2435.0 KB          binary plist encodes to 1790.3 KB
JSON encode      3.22 ms            binary plist encode      0.02 ms
JSON decode      4.96 ms            binary plist decode      0.02 ms
```

**26% smaller and roughly 150× faster each way.** Reading falls back to JSON so a
pinned archive written by an earlier version still opens — verified along with
the failure case:

```
legacy JSON index decodes: true      binary plist index decodes: true
legacy JSON blob decodes:  true      binary plist blob decodes:  true
garbage returns nil: true
```

**The thread.** `DiskStore` had a `.utility` queue declared and never used, while
`offloadIdleItems` encrypted and wrote from a `Timer` on the main run loop. It
now writes on that queue and drops the bytes on the main thread once the disk
confirms it has them — the ordering guarantee is unchanged, only the location.

Verified end to end: two blobs appeared 5.5 minutes after the copies, 125,584
bytes for an image and 123 for a line of text.

**The timer.** It ticked every 60 seconds for the life of the process, nearly
always finding nothing — history is cleared on quit and at the daily purge, so an
app with nothing left to offload is the *normal* state. It now starts when an
item arrives and stops when everything is written.

---

## 5 · Not three copies of a picture — one uncompressed one

I described this as apps writing PNG *and* TIFF *and* PDF of the same image.
Probing the pasteboard says otherwise:

| Source | What lands on the pasteboard |
| --- | --- |
| macOS screenshot (`screencapture -c`) | `public.png`, 1,948 KB |
| Any app copying an `NSImage` | `public.tiff`, **23,202 KB** |

Duplicate flavours happen, but they are not the cost. **TIFF is uncompressed**,
and `NSImage` is how apps copy pictures. One screenshot-sized copy is 23 MB in
RAM until the offload five minutes later; two put the app past 40 MB on their
own.

**Fix.** Store PNG, rebuild the TIFF on paste. PNG is lossless, so this is free —
which is the claim worth proving rather than asserting:

```
stored: 23202.1 KB -> 1803.7 KB (92% smaller), restoresTIFF=true
kept flavours:  ["public.png"]
pasted flavours: ["public.png", "public.tiff"]
restored 23758918 bytes vs original 23758918
identical bytes: true, identical pixels: true
PASS
```

Byte-for-byte. An app that asks only for `public.tiff` cannot tell.

**Why it runs off the main thread.** The transcode is not cheap:

```
tiff -> png   85 ms     png -> tiff   35 ms
```

85 ms on the capture path would hitch every image copy, so the item lands as
captured and its bytes are swapped a moment later. The decode is wrapped in an
explicit `autoreleasepool`: `NSBitmapImageRep` produces a bitmap as large as the
TIFF and is autoreleased, and on a queue that goes idle those outlive the work.

Live in the capture log:

```
compact AF39AA51 23083.9 KB -> 1789.5 KB
```

### The part that did not work

Process footprint after three 23 MB copies fell 121 MB → 96 MB. Nothing like the
69 MB → 5.3 MB the stored data actually dropped by. `heap` explains it:

```
Physical footprint:   96.2M
All zones: 54419 nodes (31853476 bytes)     ← live heap is 31.8 MB
  68 MB  0 B  0 B  3  MALLOC_LARGE          ← footprint says otherwise
```

The live heap is 31.8 MB. The other ~64 MB is memory `malloc` has freed and not
returned to the OS. **I tried `malloc_zone_pressure_relief` to reclaim it and it
did nothing** — 98 MB with and without, including after I fixed my own ordering
bug (I had placed the call before the buffers were actually released). I removed
it rather than ship a call with a confident comment about a benefit it does not
deliver.

So: the data really did shrink by 55%, and the number in Activity Monitor will
not fall by nearly that much. The same retention exists in the old build. Still
open.

---

## 6 · A window built for guests who never come

`PreferencesWindowController` was constructed in `applicationDidFinishLaunching`
— window, hosting controller, and the whole SwiftUI view graph — for a window
most people open once and many never open at all. Setting `contentViewController`
and calling `center()` forces the view to load, so SwiftUI defers none of it.

Built on first `show()` now. The popup panel still gets built at launch, because
it has to open instantly, but with `defer: true` so its backing store waits for
the first order-front.

Together with #3: **idle memory 32 MB → 20 MB.**

---

## 7 · 25 Hz all day for a gesture that happens a few times an hour

The drag watcher polls because the alternatives are worse — a `CGEventTap` needs
Accessibility, which lapses on every rebuild, and a global monitor cannot see the
source app's modal drag loop. That reasoning is sound and is why the timer is
still here.

What was wrong is the rate. A drag *begins* with a mouse-down, and a global
`NSEvent` monitor sees that for free and with no permission. So the fast poll can
start on demand.

**The monitor cannot replace polling**, which is the part worth being careful
about:

- Global monitors never observe our own app's events.
- The source app's drag loop swallows everything after mouse-down, including the
  mouse-up.

So the timer stays as a 5 Hz backstop rather than trading a feature for wakeups.

**Measured**, 120 s, no input:

| | Idle CPU | Idle wakeups |
| --- | --- | --- |
| Before, 25 Hz always | 0.22% | 11.1/sec |
| After, 5 Hz + monitor | **0.067%** | **3.5/sec** |

I also introduced re-entrancy doing this — `poll()` called `schedule(fast:)`
which called `poll()` — and removed it. It was harmless by luck, not design.

---

## 8 · Half the binary was symbols nothing reads

I estimated `-Osize` would cut 20–30%. Measured:

| | Size |
| --- | --- |
| `-O` (what it was) | 2.63 MB |
| `-O` + `strip -x` | 1.22 MB |
| `-Osize` + `strip -x` | **1.08 MB** |
| `+ -Xlinker -dead_strip` | 1.22 MB — no effect |

**`-Osize` alone is worth 0.8%.** Stripping is worth 54%. My estimate was wrong
about which lever mattered by two orders of magnitude. `-dead_strip` does nothing
measurable here, so it is not in the script.

`strip` has to run **before** `codesign`. Afterwards it rewrites the file and
invalidates the signature macOS hangs the privacy grants on — the same signature
trap as [05-permissions.md](05-permissions.md), from the other direction.
Verified: `valid on disk`, `satisfies its Designated Requirement`.

---

## 9 · A fingerprint that changed every launch

The only correctness bug of the nine.

Duplicate detection hashed content with `hashValue`. **Swift seeds that randomly
per process.** Pinned items persist their fingerprint in the index, so after a
relaunch a pinned item's stored fingerprint no longer described its own content:
re-copying it failed to collapse onto the row already there and added a duplicate
beside it.

Caught in this session's own logs — the identical string `"frontmost tracking
check"`, two launches apart:

```
capture #41 ... fp=text:6765300667224615189
capture #42 ... fp=text:-2043830469409048911
```

After, the same probe across two launches:

```
run 1   fp=text:8ea40a1b2b58fc8c…4ea1b8      fp=data:ddbe7f3e40fadd…2ea3aef
run 2   fp=text:8ea40a1b2b58fc8c…4ea1b8      fp=data:ddbe7f3e40fadd…2ea3aef
```

**Why not hash everything.** Fingerprints are computed on the capture path,
before compaction, so a large image means hashing 23 MB:

```
SHA256, whole payload        6.76 ms
SHA256, count + 64KB ends    0.04 ms
Data.hashValue (unstable)    0.00 ms
```

Anything over a megabyte is hashed as length plus both ends — 170× faster, and
the worst a collision could do is treat a new copy as a repeat of the row above
it. Text and small payloads are hashed entire.

**Migration cost:** existing pinned items keep their old fingerprints, so the
first re-copy of one after this change still duplicates once, then behaves.

---

## What I got wrong

Four things, all of them claims I made before measuring:

1. **Ranked #1 as the biggest win.** It cost 0.01% CPU. #2 was the CPU fix; #1
   was a main-thread stall and a daemon-wakeup fix. Different problem, different
   argument for fixing it.
2. **Described #5 as three copies of one image.** It is one uncompressed copy.
   The fix that follows from the real diagnosis is transcoding, not de-duping.
3. **Estimated `-Osize` at 20–30%.** It is 0.8%. Stripping was the lever.
4. **Reached for `malloc_zone_pressure_relief`** and shipped nothing, because it
   changed nothing. Removed rather than left in with a comment claiming otherwise.

The pattern is the same one in
[11-what-i-got-wrong.md](11-what-i-got-wrong.md#3--diagnosing-by-the-wrong-axis):
a plausible mechanism, stated confidently, that measurement does not support.
Three of the four would have shipped as working fixes for problems that were not
there.

## Still open

- **The malloc retention in #5.** 68 MB in three `MALLOC_LARGE` regions that
  `heap` says are not live. Present in the old build too. Pressure relief does
  not touch it.
- **Two thirds of the shelf corner fix is unverified.** The glass overshoot is
  confirmed by before/after pixel crops. The stale window shadow and the focus
  ring are reasoned from the mechanism and have not been seen on a live shelf
  with the window key — which is the only state the artefact appears in.

## Reproducing

```bash
swiftc -O -o /tmp/perf analysis/code/perf-bench.swift
/tmp/perf tcc                 # permission call cost, CPU vs blocked
/tmp/perf encode some.png     # JSON against binary plist
/tmp/perf hash some.tiff      # fingerprint hashing options

swiftc -O -o /tmp/rt analysis/code/image-roundtrip.swift \
    Sources/KlipKlick/Models/ClipboardItem.swift
/tmp/rt some.png              # image compaction, losslessness
```

Idle CPU and memory, against a build of the previous commit:

```bash
git worktree add /tmp/prev HEAD~1 && (cd /tmp/prev && ./Scripts/build_app.sh release)
# launch each, wait for it to settle, then over a fixed window:
ps -o time= -p $(pgrep -x KlipKlick)
footprint -p $(pgrep -x KlipKlick)
heap $(pgrep -x KlipKlick) | grep "All zones"
```

`footprint` and `heap` disagree by design — the first counts dirty pages, the
second counts live nodes. #5 is only legible if you read both.
