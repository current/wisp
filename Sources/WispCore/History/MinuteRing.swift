import Foundation

/// One value per wall-clock minute for the last `capacity` minutes. Missing minutes
/// are NaN, so a gap in sampling shows as a gap rather than a zero.
public struct MinuteRing: Sendable {
    public let capacity: Int
    private var values: [Float]
    /// Minute number (seconds since 1970 / 60) of the newest slot.
    private(set) var newest: Int = 0

    public init(capacity: Int = 1440) {
        self.capacity = capacity
        values = [Float](repeating: .nan, count: capacity)
    }

    public mutating func set(_ value: Float, minute: Int) {
        if newest == 0 { newest = minute }
        if minute > newest {
            let gap = min(minute - newest, capacity)
            for step in 1...gap { values[(newest + step) % capacity] = .nan }
            newest = minute
        } else if newest - minute >= capacity {
            return
        }
        values[minute % capacity] = value
    }

    public func value(at minute: Int) -> Float {
        guard newest != 0, minute <= newest, newest - minute < capacity else { return .nan }
        return values[minute % capacity]
    }

    /// The last `count` minutes ending at `end`, oldest first.
    public func values(last count: Int, endingAt end: Int) -> [Float] {
        let n = min(count, capacity)
        return (0..<n).map { value(at: end - n + 1 + $0) }
    }

    public var isEmpty: Bool {
        newest == 0 || !values.contains { !$0.isNaN }
    }
}

/// Fixed-size ring of the most recent samples, for sparklines.
public struct RecentRing: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    public mutating func append(_ value: Float) {
        storage[head] = value
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Oldest first.
    public var values: [Float] {
        (0..<count).map { storage[(head - count + $0 + capacity) % capacity] }
    }

    public var last: Float? { count == 0 ? nil : storage[(head - 1 + capacity) % capacity] }
}
