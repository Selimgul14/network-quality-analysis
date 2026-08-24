import SwiftUI
import WiFiProbeKit

/// The main screen: a score, a sentence, three lights, and one way in to
/// everything else.
///
/// Every number that used to be on this screen still exists; it moved to
/// `RunDetailView`, one tap away. Nothing was deleted, it was ranked.
struct NowView: View {
    @State private var model = RunViewModel()
    @State private var knownSites: [String] = []
    @State private var lastRun: StoredRun?
    @State private var showingDetail = false
    @State private var showingSteps = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SitePicker(selection: $model.siteInput, known: knownSites)

                    ScoreDial(score: model.savedRun?.verdict?.score,
                              label: model.savedRun?.verdict?.label,
                              progress: model.progressFraction,
                              isRunning: model.phase == .running
                                      || model.phase == .fetchingVerdict)
                        .padding(.top, 4)

                    headline
                    lastRunNote
                    if model.phase == .done { segments }
                    if let failures = failureNote { note(failures, .orange) }
                    if let problem = model.verdictProblem { note(problem, .secondary) }
                    if let warning = wifiLinkWarning { note(warning, .orange) }
                    runButton
                    if model.phase == .done { detailLink }
                    if model.phase == .running || model.phase == .fetchingVerdict {
                        stepDisclosure
                    }
                }
                .padding()
            }
            .navigationTitle("This network")
            .background(WebHostView().frame(width: 1, height: 1).opacity(0.01))
            .task {
                knownSites = await AppStores.runs.sites()
                lastRun = await AppStores.runs.all().first
            }
            .navigationDestination(isPresented: $showingDetail) {
                if let run = model.savedRun { RunDetailView(run: run) }
            }
        }
    }

    // MARK: pieces

    @ViewBuilder
    private var headline: some View {
        switch model.phase {
        case .running, .fetchingVerdict:
            Text(model.phase == .fetchingVerdict ? "Reading the verdict" : model.stageText)
                .font(.headline)
                .contentTransition(.opacity)
        case .done:
            VStack(spacing: 6) {
                Text(model.savedRun?.verdict?.headline ?? "Measured")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let pct = model.savedRun?.verdict?.availabilityPct, pct < 100 {
                    Text("\(Int(pct))% of tasks completed")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
        case .failed(let reason):
            Text(reason).font(.subheadline).foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .idle:
            Text(model.siteInput.isEmpty
                 ? "Pick a network, then test it"
                 : "Ready to test")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// What happened last time, so the screen is not blank on launch.
    @ViewBuilder
    private var lastRunNote: some View {
        if model.phase == .idle, let last = lastRun {
            Text("Last tested \(last.finishedAt.formatted(.relative(presentation: .named)))"
                 + (last.verdict?.score.map { ", scored \(Int($0.rounded()))" } ?? ""))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var segments: some View {
        VStack(spacing: 0) {
            ForEach(["wifi_link", "internet_path", "third_party"], id: \.self) { key in
                HStack {
                    Circle().fill(colour(model.savedRun?.verdict?.segments[key]))
                        .frame(width: 10, height: 10)
                    Text(name(key))
                    Spacer()
                    Text(state(model.savedRun?.verdict?.segments[key]))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                if key != "third_party" { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var runButton: some View {
        Button {
            Task {
                await model.run()
                knownSites = await AppStores.runs.sites()
                lastRun = await AppStores.runs.all().first
            }
        } label: {
            Text(model.phase == .running || model.phase == .fetchingVerdict
                 ? "Measuring..." : "Test this network")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canRun)
    }

    private var detailLink: some View {
        Button("See the numbers") { showingDetail = true }
            .font(.subheadline)
    }

    private var stepDisclosure: some View {
        DisclosureGroup("What it is doing", isExpanded: $showingSteps) {
            ForEach(model.steps) { step in
                HStack {
                    Text("\(step.workload.rawValue) \u{00B7} \(step.endpoint.rawValue)")
                        .font(.caption)
                    Spacer()
                    if case .failed = step.state {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else if step.state == .ok {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if step.state == .running {
                        ProgressView()
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private func note(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(colour)
            .multilineTextAlignment(.center)
    }

    /// What failed, as a consequence rather than as an error string. The
    /// raw text is on the detail screen; here a person needs to know that
    /// video was not tested, not that a URLSession task timed out.
    private var failureNote: String? {
        guard model.phase == .done, let run = model.savedRun else { return nil }
        let broken = Set(run.steps.filter { !$0.ok }.map(\.workload))
        guard !broken.isEmpty else { return nil }
        let names = broken.compactMap { workload -> String? in
            switch workload {
            case "web": return "loading a page"
            case "video": return "playing a video"
            case "download": return "downloading a file"
            case "loadlat": return "latency under load"
            case "baseline", "path": return "reaching the network"
            default: return nil
            }
        }.sorted()
        guard !names.isEmpty else { return nil }
        return names.count == 1
            ? "\(names[0].capitalized) could not be tested on this network."
            : "Some tests did not complete: \(names.joined(separator: ", "))."
    }

    /// Only shown when the ladder actually failed. Rung 1 works, so this
    /// should now be rare, and when it happens the detail screen lists
    /// what was tried.
    private var wifiLinkWarning: String? {
        guard model.phase == .done, let run = model.savedRun,
              run.wifiLinkMethod == "none" else { return nil }
        return "Your router answered nothing, so the WiFi link could not be timed. "
             + "Everything past the router was still measured. See the numbers for "
             + "what was tried."
    }

    private func name(_ key: String) -> String {
        switch key {
        case "wifi_link": return "Your WiFi"
        case "internet_path": return "Internet path"
        default: return "The services"
        }
    }

    private func state(_ value: String?) -> String {
        switch value {
        case "ok": return "fine"
        case "suspect": return "slow"
        case "unstable": return "patchy"
        case "down": return "down"
        default: return "no data"
        }
    }

    private func colour(_ value: String?) -> Color {
        switch value {
        case "ok": return .green
        case "suspect", "unstable": return .orange
        case "down": return .red
        default: return .gray
        }
    }
}
