import XCTest
@testable import WiFiProbeKit

/// Stubs the network so the upload path can be tested without touching the
/// live backend. Responses are queued and served in order.
final class StubProtocol: URLProtocol {
    struct Step {
        let status: Int?          // nil means a transport failure
        let body: Data
    }

    nonisolated(unsafe) static var steps: [Step] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        steps = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let step = Self.steps.isEmpty ? Step(status: 500, body: Data()) : Self.steps.removeFirst()
        guard let status = step.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: step.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class UploadTests: XCTestCase {

    private var session: URLSession!
    private var config: ProbeConfig!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        config = ProbeConfig(
            probeID: "iphone13-selim", site: "phone-test",
            ingestURL: URL(string: "https://comp702-api.azurewebsites.net/ingest")!,
            ingestToken: "test-token",
            apiBase: URL(string: "https://comp702-api.azurewebsites.net")!,
            dashUser: "wifi", dashPass: "p",
            cloudBase: URL(string: "https://comp702-ref.azurewebsites.net")!,
            realWeb: URL(string: "https://www.bbc.co.uk/news")!,
            realVideo: URL(string: "https://example.invalid/clip.mp4")!,
            realDownload: URL(string: "http://example.invalid/50MB.zip")!)
    }

    private func record(ok: Bool = true) -> Record {
        Record(probeID: "iphone13-selim", site: "phone-test", runID: "r1",
               workload: .download, endpoint: .cloud,
               target: "https://comp702-ref.azurewebsites.net/files/testfile.bin",
               ok: ok, error: ok ? nil : "boom",
               metrics: ok ? ["throughput_mbps": .number(54.2)] : [:])
    }

    private func accepted(_ status: String = "accepted") -> StubProtocol.Step {
        .init(status: 201, body: Data(#"{"status":"\#(status)","run_id":"r1"}"#.utf8))
    }

    // MARK: sending

    func testSendsBearerTokenAndJSONBody() async throws {
        StubProtocol.steps = [accepted()]
        let outcome = try await Uploader(config: config, session: session).send(record())
        XCTAssertEqual(outcome, .accepted)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// The probe's buffer treats a duplicate as success so a retried
    /// upload can be acknowledged rather than resent forever.
    func testDuplicateCountsAsDelivered() async throws {
        StubProtocol.steps = [accepted("duplicate")]
        let outcome = try await Uploader(config: config, session: session).send(record())
        XCTAssertEqual(outcome, .duplicate)
    }

    func testServerErrorThrowsSoTheRecordIsKept() async {
        StubProtocol.steps = [.init(status: 503, body: Data())]
        do {
            _ = try await Uploader(config: config, session: session).send(record())
            XCTFail("a 503 must not be treated as delivered")
        } catch {
            XCTAssertEqual(error as? Uploader.Failure, .server(status: 503))
        }
    }

    func testTransportFailureThrows() async {
        StubProtocol.steps = [.init(status: nil, body: Data())]
        do {
            _ = try await Uploader(config: config, session: session).send(record())
            XCTFail("a dead network must not be treated as delivered")
        } catch {
            guard case .transport = error as? Uploader.Failure else {
                return XCTFail("expected a transport failure, got \(error)")
            }
        }
    }

    // MARK: draining

    func testDrainDeliversInOrderAndEmptiesTheStore() async throws {
        StubProtocol.steps = [accepted(), accepted(), accepted()]
        let store = PendingStore()
        for _ in 0..<3 { await store.add(record()) }

        let sent = await Uploader(config: config, session: session).drain(store)
        XCTAssertEqual(sent, 3)
        let pending = await store.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// `uploader.flush` breaks rather than skipping, so a failure leaves a
    /// contiguous prefix delivered and the rest still queued in order.
    func testDrainStopsAtTheFirstFailureAndKeepsTheRest() async throws {
        StubProtocol.steps = [accepted(), .init(status: nil, body: Data())]
        let store = PendingStore()
        for _ in 0..<3 { await store.add(record()) }

        let sent = await Uploader(config: config, session: session).drain(store)
        XCTAssertEqual(sent, 1)
        let pending = await store.pendingCount
        XCTAssertEqual(pending, 2, "the unsent records must survive a failed drain")
        XCTAssertEqual(StubProtocol.requests.count, 2, "must not race past a failure")
    }

    /// A 422 means the record broke the contract, which validation should
    /// have caught. Retrying cannot fix it, so it is set aside and counted
    /// rather than looped over.
    func testRejectedRecordsAreSetAsideNotRetried() async throws {
        StubProtocol.steps = [.init(status: 422, body: Data(#"{"detail":"bad"}"#.utf8)),
                              accepted()]
        let store = PendingStore()
        await store.add(record())
        await store.add(record())

        let sent = await Uploader(config: config, session: session).drain(store)
        XCTAssertEqual(sent, 1)
        let pending = await store.pendingCount
        let rejected = await store.rejectedCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(rejected, 1)
    }

    /// M8: a failed measurement is still a record, and it must upload.
    func testFailedMeasurementsAreUploadedToo() async throws {
        StubProtocol.steps = [accepted()]
        let outcome = try await Uploader(config: config, session: session).send(record(ok: false))
        XCTAssertEqual(outcome, .accepted)
    }
}

final class NetIDTests: XCTestCase {
    /// Never the raw address: a truncated SHA-256, as `netid.py` stores.
    func testHashIsTruncatedAndNotTheAddress() {
        let hash = NetID.truncatedHash(of: "203.0.113.7")
        XCTAssertEqual(hash.count, 12)
        XCTAssertFalse(hash.contains("203"))
        XCTAssertEqual(hash, NetID.truncatedHash(of: "203.0.113.7"), "must be stable")
        XCTAssertNotEqual(hash, NetID.truncatedHash(of: "203.0.113.8"))
    }
}
