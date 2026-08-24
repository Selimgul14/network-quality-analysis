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
    /// The one plain line shown while a run is in progress, instead of
    /// eleven rows naming workloads and endpoints.
    private(set) var stageText = ""
    /// How far through, for the ring. The denominator is the number of
    /// steps this run will actually produce, reported by
    /// `RunCoordinator.run`'s `plan` callback right after the gateway
    /// lookup resolves and held fixed for the rest of the run, so the
    /// fraction only rises as steps finish and never falls back the way
    /// dividing by the live `steps.count` did.
    private(set) var progressFraction: Double = 0
    /// The run just written to disk.
    private(set) var savedRun: StoredRun?
    /// The planned total for the run in progress. Nil until
    /// `RunCoordinator.run`'s `plan` callback fires (right after the
    /// gateway lookup resolves, before any step), so `progressFraction`
    /// has nothing meaningful to report before that beyond its initial 0.
    private var plannedSteps: Int?
    /// R6: `pendingUploads` used to be sampled three times, all at or
    /// after `coordinator.run()` returned, so a queue that filled and
    /// drained mid-run (the exact case the interruption test watches for)
    /// was invisible between those samples. This task re-reads the store
    /// every couple of seconds for as long as a run is in progress or
    /// something is still queued, and stops itself otherwise, so nothing
    /// polls while the screen is idle.
    private var pendingWatch: Task<Void, Never>?

    private static let stageNames: [Workload: String] = [
        .baseline: "Checking the connection",
        .path: "Timing your WiFi link",
        .web: "Loading a web page",
        .video: "Starting a video",
        .download: "Testing download speed",
        .loadlat: "Checking latency under load",
        .email: "Checking email",
    ]

    /// The plain-English phrase for a workload, shared between the live
    /// stage text and the Now screen's step disclosure, so a run in
    /// progress never shows a raw identifier like `loadlat` or `cloud`.
    static func stageName(for workload: Workload) -> String {
        stageNames[workload] ?? workload.rawValue
    }

    private let store = AppStores.pending

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
        plannedSteps = nil
        progressFraction = 0
        // Cleared so a screen gated on `.failed` cannot still show the
        // previous run's dial score and tint underneath the error text.
        savedRun = nil
        phase = .running
        startPendingWatch()

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

        let result = await coordinator.run(
            site: site,
            plan: { [weak self] planned in
                Task { @MainActor in self?.plannedSteps = planned }
            }
        ) { [weak self] step in
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

        // Written after the verdict so the stored run carries it. A run
        // reopened later shows what it showed at the time, which is why
        // the verdict is snapshotted rather than refetched. Assigned
        // before `phase` flips to `.done` so nothing gated on `.done`
        // can observe that phase with `savedRun` still nil.
        let stored = StoredRun.from(outcome: result, steps: steps, verdict: verdict)
        savedRun = stored
        phase = .done
        try? await AppStores.runs.save(stored)
        pendingUploads = await store.pendingCount
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

    /// R6, part 2. Runs on the main actor (this class is `@MainActor`, and
    /// a plain `Task {}` created here inherits that), so assigning
    /// `pendingUploads` needs no hop back. Stops itself once nothing is
    /// queued and no run is in progress, rather than running forever.
    private func startPendingWatch() {
        pendingWatch?.cancel()
        pendingWatch = Task { [weak self] in
            while let self, !Task.isCancelled {
                let count = await self.store.pendingCount
                guard !Task.isCancelled else { return }
                self.pendingUploads = count
                let runInProgress = self.phase == .running || self.phase == .fetchingVerdict
                if count == 0 && !runInProgress { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
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
        stageText = Self.stageNames[step.workload] ?? step.workload.rawValue
        let finished = steps.filter { $0.state != .pending && $0.state != .running }.count
        progressFraction = RunCoordinator.progressFraction(finished: finished,
                                                            planned: plannedSteps ?? 0)
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
