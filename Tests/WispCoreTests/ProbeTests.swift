import Foundation
import Testing
@testable import WispCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil))
func probeHardware() {
    var start = Date()
    let thermal = ThermalCollector()
    let t = thermal.sample(detail: true)
    print("thermal first \(Date().timeIntervalSince(start) * 1000) ms cpu \(t.cpuCelsius ?? -1) gpu \(t.gpuCelsius ?? -1) sensors \(t.sensors.count) fans \(t.fans)")
    start = Date()
    _ = thermal.sample(detail: true)
    print("thermal steady \(Date().timeIntervalSince(start) * 1000) ms")
    let gpu = GPUCollector()
    _ = gpu.sample()
    Thread.sleep(forTimeInterval: 0.3)
    print("gpu", gpu.sample() as Any)
    print("battery", BatteryCollector().sample() as Any)
    print("memory", MemoryCollector().sample() as Any)
}
