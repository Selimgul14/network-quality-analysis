import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds the default gateway, which is the router the phone is associated
/// with, and therefore the far end of the WiFi link (M10).
///
/// iOS publishes no API for this. The route table is read with `sysctl`
/// and walked by hand: a sequence of `rt_msghdr` records, each followed by
/// the sockaddrs its `rtm_addrs` bitmask selects, every sockaddr advanced
/// by its own `sa_len` rounded up to four bytes. The wanted entry is the
/// one whose destination is 0.0.0.0 with `RTF_GATEWAY | RTF_UP` set.
///
/// Parsing is separated from fetching so the awkward half takes a `Data`
/// and a captured route table becomes a test fixture. This is the code in
/// the app most likely to be wrong, and it is fully testable with no
/// device and no network.
public enum RouteTable {

    // net/route.h. Defined here rather than imported: these are C macros
    // and their visibility to Swift is not guaranteed across SDKs.
    private static let rtfUp: Int32 = 0x1
    private static let rtfGateway: Int32 = 0x2
    private static let rtaDst: Int32 = 0x1
    private static let rtaGateway: Int32 = 0x2
    private static let netRTFlags: Int32 = 2

    /// `sizeof(struct rt_msghdr)`. Spelled out rather than taken from
    /// `MemoryLayout` because the type is exposed to Swift on the macOS
    /// SDK but not the iOS one, and this code has to compile for a phone.
    /// Layout: 36 bytes of header fields (msglen, version, type, index,
    /// two padding bytes, then flags, addrs, pid, seq, errno, use, inits)
    /// followed by a 56 byte `rt_metrics` of fourteen 32-bit words.
    /// `RouteTableTests` pins this against the real type on macOS, so a
    /// change in the SDK cannot pass unnoticed.
    static let messageHeaderSize = 92
    static let flagsOffset = 8
    static let addrsOffset = 12

    public enum Failure: Error, Equatable {
        case sysctlFailed(errno: Int32)
        case noDefaultRoute
    }

    // MARK: fetching

    /// The raw route table for IPv4 gateway routes.
    public static func rawTable() throws -> Data {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, netRTFlags, rtfGateway]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw Failure.sysctlFailed(errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            throw Failure.sysctlFailed(errno: errno)
        }
        return Data(buffer.prefix(size))
    }

    // MARK: parsing

    /// Walk the buffer and return the default route's gateway address.
    public static func defaultGateway(from data: Data) -> String? {
        let headerSize = messageHeaderSize
        var offset = 0

        return data.withUnsafeBytes { raw -> String? in
            while offset + headerSize <= raw.count {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset,
                                                          as: UInt16.self))
                guard messageLength >= headerSize,
                      offset + messageLength <= raw.count else { return nil }

                let flags = raw.loadUnaligned(fromByteOffset: offset + flagsOffset,
                                              as: Int32.self)
                let addrs = raw.loadUnaligned(fromByteOffset: offset + addrsOffset,
                                              as: Int32.self)

                if flags & rtfGateway != 0, flags & rtfUp != 0,
                   addrs & rtaDst != 0, addrs & rtaGateway != 0 {
                    var cursor = offset + headerSize
                    var destinationIsDefault = false

                    // Sockaddrs appear in ascending RTA_ bit order.
                    for bit in 0..<8 {
                        let mask = Int32(1 << bit)
                        guard addrs & mask != 0, cursor < offset + messageLength else { continue }
                        let saLen = Int(raw.loadUnaligned(fromByteOffset: cursor, as: UInt8.self))
                        let family = raw.loadUnaligned(fromByteOffset: cursor + 1, as: UInt8.self)

                        if mask == rtaDst {
                            // A default route's destination is 0.0.0.0, which
                            // the kernel may report with a zero-length sockaddr.
                            destinationIsDefault = saLen == 0
                                || (family == UInt8(AF_INET)
                                    && ipv4(raw, at: cursor, length: saLen) == "0.0.0.0")
                        } else if mask == rtaGateway, destinationIsDefault {
                            if family == UInt8(AF_INET),
                               let address = ipv4(raw, at: cursor, length: saLen) {
                                return address
                            }
                        }
                        cursor += roundUp(saLen)
                    }
                }
                offset += messageLength
            }
            return nil
        }
    }

    public static func defaultGateway() throws -> String {
        guard let gateway = defaultGateway(from: try rawTable()) else {
            throw Failure.noDefaultRoute
        }
        return gateway
    }

    // MARK: helpers

    /// ROUNDUP from net/route.h: sockaddrs are padded to a 4 byte boundary,
    /// and a zero-length one still consumes 4.
    static func roundUp(_ length: Int) -> Int {
        length > 0 ? (1 + ((length - 1) | (MemoryLayout<UInt32>.size - 1))) : MemoryLayout<UInt32>.size
    }

    /// sockaddr_in: sin_len, sin_family, sin_port, then four address bytes.
    private static func ipv4(_ raw: UnsafeRawBufferPointer, at offset: Int,
                             length: Int) -> String? {
        guard length >= 8, offset + 8 <= raw.count else { return nil }
        let bytes = (0..<4).map { raw.loadUnaligned(fromByteOffset: offset + 4 + $0,
                                                    as: UInt8.self) }
        return bytes.map(String.init).joined(separator: ".")
    }
}

/// The gateway only changes when the network does, so it is cached for the
/// same 300 seconds `baseline.gateway_ip` caches it for.
public actor GatewayCache {
    public static let shared = GatewayCache()
    private var cached: (address: String, at: Date)?
    private let ttl: TimeInterval = 300

    public init() {}

    public func address() throws -> String {
        if let cached, Date().timeIntervalSince(cached.at) < ttl { return cached.address }
        let address = try RouteTable.defaultGateway()
        cached = (address, Date())
        return address
    }

    /// Discard the cached address. Called at the start of every run,
    /// because the phone may have joined a different network since the
    /// last one.
    public func flush() { cached = nil }

    /// For tests.
    public var isEmpty: Bool { cached == nil }
}
