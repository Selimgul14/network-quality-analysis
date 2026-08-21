import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether an address is on the same link as this device.
///
/// This exists because of a measurement error found on 21 August 2026. A
/// TCP refusal was being treated as proof that a host answered, but
/// connecting to 192.0.2.1 (TEST-NET-1, reserved and unrouted) came back
/// `ECONNREFUSED` in 4.8 ms. Nothing left the device: the local stack
/// rejected it. Recording that as a round trip would have invented a
/// measurement of a host that does not exist, which is the exact failure
/// this project is built to prevent.
///
/// The guard is that the gateway is on-link by definition, sharing a
/// subnet with one of our own interface addresses. A refusal from an
/// on-link address is an answer; a refusal from anywhere else is not
/// trusted.
public enum LocalSubnet {

    /// Pure form, so the masking is testable without any interfaces.
    public static func isOnLink(host: String, address: String, netmask: String) -> Bool {
        guard let host = packed(host), let address = packed(address),
              let mask = packed(netmask), mask != 0 else { return false }
        return host & mask == address & mask
    }

    /// Against every IPv4 interface this device currently has.
    public static func isOnLink(_ host: String) -> Bool {
        for (address, netmask) in interfaces() {
            if isOnLink(host: host, address: address, netmask: netmask) { return true }
        }
        return false
    }

    /// (address, netmask) for each running, non-loopback IPv4 interface.
    static func interfaces() -> [(String, String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(String, String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            if let a = dotted(addr), let m = dotted(mask) { found.append((a, m)) }
        }
        return found
    }

    private static func dotted(_ pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            var raw = $0.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
            else { return nil }
            return String(cString: buffer)
        }
    }

    private static func packed(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }
}
