# 09 — Getting it onto other machines

## Building the bundle

No Xcode, so the `.app` is assembled by script. Compile with SwiftPM, lay out the
bundle, sign:

```bash
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/KlipKlik"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/KlipKlik"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP"
```

`LSUIElement: true` in the plist is what keeps it out of the Dock.

## The DMG

`Scripts/make_dmg.sh` builds the app, stages it with an `Applications` symlink,
and makes a compressed image:

```bash
cp -R "$APP" "$STAGING/KlipKlik.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KlipKlik $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$DMG"
```

Around 1.4 MB. Verified by mounting it and checking the contents rather than
assuming:

```
$ hdiutil attach build/KlipKlik-1.0.4.dmg
/Volumes/KlipKlik 1.0.4

Applications -> /Applications
KlipKlik.app

$ codesign --verify --verbose=1 "/Volumes/.../KlipKlik.app"
valid on disk
satisfies its Designated Requirement
```

And that the right build is inside, by looking for a string that only exists in
the new code:

```
FOUND: "Restart and use KlipKlik"
DMG cdhash  = 96fe8bc5...
disk cdhash = 96fe8bc5...  → same build
```

## Gatekeeper

This is where an ad-hoc signed app stops being a private tool and starts being a
problem.

```
$ spctl --assess --type execute -vv build/KlipKlik.app
build/KlipKlik.app: rejected
```

Gatekeeper only judges **quarantined** files, which is why a locally built app
runs fine and the same binary downloaded does not:

```
locally built:  "Scan completed and software is allowed by system policy."
quarantined:    "Scan completed, but failed because the software is not signed
                 by a distributor that meets the system Gatekeeper requirements."
```

Same bytes. The only difference is the `com.apple.quarantine` attribute a browser
attaches to downloads.

### Can the app fix this itself?

No, and not for a reason that can be coded around.

Gatekeeper blocks a quarantined app **before any of its code runs**. The app
cannot strip its own quarantine flag because it never executes. That is the point
of the mechanism — an app that could disable its own quarantine check would make
quarantine worthless.

Same reason a DMG cannot run anything on mount (macOS has no autorun), and
wrapping it in an unsigned `.pkg` gets blocked identically.

The workarounds and what they cost:

| Route | Cost |
| --- | --- |
| Developer ID + notarization | $99/year. Clean double-click install. |
| `xattr -dr com.apple.quarantine` | One terminal command per user. |
| Build from source | No warning at all — locally built binaries are never quarantined. |
| `spctl --master-disable` | Turns Gatekeeper off machine-wide. Not documented, not suggested. |

Building from source is the honest answer for a developer-facing utility. The
README leads with it, and the DMG is offered as the convenience option that
carries the friction.

## The self-signed certificate

Full account in [05-permissions.md](05-permissions.md#the-self-signed-certificate-and-why-it-failed).
Short version: created one, trusted it for code signing, and `codesign` still
failed with `errSecInternalComponent`. Removed it from the keychain afterwards
rather than leaving an unused trusted certificate in the user's security
configuration.

It would not have helped distribution anyway. Gatekeeper rejects a self-signed
certificate as firmly as ad-hoc. Its only value would have been keeping the
Accessibility grant stable across rebuilds.

## Homebrew

Two questions, different answers.

**Own tap — works today.** Nothing gates it. Create `d-sanoj/homebrew-klipklik`,
point a cask at the release asset. The install command is qualified:

```bash
brew install --cask d-sanoj/klipklik/klipklik
```

**`brew install klipklik` bare — needs `homebrew-cask`.** I checked Homebrew's
docs rather than assuming a tap would give the short command. It does not:
unqualified tokens resolve against the official taps, and a third-party tap needs
the full `user/repo/token` or a per-formula `brew trust`.

Two things block acceptance into `homebrew-cask`:

1. **Gatekeeper.** Their policy requires a cask to work without users disabling
   macOS security protections. An ad-hoc signed app cannot clear that. Homebrew
   6.0.16's cask audit runs `gktool scan` on app artifacts, so this is checked,
   not just stated.
2. **Notability.** 0 stars, 0 forks, 0 watchers at the time of writing. Their bar
   is "substantial, independently verifiable public interest."

I also looked for a `quarantine` stanza that would let the cask strip the flag.
It does not exist in the cask DSL in this Homebrew version, and no
`--no-quarantine` flag appears in `brew install --help`. So there is no
author-side or user-side way to skip it.

## Releases

`v1.0.4` published to GitHub with the DMG attached, tagged at the commit that
built it:

```
$ gh release view v1.0.4 --json assets
KlipKlik-1.0.4.dmg  1516069 bytes

$ gh api repos/d-sanoj/KlipKlik/git/ref/tags/v1.0.4 --jq '.object.sha[0:7]'
26d5466
```

Release notes lead with the Gatekeeper situation and give both the `xattr` line
and the build-from-source route, so anyone downloading it knows why macOS refuses
it on first open rather than concluding the app is broken.

## Two loose ends

**Version numbering drifted.** `1.0.3` shipped, then more code landed while the
plist still said `1.0.3`. Caught before publishing and bumped to `1.0.4`, but
briefly there was a DMG labelled the same as a release with different code in it.

**The repo is `KlipKlik`, the app is `KlipKlik`.** One `c` apart. The buttons say
`KlipKlik`, the headings and bundle identifier say `KlipKlik`. Whichever wins
becomes the cask token, and renaming a published cask means a deprecation dance.
Worth settling before any of the distribution work above goes further.
