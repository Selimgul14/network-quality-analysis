import Foundation

/// The player simulation from `probe/workloads/video.py`, ported exactly.
///
/// The probe does not use a real player, and neither does this. Playback
/// starts once `startupBufferSeconds` of media is buffered, the buffer
/// drains at 1x wall clock, and any moment it runs dry is a rebuffer
/// event (cf. Dobrian et al.). `AVPlayer` was considered and rejected: it
/// would be a different measurement rather than a better one, and its
/// access log counts stalls without timing them, so `rebuffer_ms` would
/// be lost.
public enum VideoSimulator {

    public static let startupBufferSeconds = 2.0
    public static let maxWatchSeconds = 30.0

    /// Published minimum sustained rates per resolution, as in `video.py`.
    static let qualityTiers: [(Double, String)] = [
        (25.0, "4K"), (8.0, "1080p"), (5.0, "720p"), (3.0, "480p"),
    ]

    /// One delivered chunk: its size, and the elapsed time since the
    /// transfer began when it arrived.
    public struct Chunk: Sendable {
        public let bytes: Int
        public let at: TimeInterval
        public init(bytes: Int, at: TimeInterval) {
            self.bytes = bytes
            self.at = at
        }
    }

    public struct Result: Equatable, Sendable {
        public let startupMs: Double
        public let rebufferCount: Int
        public let rebufferMs: Double
        public let streamMbps: Double
        public let bitrateMbps: Double
        public let headroomX: Double
        public let qualityTier: String

        public var metrics: [String: MetricValue] {
            [
                "startup_ms": .number(startupMs),
                "rebuffer_count": .number(Double(rebufferCount)),
                "rebuffer_ms": .number(rebufferMs),
                "stream_mbps": .number(streamMbps),
                "bitrate_mbps": .number(bitrateMbps),
                // How many times faster than real time the media arrived:
                // 1.0 means playback is on the edge of stalling.
                "headroom_x": .number(headroomX),
                "quality_tier": .string(qualityTier),
            ]
        }
    }

    public static func tier(forMbps mbps: Double) -> String {
        for (need, name) in qualityTiers where mbps >= need { return name }
        return "below-480p"
    }

    /// - Parameter endedAt: when the transfer actually finished. The Pi
    ///   measures elapsed time after its stream loop returns, which is
    ///   later than the last chunk, and that gap is what lets a stall
    ///   still in progress at the end be counted. Ignored when the watch
    ///   loop breaks early, matching `video.py`, where the break makes
    ///   the return immediate.
    public static func simulate(chunks: [Chunk],
                                bitrateBps: Double,
                                durationSeconds: Double,
                                endedAt: TimeInterval? = nil) -> Result {
        let bitrate = bitrateBps > 0 ? bitrateBps : 2_000_000  // video.py's fallback
        let duration = min(durationSeconds, maxWatchSeconds)

        var startupMs: Double?
        var playStart: TimeInterval = 0
        var stalledSince: TimeInterval?
        var rebufferCount = 0
        var rebufferMs: Double = 0
        var bytesDownloaded = 0
        var end: TimeInterval = 0
        var brokeEarly = false

        for chunk in chunks {
            bytesDownloaded += chunk.bytes
            end = chunk.at
            let buffered = Double(bytesDownloaded) * 8 / bitrate

            guard let _ = startupMs else {
                if buffered >= startupBufferSeconds {
                    startupMs = chunk.at * 1000
                    playStart = chunk.at
                }
                continue
            }

            // Playback advances with the wall clock, minus time spent stalled.
            let played = (chunk.at - playStart) - rebufferMs / 1000
            if buffered <= played {
                if stalledSince == nil {  // buffer just ran dry
                    stalledSince = chunk.at
                    rebufferCount += 1
                }
            } else if let since = stalledSince {  // recovered
                rebufferMs += (chunk.at - since) * 1000
                stalledSince = nil
            }

            if played >= duration || buffered >= duration {
                brokeEarly = true
                break
            }
        }

        if !brokeEarly, let endedAt, endedAt > end { end = endedAt }

        if let since = stalledSince {  // stream ended mid-stall
            rebufferMs += (end - since) * 1000
        }

        // Small clips spend part of the transfer in TCP slow start, so this
        // is a lower bound on what the link can sustain.
        let streamMbps = end > 0 ? Double(bytesDownloaded) * 8 / end / 1_000_000 : 0
        let bitrateMbps = bitrate / 1_000_000

        return Result(
            startupMs: PingStats.round(startupMs ?? end * 1000, 2),
            rebufferCount: rebufferCount,
            rebufferMs: PingStats.round(rebufferMs, 2),
            streamMbps: PingStats.round(streamMbps, 2),
            bitrateMbps: PingStats.round(bitrateMbps, 2),
            headroomX: bitrateMbps > 0 ? PingStats.round(streamMbps / bitrateMbps, 2) : 0,
            qualityTier: tier(forMbps: streamMbps)
        )
    }
}
