import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// ICMP echo, replacing the probe's `ping` subprocess.
///
/// A `SOCK_DGRAM` ICMP socket needs neither root nor an entitlement on
/// Darwin, which is what makes this possible on an unjailbroken phone at
/// all. Two consequences of using a datagram socket rather than a raw one:
/// the kernel rewrites the identifier field, so replies are matched on
/// sequence number, and the received buffer carries the IPv4 header ahead
/// of the ICMP one, so `parseReply` skips it by reading the IHL.
///
/// Timing mirrors `baseline._ping`: packets go out at a fixed interval
/// while replies are collected as they arrive, rather than waiting for
/// each in turn, so one lost packet costs the timeout rather than
/// stretching the whole run.
public enum ICMPPinger {

    public enum Failure: Error, Equatable {
        case socketUnavailable(errno: Int32)
        case unresolvable(String)
        /// The likely cause of total silence from a LAN address on iOS is
        /// a refused local network permission, not a dead link.
        case sendFailed(errno: Int32)
    }

    /// One parsed reply: the ICMP type, and the sequence number that
    /// identifies which of our packets it answers.
    public struct ParsedICMP: Equatable, Sendable {
        public let type: UInt8
        public let sequence: UInt16
    }

    private static let echoRequest: UInt8 = 8
    private static let echoReply: UInt8 = 0
    private static let timeExceeded: UInt8 = 11
    private static let payloadSize = 56  // as ping(8) sends

    /// Parse one datagram received on a `SOCK_DGRAM` ICMP socket.
    ///
    /// Darwin includes the IPv4 header in what it hands back, unlike
    /// Linux, so the ICMP header starts at the IHL rather than at byte 0.
    /// The IHL is read rather than assumed to be 20, because a header
    /// carrying options is longer and a fixed offset would then land in
    /// the middle of the ICMP header.
    ///
    /// Replies are matched on sequence, not identifier: the kernel owns
    /// the identifier field on a datagram socket.
    public static func parseReply(_ buffer: [UInt8], count: Int) -> ParsedICMP? {
        guard count >= 20, buffer.count >= count else { return nil }
        guard buffer[0] >> 4 == 4 else { return nil }
        let ipHeader = Int(buffer[0] & 0x0F) * 4
        guard ipHeader >= 20, count >= ipHeader + 8 else { return nil }

        let type = buffer[ipHeader]
        switch type {
        case echoReply:
            let sequence = UInt16(buffer[ipHeader + 6]) << 8 | UInt16(buffer[ipHeader + 7])
            return ParsedICMP(type: type, sequence: sequence)

        case timeExceeded:
            // The error body is 8 bytes, then a copy of the datagram that
            // expired: its own IPv4 header, then the first 8 bytes of our
            // echo. The sequence lives in that copy.
            let quoted = ipHeader + 8
            guard count >= quoted + 20, buffer[quoted] >> 4 == 4 else { return nil }
            let quotedHeader = Int(buffer[quoted] & 0x0F) * 4
            let inner = quoted + quotedHeader
            guard quotedHeader >= 20, count >= inner + 8,
                  buffer[inner] == echoRequest else { return nil }
            let sequence = UInt16(buffer[inner + 6]) << 8 | UInt16(buffer[inner + 7])
            return ParsedICMP(type: type, sequence: sequence)

        default:
            return nil
        }
    }

    public static func ping(host: String,
                            count: Int = 10,
                            interval: TimeInterval = 0.2,
                            graceSeconds: TimeInterval = 2.0,
                            ttl: Int32? = nil) async throws -> PingStats.Summary {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try pingSync(
                        host: host, count: count, interval: interval,
                        grace: graceSeconds, ttl: ttl))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func pingSync(host: String, count: Int, interval: TimeInterval,
                         grace: TimeInterval, ttl: Int32? = nil) throws -> PingStats.Summary {
        guard let address = IPv4Address.resolve(host) else { throw Failure.unresolvable(host) }

        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard handle >= 0 else { throw Failure.socketUnavailable(errno: errno) }
        defer { close(handle) }

        // Short receive timeout: the loop polls between sends rather than
        // blocking, so a lost packet never stalls the schedule.
        var window = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &window,
                   socklen_t(MemoryLayout<timeval>.size))

        // Rung 2 of the gateway ladder: an echo sent with TTL 1 expires at
        // the first router, which is obliged to answer with time exceeded
        // even when it ignores pings addressed to itself.
        if var hops = ttl {
            setsockopt(handle, IPPROTO_IP, IP_TTL, &hops,
                       socklen_t(MemoryLayout<Int32>.size))
        }

        var destination = address.socketAddress
        var sentAt: [UInt16: TimeInterval] = [:]
        var rtts: [Double] = []
        var sendFailures = 0

        func collect(until deadline: TimeInterval) {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while Date().timeIntervalSince1970 < deadline {
                let received = recv(handle, &buffer, buffer.count, 0)
                guard received > 0,
                      let parsed = parseReply(buffer, count: received),
                      let start = sentAt.removeValue(forKey: parsed.sequence) else { continue }
                rtts.append((Date().timeIntervalSince1970 - start) * 1000)
            }
        }

        for sequence in 0..<UInt16(count) {
            let packet = echoPacket(sequence: sequence)
            let now = Date().timeIntervalSince1970
            let written = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(handle, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if written < 0 { sendFailures += 1 } else { sentAt[sequence] = now }
            collect(until: now + interval)
        }
        collect(until: Date().timeIntervalSince1970 + grace)

        // Every send failing is a different condition from every reply
        // being lost: the packets never left the device.
        if sendFailures == count { throw Failure.sendFailed(errno: errno) }
        return PingStats.summarise(rtts: rtts, sent: count)
    }

    /// Echo request: type, code, checksum, identifier, sequence, payload.
    /// The kernel fills in the identifier on a datagram socket.
    static func echoPacket(sequence: UInt16, identifier: UInt16 = 0) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 8 + payloadSize)
        packet[0] = echoRequest
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        for index in 8..<packet.count { packet[index] = UInt8(index % 256) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// Standard 16-bit one's complement checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }

    /// Time the first router by expiring a TTL at it, rather than by
    /// asking it to answer for itself.
    ///
    /// The destination is somewhere beyond the router and is never
    /// reached; only the router's error reply is timed. `mtr` measures
    /// hop 1 the same way on the Pi, so both probes end up measuring the
    /// WiFi link by one method.
    public static func firstHop(via host: String = "1.1.1.1",
                                count: Int = 10,
                                interval: TimeInterval = 0.2) async throws -> PingStats.Summary {
        try await ping(host: host, count: count, interval: interval, ttl: 1)
    }
}

/// Minimal IPv4 resolution, also used to time DNS separately from RTT so
/// the lookup is not folded into the latency figure, as `_tcp_ping` is
/// careful to avoid.
public struct IPv4Address {
    public let socketAddress: sockaddr_in

    public static func resolve(_ host: String) -> IPv4Address? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let raw = first.pointee.ai_addr else { return nil }
        let address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return IPv4Address(socketAddress: address)
    }

    /// DNS resolution time in ms, mirroring `baseline._dns_ms`.
    public static func resolutionMs(_ host: String) -> Double {
        let start = Date().timeIntervalSince1970
        _ = resolve(host)
        return PingStats.round((Date().timeIntervalSince1970 - start) * 1000, 2)
    }
}
