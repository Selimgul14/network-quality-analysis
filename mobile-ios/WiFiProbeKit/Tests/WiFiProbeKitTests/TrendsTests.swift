import XCTest
@testable import WiFiProbeKit

final class TrendsTests: XCTestCase {

    private func run(site: String, at: Date, score: Double?,
                     segments: [String: String] = [:],
                     download: Double? = nil,
                     wifiLink: Double? = nil) -> StoredRun {
        var steps: [StoredRun.Step] = []
        if download != nil {
            steps.append(StoredRun.Step(workload: "download", endpoint: "real",
                                        target: "t", ok: true, error: nil))
        }
        return StoredRun(
            id: UUID().uuidString, site: site, startedAt: at,
            finishedAt: at.addingTimeInterval(60), recordCount: 10, failedCount: 0,
            gateway: "10.0.0.1", wifiLinkMethod: "icmp", wifiLinkAttempts: [],
            steps: steps,
            verdict: StoredRun.VerdictSnapshot(
                score: score, quality: score, availabilityPct: 100, label: nil,
                headline: nil, segments: segments, wifiLinkRTTms: wifiLink),
            downloadMbps: download)
    }

    func testMedianOfAnEvenCountAveragesTheMiddleTwo() {
        XCTAssertEqual(Trends.median([1, 2, 3, 4]), 2.5)
    }

    func testMedianOfAnEmptyListIsNil() {
        XCTAssertNil(Trends.median([]))
    }

    /// Medians rather than means, for the reason the backend uses them:
    /// one failed run should not swing a summary.
    func testOneBadRunDoesNotSinkASite() {
        let now = Date()
        let runs = (0..<4).map { run(site: "phone-home", at: now.addingTimeInterval(Double($0)),
                                     score: 90) }
            + [run(site: "phone-home", at: now, score: 2)]
        let ranked = Trends.rank(runs)
        XCTAssertEqual(ranked.first?.medianScore, 90)
    }

    func testRanksBestFirstAndCountsRuns() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 59),
                    run(site: "phone-library", at: now, score: 88),
                    run(site: "phone-library", at: now.addingTimeInterval(-60), score: 88)]
        let ranked = Trends.rank(runs)
        XCTAssertEqual(ranked.map(\.site), ["phone-library", "phone-home"])
        XCTAssertEqual(ranked.first?.runCount, 2)
    }

    /// A site with no scored run at all still appears, last, because
    /// "tested and never got a verdict" is information.
    func testSitesWithoutAScoreSortLast() {
        let now = Date()
        let ranked = Trends.rank([run(site: "phone-a", at: now, score: nil),
                                  run(site: "phone-b", at: now, score: 40)])
        XCTAssertEqual(ranked.map(\.site), ["phone-b", "phone-a"])
    }

    func testNamesTheSegmentMostOftenAtFault() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 50,
                        segments: ["wifi_link": "ok", "internet_path": "suspect"]),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 55,
                        segments: ["wifi_link": "ok", "internet_path": "suspect"]),
                    run(site: "phone-home", at: now.addingTimeInterval(-120), score: 60,
                        segments: ["wifi_link": "suspect", "internet_path": "ok"])]
        XCTAssertEqual(Trends.rank(runs).first?.worstSegment, "internet_path")
    }

    func testWorstSegmentIsNilWhenNothingWasEverAtFault() {
        let ranked = Trends.rank([run(site: "phone-home", at: Date(), score: 95,
                                      segments: ["wifi_link": "ok"])])
        XCTAssertNil(ranked.first?.worstSegment)
    }

    /// Chart points come back oldest first, because that is left to right.
    func testSeriesIsOldestFirst() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 90),
                    run(site: "phone-home", at: now.addingTimeInterval(-3600), score: 40)]
        let points = Trends.series(runs, metric: .score)
        XCTAssertEqual(points.map(\.value), [40, 90])
    }

    func testSeriesSkipsRunsMissingTheMetric() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: nil),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 70)]
        XCTAssertEqual(Trends.series(runs, metric: .score).count, 1)
    }

    func testInsightNamesTheSegmentInPlainEnglish() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 50,
                        segments: ["internet_path": "suspect"])]
        let summary = Trends.rank(runs)[0]
        XCTAssertEqual(Trends.insight(for: summary),
                       "On home, the internet path beyond the router is what most often falls short.")
    }

    func testInsightIsAbsentWhenNothingIsAtFault() {
        let summary = Trends.rank([run(site: "phone-home", at: Date(), score: 95)])[0]
        XCTAssertNil(Trends.insight(for: summary))
    }

    func testMedianDownloadIsComputedFromDownloadMbps() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 90, download: 10),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 90, download: 20),
                    run(site: "phone-home", at: now.addingTimeInterval(-120), score: 90, download: 30),
                    run(site: "phone-home", at: now.addingTimeInterval(-180), score: 90, download: 40)]
        XCTAssertEqual(Trends.rank(runs).first?.medianDownloadMbps, 25)
    }

    func testMedianWiFiLinkIsComputedFromWifiLinkRTTms() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 90, wifiLink: 2),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 90, wifiLink: 4),
                    run(site: "phone-home", at: now.addingTimeInterval(-120), score: 90, wifiLink: 6),
                    run(site: "phone-home", at: now.addingTimeInterval(-180), score: 90, wifiLink: 8)]
        XCTAssertEqual(Trends.rank(runs).first?.medianWiFiLinkMs, 5)
    }

    /// Values chosen so a swapped mapping (download landing in the latency
    /// field or vice versa) fails loudly rather than plausibly.
    func testDownloadAndWifiLinkLandInTheirOwnFieldsNotSwapped() {
        let now = Date()
        let summary = Trends.rank([run(site: "phone-home", at: now, score: 90,
                                       download: 55.0, wifiLink: 3.8)]).first
        XCTAssertEqual(summary?.medianDownloadMbps, 55.0)
        XCTAssertEqual(summary?.medianWiFiLinkMs, 3.8)
    }

    /// A run missing one of the two metrics is skipped for that field's
    /// median but still counted toward runCount; a site with no download
    /// figures at all reports nil, not zero.
    func testRunsMissingAMetricAreSkippedForThatFieldButStillCounted() {
        let now = Date()
        let runs = [run(site: "phone-home", at: now, score: 90, wifiLink: 5),
                    run(site: "phone-home", at: now.addingTimeInterval(-60), score: 90, wifiLink: 7)]
        let summary = Trends.rank(runs).first
        XCTAssertEqual(summary?.runCount, 2)
        XCTAssertEqual(summary?.medianWiFiLinkMs, 6)
        XCTAssertNil(summary?.medianDownloadMbps)
    }

    func testTwoSitesWithNoScoreBothAppearOrderedAlphabetically() {
        let now = Date()
        let runs = [run(site: "phone-zebra", at: now, score: nil),
                    run(site: "phone-alpha", at: now, score: nil)]
        let ranked = Trends.rank(runs)
        XCTAssertEqual(ranked.map(\.site), ["phone-alpha", "phone-zebra"])
    }

    func testTiedMedianScoresBreakAlphabeticallyAndAreStableAcrossCalls() {
        let now = Date()
        let runs = [run(site: "phone-zebra", at: now, score: 70),
                    run(site: "phone-alpha", at: now, score: 70)]
        let firstCall = Trends.rank(runs).map(\.site)
        let secondCall = Trends.rank(runs).map(\.site)
        XCTAssertEqual(firstCall, ["phone-alpha", "phone-zebra"])
        XCTAssertEqual(secondCall, ["phone-alpha", "phone-zebra"])
    }
}
