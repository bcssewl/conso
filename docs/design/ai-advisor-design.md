# conso — On-device AI layer (design)

- **Project:** conso (native macOS maintenance app)
- **Status:** Implemented. This is the original design for conso's on-device AI suite — the **Doctor** health summary, the **"What's this?"** explainer, and the **"Ask conso"** command box. The shipping implementation lives in `Sources/ConsoCore/Advisor/` (deterministic core) and `Sources/conso/` (the live Apple FoundationModels adapters).

## Summary

Add a small **on-device AI helper** to conso, exposed in **three surfaces**: a plain-language **Doctor** health summary, an inline **"What's this?"** explainer, and an **Ask conso** natural-language command box. The helper never reads the disk and never decides anything — conso's deterministic code computes all facts and safety verdicts, and the model is used only to *phrase* those facts or *route* a request to an existing, confirmation-gated action.

One brain, three surfaces, one strict one-way data flow.

## Goals

- Make conso's findings **understandable** ("what is this and is it safe to remove?") — directly targeting the #1 documented user fear in this category.
- Turn raw telemetry into a **plain-language health summary**.
- Let users **type intent** ("free up 10 GB", "why is my fan loud?") and route it to conso's existing deterministic actions.
- Stay **100% on-device, free, private** — using Apple's Foundation Models framework (macOS 26).
- Be **purely additive**: every surface degrades to deterministic templated text when AI is unavailable; the app never depends on it.

## Non-goals (YAGNI — explicitly excluded)

- ❌ The model deciding what to delete, or computing sizes/metrics. Deterministic code owns all facts and verdicts.
- ❌ A general-purpose launcher / Spotlight or Raycast replacement (app launch, file search, clipboard, generic commands). Unwinnable vs. macOS 26 Spotlight + Raycast, and scope creep. We build a *maintenance-only* control surface and publish conso's actions to Spotlight via App Intents instead.
- ❌ Cloud / API models in the default path. Sending file paths and process lists off-device breaks the privacy story. (A reserved, opt-in "deeper analysis" path is a possible future, not part of this design.)
- ❌ Malware/AV scanning, breach monitoring (separate feature areas, out of scope here).
- ❌ Loud "AI" branding. Framed as "explanations" / "help."

## Background — why this, why now

- **The model is free and built in.** macOS 26 on Apple Silicon (the target machine is an M4 Max) ships an on-device ~3B model via the `FoundationModels` Swift framework — no API key, no cost, no network. Its two key primitives — **Guided Generation** (`@Generable` + constrained decoding → output is guaranteed to fit our Swift types) and **Tool Calling** (model can only invoke functions we define) — are exactly what these features need.
- **The AI lane is open.** The whole cleaner category has converged on the same cleanup/uninstall/treemap/telemetry feature set (conso already matches most of it). Genuine AI is nearly absent: the closest competitor "Mole" has none; CleanMyMac's is opaque; the only shipped, narrow, on-device example is Nektony's "App Summary powered by Apple Intelligence" — which validates this approach.
- **"AI" branding is poisoned here.** Users are skeptical-to-hostile toward "AI cleaner" apps (predatory scamware has trained that reflex). The winning posture is **local, transparent, explanation-first, user-in-control, quiet about the label** — which is also the one wedge that beats Mole *and* sidesteps the backlash.
- **Apple's model is small on purpose.** Apple states it is for summarization / extraction / classification / short generation / tool routing — **not** world knowledge, **not** advanced reasoning, with **no** hallucination guarantee. The official mitigation is exactly our architecture: feed it real data (grounding) and constrain its output. This design is built around that limit, not in spite of it.

## Architecture

```
   conso's deterministic core            The helper                  Surfaces (UI)
   (owns all facts & verdicts)           (on-device model)
   ──────────────────────────           ──────────────             ─────────────────────
   • live metrics (real today)      ┐                            ┌─ Doctor: health summary
   • scan results (real, later)     ├──►  facts in  ─►  words out ┤─ "What's this?": explain
   • curated safety rules table     ┘    (ONE direction only)     └─ Ask conso: NL → action
        ▲                                                            (confirm, then run)
        │ deterministic, unit-tested
        └─ stays in charge; the model can never reach back
```

**The grounding contract (the heart of the design):** facts flow *into* the model; words flow *out*. The model receives only a small, structured package of facts conso already computed. It cannot read the filesystem, cannot execute actions, and cannot originate a safety verdict. This one-way flow is what makes an LLM acceptable inside a destructive-adjacent maintenance app.

## Safety model (7 hard rules)

1. **The model never reads the disk or decides safety.** It sees only structured facts conso computed.
2. **Safety verdicts come from a hand-curated deterministic rules table**, surfaced to the model as data (or via a lookup tool). The model only *explains* a verdict; it never originates one.
3. **Unknown ⇒ "unknown."** If conso cannot identify an item, the helper says so and never guesses. (Constrain output to allow an explicit `unknown` state.)
4. **The model can propose but never execute.** Every destructive/changing action stops for explicit user confirmation. The model's role ends at "here's what I'd do."
5. **On-device only.** Nothing leaves the Mac. No account, no network, no cost.
6. **Graceful fallback.** If AI is unavailable (ineligible device, Apple Intelligence off, model not ready, unsupported language), every surface renders deterministic templated text from the same facts. The AI is a bonus layer, never a dependency.
7. **Quiet branding.** Surfaces are named for what they do (Doctor, What's this?, Ask conso) — not "AI."

### Prompt-injection guardrail

File names, process names, and bundle IDs are **untrusted input**. They are passed only as *prompt / tool data*, never interpolated into the session's `instructions`. The model is post-trained to obey instructions over prompt content, so the static policy (role, refusal rules, output contract) lives in `instructions` and stays authoritative.

## Components

A dedicated advisor module (e.g. `ConsoCore/Advisor/` or a thin `ConsoAdvisor` layer), behind a protocol so the deterministic parts are unit-testable and the model is swappable/mockable.

- **`AdvisorAvailability`** — wraps `SystemLanguageModel.default.availability`; maps to `.available` / `.unavailable(reason)`; drives the fallback decision everywhere.
- **Fact types (grounded inputs)** — one small `Codable`/`@Generable` input struct per surface (`HealthFacts`, `ItemFacts`, `IntentRequest`). These are the *only* things the model sees. Built by conso's scanners/telemetry.
- **Safety rules table** — deterministic mapping from known paths / bundle IDs / categories → `SafetyVerdict { recommendation: keep | safeToRemove | caution | unknown, reason }`. Hand-curated, unit-tested, versioned. Independent of the model.
- **Output types (`@Generable`)** — typed model outputs per surface (`DoctorReport`, `ItemExplanation`, `RoutedIntent`), with `@Guide` constraints (enums, ranges, counts) so decoding cannot drift and cannot emit out-of-catalog values.
- **Tool catalog (Ask conso only)** — each conso action exposed as a `Tool` whose `call(...)` does **not** execute directly but returns a *proposed* action for confirmation. Plus read-only tools for live state queries.
- **Fallback renderer** — deterministic templates that turn the same fact structs into readable text when AI is off. Every surface has one.
- **Session management** — short, terse `instructions` per surface; token-budget-aware input assembly (see constraints); `GenerationError` handling.

## The three surfaces

### 1. Doctor (build first)

- **Trigger:** the existing "Run Doctor" top-bar button.
- **Input:** `HealthFacts` built from the **already-real** Status telemetry (CPU, memory pressure, thermal state, GPU, battery, disk, top processes) + any flagged findings.
- **Output (`DoctorReport`):** a short summary (what's good), a prioritized list of attention items each with a *why*, and one suggested next step that maps to an existing conso action (button).
- **UI:** a card/sheet; streamed in progressively.
- **Fallback:** templated "Health: Nominal. N items worth attention: …" from the same facts.
- **Why first:** needs no new scanners (Status telemetry is real today) and the button already exists — smallest, safest, instantly demoable.

### 2. "What's this?" explainer

- **Trigger:** a small "?" affordance next to any item in Clean / Software / Optimize / Analyze lists.
- **Input:** `ItemFacts` (real path, bundle ID, size, last-access, owner/category) + the deterministic `SafetyVerdict` from the rules table.
- **Output (`ItemExplanation`):** 1–2 lines — what it is, whether it's safe, and why — plus an explicit `unknown` path. An always-visible "verify before deleting" note for anything destructive.
- **UI:** inline popover.
- **Fallback:** show the rules-table verdict + reason text directly (no rephrasing).
- **Depends on:** the real Clean/Software scanners (deferred to the Xcode phase) + the safety rules table.

### 3. Ask conso (command box)

- **Trigger:** a hotkey-summoned window and an embedded in-app field. Maintenance-scoped only.
- **Input:** the typed `IntentRequest` + the tool catalog + read-only state tools.
- **Output (`RoutedIntent`):** the chosen action(s) with filled parameters, or a state answer — shown as a preview that waits for the user's OK before anything runs.
- **Also:** publish conso's actions as **App Intents** so they appear in macOS 26 Spotlight for free (ride Spotlight, don't fight it).
- **Fallback:** plain keyword search over the action catalog (no NL).
- **Depends on:** the action catalog wired as tools (latest of the three).

## Technical constraints (Foundation Models, macOS 26 / Tahoe)

- **Context window: 4,096 tokens total** (instructions + prompt + tool I/O + output). Hard ceiling on this OS. ⇒ feed **pre-aggregated** facts (top-N, totals, counts), never raw scan lists; for large reports use **map-reduce** (summarize sections in separate sessions, then synthesize). Handle `GenerationError.exceededContextWindowSize` by condensing. (macOS 27 raises on-device to 8,192 — treated as a future upgrade, not a dependency.)
- **Availability gating:** check `SystemLanguageModel.default.availability` before every use; handle `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`. Always have the fallback path.
- **On-device only** via this API surface (no silent cloud offload).
- **Languages:** check `supportedLanguages`; handle `unsupportedLanguageOrLocale`.
- **API surface:** `LanguageModelSession(tools:instructions:)`, `respond(to:)` / `streamResponse(...)` (snapshot streaming → SwiftUI), `@Generable`/`@Guide`, `Tool` protocol, `tokenCount(for:)`, and `GenerationError` (`rateLimited`, `guardrailViolation`, `refusal`).
- **No adapters / no fine-tuning.** Use the base model + guided generation + grounding. (Adapters must be retrained per OS update — not worth it.)

## Build order & roadmap fit

All three need the real signed `.app` (Foundation Models is a system framework requiring Apple Intelligence), so this lands **in/after the Xcode phase**, in this order:

1. **Doctor** — first; rides existing real telemetry + existing button.
2. **"What's this?" explainer** — with the real Clean/Software scanners + safety rules table.
3. **Ask conso** — last; needs the action catalog as tools + App Intents.

Each build is independently shippable: stopping after any one still leaves conso better.

## Testing strategy

The model is non-deterministic, so we **TDD the deterministic parts** and integration-test the model boundary:

- Unit-test: the safety rules table; fact-building from telemetry/scan results; the fallback renderers; availability→fallback gating; tool-catalog wiring (proposed action ≠ executed action); token-budget assembly (pre-aggregation stays under budget).
- Behind a protocol: a mock advisor returns canned `@Generable` outputs so surfaces are testable without the model.
- Manual / integration: real-model smoke tests for each surface, including the AI-off fallback path and the `unknown` path.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Model hallucinates an item description / safety call | Grounding contract + rules-table verdicts + explicit `unknown`; model never originates facts |
| 4,096-token window overflow on big scans | Pre-aggregate; map-reduce; handle `exceededContextWindowSize` |
| AI unavailable on a user's Mac | Deterministic fallback on every surface; AI is additive only |
| Prompt injection via file/process names | Untrusted text only in prompt/tool data, never in `instructions` |
| "AI cleaner" trust backlash | Quiet branding; transparent, local, user-confirms-everything |
| Scope creep into a general launcher | Maintenance-only command bar; App Intents for general launching |

## Open questions (defer to planning)

- Module placement: extend `ConsoCore` vs. a separate `ConsoAdvisor` target.
- Exact `HealthFacts` field set for the Doctor (which telemetry + findings to include within budget).
- Hotkey + window behavior for Ask conso (and whether to ship the embedded field first, hotkey window later).
- How much of the safety rules table to seed initially vs. grow over time.

## Sources

- Apple Foundation Models: WWDC25 [286](https://developer.apple.com/videos/play/wwdc2025/286/), [301](https://developer.apple.com/videos/play/wwdc2025/301/); [Apple ML Research — 3rd-gen models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models); [docs: SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [GenerationError / context window](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror), [TN3193 context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window).
- macOS 26 Spotlight / App Intents: [Apple Newsroom (Tahoe)](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/), [9to5Mac](https://9to5mac.com/2025/06/10/macos-26-spotlight-gets-actions-clipboard-manager-custom-shortcuts/).
- Competitor / category: [Mole](https://mole.fit/), Nektony "App Summary powered by Apple Intelligence" ([PRWeb](https://www.prweb.com/releases/nektony-transforms-app-cleaner--uninstaller-into-a-comprehensive-app-management-suite-302696559.html)), CleanMyMac relaunch ([9to5Mac](https://9to5mac.com/2024/10/16/macpaw-releases-major-update-to-cleanmymac-with-fresh-design-and-new-features/)), predatory AI-cleaner pattern ([connortumbleson](https://connortumbleson.com/2025/01/13/predatory-ios-cleanup-applications/)).
- Raycast AI Extensions pattern: [manual.raycast.com/ai/ai-extensions](https://manual.raycast.com/ai/ai-extensions).
