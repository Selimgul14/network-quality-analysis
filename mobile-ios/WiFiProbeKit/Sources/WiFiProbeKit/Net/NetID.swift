import Foundation
import CryptoKit

/// Egress network fingerprint, mirroring `probe/netid.py`.
///
/// The public IP identifies a network well but is locating, so per the
/// project's ethics stance it is never stored raw: only a truncated
/// SHA-256, resolved at most once per TTL.
public actor NetID {
    public static let shared = NetID()

    private var cached: String?
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 600
    private let endpoint = URL(string: "https://api.ipify.org")!

    public func hash(session: URLSession = .shared) async -> String? {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            return cached
        }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 5
            let (data, _) = try await session.data(for: request)
            guard let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty
            else { return cached }
            cached = Self.truncatedHash(of: ip)
            fetchedAt = Date()
        } catch {
            return cached  // keep the last good value, as the probe does
        }
        return cached
    }

    static func truncatedHash(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
            .description
    }
}
