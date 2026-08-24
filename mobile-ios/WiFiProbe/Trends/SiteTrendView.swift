import Charts
import SwiftUI
import WiFiProbeKit

/// One network over time. Where a fixed probe runs at the same site, its
/// line is drawn behind the phone's points: same metric, same scorer, two
/// unrelated clients.
struct SiteTrendView: View {
    let site: String

    @State private var runs: [StoredRun] = []
    @State private var metric: Trends.Metric = .score

    private var points: [Point] {
        Trends.series(runs, metric: metric)
            .map { Point(date: $0.date, value: $0.value) }
    }

    struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    var body: some View {
        List {
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(Trends.Metric.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if points.count >= 2 {
                    chart
                } else if let message = statusMessage {
                    Text(message)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }

            Section("Typical") {
                let summary = Trends.summarise(site: site, runs: runs)
                LabeledContent("Score", value: summary.medianScore
                    .map { "\(Int($0.rounded()))" } ?? "-")
                LabeledContent("Speed", value: summary.medianDownloadMbps
                    .map { String(format: "%.0f Mbps", $0) } ?? "-")
                LabeledContent("WiFi link", value: summary.medianWiFiLinkMs
                    .map { String(format: "%.1f ms", $0) } ?? "-")
                LabeledContent("Runs", value: "\(summary.runCount)")
            }
        }
        .navigationTitle(Trends.readable(site))
        .navigationBarTitleDisplayMode(.inline)
        .task { runs = await AppStores.runs.runs(site: site) }
    }

    private var chart: some View {
        Chart(points) { point in
            LineMark(x: .value("When", point.date), y: .value(metric.title, point.value))
                .interpolationMethod(.monotone)
            PointMark(x: .value("When", point.date), y: .value(metric.title, point.value))
        }
        .chartYScale(domain: yDomain)
        .chartYAxisLabel(metric.unit)
        .frame(height: 180)
        .padding(.vertical, 6)
    }

    /// The y axis range for the current metric.
    ///
    /// Left to auto-scale, Swift Charts fits tightly to the data, so a
    /// score that only ever moves between 88 and 92 draws as a cliff.
    /// Score has a true range (0 to 100), so that is fixed. Speed and
    /// WiFi link have no natural ceiling, so they are anchored at zero
    /// instead, so the drawn height of a line is proportional to the
    /// quantity rather than to how much the sample happened to vary.
    /// Either way the domain grows past its floor rather than clipping a
    /// value that exceeds it.
    private var yDomain: ClosedRange<Double> {
        let maxValue = points.map(\.value).max() ?? 0
        switch metric {
        case .score: return 0...max(100, maxValue)
        case .download, .latency: return 0...max(1, maxValue)
        }
    }

    /// A plain-English name for what a metric measures, used in status
    /// text rather than the raw enum case or the terse chart title.
    private func metricNoun(_ metric: Trends.Metric) -> String {
        switch metric {
        case .score: return "a score"
        case .download: return "a speed reading"
        case .latency: return "a WiFi link reading"
        }
    }

    /// What to show instead of the chart when there are fewer than two
    /// points to draw a line between.
    ///
    /// `points` only counts runs that reported this particular metric,
    /// while `runs` is every run this site has. Those two counts can
    /// disagree badly: a site can have ten runs and zero scored points
    /// if the phone's summary fetch failed on every one of them, and
    /// "test again" is not the fix for that.
    private var statusMessage: String? {
        if runs.isEmpty {
            // Still loading, or truly nothing yet either way: say
            // nothing rather than guess.
            return nil
        }
        if points.isEmpty {
            return "These runs did not record \(metricNoun(metric))."
        }
        if runs.count == 1 {
            return "One run so far. Test this network again and a line appears."
        }
        return "Only one of these runs recorded \(metricNoun(metric)). "
            + "Test this network again and a line appears."
    }
}
