import Foundation
import WiFiProbeKit

/// The two on-disk stores, shared by every screen.
///
/// Created once rather than per view: two `RunStore` actors over the same
/// directory would not corrupt anything, since a run is written once and
/// never edited, but they would disagree about what is there until both
/// re-read it.
enum AppStores {
    static let runs: RunStore = {
        let directory = (try? RunStore.defaultDirectory())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runs")
        return RunStore(directory: directory)
    }()

    static let pending: PendingStore = {
        PendingStore(directory: try? PendingStore.defaultDirectory())
    }()
}
