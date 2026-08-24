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
    @State private var showingSettings = false

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
                    if model.pendingUploads > 0 { pendingNote }
                    if model.phase == .running || model.phase == .fetchingVerdict {
                        stepDisclosure
                    }
                }
                .padding()
            }
            .navigationTitle("This network")
            .background(WebHostView().frame(width: 1, height: 1).opacity(0.01))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .task {
                knownSites = await AppStores.runs.sites()
                lastRun = await AppStores.runs.all().first
                // A queue can be left over from before launch (app killed
                // with something still pending). Sample it now, try a
                // drain, and start the live watch if anything remains,
                // rather than leaving the screen silent until a new run.
                await model.checkPendingOnLaunch()
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

    /// R6: this reads `model.pendingUploads`, an `@Observable` property
    /// that `RunViewModel` now keeps fresh with a background watch rather
    /// than a single sample, so this line updates on its own while a run
    /// is interrupted and drains once the network returns. No polling
    /// lives in the view.
    private var pendingNote: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Waiting to upload: \(model.pendingUploads)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var stepDisclosure: some View {
        DisclosureGroup("What it is doing", isExpanded: $showingSteps) {
            ForEach(model.steps) { step in
                HStack {
                    // Plain-English stage phrase, not the raw workload and
                    // endpoint identifiers (`loadlat`, `cloud`). Identifiers
                    // belong on the detail screen, not here.
                    Text(RunViewModel.stageName(for: step.workload))
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
            case "email": return "checking email"
            case "download": return "downloading a file"
            case "loadlat": return "latency under load"
            case "baseline", "path": return "reaching the network"
            default: return nil
            }
        }.sorted()
        // A workload with no display string must never suppress the note:
        // say something did not complete rather than saying nothing.
        guard !names.isEmpty else {
            return "Some tests did not complete on this network."
        }
        return names.count == 1 && broken.count == 1
            ? "\(sentenceCase(names[0])) could not be tested on this network."
            : "Some tests did not complete: \(names.joined(separator: ", "))."
    }

    /// Uppercases only the first character. `String.capitalized` title-cases
    /// every word ("Loading A Page could not be tested..."), which reads as
    /// a heading rather than a sentence.
    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
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
