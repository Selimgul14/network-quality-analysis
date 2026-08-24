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
