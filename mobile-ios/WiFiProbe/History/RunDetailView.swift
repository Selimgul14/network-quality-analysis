import SwiftUI
import WiFiProbeKit

/// One run, in full: what was measured, against what, and what failed.
///
/// The Now screen is deliberately thin, which is only safe because
/// everything it leaves out is here. This is also the screenshot for the
/// evaluation chapter, since it shows the phone's own evidence beside the
/// verdict the backend returned for it.
struct RunDetailView: View {
    let run: StoredRun

    private var stamp: String {
        run.finishedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        List {
            Section("Verdict") {
                if let verdict = run.verdict {
                    LabeledContent("Score", value: verdict.score.map {
                        "\(Int($0.rounded())) \(verdict.label ?? "")"
                    } ?? "not scored")
                    if let quality = verdict.quality {
                        LabeledContent("Quality", value: String(format: "%.0f", quality))
                    }
                    if let availability = verdict.availabilityPct {
                        LabeledContent("Tasks completed",
                                       value: String(format: "%.0f%%", availability))
                    }
                    if let headline = verdict.headline { Text(headline).font(.callout) }
                    ForEach(verdict.segments.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabeledContent($0.key, value: $0.value)
                    }
                } else {
                    Text("The verdict could not be read for this run.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("The WiFi link") {
                LabeledContent("Router", value: run.gateway ?? "not found")
                LabeledContent("Measured by", value: methodName(run.wifiLinkMethod))
                if let rtt = run.verdict?.wifiLinkRTTms {
                    LabeledContent("Round trip", value: String(format: "%.1f ms", rtt))
                }
                ForEach(Array(run.wifiLinkAttempts.enumerated()), id: \.offset) { _, attempt in
                    HStack {
                        Image(systemName: attempt.answered
                              ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(attempt.answered ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(methodName(attempt.method)).font(.subheadline)
                            Text(attempt.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Measurements") {
                ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: step.ok ? "checkmark.circle.fill"
                                                      : "xmark.circle.fill")
                                .foregroundStyle(step.ok ? .green : .red)
                            Text("\(step.workload) \u{00B7} \(step.endpoint)")
                                .font(.subheadline)
                        }
                        Text(step.target).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let error = step.error {
                            Text(error).font(.caption2).foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Uploaded", value: "\(run.recordCount) records")
                if run.failedCount > 0 {
                    LabeledContent("Failed", value: "\(run.failedCount)")
                }
                LabeledContent("Network label", value: run.site)
                LabeledContent("Run id", value: run.id).font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("This run")
            } footer: {
                // M6 disclosure, unchanged in substance from the old screen.
                Text("Based on \(run.recordCount) measurements from one run, a single "
                     + "sample per test. Scored by the same server-side logic as the "
                     + "fixed probes.")
            }
        }
        .navigationTitle(Trends.readable(run.site))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(Trends.readable(run.site)).font(.headline)
                    Text(stamp).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func methodName(_ raw: String) -> String {
        switch raw {
        case "icmp": return "Ping to the router"
        case "firstHopTTL": return "Expiring TTL at the first hop"
        case "tcp": return "TCP to the router"
        default: return "Nothing answered"
        }
    }
}
