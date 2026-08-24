import Foundation

/// Continuous baseline probes, mirroring `probe/workloads/baseline.py`.
///
/// Several destination classes are probed so loss can be compared across
/// them: loss at the gateway is the WiFi link, loss to a single distant
/// target is that path. That comparison is what the summary page's
/// segment attribution rests on.
public enum BaselineWorkload {

    public static func run(target: BaselineTarget,
                           count: Int = 10,
                           interval: TimeInterval = 0.2) async throws -> [String: MetricValue] {
        // Resolved separately so the lookup is not folded into the RTT.
        let dns = IPv4Address.resolutionMs(target.host)

        var metrics: [String: MetricValue] = ["dns_ms": .number(dns)]
        let summary: PingStats.Summary

        switch target.method {
        case .icmp:
            summary = try await ICMPPinger.ping(host: target.host, count: count,
                                                interval: interval)
        case .tcp:
            summary = await TCPProbe.probe(host: target.host, count: count,
                                           interval: interval)
            // Marks RTT and loss as having come from handshakes, so the
            // dashboard does not read them as ICMP figures.
            metrics["tcp_mode"] = .number(1)
        case .icmpThenTCP:
            let result = await GatewayProbe.measure(host: target.host, count: count,
                                                    interval: interval)
            summary = result.summary
            if result.method == .tcp { metrics["tcp_mode"] = .number(1) }
        }

        metrics["rtt_ms"] = .number(summary.rttMs)
        metrics["jitter_ms"] = .number(summary.jitterMs)
        metrics["loss_pct"] = .number(summary.lossPct)
        return metrics
    }

    /// The gateway leg, which needs to report which rung of the ladder
    /// answered as well as the numbers. `run` returns metrics only, and
    /// the method matters to the screen.
    public static func runGateway(host: String,
                                  count: Int = 10,
                                  interval: TimeInterval = 0.2)
        async -> (metrics: [String: MetricValue], result: GatewayProbe.Result) {
        let dns = IPv4Address.resolutionMs(host)
        let result = await GatewayProbe.measure(host: host, count: count, interval: interval)

        var metrics: [String: MetricValue] = ["dns_ms": .number(dns)]
        switch result.method {
        case .tcp: metrics["tcp_mode"] = .number(1)
        // Marks the RTT as a first-hop TTL measurement rather than a ping
        // of the router itself, so the two are not silently mixed.
        case .firstHopTTL: metrics["ttl_mode"] = .number(1)
        case .icmp, .none: break
        }
        metrics["rtt_ms"] = .number(result.summary.rttMs)
        metrics["jitter_ms"] = .number(result.summary.jitterMs)
        metrics["loss_pct"] = .number(result.summary.lossPct)
        return (metrics, result)
    }
}

/// The WiFi-link leg (M10).
///
/// Not a traceroute. Hop 1 is the router reached over the air, which is
/// exactly what the contract documents `first_hop_rtt_ms` to mean, and it
/// is the only metric this record carries. `hops` is deliberately omitted:
/// setting it to 1 would assert something false about the path.
///
/// This record exists because of how `compute_summary` resolves segments.
/// Only web, video, email and download set `endpoint_has_data`, so no
/// baseline record can light up `wifi_link`; the verdict comes from
/// `_first_hop_rtt`, which reads a `path` record. Without this the app
/// would report "WiFi link: not measured" on every run.
public enum PathWorkload {

    public static func firstHopMetrics(gatewayRTTms: Double) -> [String: MetricValue] {
        ["first_hop_rtt_ms": .number(gatewayRTTms)]
    }

    /// Measure the gateway directly, for a run that is not also doing a
    /// baseline pass over it.
    public static func run(gateway: String,
                           count: Int = 10,
                           interval: TimeInterval = 0.2) async throws -> [String: MetricValue] {
        let summary = try await ICMPPinger.ping(host: gateway, count: count, interval: interval)
        guard summary.lossPct < 100 else {
            throw PathFailure.gatewaySilent(host: gateway)
        }
        return firstHopMetrics(gatewayRTTms: summary.rttMs)
    }

    public enum PathFailure: Error, Equatable {
        /// Total silence from the gateway. On iOS the likeliest cause is a
        /// refused local network permission rather than a dead link, and
        /// the two must not be confused: reporting a healthy router as
        /// down would be exactly the misattribution this project exists to
        /// prevent.
        case gatewaySilent(host: String)
    }
}
