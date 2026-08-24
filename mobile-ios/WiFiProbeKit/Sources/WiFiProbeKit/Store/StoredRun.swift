import Foundation

/// One finished run, as it was displayed, kept on the device.
///
/// The verdict is a snapshot rather than something refetched later. A run
/// reopened in December has to show what it showed in August, and `?at=`
/// on the backend is not a substitute: the local record is the point.
///
/// Everything is a plain `String` rather than the kit's enums so that a
/// build which adds a workload can still read runs written by an older
/// one. A history that cannot be decoded is worse than a history with an
/// unfamiliar label in it.
public struct StoredRun: Codable, Sendable, Identifiable, Equatable {

    public struct Step: Codable, Sendable, Equatable {
        public let workload: String
        public let endpoint: String
        public let target: String
        public let ok: Bool
        public let error: String?

        public init(workload: String, endpoint: String, target: String,
                    ok: Bool, error: String?) {
            self.workload = workload
            self.endpoint = endpoint
            self.target = target
            self.ok = ok
            self.error = error
        }
    }

    public struct Attempt: Codable, Sendable, Equatable {
        public let method: String
        public let answered: Bool
        public let detail: String

        public init(method: String, answered: Bool, detail: String) {
            self.method = method
            self.answered = answered
            self.detail = detail
        }
    }

    public struct VerdictSnapshot: Codable, Sendable, Equatable {
        public let score: Double?
        public let quality: Double?
        public let availabilityPct: Double?
        public let label: String?
        public let headline: String?
        public let segments: [String: String]
        public let wifiLinkRTTms: Double?

        public init(score: Double?, quality: Double?, availabilityPct: Double?,
                    label: String?, headline: String?, segments: [String: String],
                    wifiLinkRTTms: Double?) {
            self.score = score
            self.quality = quality
            self.availabilityPct = availabilityPct
            self.label = label
            self.headline = headline
            self.segments = segments
            self.wifiLinkRTTms = wifiLinkRTTms
        }
    }

    public let id: String
    public let site: String
    public let startedAt: Date
    public let finishedAt: Date
    public let recordCount: Int
    public let failedCount: Int
    public let gateway: String?
    public let wifiLinkMethod: String
    public let wifiLinkAttempts: [Attempt]
    public let steps: [Step]
    public let verdict: VerdictSnapshot?
    /// Headline numbers, lifted out of the run so a chart does not have to
    /// re-read every record. Nil when that workload did not report.
    public let downloadMbps: Double?

    public init(id: String, site: String, startedAt: Date, finishedAt: Date,
                recordCount: Int, failedCount: Int, gateway: String?,
                wifiLinkMethod: String, wifiLinkAttempts: [Attempt],
                steps: [Step], verdict: VerdictSnapshot?,
                downloadMbps: Double? = nil) {
        self.id = id
        self.site = site
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.recordCount = recordCount
        self.failedCount = failedCount
        self.gateway = gateway
        self.wifiLinkMethod = wifiLinkMethod
        self.wifiLinkAttempts = wifiLinkAttempts
        self.steps = steps
        self.verdict = verdict
        self.downloadMbps = downloadMbps
    }

    /// The site label without the `phone-` prefix, which is the name the
    /// fixed probe would use for the same network. Trends uses it to look
    /// for a Pi at the same site.
    public var fixedProbeSite: String {
        site.hasPrefix(SiteLabel.prefix)
            ? String(site.dropFirst(SiteLabel.prefix.count)) : site
    }
}
