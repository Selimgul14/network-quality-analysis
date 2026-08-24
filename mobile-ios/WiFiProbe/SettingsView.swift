import SwiftUI
import WiFiProbeKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pending = 0
    @State private var runCount = 0
    @State private var confirmingWipe = false

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
                pending = await AppStores.pending.pendingCount
                runCount = await AppStores.runs.all().count
            }
            .alert("Delete all runs?", isPresented: $confirmingWipe) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        try? await AppStores.runs.deleteAll()
                        runCount = 0
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
