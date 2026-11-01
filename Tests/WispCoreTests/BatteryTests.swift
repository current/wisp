import Foundation
import Testing
@testable import WispCore

@Suite struct BatteryTests {
    private func sample(_ minute: Int, _ level: Float, _ state: BatteryLogState) -> BatteryLogSample {
        BatteryLogSample(minute: minute, level: level, state: state)
    }

    @Test func desktopMacGetsNoBatteryCards() {
        let layout = PowerPageLayout(hasBattery: false, hasSystemPower: false)
        #expect(layout.title == "Power")
        #expect(!layout.cards.contains(.charge))
        #expect(!layout.cards.contains(.health))
        #expect(layout.cards.first == .chipPower)
        #expect(layout.cards.contains(.awake) && layout.cards.contains(.appEnergy))
        #expect(!layout.tiles.contains(.screenOn) && !layout.tiles.contains(.drain) && !layout.tiles.contains(.adapter))
        #expect(!layout.tiles.contains(.systemPower))
        #expect(!layout.batteryFilter)
        #expect(PowerPageLayout(hasBattery: false, hasSystemPower: true).tiles.first == .systemPower)
    }

    @Test func laptopGetsTheBatteryPage() {
        let layout = PowerPageLayout(hasBattery: true, hasSystemPower: true)
        #expect(layout.title == "Battery")
        #expect(layout.cards.first == .charge)
        #expect(layout.cards.contains(.health))
        #expect(layout.tiles.contains(.screenOn) && layout.tiles.contains(.drain))
        #expect(layout.batteryFilter)
    }

    @Test func logKeepsOnlyBatteryAndChargingMinutes() {
        let log = BatteryLog(url: nil)
        let start = Date(timeIntervalSince1970: 60 * 1_000_000)
        func at(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
        log.record(level: 50, charging: false, plugged: false, at: at(0))
        log.record(level: 49, charging: false, plugged: false, at: at(0).addingTimeInterval(20)) // same minute
        log.record(level: 49, charging: true, plugged: true, at: at(1))
        log.record(level: 80, charging: false, plugged: true, at: at(2))
        log.record(level: 80, charging: false, plugged: true, at: at(3))
        log.record(level: 80, charging: false, plugged: true, at: at(4))
        log.record(level: 79, charging: false, plugged: false, at: at(5))
        let samples = log.samples(since: 0)
        #expect(samples.map(\.minute) == [1_000_000, 1_000_001, 1_000_002, 1_000_005])
        #expect(samples.map(\.state) == [.onBattery, .charging, .pluggedIn, .onBattery])
    }

    @Test func logPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-battery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date(timeIntervalSince1970: 60 * 2_000_000)
        do {
            let log = BatteryLog(url: url)
            for minute in 0..<20 {
                log.record(level: Double(100 - minute), charging: false, plugged: false, at: start.addingTimeInterval(Double(minute) * 60))
            }
            // 15 are on disk; the rest are buffered until a flush.
            #expect(log.samples(since: 0).count == 20)
            log.flush()
        }
        let reopened = BatteryLog(url: url)
        let samples = reopened.samples(since: 2_000_010)
        #expect(samples.count == 10)
        #expect(samples.first?.level == 90)
    }

    @Test func seriesShadesChargingAndCarriesHeldLevel() {
        let samples = [
            sample(100, 60, .onBattery), sample(101, 59, .onBattery),
            sample(102, 59, .charging), sample(103, 62, .charging),
            sample(104, 80, .pluggedIn),
            // minutes 105...107 sat on the charger and logged nothing
            sample(108, 80, .onBattery),
        ]
        let series = BatteryStats.series(samples, endingAt: 109, minutes: 10, bucket: 1)
        #expect(series.levels.count == 10)
        #expect(series.levels[0] == 60 && series.levels[1] == 59)
        #expect(series.charging[2] && series.charging[3] && !series.charging[4])
        #expect(series.levels[5] == 80 && series.levels[7] == 80)
        #expect(series.levels[9].isNaN)
        #expect(series.step == 60)

        let buckets = BatteryStats.series(samples, endingAt: 109, minutes: 10, bucket: 5)
        #expect(buckets.levels == [80, 80])
        #expect(buckets.charging == [true, false])
    }

    @Test func drainAndScreenTime() {
        // 60 minutes on battery losing 10%, then a 2-hour gap (display asleep) and 30 more minutes.
        var samples = (0..<60).map { sample(1000 + $0, 90 - Float($0) / 6, .onBattery) }
        samples += (0..<30).map { sample(1180 + $0, 70 - Float($0) / 6, .onBattery) }
        samples.append(sample(1300, 50, .charging))
        #expect(BatteryStats.screenOnMinutes(samples, since: 0) == 90)
        #expect(BatteryStats.screenOnMinutes(samples, since: 1180) == 30)
        let drain = try! #require(BatteryStats.drainPerHour(samples, since: 0))
        // The drop across the gap is left out.
        #expect(abs(drain - 10) < 0.01)
        #expect(BatteryStats.drainPerHour(Array(samples.prefix(5)), since: 0) == nil)
        #expect(BatteryStats.onBatteryMinutes(samples, since: 1200).count == 10)
    }

    @Test func manufactureDateDecodesSmartBatteryFormat() {
        let raw = (2023 - 1980) << 9 | 7 << 5 | 14
        let date = try! #require(BatteryCollector.manufactureDate(raw))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2023 && parts.month == 7 && parts.day == 14)
        // Apple silicon packs store a vendor code here.
        #expect(BatteryCollector.manufactureDate(62_887_853_830_451) == nil)
    }

    @Test func appEnergyWeightsMinutesOnBattery() {
        let store = HistoryStore()
        let start = Date(timeIntervalSince1970: 60 * 3_000_000)
        // An app drawing 6 W for ten minutes, scanned every 10 s.
        for step in 0...60 {
            let app = AppGroup(id: "/Applications/Safari.app", name: "Safari", kind: .app, bundlePath: "/Applications/Safari.app",
                               bundleIdentifier: nil, pids: [1], cpu: 0.1, memory: 1, watts: 6, diskReadPerSecond: 0,
                               diskWritePerSecond: 0, networkInPerSecond: 0, networkOutPerSecond: 0, unreadable: 0)
            store.record(table: ProcessTable(date: start.addingTimeInterval(Double(step) * 10), interval: 10, apps: [app]))
        }
        let now = start.addingTimeInterval(600)
        let all = store.appEnergy(since: start, now: now)
        #expect(all.count == 1)
        #expect(abs(all[0].wh - 1.0) < 0.05)
        // Only the first five minutes on battery.
        let first = HistoryStore.minute(start)
        let battery = store.appEnergy(since: start, now: now, minuteWeight: { $0 < first + 5 ? 1 : 0 })
        #expect(abs(battery[0].wh - 0.5) < 0.01)
    }
}
