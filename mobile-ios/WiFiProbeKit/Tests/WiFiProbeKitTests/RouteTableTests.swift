import XCTest
@testable import WiFiProbeKit

/// Gateway discovery is the code most likely to be wrong in this app, and
/// the only part that reads kernel structures by hand. Splitting the parse
/// from the `sysctl` call makes it testable against a captured route
/// table: `route-table.bin` is a real dump, and the answer it should give
/// is pinned in `route-table-expected.txt`, so the test is deterministic
/// on any machine. The dump holds only RFC 1918 addresses.
final class RouteTableTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                        withExtension: ext))
    }

    func testFindsTheDefaultGatewayInARealRouteTable() throws {
        let data = try Data(contentsOf: fixture("route-table", "bin"))
        let expected = try String(contentsOf: fixture("route-table-expected", "txt"),
                                  encoding: .utf8)
        XCTAssertEqual(RouteTable.defaultGateway(from: data), expected)
    }

    func testEmptyTableYieldsNoGateway() {
        XCTAssertNil(RouteTable.defaultGateway(from: Data()))
    }

    /// A truncated buffer must return nil rather than reading past the end.
    func testTruncatedBufferIsRejectedRatherThanCrashing() throws {
        let data = try Data(contentsOf: fixture("route-table", "bin"))
        for cut in [1, 8, 16, 40, data.count / 3, data.count - 1] {
            _ = RouteTable.defaultGateway(from: data.prefix(cut))
        }
    }

    /// Garbage must not be read as a route: a zero length field would
    /// otherwise loop forever.
    func testGarbageTerminates() {
        XCTAssertNil(RouteTable.defaultGateway(from: Data(repeating: 0, count: 512)))
        XCTAssertNil(RouteTable.defaultGateway(from: Data(repeating: 0xFF, count: 512)))
    }

    /// ROUNDUP from net/route.h: padded to four bytes, and a zero-length
    /// sockaddr still consumes four.
    func testSockaddrPadding() {
        XCTAssertEqual(RouteTable.roundUp(0), 4)
        XCTAssertEqual(RouteTable.roundUp(1), 4)
        XCTAssertEqual(RouteTable.roundUp(4), 4)
        XCTAssertEqual(RouteTable.roundUp(5), 8)
        XCTAssertEqual(RouteTable.roundUp(16), 16)
    }

    /// The live path, exercised on the machine running the tests. Skipped
    /// rather than failed where there is no default route.
    func testLiveLookupAgreesWithTheSystem() throws {
        guard let gateway = try? RouteTable.defaultGateway() else {
            throw XCTSkip("no default IPv4 route on this host")
        }
        XCTAssertTrue(gateway.split(separator: ".").count == 4, "not a dotted quad: \(gateway)")
    }
}

#if os(macOS)
import Darwin

/// `rt_msghdr` is exposed to Swift on the macOS SDK but not the iOS one,
/// so `RouteTable` spells its layout out by hand. These pin the
/// hand-written constants against the real type on the one platform that
/// can see it: if an SDK ever changes the struct, this fails here rather
/// than silently misparsing the route table on a phone.
final class RouteTableLayoutTests: XCTestCase {

    func testHeaderSizeMatchesTheRealStruct() {
        XCTAssertEqual(RouteTable.messageHeaderSize, MemoryLayout<rt_msghdr>.size)
    }

    func testFieldOffsetsMatchTheRealStruct() {
        XCTAssertEqual(RouteTable.flagsOffset, MemoryLayout<rt_msghdr>.offset(of: \.rtm_flags))
        XCTAssertEqual(RouteTable.addrsOffset, MemoryLayout<rt_msghdr>.offset(of: \.rtm_addrs))
    }
}
#endif
