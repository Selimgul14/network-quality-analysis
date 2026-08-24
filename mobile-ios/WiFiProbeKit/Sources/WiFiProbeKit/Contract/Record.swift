import Foundation

/// The `workload` enum from `contracts/measurement.schema.json`.
///
/// The full set is mirrored even though the phone never emits `email`
/// (N3) and emits `path` only as a single hop (M10, N4). The contract is
/// the shared vocabulary; what this client chooses to say with it is a
/// separate matter.
public enum Workload: String, CaseIterable, Codable, Sendable, Equatable {
    case web, video, email, download, baseline, path, loadlat
}

/// Which endpoint family a run hit. `local` is used only for the gateway
/// leg on this client (M2, M10); the application workloads run against
/// `cloud` and `real`, as the Pi does at a site with no wired reference.
public enum Endpoint: String, CaseIterable, Codable, Sendable, Equatable {
    case local, cloud, real
}

/// One measurement record. Field-for-field the contract, including its
/// snake_case names, which are mapped explicitly below so the mapping is
/// visible in one place and can be tested.
public struct Record: Codable, Sendable, Equatable {
    public let ts: Date
    public let probeID: String
    public let site: String?
    public let runID: String
    public let workload: Workload
    public let endpoint: Endpoint
    public let target: String
    public let ok: Bool
    public let error: String?
    public let metrics: [String: MetricValue]
    public let netHash: String?

    public init(
        ts: Date = Date(),
        probeID: String,
        site: String?,
        runID: String,
        workload: Workload,
        endpoint: Endpoint,
        target: String,
        ok: Bool,
        error: String? = nil,
        metrics: [String: MetricValue],
        netHash: String? = nil
    ) {
        self.ts = ts
        self.probeID = probeID
        self.site = site
        self.runID = runID
        self.workload = workload
        self.endpoint = endpoint
        self.target = target
        self.ok = ok
        self.error = error
        self.metrics = metrics
        self.netHash = netHash
    }

    enum CodingKeys: String, CodingKey {
        case ts, site, workload, endpoint, target, ok, error, metrics
        case probeID = "probe_id"
        case runID = "run_id"
        case context
        case rawRef = "raw_ref"
        case netHash = "net_hash"
    }

    /// Every key is written, nulls included, exactly as `scheduler._record`
    /// builds its dict. `context` and `raw_ref` are always null: none of
    /// the context fields exist on iOS (N8) and the phone ships no raw
    /// payloads (N4).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.timestampFormatter.string(from: ts), forKey: .ts)
        try c.encode(probeID, forKey: .probeID)
        try c.encode(site, forKey: .site)
        try c.encode(runID, forKey: .runID)
        try c.encode(workload, forKey: .workload)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(target, forKey: .target)
        try c.encode(ok, forKey: .ok)
        try c.encode(error, forKey: .error)
        try c.encode(metrics, forKey: .metrics)
        try c.encodeNil(forKey: .context)
        try c.encodeNil(forKey: .rawRef)
        try c.encode(netHash, forKey: .netHash)
    }

    /// Written by hand rather than synthesised: the custom `encode(to:)`
    /// above and `MetricValue`'s manual coding mean the compiler cannot be
    /// trusted to derive this correctly, so it mirrors `CodingKeys`
    /// explicitly. `context` and `raw_ref` are always posted as null and
    /// carry no stored property, so they are decoded and discarded rather
    /// than assigned; `decodeIfPresent` means an explicit null decodes to
    /// nil instead of throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tsString = try c.decode(String.self, forKey: .ts)
        guard let ts = Self.decodeTimestamp(tsString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: c,
                debugDescription: "ts is not a valid ISO 8601 timestamp: \(tsString)")
        }
        self.ts = ts
        self.probeID = try c.decode(String.self, forKey: .probeID)
        self.site = try c.decodeIfPresent(String.self, forKey: .site)
        self.runID = try c.decode(String.self, forKey: .runID)
        self.workload = try c.decode(Workload.self, forKey: .workload)
        self.endpoint = try c.decode(Endpoint.self, forKey: .endpoint)
        self.target = try c.decode(String.self, forKey: .target)
        self.ok = try c.decode(Bool.self, forKey: .ok)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.metrics = try c.decode([String: MetricValue].self, forKey: .metrics)
        self.netHash = try c.decodeIfPresent(String.self, forKey: .netHash)
        _ = try c.decodeIfPresent(String.self, forKey: .context)
        _ = try c.decodeIfPresent(String.self, forKey: .rawRef)
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `timestampFormatter` is strict on decode: a timestamp with no
    /// fractional part (`...T22:14:20Z`, no `.123`) is rejected outright
    /// even though it is valid ISO 8601. `PendingStore.load` drops its
    /// entire queue on a decode failure, so one whole-second timestamp
    /// would silently discard every unsent record. Encoding always emits
    /// fractional seconds (see `encode(to:)`); this only needs to tolerate
    /// reading a form the encoder itself does not produce, in case a
    /// queue file was written by different code or a future format.
    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decodeTimestamp(_ string: String) -> Date? {
        timestampFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // deterministic, for tests
        return try encoder.encode(self)
    }

    /// The encoded record as a JSON object, which is what the validator
    /// inspects. Going through the encoder rather than building a
    /// dictionary by hand means the validator checks what is actually
    /// posted, mistakes in `CodingKeys` included.
    public func jsonObject() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: encoded())
        guard let dictionary = object as? [String: Any] else {
            throw ContractError.badValue(key: "<root>", reason: "not a JSON object")
        }
        return dictionary
    }
}
