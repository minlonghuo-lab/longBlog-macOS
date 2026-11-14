import AppKit
import SwiftUI
import WebKit
import Darwin

// Standalone integration executable, never included in the shipping target.
// Compile together with Sources/LongBlog/Reader/*.swift inside ReaderSmoke.app.
@main
struct ReaderSmokeMain {
    static func main() {
        var screenshot: URL?
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--screenshot" else {
                print("READER_SMOKE {\"passed\":false,\"failure\":\"usage\"}")
                Darwin.exit(2)
            }
            screenshot = URL(fileURLWithPath: arguments[1])
        }
        // A separate watchdog also bounds a stuck main queue / WebKit callback.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            let message = "READER_SMOKE {\"passed\":false,\"failure\":\"hard_timeout\"}\n"
            message.withCString { pointer in _ = Darwin.write(STDOUT_FILENO, pointer, strlen(pointer)) }
            Darwin._exit(1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let runner = ReaderSmokeRunner(screenshot: screenshot)
        withExtendedLifetime(runner) {
            runner.start()
            application.run()
        }
    }
}

/// Observe the REAL production delegate's decision without letting even a regression
/// send the probe to the network. Only the artificial HTTPS navigation is forced-cancelled.
/// All normal document decisions and callbacks are forwarded to the original coordinator.
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    let original: WKNavigationDelegate
    var remoteActions = 0
    var remoteDecisions = 0
    var productionDeniedAll = true
    var onlyScriptNavigation = true
    var forwardingFailed = false
    var processTerminated = false

    init(original: WKNavigationDelegate) { self.original = original }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isNetwork = ["http", "https"].contains(action.request.url?.scheme?.lowercased() ?? "")
        if isNetwork {
            remoteActions += 1
            onlyScriptNavigation = onlyScriptNavigation && action.navigationType != .linkActivated
        }
        let invoked: Void? = original.webView?(webView, decidePolicyFor: action, decisionHandler: { [weak self] policy in
            if isNetwork {
                self?.remoteDecisions += 1
                self?.productionDeniedAll = (self?.productionDeniedAll ?? false) && policy == .cancel
                // Safety net: record an unexpected allow as a test failure, but never transmit it.
                decisionHandler(.cancel)
            } else { decisionHandler(policy) }
        })
        if case .none = invoked {
            forwardingFailed = true
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let invoked: Void? = original.webView?(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
        if case .none = invoked { forwardingFailed = true; decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        original.webView?(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        original.webView?(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        original.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processTerminated = true
        original.webViewWebContentProcessDidTerminate?(webView)
    }
}

private final class ReaderSmokeRunner {
    private let screenshot: URL?
    private var scratch: URL?
    private var window: NSWindow?
    private weak var webView: WKWebView?
    private var probe: NavigationProbe?
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var polling = false
    private var navigationDispatched = false
    private var finishing = false
    private var assertions: [String: Bool] = [:]

    init(screenshot: URL?) { self.screenshot = screenshot }

    func start() {
        do {
            let manager = FileManager.default
            let scratch = manager.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("LongBlogReaderSmoke-" + UUID().uuidString, isDirectory: true)
            self.scratch = scratch
            let article = scratch.appendingPathComponent("article", isDirectory: true)
            let assets = article.appendingPathComponent("assets", isDirectory: true)
            try manager.createDirectory(at: assets, withIntermediateDirectories: true)
            let png = try Self.makePNG()
            try png.write(to: assets.appendingPathComponent("pixel.png"), options: .atomic)
            let outside = scratch.appendingPathComponent("outside.png")
            try png.write(to: outside, options: .atomic)
            try manager.createSymbolicLink(at: assets.appendingPathComponent("escape.png"), withDestinationURL: outside)
            // Do not write private notes or read any production stores / credentials.
            let host = NSHostingView(rootView: ReaderView(markdown: Self.fixture, baseDirectory: article))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 880),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "LongBlog native reader smoke"
            window.isReleasedWhenClosed = false
            window.contentView = host
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            host.layoutSubtreeIfNeeded()
            started = Date()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
        } catch { finish(false, reason: "fixture_or_window_setup_failed") }
    }

    private static func makePNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 8, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData else { throw SmokeError.png }
        for index in 0..<16 { bytes[index] = index % 4 == 3 ? 255 : 170 }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.png }
        return data
    }

    private static func locateWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = locateWebView(child) { return web } }
        return nil
    }

    private func poll() {
        guard !finishing else { return }
        if Date().timeIntervalSince(started) >= 28 { finish(false, reason: "assertions_timeout"); return }
        guard !polling, let content = window?.contentView,
              let web = webView ?? Self.locateWebView(content) else { return }
        webView = web
        polling = true
        web.callAsyncJavaScript(Self.inspect, arguments: [:], in: nil, in: .page) { [weak self, weak web] result in
            guard let self = self, !self.finishing, let web = web else { return }
            self.polling = false
            guard case .success(let value) = result, let checks = value as? [String: Any] else { return }
            for key in Self.checkKeys { self.assertions[key] = (checks[key] as? NSNumber)?.boolValue ?? false }
            let url = web.url
            self.assertions["nativeAppDocument"] = url?.scheme == "lbmac-resource" &&
                url?.host == "app" && url?.path == "/MacReader/index.html"
            let initialPass = Self.checkKeys.allSatisfy { self.assertions[$0] == true } &&
                self.assertions["nativeAppDocument"] == true
            guard initialPass else { return }
            if !self.navigationDispatched {
                guard let original = web.navigationDelegate else { self.finish(false, reason: "missing_production_delegate"); return }
                let probe = NavigationProbe(original: original)
                self.probe = probe
                web.navigationDelegate = probe
                self.navigationDispatched = true
                // This is .other, NOT a user link: the real coordinator must cancel it.
                web.callAsyncJavaScript("window.location.assign(target); return true;",
                                        arguments: ["target": "https://reader-smoke.invalid/blocked"],
                                        in: nil, in: .page) { _ in }
                return
            }
            guard let probe = self.probe, probe.remoteActions > 0,
                  probe.remoteDecisions == probe.remoteActions else { return }
            self.assertions["networkNavigationObserved"] = probe.remoteActions == 1
            self.assertions["productionCancelledNetwork"] = probe.productionDeniedAll
            self.assertions["noUserBrowserHandoff"] = probe.onlyScriptNavigation
            self.assertions["delegateForwarding"] = !probe.forwardingFailed
            self.assertions["contentProcessAlive"] = !probe.processTerminated
            let passed = self.assertions.values.allSatisfy { $0 }
            self.finish(passed, reason: passed ? "ok" : "native_navigation_policy_failed")
        }
    }

    private func finish(_ passed: Bool, reason: String) {
        guard !finishing else { return }
        finishing = true
        timer?.cancel()
        timer = nil
        guard passed, let destination = screenshot, let web = webView else {
            complete(passed, reason: reason, screenshotWritten: false)
            return
        }
        // Snapshot only this owned WKWebView; no screen-recording permission / private APIs.
        web.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self = self else { return }
            do {
                guard let image = image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.png }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: destination, options: .atomic)
                self.complete(true, reason: reason, screenshotWritten: true)
            } catch { self.complete(false, reason: "snapshot_failed", screenshotWritten: false) }
        }
    }

    private func complete(_ passed: Bool, reason: String, screenshotWritten: Bool) {
        webView?.stopLoading()
        if let original = probe?.original { webView?.navigationDelegate = original }
        window?.contentView = nil
        window?.close()
        if let scratch = scratch { try? FileManager.default.removeItem(at: scratch) }
        // Output only booleans and controlled tokens, never URLs, paths, HTML, errors or notes.
        let report: [String: Any] = ["passed": passed, "failure": reason, "assertions": assertions,
                                     "screenshotRequested": screenshot != nil, "screenshotWritten": screenshotWritten]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("READER_SMOKE " + json) }
        else { print("READER_SMOKE {\"passed\":false,\"failure\":\"report_failed\"}") }
        fflush(stdout)
        Darwin.exit(passed ? 0 : 1)
    }

    private enum SmokeError: Error { case png }

    private static let checkKeys = [
        "rendererPresent", "table", "math", "katexFontLoaded", "mermaidImage", "diagramSource",
        "tail", "localPNG", "symlinkDenied", "noAuthorScripts", "noAuthorEvents",
        "noForbiddenNodes", "noRemoteImages", "noRemoteResources", "renderComplete"
    ]

    private static let inspect = #"""
    const c = document.getElementById('content');
    if (!c) return {};
    const images = Array.from(c.querySelectorAll('img'));
    const local = images.find(image => image.alt === 'local-png');
    const escape = images.find(image => image.alt === 'symlink-escape');
    const diagram = c.querySelector('img.mermaid-image');
    const status = document.getElementById('reader-status');
    const fonts = document.fonts ? Array.from(document.fonts) : [];
    return {
      rendererPresent: !!(window.LBMacReader && typeof window.LBMacReader.render === 'function'),
      table: c.querySelectorAll('table').length === 1 && c.querySelectorAll('tbody tr').length === 2,
      math: c.querySelectorAll('.katex').length === 1,
      katexFontLoaded: fonts.some(font => /KaTeX/.test(font.family) && font.status === 'loaded'),
      mermaidImage: !!diagram && diagram.complete && diagram.naturalWidth > 0 && diagram.src.startsWith('data:image/svg+xml'),
      diagramSource: !!c.querySelector('details pre code.language-mermaid'),
      tail: c.textContent.includes('READER_SMOKE_TAIL_7F1'),
      localPNG: !!local && local.complete && local.naturalWidth === 2 &&
                /^lbmac-resource:\/\/article-[a-f0-9-]+\/assets\/pixel\.png$/.test(local.src),
      symlinkDenied: !escape && c.textContent.includes('本地图片不可用：symlink-escape'),
      noAuthorScripts: !window.__readerSmokeAttack,
      noAuthorEvents: Array.from(c.querySelectorAll('*')).every(element =>
                      Array.from(element.attributes).every(attribute => !/^on/i.test(attribute.name))),
      noForbiddenNodes: !c.querySelector('script,iframe,object,embed,svg,foreignObject,audio,video,source'),
      noRemoteImages: images.every(image => !/^https?:/i.test(image.src)),
      noRemoteResources: performance.getEntriesByType('resource').every(entry => !/^https?:/i.test(entry.name)),
      renderComplete: !!status && status.hidden && !c.querySelector('.mermaid-status') &&
                      (!document.fonts || document.fonts.status === 'loaded')
    };
    """#

    private static let fixture = #"""
    # Native WebKit custom-scheme smoke

    | Feature | Expected |
    | --- | --- |
    | Transport | lbmac-resource |
    | Rendering | Offline |

    Mathematics: $x_1 < y$.

    ![local-png](/assets/smoke-note/pixel.png)

    ![symlink-escape](./assets/escape.png)

    ```mermaid
    flowchart TD
      A[Offline] --> B[Native WebKit]
    ```

    ```swift
    let localOnly = true
    ```

    <script>window.__readerSmokeAttack = 99</script>

    <img src="https://reader-smoke.invalid/remote.png" onerror="window.__readerSmokeAttack=98" alt="remote-author-image">

    <svg><foreignObject><iframe src="https://reader-smoke.invalid/frame"></iframe></foreignObject></svg>

    <video autoplay src="https://reader-smoke.invalid/remote.mp4"></video>

    <div style="background-image:url(https://reader-smoke.invalid/css.png)" onclick="window.__readerSmokeAttack=97">Untrusted author attributes</div>

    <a href="javascript:window.__readerSmokeAttack=96">Disabled author link</a>

    READER_SMOKE_TAIL_7F1
    """#
}
