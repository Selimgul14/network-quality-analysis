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
    func testOffLinkRefusalIsNotAcceptedAsAnAnswer() async {
        let port = await GatewayProbe.respondingPort(
            host: "192.0.2.1", ports: [80], onLink: { _ in false })
        XCTAssertNil(port)
    }

    func testOnLinkRefusalIsAcceptedAsAnAnswer() async {
        let port = await GatewayProbe.respondingPort(
            host: "192.0.2.1", ports: [80], onLink: { _ in true })
        XCTAssertEqual(port, 80, "a refusal from an on-link host is a real round trip")
    }
}
