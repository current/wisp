import AppKit
import WispCore

/// Spike labels for the machine pages' Hour and Day charts. Worked out only when the
/// range changes or a new minute is in (that is when `refreshChart` redraws them), and
/// kept per chart and range, so switching back and forth costs nothing.
@MainActor
enum SpikeLabels {
    private static var cache: [String: (minute: Int, spikes: [ChartSpike])] = [:]
    private static var seeded = false

    /// Called once when a machine page loads.
    static func install(on page: MachinePage) {
        let environment = ProcessInfo.processInfo.environment
        // WISP_RANGE=hour|day opens the chart on that range, for screenshots and benchmarks.
        if let range = ["hour": 1, "day": 2][environment["WISP_RANGE"] ?? ""] { page.hero.range.select(range, animated: false) }
        // WISP_SPIKE_DEMO=1 fills a made-up day so the labels can be screenshotted on a fresh launch.
        if environment["WISP_SPIKE_DEMO"] != nil, !seeded {
            seeded = true
            page.delegate.monitor.history.seedSyntheticDay(cores: ProcessInfo.processInfo.activeProcessorCount,
                                                           memoryTotal: ProcessInfo.processInfo.physicalMemory)
        }
        page.hero.chart.onSpike = { [weak page] spike in
            guard let page, page.delegate.table.app(spike.appID) != nil else { return }
            page.onSelect(.app(spike.appID))
        }
    }

    /// What a page's chart plots, in spike terms; nil for charts with no per-app history (GPU).
    private static func metric(for page: MachinePage) -> ([SystemMetric], SpikeMetric)? {
        switch page {
        case is CPUPage: return ([.cpu], .cpu(cores: max(1, page.lastTable?.coreCount ?? ProcessInfo.processInfo.activeProcessorCount)))
        case is MemoryPage: return ([.memory], .memory)
        case is DiskPage: return ([.diskRead, .diskWrite], .disk)
        case is NetworkPage: return ([.networkIn, .networkOut], .network)
        case is PowerPage: return ([.power], .power)  // the battery hero (charge) draws its own chart and never asks
        default: return nil
        }
    }

    /// The labels for the range on screen: none on Live.
    static func refresh(_ page: MachinePage, minutes: Int?) {
        guard let minutes, let (system, metric) = metric(for: page) else {
            page.hero.chart.spikes = []
            return
        }
        let key = "\(ObjectIdentifier(type(of: page)))|\(minutes)"
        let minute = Int(Date().timeIntervalSince1970 / 60)
        if let hit = cache[key], hit.minute == minute {
            page.hero.chart.spikes = hit.spikes
            return
        }
        let spikes = page.delegate.monitor.history.spikes(system, metric: metric, minutes: minutes, limit: minutes > 120 ? 4 : 3)
        cache[key] = (minute, spikes)
        page.hero.chart.spikes = spikes
    }
}
