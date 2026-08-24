import Foundation

/// Finished runs on disk, one JSON file each.
///
/// One file per run rather than one file holding all of them: a run is
/// written once and never edited, a partial write can only damage the run
/// being written, and a file that will not decode is skipped rather than
/// taking the history with it. A few hundred small records do not need
/// SQLite, and a plain file store is testable against a temporary
/// directory with no simulator.
public actor RunStore {

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Application Support, which is backed up and not purged under disk
    /// pressure the way Caches is.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("runs", isDirectory: true)
    }

    public func save(_ run: StoredRun) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(run.id).json")
        try encoder.encode(run).write(to: url, options: .atomic)
    }

    /// Newest first, which is the order History shows and the order the
    /// charts want.
    public func all() -> [StoredRun] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StoredRun.self, from: data)
            }
            .sorted { $0.finishedAt > $1.finishedAt }
    }

    public func runs(site: String) -> [StoredRun] {
        all().filter { $0.site == site }
    }

    /// Sites in order of most recent use, so a picker offers the network
    /// you are most likely on.
    public func sites() -> [String] {
        var seen: [String] = []
        for run in all() where !seen.contains(run.site) { seen.append(run.site) }
        return seen
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).json"))
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
