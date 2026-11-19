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
    /// "auto" (follows window appearance), "paper" (warm cream paper), or "dark" (warm espresso).
    var paperTheme = "auto"

    init(markdown: String, baseDirectory: URL? = nil, bodyFormat: BodyFormat = .markdown,
         live: Bool = false, title: String = "", scrollFraction: Double? = nil, paperTheme: String = "auto") {
        self.markdown = markdown
        self.baseDirectory = baseDirectory
        self.bodyFormat = bodyFormat
        self.live = live
        self.title = title
        self.scrollFraction = scrollFraction
        self.paperTheme = paperTheme
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
        // Synchronously stamp the initial theme before first paint so dark/light never flashes on cold load.
        let initialTheme = (paperTheme == "paper" || paperTheme == "dark") ? paperTheme : "auto"
        let themeScript = WKUserScript(
            source: "document.documentElement.setAttribute('data-theme', '\(initialTheme)');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(themeScript)
        // No script message handlers, credentials, cookies, or native command bridge.
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.focusRingType = .none
        view.underPageBackgroundColor = Self.background(for: paperTheme)
        context.coordinator.live = live
        context.coordinator.update(markdown: markdown, format: bodyFormat, root: baseDirectory, title: title, theme: paperTheme, in: view)
        return view
    }

    private static let paper = NSColor(srgbRed: 246/255, green: 239/255, blue: 230/255, alpha: 1)
    private static let espresso = NSColor(srgbRed: 37/255, green: 30/255, blue: 26/255, alpha: 1)
    private static let automaticBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? espresso : paper
    }
    private static func background(for theme: String) -> NSColor {
        switch theme { case "dark": return espresso; case "paper": return paper; default: return automaticBackground }
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let background = Self.background(for: paperTheme)
        if nsView.underPageBackgroundColor != background { nsView.underPageBackgroundColor = background }
        context.coordinator.live = live
        context.coordinator.update(markdown: markdown, format: bodyFormat, root: baseDirectory, title: title, theme: paperTheme, in: nsView)
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
        private var documentNavigation: WKNavigation?
        private var revision = 0
        private var currentTitle = ""
        private var currentTheme = "auto"
        private var pendingRender: DispatchWorkItem?
        private var lastFraction: Double?
        var live = false

        func scroll(to fraction: Double, in view: WKWebView) {
            guard ready else { lastFraction = fraction; return }
            guard lastFraction != fraction else { return }
            lastFraction = fraction
            view.callAsyncJavaScript("window.LBMacReader.scrollTo(fraction)", arguments: ["fraction": fraction], in: nil, in: .page) { _ in }
        }

        func update(markdown: String, format: BodyFormat, root: URL?, title: String = "", theme: String = "auto", in view: WKWebView) {
            guard currentBody != markdown || currentFormat != format || currentRoot != root || currentTitle != title || currentTheme != theme || (!ready && documentNavigation == nil) else { return }
            let rootChanged = currentRoot != root
            if rootChanged { lastFraction = nil }
            let bodyChanged = currentBody != markdown
            let firstBody = currentBody == nil
            currentTitle = title
            currentTheme = theme
            currentBody = markdown
            currentFormat = format
            currentRoot = root
            revision += 1
            resources.setArticleRoot(root)
            // The scheme handler rotates the resource host for every article.
            // Keep the document alive and swap the sanitized body in one paint.
            if !ready && documentNavigation == nil {
                pendingRender?.cancel()
                ready = false
                documentNavigation = view.load(URLRequest(url: ReaderResources.documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
            } else if ready {
                pendingRender?.cancel()
                // Live typing: coalesce keystrokes so KaTeX / Mermaid are not rebuilt per character.
                // Theme or title switches render immediately without debounce delay.
                guard live, !rootChanged, !firstBody, bodyChanged else { render(in: view); return }
                let work = DispatchWorkItem { [weak self, weak view] in if let self = self, let view = view { self.render(in: view) } }
                pendingRender = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }

        private func render(in view: WKWebView) {
            guard ready, let body = currentBody else { return }
            let payload: [String: Any] = ["body": body, "bodyFormat": currentFormat.rawValue,
                                           "hasRoot": resources.hasArticleRoot, "revision": revision,
                                           "resourceBase": resources.articleBaseURL.absoluteString,
                                           "compact": live, "title": currentTitle, "theme": currentTheme]
            // Structured arguments preserve quotes, Unicode and </script>; no source interpolation.
            view.callAsyncJavaScript("return await window.LBMacReader.render(payload)",
                                     arguments: ["payload": payload], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, navigation === documentNavigation, webView.url?.scheme == ReaderResources.scheme,
                  webView.url?.host == "app", webView.url?.path == "/MacReader/index.html" else { return }
            documentNavigation = nil
            ready = true
            render(in: webView)
            if let fraction = lastFraction { lastFraction = nil; scroll(to: fraction, in: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === documentNavigation { documentNavigation = nil }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === documentNavigation { documentNavigation = nil }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            pendingRender?.cancel()
            documentNavigation = webView.load(URLRequest(url: ReaderResources.documentURL, cachePolicy: .reloadIgnoringLocalCacheData))
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
