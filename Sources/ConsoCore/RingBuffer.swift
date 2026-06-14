import Foundation

/// A fixed-capacity buffer that keeps the most recent `capacity` elements.
/// Used for the 60-second metric history shown in Status sparklines and the HUD.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Elements in insertion order (oldest first).
    public var values: [Element] { storage }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count >= capacity }
    public var last: Element? { storage.last }
}
