import Foundation

/// Owns the collectors and the one timer that drives them.
///
/// Everything mutable lives on `queue`. The timer is one-shot and re-armed for the
/// next job that is due, so a quiet configuration wakes the process only as often
/// as its slowest consumer needs, and a sleeping display wakes it not at all.
public final class Monitor: @unchecked Sendable {
    public typealias SystemHandler = @MainActor (SystemSnapshot) -> Void

    private let queue = DispatchQueue(label: "app.wisp.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var plan = SamplingPlan()
    private var activity: ActivityLevel = .menuBar
    private var paused = false
    private var running = false

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let disk = DiskCollector()
    private let network = NetworkCollector()
    private let gpu = GPUCollector()
    private let battery = BatteryCollector()
    private let thermal = ThermalCollector()
    private let power = PowerCollector()

    private var jobs: [Job] = []
    private var latestSystem = SystemSnapshot()
    private let lock = NSLock()

    public var onSystem: SystemHandler?
    public var onProcesses: (@MainActor (ProcessTable) -> Void)?
    /// Called on the monitor queue after every process pass, including background ones.
    public var processObserver: ((ProcessTable, Bool) -> Void)?

    let scanner = ProcessScanner()
    private var latestTable = ProcessTable()
    private var lastSystemSample: UInt64 = 0

    public let history: HistoryStore
    /// Per-app data used per day; persisted only when the history is.
    public let dataUsage: AppDataUsage
    public let alerts = AlertEngine()
    public var onAlert: (@MainActor (Alert) -> Void)?

    public init(history: HistoryStore = HistoryStore()) {
        self.history = history
        let saves = history.archive != nil && ProcessInfo.processInfo.environment["WISP_NO_SAVE"] == nil
        dataUsage = AppDataUsage(url: saves ? AppDataUsage.defaultURL : nil)
        jobs = [
            Job(name: "system") { [unowned self] in self.sampleSystem() },
            Job(name: "thermal") { [unowned self] in self.sampleThermal() },
            Job(name: "battery") { [unowned self] in self.sampleBattery() },
            Job(name: "processes") { [unowned self] in self.sampleProcesses() },
        ]
    }

    // MARK: Control

    public func start() {
        queue.async { [self] in
            running = true
            reschedule(runNow: true)
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
        }
    }

    public func update(activity: ActivityLevel, plan: SamplingPlan) {
        queue.async { [self] in
            let raised = activity > self.activity || !plan.demand.isSubset(of: self.plan.demand)
            self.activity = activity
            self.plan = plan
            reschedule(runNow: raised)
        }
    }

    /// Stops all sampling while the display sleeps; counters are re-baselined on resume.
    public func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard self.paused != paused else { return }
            self.paused = paused
            if paused {
                timer?.cancel()
                timer = nil
            } else {
                cpu.reset()
                disk.reset()
                network.reset()
                reschedule(runNow: true)
            }
        }
    }

    public func update(rules: AlertRules) {
        queue.async { [self] in alerts.rules = rules }
    }

    /// Runs `body` on the monitor queue. Used by the IPC server and tests.
    public func perform<T>(_ body: (Monitor) -> T) -> T {
        queue.sync { body(self) }
    }

    /// Readings no older than `maxAge`, sampling now if the last pass is older. Used
    /// by the local socket, so the CLI gets current figures with every window closed.
    public func fresh(maxAge: TimeInterval = 3) -> (system: SystemSnapshot, table: ProcessTable, alerts: [Alert]) {
        queue.sync {
            if Date().timeIntervalSince(latestTable.date) > maxAge || latestTable.interval == 0 {
                let table = scanner.scan(network: scanner.network != nil)
                lock.withLock { latestTable = table }
            }
            if Date().timeIntervalSince(latestSystem.date) > maxAge {
                let saved = plan
                plan.demand.formUnion(.system)
                sampleSystem()
                plan = saved
            }
            if latestSystem.thermal == nil { sampleThermal() }
            if latestSystem.battery == nil { sampleBattery() }
            return (lock.withLock { latestSystem }, lock.withLock { latestTable }, alerts.recent)
        }
    }

    /// The per-app network flows of these pids (all flows when nil), or nil when
    /// per-app network is not being measured. Waits for the monitor queue, so call it
    /// from a background queue.
    public func networkFlows(pids: Set<Int32>?) -> [NetworkFlow]? {
        queue.sync { scanner.network.map { $0.flows(owners: pids) } }
    }

    public var currentSystem: SystemSnapshot { lock.withLock { latestSystem } }
    public var currentTable: ProcessTable { lock.withLock { latestTable } }

    // MARK: Scheduling

    private var thermalMultiplier: Double {
        var factor = 1.0
        switch ProcessInfo.processInfo.thermalState {
        case .serious: factor = 2
        case .critical: factor = 4
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { factor *= 1.5 }
        return factor
    }

    private func interval(for job: Job) -> TimeInterval? {
        let visible = activity >= .menuBar
        let demand = plan.demand
        switch job.name {
        case "system":
            guard visible, !demand.isDisjoint(with: [.cpu, .cpuCores, .memory, .disk, .network, .gpu, .power]) else { return nil }
            return plan.interval
        case "thermal":
            guard visible, demand.contains(.thermal) else { return nil }
            return max(plan.interval, 5)
        case "battery":
            guard visible, demand.contains(.battery) else { return nil }
            return max(plan.interval, 10)
        case "processes":
            if visible, demand.contains(.processes) { return plan.interval }
            return plan.backgroundProcessInterval
        default:
            return nil
        }
    }

    private func reschedule(runNow: Bool) {
        guard running, !paused else { return }
        let now = MachTime.now
        let factor = thermalMultiplier
        for job in jobs {
            job.interval = interval(for: job).map { $0 * factor }
            if job.interval == nil { job.lastRun = 0 }
        }
        if runNow {
            for job in jobs where job.interval != nil && job.lastRun == 0 { run(job, at: now) }
        }
        armTimer()
    }

    private func run(_ job: Job, at now: UInt64) {
        job.lastRun = now
        job.body()
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard running, !paused else { return }
        let now = MachTime.now
        var soonest: Double?
        for job in jobs {
            guard let interval = job.interval else { continue }
            let due = job.lastRun == 0 ? 0 : max(0, interval - MachTime.seconds(now &- job.lastRun))
            soonest = min(soonest ?? due, due)
        }
        guard let delay = soonest else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A tenth of the delay as leeway lets the kernel coalesce this wakeup with others.
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(max(50, delay * 100))))
        timer.setEventHandler { [unowned self] in self.fire() }
        timer.resume()
        self.timer = timer
    }

    private func fire() {
        let now = MachTime.now
        for job in jobs {
            guard let interval = job.interval else { continue }
            // Run slightly early rather than late so coalescing does not stretch intervals.
            if job.lastRun == 0 || MachTime.seconds(now &- job.lastRun) >= interval * 0.9 {
                run(job, at: now)
            }
        }
        armTimer()
    }

    // MARK: Jobs

    private func sampleSystem() {
        let demand = plan.demand
        var snapshot = lock.withLock { latestSystem }
        snapshot.date = Date()
        // Per-core counters cost a few microseconds more. Reading them every time
        // means the dashboard's core map already has history when it opens.
        if !demand.isDisjoint(with: [.cpu, .cpuCores]) { snapshot.cpu = cpu.sample(perCore: true) ?? snapshot.cpu }
        if demand.contains(.memory) { snapshot.memory = memory.sample() }
        if demand.contains(.disk) { snapshot.disk = disk.sample() }
        if demand.contains(.network) { snapshot.network = network.sample() }
        if demand.contains(.gpu) { snapshot.gpu = gpu.sample() } else { gpu.close() }
        if demand.contains(.power) { snapshot.power = power.sample() } else { power.close() }
        let now = MachTime.now
        let interval = lastSystemSample == 0 ? plan.interval : MachTime.seconds(now &- lastSystemSample)
        lastSystemSample = now
        history.record(system: snapshot, interval: min(interval, plan.interval * 4))
        publish(snapshot)
    }

    private func sampleThermal() {
        var snapshot = lock.withLock { latestSystem }
        snapshot.thermal = thermal.sample(detail: activity >= .popover)
        publish(snapshot)
    }

    private func sampleBattery() {
        var snapshot = lock.withLock { latestSystem }
        snapshot.battery = battery.sample()
        publish(snapshot)
    }

    private func publish(_ snapshot: SystemSnapshot) {
        lock.withLock { latestSystem = snapshot }
        if let onSystem {
            DispatchQueue.main.async { onSystem(snapshot) }
        }
    }

    private func sampleProcesses() {
        let visible = activity >= .menuBar && plan.demand.contains(.processes)
        let wantsNetwork = visible ? plan.demand.contains(.appNetwork) : plan.backgroundAppNetwork
        let table = scanner.scan(network: wantsNetwork || alerts.needsNetwork)
        lock.withLock { latestTable = table }
        history.record(table: table)
        dataUsage.record(table)
        var fired = alerts.evaluate(table, history: history)
        if alerts.needsTemperature {
            // Reuse a recent reading when the thermal job is running; otherwise read the CPU sensor now.
            var celsius = lock.withLock { latestSystem.thermal?.cpuCelsius }
            if !(activity >= .menuBar && plan.demand.contains(.thermal)) { celsius = thermal.sample(detail: false).cpuCelsius }
            if let alert = alerts.evaluate(cpuCelsius: celsius) { fired.append(alert) }
        }
        if !fired.isEmpty, let onAlert {
            DispatchQueue.main.async { fired.forEach(onAlert) }
        }
        processObserver?(table, visible)
        if visible, let onProcesses {
            DispatchQueue.main.async { onProcesses(table) }
        }
    }
}

final class Job {
    let name: String
    let body: () -> Void
    var interval: TimeInterval?
    var lastRun: UInt64 = 0

    init(name: String, body: @escaping () -> Void) {
        self.name = name
        self.body = body
    }
}
