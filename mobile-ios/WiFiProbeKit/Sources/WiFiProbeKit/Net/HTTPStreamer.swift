import Foundation

/// Streams a URL and reports how the bytes arrived.
///
/// Shared by the download, video and bufferbloat workloads, which are the
/// same transfer measured three ways. Chunk arrival times are recorded so
/// the video simulation can replay them; `URLSession.AsyncBytes` is not
/// used because iterating 25 MiB one byte at a time costs more than the
/// measurement it is trying to take.
///
/// The session is ephemeral and the request defeats the cache. Without
/// both, the second run of the day reports a throughput figure that
/// describes flash storage rather than a network.
public enum HTTPStreamer {

    /// The probe presents a browser User-Agent for the same reason
    /// `video.py` does: some CDNs return 403 to anything else.
    public static let userAgent =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0 Safari/537.36"

    public struct Result: Sendable {
        public let bytes: Int
        public let seconds: Double
        public let chunks: [VideoSimulator.Chunk]

        public var mbps: Double {
            seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
        }
    }

    public enum Failure: Error, Equatable {
        case http(status: Int)
        case transport(String)
    }

    public static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    /// - Parameter collectChunks: keep per-chunk arrival times. Only the
    ///   video workload needs them; the others just want the total.
    public static func stream(_ url: URL,
                              collectChunks: Bool = false) async throws -> Result {
        let collector = StreamCollector(collectChunks: collectChunks)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: collector,
                                 delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request(url))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.onFinish = { result in continuation.resume(with: result) }
                collector.start = Date()
                task.resume()
            }
        } onCancel: {
            // Cancellation is how the bufferbloat workload stops loading
            // the link. A partial transfer is still a valid measurement of
            // how fast the bytes were arriving.
            task.cancel()
        }
    }
}

/// Counts bytes as they arrive. Confined to a serial delegate queue, so
/// its mutable state is only ever touched from one thread.
final class StreamCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let collectChunks: Bool
    private var bytes = 0
    private var chunks: [VideoSimulator.Chunk] = []
    var start = Date()
    var onFinish: ((Result<HTTPStreamer.Result, Error>) -> Void)?
    private var finished = false

    init(collectChunks: Bool) {
        self.collectChunks = collectChunks
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(HTTPStreamer.Failure.http(status: http.statusCode)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += data.count
        if collectChunks {
            chunks.append(.init(bytes: data.count, at: Date().timeIntervalSince(start)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let elapsed = Date().timeIntervalSince(start)
        // A cancelled transfer still measured a real delivery rate, which
        // is the whole point of the bufferbloat workload's saturating
        // download, so it completes rather than throwing.
        if let error, (error as? URLError)?.code != .cancelled, bytes == 0 {
            finish(.failure(HTTPStreamer.Failure.transport(error.localizedDescription)))
            return
        }
        finish(.success(.init(bytes: bytes, seconds: elapsed, chunks: chunks)))
    }

    private func finish(_ result: Result<HTTPStreamer.Result, Error>) {
        guard !finished else { return }
        finished = true
        onFinish?(result)
    }
}
