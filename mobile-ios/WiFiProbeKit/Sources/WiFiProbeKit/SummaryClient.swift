import Foundation

/// Reads the verdict back from `GET /summary` (M6).
///
/// The phone computes nothing. Thresholds, attribution and the health
/// score all stay in `cloud/app/summary.py`, so a phone and the Pi are
/// scored by identical code and any disagreement between them is a
/// difference in the network rather than in two implementations of the
/// same idea.
///
/// Two things about the request. The dashboard endpoints sit behind HTTP
/// Basic (user `wifi`), not the ingest bearer token, so the app carries
/// two credentials for two purposes. And the window is anchored on the
/// run's completion with `?at=`, the time-travel parameter added for the
/// outage replay: a phone run is a single moment, and anchoring it
/// guarantees the run's own records fall inside the window rather than
/// leaving it to wall-clock luck.
public struct SummaryClient: Sendable {

    private let config: ProbeConfig
    private let session: URLSession

    public init(config: ProbeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public enum Failure: Error, Equatable {
        case unauthorised
        case server(status: Int)
        case transport(String)
        case undecodable(String)
    }

    public func fetch(site: String, hours: Int = 1, at: Date? = nil) async throws -> Verdict {
        var components = URLComponents(
            url: config.apiBase.appendingPathComponent("summary"),
            resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "site", value: site),
                     URLQueryItem(name: "hours", value: String(hours))]
        if let at {
            items.append(URLQueryItem(name: "at",
                                      value: Record.timestampFormatter.string(from: at)))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let credentials = Data("\(config.dashUser):\(config.dashPass)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw Failure.unauthorised
        default: throw Failure.server(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Verdict.self, from: data)
        } catch {
            throw Failure.undecodable(error.localizedDescription)
        }
    }
}

/// Only the fields the screen shows, all optional, so a backend that gains
/// a field does not break the app.
public struct Verdict: Decodable, Sendable {
    public struct Availability: Decodable, Sendable {
        public let pct: Double?
        public let attempted: Int?
        public let failed: Int?
    }

    public struct Health: Decodable, Sendable {
        public let score: Double?
        public let label: String?
        /// Kept apart from `score` so the page can say "good when it
        /// worked, but it only worked 67% of the time".
        public let quality: Double?
        public let availability: Availability?
        public let components: [String: Double?]?
        public let weights: [String: Double]?
    }

    public struct WorkloadView: Decodable, Sendable {
        public let metric: String?
        public let unit: String?
        public let good: Double?
        public let poor: Double?
        public let lowerIsBetter: Bool?
        public let value: Double?
        public let status: String?
        public let likelyCause: String?

        enum CodingKeys: String, CodingKey {
            case metric, unit, good, poor, value, status
            case lowerIsBetter = "lower_is_better"
            case likelyCause = "likely_cause"
        }
    }

    public let windowHours: Int?
    public let overall: String?
    public let headline: String?
    public let health: Health?
    public let segments: [String: String]?
    public let likelyCause: String?
    public let workloads: [String: WorkloadView]?
    public let wifiLinkRTTms: Double?
    public let wifiLinkFromPath: Bool?
    public let asOf: String?
    public let historic: Bool?

    enum CodingKeys: String, CodingKey {
        case overall, headline, health, segments, workloads, historic
        case windowHours = "window_hours"
        case likelyCause = "likely_cause"
        case wifiLinkRTTms = "wifi_link_rtt_ms"
        case wifiLinkFromPath = "wifi_link_from_path"
        case asOf = "as_of"
    }
}
