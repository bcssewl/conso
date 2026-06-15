<div align="center">

<img src="docs/assets/app-icon.png" alt="conso" width="120" height="120" />

# conso

**A native macOS maintenance app for Apple Silicon — clean, fast, on-device.**

Five tools (Status · Clean · Software · Optimize · Analyze) in one menu-bar app, built clean-room in SwiftUI for macOS 26, with an on-device AI advisor that explains your Mac instead of nagging it.

</div>

---

## What it is

conso is a native macOS 26 maintenance app for Apple Silicon. It's a single, focused menu-bar app written in original SwiftUI — no Electron, no web view, no phone-home. Everything it does runs **on-device**: disk scans, telemetry, the safety checks before a delete, and even the AI prose. It collects no analytics and makes no network calls of its own.

It's a learning / portfolio project, and an honest, original competitor to the paid **Mole for Mac** app (mole.fit).

> **Clean-room note.** conso shares **no code** with Mole. The free Mole CLI is **GPLv3** and was deliberately never read or copied — conso was written from scratch against the public macOS APIs. This is a hard project rule, not a marketing line. conso also intentionally avoids Mole's globe/"Worlds" visual motif.

---

## Features

conso is organized around five pillars, plus a privileged helper for the few things that genuinely need root, plus an on-device AI suite.

### The five pillars

| Pillar | What it does |
| --- | --- |
| **Status** | Live system telemetry — CPU, memory pressure, thermal state, GPU, battery, network throughput, and a steady health score — sampled on-device and surfaced in a compact HUD. |
| **Clean** | Safe cache and junk scanning with a tested allow/deny safety guard, plus Trash emptying. Everything is previewed before deletion; the safety layer refuses anything outside the known-safe set. |
| **Software** | Real app inventory with update routing — detects apps managed by Homebrew, the Mac App Store (`mas`), Sparkle, and `softwareupdate`, and points each one at the right updater. Filterable by App / Library / System. |
| **Optimize** | A curated "Fix a problem" catalog of situational, default-off fixes (e.g. rebuild Spotlight index, flush DNS, clear font caches). Nothing runs unless you ask. |
| **Analyze** | A real disk treemap (squarified layout) plus a Files finder that surfaces content-hash duplicates and old / unused files so you can reclaim space deliberately. |

### Privileged helper (root, done safely)

A small `SMAppService` daemon handles the few operations that require root:

- **Optimize root fixes** (Spotlight / DNS / font caches).
- **APFS snapshot deletion** via `tmutil`.

The helper enforces a **strict server-side whitelist**: it accepts only fixed command keys, validates snapshot dates against a regex, and never runs a shell or arbitrary arguments. The XPC connection is code-sign-validated in both directions, so only the signed conso app can talk to it. The app classifies and phrases; the helper is the only thing with privilege, and it only does things on its hardcoded list.

### On-device AI suite

Built on Apple's **FoundationModels** (the on-device model in macOS 26). The governing rule is **facts → words**: deterministic ConsoCore code gathers the facts, the model only turns those facts into plain language. **The model never decides what to do and never executes anything.** Every surface has a deterministic fallback, so conso works fully even with Apple Intelligence off.

- **Doctor** — a plain-language health summary of your Mac (the stethoscope button).
- **"What's this?" explainer** — an ⓘ on Clean / Software / Optimize / Analyze items that explains, in context, what an item is and what cleaning or fixing it actually does.
- **"Ask conso" (⌘K)** — a grounded command bar for Q&A and suggested actions. It answers from real system facts and proposes actions you confirm; offline it degrades to a deterministic keyword launcher. Backed by App Intents so it's reachable from Spotlight.

Other polish: launch-at-login, Settings & About, refined loading / empty states, and optional **scheduled auto-clean** (off by default).

---

## Tech stack & architecture

conso is split into a testable core and a signed app, on purpose.

```
CONSO/
├── Package.swift              SPM package (library + C shim + tests)
├── Sources/
│   ├── ConsoCore/             Pure, deterministic logic — fully unit-tested
│   │   └── Advisor/           The AI "facts → words" seam (deterministic fallbacks live here)
│   ├── CSensors/              C shim over the IOKit / IOHID temperature-sensor API
│   └── conso/                 SwiftUI app sources (compiled only by the Xcode target)
├── Tests/ConsoCoreTests/      ConsoCore unit tests (run via `swift test`)
├── conso/conso.xcodeproj      The real, signed app + the privileged helper target
│   └── conso-helper/          The SMAppService privileged daemon
└── docs/                      Design notes, setup guide, mockups, assets
```

**Why the dual layout?**

- **`ConsoCore`** (and the `CSensors` C target) is a plain Swift Package — pure logic with no UI. It is the part that is fully unit-tested, so `swift test` exercises the real maintenance, safety, scanning, and advisor logic without needing the app, a signature, or a GUI.
- **The SwiftUI app and the privileged helper** live in the **Xcode project** (`conso/conso.xcodeproj`), which links `ConsoCore` and compiles the `Sources/conso/` UI files. The app must be **signed** (for the menu-bar app, App Intents, and especially the code-sign-validated XPC to the helper), and signing is an Xcode/`xcodebuild` concern — so the app can only be built that way.

In short: **`swift build` builds the library; it does not build the app.** Use Xcode / `xcodebuild` for the real app, and `swift test` for the logic.

---

## Install

### Download (recommended)

1. Grab the latest **`conso.dmg`** from the [**releases page**](https://github.com/bcssewl/conso/releases/latest) (or the **Download for macOS** button on [conso.app](https://conso.app)).
2. Open the DMG and drag **conso** into **Applications**.
3. **First launch.** conso is self-signed (not notarized by Apple), so macOS Gatekeeper blocks it once. Double-click conso, then open **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway**, and authenticate. You only do this once per version. (macOS 15+ removed the old right-click → Open shortcut.) If macOS instead says the app is "damaged", clear the download quarantine:
   ```sh
   xattr -dr com.apple.quarantine /Applications/conso.app
   ```

From then on conso **updates itself** — Sparkle checks daily and prompts you when a new version is ready (toggle auto-updates and opt into the **Beta** channel in **Settings → Updates**). Permissions you grant carry across updates.

> **One limitation of the download:** four root-maintenance features — rebuild Spotlight, flush DNS, clear system font caches, delete APFS snapshots — require a team-signed build, so they're disabled in the self-signed DMG. Everything else works fully. To enable them, build from source with your own Apple Team ID (below).

### Build from source

For development, or to enable the root-helper features, build with your own free Apple Team ID — see [Build & run](#build--run).

## Build & run

### Prerequisites

- macOS 26 on **Apple Silicon**
- **Xcode 26** (Swift 6 toolchain)
- An **Apple Developer Team ID** of your own — see [CONTRIBUTING.md](CONTRIBUTING.md). The repo ships with the author's Team ID in a few places; you must replace it with yours to build and sign the app and helper.

### Run the tests (no signing needed)

```sh
swift test
```

This runs the ConsoCore test suite (the deterministic core and advisor logic).

### Build the app

```sh
xcodebuild -project conso/conso.xcodeproj \
  -scheme conso \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -allowProvisioningUpdates build
```

Then launch the built `.app` from Xcode's DerivedData (or open the project in Xcode and run).

> **Notes for contributors**
> - conso is a **menu-bar app**: closing its window does not quit it. When testing a rebuild, quit the running copy first (e.g. `pkill -9 -x conso`) before relaunching.
> - conso is **non-sandboxed** by design and is **not** a Mac App Store app — it needs filesystem and privileged-helper access the sandbox forbids.
> - To exercise the privileged helper and snapshot deletion, run a copy of `conso.app` from **/Applications**, then use **Settings → helper Remove + Install** to register the current helper version.

### Releasing (maintainers)

Releases are built locally (conso needs the macOS 26 SDK + Apple Intelligence, which hosted CI can't provide) and published as a self-signed DMG with a Sparkle appcast, the same way the [Trace](https://github.com/bcssewl/trace) app does it.

```sh
# one-time
scripts/setup-local-signing.sh          # create the stable "conso Local Signing" identity
scripts/sparkle-sign.sh --generate-key  # create the EdDSA key; paste SUPublicEDKey into conso/Info.plist

# each release (builds, signs, packages, signs the appcast, publishes to GitHub Releases)
scripts/release.sh v1.2.0               # stable -> Stable channel (releases/latest)
scripts/release.sh v1.3.0-beta.1        # pre-release -> Beta channel only (rolling beta-feed)
scripts/release.sh v1.2.0 --no-publish  # build + sign + DMG + appcast locally, push nothing
```

**Do not rotate both the signing certificate and the EdDSA key in the same release** — Sparkle needs at least one to stay constant across versions, or existing users can't update.

---

## Status

**Feature-complete portfolio project.** All five pillars, the privileged helper, and the full on-device AI suite are implemented, committed, and covered by a green `swift test` run.

A few honest caveats:

- **AI prose requires Apple Intelligence to be ON** (System Settings). With it off, Doctor / explainer / Ask all fall back to deterministic, hand-written copy — functional, just not model-generated.
- **System-level root deletion** (e.g. `/Library/Caches`, `/Library/Logs`) is intentionally **not** shipped. It would need a new validated helper command and a system-path scanner; it's deferred rather than rushed, because root `rm` outside the home directory deserves the same strict whitelist pattern the snapshot path already uses.
- **Distribution / notarization** (Developer ID, notarize, staple) requires a **paid Apple Developer account** and is out of scope for this repo. You can build and run locally with a free / personal team.

---

## Screenshots

_Screenshots coming soon._

---

## License

Distributed under the **MIT** license. See [LICENSE](LICENSE) for the full text.

Copyright © 2026 Bassel.

Project home: <https://github.com/bcssewl/conso>
