import SwiftUI
import WiFiProbeKit

struct RootView: View {
    var body: some View {
        TabView {
            NowView()
                .tabItem { Label("Now", systemImage: "gauge.with.dots.needle.67percent") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar") }
        }
    }
}

// Replaced in Tasks 9 and 10.
struct HistoryView: View { var body: some View { Text("History") } }
struct TrendsView: View { var body: some View { Text("Trends") } }

// Replaced in Task 9.
struct RunDetailView: View {
    let run: StoredRun
    var body: some View { Text("Detail") }
}
