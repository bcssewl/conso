# Contributing to conso

Thanks for your interest in conso. It is a native macOS maintenance app
(Clean / Software / Optimize / Analyze / Status) written from scratch in
SwiftUI, with a fully unit-tested logic core. Contributions are welcome —
this guide covers everything you need to build, test, and submit changes.

## Requirements

- macOS 26 (Tahoe) on Apple Silicon
- Xcode 26
- Your own Apple Developer Team ID (see [Signing](#signing) below — you cannot
  build the signed app or the privileged helper with someone else's Team ID)

## Build & test

The logic core is an SPM library; the real signed app and its privileged
helper are built by the Xcode project. See [Project layout](#project-layout)
for why there are two build systems.

### Run the tests (no Xcode required)

```sh
swift test
```

This runs the `ConsoCore` test suite (the pure logic library). Keep it green —
every logic change should land with tests.

### Build the app

```sh
xcodebuild -project conso/conso.xcodeproj -scheme conso \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -allowProvisioningUpdates build
```

### Relaunching while testing rebuilds

conso is a **menu-bar app** — closing its window does not quit it, so an old
instance keeps running and will mask your rebuild. Kill it before relaunching:

```sh
pkill -9 -x conso
```

Then launch the freshly built `.app`.

## Signing

The repository ships with the maintainer's Apple Developer Team ID
(`VMJ9FM7QD9`). You must replace it with **your own** Team ID before the app or
the privileged helper will build and run, because the helper validates the
app's code signature against this Team ID over XPC.

Replace it in **three** places:

1. **Xcode signing settings** — set `DEVELOPMENT_TEAM` to your Team ID for
   every target in `conso/conso.xcodeproj` (target → Signing & Capabilities).
2. `Sources/conso/HelperClient.swift` — the `teamID` constant.
3. `conso/conso-helper/main.swift` — the `teamID` constant.

A Team ID is not a secret, but it is tied to a specific Apple account, so do
not commit your own ID back to a shared branch — keep that change local.

## Project layout

conso uses two build systems on purpose:

- **`Sources/ConsoCore/`** — the pure logic library (`ConsoCore`). All
  business logic lives here. It is platform-light, has no UI, and is developed
  **test-first (TDD)**. If you change or add logic, add or update tests in
  `Tests/ConsoCoreTests/`. This is what `swift test` exercises.
- **`Sources/CSensors/`** — a small C shim for reading sensor data.
- **`Sources/conso/`** — the SwiftUI app UI. It links `ConsoCore` for all
  logic. UI lives here; logic does not. SwiftUI views are compiled only by the
  Xcode app target, not by `swift build`.
- **`conso/conso.xcodeproj`** — the real, signed app target plus the
  privileged helper (`conso/conso-helper/`). This is the only way to build and
  run the actual app. `swift build` builds the library, not the app.
- **`helper/`** — the privileged helper's LaunchDaemon plist (embedded by the
  app target). The helper's source lives in `conso/conso-helper/`.

When you add a new Swift file to `Sources/conso/`, it must also be registered
in the Xcode project (`conso/conso.xcodeproj/project.pbxproj`) so the app
target compiles it.

Rule of thumb: **logic goes in `ConsoCore` with tests; UI goes in
`Sources/conso`.** Pushing logic down into the tested core keeps the app thin
and the behavior verifiable.

## Clean-room rule (important)

conso is an original, clean-room project. It is **not** derived from "Mole"
(the GPLv3 Mole CLI) or any other GPL-licensed source, and it shares no code
with them. This is a deliberate design and licensing choice — it lets conso
ship under a permissive license.

**Do not copy, paste, or closely adapt code from the GPLv3 Mole CLI, the
mole.fit app, or any GPL / copyleft source.** If you are unsure whether a
snippet's origin is compatible, do not include it. All contributions must be
your own original work (or come from a permissively-licensed source you are
allowed to use), so that the whole project remains permissively licensed.

## Code style

- Match the existing Swift conventions you see in the surrounding code:
  clear value types, small focused functions, no dead/commented-out code, and
  no stray `print` / `NSLog` debugging left behind.
- Prefer pushing testable logic into `ConsoCore` over embedding it in views.
- **Privileged / root operations stay behind the helper's strict,
  server-side allow-list.** The privileged helper only performs a fixed set of
  vetted operations and validates the caller's code signature. **Never add
  arbitrary shell execution**, and never widen the helper to run
  caller-supplied commands or paths. New privileged capabilities must be added
  as explicit, narrowly-scoped, server-side-validated operations.

## Pull requests

- Keep `swift test` green.
- Follow the repository's existing commit-message style (Conventional
  Commits, e.g. `feat(advisor): ...`, `fix: ...`, `ui: ...`).
- Describe what changed and why; include before/after notes or screenshots for
  UI changes.
- Keep changes focused — small, reviewable PRs merge faster.

By contributing, you agree that your contributions are licensed under the same
license as this project (see [LICENSE](LICENSE)).
