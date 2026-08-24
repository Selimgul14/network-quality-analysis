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

                if points.count < 2 {
                    Text("One run so far. Test this network again and a line appears.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    chart
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
        .chartYAxisLabel(metric.unit)
        .frame(height: 180)
        .padding(.vertical, 6)
    }
}
