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

extension UploadTests {
    /// The upload fails precisely when the network is worst, which is when
    /// the measurement matters most. If the app is killed while the queue is
    /// full, the queue has to still be there afterwards.
    func testQueuedRecordsSurviveANewStoreOverTheSameDirectory() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = PendingStore(directory: directory)
        await first.add(sampleRecord())
        await first.add(sampleRecord())
        var count = await first.pendingCount
        XCTAssertEqual(count, 2)

        let reopened = PendingStore(directory: directory)
        count = await reopened.pendingCount
        XCTAssertEqual(count, 2, "the queue did not survive")

        let entries = await reopened.take()
        await reopened.acknowledge(entries[0].id)
        let afterAck = PendingStore(directory: directory)
        count = await afterAck.pendingCount
        XCTAssertEqual(count, 1, "an acknowledged record came back")
    }

    /// Order is preserved across a restart, so a partial upload still leaves
    /// a contiguous prefix delivered.
    func testQueueOrderSurvivesARestart() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = PendingStore(directory: directory)
        for _ in 0..<3 { await first.add(sampleRecord()) }
        let before = await first.take().map(\.id)
        let after = await PendingStore(directory: directory).take().map(\.id)
        XCTAssertEqual(before, after)
    }
}

final class RecordDecodingTests: XCTestCase {
    /// `Record.timestampFormatter` is strict on decode: a timestamp with no
    /// fractional part is rejected even though it is valid ISO 8601. A
    /// queue file written before this project always adds fractional
    /// seconds could still contain one, and `PendingStore.load` drops its
    /// entire queue on a single decode failure, so this must not throw.
    func testWholeSecondTimestampDecodes() throws {
        let json = """
        {"ts":"2026-08-24T22:14:20Z","probe_id":"p","site":null,"run_id":"r",
         "workload":"baseline","endpoint":"real","target":"1.1.1.1","ok":true,
         "error":null,"metrics":{},"context":null,"raw_ref":null,"net_hash":null}
        """
        let record = try JSONDecoder().decode(Record.self, from: Data(json.utf8))
        XCTAssertEqual(record.probeID, "p")
        let expected = ISO8601DateFormatter().date(from: "2026-08-24T22:14:20Z")
        XCTAssertEqual(record.ts, expected)
    }

    /// A queue entry decoded back from disk must re-encode to exactly the
    /// same JSON it started as: the backend validates against the
    /// read-only contract schema, and a mismatch here would mean ingestion
    /// silently breaks the moment a record survives a restart.
    func testDecodedRecordReencodesToTheSameJSON() throws {
        let original = sampleRecord()
        let encoded = try original.encoded()
        let decoded = try JSONDecoder().decode(Record.self, from: encoded)
        let reencoded = try decoded.encoded()

        let originalObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertEqual(NSDictionary(dictionary: originalObject ?? [:]),
                       NSDictionary(dictionary: reencodedObject ?? [:]))
    }

    /// The contract's 13 keys, nulls included, must survive the round
    /// trip through `Decodable` unchanged: `Codable` conformance must not
    /// have altered what gets encoded.
    func testEncodedKeySetStillMatchesContractAfterAddingDecodable() throws {
        let json = try sampleRecord().jsonObject()
        XCTAssertEqual(Set(json.keys), Set(ContractValidator.allowedKeys))
        XCTAssertTrue(json["context"] is NSNull)
        XCTAssertTrue(json["raw_ref"] is NSNull)
    }
}

private func sampleRecord() -> Record {
    Record(probeID: "iphone-test", site: "phone-home",
           runID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
           workload: .baseline, endpoint: .real, target: "1.1.1.1",
           ok: true, error: nil,
           metrics: ["rtt_ms": .number(13.9), "loss_pct": .number(0)],
           netHash: nil)
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
