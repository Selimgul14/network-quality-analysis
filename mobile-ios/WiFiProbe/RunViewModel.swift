import Foundation
import Observation
import WiFiProbeKit

/// Drives one measurement run and holds what the screen shows.
///
/// It deliberately computes nothing about the results. Thresholds,
/// attribution and the health score all live in the backend's
/// `summary.py`, so a phone and the Pi are scored by identical code (M6).
@MainActor
@Observable
final class RunViewModel {

    enum Phase: Equatable {
        case idle
        case running
        case fetchingVerdict
        case done
        case failed(String)
    }

    var siteInput = ""
    private(set) var phase: Phase = .idle
    private(set) var steps: [RunStep] = []
    private(set) var outcome: RunOutcome?
    private(set) var verdict: Verdict?
    private(set) var verdictProblem: String?
    private(set) var pendingUploads = 0

    private let store = PendingStore()

    var canRun: Bool {
        SiteLabel.make(from: siteInput) != nil && phase != .running && phase != .fetchingVerdict
    }

    /// C2: the prefix is applied by the app, not typed, and an empty
    /// label is refused outright. An unlabelled phone record is the one
    /// outcome that would be hard to unpick from the deployment dataset.
    var resolvedSite: String? { SiteLabel.make(from: siteInput) }

    func run() async {
        guard let site = resolvedSite else { return }
        steps = []
        verdict = nil
        verdictProblem = nil
        outcome = nil
        phase = .running

        let config: ProbeConfig
        do {
            config = try AppConfig.load(site: site)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let uploader = Uploader(config: config)
        let coordinator = RunCoordinator(
            config: config,
            uploader: uploader,
            store: store,
            runner: RunCoordinator.liveRunner(webHost: { WebHost.shared.view }))

        let result = await coordinator.run(site: site) { [weak self] step in
            Task { @MainActor in self?.apply(step) }
        }
        outcome = result
        pendingUploads = await store.pendingCount

        // Anything still queued is retried before the verdict is read, so
        // the window the backend scores actually contains this run.
        if pendingUploads > 0 {
            await uploader.drain(store)
            pendingUploads = await store.pendingCount
        }

        phase = .fetchingVerdict
        await fetchVerdict(config: config, site: site, at: result.finishedAt)
        phase = .done
    }

    private func fetchVerdict(config: ProbeConfig, site: String, at: Date) async {
        guard AppConfig.hasDashboardPassword else {
            verdictProblem = "No dashboard password set, so the verdict cannot be read. "
                + "The measurements were still uploaded."
            return
        }
        do {
            // Anchored on the run's completion with `?at=`, the parameter
            // added for the outage replay: a phone run is a single moment,
            // and anchoring guarantees its records fall inside the window.
            verdict = try await SummaryClient(config: config)
                .fetch(site: site, hours: 1, at: at)
        } catch SummaryClient.Failure.unauthorised {
            verdictProblem = "The dashboard rejected the credentials. "
                + "Check DASH_PASS in Secrets.xcconfig."
        } catch {
            // Never invent a verdict: say it could not be read.
            verdictProblem = "Measurements uploaded, but the verdict could not be read: "
                + "\(error)"
        }
    }

    private func apply(_ step: RunStep) {
        if let index = steps.firstIndex(where: {
            $0.workload == step.workload && $0.endpoint == step.endpoint
                && $0.target == step.target
        }) {
            steps[index].state = step.state
        } else {
            steps.append(step)
        }
    }

    /// M6 disclosure. A run yields one sample per workload and endpoint,
    /// so every median in the verdict rests on a single number and
    /// `summary.py` has no notion of a sample too thin to judge. The app
    /// knows exactly how many records it posted, so it says so rather
    /// than presenting one run as settled.
    var sampleCaption: String? {
        guard let outcome else { return nil }
        return "Based on \(outcome.recordCount) measurements from one run, "
             + "a single sample per test. Run again to build confidence."
    }
}
