import Foundation
import Testing
@testable import WispCore

@Suite struct HistoryTests {
    @Test func minuteRingKeepsGapsAsNaN() {
        var ring = MinuteRing(capacity: 10)
        ring.set(1, minute: 100)
        ring.set(2, minute: 101)
        ring.set(5, minute: 104)
        let values = ring.values(last: 5, endingAt: 104)
        #expect(values[0] == 1 && values[1] == 2 && values[4] == 5)
        #expect(values[2].isNaN && values[3].isNaN)
        // Anything older than the capacity has fallen off.
        ring.set(9, minute: 120)
        #expect(ring.value(at: 104).isNaN)
        #expect(ring.value(at: 120) == 9)
    }

    @Test func totalsUseTheArchiveBeforeThisRunBegan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-total-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try #require(HourlyArchive(url: url))
        let midnight = Date(timeIntervalSince1970: 3600 * 500_000)
        // Two earlier hours at 100 B/s, written by a previous run.
        archive.write(hour: 500_000, apps: [], system: [.networkIn: 100])
        archive.write(hour: 500_001, apps: [], system: [.networkIn: 100])
        let store = HistoryStore(archive: archive)
        // This run starts at 02:00 and records two minutes at 10 B/s.
        for second in stride(from: 0.0, to: 180, by: 10) {
            var snapshot = SystemSnapshot(date: midnight.addingTimeInterval(7200 + second))
            snapshot.network = NetworkReading(receivedBytesPerSecond: 10, sentBytesPerSecond: 0, totalReceived: 0, totalSent: 0)
            store.record(system: snapshot, interval: 10)
        }
        let total = store.total(.networkIn, since: midnight, now: midnight.addingTimeInterval(7200 + 170))
        #expect(total == 100 * 7200 + 10 * 120)
    }

    @Test func recentRingIsOldestFirst() {
        var ring = RecentRing(capacity: 3)
        for value in [1, 2, 3, 4] as [Float] { ring.append(value) }
        #expect(ring.values == [2, 3, 4])
        #expect(ring.last == 4)
    }

    static func table(at date: Date, cpu: Double, memory: UInt64, interval: Double = 10) -> ProcessTable {
        let app = AppGroup(id: "a", name: "A", kind: .app, bundlePath: nil, bundleIdentifier: nil, pids: [1], cpu: cpu,
                           memory: memory, watts: 1, diskReadPerSecond: 0, diskWritePerSecond: 100,
                           networkInPerSecond: 0, networkOutPerSecond: 0, unreadable: 0)
        return ProcessTable(date: date, interval: interval, apps: [app])
    }

    @Test func appMinutesAverageCPUAndKeepPeakMemory() {
        let store = HistoryStore()
        let base = Date(timeIntervalSince1970: 60 * 1_000_000)
        store.record(table: Self.table(at: base.addingTimeInterval(10), cpu: 1, memory: 100))
        store.record(table: Self.table(at: base.addingTimeInterval(20), cpu: 0, memory: 300))
        store.record(table: Self.table(at: base.addingTimeInterval(70), cpu: 2, memory: 50))
        let cpu = store.app("a", .cpu, minutes: 1, now: base.addingTimeInterval(70))
        #expect(cpu == [0.5])
        #expect(store.app("a", .memory, minutes: 1, now: base.addingTimeInterval(70)) == [300])
        let summary = store.summaries(minutes: 5, now: base.addingTimeInterval(70))
        #expect(summary.first?.energyWh == 1.0 / 60)
    }

    @Test func archiveRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try #require(HourlyArchive(url: url))
        let row = HourlyArchive.Row(hour: 500_000, app: "a", name: "A", cpu: 0.5, memoryPeak: 1e9, energyWh: 2,
                                    diskBytes: 3, networkBytes: 4, minutes: 60)
        archive.write(hour: 500_000, apps: [row], system: [.cpu: 0.25])
        archive.write(hour: 500_000, apps: [row], system: [.cpu: 0.25])
        #expect(archive.rows(since: 0) == [row])
        #expect(archive.rows(app: "b", since: 0).isEmpty)
        #expect(archive.system(.cpu, since: 0).map(\.value) == [0.25])
    }

    @Test func storeArchivesFinishedHours() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-test-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try #require(HourlyArchive(url: url))
        let store = HistoryStore(archive: archive)
        let hourStart = Date(timeIntervalSince1970: 3600 * 480_000)
        for minute in 0..<61 {
            store.record(table: Self.table(at: hourStart.addingTimeInterval(Double(minute) * 60 + 30), cpu: 1, memory: 10, interval: 60))
        }
        let rows = archive.rows(since: 0)
        #expect(rows.count == 1)
        #expect(rows.first?.hour == 480_000)
        #expect(rows.first?.minutes == 60)
        #expect(abs((rows.first?.cpu ?? 0) - 1) < 1e-6)
    }
}

@Suite struct AlertTests {
    @Test func cpuMustBeSustained() {
        var rules = AlertRules()
        rules.cpuMinutes = 2
        let engine = AlertEngine(rules: rules)
        let start = Date()
        #expect(engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start).isEmpty)
        #expect(engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start + 60).isEmpty)
        let fired = engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start + 121)
        #expect(fired.map(\.kind) == [.cpu])
        // Cooldown.
        #expect(engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start + 200).isEmpty)
    }

    @Test func quietPassResetsTheClock() {
        var rules = AlertRules()
        rules.cpuMinutes = 2
        let engine = AlertEngine(rules: rules)
        let start = Date()
        _ = engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start)
        _ = engine.evaluate(HistoryTests.table(at: start, cpu: 0.1, memory: 1), history: nil, now: start + 60)
        #expect(engine.evaluate(HistoryTests.table(at: start, cpu: 1.2, memory: 1), history: nil, now: start + 130).isEmpty)
    }

    @Test func memoryGrowthNeedsATrend() {
        let steady = (0..<30).map { Float(1e9 + Double($0) * 5e7) }
        #expect(AlertEngine.isGrowing(steady, by: 1e9))
        var spiky = [Float](repeating: 1e9, count: 30)
        spiky[29] = 3e9
        for index in stride(from: 1, to: 28, by: 2) { spiky[index] = 2e9 }
        #expect(!AlertEngine.isGrowing(spiky, by: 1e9))
        #expect(!AlertEngine.isGrowing([1e9, 3e9], by: 1e9))
    }
}
