import Foundation

/// Owns the collectors and the one timer that drives them.
///
/// Everything mutable lives on `queue`. The timer is re-armed after each fire for the
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
    /// Set while one fire runs several jobs, so they reach the main thread as one snapshot.
    private var batching = false
    private var unpublished = false
    private var observers: [NSObjectProtocol] = []

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
            Job(name: "batteryLog") { [unowned self] in self.logBattery() },
        ]
        // Thermal pressure and Low Power Mode stretch every interval.
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.reschedule(runNow: false) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.cancel()
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
            armTimer()
        }
    }

    public func update(activity: ActivityLevel, plan: SamplingPlan) {
        queue.async { [self] in
            let raised = activity > self.activity || !plan.demand.isSubset(of: self.plan.demand)
            // A reading newly asked for, or the detail an opened dropdown adds, is taken
            // now rather than at the job's next due time.
            let gained = plan.demand.subtracting(self.plan.demand)
            let detailed = activity >= .popover && self.activity < .popover
            for job in jobs {
                switch job.name {
                case "system": if !gained.isDisjoint(with: Self.systemReadings) { job.lastRun = 0 }
                case "thermal", "battery": if detailed { job.lastRun = 0 }
                default: break
                }
            }
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
                armTimer()
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
            batched {
                // The regular passes keep only what is on screen; the CLI wants every reading.
                if Date().timeIntervalSince(latestSystem.date) > maxAge || !plan.demand.isSuperset(of: .system) {
                    let saved = plan
                    plan.demand.formUnion(.system)
                    sampleSystem()
                    plan = saved
                }
                if latestSystem.thermal == nil { sampleThermal() }
                if latestSystem.battery == nil { sampleBattery() }
            }
            return (lock.withLock { latestSystem }, lock.withLock { latestTable }, alerts.recent)
        }
    }

    /// Writes the hour in progress and the data usage to disk, on the monitor queue.
    public func save() {
        queue.async { [self] in
            history.flushToArchive()
            dataUsage.save()
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

    /// What the system job reads; thermal and battery have jobs of their own.
    static let systemReadings: Demand = [.cpu, .cpuCores, .memory, .disk, .network, .gpu, .power]

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
            guard visible, !demand.isDisjoint(with: Self.systemReadings) else { return nil }
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
        case "batteryLog":
            // The process pass logs the battery when it runs at least once a minute; this
            // job covers the rest, so the charge history needs no wakeups of its own.
            guard hasBattery else { return nil }
            let processes = visible && demand.contains(.processes) ? plan.interval : plan.backgroundProcessInterval
            if let processes, processes <= 60 { return nil }
            return 60
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
            batched {
                for job in jobs where job.interval != nil && job.lastRun == 0 { run(job, at: now) }
            }
        }
        armTimer()
    }

    private func run(_ job: Job, at now: UInt64) {
        job.lastRun = now
        job.body()
    }

    /// Moves the one timer to the next due job, or parks it when nothing is due.
    private func armTimer() {
        var soonest: Double?
        if running, !paused {
            let now = MachTime.now
            for job in jobs {
                guard let interval = job.interval else { continue }
                let due = job.lastRun == 0 ? 0 : max(0, interval - MachTime.seconds(now &- job.lastRun))
                soonest = min(soonest ?? due, due)
            }
        }
        guard let delay = soonest else {
            timer?.schedule(deadline: .distantFuture)
            return
        }
        let timer = self.timer ?? {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [unowned self] in self.fire() }
            timer.resume()
            self.timer = timer
            return timer
        }()
        // A tenth of the delay as leeway lets the kernel coalesce this wakeup with others.
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(max(50, delay * 100))))
    }

    private func fire() {
        let now = MachTime.now
        batched {
            for job in jobs {
                guard let interval = job.interval else { continue }
                // Run slightly early rather than late so coalescing does not stretch intervals.
                if job.lastRun == 0 || MachTime.seconds(now &- job.lastRun) >= interval * 0.9 {
                    run(job, at: now)
                }
            }
        }
        armTimer()
    }

    /// Runs `body` with publishing held back, then publishes once if any job did.
    private func batched(_ body: () -> Void) {
        batching = true
        body()
        batching = false
        guard unpublished else { return }
        unpublished = false
        deliver(lock.withLock { latestSystem })
    }

    // MARK: Jobs

    func sampleSystem() {
        let demand = plan.demand
        var snapshot = lock.withLock { latestSystem }
        snapshot.date = Date()
        // Per-core counters cost a few microseconds more. Reading them every time
        // means the dashboard's core map already has history when it opens.
        snapshot.cpu = demand.isDisjoint(with: [.cpu, .cpuCores]) ? nil : cpu.sample(perCore: true) ?? snapshot.cpu
        // Readings nothing asks for are dropped rather than carried: the history would
        // otherwise record their last value every pass, long after a dropdown closed.
        snapshot.memory = demand.contains(.memory) ? memory.sample() : nil
        snapshot.disk = demand.contains(.disk) ? disk.sample() : nil
        snapshot.network = demand.contains(.network) ? network.sample() : nil
        if demand.contains(.gpu) { snapshot.gpu = gpu.sample() } else { snapshot.gpu = nil; gpu.close() }
        if demand.contains(.power) { snapshot.power = power.sample() } else { snapshot.power = nil; power.close() }
        if !demand.contains(.thermal) { snapshot.thermal = nil }
        if !demand.contains(.battery) { snapshot.battery = nil }
        let now = MachTime.now
        let interval = lastSystemSample == 0 ? plan.interval : MachTime.seconds(now &- lastSystemSample)
        lastSystemSample = now
        history.record(system: snapshot, interval: min(interval, plan.interval * 4))
        publish(snapshot)
    }

    func sampleThermal() {
        var snapshot = lock.withLock { latestSystem }
        snapshot.thermal = thermal.sample(detail: activity >= .popover)
        publish(snapshot)
    }

    func sampleBattery() {
        var snapshot = lock.withLock { latestSystem }
        snapshot.battery = battery.sample(detail: activity >= .popover)
        if let b = snapshot.battery { logBattery((b.percent, b.isCharging, b.isPluggedIn)) }
        publish(snapshot)
    }

    private lazy var hasBattery = MachinePower.hasBattery
    private var lastBatteryLog: UInt64 = 0

    /// One charge sample a minute for the history: a power source read, no registry.
    private func logBattery(_ known: (Double, Bool, Bool)? = nil) {
        guard hasBattery else { return }
        let now = MachTime.now
        if lastBatteryLog != 0, MachTime.seconds(now &- lastBatteryLog) < 55 { return }
        guard let (percent, charging, plugged) = known ?? BatteryCollector.quick() else { return }
        lastBatteryLog = now
        history.batteryLog.record(level: percent, charging: charging, plugged: plugged)
    }

    private func publish(_ snapshot: SystemSnapshot) {
        lock.withLock { latestSystem = snapshot }
        if batching { unpublished = true } else { deliver(snapshot) }
    }

    private func deliver(_ snapshot: SystemSnapshot) {
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
        logBattery()
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
