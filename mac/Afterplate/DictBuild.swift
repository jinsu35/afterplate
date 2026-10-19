import Foundation

/// Builds the English (global) dish dictionary from English Wikipedia intros,
/// on the linked subscription. The Korean
/// dictionary stays as it is.
///
/// Asked for by a file, `dict-build.json` in the app's support folder: a list
/// of `{"key", "en", "title", "extract"}`. At launch the app checks each intro
/// is about that dish and, when it is, writes a short English description —
/// what it is, what goes in, how it is made and served, how it tastes; no
/// history, origin or nutrition, as the Korean dictionary was made. Results go
/// to `dict-build-results.json` as they come; the request is removed.
enum DictBuild {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Afterplate", isDirectory: true)
    }

    struct Item: Codable {
        let key: String
        let en: String
        let title: String
        let extract: String
    }

    struct Entry: Codable {
        let key: String
        let en: String
        let title: String
        let about: Bool
        let desc: String
    }

    private struct Answer: Decodable {
        struct Row: Decodable { let n: Int; let about: Bool; let desc: String }
        let rows: [Row]
    }

    /// A second pass over the ones judged "not about" goes in fives: in
    /// fifteens, plain matches (Galbi-tang, Moussaka) came back false — 257
    /// of 966, scattered.
    private struct Request: Decodable { let batch: Int?; let items: [Item] }
    private static let atOnce = 4

    @MainActor
    static func runIfAsked() async {
        let requestURL = folder.appendingPathComponent("dict-build.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = (try? JSONDecoder().decode(Request.self, from: data))
                ?? (try? JSONDecoder().decode([Item].self, from: data)).map({ Request(batch: nil, items: $0) }) else { return }
        let items = request.items
        let batch = request.batch ?? 15
        let resultsName = request.batch == nil ? "dict-build-results.json" : "dict-build-results-\(batch).json"
        try? FileManager.default.removeItem(at: requestURL)
        let started = Date()
        Usage.local(tag: "사전 만들기 시작", detail: "\(items.count)개", seconds: 0)
        let chunks = stride(from: 0, to: items.count, by: batch).map { Array(items[$0..<min($0 + batch, items.count)]) }
        var done: [Entry] = []
        var failed = 0
        for group in stride(from: 0, to: chunks.count, by: atOnce) {
            let slice = chunks[group..<min(group + atOnce, chunks.count)]
            let results = await OpenAITransport.$planOnly.withValue(true) {
                await withTaskGroup(of: [Entry]?.self) { tasks in
                    for chunk in slice { tasks.addTask { await describe(chunk) } }
                    var all: [[Entry]?] = []
                    for await r in tasks { all.append(r) }
                    return all
                }
            }
            for r in results { if let r { done += r } else { failed += 1 } }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? encoder.encode(done).write(to: folder.appendingPathComponent(resultsName))
        }
        Usage.local(tag: "사전 만들기 끝", detail: "\(done.filter(\.about).count)/\(items.count)개 · 실패 묶음 \(failed)",
                    seconds: -started.timeIntervalSinceNow)
    }

    private static func describe(_ chunk: [Item]) async -> [Entry]? {
        let listing = chunk.enumerated().map { i, item in
            "\(i + 1). \(item.en) — Wikipedia \"\(item.title)\": \(item.extract.prefix(700))"
        }.joined(separator: "\n\n")
        let prompt = """
        For each numbered item: is the Wikipedia intro about this dish or drink as served in restaurants and cafés? If it is, write an English description of one or two sentences — what it is, its main ingredients, how it is made or served, how it tastes. No history, origin story, regions or nutrition. If it is not about the dish, about=false and desc empty.

        \(listing)
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["rows"],
            "properties": ["rows": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["n", "about", "desc"],
                "properties": ["n": ["type": "integer"], "about": ["type": "boolean"], "desc": ["type": "string"]],
            ]]],
        ]
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "input": prompt,
            "text": ["format": ["type": "json_schema", "name": "dishes", "strict": true, "schema": schema]],
        ]
        guard let text = await OpenAICall.text(body, key: PlaceMatcher.openAIKey ?? "", tag: "DictBuild"),
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)) else { return nil }
        return answer.rows.compactMap { row in
            guard chunk.indices.contains(row.n - 1) else { return nil }
            let item = chunk[row.n - 1]
            return Entry(key: item.key, en: item.en, title: item.title, about: row.about,
                         desc: row.desc.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
