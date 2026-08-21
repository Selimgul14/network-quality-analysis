import Foundation
import WebKit

/// Page load timing through a real browser engine, mirroring `web.py`.
///
/// Reads the Navigation Timing API rather than timing the transfer, so
/// rendering and script execution are counted, not just network time
/// (cf. Wang et al., WProf). The JavaScript and the four subtractions are
/// identical to the probe's, which is what makes the numbers comparable.
///
/// Two details that matter. A fresh non-persistent data store per run
/// gives a cold cache, matching a freshly launched Chromium; reusing one
/// would measure the cache from the second run onward. And the web view
/// is mounted in the view hierarchy at 1x1 point rather than left
/// detached, because the system throttles or suspends off-screen web
/// views and the load can then simply never finish.
@MainActor
public final class WebWorkload: NSObject, WKNavigationDelegate {

    public enum Failure: Error, Equatable {
        case timedOut
        case navigation(String)
        case noTimingEntry
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    /// - Parameter host: a view to mount the web view in. Optional so the
    ///   logic can be exercised headlessly in tests; the app always
    ///   supplies one.
    public func run(target: URL, host: PlatformView? = nil) async throws -> [String: MetricValue] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()  // cold cache per run
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1),
                                configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        host?.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            self.webView = nil
        }

        try await load(target, in: webView)

        guard let json = try await webView.evaluateJavaScript(
            NavigationTiming.javaScript) as? String else {
            throw Failure.noTimingEntry
        }
        return try NavigationTiming.metrics(fromJSON: json)
    }

    private func load(_ target: URL, in webView: WKWebView) async throws {
        let timeoutTask = Task { [timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.resume(throwing: Failure.timedOut)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: target))
        }
    }

    private func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: Error) {
        resume(throwing: Failure.navigation(error.localizedDescription))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        resume(throwing: Failure.navigation(error.localizedDescription))
    }
}

#if canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
#endif
