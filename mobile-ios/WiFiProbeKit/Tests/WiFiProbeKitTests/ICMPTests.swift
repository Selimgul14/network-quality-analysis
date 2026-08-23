import XCTest
@testable import WiFiProbeKit

final class ICMPTests: XCTestCase {

    // MARK: packet construction

    func testEchoRequestHeaderLayout() {
        let packet = ICMPPinger.echoPacket(sequence: 0x0107)
        XCTAssertEqual(packet[0], 8, "type must be echo request")
        XCTAssertEqual(packet[1], 0, "code")
        XCTAssertEqual(packet[6], 0x01, "sequence, high byte")
        XCTAssertEqual(packet[7], 0x07, "sequence, low byte")
        XCTAssertEqual(packet.count, 64, "8 byte header plus a 56 byte payload, as ping(8) sends")
    }

    /// The defining property of the one's complement checksum: recomputing
    /// it over a packet that already carries it yields zero. A receiver
    /// validates exactly this way, so a wrong checksum means every reply
    /// is dropped and the tool reports 100% loss on a healthy link.
    func testChecksumVerifiesToZero() {
        for sequence in [0, 1, 9, 255, 4096] as [UInt16] {
            let packet = ICMPPinger.echoPacket(sequence: sequence)
            XCTAssertEqual(ICMPPinger.checksum(packet), 0, "sequence \(sequence)")
        }
    }

    func testChecksumHandlesAnOddLengthBuffer() {
        XCTAssertNotEqual(ICMPPinger.checksum([0x01, 0x02, 0x03]), 0)
    }

    // MARK: resolution

    func testResolvesADottedQuadWithoutDNS() {
        XCTAssertNotNil(IPv4Address.resolve("1.1.1.1"))
    }

    func testUnresolvableHostReturnsNil() {
        XCTAssertNil(IPv4Address.resolve("no-such-host.invalid"))
    }

    // MARK: live

    /// Exercises the real socket. Skipped rather than failed where ICMP is
    /// blocked, which is the normal case on many venue networks and is
    /// precisely why the cloud reference leg uses a TCP handshake instead.
    func testLivePingReachesAPublicAnchor() async throws {
        let summary: PingStats.Summary
        do {
            summary = try await ICMPPinger.ping(host: "1.1.1.1", count: 5, interval: 0.2)
        } catch {
            throw XCTSkip("ICMP unavailable here: \(error)")
        }
        if summary.lossPct == 100 { throw XCTSkip("ICMP echo appears to be filtered") }
        XCTAssertGreaterThan(summary.rttMs, 0)
        XCTAssertLessThan(summary.rttMs, 2000)
    }

    /// The WiFi-link leg end to end: discover the gateway, then measure it.
    /// This is M10 on real hardware.
    func testLiveGatewayPingIsTheWiFiLinkLeg() async throws {
        guard let gateway = try? RouteTable.defaultGateway() else {
            throw XCTSkip("no default route")
        }
        let summary: PingStats.Summary
        do {
            summary = try await ICMPPinger.ping(host: gateway, count: 5, interval: 0.2)
        } catch {
            throw XCTSkip("gateway unreachable by ICMP: \(error)")
        }
        if summary.lossPct == 100 { throw XCTSkip("gateway does not answer ICMP here") }
        // The first hop is a local link, so it should be well under a
        // wide-area RTT. The summary page grades it against 10 ms.
        XCTAssertLessThan(summary.rttMs, 500, "first hop RTT of \(summary.rttMs) ms")
        print("WiFi link: \(summary.rttMs) ms, jitter \(summary.jitterMs) ms, loss \(summary.lossPct)%")
    }

    // MARK: reply parsing

    /// The bug this fixture exists for: on Darwin a SOCK_DGRAM ICMP socket
    /// hands back the IP header as well, so the ICMP type is not at byte 0.
    /// Reading it there yields 0x45, the version and IHL nibble, and every
    /// reply is discarded as "not an echo reply".
    func testParsesEchoReplyPastTheIPHeader() throws {
        let data = try fixture("icmp-echo-reply.bin")
        let parsed = try XCTUnwrap(ICMPPinger.parseReply([UInt8](data), count: data.count))
        XCTAssertEqual(parsed.type, 0)
        XCTAssertEqual(parsed.sequence, 4242)
    }

    /// The IHL is read rather than assumed, so a header carrying options is
    /// still parsed correctly. Built by widening the fixture's header to 24
    /// bytes and inserting four bytes of IP option padding.
    func testHonoursAnIPHeaderWithOptions() throws {
        var bytes = [UInt8](try fixture("icmp-echo-reply.bin"))
        bytes[0] = 0x46                                  // IHL 6, so 24 bytes
        bytes.insert(contentsOf: [0x01, 0x01, 0x01, 0x00], at: 20)
        let parsed = try XCTUnwrap(ICMPPinger.parseReply(bytes, count: bytes.count))
        XCTAssertEqual(parsed.type, 0)
        XCTAssertEqual(parsed.sequence, 4242)
    }

    func testRejectsATruncatedDatagram() {
        let bytes = [UInt8](repeating: 0x45, count: 12)
        XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
    }

    func testRejectsANonEchoReply() throws {
        var bytes = [UInt8](try fixture("icmp-echo-reply.bin"))
        bytes[20] = 3                                    // destination unreachable
        XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
    }

    /// A router that will not answer a ping addressed to itself still has to
    /// report an expired TTL. The sequence is recovered from the copy of our
    /// own packet quoted inside the error, which is what ties the reply to
    /// the request it answers.
    func testParsesTimeExceededAndRecoversTheQuotedSequence() throws {
        let data = try fixture("icmp-time-exceeded.bin")
        let parsed = try XCTUnwrap(ICMPPinger.parseReply([UInt8](data), count: data.count))
        XCTAssertEqual(parsed.type, 11)
        XCTAssertEqual(parsed.sequence, 4243)
    }

    /// A time-exceeded quoting somebody else's traffic is not ours to count.
    func testIgnoresTimeExceededQuotingANonEchoDatagram() throws {
        var bytes = [UInt8](try fixture("icmp-time-exceeded.bin"))
        bytes[48] = 17                                   // quoted protocol is not an echo
        XCTAssertNil(ICMPPinger.parseReply(bytes, count: bytes.count))
    }

    func testRejectsTimeExceededTruncatedBeforeTheQuotedHeader() throws {
        let bytes = [UInt8](try fixture("icmp-time-exceeded.bin"))
        XCTAssertNil(ICMPPinger.parseReply(bytes, count: 40))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: nil))
        return try Data(contentsOf: url)
    }
}
