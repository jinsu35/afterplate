import Foundation

/// Claude as the app's brain, on the person's own Anthropic API key
/// (to try it next to ChatGPT and Grok). Every call the app makes
/// is an OpenAI Responses body; it is rewritten here for the Messages API and
/// the answer folded back into the Responses shape, so the callers' parsing
/// and the ledger do not change.
///
/// - `instructions` and system/developer turns become `system`.
/// - input_text/input_image become text/image blocks.
/// - A JSON schema becomes `output_config.format`; refused, the schema is put
///   in the system prompt instead and the JSON is cut out of the answer.
/// - `web_search` becomes Anthropic's server-side web search.
/// - `tool_choice: required` becomes a line asking to search first.
///
/// Paid per call. Work nobody asked for yet (the feed's preparation) stops
/// once it has spent `prepBudget` in this run of the app.
enum ClaudeAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-sonnet-5-5"
    /// The most the background preparation may spend per launch (a
    /// $1 cap on paid runs).
    static let prepBudget = 1.0
    /// Web searches one call may run. The menu search is being measured at
    /// one against three (accuracy first, then cut).
    @TaskLocal static var searchLimit = 5
    /// A model other than `model` for one call, for trials (Haiku on the menu
    /// search).
    @TaskLocal static var modelOverride: String?
    nonisolated(unsafe) private(set) static var prepSpent = 0.0
    /// Anthropic refused for want of credit.
    nonisolated(unsafe) static var creditOut = false

    nonisolated static var key: String? {
        let key = Keys.get(.anthropic) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// (Responses-shaped body, HTTP status), as `OpenAITransport.post`.
    static func post(_ original: [String: Any], timeout: TimeInterval, tag: String) async -> (Data, Int)? {
        guard let key else { return nil }
        if OpenAITransport.planOnly, prepSpent >= prepBudget {
            print("[\(tag)] Claude: preparation budget spent ($\(prepSpent))")
            OpenAITransport.planLimitedAt = Date()
            return (Data(), 429)
        }
        var body = messagesBody(original)
        var schemaInPrompt = false
        var result = await send(body, key: key, timeout: timeout, tag: tag)
        // A schema the structured output refuses: ask for it in words.
        if let (data, status) = result, status == 400, body["output_config"] != nil,
           let schema = schema(of: original) {
            print("[\(tag)] Claude refused the schema (\(String(data: data, encoding: .utf8)?.prefix(200) ?? "")); asking in the prompt")
            body["output_config"] = nil
            let ask = "Answer with only one JSON object, no prose and no code fence, matching this JSON schema:\n"
                + (String(data: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}")
            body["system"] = [(body["system"] as? String), ask].compactMap { $0 }.joined(separator: "\n\n")
            schemaInPrompt = true
            result = await send(body, key: key, timeout: timeout, tag: tag)
        }
        guard let (data, status) = result else { return nil }
        // The month's credit is spent: Anthropic stops the calls until the
        // next one arrives (no card is charged); the preparation stops too.
        if status == 400, String(data: data, encoding: .utf8)?.contains("credit balance") == true {
            print("[\(tag)] Claude: no API credit left")
            creditOut = true
            return (data, 429)
        }
        guard status == 200, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[\(tag)] Claude HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return (data, status == 529 ? 503 : status)
        }
        creditOut = false
        let (folded, cost) = responses(from: root, jsonOnly: schemaInPrompt)
        if OpenAITransport.planOnly { prepSpent += cost }
        return ((try? JSONSerialization.data(withJSONObject: folded)) ?? data, 200)
    }

    /// One request, continuing a turn the API paused mid-search.
    private static func send(_ body: [String: Any], key: String, timeout: TimeInterval, tag: String) async -> (Data, Int)? {
        var body = body
        var content: [[String: Any]] = []
        var usage: [String: Int] = [:]
        var searches = 0
        for _ in 0..<4 {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout
            var answer = try? await URLSession.shared.data(for: request)
            // Overloaded or rate-limited in a burst: once more, a moment later.
            if let status = (answer?.1 as? HTTPURLResponse)?.statusCode, status == 429 || status == 529 {
                try? await Task.sleep(for: .seconds(3 + Double.random(in: 0...2)))
                answer = try? await URLSession.shared.data(for: request)
            }
            guard let (data, response) = answer else { return nil }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (data, status)
            }
            let part = root["content"] as? [[String: Any]] ?? []
            content += part
            let u = root["usage"] as? [String: Any] ?? [:]
            for name in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                usage[name, default: 0] += u[name] as? Int ?? 0
            }
            searches += (u["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
            if root["stop_reason"] as? String == "pause_turn" {
                var messages = body["messages"] as? [[String: Any]] ?? []
                messages.append(["role": "assistant", "content": part])
                body["messages"] = messages
                continue
            }
            var whole = root
            whole["content"] = content
            whole["usage"] = usage.merging(["web_search_requests": searches]) { $1 }
            return ((try? JSONSerialization.data(withJSONObject: whole)) ?? data, 200)
        }
        print("[\(tag)] Claude kept pausing")
        return nil
    }

    private static func schema(of body: [String: Any]) -> [String: Any]? {
        guard let format = (body["text"] as? [String: Any])?["format"] as? [String: Any],
              format["type"] as? String == "json_schema" else { return nil }
        return format["schema"] as? [String: Any]
    }

    static func messagesBody(_ body: [String: Any]) -> [String: Any] {
        var system: [String] = []
        if let instructions = body["instructions"] as? String, !instructions.isEmpty { system.append(instructions) }
        var messages: [[String: Any]] = []
        if let text = body["input"] as? String {
            messages.append(["role": "user", "content": text])
        }
        for turn in body["input"] as? [[String: Any]] ?? [] {
            let role = turn["role"] as? String ?? "user"
            let blocks: [[String: Any]]
            if let parts = turn["content"] as? [[String: Any]] {
                blocks = parts.compactMap(block)
            } else {
                blocks = [["type": "text", "text": turn["content"] as? String ?? ""]]
            }
            if role == "system" || role == "developer" {
                system += blocks.compactMap { $0["text"] as? String }
                continue
            }
            let side = role == "assistant" ? "assistant" : "user"
            // Two turns of one side in a row are one message to Claude.
            if let last = messages.last, last["role"] as? String == side, var held = last["content"] as? [[String: Any]] {
                held += blocks
                messages[messages.count - 1]["content"] = held
            } else {
                messages.append(["role": side, "content": blocks])
            }
        }
        var out: [String: Any] = [
            "model": modelOverride ?? model,
            "max_tokens": max(body["max_output_tokens"] as? Int ?? 0, 8000),
            "messages": messages,
        ]
        let tools = body["tools"] as? [[String: Any]] ?? []
        if tools.contains(where: { ($0["type"] as? String ?? "").hasPrefix("web_search") }) {
            out["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": searchLimit]]
            if body["tool_choice"] as? String == "required" {
                system.append("Search the web before you answer.")
            }
        }
        if let schema = schema(of: body) {
            out["output_config"] = ["format": ["type": "json_schema", "schema": supported(schema)]]
        }
        if !system.isEmpty { out["system"] = system.joined(separator: "\n\n") }
        return out
    }

    /// The schema without the limits Claude's structured output refuses
    /// (`maxItems`, `minItems` over 1): every such call was refused and
    /// sent again with the schema in words, paying twice in time. The
    /// prompts say the counts anyway.
    static func supported(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, item) in object {
                if key == "maxItems" { continue }
                if key == "minItems", let n = item as? Int, n > 1 { continue }
                out[key] = supported(item)
            }
            return out
        }
        if let array = value as? [Any] { return array.map(supported) }
        return value
    }

    private static func block(_ part: [String: Any]) -> [String: Any]? {
        switch part["type"] as? String {
        case "input_text", "output_text", "text":
            return ["type": "text", "text": part["text"] as? String ?? ""]
        case "input_image":
            let url = part["image_url"] as? String ?? ""
            if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                let head = url[url.index(url.startIndex, offsetBy: 5)..<comma]
                let media = head.split(separator: ";").first.map(String.init) ?? "image/jpeg"
                return ["type": "image", "source": ["type": "base64", "media_type": media, "data": String(url[url.index(after: comma)...])]]
            }
            return ["type": "image", "source": ["type": "url", "url": url]]
        default:
            return nil
        }
    }

    /// The Messages answer in the Responses shape: one web_search_call item
    /// per search (the ledger counts them), then the text after the last
    /// search as the message. Returns what it cost at list price.
    private static func responses(from root: [String: Any], jsonOnly: Bool) -> ([String: Any], Double) {
        let content = root["content"] as? [[String: Any]] ?? []
        let lastSearch = content.lastIndex { $0["type"] as? String == "web_search_tool_result" } ?? -1
        var text = content.enumerated()
            .filter { $0.offset > lastSearch && $0.element["type"] as? String == "text" }
            .compactMap { $0.element["text"] as? String }
            .joined()
        if jsonOnly, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        let u = root["usage"] as? [String: Any] ?? [:]
        let fresh = u["input_tokens"] as? Int ?? 0
        let read = u["cache_read_input_tokens"] as? Int ?? 0
        let wrote = u["cache_creation_input_tokens"] as? Int ?? 0
        let out = u["output_tokens"] as? Int ?? 0
        let searches = u["web_search_requests"] as? Int ?? 0
        var output: [[String: Any]] = Array(repeating: ["type": "web_search_call", "status": "completed"], count: searches)
        output.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
        let price = Usage.price(model)
        let cost = Double(fresh + wrote) / 1_000_000 * price.input + Double(read) / 1_000_000 * price.input / 10
            + Double(out) / 1_000_000 * price.output + Double(searches) * Usage.claudeSearchCall
        return ([
            "model": root["model"] as? String ?? model,
            "status": "completed",
            "output": output,
            "usage": [
                "input_tokens": fresh + read + wrote,
                "input_tokens_details": ["cached_tokens": read],
                "output_tokens": out,
            ],
        ], cost)
    }
}
