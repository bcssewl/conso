import Foundation
import ConsoCore
import FoundationModels

/// The one shared on-device-model call path behind every grounded AI adapter (Doctor,
/// Explainer, Asker, Command resolver, Clean summarizer). It standardizes the four steps
/// each adapter used to repeat by hand:
///
///  1. Availability gate — if the on-device model isn't available, return `fallback()`
///     without ever opening a session.
///  2. Bounded call — run the generation inside `withTimeout(seconds: aiCallTimeoutSeconds)`
///     so a stalled model can never leave a surface "thinking…" forever.
///  3. Generate — open a `LanguageModelSession` with the adapter's trusted `instructions`,
///     respond to its `prompt` with greedy (deterministic) decoding, and `map` the schema
///     to the adapter's result type. `map` throws `EmptyModelAnswer` for the empty-answer
///     case, which is treated exactly like any other failure.
///  4. Catch → fallback — ANY error (timeout, guardrail refusal, empty answer, mapping
///     failure) routes to `fallback()`, so the caller always gets a usable result.
///
/// Grounding is unchanged: each adapter passes its OWN `instructions` and `prompt`
/// (untrusted data stays in the prompt, never in instructions) and its own `map`, so the
/// pinned-facts contract is identical to before — this only removes the duplicated plumbing.
@available(macOS 26, *)
func runGroundedModel<Schema: Generable, Result>(
    instructions: String,
    prompt: String,
    generating: Schema.Type,
    map: @escaping @Sendable (Schema) throws -> Result,
    fallback: () async -> Result
) async -> Result where Schema: Sendable, Result: Sendable {
    guard DoctorModel.availability().isAvailable else { return await fallback() }
    do {
        return try await withTimeout(seconds: aiCallTimeoutSeconds) {
            let session = LanguageModelSession(instructions: instructions)
            let schema = try await session.respond(
                to: prompt,
                generating: Schema.self,
                options: GenerationOptions(sampling: .greedy)   // deterministic decoding
            ).content
            return try map(schema)
        }
    } catch {
        return await fallback()
    }
}
