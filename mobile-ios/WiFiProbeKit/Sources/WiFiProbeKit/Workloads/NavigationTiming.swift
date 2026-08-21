import Foundation

/// Maps a PerformanceNavigationTiming entry to the contract's web metrics.
///
/// Kept separate from `WebWorkload` so the arithmetic is testable without
/// a browser. The JavaScript and the four subtractions are identical to
/// `probe/workloads/web.py`, which is what makes a phone page load
/// comparable with the Pi's.
public enum NavigationTiming {

    public static let javaScript =
        "JSON.stringify(performance.getEntriesByType('navigation')[0].toJSON())"

    public enum Failure: Error, Equatable { case missingField(String) }

    public static func metrics(from entry: [String: Double]) throws -> [String: MetricValue] {
        func value(_ key: String) throws -> Double {
            guard let value = entry[key] else { throw Failure.missingField(key) }
            return value
        }
        return [
            "dns_ms": .rounded(try value("domainLookupEnd") - value("domainLookupStart")),
            "connect_ms": .rounded(try value("connectEnd") - value("connectStart")),
            "ttfb_ms": .rounded(try value("responseStart") - value("requestStart")),
            "load_ms": .rounded(try value("loadEventEnd") - value("startTime")),
        ]
    }

    /// The entry arrives as a JSON string from `evaluateJavaScript`.
    public static func metrics(fromJSON json: String) throws -> [String: MetricValue] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.missingField("<entry>") }
        let numbers = object.compactMapValues { $0 as? Double }
        return try metrics(from: numbers)
    }
}
