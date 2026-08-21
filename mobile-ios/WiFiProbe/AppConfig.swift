import Foundation
import WiFiProbeKit

/// Builds the runtime configuration from Info.plist, whose values come
/// from `Secrets.xcconfig` at build time (C5: never committed).
///
/// Hosts are stored without a scheme because `//` starts a comment in an
/// xcconfig file, so a stored `https://host` silently truncates to
/// `https:`. The scheme is added back here.
enum AppConfig {

    enum Missing: Error, LocalizedError {
        case key(String)
        var errorDescription: String? {
            switch self {
            case .key(let name):
                return "\(name) is missing from Secrets.xcconfig. "
                     + "Copy Secrets.xcconfig.example and fill it in."
            }
        }
    }

    static func load(site: String) throws -> ProbeConfig {
        func value(_ key: String) throws -> String {
            guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !text.isEmpty else { throw Missing.key(key) }
            return text
        }
        func url(_ key: String, scheme: String = "https") throws -> URL {
            guard let url = URL(string: "\(scheme)://\(try value(key))") else {
                throw Missing.key(key)
            }
            return url
        }

        let apiBase = try url("API_HOST")
        return ProbeConfig(
            probeID: try value("PROBE_ID"),
            site: site,
            ingestURL: apiBase.appendingPathComponent("ingest"),
            ingestToken: try value("INGEST_TOKEN"),
            apiBase: apiBase,
            dashUser: (try? value("DASH_USER")) ?? "wifi",
            // Empty is tolerated: the run still uploads, and only the
            // verdict fetch fails, with a message saying why.
            dashPass: (try? value("DASH_PASS")) ?? "",
            cloudBase: try url("CLOUD_REF_HOST"),
            realWeb: try url("REAL_WEB"),
            realVideo: try url("REAL_VIDEO",
                               scheme: (try? value("REAL_VIDEO_SCHEME")) ?? "https"),
            realDownload: try url("REAL_DOWNLOAD",
                                  scheme: (try? value("REAL_DOWNLOAD_SCHEME")) ?? "http"))
    }

    /// Whether the dashboard password was supplied. Without it `/summary`
    /// returns 401 and the verdict cannot be shown (M6).
    static var hasDashboardPassword: Bool {
        let pass = Bundle.main.object(forInfoDictionaryKey: "DASH_PASS") as? String
        return !(pass ?? "").isEmpty
    }
}
