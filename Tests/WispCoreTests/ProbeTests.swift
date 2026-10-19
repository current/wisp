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

@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil))
func probeScan() {
    let scanner = ProcessScanner()
    var start = Date()
    _ = scanner.scan(network: false)
    print("first scan \(Date().timeIntervalSince(start) * 1000) ms")
    Thread.sleep(forTimeInterval: 1)
    var cpuStart = clock()
    start = Date()
    var table = ProcessTable()
    for _ in 0..<20 { table = scanner.scan(network: false) }
    print("steady scan \(Date().timeIntervalSince(start) * 1000 / 20) ms wall, \(Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1000 / 20) ms cpu")
    cpuStart = clock()
    Thread.sleep(forTimeInterval: 1)
    table = scanner.scan(network: false)
    print("processes \(table.processes.count) apps \(table.apps.count) machine \(table.machineCPU) unattributed \(table.unattributedCPU)")
    for app in table.apps.prefix(30) {
        print(String(format: "%-34@ %3d procs cpu %6.2f mem %6.0f MB %6.2f W", app.name as NSString, app.processCount, app.cpu * 100, Double(app.memory) / 1e6, app.watts))
    }
}
