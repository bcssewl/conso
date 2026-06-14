import Foundation

/// Builds an `ExplainReport` from facts with no model involved. This is BOTH the no-AI
/// fallback AND the safety net when generation fails — so the popover always has a
/// usable, truthful explanation. Mirrors `DoctorFallback`'s role for the explainer.
public enum ExplainFallback {
    public static func report(from f: ExplainFacts) -> ExplainReport {
        let verdict = ExplainVerdict.from(f)

        var sentences: [String] = []

        // Lead clause: what it is (+ size when known).
        var lead = "\(f.title) is \(f.whatItIs)."
        if let bytes = f.sizeBytes, bytes > 0 {
            lead = "\(f.title) (\(ByteFormat.string(bytes))) is \(f.whatItIs)."
        }
        sentences.append(lead)

        // Safety clause, keyed off the deterministic verdict AND the action kind. The
        // action kind is what makes this context-aware: Clean items "remove", Software
        // items "update" (reversible via the app/Homebrew), Optimize "run a fix", Analyze
        // "move to the Trash". The old copy said "remove" everywhere, which was wrong on
        // the Software page (you update there, you don't remove).
        let verb = f.actionKind.verbGerund   // "Removing it" / "Updating" / "Running this fix" / "Moving it to the Trash"
        switch verdict {
        case .safe:
            switch f.actionKind {
            case .clean, .trash:
                if f.regenerates, let note = f.regeneratesNote {
                    sentences.append("\(verb) is safe — \(note).")
                } else if f.actionKind == .trash {
                    sentences.append("It's safe to move to the Trash, so you can restore it if you change your mind.")
                } else {
                    sentences.append("It's safe to remove.")
                }
            case .update:
                // Updates are NOT removals: frame the safety around updating + how to undo.
                sentences.append("Updating is safe and reversible — you can reinstall an earlier version through the app or Homebrew if needed.")
            case .fix:
                var s = "Running this fix is safe and reversible — \(f.regeneratesNote ?? "the affected items rebuild automatically")."
                if f.needsAdmin { s += " It needs your admin password." }
                sentences.append(s)
            }
        case .caution:
            switch f.actionKind {
            case .update:
                sentences.append("This update installs through Software Update and restarts your Mac — install it when you can spare a few minutes.")
            case .fix:
                var s = "This fix is more involved, so review it first."
                if !f.isReversible { s += " It can't be undone." }
                if f.needsAdmin { s += " It needs your admin password." }
                sentences.append(s)
            case .clean, .trash:
                if f.isReversible {
                    sentences.append("It moves to the Trash, so you can restore it — but review it first.")
                } else {
                    sentences.append("Removing it is permanent, so review it before you do.")
                }
            }
        case .recoveryData:
            var note = "This is recovery data, so it's left off by default — only remove it if you're sure you won't need it."
            if f.regenerates, let r = f.regeneratesNote { note = "This is recovery data — \(r). It's left off by default." }
            sentences.append(note)
        }

        return ExplainReport(title: f.title,
                             summary: sentences.joined(separator: " "),
                             verdict: verdict,
                             actionKind: f.actionKind,
                             isAIGenerated: false)
    }
}
