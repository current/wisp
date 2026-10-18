import Foundation
import Testing
@testable import WispCore

@Suite struct SystemCollectorTests {
    @Test func cpuNeedsABaselineThenReportsFractions() throws {
        let cpu = CPUCollector()
        #expect(cpu.sample(perCore: true) == nil)
        Thread.sleep(forTimeInterval: 0.2)
        let reading = try #require(cpu.sample(perCore: true))
        #expect((0...1).contains(reading.total))
        #expect(reading.cores.count == ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test func memoryAddsUp() throws {
        let reading = try #require(MemoryCollector().sample())
        #expect(reading.total == ProcessInfo.processInfo.physicalMemory)
        #expect(reading.used > 0 && reading.used < reading.total)
    }

    @Test func networkSkipsTunnels() {
        #expect(!NetworkCollector.countsInterface("lo0"))
        #expect(!NetworkCollector.countsInterface("utun3"))
        #expect(!NetworkCollector.countsInterface("awdl0"))
        #expect(NetworkCollector.countsInterface("en0"))
    }

    @Test func networkAndDiskReadCounters() throws {
        let net = try #require(NetworkCollector().sample())
        #expect(net.totalReceived > 0)
        let disk = try #require(DiskCollector().sample())
        #expect(disk.volumeTotal > 0)
    }

    @Test func spreadKeepsEnds() {
        #expect(ThermalCollector.spread(Array(0..<10), limit: 3) == [0, 5, 9])
        #expect(ThermalCollector.spread([1, 2], limit: 4) == [1, 2])
    }

    @Test func smcCodesRoundTrip() {
        #expect(SMC.string(SMC.code("TC0P")) == "TC0P")
    }
}
