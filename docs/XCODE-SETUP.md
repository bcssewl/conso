# conso — Xcode setup (SPM package → real signed .app)

Goal: a real, signed, **non-sandboxed** macOS app that links the existing `ConsoCore`
package, shows the app icon in the Dock, and is ready for the SMAppService helper spike.

Current repo: a Swift package at the root — `ConsoCore` (library + `CSensors` C shim,
all tested) and `conso` (the SwiftUI executable). In Xcode we keep `ConsoCore` as a
**local package** and move the SwiftUI files into a new **App target**.

---

## 0. One-time: add a free Apple ID
Xcode ▸ **Settings… ▸ Accounts ▸ +** ▸ *Apple ID* ▸ sign in with your Apple ID
(free — no paid program needed). This gives you a **Personal Team** with a Team ID,
which the SMAppService privileged helper later requires.

## 1. Create the App project
**File ▸ New ▸ Project… ▸ macOS ▸ App ▸ Next**
- Product Name: **conso**
- Team: your Personal Team (from step 0)
- Organization Identifier: **com.conso**  → bundle id becomes `com.conso.conso`;
  change it to **`com.conso.app`** in step 5.
- Interface: **SwiftUI**, Language: **Swift**
- **Uncheck** Core Data / Tests if offered.
- Save it **inside this repo** (e.g. at `<repo-root>/`), so it's version-controlled
  next to `Package.swift`.

## 2. Add ConsoCore as a local package
**File ▸ Add Package Dependencies… ▸ Add Local…** ▸ choose the repo root
(`<repo-root>`, the folder with `Package.swift`) ▸ Add.
When asked which products to add to the **conso** target, add **`ConsoCore`**.
(`CSensors` comes along automatically as ConsoCore's dependency.)

## 3. Add the SwiftUI source files to the app target
- In Finder, the UI lives in `Sources/conso/`. Drag **all of `Sources/conso/*.swift`**
  into the Xcode project navigator, **Target Membership = conso (the app)**,
  "Reference files in place" (don't copy).
- **Delete the two files Xcode generated**: `consoApp.swift` and `ContentView.swift`
  (our `ConsoApp.swift` is the real `@main`).
- So Xcode doesn't compile those files twice, make the package **library-only**:
  ask me and I'll remove the `conso` executable target from `Package.swift`
  (leaves `ConsoCore` + `CSensors` + tests). `swift run` stops working after that,
  but you'll be running from Xcode.

## 4. App icon + logo marks
- **Icon:** open `Assets.xcassets` ▸ delete the empty AppIcon ▸ drag in the set from
  `~/Downloads/conso_macos_iconsets/conso-blue-c-pulse/AppIcon.appiconset`
  (drag the `.appiconset` folder onto the asset catalog). Target ▸ General ▸
  App Icon = **AppIcon**.
- **Marks (theme logos):** drag `docs/assets/mark-native.png`, `mark-pro.png`,
  `mark-character.png` into the project, **Target Membership = conso**, and confirm
  they land in **Build Phases ▸ Copy Bundle Resources**. `ThemeLogo` loads them from
  `Bundle.main`. (The runtime `AppIcon.icns` dock override in `ConsoApp.swift` becomes a
  harmless no-op — the asset-catalog icon drives the Dock now.)

## 5. Bundle id, signing, no sandbox
Target **conso ▸ Signing & Capabilities**:
- **Automatically manage signing = on**, Team = your Personal Team.
- **Bundle Identifier = `com.conso.app`**.
- **Remove the App Sandbox capability if present** (conso is intentionally
  non-sandboxed — needed for Full Disk Access / system reads). Do **not** add Hardened
  Runtime yet; add it later when notarizing.

## 6. Deployment target
Target **conso ▸ General ▸ Minimum Deployments ▸ macOS**:
- **14.0** keeps everything as-is (cards already use `.regularMaterial` glass).
- **26.0** if you want true Liquid Glass — then we swap the material backgrounds /
  nav for `.glassEffect()` (I'll do that pass once the target builds).

## 7. Build & run, then install
- Scheme = **conso**, destination = **My Mac** ▸ **⌘R**. The window opens with the
  Dock icon. Toggle themes in the ⚙︎ Settings popover to see the logo swap.
- Install: **Product ▸ Archive ▸ Distribute App ▸ Copy App**, or drag the built
  `conso.app` (right-click the product in Xcode ▸ *Show in Finder*) into `/Applications`.

## 8. Next (the real risk): SMAppService helper spike
Once the app runs signed: add an embedded **privileged helper** registered via
`SMAppService.daemon(plistName:)`, XPC-connected, validated by an audit-token
code-signing requirement. Build the smallest possible "register + ping + run one root
command" spike before depending on it. See `docs/macos-lessons.md`.

---

### Common snags
- **"Multiple commands produce …" / duplicate `@main`** → you didn't delete the
  generated `consoApp.swift`, or the package still has the `conso` executable target
  (do step 3's library-only edit).
- **Logo doesn't appear** → marks not in *Copy Bundle Resources* (step 4).
- **CoreWLAN / IOKit link errors** → none expected; the package already links IOKit,
  and CoreWLAN auto-links from the `import`.
- **Icon not updating in Dock** → macOS caches icons; `touch` the .app or log out/in.
