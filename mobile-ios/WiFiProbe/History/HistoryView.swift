import SwiftUI
import WiFiProbeKit

/// Every run this phone has taken, newest first.
struct HistoryView: View {
    @State private var runs: [StoredRun] = []
    @State private var sites: [String] = []
    @State private var filter: String?

    private var shown: [StoredRun] {
        guard let filter else { return runs }
        return runs.filter { $0.site == filter }
    }

    private var days: [(day: Date, runs: [StoredRun])] {
        Dictionary(grouping: shown) {
            Calendar.current.startOfDay(for: $0.finishedAt)
        }
        .map { (day: $0.key, runs: $0.value.sorted { $0.finishedAt > $1.finishedAt }) }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView("No runs yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Measure a network and it "
                                                             + "will show up here."))
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private var list: some View {
        List {
            if sites.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", value: nil)
                            ForEach(sites, id: \.self) { chip(Trends.readable($0), value: $0) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            ForEach(days, id: \.day) { group in
                Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(group.runs) { run in
                        NavigationLink { RunDetailView(run: run) } label: { row(run) }
                    }
                    .onDelete { offsets in
                        Task { await delete(offsets, in: group.runs) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        Button(title) { filter = value }
            .buttonStyle(.bordered)
            .tint(filter == value ? .accentColor : .gray)
    }

    private func row(_ run: StoredRun) -> some View {
        HStack(spacing: 12) {
            Text(run.verdict?.score.map { "\(Int($0.rounded()))" } ?? "?")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 38, height: 30)
                .background(badgeColour(run), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(Trends.readable(run.site)).font(.body)
                Text(subtitle(run)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One distinguishing number, or the failure if there was one, which
    /// is what makes the list skimmable.
    private func subtitle(_ run: StoredRun) -> String {
        let time = run.finishedAt.formatted(date: .omitted, time: .shortened)
        if run.verdict?.segments["internet_path"] == "down" { return "\(time) \u{00B7} internet down" }
        if run.failedCount > 0 { return "\(time) \u{00B7} \(run.failedCount) failed" }
        if let mbps = run.downloadMbps { return "\(time) \u{00B7} \(Int(mbps)) Mbps" }
        return time
    }

    private func badgeColour(_ run: StoredRun) -> Color {
        switch run.verdict?.score {
        case .some(80...): return .green
        case .some(50..<80): return .orange
        case .some: return .red
        default: return .gray
        }
    }

    private func reload() async {
        runs = await AppStores.runs.all()
        sites = await AppStores.runs.sites()
        if let filter, !sites.contains(filter) { self.filter = nil }
    }

    private func delete(_ offsets: IndexSet, in group: [StoredRun]) async {
        for index in offsets { try? await AppStores.runs.delete(id: group[index].id) }
        await reload()
    }
}
