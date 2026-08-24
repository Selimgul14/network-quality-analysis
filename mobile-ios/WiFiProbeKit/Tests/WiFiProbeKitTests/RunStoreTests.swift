import XCTest
@testable import WiFiProbeKit

final class RunStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runstore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(id: String, site: String, at: Date,
                     score: Double? = 91) -> StoredRun {
        StoredRun(
            id: id, site: site, startedAt: at, finishedAt: at.addingTimeInterval(60),
            recordCount: 11, failedCount: 0, gateway: "10.0.0.1",
            wifiLinkMethod: "icmp",
            wifiLinkAttempts: [StoredRun.Attempt(method: "icmp", answered: true,
                                                 detail: "3.2 ms")],
            steps: [StoredRun.Step(workload: "web", endpoint: "real",
                                   target: "https://bbc.co.uk", ok: true, error: nil)],
            verdict: StoredRun.VerdictSnapshot(
                score: score, quality: score, availabilityPct: 100, label: "excellent",
                headline: "Your WiFi is doing fine",
                segments: ["wifi_link": "ok"], wifiLinkRTTms: 3.2))
    }

    func testSavesAndReadsBackARun() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "a", site: "phone-home", at: Date()))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.verdict?.score, 91)
        XCTAssertEqual(all.first?.steps.first?.workload, "web")
    }

    /// Newest first, because that is the order History shows.
    func testOrdersNewestFirst() async throws {
        let store = RunStore(directory: directory)
        let now = Date()
        try await store.save(run(id: "old", site: "phone-home",
                                 at: now.addingTimeInterval(-3600)))
        try await store.save(run(id: "new", site: "phone-home", at: now))
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), ["new", "old"])
    }

    func testFiltersBySiteAndListsSites() async throws {
        let store = RunStore(directory: directory)
        let now = Date()
        try await store.save(run(id: "a", site: "phone-home", at: now))
        try await store.save(run(id: "b", site: "phone-library",
                                 at: now.addingTimeInterval(-10)))
        let home = await store.runs(site: "phone-home")
        XCTAssertEqual(home.map(\.id), ["a"])
        let sites = await store.sites()
        XCTAssertEqual(Set(sites), ["phone-home", "phone-library"])
    }

    /// A run written by an older build, or half-written when the app was
    /// killed, must not take the whole history down with it.
    func testSkipsAnUnreadableRunFile() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "good", site: "phone-home", at: Date()))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), ["good"])
    }

    func testDeletesOneRunAndThenAll() async throws {
        let store = RunStore(directory: directory)
        try await store.save(run(id: "a", site: "phone-home", at: Date()))
        try await store.save(run(id: "b", site: "phone-home", at: Date()))
        try await store.delete(id: "a")
        var all = await store.all()
        XCTAssertEqual(all.map(\.id), ["b"])
        try await store.deleteAll()
        all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    /// Runs survive the process, which is the whole point.
    func testASecondStoreOverTheSameDirectorySeesTheRuns() async throws {
        try await RunStore(directory: directory)
            .save(run(id: "a", site: "phone-home", at: Date()))
        let reopened = await RunStore(directory: directory).all()
        XCTAssertEqual(reopened.map(\.id), ["a"])
    }
}
