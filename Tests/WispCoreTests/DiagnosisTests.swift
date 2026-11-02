import Foundation
import Testing
@testable import WispCore

@Suite struct DiagnosisTests {
    static let gb: UInt64 = 1 << 30

    static func app(_ id: String, _ name: String, kind: AppKind = .app, cpu: Double = 0, memory: UInt64 = 0, disk: Double = 0,
                    bundle: String? = "com.example.app", pids: [Int32] = [100]) -> AppGroup {
        AppGroup(id: id, name: name, kind: kind, bundlePath: kind == .app ? id : nil, bundleIdentifier: kind == .app ? bundle : nil,
                 pids: pids, cpu: cpu, memory: memory, watts: 0, diskReadPerSecond: 0, diskWritePerSecond: disk,
                 networkInPerSecond: 0, networkOutPerSecond: 0, unreadable: 0)
    }

    static func process(_ pid: Int32, _ name: String, group: String = AppGrouping.systemID, cpu: Double = 0, readable: Bool = true) -> ProcessRow {
        ProcessRow(pid: pid, ppid: 1, uid: 501, name: name, path: nil, responsiblePID: pid, groupID: group, readable: readable,
                   cpu: cpu, memory: 0, watts: 0, diskReadPerSecond: 0, diskWritePerSecond: 0, networkInPerSecond: 0,
                   networkOutPerSecond: 0, cpuTime: 0, startDate: nil)
    }

    /// A quiet 16-core, 36 GB Mac with 300 GB free.
    static func quiet(cpu: Double = 0.12, pressure: MemoryPressure = .normal, compressed: UInt64 = 1 << 30,
                      free: UInt64 = 300_000_000_000) -> SystemSnapshot {
        var s = SystemSnapshot(date: Date(timeIntervalSince1970: 1_800_000_000))
        s.cpu = CPUReading(user: cpu * 0.7, system: cpu * 0.3, performanceCores: 12, efficiencyCores: 4)
        s.memory = MemoryReading(total: 36 * gb, app: 14 * gb, wired: 3 * gb, compressed: compressed, cached: 4 * gb, free: 6 * gb,
                                 swapUsed: 0, swapTotal: 0, pressure: pressure)
        s.disk = DiskReading(readBytesPerSecond: 1_000_000, writeBytesPerSecond: 1_000_000, volumeTotal: 1_000_000_000_000, volumeFree: free)
        return s
    }

    @Test func aQuietMacSaysSoWithTheKeyNumbers() {
        let table = ProcessTable(apps: [Self.app("/Applications/Safari.app", "Safari", cpu: 0.3, memory: 2 * Self.gb)],
                                 machineCPU: 1.9, coreCount: 16)
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(), table: table, swapInPerSecond: 0, swapOutPerSecond: 0))
        #expect(result.isHealthy)
        #expect(result.summary == "Nothing is slowing this Mac down")
        #expect(result.numbers == ["CPU 12%", "Memory pressure normal", "300 GB free"])
    }

    @Test func memoryNamesTheHolderAndTheSwapRate() {
        var system = Self.quiet(pressure: .warning, compressed: 8 * Self.gb)
        system.memory?.swapUsed = 6 * Self.gb
        let lima = Self.app("tool:/opt/homebrew/bin/limactl", "limactl", kind: .tool, cpu: 0.4, memory: 20 * Self.gb)
        let table = ProcessTable(apps: [lima, Self.app("/Applications/Safari.app", "Safari", memory: 2 * Self.gb)], coreCount: 16)
        // 5 MB/s of swap traffic is 300 MB a minute.
        let result = Diagnoser.diagnose(DiagnosisInput(system: system, table: table, swapInPerSecond: 2_621_440, swapOutPerSecond: 2_621_440))
        let first = try! #require(result.findings.first)
        #expect(first.kind == .memory)
        #expect(first.title == "limactl is holding 20 GB and macOS is swapping 300 MB a minute")
        // A command-line tool has no app to quit normally; its drawer opens instead.
        #expect(first.action == .showApp(lima.id))
    }

    @Test func aRegularAppHoggingMemoryCanBeQuit() {
        let chrome = Self.app("/Applications/Google Chrome.app", "Google Chrome", memory: 14 * Self.gb)
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(pressure: .critical), table: ProcessTable(apps: [chrome], coreCount: 16)))
        #expect(result.findings.first?.title == "Google Chrome is holding 14 GB and memory pressure is critical")
        #expect(result.findings.first?.action == .quitApp(chrome.id))
    }

    @Test func saturatedCPUNamesTheBusiestApps() {
        let xcode = Self.app("/Applications/Xcode.app", "Xcode", cpu: 9.6)
        let swift = Self.app("tool:/usr/bin/swift-frontend", "swift-frontend", kind: .tool, cpu: 4.1)
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(cpu: 0.96), table: ProcessTable(apps: [swift, xcode], coreCount: 16)))
        let first = try! #require(result.findings.first)
        #expect(first.title == "CPU is at 96%: Xcode is using 9.6 cores")
        #expect(first.detail == "Then swift-frontend with 4.1 cores")
        #expect(first.action == .showApp(xcode.id))
    }

    @Test func anAppHoldingACoreForMinutesIsFoundFromHistory() {
        let node = Self.app("tool:/opt/homebrew/bin/node", "node", kind: .tool, cpu: 2.0)
        // Idle, then two cores for the last 14 minutes, the current minute not in yet.
        let minutes: [Float] = Array(repeating: 0.1, count: 15) + Array(repeating: 2.0, count: 14) + [.nan]
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(cpu: 0.3), table: ProcessTable(apps: [node], coreCount: 16),
                                                       recentAppCPU: [node.id: minutes]))
        #expect(result.findings.first?.title == "node has held 2.0 cores for 14 min")
        // A short burst is not "holding".
        let short: [Float] = Array(repeating: 0.1, count: 27) + [2, 2, 2]
        let quiet = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(cpu: 0.3), table: ProcessTable(apps: [node], coreCount: 16),
                                                      recentAppCPU: [node.id: short]))
        #expect(quiet.isHealthy)
    }

    @Test func throttlingDiskSpaceAndHeavyWritesAreRanked() {
        let backup = Self.app("/Applications/Arq.app", "Arq", disk: 180_000_000)
        let input = DiagnosisInput(system: Self.quiet(free: 12_000_000_000), table: ProcessTable(apps: [backup], coreCount: 16),
                                   thermalState: .serious, cpuSpeedLimit: 70)
        let result = Diagnoser.diagnose(input)
        #expect(result.findings.map(\.kind) == [.thermal, .diskSpace, .diskActivity])
        #expect(result.findings[0].title == "macOS has capped the CPU at 70% speed to cool it down")
        #expect(result.findings[1].title == "Only 12 GB free on the startup disk")
        #expect(result.findings[1].action == .openStorage)
        #expect(result.findings[2].title == "Arq is writing 180 MB/s to disk")
        // Low space by share alone: 8% of a 1 TB disk is still more than 20 GB but under 10%.
        let share = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(free: 80_000_000_000), table: ProcessTable(coreCount: 16)))
        #expect(share.findings.map(\.kind) == [.diskSpace])
    }

    @Test func spotlightPhotosAndUnmeasuredSystemWork() {
        let processes = [Self.process(10, "mdworker_shared", cpu: 0.6), Self.process(11, "mdworker_shared", cpu: 0.5),
                         Self.process(12, "mds_stores", readable: false), Self.process(13, "photoanalysisd", cpu: 1.2)]
        // The machine is using 5 cores, 2.3 of them readable.
        let table = ProcessTable(processes: processes, apps: [Self.app(AppGrouping.systemID, "macOS", kind: .system, cpu: 2.3, pids: [10, 11, 12, 13])],
                                 machineCPU: 5.0, coreCount: 16)
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(cpu: 0.31), table: table))
        let titles = result.findings.map(\.title)
        #expect(titles.contains("Spotlight is indexing: 2 mdworker processes are using 1.1 cores"))
        #expect(titles.contains("Photos is analysing your library: photoanalysisd is using 1.2 cores"))
        #expect(titles.contains("macOS processes Wisp cannot measure are using 2.7 cores"))
        // With a backup mounted, the unmeasured work is put down to Time Machine.
        let backing = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(cpu: 0.31), table: table, timeMachineRunning: true))
        #expect(backing.findings.contains { $0.kind == .timeMachine && $0.detail.contains("2.7 cores") })
        #expect(!backing.findings.contains { $0.kind == .unmeasured })
    }

    @Test func gpuAndWindowServer() {
        var system = Self.quiet()
        system.gpu = GPUReading(name: "Apple M3 Max", utilization: 0.97)
        let processes = [Self.process(441, "WindowServer", group: "windowserver", readable: false),
                         Self.process(900, "Blender", group: "/Applications/Blender.app")]
        let table = ProcessTable(processes: processes, apps: [Self.app("/Applications/Blender.app", "Blender", cpu: 1, pids: [900]),
                                                              Self.app("windowserver", "WindowServer", kind: .system, pids: [441])], coreCount: 16)
        let result = Diagnoser.diagnose(DiagnosisInput(system: system, table: table, gpuShares: [441: 0.45, 900: 0.5]))
        #expect(result.findings.map(\.title).contains("GPU is at 97%: Blender is using 50% of it"))
        #expect(result.findings.map(\.title).contains("WindowServer is using 45% of the GPU to draw the screen"))
    }

    @Test func manyCodingAgents() {
        let agents = (0..<5).map { CodingAgent(pid: Int32(200 + $0), kind: "Claude Code", folder: nil, startDate: nil, processes: [],
                                               cpu: 0.5, memory: 2 * Self.gb, host: nil) }
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(), table: ProcessTable(coreCount: 16), agents: agents,
                                                       devServers: 3, containers: 2))
        #expect(result.findings.first?.title == "5 coding agents are running, using 2.5 cores and 10 GB together")
        #expect(result.findings.first?.detail == "Also running: 3 dev servers, 2 containers")
        #expect(result.findings.first?.action == .openPage("agents"))
    }

    @Test func findingsAreRankedAndCapped() {
        var system = Self.quiet(cpu: 0.97, pressure: .critical, free: 3_000_000_000)
        system.gpu = GPUReading(name: "GPU", utilization: 0.95)
        let apps = [Self.app("/Applications/A.app", "A", cpu: 12, memory: 20 * Self.gb, disk: 400_000_000)]
        let result = Diagnoser.diagnose(DiagnosisInput(system: system, table: ProcessTable(apps: apps, machineCPU: 15.5, coreCount: 16),
                                                       swapInPerSecond: 50_000_000, thermalState: .critical,
                                                       agents: (0..<6).map { CodingAgent(pid: Int32($0), kind: "Codex", processes: [], cpu: 0.1, memory: 0) }))
        #expect(result.findings.count == 6)
        #expect(zip(result.findings, result.findings.dropFirst()).allSatisfy { $0.severity >= $1.severity })
        #expect(result.summary == result.findings[0].title)
    }

    @Test func heldRunAllowsTheCurrentMinuteToBeMissing() {
        #expect(Diagnoser.heldRun([0.1, 1, 1, 1, .nan])?.minutes == 3)
        #expect(Diagnoser.heldRun([1, 1, .nan, 1])?.minutes == 1)
        #expect(Diagnoser.heldRun([1, 1, 0.2]) == nil)
        #expect(Diagnoser.cores(1.0) == "1 core")
        #expect(Diagnoser.cores(0.6) == "60% of a core")
    }

    @Test func diagnosisRoundTripsAsJSON() throws {
        let result = Diagnoser.diagnose(DiagnosisInput(system: Self.quiet(pressure: .critical),
                                                       table: ProcessTable(apps: [Self.app("/Applications/X.app", "X", memory: 9 * Self.gb)], coreCount: 16)))
        let data = Report.json(result)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Diagnosis.self, from: data) == result)
    }
}

@Suite struct SpikeTests {
    static let end = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    @Test func aPlateauIsLabelledWithTheAppThatExplainsIt() {
        // A day of CPU on 16 cores at 10%, with Chrome adding three cores for 12 minutes.
        var series = [Float](repeating: 0.1, count: 1440)
        var chrome = [Float](repeating: 0.2, count: 1440)
        let safari = [Float](repeating: 0.4, count: 1440)
        for i in 600..<612 {
            series[i] += 3 / 16
            chrome[i] += 3
        }
        let spikes = SpikeFinder.find(series: series, apps: [.init(id: "chrome", name: "Chrome", values: chrome),
                                                             .init(id: "safari", name: "Safari", values: safari)],
                                      metric: .cpu(cores: 16), end: Self.end, step: 60, calendar: Self.utc, locale: Locale(identifier: "en_US"))
        #expect(spikes.count == 1)
        let spike = try! #require(spikes.first)
        #expect(spike.appID == "chrome")
        #expect(spike.start == 600 && spike.end == 611)
        // 1_800_000_000 is 08:00 UTC; index 600 is 839 minutes earlier, 18:01 the day before.
        #expect(spike.label == "6:01 pm · Chrome held 3 cores for 12 min")
    }

    @Test func noHistoryForTheSpanMeansNoLabel() {
        var series = [Float](repeating: 0.1, count: 600)
        for i in 300..<320 { series[i] = 0.6 }
        // The app's history starts after the spike (Wisp was not running then).
        var app = [Float](repeating: .nan, count: 600)
        for i in 330..<600 { app[i] = 0.2 }
        let spikes = SpikeFinder.find(series: series, apps: [.init(id: "a", name: "A", values: app)], metric: .cpu(cores: 16),
                                      end: Self.end, step: 60)
        #expect(spikes.isEmpty)
    }

    @Test func anAppThatDoesNotExplainTheRiseGetsNoLabel() {
        var series = [Float](repeating: 0.1, count: 600)
        for i in 300..<320 { series[i] = 0.6 }  // 8 cores more
        var app = [Float](repeating: 0.2, count: 600)
        for i in 300..<320 { app[i] = 0.8 }  // only 0.6 of a core of it
        #expect(SpikeFinder.find(series: series, apps: [.init(id: "a", name: "A", values: app)], metric: .cpu(cores: 16),
                                 end: Self.end, step: 60).isEmpty)
    }

    @Test func aSteadyNoisyChartHasNoLabels() {
        let series = (0..<1440).map { Float(0.3 + 0.05 * sin(Double($0) / 5)) }
        let app = (0..<1440).map { Float(4 + 0.8 * sin(Double($0) / 5)) }
        #expect(SpikeFinder.find(series: series, apps: [.init(id: "a", name: "A", values: app)], metric: .cpu(cores: 16),
                                 end: Self.end, step: 60).isEmpty)
    }

    @Test func neighboursMergeAndTheCountIsCapped() {
        var series = [Float](repeating: 0.05, count: 1440)
        var app = [Float](repeating: 0.1, count: 1440)
        // Two bursts with a two-minute dip between them read as one.
        for i in Array(100..<110) + Array(112..<120) { series[i] = 0.5; app[i] = 7 }
        // Eight more separate bursts across the day.
        for start in stride(from: 250, to: 1440, by: 150) {
            for i in start..<(start + 5) { series[i] = 0.4 + Float(start) / 10000; app[i] = 6 }
        }
        let spikes = SpikeFinder.find(series: series, apps: [.init(id: "a", name: "A", values: app)], metric: .cpu(cores: 16),
                                      end: Self.end, step: 60, limit: 4)
        #expect(spikes.count == 4)
        #expect(spikes.contains { $0.start == 100 && $0.end == 119 })
        #expect(zip(spikes, spikes.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test func memoryAndDiskAreWordedInTheirUnits() {
        let gb = Float(1 << 30)
        var memory = [Float](repeating: 20 * gb, count: 120)
        var xcode = [Float](repeating: 2 * gb, count: 120)
        for i in 60..<90 { memory[i] = 30 * gb; xcode[i] = 12 * gb }
        let m = SpikeFinder.find(series: memory, apps: [.init(id: "x", name: "Xcode", values: xcode)], metric: .memory,
                                 end: Self.end, step: 60, calendar: Self.utc, locale: Locale(identifier: "en_US"))
        #expect(m.first?.label.hasSuffix("Xcode grew to 12 GB") == true)

        var disk = [Float](repeating: 1_000_000, count: 120)
        var tm = [Float](repeating: 0, count: 120)
        for i in 30..<40 { disk[i] = 101_000_000; tm[i] = 100_000_000 }
        let d = SpikeFinder.find(series: disk, apps: [.init(id: "t", name: "backupd", values: tm)], metric: .disk,
                                 end: Self.end, step: 60, calendar: Self.utc, locale: Locale(identifier: "en_US"))
        #expect(d.first?.label.hasSuffix("backupd moved 60 GB on disk in 10 min") == true)
    }

    @Test func historyStoreFindsTheSeededSpells() {
        let store = HistoryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_030)
        store.seedSyntheticDay(now: now)
        let clock = ContinuousClock()
        var spikes: [ChartSpike] = []
        let elapsed = clock.measure { spikes = store.spikes([.cpu], metric: .cpu(cores: 16), minutes: HistoryStore.minutes, now: now) }
        #expect(Set(spikes.map(\.appName)) == ["Xcode", "Google Chrome", "node"])
        // Cheap enough to run on the main thread once a minute.
        #expect(elapsed < .milliseconds(30))
        let memory = store.spikes([.memory], metric: .memory, minutes: HistoryStore.minutes, now: now)
        #expect(memory.contains { $0.appName == "Xcode" })
        let hour = store.spikes([.cpu], metric: .cpu(cores: 16), minutes: 60, now: now)
        #expect(hour.isEmpty)
    }
}

@Suite struct DevLoadTests {
    @Test func idleDevServersAreNotBlamed() {
        let system = DiagnosisTests.quiet()
        let idle = Diagnoser.diagnose(DiagnosisInput(system: system, table: ProcessTable(coreCount: 16), devServers: 25,
                                                     devServerCPU: 0.1, devServerMemory: 2 << 30))
        #expect(idle.isHealthy)
        let busy = Diagnoser.diagnose(DiagnosisInput(system: system, table: ProcessTable(coreCount: 16), devServers: 6,
                                                     devServerCPU: 1.4, devServerMemory: 5 << 30))
        #expect(busy.findings.first?.title == "6 dev servers are using 1.4 cores and 5.0 GB together")
    }
}

@Suite struct BusyAppTests {
    @Test func oneAppTakingABigShareIsNamedBelowTheLine() {
        let app = DiagnosisTests.app("/Applications/Busy.app", "Busy", cpu: 6.4)
        let result = Diagnoser.diagnose(DiagnosisInput(system: DiagnosisTests.quiet(cpu: 0.5), table: ProcessTable(apps: [app], coreCount: 16),
                                                       recentAppCPU: [app.id: Array(repeating: 6, count: 20)]))
        #expect(result.findings.first?.title == "Busy is using 6.4 cores, 40% of the CPU")
        // Not reported twice as "held for minutes".
        #expect(result.findings.filter { $0.appID == app.id }.count == 1)
    }
}

@Suite struct WordingTests {
    @Test func macOSKeepsItsCase() {
        // Swapping with no single app to blame starts the sentence with "macOS".
        let result = Diagnoser.diagnose(DiagnosisInput(system: DiagnosisTests.quiet(), table: ProcessTable(coreCount: 16),
                                                       swapInPerSecond: 4_000_000, swapOutPerSecond: 0))
        #expect(result.findings.first?.title == "macOS is swapping 229 MB a minute")
    }
}
