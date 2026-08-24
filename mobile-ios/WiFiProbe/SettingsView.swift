import SwiftUI
import WiFiProbeKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pending = 0
    @State private var runCount = 0
    @State private var confirmingWipe = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("This phone") {
                    LabeledContent("Probe id",
                                   value: (Bundle.main.object(
                                    forInfoDictionaryKey: "PROBE_ID") as? String) ?? "not set")
                    LabeledContent("Runs kept", value: "\(runCount)")
                    LabeledContent("Waiting to upload", value: "\(pending)")
                }

                Section {
                    Button("Delete all local runs", role: .destructive) {
                        confirmingWipe = true
                    }
                    if let deleteError {
                        Text(deleteError).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    // Uploaded records are the backend's, and there is no
                    // delete endpoint. Say so rather than implying the
                    // button reaches further than it does.
                    Text("Removes the history kept on this phone. Measurements already "
                         + "uploaded stay on the server.")
                }

                Section {
                    LabeledContent("Site prefix", value: SiteLabel.prefix)
                } footer: {
                    Text("Every measurement from this phone is filed under this prefix, "
                         + "which keeps it apart from the fixed probes.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // A single snapshot goes stale while the sheet is open:
                // the gear is reachable mid-run, and the pending count on
                // Now is now live (R6). Loop instead of sampling once;
                // SwiftUI cancels this task on its own when the sheet is
                // dismissed, so nothing needs to stop it by hand.
                while !Task.isCancelled {
                    pending = await AppStores.pending.pendingCount
                    runCount = await AppStores.runs.all().count
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .alert("Delete all runs?", isPresented: $confirmingWipe) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await AppStores.runs.deleteAll()
                            deleteError = nil
                        } catch {
                            // Do not claim success `runCount = 0` would
                            // imply. Show what actually happened and let
                            // the count below reflect what is really on
                            // disk after the attempt.
                            deleteError = "Could not delete every run: "
                                + error.localizedDescription
                        }
                        runCount = await AppStores.runs.all().count
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
