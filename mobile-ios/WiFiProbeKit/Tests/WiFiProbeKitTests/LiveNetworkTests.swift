import XCTest
@testable import WiFiProbeKit

/// Integration tests against the real endpoints the probe uses. They skip
/// rather than fail when the network is unavailable, so the suite stays
/// usable offline. Runs that touch a network a Pi is also measuring must
/// be logged in RUNS.md (C3).
final class LiveNetworkTests: XCTestCase {

    private let cloudRef = URL(string: "https://comp702-ref.azurewebsites.net")!

    func testTCPHandshakeToTheBufferbloatAnchor() async throws {
        guard let rtt = await TCPProbe.handshakeMs(host: "1.1.1.1", port: 443) else {
            throw XCTSkip("1.1.1.1:443 unreachable")
        }
        XCTAssertGreaterThan(rtt, 0)
        XCTAssertLessThan(rtt, 3000)
        print("idle TCP RTT to 1.1.1.1: \(PingStats.round(rtt, 2)) ms")
    }

    /// The cloud reference drops ICMP, which is why this leg is a
    /// handshake probe rather than a ping.
    func testCloudReferenceAnswersTCPButNotICMP() async throws {
        let host = cloudRef.host!
        let summary = await TCPProbe.probe(host: host, count: 3, interval: 0.2)
        if summary.lossPct == 100 { throw XCTSkip("cloud reference unreachable") }
        XCTAssertGreaterThan(summary.rttMs, 0)
        print("cloud reference: \(summary.rttMs) ms, jitter \(summary.jitterMs) ms, "
              + "loss \(summary.lossPct)%")
    }

    func testBaselineWorkloadProducesTheContractsMetrics() async throws {
        let target = BaselineTarget(.cloud, cloudRef.host!, .tcp)
        let metrics: [String: MetricValue]
        do {
            metrics = try await BaselineWorkload.run(target: target, count: 3)
        } catch {
            throw XCTSkip("baseline unavailable: \(error)")
        }
        XCTAssertEqual(Set(metrics.keys),
                       ["dns_ms", "rtt_ms", "jitter_ms", "loss_pct", "tcp_mode"])
        XCTAssertEqual(metrics["tcp_mode"], .number(1))
    }

    func testDownloadAgainstTheCloudReference() async throws {
        let target = cloudRef.appendingPathComponent("/files/testfile.bin")
        let metrics: [String: MetricValue]
        do {
            metrics = try await DownloadWorkload.run(target: target)
        } catch {
            throw XCTSkip("cloud reference download unavailable: \(error)")
        }
        guard case .number(let mbps)? = metrics["throughput_mbps"],
              case .number(let bytes)? = metrics["bytes"] else {
            return XCTFail("missing metrics")
        }
        XCTAssertGreaterThan(bytes, 1_000_000, "the reference file is 25 MiB")
        XCTAssertGreaterThan(mbps, 0)
        print("download: \(mbps) Mbps over \(Int(bytes)) bytes")
    }

    /// End to end on the real video target: metadata, transfer, and the
    /// player simulation, producing the contract's seven video metrics.
    func testVideoWorkloadAgainstTheRealTarget() async throws {
        let target = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/"
                         + "Big_Buck_Bunny_720_10s_1MB.mp4")!
        let metrics: [String: MetricValue]
        do {
            metrics = try await VideoWorkload.run(target: target)
        } catch {
            throw XCTSkip("real video target unavailable: \(error)")
        }
        XCTAssertEqual(Set(metrics.keys), ["startup_ms", "rebuffer_count", "rebuffer_ms",
                                           "stream_mbps", "bitrate_mbps", "headroom_x",
                                           "quality_tier"])
        if case .number(let headroom)? = metrics["headroom_x"] {
            XCTAssertGreaterThan(headroom, 0)
        }
        print("video: \(metrics)")
    }

    func testMedianMatchesTheProbesDefinition() {
        XCTAssertEqual(LoadLatWorkload.median([3, 1, 2]), 2)
        XCTAssertEqual(LoadLatWorkload.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(LoadLatWorkload.median([]), 0)
    }
}
