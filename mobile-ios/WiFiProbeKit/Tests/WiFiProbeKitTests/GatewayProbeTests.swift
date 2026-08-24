import XCTest
@testable import WiFiProbeKit

final class GatewayProbeTests: XCTestCase {

    /// The whole WiFi-link leg against the real router: discover it, then
    /// measure it by whatever it will answer to.
    func testLiveGatewayIsMeasurableSomehow() async throws {
        guard let gateway = try? RouteTable.defaultGateway() else {
            throw XCTSkip("no default route")
        }
        let result = await GatewayProbe.measure(host: gateway, count: 5, interval: 0.2)
        print("gateway \(gateway): method=\(result.method.rawValue) "
              + "port=\(result.port.map(String.init) ?? "-") "
              + "rtt=\(result.summary.rttMs) ms jitter=\(result.summary.jitterMs) "
              + "loss=\(result.summary.lossPct)%")

        if result.method == .none {
            throw XCTSkip("this router answers neither ICMP nor TCP on any candidate port")
        }
        XCTAssertLessThan(result.summary.lossPct, 100)
        XCTAssertGreaterThan(result.summary.rttMs, 0)
        // A first hop is a local link: it should be far quicker than any
        // wide-area RTT. The summary page grades it against 10 ms.
        XCTAssertLessThan(result.summary.rttMs, 500)
    }

    /// A refusal is an answer, so it must carry a timing. Anything else
    /// must not, or the tool would invent a round trip that never happened.
    func testOnlyAnsweredProbesYieldATiming() {
        XCTAssertEqual(TCPProbe.Outcome.connected(4.2).rttMs, 4.2)
        XCTAssertEqual(TCPProbe.Outcome.refused(3.1).rttMs, 3.1)
        XCTAssertNil(TCPProbe.Outcome.unreachable.rttMs)
    }

    func testUnroutableHostIsNotReportedAsResponding() async {
        // TEST-NET-1, reserved and unrouted.
        let port = await GatewayProbe.respondingPort(host: "192.0.2.1", ports: [80])
        XCTAssertNil(port)
    }
}

/// The guard that stops a locally-generated refusal being read as a reply.
final class LocalSubnetTests: XCTestCase {

    func testSameSubnetIsOnLink() {
        XCTAssertTrue(LocalSubnet.isOnLink(host: "192.168.1.1",
                                           address: "192.168.1.57",
                                           netmask: "255.255.255.0"))
        XCTAssertTrue(LocalSubnet.isOnLink(host: "10.224.23.254",
                                           address: "10.224.16.9",
                                           netmask: "255.255.240.0"))
    }

    func testDifferentSubnetIsNotOnLink() {
        XCTAssertFalse(LocalSubnet.isOnLink(host: "192.168.2.1",
                                            address: "192.168.1.57",
                                            netmask: "255.255.255.0"))
        // The address that exposed the bug: reserved, unrouted, and
        // refused in 4.8 ms by the local stack without a packet leaving.
        XCTAssertFalse(LocalSubnet.isOnLink(host: "192.0.2.1",
                                            address: "10.224.16.9",
                                            netmask: "255.255.240.0"))
    }

    func testMalformedInputIsNeverOnLink() {
        XCTAssertFalse(LocalSubnet.isOnLink(host: "not-an-ip", address: "192.168.1.1",
                                            netmask: "255.255.255.0"))
        XCTAssertFalse(LocalSubnet.isOnLink(host: "192.168.1.1", address: "192.168.1.1",
                                            netmask: "0.0.0.0"))
        XCTAssertFalse(LocalSubnet.isOnLink(host: "999.1.1.1", address: "192.168.1.1",
                                            netmask: "255.255.255.0"))
    }

    func testThisDeviceHasAnOnLinkGateway() throws {
        guard let gateway = try? RouteTable.defaultGateway() else {
            throw XCTSkip("no default route")
        }
        // A default gateway that is not on-link would mean the route table
        // walk picked the wrong interface, which is the other explanation
        // for a router that never answers.
        XCTAssertTrue(LocalSubnet.isOnLink(gateway),
                      "\(gateway) is not in any local subnet: wrong interface?")
    }

    /// Refusals from off-link addresses must be discarded even though the
    /// probe reports a timing for them.
    ///
    /// Driven by an injected probe rather than the real network: this is
    /// about the trust rule, not about how a particular network happens to
    /// treat reserved address space. On some networks a connection to
    /// 192.0.2.1 (TEST-NET-1) refuses in a few milliseconds; on others it
    /// times out instead, which made this test flaky when it drove the
    /// real stack.
    func testOffLinkRefusalIsNotAcceptedAsAnAnswer() async {
        let port = await GatewayProbe.respondingPort(
            host: "192.0.2.1", ports: [80], onLink: { _ in false },
            probe: { _, _ in .refused(4.85) })
        XCTAssertNil(port)
    }

    func testOnLinkRefusalIsAcceptedAsAnAnswer() async {
        let port = await GatewayProbe.respondingPort(
            host: "192.0.2.1", ports: [80], onLink: { _ in true },
            probe: { _, _ in .refused(4.85) })
        XCTAssertEqual(port, 80, "a refusal from an on-link host is a real round trip")
    }
}

// MARK: the ladder, with no network

private extension GatewayProbe.Probes {
    /// Every rung silent unless a test replaces one.
    static func silent() -> GatewayProbe.Probes {
        GatewayProbe.Probes(
            echo: { _, count, _ in PingStats.summarise(rtts: [], sent: count) },
            firstHopTTL: { _, count, _ in PingStats.summarise(rtts: [], sent: count) },
            tcpPort: { _ in nil },
            tcp: { _, _, count, _ in PingStats.summarise(rtts: [], sent: count) })
    }
}

final class GatewayLadderTests: XCTestCase {

    func testEchoWinsWhenTheRouterAnswersIt() async {
        var probes = GatewayProbe.Probes.silent()
        probes.echo = { _, count, _ in PingStats.summarise(rtts: [3.2, 3.4, 3.1], sent: count) }
        let result = await GatewayProbe.measure(host: "10.0.0.1", count: 3,
                                                interval: 0, probes: probes)
        XCTAssertEqual(result.method, .icmp)
        XCTAssertEqual(result.attempts.count, 1, "later rungs must not run once one answers")
    }

    func testFallsThroughToTTLWhenEchoIsIgnored() async {
        var probes = GatewayProbe.Probes.silent()
        probes.firstHopTTL = { _, count, _ in PingStats.summarise(rtts: [4.0, 4.2], sent: count) }
        let result = await GatewayProbe.measure(host: "10.0.0.1", count: 2,
                                                interval: 0, probes: probes)
        XCTAssertEqual(result.method, .firstHopTTL)
        XCTAssertEqual(result.attempts.map(\.method), [.icmp, .firstHopTTL])
    }

    func testFallsThroughToTCPWhenNeitherICMPRungAnswers() async {
        var probes = GatewayProbe.Probes.silent()
        probes.tcpPort = { _ in 80 }
        probes.tcp = { _, _, count, _ in PingStats.summarise(rtts: [6.1], sent: count) }
        let result = await GatewayProbe.measure(host: "10.0.0.1", count: 1,
                                                interval: 0, probes: probes)
        XCTAssertEqual(result.method, .tcp)
        XCTAssertEqual(result.port, 80)
        XCTAssertEqual(result.attempts.map(\.method), [.icmp, .firstHopTTL, .tcp])
    }

    /// Total silence has to stay distinguishable from a measurement, and the
    /// app has to be able to say what it tried rather than offer the user a
    /// choice of two explanations.
    func testTotalSilenceRecordsEveryRungItTried() async {
        let result = await GatewayProbe.measure(host: "10.0.0.1", count: 4,
                                                interval: 0, probes: .silent())
        XCTAssertEqual(result.method, GatewayProbe.Method.none)
        XCTAssertEqual(result.summary.lossPct, 100)
        XCTAssertEqual(result.attempts.count, 3)
        XCTAssertTrue(result.attempts.allSatisfy { !$0.answered })
    }

    /// A rung that throws is a rung that did not answer, not a crash.
    func testAThrowingRungIsTreatedAsSilence() async {
        struct Boom: Error {}
        var probes = GatewayProbe.Probes.silent()
        probes.echo = { _, _, _ in throw Boom() }
        probes.firstHopTTL = { _, count, _ in PingStats.summarise(rtts: [5.0], sent: count) }
        let result = await GatewayProbe.measure(host: "10.0.0.1", count: 1,
                                                interval: 0, probes: probes)
        XCTAssertEqual(result.method, .firstHopTTL)
        XCTAssertFalse(result.attempts[0].answered)
    }
}
