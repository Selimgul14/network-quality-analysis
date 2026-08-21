import Foundation

/// Records produced but not yet accepted by the backend (M9).
///
/// The upload fails precisely when the network is worst, which is when the
/// measurement matters most, so nothing is discarded on a failed send.
/// This is the probe's SQLite buffer with the persistence removed:
/// surviving a relaunch is MS1, not this.
public actor PendingStore {
    public struct Entry: Sendable {
        public let id: UUID
        public let record: Record
    }

    private var entries: [Entry] = []
    /// Records the backend refused outright. A rejection is an app bug
    /// rather than a network condition, so they are kept apart and
    /// surfaced instead of being retried forever.
    private(set) var rejected: [Entry] = []

    public init() {}

    public func add(_ record: Record) {
        entries.append(Entry(id: UUID(), record: record))
    }

    /// Oldest first: order is preserved so a partial upload leaves a
    /// contiguous prefix delivered.
    public func take() -> [Entry] { entries }

    public func acknowledge(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func reject(_ id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            rejected.append(entries.remove(at: index))
        }
    }

    public var pendingCount: Int { entries.count }
    public var rejectedCount: Int { rejected.count }
}
