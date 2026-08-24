import XCTest
@testable import WiFiProbeKit

/// The run sequence, tested with every network call stubbed. The uploader
/// is pointed at a stub that always fails, so every record stays in the
/// pending store where the test can inspect it: that also exercises M9,
/// since nothing may be lost when the upload cannot get through.
final class RunCoordinatorTests: XCTestCase {

    private var session: URLSession!
    private var config: ProbeConfig!
    private var store: PendingStore!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        store = PendingStore()
        config = ProbeConfig(
            probeID: "iphone13-selim", site: "phone-test",
            ingestURL: URL(string: "https://comp702-api.azurewebsites.net/ingest")!,
            ingestToken: "t",
            apiBase: URL(string: "https://comp702-api.azurewebsites.net")!,
            dashUser: "wifi", dashPass: "p",
            cloudBase: URL(string: "https://comp702-ref.azurewebsites.net")!,
            realWeb: URL(string: "https://www.bbc.co.uk/news")!,
            realVideo: URL(string: "https://example.com/clip.mp4")!,
            realDownload: URL(string: "http://example.com/50MB.zip")!)
    }

    /// `gatewayLoss: 100` simulates the gateway leg answering nothing (the
    /// ladder exhausted all three rungs); anything less simulates rung 1
    /// (echo) answering. Since Task 3, the gateway is measured once before
    /// the baseline group through an injected `gatewayRunner`, not through
    /// `baselineRunner`, so this stub never touches the real ladder or the
    /// real network: see the report's "gatewayRunner" note for why.
    private func coordinator(
        gateway: String? = "192.168.1.1",
        gatewayLoss: Double = 0,
        failing: Set<Workload> = [],
        offSiteLoss: Double = 0
    ) -> RunCoordinator {
        RunCoordinator(
            config: config,
            uploader: Uploader(config: config, session: session),
            store: store,
            runner: { workload, _, _ in
                if failing.contains(workload) {
                    throw NSError(domain: "test", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "stub failure"])
                }
                return ["stub_ms": .number(1)]
            },
            baselineRunner: { target in
                ["dns_ms": .number(1), "rtt_ms": .number(4.2),
                 "jitter_ms": .number(0.3), "loss_pct": .number(offSiteLoss)]
            },
            gatewayRunner: { _, _, _ in
                let answered = gatewayLoss < 100
                let summary = PingStats.Summary(rttMs: answered ? 4.2 : 0,
                                                jitterMs: answered ? 0.3 : 0,
                                                lossPct: gatewayLoss)
                let attempt = GatewayProbe.Attempt(
                    method: answered ? .icmp : .tcp, answered: answered,
                    detail: answered ? "4.2 ms" : "no candidate port answered")
                let result = GatewayProbe.Result(summary: summary,
                                                 method: answered ? .icmp : .none,
                                                 port: nil, attempts: [attempt])
                let metrics: [String: MetricValue] = [
                    "dns_ms": .number(1), "rtt_ms": .number(summary.rttMs),
                    "jitter_ms": .number(summary.jitterMs), "loss_pct": .number(summary.lossPct)]
                return (metrics, result)
            },
            gatewayLookup: { gateway },
            netHash: { "abc123def456" },
            settleSeconds: 0)
    }

    private func records() async -> [Record] {
        await store.take().map(\.record)
    }

    // MARK: identity

    /// One run_id per tap, as `run_heavy` uses one per cycle.
    func testEveryRecordSharesOneRunID() async {
        _ = await coordinator().run(site: "phone-test") { _ in }
        let ids = Set(await records().map(\.runID))
        XCTAssertEqual(ids.count, 1)
    }

    /// C2: nothing may reach the deployment dataset unlabelled or wearing
    /// a probe id that could be mistaken for the Pi's.
    func testEveryRecordCarriesThePhoneSiteAndProbeID() async {
        _ = await coordinator().run(site: "phone-halls-room") { _ in }
        for record in await records() {
            XCTAssertEqual(record.site, "phone-halls-room")
            XCTAssertEqual(record.probeID, "iphone13-selim")
            XCTAssertTrue(record.site!.hasPrefix("phone-"))
            XCTAssertFalse(record.probeID.hasPrefix("pi-"))
        }
    }

    func testEveryRecordValidatesAgainstTheContract() async throws {
        _ = await coordinator().run(site: "phone-test") { _ in }
        for record in await records() {
            try ContractValidator.validate(try record.jsonObject())
        }
    }

    // MARK: coverage and order

    func testRunCoversEveryWorkloadAndEndpointPair() async {
        _ = await coordinator().run(site: "phone-test") { _ in }
        let pairs = Set(await records().map { "\($0.workload.rawValue)/\($0.endpoint.rawValue)" })
        XCTAssertEqual(pairs, [
            "baseline/local", "baseline/cloud", "baseline/real",
            "path/local",
            "web/cloud", "web/real",
            "video/cloud", "video/real",
            "download/cloud", "download/real",
            "loadlat/real",
        ])
    }

    /// Bufferbloat must come last: it measures idle latency before it
    /// creates load, so anything still transferring would poison it.
    func testSaturatingWorkloadsRunLast() async {
        var order: [Workload] = []
        _ = await coordinator().run(site: "phone-test") { step in
            if case .running = step.state, !order.contains(step.workload) {
                order.append(step.workload)
            }
        }
        XCTAssertEqual(order.last, .loadlat)
        XCTAssertEqual(order.first, .baseline)
        let downloadIndex = order.firstIndex(of: .download)!
        XCTAssertLessThan(order.firstIndex(of: .web)!, downloadIndex)
        XCTAssertLessThan(order.firstIndex(of: .video)!, downloadIndex)
    }

    // MARK: the WiFi-link record (M10)

    /// A `path` record carrying `first_hop_rtt_ms` is the only thing that
    /// resolves the `wifi_link` segment in `compute_summary`.
    func testPathRecordCarriesOnlyTheFirstHopRTT() async throws {
        _ = await coordinator().run(site: "phone-test") { _ in }
        let all = await records()
        let path = try XCTUnwrap(all.first { $0.workload == .path })
        XCTAssertTrue(path.ok)
        XCTAssertEqual(path.metrics, ["first_hop_rtt_ms": .number(4.2)])
        // `hops` would assert something false about the path.
        XCTAssertNil(path.metrics["hops"])
    }

    /// The gateway is measured once, and the path record reuses that
    /// number rather than pinging the router a second time. Guards
    /// against a regression where the gateway leaked back into the
    /// parallel baseline group as well as the dedicated pre-group step,
    /// which `testRunCoversEveryWorkloadAndEndpointPair` could not catch
    /// since it collapses duplicates into a Set.
    func testGatewayIsMeasuredOnceAndReusedByThePathRecord() async throws {
        _ = await coordinator().run(site: "phone-test") { _ in }
        let gatewayBaselines = await records().filter {
            $0.workload == .baseline && $0.endpoint == .local
        }
        XCTAssertEqual(gatewayBaselines.count, 1)
    }

    func testNoGatewayMeansNoPathRecord() async {
        _ = await coordinator(gateway: nil).run(site: "phone-test") { _ in }
        let paths = await records().filter { $0.workload == .path }
        XCTAssertTrue(paths.isEmpty, "a path record with no gateway would be invented data")
    }

    /// A silent gateway must not be reported as a measured one.
    func testSilentGatewayProducesAFailedPathRecord() async throws {
        _ = await coordinator(gatewayLoss: 100).run(site: "phone-test") { _ in }
        let all = await records()
        let path = try XCTUnwrap(all.first { $0.workload == .path })
        XCTAssertFalse(path.ok)
        XCTAssertTrue(path.metrics.isEmpty)
    }

    /// Silence from the gateway while everything off-site answers is the
    /// signature of a refused local network permission on iOS, not a dead
    /// router. Reporting the second when it is the first would be exactly
    /// the misattribution this project exists to prevent.
    func testLocalNetworkPermissionIsDistinguishedFromADeadLink() async {
        let denied = await coordinator(gatewayLoss: 100, offSiteLoss: 0)
            .run(site: "phone-test") { _ in }
        XCTAssertTrue(denied.gatewaySilentButInternetWorks)

        let genuinelyOffline = await coordinator(gatewayLoss: 100, offSiteLoss: 100)
            .run(site: "phone-test") { _ in }
        XCTAssertFalse(genuinelyOffline.gatewaySilentButInternetWorks)
    }

    // MARK: failures

    /// M8: the backend's availability figure counts attempted-and-failed
    /// runs, so a skipped failure would let the phone score itself healthy
    /// during an outage.
    func testFailedWorkloadsStillProduceRecords() async throws {
        let outcome = await coordinator(failing: [.video, .download])
            .run(site: "phone-test") { _ in }
        let failures = await records().filter { !$0.ok }
        XCTAssertEqual(failures.count, 4, "two workloads times two endpoints")
        XCTAssertEqual(outcome.failedCount, 4)
        for record in failures {
            XCTAssertTrue(record.metrics.isEmpty)
            XCTAssertNotNil(record.error)
            try ContractValidator.validate(try record.jsonObject())
        }
    }

    /// M9: the upload fails exactly when the network is worst, which is
    /// when the measurement matters most. Nothing may be dropped.
    func testRecordsSurviveAnUnreachableBackend() async {
        let outcome = await coordinator().run(site: "phone-test") { _ in }
        let pending = await store.pendingCount
        XCTAssertEqual(pending, outcome.recordCount)
        XCTAssertGreaterThan(pending, 0)
    }

    func testProgressIsReportedForEveryStep() async {
        var running = 0, settled = 0
        let outcome = await coordinator().run(site: "phone-test") { step in
            switch step.state {
            case .running: running += 1
            case .ok, .failed: settled += 1
            case .pending: break
            }
        }
        XCTAssertEqual(running, outcome.recordCount)
        XCTAssertEqual(settled, outcome.recordCount)
    }

    // MARK: planned step count and progress fraction
    //
    // `RunViewModel.progressFraction` used to divide by `steps.count`,
    // a denominator that grows as work arrives and so falls back once
    // more steps land than the eleven it assumed. These tests pin down
    // the fixed denominator that replaced it.

    /// Computed against the same `Endpoints` calls `run(site:progress:)`
    /// itself uses, not a frozen number, so this tracks the config
    /// rather than freezing today's target list.
    func testPlannedStepCountWithGatewayMatchesEndpoints() {
        let offSite = Endpoints.baselineTargets(config: config, gateway: nil).count
        let applicationSteps = [Workload.web, .video, .download, .loadlat].reduce(0) {
            $0 + Endpoints.targets(for: $1, config: config).count
        }
        // The gateway leg and the WiFi-link path record, one step each.
        let expected = offSite + 1 + 1 + applicationSteps
        XCTAssertEqual(RunCoordinator.plannedStepCount(config: config, gatewayFound: true),
                       expected)
    }

    /// Cross-checked against an actual run: every record the stub
    /// coordinator produces should match the planned total when the
    /// gateway answers.
    func testPlannedStepCountWithGatewayMatchesARealRun() async {
        let outcome = await coordinator().run(site: "phone-test") { _ in }
        XCTAssertEqual(outcome.recordCount,
                       RunCoordinator.plannedStepCount(config: config, gatewayFound: true))
    }

    /// No gateway found drops both the gateway baseline step and the
    /// path record: exactly two fewer, not one. The off-site baseline
    /// count does not change, since `run(site:progress:)` always looks
    /// those up with `gateway: nil` regardless of whether the gateway
    /// leg ran.
    func testPlannedStepCountWithoutGatewayIsExactlyTwoLess() {
        let with = RunCoordinator.plannedStepCount(config: config, gatewayFound: true)
        let without = RunCoordinator.plannedStepCount(config: config, gatewayFound: false)
        XCTAssertEqual(with - without, 2)
    }

    /// Same cross-check as above, gateway absent.
    func testPlannedStepCountWithoutGatewayMatchesARealRun() async {
        let outcome = await coordinator(gateway: nil).run(site: "phone-test") { _ in }
        XCTAssertEqual(outcome.recordCount,
                       RunCoordinator.plannedStepCount(config: config, gatewayFound: false))
    }

    /// Fed the finished-step counts in the order a real run reports
    /// them (rising by exactly one at a time, planned total fixed),
    /// the fraction must never fall back and never exceed 1. This is
    /// the regression test for the bug: a denominator that moved with
    /// `steps.count` let the fraction reach 1 early, then retreat.
    func testProgressFractionIsMonotonicAcrossARun() {
        let planned = RunCoordinator.plannedStepCount(config: config, gatewayFound: true)
        var previous = 0.0
        for finished in 0...planned {
            let fraction = RunCoordinator.progressFraction(finished: finished, planned: planned)
            XCTAssertGreaterThanOrEqual(fraction, previous)
            XCTAssertLessThanOrEqual(fraction, 1)
            previous = fraction
        }
        XCTAssertEqual(previous, 1)
    }
}
