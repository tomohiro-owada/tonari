import Foundation

enum OllamaChunk: Sendable {
    case thinking(String)
    case answer(String)
    case toolCall(name: String, argumentsJSON: String)
}

struct OllamaTool: Sendable {
    let name: String
    let description: String
    /// JSON schema for function parameters, as raw JSON string (object).
    let parametersJSON: String
}

struct ChatTurn: Sendable {
    let role: String  // "user" | "assistant" | "tool" | "system"
    let content: String
    var images: [Data] = []
    /// Only set when role == "tool".
    var toolName: String? = nil
}

struct OllamaClient {
    let baseURL = URL(string: "http://localhost:11434")!

    private struct TagsResponse: Decodable {
        struct ModelInfo: Decodable { let name: String }
        let models: [ModelInfo]
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("/api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { $0.name }.sorted()
    }

    /// One-shot, non-streaming chat call. Useful for background tasks that
    /// don't need to render token-by-token (e.g. periodic presence checks).
    func oneShot(
        model: String,
        prompt: String,
        image: Data? = nil,
        timeout: TimeInterval = 120
    ) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        var userMsg: [String: Any] = ["role": "user", "content": prompt]
        if let image {
            userMsg["images"] = [image.base64EncodedString()]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [userMsg],
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(
                domain: "OllamaClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama HTTP \(http.statusCode)"]
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        return (message?["content"] as? String) ?? ""
    }

    private struct ChatChunk: Decodable {
        struct Msg: Decodable {
            let content: String?
            let thinking: String?
        }
        let message: Msg?
        let done: Bool
    }

    func chat(
        model: String,
        messages: [ChatTurn],
        tools: [OllamaTool] = [],
        think: Bool
    ) -> AsyncThrowingStream<OllamaChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("/api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600

                    var processed = messages
                    if !think, let lastIdx = processed.indices.last, processed[lastIdx].role == "user" {
                        processed[lastIdx].images = processed[lastIdx].images  // keep
                        processed[lastIdx] = ChatTurn(
                            role: "user",
                            content: processed[lastIdx].content + " /no_think",
                            images: processed[lastIdx].images,
                            toolName: nil
                        )
                    }

                    let msgArray: [[String: Any]] = processed.map { m in
                        var d: [String: Any] = ["role": m.role, "content": m.content]
                        if !m.images.isEmpty {
                            d["images"] = m.images.map { $0.base64EncodedString() }
                        }
                        if let toolName = m.toolName {
                            d["tool_name"] = toolName
                        }
                        return d
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "messages": msgArray,
                        "stream": true
                    ]
                    if think { body["think"] = true }
                    if !tools.isEmpty {
                        body["tools"] = tools.map { tool -> [String: Any] in
                            let params = (try? JSONSerialization.jsonObject(
                                with: Data(tool.parametersJSON.utf8)
                            )) ?? [:]
                            return [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": params
                                ]
                            ]
                        }
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(
                            domain: "OllamaClient",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "Ollama API HTTP \(http.statusCode)"]
                        )
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8) else { continue }
                        // Typed decode for known fields
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                        if let t = chunk.message?.thinking, !t.isEmpty {
                            continuation.yield(.thinking(t))
                        }
                        if let c = chunk.message?.content, !c.isEmpty {
                            continuation.yield(.answer(c))
                        }
                        // Tool calls — parsed from raw JSON since the args shape is dynamic
                        if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let message = raw["message"] as? [String: Any],
                           let toolCalls = message["tool_calls"] as? [[String: Any]] {
                            for call in toolCalls {
                                guard let fn = call["function"] as? [String: Any],
                                      let name = fn["name"] as? String else { continue }
                                let args = fn["arguments"] ?? [String: Any]()
                                let argsData = (try? JSONSerialization.data(withJSONObject: args))
                                    ?? Data("{}".utf8)
                                let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                                continuation.yield(.toolCall(name: name, argumentsJSON: argsJSON))
                            }
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
