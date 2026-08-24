import SwiftUI
import WiFiProbeKit

struct ContentView: View {
    @State private var model = RunViewModel()

    var body: some View {
        NavigationStack {
            Form {
                siteSection
                if !model.steps.isEmpty { progressSection }
                if let outcome = model.outcome { resultSection(outcome) }
                if let verdict = model.verdict { verdictSection(verdict) }
                if let problem = model.verdictProblem { problemSection(problem) }
            }
            .navigationTitle("WiFi Probe")
            // One point, in the hierarchy, so the web workload's WKWebView
            // is not throttled as an off-screen view would be.
            .background(WebHostView().frame(width: 1, height: 1).opacity(0.01))
        }
    }

    // MARK: sections

    private var siteSection: some View {
        Section {
            HStack {
                Text(SiteLabel.prefix).foregroundStyle(.secondary)
                TextField("where you are", text: $model.siteInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button(action: { Task { await model.run() } }) {
                HStack {
                    if model.phase == .running || model.phase == .fetchingVerdict {
                        ProgressView().padding(.trailing, 6)
                    }
                    Text(runButtonTitle)
                }
            }
            .disabled(!model.canRun)
        } header: {
            Text("Network label")
        } footer: {
            // C2: the prefix keeps phone records out of the deployment
            // dataset the dissertation's analysis depends on.
            Text("Every measurement is filed under this label. The \(SiteLabel.prefix)"
                 + "prefix keeps it separate from the fixed probes.")
        }
    }

    private var runButtonTitle: String {
        switch model.phase {
        case .running: return "Measuring, about a minute"
        case .fetchingVerdict: return "Reading the verdict"
        default: return "Run measurements"
        }
    }

    private var progressSection: some View {
        Section("Measurements") {
            ForEach(model.steps) { step in
                HStack {
                    stateIcon(step.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(step.workload.rawValue) · \(step.endpoint.rawValue)")
                        if case .failed(let reason) = step.state {
                            Text(reason).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: RunStepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func resultSection(_ outcome: RunOutcome) -> some View {
        Section("This run") {
            LabeledContent("Uploaded", value: "\(outcome.recordCount) records")
            if outcome.failedCount > 0 {
                LabeledContent("Failed", value: "\(outcome.failedCount)")
            }
            if model.pendingUploads > 0 {
                LabeledContent("Waiting to upload", value: "\(model.pendingUploads)")
            }
            if let gateway = outcome.gateway {
                LabeledContent("Router", value: gateway)
                LabeledContent("WiFi link measured by", value: {
                    switch outcome.wifiLinkMethod {
                    case .icmp: return "ping"
                    case .firstHopTTL: return "TTL trace (router ignores ping)"
                    case .tcp: return "TCP (router ignores ping and TTL)"
                    case .none: return "not measurable here"
                    }
                }())
            }
            // Two causes are indistinguishable from the phone, so neither
            // is asserted. Some routers answer nothing at all by design,
            // which is what a managed campus network looks like.
            if outcome.gatewaySilentButInternetWorks {
                Text("Your router did not answer, but the internet did, so the WiFi link "
                     + "itself could not be timed. Either this app lacks local network "
                     + "access (Settings, Privacy & Security, Local Network), or the "
                     + "router is set up to ignore both ping and connections, which is "
                     + "common on managed networks. Everything beyond the router was "
                     + "still measured.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func verdictSection(_ verdict: Verdict) -> some View {
        Section {
            if let score = verdict.health?.score {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(score.rounded()))").font(.system(size: 46, weight: .semibold))
                    Text(verdict.health?.label ?? "").foregroundStyle(.secondary)
                }
            }
            if let headline = verdict.headline {
                Text(headline).font(.headline)
            }
            if let availability = verdict.health?.availability?.pct, availability < 100 {
                Text("\(availability, specifier: "%.0f")% of tasks completed")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(["wifi_link", "internet_path", "third_party"], id: \.self) { segment in
                HStack {
                    Circle().fill(colour(for: verdict.segments?[segment]))
                        .frame(width: 10, height: 10)
                    Text(segmentName(segment))
                    Spacer()
                    Text(verdict.segments?[segment] ?? "no data")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let rtt = verdict.wifiLinkRTTms {
                LabeledContent("WiFi link", value: String(format: "%.1f ms", rtt))
            }
        } header: {
            Text("Verdict")
        } footer: {
            if let caption = model.sampleCaption {
                // The verdict came from the backend, scored by the same
                // code that scores the fixed probes.
                Text(caption + " Scored by the same server-side logic as the fixed probes.")
            }
        }
    }

    private func problemSection(_ problem: String) -> some View {
        Section("Verdict") {
            Text(problem).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func segmentName(_ segment: String) -> String {
        switch segment {
        case "wifi_link": return "Your WiFi"
        case "internet_path": return "Internet path"
        default: return "Your services"
        }
    }

    private func colour(for status: String?) -> Color {
        switch status {
        case "ok": return .green
        case "suspect", "unstable": return .orange
        case "down": return .red
        default: return .gray
        }
    }
}
