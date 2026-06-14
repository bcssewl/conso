import Foundation

// MARK: - APFS snapshot name parsing (pure, TDD'd)

/// Pure helpers for the "is this a real local-snapshot timestamp" decision. The scanner
/// lists snapshots by NAME (e.g. `com.apple.TimeMachine.2026-06-14-101500.local`); the
/// executor must extract the timestamp to pass to `tmutil deletelocalsnapshots <date>`.
/// Kept separate from any I/O so the extraction + strict validation can be unit-tested
/// against malformed names and injection attempts.
///
/// This is the FIRST of two validations — the privileged helper re-validates the SAME
/// regex server-side and never trusts the caller (the app could be compromised). A
/// snapshot name yields a date ONLY when the timestamp matches exactly
/// `^\d{4}-\d{2}-\d{2}-\d{6}$`, so nothing but a literal timestamp can ever reach `tmutil`.
public enum SnapshotName {
    /// The one timestamp shape conso will ever delete: `YYYY-MM-DD-HHMMSS`. Anchored so a
    /// trailing injection (`2026-06-14-101500; rm -rf /`) or extra segments never match.
    private static let dateRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#)

    /// True iff `s` is exactly a `YYYY-MM-DD-HHMMSS` timestamp — nothing more, nothing less.
    /// Requires the match to span the WHOLE string (NSRegularExpression's `$` would otherwise
    /// match before a trailing newline, e.g. "2026-06-14-101500\n").
    public static func isValidDate(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = dateRegex.firstMatch(in: s, options: [.anchored], range: range) else { return false }
        return m.range == range
    }

    /// Extracts the timestamp from a snapshot name of the form
    /// `com.apple.TimeMachine.<ts>.local`, returning `<ts>` ONLY when it is a valid
    /// `YYYY-MM-DD-HHMMSS` timestamp; nil for any malformed / unexpected name. The check is
    /// strict so an attacker-supplied name can never produce anything but a literal date.
    public static func date(from name: String) -> String? {
        // Expect the fixed prefix + suffix; the middle must be a valid timestamp.
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let ts = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard isValidDate(ts) else { return nil }
        return ts
    }
}
