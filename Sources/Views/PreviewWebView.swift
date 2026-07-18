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
        context.coordinator.attach(to: webView, initialURL: initialURL, state: state)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.configuredURL != initialURL {
            context.coordinator.reset(for: initialURL, state: state)
            webView.load(URLRequest(url: initialURL))
            return
        }
        context.coordinator.consumeRequests(state, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: PreviewWebView
        private(set) var configuredURL: URL?

        private var lastBackToken = 0
        private var lastForwardToken = 0
        private var lastReloadToken = 0
        private var lastStopToken = 0
        private var observations: [NSKeyValueObservation] = []
        private var isAttached = false
        private let policy = PreviewNavigationPolicy()

        init(parent: PreviewWebView) {
            self.parent = parent
        }

        func attach(to webView: WKWebView, initialURL: URL, state: PreviewState) {
            isAttached = true
            reset(for: initialURL, state: state)
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
                webView.observe(\.title, options: [.new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
                webView.observe(\.estimatedProgress, options: [.new]) {
                    [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor in self?.scheduleSnapshot(from: webView) }
                },
            ]
        }

        func reset(for url: URL, state: PreviewState) {
            configuredURL = url
            lastBackToken = state.backToken
            lastForwardToken = state.forwardToken
            lastReloadToken = state.reloadToken
            lastStopToken = state.stopToken
        }

        func detach() {
            isAttached = false
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        func consumeRequests(_ state: PreviewState, in webView: WKWebView) {
            if state.backToken != lastBackToken {
                lastBackToken = state.backToken
                if webView.canGoBack { webView.goBack() }
            }
            if state.forwardToken != lastForwardToken {
                lastForwardToken = state.forwardToken
                if webView.canGoForward { webView.goForward() }
            }
            if state.reloadToken != lastReloadToken {
                lastReloadToken = state.reloadToken
                webView.reloadFromOrigin()
            }
            if state.stopToken != lastStopToken {
                lastStopToken = state.stopToken
                webView.stopLoading()
                finishStoppedLoad()
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let context = navigationContext(for: navigationAction)
            switch policy.decision(for: context) {
            case .allow:
                decisionHandler(.allow)
            case .openExternal(let url):
                parent.openExternal(url)
                decisionHandler(.cancel)
            case .cancel:
                if context.isMainFrame {
                    parent.state.markFailed("Preview blocked a non-local or unsafe navigation.")
                }
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
            if !allowed, navigationResponse.isForMainFrame {
                parent.state.markFailed("Preview blocked a download or unsupported response.")
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.state.markLoading()
            publishSnapshot(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            publishSnapshot(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            publishSnapshot(from: webView)
            parent.state.markLoaded()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: any Error
        ) {
            fail(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            fail(error, webView: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            publishSnapshot(from: webView)
            parent.state.markFailed("The preview web process stopped unexpectedly.")
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let context = navigationContext(for: navigationAction)
            switch policy.decision(for: context) {
            case .allow:
                webView.load(navigationAction.request)
            case .openExternal(let url):
                parent.openExternal(url)
            case .cancel:
                if context.isMainFrame {
                    parent.state.markFailed("Preview blocked a non-local or unsafe navigation.")
                }
            }
            return nil
        }

        private func navigationContext(
            for navigationAction: WKNavigationAction
        ) -> PreviewNavigationContext {
            PreviewNavigationContext.resolvingWebKitFrames(
                url: navigationAction.request.url,
                targetFrameIsMain: navigationAction.targetFrame?.isMainFrame,
                sourceFrameIsMain: navigationAction.sourceFrame.isMainFrame,
                isUserActivated: navigationAction.navigationType == .linkActivated
            )
        }

        private func fail(_ error: any Error, webView: WKWebView) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else {
                publishSnapshot(from: webView)
                return
            }
            publishSnapshot(from: webView)
            parent.state.markFailed(error.localizedDescription)
        }

        private func finishStoppedLoad() {
            Task { @MainActor [weak self] in
                guard let self, self.isAttached else { return }
                if self.parent.state.hasLoadedContent {
                    self.parent.state.markLoaded()
                } else {
                    self.parent.state.markFailed("Loading stopped.")
                }
            }
        }

        private func scheduleSnapshot(from webView: WKWebView?) {
            guard let webView, isAttached else { return }
            publishSnapshot(from: webView)
        }

        private func publishSnapshot(from webView: WKWebView) {
            guard isAttached else { return }
            parent.state.apply(PreviewWebSnapshot(
                currentURL: webView.url,
                pageTitle: webView.title,
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                estimatedProgress: webView.estimatedProgress,
                isLoading: webView.isLoading
            ))
        }
    }
}
