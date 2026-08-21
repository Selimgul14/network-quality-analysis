import Foundation

/// Turns a set of echo replies into the baseline metrics.
///
/// `jitter_ms` is the *population* standard deviation, which is not an
/// arbitrary choice: the probe's ICMP path parses `mdev` out of `ping`,
/// and `mdev` is the population standard deviation, while its TCP path
/// uses `statistics.pstdev`. Both agree, and this matches both. A sample
/// standard deviation here would quietly make phone jitter read higher
/// than Pi jitter on identical data.
public enum PingStats {

    public struct Summary: Equatable, Sendable {
        public let rttMs: Double
        public let jitterMs: Double
        public let lossPct: Double
    }

    /// - Parameters:
    ///   - rtts: round-trip times in ms, one per reply actually received.
    ///   - sent: how many echoes were sent.
    public static func summarise(rtts: [Double], sent: Int) -> Summary {
        guard sent > 0 else { return Summary(rttMs: 0, jitterMs: 0, lossPct: 0) }
        let loss = Double(sent - rtts.count) / Double(sent) * 100

        // No replies: the probe reports zeroed timings rather than nothing,
        // so the record still says "measured, and everything was lost".
        guard !rtts.isEmpty else {
            return Summary(rttMs: 0, jitterMs: 0, lossPct: round(loss, 1))
        }

        let mean = rtts.reduce(0, +) / Double(rtts.count)
        let jitter: Double = rtts.count > 1
            ? (rtts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rtts.count)).squareRoot()
            : 0
        return Summary(rttMs: round(mean, 2), jitterMs: round(jitter, 2), lossPct: round(loss, 1))
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }
}
