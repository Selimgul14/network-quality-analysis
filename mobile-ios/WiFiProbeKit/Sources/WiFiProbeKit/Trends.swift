import Foundation

/// What the Trends tab shows, computed over the runs kept on the device.
///
/// Pure functions over `[StoredRun]`, so this is unit-tested directly and
/// the SwiftUI layer above it holds no arithmetic.
///
/// A phone produces one point per tap rather than one every ten seconds,
/// so this deliberately does not try to be Grafana. It answers the
/// question a phone is placed to answer, which is which of the networks
/// you actually visit is any good.
public enum Trends {

    public enum Metric: String, CaseIterable, Sendable {
        case score, download, latency

        public var title: String {
            switch self {
            case .score: return "Score"
            case .download: return "Speed"
            case .latency: return "WiFi link"
            }
        }

        public var unit: String {
            switch self {
            case .score: return ""
            case .download: return "Mbps"
            case .latency: return "ms"
            }
        }

        func value(from run: StoredRun) -> Double? {
            switch self {
            case .score: return run.verdict?.score
            case .download: return run.downloadMbps
            case .latency: return run.verdict?.wifiLinkRTTms
            }
        }
    }

    public struct SiteSummary: Sendable, Equatable, Identifiable {
        public let site: String
        public let runCount: Int
        public let medianScore: Double?
        public let medianDownloadMbps: Double?
        public let medianWiFiLinkMs: Double?
        public let firstRun: Date
        public let lastRun: Date
        /// The segment most often not `ok` across this site's runs, or nil
        /// if nothing was ever at fault.
        public let worstSegment: String?

        public var id: String { site }
    }

    /// Medians rather than means throughout, the same reason the backend
    /// uses them (see cloud/app/summary.py): one failed run should not
    /// swing a site's summary the way it would swing an average.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Best median score first. A site with no scored run sorts last,
    /// rather than being dropped: "tested and never got a verdict" is
    /// information about that network. Ties fall back to site name so the
    /// order is stable rather than dependent on dictionary iteration.
    public static func rank(_ runs: [StoredRun]) -> [SiteSummary] {
        Dictionary(grouping: runs, by: \.site)
            .map { site, siteRuns in summarise(site: site, runs: siteRuns) }
            .sorted { left, right in
                switch (left.medianScore, right.medianScore) {
                case let (l?, r?): return l == r ? left.site < right.site : l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return left.site < right.site
                }
            }
    }

    static func summarise(site: String, runs: [StoredRun]) -> SiteSummary {
        var faults: [String: Int] = [:]
        for run in runs {
            for (segment, state) in run.verdict?.segments ?? [:] where state != "ok" {
                // no_data means the measurement was absent, not that it failed.
                if state != "no_data" { faults[segment, default: 0] += 1 }
            }
        }
        // Ties break on segment name so the result is deterministic rather
        // than dependent on dictionary iteration order.
        let worst = faults.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key

        let dates = runs.map(\.finishedAt)
        return SiteSummary(
            site: site,
            runCount: runs.count,
            medianScore: median(runs.compactMap { $0.verdict?.score }),
            medianDownloadMbps: median(runs.compactMap(\.downloadMbps)),
            medianWiFiLinkMs: median(runs.compactMap { $0.verdict?.wifiLinkRTTms }),
            firstRun: dates.min() ?? .distantPast,
            lastRun: dates.max() ?? .distantPast,
            worstSegment: worst)
    }

    /// Chart points, oldest first, skipping runs that never reported the
    /// metric asked for.
    public static func series(_ runs: [StoredRun],
                              metric: Metric) -> [(date: Date, value: Double)] {
        runs.sorted { $0.finishedAt < $1.finishedAt }
            .compactMap { run in
                metric.value(from: run).map { (date: run.finishedAt, value: $0) }
            }
    }

    /// The sentence under the ranking. Built here rather than in the view
    /// so it is covered by tests.
    public static func insight(for summary: SiteSummary) -> String? {
        guard let segment = summary.worstSegment else { return nil }
        let name: String
        switch segment {
        case "wifi_link": name = "the WiFi link itself"
        case "internet_path": name = "the internet path beyond the router"
        default: name = "the services being reached"
        }
        return "On \(readable(summary.site)), \(name) is what most often falls short."
    }

    /// The label as a person wrote it, without the prefix the app forces
    /// on to keep phone records out of the deployment dataset.
    public static func readable(_ site: String) -> String {
        site.hasPrefix(SiteLabel.prefix)
            ? String(site.dropFirst(SiteLabel.prefix.count)) : site
    }
}
