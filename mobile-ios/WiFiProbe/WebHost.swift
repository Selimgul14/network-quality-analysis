import SwiftUI
import WebKit

/// A one point view kept in the hierarchy purely so the web workload has
/// somewhere to mount its `WKWebView`.
///
/// This is not decoration. The system throttles or suspends web views that
/// are not in a view hierarchy, and a detached one can simply never finish
/// loading, which would show up as every web measurement timing out.
@MainActor
final class WebHost {
    static let shared = WebHost()
    weak var view: UIView?
}

struct WebHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .init(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        WebHost.shared.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        WebHost.shared.view = uiView
    }
}
