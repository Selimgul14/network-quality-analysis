import Foundation

public enum ProbeMethod: String, Sendable {
    case icmp, tcp
    /// ICMP first, then TCP if the host ignores echo requests. Used for
    /// the gateway, which is the one destination that cannot be swapped
    /// for a more cooperative one.
    case icmpThenTCP
}

public struct EndpointTarget: Equatable, Sendable {
    public let endpoint: Endpoint
    public let url: URL
    public init(_ endpoint: Endpoint, _ url: URL) {
        self.endpoint = endpoint
        self.url = url
    }
}

public struct BaselineTarget: Equatable, Sendable {
    public let endpoint: Endpoint
    public let host: String
    public let method: ProbeMethod
    public init(_ endpoint: Endpoint, _ host: String, _ method: ProbeMethod) {
        self.endpoint = endpoint
        self.host = host
        self.method = method
    }
}

/// Mirrors `probe/endpoints.py` and `scheduler._baseline_targets`.
///
/// The `local` family is absent for the application workloads, exactly as
/// it is on the Pi at the halls site where `PROBE_LOCAL_BASE` is empty:
/// there is no wired reference host. `local` is used only for the gateway
/// leg (M10).
public enum Endpoints {

    /// Paths served by the reference image, shared by local and cloud.
    public static let refPaths: [Workload: String] = [
        .web: "/page/index.html",
        .video: "/media/reference.mp4",
        .download: "/files/testfile.bin",
    ]

    public static func targets(for workload: Workload,
                               config: ProbeConfig) -> [EndpointTarget] {
        switch workload {
        case .email:
            return []  // N3: no mailbox credentials on a phone
        case .baseline, .path:
            return []  // these have their own target lists
        case .loadlat:
            // Needs a target big enough to saturate the link; the probe
            // uses the real download file and labels the run `real`.
            return [EndpointTarget(.real, config.realDownload)]
        case .web, .video, .download:
            guard let path = refPaths[workload] else { return [] }
            let real: URL = {
                switch workload {
                case .web: return config.realWeb
                case .video: return config.realVideo
                default: return config.realDownload
                }
            }()
            return [
                EndpointTarget(.cloud, config.cloudBase.appendingPathComponent(path)),
                EndpointTarget(.real, real),
            ]
        }
    }

    /// Destination classes for the baseline probe, in the probe's own
    /// order. Comparing loss across classes is what tells the WiFi link
    /// apart from one bad path.
    public static func baselineTargets(config: ProbeConfig,
                                       gateway: String?) -> [BaselineTarget] {
        var targets: [BaselineTarget] = []
        if let gateway {
            targets.append(BaselineTarget(.local, gateway, .icmpThenTCP))
        }
        if let host = config.cloudBase.host {
            // App Service drops ICMP, so this leg is a TCP handshake.
            targets.append(BaselineTarget(.cloud, host, .tcp))
        }
        targets += config.dnsAnchors.map { BaselineTarget(.real, $0, .icmp) }
        if let cdn = config.baselineCDN, !cdn.isEmpty {
            targets.append(BaselineTarget(.real, cdn, .icmp))
        }
        return targets
    }
}
