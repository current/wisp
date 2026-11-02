import Foundation

/// The charge history bucketed for a chart: one level per bucket (NaN where nothing
/// was logged) and whether the Mac was charging in it.
public struct ChargeSeries: Equatable, Sendable {
    public var levels: [Float]
    public var charging: [Bool]
    /// Seconds per bucket.
    public var step: Double
}

/// Figures derived from the battery log. Pure functions over samples, so they can be tested.
public enum BatteryStats {
    /// `minutes` of history ending with minute `end`, in buckets of `bucket` minutes.
    /// While the Mac sat on its charger without charging nothing is logged; the level
    /// it stopped at is carried across that stretch, so the line does not break.
    public static func series(_ samples: [BatteryLogSample], endingAt end: Int, minutes: Int, bucket: Int) -> ChargeSeries {
        let bucket = max(1, bucket)
        let count = max(1, minutes / bucket)
        let start = end - count * bucket + 1
        var levels = [Float](repeating: .nan, count: count)
        var charging = [Bool](repeating: false, count: count)
        var held: Float?
        var index = 0
        let sorted = samples.sorted { $0.minute < $1.minute }
        // The last sample before the window decides whether the start is a held stretch.
        for sample in sorted where sample.minute < start { held = sample.state == .pluggedIn ? sample.level : nil }
        for slot in 0..<count {
            let from = start + slot * bucket, to = from + bucket
            while index < sorted.count, sorted[index].minute < from { index += 1 }
            var last: BatteryLogSample?
            while index < sorted.count, sorted[index].minute < to {
                let sample = sorted[index]
                if sample.state == .charging { charging[slot] = true }
                last = sample
                index += 1
            }
            if let last {
                levels[slot] = last.level
                held = last.state == .pluggedIn ? last.level : nil
            } else if let held {
                levels[slot] = held
            }
        }
        return ChargeSeries(levels: levels, charging: charging, step: Double(bucket) * 60)
    }

    /// Minutes on battery with the display on since `from`. The monitor pauses while
    /// the display sleeps, so every logged minute on battery is a minute of screen time.
    public static func screenOnMinutes(_ samples: [BatteryLogSample], since from: Int) -> Int {
        samples.lazy.filter { $0.minute >= from && $0.state == .onBattery }.count
    }

    /// Average drain on battery in percent per hour since `from`: the drops between
    /// neighbouring minutes on battery over the time on battery. Nil with under ten minutes.
    public static func drainPerHour(_ samples: [BatteryLogSample], since from: Int) -> Double? {
        let onBattery = samples.filter { $0.minute >= from && $0.state == .onBattery }.sorted { $0.minute < $1.minute }
        guard onBattery.count >= 10 else { return nil }
        var dropped = 0.0
        var minutes = 0
        for (a, b) in zip(onBattery, onBattery.dropFirst()) {
            let gap = b.minute - a.minute
            // A longer gap is the display asleep or the Mac off; its drain is not screen time.
            guard gap <= 3 else { continue }
            minutes += gap
            dropped += max(0, Double(a.level - b.level))
        }
        guard minutes >= 10 else { return nil }
        return dropped / (Double(minutes) / 60)
    }

    /// The minutes on battery since `from`, for weighting per-app energy.
    public static func onBatteryMinutes(_ samples: [BatteryLogSample], since from: Int) -> Set<Int> {
        Set(samples.lazy.filter { $0.minute >= from && $0.state == .onBattery }.map(\.minute))
    }
}

/// Which cards the Power page shows. A Mac without a battery gets no battery cards
/// at all rather than empty ones.
public enum PowerCard: String, CaseIterable, Sendable {
    /// Hero: charge history with charging shaded.
    case charge
    /// Hero on Macs without a battery: chip power over time.
    case chipPower
    case health
    case awake
    case appEnergy
    case liveApps
}

public enum PowerTile: String, CaseIterable, Sendable {
    case systemPower, adapter, chip, lowPower, screenOn, drain, mostPower
}

public struct PowerPageLayout: Equatable, Sendable {
    public var title: String
    public var cards: [PowerCard]
    public var tiles: [PowerTile]
    /// Whether the per-app energy card can filter to time on battery.
    public var batteryFilter: Bool

    public init(hasBattery: Bool, hasSystemPower: Bool) {
        if hasBattery {
            title = "Battery"
            cards = [.charge, .health, .awake, .appEnergy, .liveApps]
            tiles = [.systemPower, .adapter, .chip, .lowPower, .screenOn, .drain]
            batteryFilter = true
        } else {
            title = "Power"
            cards = [.chipPower, .awake, .appEnergy, .liveApps]
            tiles = (hasSystemPower ? [.systemPower] : []) + [.chip, .lowPower, .mostPower]
            batteryFilter = false
        }
    }
}

/// Whether this Mac has an internal battery. Asked once; a battery does not come and go.
public enum MachinePower {
    /// WISP_NO_BATTERY shows the page as a Mac without a battery would, for screenshots.
    public static let hasBattery: Bool = ProcessInfo.processInfo.environment["WISP_NO_BATTERY"] == nil
        && BatteryCollector.internalSource() != nil

    /// Level and power state from the power source list, without registry reads.
    public static func quickBattery() -> (percent: Double, charging: Bool, plugged: Bool)? { BatteryCollector.quick() }
}
