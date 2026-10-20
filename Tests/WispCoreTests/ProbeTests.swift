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

@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil))
func probePowerAndNetwork() {
    let power = PowerCollector()
    _ = power.sample()
    let network = AppNetwork()
    _ = network?.rates()
    Thread.sleep(forTimeInterval: 2)
    print("power", power.sample() as Any)
    let cpuStart = clock()
    let rates = network?.rates() ?? [:]
    print("network query \(Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1000) ms cpu, \(rates.count) processes")
    for (pid, rate) in rates.sorted(by: { $0.value.received + $0.value.sent > $1.value.received + $1.value.sent }).prefix(5) {
        print(pid, Format.rate(rate.received), Format.rate(rate.sent))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil))
func probeMonitorLoop() {
    let monitor = Monitor()
    var passes = 0
    monitor.processObserver = { table, _ in
        passes += 1
        print("pass \(passes): \(table.apps.count) apps, network \(table.networkMeasured), system power \(monitor.currentSystem.power as Any)")
    }
    monitor.update(activity: .window, plan: SamplingPlan(demand: [.system, .processes, .appNetwork], interval: 1))
    monitor.start()
    Thread.sleep(forTimeInterval: 4)
    monitor.stop()
    print("passes", passes)
}
