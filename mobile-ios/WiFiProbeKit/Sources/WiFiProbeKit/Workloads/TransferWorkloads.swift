import Foundation
import AVFoundation

/// Throughput against a fixed-size file, mirroring `download.py`.
public enum DownloadWorkload {
    public static func run(target: URL) async throws -> [String: MetricValue] {
        let result = try await HTTPStreamer.stream(target)
        return [
            "throughput_mbps": .rounded(result.mbps),
            "bytes": .number(Double(result.bytes)),
        ]
    }
}

/// Video streaming, mirroring `video.py`.
///
/// `AVURLAsset` replaces `ffprobe` for the media's duration and bitrate,
/// then the byte stream is replayed through the same player simulation.
/// No `AVPlayer`: see `VideoSimulator` for why a real player would be a
/// different measurement rather than a better one.
public enum VideoWorkload {

    public static func run(target: URL) async throws -> [String: MetricValue] {
        let (bitrate, duration) = await mediaProperties(of: target)
        let result = try await HTTPStreamer.stream(target, collectChunks: true)
        return VideoSimulator.simulate(chunks: result.chunks,
                                       bitrateBps: bitrate,
                                       durationSeconds: duration,
                                       endedAt: result.seconds).metrics
    }

    /// Bitrate in bits per second and duration in seconds. Falls back to
    /// `video.py`'s 2 Mbps and the watch cap when the media will not say,
    /// which a progressive MP4 sometimes will not.
    static func mediaProperties(of url: URL) async -> (bitrate: Double, duration: Double) {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": HTTPStreamer.userAgent],
        ])
        var bitrate = 0.0
        var duration = VideoSimulator.maxWatchSeconds
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let rate = try? await tracks.first?.load(.estimatedDataRate), rate > 0 {
            bitrate = Double(rate)
        }
        if let loaded = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loaded)
            if seconds.isFinite, seconds > 0 { duration = min(seconds, VideoSimulator.maxWatchSeconds) }
        }
        return (bitrate, duration)
    }
}

/// Latency under load, mirroring `loadlat.py`.
///
/// Idle latency flatters a network. What users feel is latency while
/// something else is downloading, so this measures both and reports the
/// inflation. RTT comes from a TCP handshake rather than ping so the
/// workload survives networks that block ICMP.
public enum LoadLatWorkload {

    static let rttHost = "1.1.1.1"
    static let rttPort: UInt16 = 443
    static let idleSamples = 5
    static let loadSeconds = 8.0
    static let sampleGap = 0.4

    public enum Failure: Error, Equatable {
        case noIdleBaseline
        case noLoadedSamples
    }

    public static func run(target: URL) async throws -> [String: MetricValue] {
        let idle = await sample(count: idleSamples, gap: 0.2)
        guard !idle.isEmpty else { throw Failure.noIdleBaseline }

        // Saturate the link, then measure while it is busy.
        let loader = Task { try await HTTPStreamer.stream(target) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // let TCP ramp up

        var loaded: [Double] = []
        let deadline = Date().addingTimeInterval(loadSeconds)
        while Date() < deadline {
            if let rtt = await TCPProbe.handshakeMs(host: rttHost, port: rttPort) {
                loaded.append(rtt)
            }
            try? await Task.sleep(nanoseconds: UInt64(sampleGap * 1_000_000_000))
        }
        loader.cancel()
        let transfer = try? await loader.value

        guard !loaded.isEmpty else { throw Failure.noLoadedSamples }
        let idleMedian = median(idle)
        let loadedMedian = median(loaded)

        return [
            "idle_rtt_ms": .rounded(idleMedian),
            "loaded_rtt_ms": .rounded(loadedMedian),
            // The headline: how much latency the load added.
            "bloat_ms": .rounded(max(0, loadedMedian - idleMedian)),
            "loaded_rtt_max_ms": .rounded(loaded.max() ?? 0),
            "load_mbps": .rounded(transfer?.mbps ?? 0),
        ]
    }

    private static func sample(count: Int, gap: TimeInterval) async -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count {
            if let rtt = await TCPProbe.handshakeMs(host: rttHost, port: rttPort) {
                samples.append(rtt)
            }
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        }
        return samples
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
