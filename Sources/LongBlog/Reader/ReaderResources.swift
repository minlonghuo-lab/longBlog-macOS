import Foundation
import WebKit
import Darwin

/// Capability-like, read-only transport. Never use loadFileURL or give WebKit a vault URL.
/// Calls run synchronously on WebKit's main-thread scheme-handler callbacks; stop has no queued work.
final class ReaderResources: NSObject, WKURLSchemeHandler {
    static let scheme = "lbmac-resource"
    static let documentURL = URL(string: "lbmac-resource://app/MacReader/index.html")!
    private let bundleRoot: URL? = Bundle.main.resourceURL
    private var rootDescriptor: Int32 = -1
    private var articleRoot: URL?
    private var articleHost = "article-" + UUID().uuidString.lowercased()
    var hasArticleRoot: Bool { rootDescriptor >= 0 }
    var articleBaseURL: URL { URL(string: "\(Self.scheme)://\(articleHost)/")! }

    private static let bundleFiles: [String: String] = [
        "MacReader/index.html": "text/html", "MacReader/reader.css": "text/css",
        "MacReader/reader.js": "text/javascript", "Reader/reader-mermaid.js": "text/javascript",
        "Reader/vendor/marked.umd.js": "text/javascript", "Reader/vendor/katex.min.js": "text/javascript",
        "Reader/vendor/mermaid.min.js": "text/javascript", "Reader/vendor/katex.min.css": "text/css"
    ]
    private static let imageMIMEs = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                     "gif": "image/gif", "webp": "image/webp"]

    deinit { if rootDescriptor >= 0 { Darwin.close(rootDescriptor) } }

    func setArticleRoot(_ root: URL?) {
        if articleRoot == root, rootDescriptor >= 0 { return }
        if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
        rootDescriptor = -1
        articleRoot = root
        articleHost = "article-" + UUID().uuidString.lowercased()
        guard let root = root, root.isFileURL,
              let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        // Resolve only trusted system ancestors, never resolve the article leaf itself:
        // swapping the leaf for a symlink between resourceValues and open must fail closed.
        let leaf = root.standardizedFileURL
        guard leaf.lastPathComponent != "/", !leaf.lastPathComponent.isEmpty else { return }
        let parent = leaf.deletingLastPathComponent().resolvingSymlinksInPath()
        let directory = Self.openPinnedDirectory(parent)
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        rootDescriptor = Darwin.openat(directory, leaf.lastPathComponent,
                                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    private static func openPinnedDirectory(_ directory: URL) -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in directory.pathComponents.dropFirst() {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func pathParts(_ url: URL) -> [String]? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == scheme, c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil else { return nil }
        let encoded = c.percentEncodedPath
        guard encoded.hasPrefix("/"), encoded.utf8.count < 4096 else { return nil }
        let raw = encoded.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !raw.isEmpty, raw.count <= 24 else { return nil }
        var parts: [String] = []
        for item in raw {
            guard let part = String(item).removingPercentEncoding, !part.isEmpty,
                  part != ".", part != "..", part.utf8.count <= 255,
                  !part.contains("/"), !part.contains("\\"), !part.contains("%"),
                  !part.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            parts.append(part)
        }
        return parts
    }

    private static func bundleMIME(_ path: String) -> String? {
        if let mime = bundleFiles[path] { return mime }
        // KaTeX references only its own bundled font families. No user-controlled CSS or scripts.
        if path.hasPrefix("Reader/vendor/fonts/"), path.split(separator: "/").count == 4,
           path.split(separator: "/").last?.hasPrefix("KaTeX_") == true {
            switch (path as NSString).pathExtension.lowercased() {
            case "woff2": return "font/woff2"
            case "woff": return "font/woff"
            case "ttf": return "font/ttf"
            default: return nil
            }
        }
        return nil
    }

    private static func read(root: Int32, parts: [String], limit: Int) throws -> Data {
        guard root >= 0 else { throw URLError(.noPermissionsToReadFile) }
        var directory = Darwin.dup(root)
        guard directory >= 0 else { throw URLError(.cannotOpenFile) }
        defer { Darwin.close(directory) }
        for component in parts.dropLast() {
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw URLError(.noPermissionsToReadFile) }
            Darwin.close(directory)
            directory = next
        }
        guard let name = parts.last else { throw URLError(.badURL) }
        // O_NONBLOCK avoids hanging on a FIFO/device before fstat rejects it.
        let file = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw URLError(.fileDoesNotExist) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard Darwin.fstat(file, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0, status.st_size <= Int64(limit) else {
            throw URLError(.noPermissionsToReadFile)
        }
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    private static func validImage(_ data: Data, mime: String) -> Bool {
        let head = Array(data.prefix(12))
        switch mime {
        case "image/png": return head.starts(with: [137,80,78,71,13,10,26,10])
        case "image/jpeg": return head.starts(with: [255,216,255])
        case "image/gif": return head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8))
        case "image/webp": return head.count == 12 && Array(head[0..<4]) == Array("RIFF".utf8) && Array(head[8..<12]) == Array("WEBP".utf8)
        default: return false
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard task.request.httpMethod == "GET", let url = task.request.url,
                  let parts = Self.pathParts(url) else { throw URLError(.badURL) }
            let path = parts.joined(separator: "/")
            let data: Data
            let mime: String
            if url.host == "app" {
                guard let root = bundleRoot, let type = Self.bundleMIME(path) else { throw URLError(.noPermissionsToReadFile) }
                let directory = Darwin.open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                defer { if directory >= 0 { Darwin.close(directory) } }
                data = try Self.read(root: directory, parts: parts, limit: 12 * 1024 * 1024)
                mime = type
            } else if url.host == articleHost {
                guard let type = Self.imageMIMEs[(path as NSString).pathExtension.lowercased()] else { throw URLError(.noPermissionsToReadFile) }
                data = try Self.read(root: rootDescriptor, parts: parts, limit: 24 * 1024 * 1024)
                guard Self.validImage(data, mime: type) else { throw URLError(.cannotDecodeContentData) }
                mime = type
            } else { throw URLError(.noPermissionsToReadFile) }
            var headers = ["Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
                           "Content-Length": String(data.count), "Cache-Control": "no-store",
                           "X-Content-Type-Options": "nosniff"]
            // Custom-scheme font origins can be opaque in WebKit. Public bundled fonts may
            // be read anonymously; article resources deliberately get no CORS grant.
            if url.host == "app", mime.hasPrefix("font/") { headers["Access-Control-Allow-Origin"] = "*" }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else { throw URLError(.badServerResponse) }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(URLError(.noPermissionsToReadFile)) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // No asynchronous callbacks or retained tasks. All start work has already completed.
    }
}
