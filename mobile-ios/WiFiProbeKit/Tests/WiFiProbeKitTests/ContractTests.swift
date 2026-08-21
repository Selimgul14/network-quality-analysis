import XCTest
@testable import WiFiProbeKit

/// Mirrors `src/tests/test_contract.py`: the record the phone posts must
/// satisfy `contracts/measurement.schema.json`, which is read-only (C8).
final class ContractTests: XCTestCase {

    private func sample(
        workload: Workload = .download,
        endpoint: Endpoint = .cloud,
        ok: Bool = true,
        error: String? = nil,
        metrics: [String: MetricValue] = ["throughput_mbps": .number(54.2),
                                          "bytes": .number(26_214_400)]
    ) -> Record {
        Record(
            ts: Date(timeIntervalSince1970: 1_755_000_000),
            probeID: "iphone13-selim",
            site: "phone-halls-room",
            runID: "0f3a1c9d4b2e",
            workload: workload,
            endpoint: endpoint,
            target: "https://comp702-ref.azurewebsites.net/files/testfile.bin",
            ok: ok,
            error: error,
            metrics: metrics,
            netHash: "a1b2c3d4e5f6"
        )
    }

    // MARK: encoding

    func testEncodesExactlyTheContractsKeys() throws {
        let json = try sample().jsonObject()
        XCTAssertEqual(Set(json.keys), Set(ContractValidator.allowedKeys))
    }

    func testSnakeCaseKeyMapping() throws {
        let json = try sample().jsonObject()
        XCTAssertEqual(json["probe_id"] as? String, "iphone13-selim")
        XCTAssertEqual(json["run_id"] as? String, "0f3a1c9d4b2e")
        XCTAssertEqual(json["net_hash"] as? String, "a1b2c3d4e5f6")
    }

    func testTimestampIsISO8601WithTimezone() throws {
        let json = try sample().jsonObject()
        let ts = try XCTUnwrap(json["ts"] as? String)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(parser.date(from: ts), "ts must round-trip as ISO 8601: \(ts)")
    }

    /// N8: none of the five context fields are obtainable on iOS, and the
    /// phone ships no raw payloads. Both are posted as explicit null, as
    /// the probe does.
    func testContextAndRawRefAreNull() throws {
        let json = try sample().jsonObject()
        XCTAssertTrue(json["context"] is NSNull)
        XCTAssertTrue(json["raw_ref"] is NSNull)
    }

    func testMetricsAcceptStringValues() throws {
        let json = try sample(workload: .video,
                              metrics: ["startup_ms": .number(210.5),
                                        "quality_tier": .string("1080p")]).jsonObject()
        let metrics = try XCTUnwrap(json["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["quality_tier"] as? String, "1080p")
        XCTAssertEqual(metrics["startup_ms"] as? Double, 210.5)
    }

    /// M8: a failed run is a data point, not an absence. Empty metrics and
    /// a populated error, matching `scheduler._record`'s except branch.
    func testFailedRecordCarriesErrorAndEmptyMetrics() throws {
        let json = try sample(ok: false, error: "timed out", metrics: [:]).jsonObject()
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "timed out")
        XCTAssertEqual((json["metrics"] as? [String: Any])?.count, 0)
        try ContractValidator.validate(json)
    }

    // MARK: validation

    func testValidRecordPasses() throws {
        try ContractValidator.validate(sample().jsonObject())
    }

    func testEveryWorkloadAndEndpointValuePasses() throws {
        for workload in Workload.allCases {
            for endpoint in Endpoint.allCases {
                try ContractValidator.validate(
                    sample(workload: workload, endpoint: endpoint).jsonObject())
            }
        }
    }

    func testRejectsUnknownTopLevelKey() throws {
        var json = try sample().jsonObject()
        json["device_model"] = "iPhone13,2"
        XCTAssertThrowsError(try ContractValidator.validate(json)) { error in
            XCTAssertEqual(error as? ContractError, .unexpectedKey("device_model"))
        }
    }

    func testRejectsMissingRequiredKey() throws {
        for key in ContractValidator.requiredKeys {
            var json = try sample().jsonObject()
            json.removeValue(forKey: key)
            XCTAssertThrowsError(try ContractValidator.validate(json),
                                 "removing \(key) must fail validation")
        }
    }

    func testRejectsNullInARequiredKey() throws {
        var json = try sample().jsonObject()
        json["target"] = NSNull()
        XCTAssertThrowsError(try ContractValidator.validate(json))
    }

    func testRejectsEmptyIdentifiers() throws {
        for key in ["probe_id", "run_id", "target"] {
            var json = try sample().jsonObject()
            json[key] = ""
            XCTAssertThrowsError(try ContractValidator.validate(json),
                                 "empty \(key) must fail validation")
        }
    }

    func testRejectsUnknownWorkloadOrEndpoint() throws {
        var json = try sample().jsonObject()
        json["workload"] = "speedtest"
        XCTAssertThrowsError(try ContractValidator.validate(json))

        json = try sample().jsonObject()
        json["endpoint"] = "wifi"
        XCTAssertThrowsError(try ContractValidator.validate(json))
    }

    /// The schema allows only numbers and strings in `metrics`.
    func testRejectsNonScalarMetricValues() throws {
        let bad: [Any] = [[1, 2], NSNull(), ["nested": 1]]
        for value in bad {
            var json = try sample().jsonObject()
            json["metrics"] = ["odd": value]
            XCTAssertThrowsError(try ContractValidator.validate(json))
        }
    }

    /// `site` is nullable in the schema. The app still refuses to *run*
    /// without one (M5, C2), but that is a coordinator rule, not a
    /// contract rule, so the validator must not duplicate it.
    func testNullSiteIsContractValid() throws {
        var json = try sample().jsonObject()
        json["site"] = NSNull()
        try ContractValidator.validate(json)
    }
}
