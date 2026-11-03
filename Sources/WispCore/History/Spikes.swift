import Foundation

/// A notable peak or plateau on a history chart and the app that explains it.
public struct ChartSpike: Sendable, Equatable {
    /// Indexes into the chart's series, inclusive.
    public var start: Int
    public var end: Int
    public var peak: Int
    /// The chart's value at the peak, in the chart's units.
    public var value: Float
    public var appID: String
    public var appName: String
    /// "2:14 pm · Chrome held 3 cores for 12 min"
    public var label: String
    /// A longer line for hover: the span and the figures.
    public var detail: String
}

/// What a chart plots, so spikes are measured and worded in its terms.
public enum SpikeMetric: Sendable {
    /// Machine CPU as a fraction (0...1) against app CPU in cores; `cores` converts.
    case cpu(cores: Int)
    case memory
    case power
    case disk
    case network

    var appMetric: AppMetric {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .power: return .energy
        case .disk: return .disk
        case .network: return .network
        }
    }

    /// Multiplies a chart value into app units.
    var scale: Double {
        if case .cpu(let cores) = self { return Double(max(1, cores)) }
        return 1
    }

    /// The smallest rise above the baseline worth a label, in app units.
    var minimumRise: Double {
        switch self {
        case .cpu: return 1.0              // a core
        case .memory: return 1_500_000_000 // 1.5 GB
        case .power: return 5               // watts
        case .disk: return 20_000_000       // 20 MB/s
        case .network: return 2_000_000     // 2 MB/s
        }
    }
}

/// Finds a few significant peaks per chart and names the app behind each.
///
/// Pure and cheap: a pass over the series to find runs above the baseline, then one
/// pass over each candidate app's history. Callers run it when the range changes or a
/// new minute arrives, never per frame.
public enum SpikeFinder {
    public struct AppSeries: Sendable {
        public var id: String
        public var name: String
        /// Aligned with the chart's series, NaN where there is no data.
        public var values: [Float]
        public init(id: String, name: String, values: [Float]) {
            self.id = id
            self.name = name
            self.values = values
        }
    }

    /// - Parameters:
    ///   - series: the chart's values, oldest first, NaN for gaps.
    ///   - apps: per-app history aligned with `series`.
    ///   - end: the time of the last point.
    ///   - step: seconds between points.
    ///   - limit: the most labels to return.
    public static func find(series: [Float], apps: [AppSeries], metric: SpikeMetric, end: Date, step: TimeInterval,
                            limit: Int = 4, calendar: Calendar = .current, locale: Locale = .current) -> [ChartSpike] {
        let scale = metric.scale
        let values = series.map { $0.isNaN ? Double.nan : Double($0) * scale }
        let known = values.filter { !$0.isNaN }.sorted()
        guard known.count >= 8 else { return [] }
        let baseline = known[known.count / 2]
        let spread = known[min(known.count - 1, known.count * 9 / 10)] - baseline
        // Above the baseline by the larger of a fixed floor, half the baseline, and the
        // typical spread, so a busy but steady chart is not labelled everywhere.
        let threshold = baseline + max(metric.minimumRise, baseline * 0.5, spread * 0.8)

        // Runs of points over the threshold, joined across short dips.
        let mergeGap = max(2, values.count / 60)
        var runs: [(start: Int, end: Int)] = []
        for (index, value) in values.enumerated() where !value.isNaN && value >= threshold {
            if let last = runs.last, index - last.end <= mergeGap + 1 {
                runs[runs.count - 1].end = index
            } else {
                runs.append((index, index))
            }
        }
        guard !runs.isEmpty else { return [] }

        // App baselines, for "how much did it rise" rather than "how much does it use".
        let appBaselines: [Double] = apps.map { app in
            let sorted = app.values.filter { !$0.isNaN }.map(Double.init).sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }

        struct Candidate { var spike: ChartSpike; var score: Double }
        var candidates: [Candidate] = []
        for run in runs {
            let span = run.start...run.end
            let inside = span.compactMap { values[$0].isNaN ? nil : values[$0] }
            guard !inside.isEmpty else { continue }
            let excess = inside.reduce(0) { $0 + ($1 - baseline) } / Double(inside.count)
            guard excess > 0 else { continue }
            let peak = span.filter { !values[$0].isNaN }.max { values[$0] < values[$1] } ?? run.start

            // Each app's rise over its own baseline during the run.
            var best: (index: Int, rise: Double, mean: Double, top: Double)?
            var second: (index: Int, rise: Double)?
            for (index, app) in apps.enumerated() where app.values.count == values.count {
                let points = span.compactMap { app.values[$0].isNaN ? nil : Double(app.values[$0]) }
                // Missing history for most of the run: no guess.
                guard Double(points.count) >= Double(span.count) * 0.6 else { continue }
                let mean = points.reduce(0, +) / Double(points.count)
                let rise = metric.isMemory ? (points.max() ?? 0) - appBaselines[index] : mean - appBaselines[index]
                guard rise > 0 else { continue }
                if rise > (best?.rise ?? 0) {
                    if let best { second = (best.index, best.rise) }
                    best = (index, rise, mean, points.max() ?? 0)
                } else if rise > (second?.rise ?? 0) {
                    second = (index, rise)
                }
            }
            guard let best, best.rise >= excess * 0.4 else { continue }
            var names = apps[best.index].name
            if let second, second.rise >= excess * 0.3, second.rise >= metric.minimumRise * 0.5 {
                names += " and " + apps[second.index].name
            }
            let duration = Double(span.count) * step
            let when = time(end.addingTimeInterval(-Double(values.count - 1 - run.start) * step), calendar: calendar, locale: locale)
            let until = time(end.addingTimeInterval(-Double(values.count - 1 - run.end) * step + step), calendar: calendar, locale: locale)
            let app = apps[best.index]
            let label = when + " · " + phrase(metric, names: names, plural: names.contains(" and "), mean: best.mean, top: best.top,
                                               duration: duration)
            let detail = "\(when) to \(until) · \(app.name) \(figure(metric, best.mean, top: best.top)) · " +
                peakFigure(metric, Double(series[peak]))
            let spike = ChartSpike(start: run.start, end: run.end, peak: peak, value: series[peak], appID: app.id, appName: app.name,
                                   label: label, detail: detail)
            candidates.append(Candidate(spike: spike, score: excess * Double(span.count).squareRoot()))
        }

        // Keep the biggest, then drop any that sit too close to a bigger one to label clearly.
        let spacing = max(3, values.count / 8)
        var kept: [ChartSpike] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard kept.count < limit else { break }
            if kept.contains(where: { abs($0.peak - candidate.spike.peak) < spacing }) { continue }
            kept.append(candidate.spike)
        }
        return kept.sorted { $0.start < $1.start }
    }

    static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        // "2:14 PM" reads as shouting next to a sentence; macOS menus use lowercase too.
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 90 { return "\(max(1, m)) min" }
        let h = Double(m) / 60
        return String(format: h < 10 ? "%.1f h" : "%.0f h", h).replacingOccurrences(of: ".0 h", with: " h")
    }

    static func phrase(_ metric: SpikeMetric, names: String, plural: Bool, mean: Double, top: Double, duration: Double) -> String {
        switch metric {
        case .cpu:
            let cores = mean >= 1.5 ? "\(Int(mean.rounded())) cores" : (mean >= 0.95 ? "a core" : Format.percent(mean) + " of a core")
            return "\(names) held \(cores) for \(minutes(duration))"
        case .memory:
            return plural ? "\(names) grew to \(Format.memory(top))" : "\(names) grew to \(Format.memory(top))"
        case .power:
            return "\(names) drew \(String(format: "%.0f W", mean)) for \(minutes(duration))"
        case .disk:
            return "\(names) moved \(Format.bytes(mean * duration)) on disk in \(minutes(duration))"
        case .network:
            return "\(names) moved \(Format.bytes(mean * duration)) in \(minutes(duration))"
        }
    }

    /// The chart at its highest point in the spell, in the chart's own units.
    static func peakFigure(_ metric: SpikeMetric, _ value: Double) -> String {
        switch metric {
        case .cpu: return "CPU peaked at " + Format.percent(value)
        case .memory: return "memory peaked at " + Format.memory(value)
        case .power: return String(format: "power peaked at %.0f W", value)
        case .disk, .network: return "peaked at " + Format.rate(value)
        }
    }

    static func figure(_ metric: SpikeMetric, _ mean: Double, top: Double) -> String {
        switch metric {
        case .cpu: return String(format: "%.1f cores on average", mean)
        case .memory: return "up to " + Format.memory(top)
        case .power: return String(format: "%.1f W on average", mean)
        case .disk, .network: return Format.rate(mean) + " on average"
        }
    }
}

extension SpikeMetric {
    var isMemory: Bool { if case .memory = self { return true } else { return false } }
}

extension HistoryStore {
    /// Spikes on the last `minutes` of a machine chart, attributed from per-app history.
    /// The metric names the per-app series; `candidates` caps how many apps are read.
    public func spikes(_ system: [SystemMetric], metric: SpikeMetric, minutes: Int, now: Date = Date(),
                       limit: Int = 4, candidates: Int = 24) -> [ChartSpike] {
        let series: [Float]
        if system.count == 1 {
            series = day(system[0], minutes: minutes, now: now)
        } else {
            let parts = system.map { day($0, minutes: minutes, now: now) }
            guard let first = parts.first else { return [] }
            series = (0..<first.count).map { index in
                parts.reduce(Float(0)) { total, part in index < part.count ? total + part[index] : .nan }
            }
        }
        guard series.contains(where: { !$0.isNaN }) else { return [] }
        let ranked = summaries(minutes: minutes, now: now).sorted { a, b in
            switch metric {
            case .cpu: return a.cpu * Double(a.minutes) > b.cpu * Double(b.minutes)
            case .memory: return a.memoryPeak > b.memoryPeak
            case .power: return a.energyWh > b.energyWh
            case .disk: return a.diskBytes > b.diskBytes
            case .network: return a.networkBytes > b.networkBytes
            }
        }
        let apps = ranked.prefix(candidates).map { summary in
            SpikeFinder.AppSeries(id: summary.id, name: summary.id == AppGrouping.systemID ? "macOS" : summary.name,
                                  values: app(summary.id, metric.appMetric, minutes: minutes, now: now))
        }
        let end = Date(timeIntervalSince1970: Double(Self.minute(now) - 1) * 60)
        return SpikeFinder.find(series: series, apps: apps, metric: metric, end: end, step: 60, limit: limit)
    }
}

extension HistoryStore {
    /// Fills the last day with a made-up but plausible machine and three busy spells,
    /// for screenshots (WISP_SPIKE_DEMO) and tests. Detaches the archive first so
    /// nothing made up ever reaches the owner's history on disk.
    public func seedSyntheticDay(now: Date = Date(), cores: Int = 16, memoryTotal: UInt64 = 36 << 30) {
        archive = nil
        let gb = Double(1 << 30)
        let end = Self.minute(now) - 1
        struct Spell { var id: String; var name: String; var from: Int; var length: Int; var cores: Double; var memory: Double; var watts: Double; var disk: Double }
        // Minutes before now.
        let spells = [
            Spell(id: "/Applications/Xcode.app", name: "Xcode", from: 1010, length: 24, cores: 8, memory: 9 * gb, watts: 28, disk: 160_000_000),
            Spell(id: "/Applications/Google Chrome.app", name: "Google Chrome", from: 520, length: 12, cores: 3, memory: 4 * gb, watts: 9, disk: 5_000_000),
            Spell(id: "tool:/opt/homebrew/bin/node", name: "node", from: 190, length: 38, cores: 2, memory: 2 * gb, watts: 7, disk: 30_000_000),
        ]
        let steady: [(String, String, Double, Double)] = [
            ("/Applications/Google Chrome.app", "Google Chrome", 0.25, 3 * gb), ("/Applications/Xcode.app", "Xcode", 0.05, 2 * gb),
            ("tool:/opt/homebrew/bin/node", "node", 0.08, 0.6 * gb), ("/Applications/Safari.app", "Safari", 0.15, 1.5 * gb),
            (AppGrouping.systemID, "macOS", 0.6, 6 * gb),
        ]
        for offset in stride(from: 1439, through: 0, by: -1) {
            let minute = end - offset
            let date = Date(timeIntervalSince1970: Double(minute) * 60 + 30)
            let wave = sin(Double(minute) / 23) * 0.04 + sin(Double(minute) / 7) * 0.02
            var groups: [AppGroup] = []
            for (id, name, baseCPU, baseMemory) in steady {
                var cpu = max(0.01, baseCPU * (1 + wave * 4)), memory = baseMemory, watts = cpu * 2.5, disk = 200_000.0
                for spell in spells where spell.id == id && offset <= spell.from && offset > spell.from - spell.length {
                    let progress = Double(spell.from - offset) / Double(spell.length)
                    cpu += spell.cores * (0.85 + 0.15 * sin(progress * .pi))
                    memory += spell.memory * min(1, progress * 2)
                    watts += spell.watts
                    disk += spell.disk
                }
                groups.append(AppGroup(id: id, name: name, kind: id.hasPrefix("/") ? .app : (id == AppGrouping.systemID ? .system : .tool),
                                       bundlePath: id.hasPrefix("/") ? id : nil, bundleIdentifier: nil, pids: [1], cpu: cpu,
                                       memory: UInt64(memory), watts: watts, diskReadPerSecond: disk * 0.3, diskWritePerSecond: disk * 0.7,
                                       networkInPerSecond: 20_000, networkOutPerSecond: 5_000, unreadable: 0))
            }
            let busy = groups.reduce(0) { $0 + $1.cpu }
            var snapshot = SystemSnapshot(date: date)
            snapshot.cpu = CPUReading(user: busy / Double(cores) * 0.75, system: busy / Double(cores) * 0.25)
            let used = groups.reduce(0) { $0 + Double($1.memory) } + 4 * gb
            snapshot.memory = MemoryReading(total: memoryTotal, app: UInt64(used * 0.7), wired: UInt64(used * 0.2), compressed: UInt64(used * 0.1),
                                            cached: 0, free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
            let disk = groups.reduce(0) { $0 + $1.diskPerSecond }
            snapshot.disk = DiskReading(readBytesPerSecond: disk * 0.3, writeBytesPerSecond: disk * 0.7, volumeTotal: 0, volumeFree: 0)
            snapshot.network = NetworkReading(receivedBytesPerSecond: 120_000, sentBytesPerSecond: 30_000, totalReceived: 0, totalSent: 0)
            let watts = groups.reduce(0) { $0 + $1.watts }
            snapshot.power = PowerReading(cpu: watts * 0.8, gpu: watts * 0.2, ane: 0)
            record(system: snapshot, interval: 60)
            record(table: ProcessTable(date: date, interval: 60, apps: groups, machineCPU: busy, coreCount: cores))
        }
    }
}
