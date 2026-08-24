import Foundation

/// Records produced but not yet accepted by the backend (M9).
///
/// The upload fails precisely when the network is worst, which is when
/// the measurement matters most, so nothing is discarded on a failed
/// send. Given a directory the queue is mirrored to disk and survives the
/// app being killed mid-run, which is MS1. Given nil it stays in memory,
/// which is what the unit tests want.
public actor PendingStore {
    public struct Entry: Sendable, Codable {
        public let id: UUID
        public let record: Record
    }

    private var entries: [Entry] = []
    /// Records the backend refused outright. A rejection is an app bug
    /// rather than a network condition, so they are kept apart and
    /// surfaced instead of being retried forever.
    private(set) var rejected: [Entry] = []

    private let directory: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            entries = Self.load(from: directory.appendingPathComponent("queue.json"),
                                decoder: decoder)
            rejected = Self.load(from: directory.appendingPathComponent("rejected.json"),
                                 decoder: decoder)
        }
    }

    public func add(_ record: Record) {
        entries.append(Entry(id: UUID(), record: record))
        persist()
    }

    /// Oldest first: order is preserved so a partial upload leaves a
    /// contiguous prefix delivered.
    public func take() -> [Entry] { entries }

    public func acknowledge(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    public func reject(_ id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            rejected.append(entries.remove(at: index))
            persist()
        }
    }

    public var pendingCount: Int { entries.count }
    public var rejectedCount: Int { rejected.count }

    // MARK: disk

    private func persist() {
        guard let directory else { return }
        write(entries, to: directory.appendingPathComponent("queue.json"))
        write(rejected, to: directory.appendingPathComponent("rejected.json"))
    }

    private func write(_ list: [Entry], to url: URL) {
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A queue file that will not decode is dropped rather than crashing
    /// the app on launch. Losing an unsent record is bad; refusing to
    /// start is worse. The date decode this depends on tolerates both a
    /// fractional and a whole-second timestamp (see
    /// `Record.decodeTimestamp`), so the only files that hit this path are
    /// genuinely corrupt ones, not merely differently formatted ones.
    private static func load(from url: URL, decoder: JSONDecoder) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// Where the app keeps its queue, beside the runs.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("pending", isDirectory: true)
    }
}
