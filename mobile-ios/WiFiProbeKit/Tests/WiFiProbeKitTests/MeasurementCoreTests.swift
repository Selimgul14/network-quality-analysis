import XCTest
@testable import WiFiProbeKit

/// The pure measurement logic: everything that decides what a number
/// *means*, tested without a network or a device.
final class PingStatsTests: XCTestCase {

    func testMeanAndPopulationStandardDeviation() {
        let summary = PingStats.summarise(rtts: [10, 20], sent: 2)
        XCTAssertEqual(summary.rttMs, 15, accuracy: 0.001)
        // Population stdev of [10, 20] is 5; the sample stdev would be 7.07.
        XCTAssertEqual(summary.jitterMs, 5, accuracy: 0.001)
        XCTAssertEqual(summary.lossPct, 0, accuracy: 0.001)
    }

    /// Ten packets is what the probe sends, so loss quantises in 10% steps
    /// rather than the 20% steps that once drew a full-height bar for a
    /// single lost packet.
    func testLossQuantisesInTenPercentSteps() {
        XCTAssertEqual(PingStats.summarise(rtts: Array(repeating: 12, count: 9), sent: 10).lossPct,
                       10.0, accuracy: 0.001)
        XCTAssertEqual(PingStats.summarise(rtts: Array(repeating: 12, count: 8), sent: 10).lossPct,
                       20.0, accuracy: 0.001)
    }

    /// Everything lost is a measurement, not an absence: the record still
    /// says the target was probed and nothing came back.
    func testTotalLossReportsZeroedTimings() {
        let summary = PingStats.summarise(rtts: [], sent: 10)
        XCTAssertEqual(summary, PingStats.Summary(rttMs: 0, jitterMs: 0, lossPct: 100))
    }

    func testSingleReplyHasNoJitter() {
        XCTAssertEqual(PingStats.summarise(rtts: [7.5], sent: 1).jitterMs, 0)
    }
}

final class NavigationTimingTests: XCTestCase {

    private let entry: [String: Double] = [
        "startTime": 0,
        "domainLookupStart": 12.0, "domainLookupEnd": 30.5,
        "connectStart": 30.5, "connectEnd": 88.25,
        "requestStart": 90.0, "responseStart": 310.0,
        "loadEventEnd": 1842.75,
    ]

    func testMapsTheSameFourNumbersAsTheProbe() throws {
        let metrics = try NavigationTiming.metrics(from: entry)
        XCTAssertEqual(metrics["dns_ms"], .number(18.5))
        XCTAssertEqual(metrics["connect_ms"], .number(57.75))
        XCTAssertEqual(metrics["ttfb_ms"], .number(220.0))
        XCTAssertEqual(metrics["load_ms"], .number(1842.75))
        XCTAssertEqual(metrics.count, 4)
    }

    func testMissingFieldThrowsRatherThanReportingZero() {
        var broken = entry
        broken.removeValue(forKey: "responseStart")
        XCTAssertThrowsError(try NavigationTiming.metrics(from: broken)) { error in
            XCTAssertEqual(error as? NavigationTiming.Failure, .missingField("responseStart"))
        }
    }

    func testParsesTheJSONTheBrowserReturns() throws {
        let json = """
        {"startTime":0,"domainLookupStart":1,"domainLookupEnd":3,\
        "connectStart":3,"connectEnd":9,"requestStart":10,\
        "responseStart":60,"loadEventEnd":500}
        """
        let metrics = try NavigationTiming.metrics(fromJSON: json)
        XCTAssertEqual(metrics["dns_ms"], .number(2))
        XCTAssertEqual(metrics["load_ms"], .number(500))
    }
}

final class VideoSimulatorTests: XCTestCase {

    /// 64 KiB every 10 ms against a 2 Mbps clip: far faster than playback,
    /// so the buffer never empties.
    private func fastChunks(count: Int) -> [VideoSimulator.Chunk] {
        (1...count).map { .init(bytes: 65_536, at: Double($0) * 0.01) }
    }

    func testHealthyDeliveryNeverRebuffers() {
        let result = VideoSimulator.simulate(chunks: fastChunks(count: 200),
                                             bitrateBps: 2_000_000,
                                             durationSeconds: 10)
        XCTAssertEqual(result.rebufferCount, 0)
        XCTAssertEqual(result.rebufferMs, 0)
        // 2 s of a 2 Mbps clip is 500 KB, so the 8th 64 KiB chunk starts
        // playback, at 80 ms in.
        XCTAssertEqual(result.startupMs, 80, accuracy: 0.5)
        XCTAssertGreaterThan(result.headroomX, 1)
    }

    /// Delivery below the media bitrate is the only thing that can stall a
    /// player, which is why headroom exists alongside rebuffering.
    func testDeliveryBelowBitrateStalls() {
        // 100 KB every 0.5 s is 1.6 Mbps against an 8 Mbps clip.
        let chunks = (1...80).map { VideoSimulator.Chunk(bytes: 102_400, at: Double($0) * 0.5) }
        let result = VideoSimulator.simulate(chunks: chunks,
                                             bitrateBps: 8_000_000,
                                             durationSeconds: 30)
        XCTAssertGreaterThanOrEqual(result.rebufferCount, 1)
        XCTAssertGreaterThan(result.rebufferMs, 0)
        XCTAssertLessThan(result.headroomX, 1)
    }

    /// The Pi measures elapsed time after its stream loop returns, so a
    /// stall still in progress when the media runs out is counted. The
    /// port has to do the same or a stream that dies mid-stall looks clean.
    func testStallInProgressAtTheEndIsCounted() {
        let chunks = (1...30).map { VideoSimulator.Chunk(bytes: 102_400, at: Double($0) * 0.5) }
        let stalled = VideoSimulator.simulate(chunks: chunks, bitrateBps: 8_000_000,
                                              durationSeconds: 30, endedAt: 20.0)
        let truncated = VideoSimulator.simulate(chunks: chunks, bitrateBps: 8_000_000,
                                                durationSeconds: 30)
        XCTAssertGreaterThan(stalled.rebufferMs, truncated.rebufferMs)
    }

    func testQualityTierBoundaries() {
        XCTAssertEqual(VideoSimulator.tier(forMbps: 25.0), "4K")
        XCTAssertEqual(VideoSimulator.tier(forMbps: 24.99), "1080p")
        XCTAssertEqual(VideoSimulator.tier(forMbps: 8.0), "1080p")
        XCTAssertEqual(VideoSimulator.tier(forMbps: 5.0), "720p")
        XCTAssertEqual(VideoSimulator.tier(forMbps: 3.0), "480p")
        XCTAssertEqual(VideoSimulator.tier(forMbps: 2.99), "below-480p")
    }

    /// `video.py` falls back to 2 Mbps when the bitrate is unreadable, and
    /// `AVURLAsset` can equally fail to report one.
    func testUnreadableBitrateFallsBackToTwoMbps() {
        let result = VideoSimulator.simulate(chunks: fastChunks(count: 50),
                                             bitrateBps: 0,
                                             durationSeconds: 10)
        XCTAssertEqual(result.bitrateMbps, 2.0)
    }

    func testMetricsMatchTheContractsVideoKeys() {
        let metrics = VideoSimulator.simulate(chunks: fastChunks(count: 50),
                                              bitrateBps: 2_000_000,
                                              durationSeconds: 10).metrics
        XCTAssertEqual(Set(metrics.keys), ["startup_ms", "rebuffer_count", "rebuffer_ms",
                                           "stream_mbps", "bitrate_mbps", "headroom_x",
                                           "quality_tier"])
        if case .string = metrics["quality_tier"] {} else {
            XCTFail("quality_tier must be a string, as the contract allows")
        }
    }
}
