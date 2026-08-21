import Foundation

/// Runtime configuration, mirroring `probe/config.py`.
///
/// In the app these come from `Secrets.xcconfig` by way of Info.plist and
/// are never committed (C5). The defaults below are the non-secret values
/// the Pi runs with, so the two probes measure the same things.
public struct ProbeConfig: Sendable {
    public var probeID: String
    /// Already carries the `phone-` prefix; `SiteLabel` is what applies it.
    public var site: String
    public var ingestURL: URL
    public var ingestToken: String
    /// Base of the query API, e.g. https://comp702-api.azurewebsites.net
    public var apiBase: URL
    public var dashUser: String
    public var dashPass: String
    public var cloudBase: URL
    public var realWeb: URL
    public var realVideo: URL
    public var realDownload: URL
    public var baselineCDN: String?
    public var dnsAnchors: [String]
    /// Ten packets at 0.2 s: the values the packet-loss investigation
    /// settled on. Changing them changes how loss quantises, and phone
    /// numbers would stop being comparable with the Pi's.
    public var pingCount: Int
    public var pingInterval: TimeInterval

    public init(
        probeID: String,
        site: String,
        ingestURL: URL,
        ingestToken: String,
        apiBase: URL,
        dashUser: String,
        dashPass: String,
        cloudBase: URL,
        realWeb: URL,
        realVideo: URL,
        realDownload: URL,
        baselineCDN: String? = "www.google.com",
        dnsAnchors: [String] = ["1.1.1.1", "8.8.8.8"],
        pingCount: Int = 10,
        pingInterval: TimeInterval = 0.2
    ) {
        self.probeID = probeID
        self.site = site
        self.ingestURL = ingestURL
        self.ingestToken = ingestToken
        self.apiBase = apiBase
        self.dashUser = dashUser
        self.dashPass = dashPass
        self.cloudBase = cloudBase
        self.realWeb = realWeb
        self.realVideo = realVideo
        self.realDownload = realDownload
        self.baselineCDN = baselineCDN
        self.dnsAnchors = dnsAnchors
        self.pingCount = pingCount
        self.pingInterval = pingInterval
    }
}

/// C2: every phone record is labelled `phone-<something>`, the prefix is
/// applied by the app rather than typed, and an empty label is refused
/// outright. An unlabelled phone record is the one outcome that would be
/// hard to unpick from the deployment dataset later.
public enum SiteLabel {
    public static let prefix = "phone-"

    public static func make(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix(prefix) ? trimmed : prefix + trimmed
    }
}
