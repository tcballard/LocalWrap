import SwiftUI
import WebKit

struct PreviewWebView: NSViewRepresentable {
    let initialURL: URL
    @Binding var state: PreviewState
    let openExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.loadedURL = initialURL
        context.coordinator.lastReloadToken = state.reloadToken
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != initialURL {
            context.coordinator.loadedURL = initialURL
            webView.load(URLRequest(url: initialURL))
        } else if context.coordinator.lastReloadToken != state.reloadToken {
            context.coordinator.lastReloadToken = state.reloadToken
            webView.reloadFromOrigin()
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: PreviewWebView
        var loadedURL: URL?
        var lastReloadToken = 0
        private let policy = PreviewNavigationPolicy()

        init(parent: PreviewWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            switch policy.decision(for: navigationAction.request.url) {
            case .allow:
                decisionHandler(.allow)
            case .openExternal(let url):
                parent.openExternal(url)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")
            let allowed = policy.allowsResponse(
                url: navigationResponse.response.url,
                canShowMIMEType: navigationResponse.canShowMIMEType,
                contentDisposition: contentDisposition
            )
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.state.status = .loading
            parent.state.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            parent.state.status = .ready
            parent.state.currentURL = webView.url
            parent.state.errorMessage = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: any Error
        ) {
            fail(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            fail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.state.status = .failed
            parent.state.errorMessage = "The preview web process stopped unexpectedly."
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            switch policy.decision(for: navigationAction.request.url) {
            case .allow:
                webView.load(navigationAction.request)
            case .openExternal(let url):
                parent.openExternal(url)
            case .cancel:
                break
            }
            return nil
        }

        private func fail(_ error: any Error) {
            parent.state.status = .failed
            parent.state.errorMessage = error.localizedDescription
        }
    }
}
