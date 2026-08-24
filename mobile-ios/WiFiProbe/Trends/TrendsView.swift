import SwiftUI
import WiFiProbeKit

/// The networks this phone has visited, ranked.
///
/// A phone produces one point per tap, so this does not try to be the
/// Grafana board. It answers the question a phone is placed to answer,
/// which is which of the networks you actually go to is any good.
struct TrendsView: View {
    @State private var summaries: [Trends.SiteSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView("Nothing to compare yet",
                                           systemImage: "chart.bar",
                                           description: Text("Measure a couple of "
                                                             + "networks and they will "
                                                             + "be ranked here."))
                } else {
                    List {
                        Section("Networks you have tested") {
                            ForEach(summaries) { summary in
                                NavigationLink {
                                    SiteTrendView(site: summary.site)
                                } label: {
                                    row(summary)
                                }
                            }
                        }
                        if let weakest = summaries.last,
                           let insight = Trends.insight(for: weakest) {
                            Section { Text(insight).font(.callout) }
                        }
                    }
                }
            }
            .navigationTitle("Trends")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func row(_ summary: Trends.SiteSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Trends.readable(summary.site)).font(.body)
                Spacer()
                Text(summary.medianScore.map { "\(Int($0.rounded()))" } ?? "-")
                    .font(.subheadline.weight(.bold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule().fill(colour(summary.medianScore))
                        .frame(width: barWidth(summary.medianScore,
                                                totalWidth: geometry.size.width))
                }
            }
            .frame(height: 8)
            Text("\(summary.runCount) run\(summary.runCount == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// Width of the ranking bar's coloured fill.
    ///
    /// A nil score (never measured) draws no fill, leaving only the grey
    /// track. A real score is clamped to the track (a score above 100
    /// should not run past the row edge) and always draws at least a
    /// small stub, even at zero. Without that floor a network that is
    /// completely down and a network that was never measured both draw
    /// as an empty bar, and the ranking's whole point is spotting the
    /// dead one at a glance.
    private func barWidth(_ score: Double?, totalWidth: CGFloat) -> CGFloat {
        guard let score else { return 0 }
        let fraction = min(1, max(0, score / 100))
        let minimumStub: CGFloat = 6
        return max(minimumStub, totalWidth * fraction)
    }

    private func colour(_ score: Double?) -> Color {
        switch score {
        case .some(80...): return .green
        case .some(50..<80): return .orange
        case .some: return .red
        default: return .gray
        }
    }

    private func reload() async {
        summaries = Trends.rank(await AppStores.runs.all())
    }
}
