import AppKit
import SwiftUI
import WebKit

/// An offline, read-only preview. `baseDirectory` is ONE article directory, not the vault.
/// Its security-scoped access must remain alive in LBMdStore while this view is visible.
struct ReaderView: NSViewRepresentable {
    enum BodyFormat: String { case markdown, html }
    let markdown: String
    let baseDirectory: URL?
    let bodyFormat: BodyFormat
    /// Split-view live preview: hides the reader chrome, shows `title`, debounces typing.
    var live = false
    var title = ""
    /// 0...1 editor scroll position mirrored into the preview (nil = leave scrolling to the user).
    var scrollFraction: Double?

    init(markdown: String, baseDirectory: URL? = nil, bodyFormat: BodyFormat = .markdown,
         live: Bool = false, title: String = "", scrollFraction: Double? = nil) {
        self.markdown = markdown
        self.baseDirectory = baseDirectory
        self.bodyFormat = bodyFormat
        self.live = live
        self.title = title
        self.scrollFraction = scrollFraction
    }

    init(html: String, baseDirectory: URL? = nil) {
        self.init(markdown: html, baseDirectory: baseDirectory, bodyFormat: .html)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: ReaderResources.scheme)
        // No script message handlers, credentials, cookies, or native command bridge.
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.underPageBackgroundColor = .clear
        context.coordinator.live = live
        context.coordinator.update(markdown: markdown, format: bodyFormat, root: baseDirectory, title: title, in: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.live = live
        context.coordinator.update(markdown: markdown, format: bodyFormat, root: baseDirectory, title: title, in: nsView)
        if let fraction = scrollFraction { context.coordinator.scroll(to: fraction, in: nsView) }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        coordinator.resources.setArticleRoot(nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let resources = ReaderResources()
        private var currentBody: String?
        private var currentFormat: BodyFormat = .markdown
        private var currentRoot: URL?
        private var ready = false
        private var loading = false
        private var revision = 0
        private var currentTitle = ""
        private var pendingRender: DispatchWorkItem?
        private var lastFraction: Double?
        var live = false

        func scroll(to fraction: Double, in view: WKWebView) {
            guard ready, lastFraction != fraction else { return }
            lastFraction = fraction
            view.callAsyncJavaScript("window.LBMacReader.scrollTo(fraction)", arguments: ["fraction": fraction], in: nil, in: .page) { _ in }
        }

        func update(markdown: String, format: BodyFormat, root: URL?, title: String = "", in view: WKWebView) {
            guard currentBody != markdown || currentFormat != format || currentRoot != root || currentTitle != title else { return }
            let rootChanged = currentRoot != root
            let firstBody = currentBody == nil
            currentTitle = title
            currentBody = markdown
            currentFormat = format
            currentRoot = root
            revision += 1
            resources.setArticleRoot(root)
            // A fresh document drops old image caches and pending diagram work on root changes.
            if !loading || rootChanged {
                ready = false
                loading = true
                view.load(URLRequest(url: ReaderResources.documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
            } else if ready {
                pendingRender?.cancel()
                // Live typing: coalesce keystrokes so KaTeX / Mermaid are not rebuilt per character.
                guard live, !firstBody else { render(in: view); return }
                let work = DispatchWorkItem { [weak self, weak view] in if let self = self, let view = view { self.render(in: view) } }
                pendingRender = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }

        private func render(in view: WKWebView) {
            guard ready, let body = currentBody else { return }
            let payload: [String: Any] = ["body": body, "bodyFormat": currentFormat.rawValue,
                                           "hasRoot": resources.hasArticleRoot, "revision": revision,
                                           "resourceBase": resources.articleBaseURL.absoluteString,
                                           "compact": live, "title": currentTitle]
            // Structured arguments preserve quotes, Unicode and </script>; no source interpolation.
            view.callAsyncJavaScript("return await window.LBMacReader.render(payload)",
                                     arguments: ["payload": payload], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.scheme == ReaderResources.scheme,
                  webView.url?.host == "app", webView.url?.path == "/MacReader/index.html" else { return }
            ready = true
            render(in: webView)
            if let fraction = lastFraction { lastFraction = nil; scroll(to: fraction, in: webView) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.load(URLRequest(url: ReaderResources.documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            // Exactly one app document; no file://, arbitrary custom schemes or article navigation.
            if url.scheme == ReaderResources.scheme, url.host == "app",
               url.path == "/MacReader/index.html", url.user == nil, url.password == nil,
               url.port == nil, url.query == nil, action.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
                return
            }
            // WebKit never requests the external URL: only a real user link activation hands off.
            if action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
               url.scheme?.lowercased() == "https", url.host != nil,
               url.user == nil, url.password == nil, url.port == nil || url.port == 443 {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let url = response.response.url
            decisionHandler(response.isForMainFrame && url?.scheme == ReaderResources.scheme &&
                            url?.host == "app" && url?.path == "/MacReader/index.html" ? .allow : .cancel)
        }

        // Suppress script-created windows; target=_blank user links are handled above.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    }
}
