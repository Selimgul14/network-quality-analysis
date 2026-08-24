import SwiftUI
import WiFiProbeKit

/// Choosing the network label, from the ones already used plus a new one.
///
/// This replaces a free-text field. History and Trends are keyed on the
/// label, so a typo silently creates a second network, and a stray label
/// is how `phone-smoke-test` ended up in the deployment database.
struct SitePicker: View {
    @Binding var selection: String
    var known: [String]
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        Menu {
            ForEach(known, id: \.self) { site in
                Button {
                    selection = site
                } label: {
                    Label(Trends.readable(site),
                          systemImage: site == selection ? "checkmark" : "wifi")
                }
            }
            if !known.isEmpty { Divider() }
            Button("New network...") { draft = ""; adding = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wifi")
                Text(selection.isEmpty ? "Choose a network"
                                       : Trends.readable(selection))
                    .fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(selection.isEmpty ? .secondary : .primary)
        }
        .alert("Name this network", isPresented: $adding) {
            TextField("home, library, the cafe", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Use it") {
                if let label = SiteLabel.make(from: draft) { selection = label }
            }
        } message: {
            Text("Whatever you call the place you are in. Results are grouped by it.")
        }
    }
}
