import XCTest
@testable import WiFiProbeKit

/// Posts one real record to the live backend, to prove it accepts the
/// exact JSON this client encodes. Everything else about the upload path
/// is tested against a stub; this is the one thing a stub cannot tell you.
///
/// Opt-in: it writes a row to the production database, so it runs only
/// when WIFIPROBE_LIVE_INGEST_TOKEN is set. The record is labelled
/// `phone-smoke-test` per C2, so it is trivially filtered out of the
/// deployment dataset the dissertation analyses.
final class IngestSmokeTest: XCTestCase {

    func testLiveBackendAcceptsOurRecord() async throws {
        guard let token = ProcessInfo.processInfo.environment["WIFIPROBE_LIVE_INGEST_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("set WIFIPROBE_LIVE_INGEST_TOKEN to run the live smoke test")
        }

        let config = ProbeConfig(
            probeID: "iphone-dev-01", site: "phone-smoke-test",
            ingestURL: URL(string: "https://comp702-api.azurewebsites.net/ingest")!,
            ingestToken: token,
            apiBase: URL(string: "https://comp702-api.azurewebsites.net")!,
            dashUser: "wifi", dashPass: "",
            cloudBase: URL(string: "https://comp702-ref.azurewebsites.net")!,
            realWeb: URL(string: "https://www.bbc.co.uk/news")!,
            realVideo: URL(string: "https://example.com/clip.mp4")!,
            realDownload: URL(string: "http://example.com/50MB.zip")!)

        // A real measurement rather than invented numbers: the cloud
        // reference by TCP handshake, exactly as a run would do it.
        let host = config.cloudBase.host!
        let metrics = try await BaselineWorkload.run(
            target: BaselineTarget(.cloud, host, .tcp), count: 3, interval: 0.2)

        let record = Record(
            probeID: config.probeID, site: config.site,
            runID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            workload: .baseline, endpoint: .cloud, target: host,
            ok: true, metrics: metrics,
            netHash: await NetID.shared.hash())

        try ContractValidator.validate(try record.jsonObject())
        let outcome = try await Uploader(config: config).send(record)

        switch outcome {
        case .accepted, .duplicate:
            print("live ingest accepted: \(metrics)")
        case .rejected(let status, let body):
            XCTFail("the backend refused the record: \(status) \(body)")
        }
    }
}
