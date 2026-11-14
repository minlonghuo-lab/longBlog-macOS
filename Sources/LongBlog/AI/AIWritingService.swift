import Foundation

// Never forward an API key to a redirect target, even if it shares the host.
private final class AINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AIRequestError: LocalizedError {
    case invalidConfiguration, tooLarge, http(Int), invalidResponse, incomplete, truncated
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请填写有效的 HTTPS 接口地址、模型和 API Key（地址不得含用户名、密码、查询参数或片段）。"
        case .tooLarge: return "请求或响应超过安全上限，请缩短正文后重试。"
        case .http(let status): return "AI 接口返回 HTTP \(status)；请求没有自动重试。请检查接口与权限。"
        case .invalidResponse: return "AI 接口返回了无法识别的响应。"
        case .incomplete: return "连接提前结束，未收到完整结果。为避免误用残缺内容，本次不能应用。"
        case .truncated: return "模型输出达到上限或被过滤，本次不能应用，请缩短输入后重试。"
        }
    }
}

actor AIWritingService {
    static func endpoint(_ base: String) -> URL? {
        guard var c = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url else { return nil }
        return url.path.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }

    func generate(base: String, model: String, key: String, prompt: String,
                  onUpdate: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        guard let url = Self.endpoint(base), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.isEmpty else { throw AIRequestError.invalidConfiguration }
        guard prompt.utf8.count <= 1_000_000 else { throw AIRequestError.tooLarge }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true,
            "messages": [
                ["role": "system", "content": "你是中文写作助手。忠实保留事实、链接、代码和 Markdown 结构，不编造资料。仅输出请求的正文，不添加解释或代码围栏。"],
                ["role": "user", "content": prompt]
            ]
        ])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: AINoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIRequestError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIRequestError.http(http.statusCode) }
        if response.expectedContentLength > 2_000_000 { throw AIRequestError.tooLarge }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("application/json") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count > 2_000_000 { throw AIRequestError.tooLarge }
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (root["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any],
                  let output = message["content"] as? String, !output.isEmpty else {
                throw AIRequestError.invalidResponse
            }
            if let finish = choice["finish_reason"] as? String, finish != "stop" { throw AIRequestError.truncated }
            await onUpdate(output)
            return output
        }
        guard type.contains("text/event-stream") else { throw AIRequestError.invalidResponse }
        var stream = AIStreamAccumulator()
        var lastUpdate = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try stream.consume(line: line)
            if line.isEmpty && Date().timeIntervalSince(lastUpdate) >= 0.05 {
                await onUpdate(stream.output)
                lastUpdate = Date()
            }
            if stream.done { break }
        }
        let output = try stream.finish()
        await onUpdate(output)
        return output
    }
}

/// Bounded OpenAI-compatible SSE state. Shared by the real request and native fixtures.
struct AIStreamAccumulator {
    private(set) var output = ""
    private(set) var done = false
    private var stopped = false
    private var frame: [String] = []
    private var wireBytes = 0, outputBytes = 0

    mutating func consume(line: String) throws {
        wireBytes += line.utf8.count + 1
        guard wireBytes <= 2_000_000 else { throw AIRequestError.tooLarge }
        if line.isEmpty { try flush() }
        else if line.hasPrefix("data:") {
            var data = String(line.dropFirst(5))
            if data.first == " " { data.removeFirst() }
            frame.append(data)
        }
    }

    mutating func finish() throws -> String {
        try flush()
        guard done || stopped else { throw AIRequestError.incomplete }
        guard !output.isEmpty else { throw AIRequestError.invalidResponse }
        return output
    }

    private mutating func flush() throws {
        guard !frame.isEmpty else { return }
        let payload = frame.joined(separator: "\n")
        frame.removeAll(keepingCapacity: true)
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { done = true; return }
        guard let data = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil else { throw AIRequestError.invalidResponse }
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String {
            outputBytes += text.utf8.count
            guard outputBytes <= 1_000_000 else { throw AIRequestError.tooLarge }
            output += text
        }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else { throw AIRequestError.truncated }
            stopped = true
        }
    }
}
