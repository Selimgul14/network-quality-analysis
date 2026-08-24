import Foundation

public enum RunStepState: Sendable, Equatable {
    case pending, running, ok
    case failed(String)
}

public struct RunStep: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let workload: Workload
    public let endpoint: Endpoint
    public let target: String
    public var state: RunStepState

    public init(workload: Workload, endpoint: Endpoint, target: String) {
        self.id = UUID()
        self.workload = workload
        self.endpoint = endpoint
        self.target = target
        self.state = .pending
    }
}

public struct RunOutcome: Sendable {
    public let runID: String
    public let site: String
    public let startedAt: Date
    public let finishedAt: Date
    public let recordCount: Int
    public let failedCount: Int
    public let gateway: String?
    /// How the WiFi link was measured, if at all: by ICMP echo, by TCP
    /// once the router ignored echo, or not at all.
    public let wifiLinkMethod: GatewayProbe.Method
    /// Every rung of the ladder that was tried, in order, so the screen
    /// can show what happened instead of guessing between two causes.
    public let wifiLinkAttempts: [GatewayProbe.Attempt]
    /// Total silence from the gateway while off-site targets answered.
    /// Two causes look identical from here and neither may be asserted:
    /// a refused local network permission, and a router configured to
    /// answer nothing (observed on a campus WLAN, 21 August 2026).
    public let gatewaySilentButInternetWorks: Bool
    /// The throughput this run measured, for the on-device chart. The
    /// verdict does not carry it, so it comes from the run's own record.
    public let downloadMbps: Double?

    public init(runID: String, site: String, startedAt: Date, finishedAt: Date,
                recordCount: Int, failedCount: Int, gateway: String?,
                wifiLinkMethod: GatewayProbe.Method,
                wifiLinkAttempts: [GatewayProbe.Attempt],
                gatewaySilentButInternetWorks: Bool,
                downloadMbps: Double? = nil) {
        self.runID = runID
        self.site = site
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.recordCount = recordCount
        self.failedCount = failedCount
        self.gateway = gateway
        self.wifiLinkMethod = wifiLinkMethod
        self.wifiLinkAttempts = wifiLinkAttempts
        self.gatewaySilentButInternetWorks = gatewaySilentButInternetWorks
        self.downloadMbps = downloadMbps
    }
}

/// Dispatches one workload against one target. Injectable so the run
/// sequence can be tested without a network.
public typealias WorkloadRunner =
    @Sendable (Workload, Endpoint, URL) async throws -> [String: MetricValue]

/// Same idea for the baseline pass, which takes a destination class
/// rather than a URL.
public typealias BaselineRunner =
    @Sendable (BaselineTarget) async throws -> [String: MetricValue]

/// The gateway leg, which needs the ladder's verdict as well as its
/// numbers. Injectable for the same reason `baselineRunner` is: so the
/// coordinator's plumbing (one gateway measurement, reused by the path
/// record) can be tested without a router, rather than only through
/// `BaselineWorkload.runGateway`'s live network calls.
public typealias GatewayRunner =
    @Sendable (String, Int, TimeInterval) async -> (metrics: [String: MetricValue],
                                                     result: GatewayProbe.Result)

/// Builds records and sequences a run, mirroring `probe/scheduler.py`.
///
/// One `run_id` per tap, as `run_heavy` uses one per cycle. Workloads run
/// sequentially with the saturating ones last: running them together
/// would be the contamination problem of C3 in miniature, the app
/// competing with itself for the link it is trying to measure.
public struct RunCoordinator: Sendable {

    private let config: ProbeConfig
    private let uploader: Uploader
    private let store: PendingStore
    private let runner: WorkloadRunner
    private let baselineRunner: BaselineRunner
    private let gatewayRunner: GatewayRunner
    private let gatewayLookup: @Sendable () async -> String?
    private let settleSeconds: TimeInterval
    private let netHash: @Sendable () async -> String?

    public init(config: ProbeConfig,
                uploader: Uploader,
                store: PendingStore,
                runner: @escaping WorkloadRunner = RunCoordinator.liveRunner,
                baselineRunner: BaselineRunner? = nil,
                gatewayRunner: @escaping GatewayRunner = { host, count, interval in
                    await BaselineWorkload.runGateway(host: host, count: count, interval: interval)
                },
                gatewayLookup: @escaping @Sendable () async -> String? = {
                    try? await GatewayCache.shared.address()
                },
                netHash: @escaping @Sendable () async -> String? = {
                    await NetID.shared.hash()
                },
                settleSeconds: TimeInterval = 2.0) {
        self.config = config
        self.uploader = uploader
        self.store = store
        self.runner = runner
        let pingCount = config.pingCount
        let pingInterval = config.pingInterval
        self.baselineRunner = baselineRunner ?? { target in
            try await BaselineWorkload.run(target: target, count: pingCount,
                                           interval: pingInterval)
        }
        self.gatewayRunner = gatewayRunner
        self.gatewayLookup = gatewayLookup
        self.netHash = netHash
        self.settleSeconds = settleSeconds
    }

    /// The order matters. Baseline first because it is cheap and wants a
    /// quiet link; the two saturating workloads last, bufferbloat last of
    /// all because it must measure idle latency before it creates load.
    private static let applicationOrder: [Workload] = [.web, .video, .download, .loadlat]

    public func run(site: String,
                    progress: @Sendable @escaping (RunStep) -> Void) async -> RunOutcome {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let startedAt = Date()
        let fingerprint = await netHash()
        var failed = 0
        var produced = 0
        let baselineRunner = self.baselineRunner

        func emit(_ step: RunStep, _ metrics: [String: MetricValue]?, _ error: Error?) async {
            var step = step
            if let error {
                step.state = .failed(String(describing: error))
                failed += 1
            } else {
                step.state = .ok
            }
            progress(step)
            // M8: a failed run is a data point. The backend's availability
            // calculation counts attempted-and-failed runs, so skipping
            // one would let the phone score itself healthy during an
            // outage, which is the bug the 18 August replay exposed.
            let record = Record(
                probeID: config.probeID, site: site, runID: runID,
                workload: step.workload, endpoint: step.endpoint, target: step.target,
                ok: error == nil, error: error.map { String(describing: $0) },
                metrics: metrics ?? [:], netHash: fingerprint)
            await store.add(record)
            produced += 1
        }

        // 1. The gateway leg on its own, before the parallel group: it
        //    needs the ladder's verdict as well as its numbers, and it
        //    feeds the path record below. Flushed first because the phone
        //    may have joined a different network since the last run.
        await GatewayCache.shared.flush()
        let gateway = await gatewayLookup()

        var gatewayRTT: Double?
        var gatewayMethod: GatewayProbe.Method = .none
        var gatewayAttempts: [GatewayProbe.Attempt] = []
        var gatewaySilent = false
        var offSiteReachable = false
        var downloadMbps: Double?

        if let gateway {
            var step = RunStep(workload: .baseline, endpoint: .local, target: gateway)
            step.state = .running
            progress(step)
            let (metrics, result) = await gatewayRunner(gateway, config.pingCount,
                                                         config.pingInterval)
            gatewayMethod = result.method
            gatewayAttempts = result.attempts
            if result.summary.lossPct >= 100 {
                gatewaySilent = true
            } else {
                gatewayRTT = result.summary.rttMs
            }
            await emit(step, metrics, nil)
        }

        // 2. Baseline across every off-site destination class, in
        //    parallel as `run_baseline` does: four sequential runs would
        //    not fit. The gateway is excluded here since it was just
        //    measured above.
        let baselineTargets = Endpoints.baselineTargets(config: config, gateway: nil)

        await withTaskGroup(of: (BaselineTarget, Result<[String: MetricValue], Error>).self) { group in
            for target in baselineTargets {
                group.addTask {
                    do {
                        let metrics = try await baselineRunner(target)
                        return (target, .success(metrics))
                    } catch {
                        return (target, .failure(error))
                    }
                }
            }
            for await (target, result) in group {
                var step = RunStep(workload: .baseline, endpoint: target.endpoint,
                                   target: target.host)
                step.state = .running
                progress(step)
                switch result {
                case .success(let metrics):
                    if case .number(let loss)? = metrics["loss_pct"], loss < 100 {
                        offSiteReachable = true
                    }
                    await emit(step, metrics, nil)
                case .failure(let error):
                    await emit(step, nil, error)
                }
            }
        }

        // 3. The WiFi-link record (M10). Reuses the gateway RTT just
        //    measured rather than pinging the router twice.
        if let gateway {
            var step = RunStep(workload: .path, endpoint: .local, target: gateway)
            step.state = .running
            progress(step)
            if let rtt = gatewayRTT {
                await emit(step, PathWorkload.firstHopMetrics(gatewayRTTms: rtt), nil)
            } else {
                await emit(step, nil, PathWorkload.PathFailure.gatewaySilent(host: gateway))
            }
        }

        await uploader.drain(store)

        // 4. Application workloads, sequential, saturating ones last.
        for workload in Self.applicationOrder {
            for target in Endpoints.targets(for: workload, config: config) {
                var step = RunStep(workload: workload, endpoint: target.endpoint,
                                   target: target.url.absoluteString)
                step.state = .running
                progress(step)
                do {
                    let metrics = try await runner(workload, target.endpoint, target.url)
                    if workload == .download,
                       case .number(let mbps)? = metrics["throughput_mbps"] {
                        downloadMbps = mbps
                    }
                    await emit(step, metrics, nil)
                } catch {
                    await emit(step, nil, error)
                }
                // Let the link settle so one workload's transfer is not
                // still draining while the next one measures.
                if settleSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
                }
            }
            await uploader.drain(store)
        }

        return RunOutcome(
            runID: runID, site: site, startedAt: startedAt, finishedAt: Date(),
            recordCount: produced, failedCount: failed, gateway: gateway,
            wifiLinkMethod: gatewayMethod,
            wifiLinkAttempts: gatewayAttempts,
            gatewaySilentButInternetWorks: gatewaySilent && offSiteReachable,
            downloadMbps: downloadMbps)
    }

    /// Dispatches to the real workload modules. Exhaustive on purpose: a
    /// `default` branch here is how `scheduler._record` once silently ran
    /// the wrong module for `path`, so that mtr never executed at all.
    public static let liveRunner: WorkloadRunner = liveRunner(webHost: { nil })

    /// - Parameter webHost: the view to mount the web view in. The system
    ///   throttles off-screen web views, so the app supplies a real one;
    ///   passing nil is for headless use only.
    public static func liveRunner(
        webHost: @escaping @MainActor @Sendable () -> PlatformView?
    ) -> WorkloadRunner {
        { workload, _, target in
        switch workload {
        case .web:
            let worker = await WebWorkload()
            return try await worker.run(target: target, host: webHost())
        case .video:
            return try await VideoWorkload.run(target: target)
        case .download:
            return try await DownloadWorkload.run(target: target)
        case .loadlat:
            return try await LoadLatWorkload.run(target: target)
        case .baseline, .path, .email:
            throw RunnerFailure.notDispatchedHere(workload.rawValue)
        }
        }
    }

    public enum RunnerFailure: Error, Equatable {
        case notDispatchedHere(String)
    }
}
