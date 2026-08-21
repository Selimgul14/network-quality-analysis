import Foundation

/// Ships records to the existing `POST /ingest`, mirroring
/// `probe/uploader.py`. The endpoint, the bearer token and the record
/// shape are all unchanged from what the Pi uses (C1).
public struct Uploader: Sendable {

    public enum Outcome: Equatable, Sendable {
        case accepted
        /// The record was already stored: the probe's buffer treats this
        /// as success so a retried upload can be safely acknowledged.
        case duplicate
        /// Permanent refusal (auth or schema). Retrying cannot help, and
        /// it means the app is at fault, so it is surfaced not looped.
        case rejected(status: Int, body: String)
    }

    public enum Failure: Error, Equatable {
        case transport(String)
        case server(status: Int)
    }

    private let config: ProbeConfig
    private let session: URLSession

    public init(config: ProbeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func send(_ record: Record) async throws -> Outcome {
        let json = try record.jsonObject()
        try ContractValidator.validate(json)  // M3: never post an invalid record

        var request = URLRequest(url: config.ingestURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.ingestToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try record.encoded()
        request.timeoutInterval = 15

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["status"] as? String }
            return status == "duplicate" ? .duplicate : .accepted
        case 401, 403, 422:
            return .rejected(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        default:
            throw Failure.server(status: http.statusCode)
        }
    }

    /// Drain the pending store, oldest first. On a transport or server
    /// failure it stops rather than skipping ahead, so records are
    /// delivered in order and nothing is silently left behind, which is
    /// what `uploader.flush`'s `break` does.
    @discardableResult
    public func drain(_ store: PendingStore) async -> Int {
        var sent = 0
        for entry in await store.take() {
            do {
                switch try await send(entry.record) {
                case .accepted, .duplicate:
                    await store.acknowledge(entry.id)
                    sent += 1
                case .rejected:
                    await store.reject(entry.id)
                }
            } catch {
                break  // backend unreachable; keep this record and the rest
            }
        }
        return sent
    }
}
