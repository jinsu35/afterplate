import Foundation

/// Every paid call the app makes — what it cost and how long it took —
/// appended to ~/Library/Application Support/Afterplate/usage.jsonl, one JSON
/// object per line. The point is to be able to sit down afterwards and see
/// where the money and the seconds actually went, per visit and per stage,
/// instead of arguing from estimates.
///
/// Prices are the list ones as of 2026-09-20 and are baked into each line as a
/// computed `usd`, so a later price change does not rewrite history:
///   gpt-5.4        $2.50 / 1M input, $15.00 / 1M output
///   gpt-5.4-mini   $0.375 / 1M input, $2.25 / 1M output
///   grok-4.20      $1.25 / 1M input, $2.50 / 1M output (xAI, 2026-09-28)
///   cached input   a tenth of the input price (OpenAI's usual discount)
///   web_search     ~$25 / 1,000 calls (OpenAI quotes $10–50 by context size;
///                  taken as $0.025 a call and marked `estimated`)
///   Google Places Pro fields         $32 / 1,000, 5,000 free a month
///   Google Places Enterprise (리뷰)   $40 / 1,000, 1,000 free a month
enum Usage {
    struct Price {
        let input: Double      // per 1M tokens
        let output: Double     // per 1M tokens
    }

    private static let prices: [String: Price] = [
        "gpt-5.4": Price(input: 2.50, output: 15.00),
        "gpt-5.4-mini": Price(input: 0.375, output: 2.25),
        // xAI list price 2026-09-28 (api.x.ai/v1/language-models); the id comes
        // back dated ("grok-4.20-0309-non-reasoning"), so price by the family.
        "grok-4.20": Price(input: 1.25, output: 2.50),
        // Anthropic list price 2026-10-13 (platform.claude.com pricing).
        "claude-sonnet-5-5": Price(input: 2.00, output: 10.00),
        "claude-haiku-4-5": Price(input: 1.00, output: 5.00),
    ]
    static let webSearchCall = 0.025
    /// Anthropic's web search, $10 / 1,000.
    static let claudeSearchCall = 0.010
    static let googlePro = 0.032
    static let googleEnterprise = 0.040

    /// A model id comes back from the API with a date suffix
    /// ("gpt-5.4-2026-08-07"); price it by the longest name that prefixes it.
    static func price(_ model: String) -> Price {
        let hit = prices.keys.filter { model.hasPrefix($0) }.max(by: { $0.count < $1.count })
        return prices[hit ?? ""] ?? Price(input: 2.50, output: 15.00)
    }

    private static let url: URL = {
        let base = AppData.folder
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage.jsonl")
    }()

    /// Which visit the app is working on, so a line reads back as "this visit,
    /// this step". The network layers know nothing about visits, so each stage
    /// stamps it; a task-local because several visits are looked up at once
    /// (the launch prefetch) and a shared variable would mislabel them. Child
    /// tasks — the parallel Nearby pages — inherit it.
    @TaskLocal static var visit = ""

    /// Run a visit's stage under its name, and log what the whole stage took,
    /// billed parts and waiting alike.
    /// A stage that returned in a blink did no work — a cache hit, a guard —
    /// and a line for it would bury the real ones.
    private static let worthLogging = 0.05

    static func stage<T>(_ visit: String, _ tag: String, _ work: () async -> T) async -> T {
        await $visit.withValue(visit) {
            let started = Date()
            let result = await work()
            let seconds = -started.timeIntervalSinceNow
            if seconds >= worthLogging { local(tag: tag, seconds: seconds) }
            return result
        }
    }

    /// One Responses API call, priced from the response's own usage block.
    /// The cost of the most recent OpenAI call, for a caller that wants to
    /// put it on its own row.
    static var lastOpenAIUSD: Double = 0

    static func openAI(tag: String, model: String, usage: [String: Any]?, output: [[String: Any]], seconds: Double) {
        let input = usage?["input_tokens"] as? Int ?? 0
        let out = usage?["output_tokens"] as? Int ?? 0
        let cached = (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let reasoning = (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        let searches = output.filter { ($0["type"] as? String ?? "").hasSuffix("search_call") }.count
        let rate = price(model)
        let fresh = max(input - cached, 0)
        // On the person's ChatGPT plan or linked Grok subscription nothing
        // is
        // billed per call.
        let onPlan = model.hasPrefix("chatgpt-plan/") || model.hasPrefix("grok-plan/")
        let cost = onPlan ? 0 : Double(fresh) / 1_000_000 * rate.input
            + Double(cached) / 1_000_000 * rate.input / 10
            + Double(out) / 1_000_000 * rate.output
            + Double(searches) * (model.hasPrefix("claude") ? claudeSearchCall : webSearchCall)
        lastOpenAIUSD = cost
        write([
            "kind": "openai",
            "tag": tag,
            "model": model,
            "in": input,
            "cached": cached,
            "out": out,
            "reasoning": reasoning,
            "searches": searches,
            "seconds": rounded(seconds, 2),
            "usd": rounded(cost, 5),
            "estimated": searches > 0 && !model.hasPrefix("claude"),
        ])
    }

    /// A call that cost time and possibly money but returned nothing usable.
    static func failed(tag: String, model: String, reason: String, seconds: Double) {
        write([
            "kind": "failed",
            "tag": tag,
            "model": model,
            "reason": reason,
            "seconds": rounded(seconds, 2),
            "usd": 0,
        ])
    }

    static func google(tag: String, requests: Int, enterprise: Bool = false, seconds: Double) {
        let cost = Double(requests) * (enterprise ? googleEnterprise : googlePro)
        write([
            "kind": "google",
            "tag": tag,
            "model": enterprise ? "places-enterprise" : "places-pro",
            "requests": requests,
            "seconds": rounded(seconds, 2),
            "usd": rounded(cost, 5),
            "free_tier": enterprise ? 1000 : 5000,
        ])
    }

    /// Whether the app's pick was the place the person chose. Written the
    /// moment they confirm — the scorecard is their own use, which costs
    /// nothing and knows the answer, instead of a replay that costs a dollar
    /// and guesses at it.
    /// Enough on the line to say WHY it was wrong without opening the app:
    /// what the photos were read as, what the app led with and why, how far
    /// each was, and what Google called them.
    static func matchScore(visit: String, rank: Int, offered: Int,
                           top: String, topCategory: String, topMetres: Int, reason: String,
                           chosen: String, chosenCategory: String, metres: Int,
                           dishes: [String], boughtReviews: Bool) {
        write([
            "kind": "match-score",
            "tag": rank == 0 ? "right" : (rank > 0 ? "in-list" : (rank == -2 ? "rejected" : "missing")),
            // Confirming happens outside any stage, so the task-local visit is
            // empty here and every scorecard line was filed under no visit.
            "visit_at": visit,
            "rank": rank,
            "offered": offered,
            "top": top,
            "top_category": topCategory,
            "top_metres": topMetres,
            "reason": reason,
            "chosen": chosen,
            "chosen_category": chosenCategory,
            "metres": metres,
            "dishes": dishes,
            "reviews": boughtReviews,
            "seconds": 0,
            "usd": 0,
        ])
    }

    /// Archived, or taken back out. Which visits a person will not review is
    /// the judgement the classifier is trying to learn, so every 보관 is a
    /// labelled example — kept with what the scores said at the time, so a
    /// later pass can ask where the scores and the person disagreed.
    static func archive(visit: String, put away: Bool, photos: Int, videos: Int,
                        food: Int, apple: Float, mainlyFood: Float, table: Float, people: Float,
                        hasGPS: Bool, place: String, step: Int) {
        write([
            "kind": "archive",
            "tag": away ? "보관" : "꺼내기",
            "photos": photos,
            "videos": videos,
            "food_photos": food,
            "apple": rounded(Double(apple), 3),
            "mainly_food": rounded(Double(mainlyFood), 3),
            "table": rounded(Double(table), 3),
            "people": rounded(Double(people), 3),
            "gps": hasGPS,
            "place": place,
            "step": step,
            "visit_at": visit,
            "seconds": 0,
            "usd": 0,
        ])
    }

    /// A step the user waits through that costs nothing — the library scan,
    /// the hidden web view reading a menu — so the time column tells the whole
    /// story and not just the billed parts.
    /// One row per side-by-side menu read, with everything a later review
    /// needs: which visit, which place, where, and what each reader saw —
    /// so the failures can be gone through in one sitting rather than
    /// re-run one at a time.
    static func menuCompare(visit: String, visitID: String, place: String, placeID: String,
                            lat: Double, lon: Double, category: String,
                            googleSeconds: Double, googleNames: [String], googleNote: String,
                            webSeconds: Double, webNames: [String], webNote: String, webUSD: Double) {
        write([
            "kind": "menu-compare",
            "tag": "메뉴 비교",
            "visit": visit,
            "visit_id": visitID,
            "place": place,
            "place_id": placeID,
            "lat": lat, "lon": lon,
            "category": category,
            "google_seconds": rounded(googleSeconds, 2),
            "google_count": googleNames.count,
            "google_names": Array(googleNames.prefix(40)),
            "google_note": String(googleNote.prefix(900)),
            "web_seconds": rounded(webSeconds, 2),
            "web_count": webNames.count,
            "web_names": Array(webNames.prefix(40)),
            "web_note": String(webNote.prefix(600)),
            "seconds": rounded(max(googleSeconds, webSeconds), 2),
            "usd": rounded(webUSD, 5),
        ])
    }

    static func local(tag: String, detail: String = "", seconds: Double) {
        write([
            "kind": "local",
            "tag": tag,
            "detail": detail,
            "seconds": rounded(seconds, 2),
            "usd": 0,
        ])
    }

    /// Wrap an awaited step so the timing cannot drift from the work.
    static func timing<T>(_ tag: String, detail: String = "", _ work: () async -> T) async -> T {
        let started = Date()
        let result = await work()
        local(tag: tag, detail: detail, seconds: -started.timeIntervalSinceNow)
        return result
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    private static let queue = DispatchQueue(label: "afterplate.usage")
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func write(_ fields: [String: Any]) {
        let now = Date()
        let visit = visit
        queue.async {
            var line = fields
            line["at"] = stamp.string(from: now)
            line["visit"] = visit
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            var blob = data
            blob.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: blob)
            } else {
                try? blob.write(to: url, options: .atomic)
            }
        }
    }
}
