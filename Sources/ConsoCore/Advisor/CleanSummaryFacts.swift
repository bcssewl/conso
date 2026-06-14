import Foundation

/// The aggregated, grounded facts about a pending clean, handed to the summarizer. This is
/// the ONLY thing the model sees: per-category totals, the few biggest items, the overall
/// size/count and a deterministic safety verdict conso computed from `SafetyCatalog`. The
/// raw 100+ target list is deliberately NOT here — long name lists trip Apple's on-device
/// safety guardrails into silent fallback and blow the ~4k-token budget. The model only
/// ever rephrases these aggregates; it never decides what is deleted or invents a number.
public struct CleanSummaryFacts: Sendable, Equatable {
    /// One per-category line: which category, its total bytes, and how many items it holds.
    public struct CategoryBreakdown: Sendable, Equatable {
        public let category: CleanCategory
        public let bytes: UInt64
        public let count: Int
        public init(category: CleanCategory, bytes: UInt64, count: Int) {
            self.category = category
            self.bytes = bytes
            self.count = count
        }
    }

    /// One of the few biggest individual items — a short display name and its size. Paths
    /// are deliberately omitted (privacy + token budget + guardrail safety).
    public struct TopItem: Sendable, Equatable {
        public let name: String
        public let bytes: UInt64
        public init(name: String, bytes: UInt64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// Total bytes that would move to the Trash across every category.
    public let totalBytes: UInt64
    /// Total number of items.
    public let totalCount: Int
    /// Per-category breakdown, sorted largest-first.
    public let categories: [CategoryBreakdown]
    /// The ~5 biggest individual items, largest-first.
    public let topItems: [TopItem]
    /// True when EVERY item in the clean is reversible (moves to the Trash / regenerates) —
    /// i.e. nothing here is permanent. Derived from `SafetyCatalog`, never from the model.
    public let isFullyReversible: Bool
    /// True when ANY item is the user's recovery/safety data (snapshots, device backups,
    /// mail attachments). Quick Clean never includes these, so it's always false there.
    public let includesRecoveryData: Bool
    /// True when this is a Quick Clean (the conservative caches/dev/logs/trash subset).
    public let isQuickClean: Bool

    public init(totalBytes: UInt64, totalCount: Int, categories: [CategoryBreakdown],
                topItems: [TopItem], isFullyReversible: Bool,
                includesRecoveryData: Bool, isQuickClean: Bool) {
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.categories = categories
        self.topItems = topItems
        self.isFullyReversible = isFullyReversible
        self.includesRecoveryData = includesRecoveryData
        self.isQuickClean = isQuickClean
    }

    /// The biggest category by bytes, if any (the headline contributor).
    public var largestCategory: CategoryBreakdown? { categories.first }
}

public extension CleanSummaryFacts {
    /// Builds the aggregated facts from the concrete targets of a pending clean. This is the
    /// deterministic boundary: it folds the raw target list into per-category totals + the
    /// top items, and consults `SafetyCatalog` to decide reversibility/recovery-data — so
    /// the model never sees (or judges) the raw list. `isQuickClean` carries the preview kind.
    ///
    /// `topItemCount` caps how many individual items are surfaced (default 5) to stay well
    /// inside the on-device token budget and the safety guardrails.
    static func from(targets: [CleanTarget], isQuickClean: Bool,
                     topItemCount: Int = 5) -> CleanSummaryFacts {
        // Per-category aggregation, then sort largest-first.
        var bytesByCat: [CleanCategory: UInt64] = [:]
        var countByCat: [CleanCategory: Int] = [:]
        for t in targets {
            bytesByCat[t.category, default: 0] += t.bytes
            countByCat[t.category, default: 0] += 1
        }
        let categories = bytesByCat.keys
            .map { CategoryBreakdown(category: $0, bytes: bytesByCat[$0] ?? 0,
                                     count: countByCat[$0] ?? 0) }
            .sorted { lhs, rhs in
                // Bytes desc; ties broken by a stable catalog order so output is deterministic.
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return catalogIndex(lhs.category) < catalogIndex(rhs.category)
            }

        // Top individual items by size — names only, never paths. Select the top-N with the
        // shared comparator; for large lists avoid sorting the whole array.
        let n = max(0, topItemCount)
        let top = topTargets(from: targets, count: n)
        let topItems = top.map { TopItem(name: PathName.leaf($0.path), bytes: $0.bytes) }

        // Safety, from the deterministic catalog — every present category's facts.
        let presentCategories = Set(targets.map(\.category))
        let isFullyReversible = !presentCategories.isEmpty && presentCategories.allSatisfy {
            SafetyCatalog.facts(for: .cleanCategory($0)).isReversible
        }
        let includesRecoveryData = presentCategories.contains {
            SafetyCatalog.facts(for: .cleanCategory($0)).isRecoveryData
        }

        return CleanSummaryFacts(
            totalBytes: targets.reduce(0) { $0 + $1.bytes },
            totalCount: targets.count,
            categories: categories,
            topItems: Array(topItems),
            isFullyReversible: isFullyReversible,
            includesRecoveryData: includesRecoveryData,
            isQuickClean: isQuickClean)
    }

    /// The `count` biggest targets (largest-first, path tiebreak), without fully sorting the
    /// whole array when it's large. Output is identical to `targets.sortedBySizeThenPath()
    /// .prefix(count)` but only does the full sort for small lists; otherwise it does a
    /// bounded insertion-select over the same comparator.
    private static func topTargets(from targets: [CleanTarget], count: Int) -> [CleanTarget] {
        guard count > 0 else { return [] }
        // Small list (or N close to the count): a single sort is cheapest and clearest.
        if targets.count <= 64 || count >= targets.count {
            return Array(targets.sortedBySizeThenPath().prefix(count))
        }
        // Large list: keep only the running top-`count` via a bounded insertion.
        var top: [CleanTarget] = []
        top.reserveCapacity(count)
        for t in targets {
            // Skip anything that can't beat the current weakest once the buffer is full.
            if top.count == count, !CleanTarget.bySizeThenPath(t, top[count - 1]) { continue }
            // Find the insertion point under the shared ordering and splice in.
            var lo = 0, hi = top.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if CleanTarget.bySizeThenPath(t, top[mid]) { hi = mid } else { lo = mid + 1 }
            }
            top.insert(t, at: lo)
            if top.count > count { top.removeLast() }
        }
        return top
    }

    /// Catalog order index for a stable tiebreak (mirrors `CleanCategory.allCases` order).
    private static func catalogIndex(_ c: CleanCategory) -> Int {
        CleanCategory.allCases.firstIndex(of: c) ?? Int.max
    }
}
