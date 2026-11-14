import Foundation

@main
struct AIEndpointFixtures {
    static func main() {
        let accepted: [(String, String)] = [
            ("https://example.com/v1", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/chat/completions/", "https://example.com/v1/chat/completions"),
            (" https://example.com/ \n", "https://example.com/chat/completions"),
        ]
        for (input, output) in accepted {
            precondition(AIWritingService.endpoint(input)?.absoluteString == output)
        }
        for input in ["", "http://example.com/v1", "file:///tmp/x", "https://user:password@example.com/v1",
                      "https://example.com/v1?key=test", "https://example.com/v1#key", "not a url"] {
            precondition(AIWritingService.endpoint(input) == nil)
        }
        try! streamFixtures()
        print("AI fixtures: 12 endpoint and 7 SSE boundary cases passed without network requests.")
    }

    static func streamFixtures() throws {
        func delta(_ text: String, finish: String? = nil) throws -> String {
            var choice: [String: Any] = ["delta": ["content": text]]
            if let finish = finish { choice["finish_reason"] = finish }
            return "data: " + String(data: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
        }
        var valid = AIStreamAccumulator()
        try valid.consume(line: delta("中文 🌷 "))
        try valid.consume(line: "")
        try valid.consume(line: delta("正文"))
        try valid.consume(line: "")
        try valid.consume(line: "data: [DONE]")
        let validResult = try valid.finish()
        precondition(validResult == "中文 🌷 正文")
        var stopped = AIStreamAccumulator()
        try stopped.consume(line: delta("完整", finish: "stop"))
        let stoppedResult = try stopped.finish()
        precondition(stoppedResult == "完整")
        var keepalive = AIStreamAccumulator()
        try keepalive.consume(line: ": heartbeat")
        try keepalive.consume(line: "event: message")
        try keepalive.consume(line: delta("保留空格  ", finish: "stop"))
        let keepaliveResult = try keepalive.finish()
        precondition(keepaliveResult == "保留空格  ")
        func rejects(_ action: () throws -> Void) {
            do { try action(); preconditionFailure("Unsafe SSE accepted") } catch { }
        }
        rejects {
            var partial = AIStreamAccumulator()
            try partial.consume(line: delta("残缺"))
            _ = try partial.finish()
        }
        rejects {
            var invalid = AIStreamAccumulator()
            try invalid.consume(line: "data: not-json")
            try invalid.consume(line: "")
        }
        rejects {
            var truncated = AIStreamAccumulator()
            try truncated.consume(line: delta("截断", finish: "length"))
            _ = try truncated.finish()
        }
        rejects {
            var huge = AIStreamAccumulator()
            try huge.consume(line: String(repeating: "x", count: 2_000_001))
        }
    }
}
