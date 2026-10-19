import Foundation

/// What the vision model read from a visit's photos, and which of the GPS
/// candidates it thinks the photos were taken at.
///
/// This is the second layer of evidence on top of GPS. A dense block puts
/// 50–80 food places inside the GPS error, so distance alone cannot pick the
/// restaurant; what is on the table can — 족발 on the plate and "족발보쌈" in a
/// candidate's name, or the name itself on a receipt. The model only
/// *re-orders* candidates and says why; nothing is dropped and the user still
/// confirms with a tap, because a wrong restaurant on a review is the one
/// failure this app must not have.
///
/// Not derived from `serving-detection.mjs` — that prompt forbids naming
/// menus and restaurants, the opposite of this job (CLAUDE.md).
struct PlaceMatch: Codable {
    struct Dish: Codable {
        let name: String
        /// "high" | "medium" | "low" — low means a guess, shown as one.
        let confidence: String
    }
    struct Pick: Codable {
        /// PlaceCandidate.id, resolved from the 1-based index the model returns.
        let id: String
        let confidence: String
        let reason: String
    }
    let dishes: [Dish]
    let cuisine: String
    /// Best first, at most three. Empty when nothing in the list fits.
    let picks: [Pick]
}

enum PlaceMatcher {
    /// The model the other OpenAI calls share (menu naming, drafts, web menus).
    static let model = "gpt-5.4"
    /// Picking a place from the list is a small job: gpt-5.4-mini matched
    /// gpt-5.4 on the 10 confirmed visits (8 of 10, same two misses) at a
    /// tenth of the cost and a second faster.
    static let placeModel = "gpt-5.4-mini"
    /// Reading a menu, naming a photo from that menu and translating a
    /// finished review are all matching jobs rather than writing ones, so
    /// they run on the cheap model too. Writing the review does not.
    static let smallModel = "gpt-5.4-mini"
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// The OpenAI key from Settings (Keychain), else the older defaults or
    /// environment. Signed in with ChatGPT and no key at all, it is "" — the
    /// calls then run on the plan alone (OpenAITransport treats "" as none).
    static var openAIKey: String? {
        let key = Keys.get(.openAI) ?? UserDefaults.standard.string(forKey: "OpenAIAPIKey")
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        if let key, !key.isEmpty { return key }
        return Brain.subscriptionReady ? "" : nil
    }

    /// xAI, for the Grok writer: the key from Settings (Keychain), else
    /// `defaults write com.jinsukim.afterplate XAIAPIKey <key>`.
    static var xaiKey: String? {
        let key = Keys.get(.xai) ?? UserDefaults.standard.string(forKey: "XAIAPIKey")
            ?? ProcessInfo.processInfo.environment["XAI_API_KEY"]
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let prompt = """
    These photos were taken during one restaurant visit. Below is a numbered list of food places within GPS range of the photos, nearest first. The photos' GPS is where the table was, give or take some metres indoors.

    Do two things.

    1. dishes: name what is actually on the table, in Korean, as a diner would say it (예: 족발, 물냉면, 아메리카노). Korean even abroad: a Japanese or English dish is written in Korean letters (ゴーヤーチャンプルー → 고야 참프루, Fish and chips → 피시 앤 칩스). Only what is visible. Mark confidence "high" when unmistakable, "medium" when likely, "low" when a guess. Never invent an exact menu name that is not visible.

    2. fits: every listed place whose KIND could serve what is on the table. Where a place carries 손님 리뷰 lines, they are the better evidence: a review naming the dish (or that kind of cooking) puts the place in, and reviews that name a different cuisine keep it out. (a 스시/초밥집 or 해산물 place serves 우니동; a 카페 serves coffee and cake, not pasta; a 족발보쌈 place serves 족발). Judge the kind only — do NOT weigh distance, and do not try to pick a winner: the app measures the metres itself and takes the nearest of the places you list. Judge by kind, not by name: a place named after 우니 is no likelier to serve 우니 than a sushi shop nearer by, and 삼겹살 in a name does not make it the grill you were at — most places serve far more than their name says, so list every plausible kind, not the best-named one. (A telling name goes in namesake below, not here.) List them by their list number, up to twelve. If nothing on the list could serve this food, return an empty list. A place whose name appears in the OCR text below is decisive on its own; put it first and say so in reason.

    namesake: places whose NAME says they cook this food — 골목칼국수 for a table of 칼국수, "Hamburg House" for 함바그카레. The word may be written in another script than the dish: 함바그 and Hamburg are the same word, ハンバーグ too. Give the index and the word AS IT IS SPELLED IN THE PLACE'S NAME. This is weak evidence and the app treats it as such: it is used only to separate places the metres cannot tell apart, never to reach past a nearer one. Only a whole word that really means the food — 우니 inside "UNI LABO" is a coincidence, not a namesake, and two or three letters swimming inside a longer word are never one. Empty when no name says anything.

    serves: only for places carrying 손님 리뷰 lines — the ones whose reviews SHOW them serving what is on the table, each with the exact words from that review that show it. Quote from the review text given, never from memory, and quote the part that names the dish or the cooking. A review that merely sounds like the right sort of place is not this; leave it out. Empty when no reviews are given, or when none of them name the food.

    picks: leave empty unless the OCR text names one of the places; then return that one, with its list number.

    reason: one short Korean sentence naming the evidence (예: "영수증에 '골목국수' 표기", "해산물 덮밥이 보이고 초밥집만 취급").

    Written evidence is admissible ONLY if the words are in the OCR text list — never claim to have read a name that is not there. A receipt or bill naming a different business (a cafe after a meal, for instance) is evidence that those photos are from somewhere else, not evidence for any listed place.

    cuisine: one short Korean word or phrase for the kind of food overall (예: 한식, 일식, 카페, 술안주).
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "dishes": [
                "type": "array",
                "maxItems": 12,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                    ],
                    "required": ["name", "confidence"],
                ],
            ],
            "cuisine": ["type": "string"],
            "fits": [
                "type": "array",
                "maxItems": 12,
                "items": ["type": "integer"],
            ],
            "serves": [
                "type": "array",
                "maxItems": 6,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "quote": ["type": "string"],
                    ],
                    "required": ["index", "quote"],
                ],
            ],
            "namesake": [
                "type": "array",
                "maxItems": 4,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "word": ["type": "string"],
                    ],
                    "required": ["index", "word"],
                ],
            ],
            "picks": [
                "type": "array",
                "maxItems": 3,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                        "reason": ["type": "string"],
                    ],
                    "required": ["index", "confidence", "reason"],
                ],
            ],
        ],
        "required": ["dishes", "cuisine", "fits", "serves", "namesake", "picks"],
    ]

    private struct Raw: Decodable {
        struct Pick: Decodable { let index: Int; let confidence: String; let reason: String }
        struct Serve: Decodable { let index: Int; let quote: String }
        struct Namesake: Decodable { let index: Int; let word: String }
        let dishes: [PlaceMatch.Dish]
        let cuisine: String
        let fits: [Int]
        let serves: [Serve]
        let namesake: [Namesake]
        let picks: [Pick]
    }

    /// One call: every reduced photo plus the candidate list. nil when the
    /// model did not answer; the caller must not cache that.
    /// A candidate whose name nearly matches a line of OCR text. Vision read
    /// a café's name on a receipt with its first syllable and one more
    /// letter wrong; the model
    /// then failed to connect the two and listed three cafes as "medium".
    /// Character distance connects them: 2 of 11 differ.
    struct TextHit { let candidate: PlaceCandidate; let line: String; let ratio: Double }

    static func textHits(candidates: [PlaceCandidate], ocrText: [String]) -> [TextHit] {
        let lines = ocrText.map { Self.normalize($0) }.filter { $0.count >= 4 }
        var hits: [TextHit] = []
        for candidate in candidates {
            let core = Self.normalize(Self.withoutBranch(candidate.name))
            let full = Self.normalize(candidate.name)
            guard core.count >= 4 else { continue }
            var best: (String, Double)? = nil
            for (raw, line) in zip(ocrText, lines) {
                // The distinctive part must resemble the line on its own (the
                // branch alone never counts); the full name then adds the
                // branch's characters when they are there too: the brand
                // alone scored 0.67 there, the full name with its branch
                // 0.8.
                let coreRatio = Self.bestWindowSimilarity(core, in: line)
                guard coreRatio >= 0.6 else { continue }
                let ratio = max(coreRatio, Self.bestWindowSimilarity(full, in: line))
                if ratio > (best?.1 ?? 0) { best = (raw, ratio) }
            }
            if let best, best.1 >= 0.7 { hits.append(TextHit(candidate: candidate, line: best.0, ratio: best.1)) }
        }
        return hits.sorted { $0.ratio > $1.ratio }
    }

    static func match(
        jpegs: [Data],
        candidates: [PlaceCandidate],
        ocrText: [String],
        reviews: [String: String] = [:],
        /// How far off the visit's position could be, by the phone's own
        /// account. It sets how far out the app is willing to look.
        positionError: Double = 30,
        key: String
    ) async -> PlaceMatch? {
        let list = candidates.enumerated().map { index, c in
            // The photograph count travels with the candidate: a listing with
            // none is one nobody has been to, and the model should not argue
            // for it either.
            let standing = c.unvisited ? ", 사진 0장 (아무도 안 가본 등록)" : ", 사진 \(c.photos)장"
            let head = "\(index + 1). \(c.name)" + (c.category.map { " — \($0)" } ?? "") + " (\(c.distanceLabel)\(standing))"
            guard let id = c.googlePlaceID, let text = reviews[id], !text.isEmpty else { return head }
            return head + "\n   손님 리뷰: " + text
        }.joined(separator: "\n")
        // The app used to read the photos with Vision first and hand the lines
        // over. That pass cost most of the wait, and the model is looking at
        // the same photos — so it reads them itself now.
        let hits = textHits(candidates: candidates, ocrText: ocrText)
        let hitText = hits.isEmpty ? "" : "\n\nCandidates whose names nearly match text read in the photos:\n" + hits.map { hit in
            let index = (candidates.firstIndex { $0.id == hit.candidate.id } ?? 0) + 1
            return "\(index). \(hit.candidate.name) ≈ '\(hit.line)' (\(Int(hit.ratio * 100))%)"
        }.joined(separator: "\n")
        let readIt = "\n\nRead every piece of writing in the photos yourself — a signboard, a receipt, a cup, a napkin, a menu board, a table mat — and say in the reason what you read. One of the candidate names appearing in the photos decides the answer."
        var content: [[String: Any]] = [["type": "input_text", "text": prompt + "\n\nPlaces:\n" + list + readIt + hitText]]
        for jpeg in jpegs {
            content.append([
                "type": "input_image",
                "detail": "high",
                "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
            ])
        }
        let body: [String: Any] = [
            "model": placeModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "place_match", "strict": true, "schema": schema]],
            "max_output_tokens": 600,
        ]
        // One retry on a dropped connection. One visit's lookup lost two
        // calls
        // in a row to the network and the visit was left with no match at all
        // — the same failure PlaceLookup already retries through.
        let started = Date()
        var answer: (Data, Int)?
        for round in 0..<2 {
            if let result = await OpenAITransport.post(body, apiKey: key, timeout: 90, tag: "place-match") { answer = result; break }
            if round == 0 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard let (data, status) = answer else {
            Usage.failed(tag: "place-match", model: placeModel, reason: "unreachable twice", seconds: -started.timeIntervalSinceNow)
            print("[PlaceMatch] OpenAI unreachable")
            return nil
        }
        let seconds = -started.timeIntervalSinceNow
        guard status == 200 else {
            Usage.failed(tag: "place-match", model: placeModel, reason: "http \(status)", seconds: seconds)
            print("[PlaceMatch] OpenAI HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return nil
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Usage.openAI(tag: "place-match", model: root["model"] as? String ?? placeModel,
                         usage: root["usage"] as? [String: Any],
                         output: root["output"] as? [[String: Any]] ?? [], seconds: seconds)
        }
        guard let text = outputText(from: data), let textData = text.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: textData) else {
            print("[PlaceMatch] OpenAI response did not decode: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return nil
        }
        // A reason that cites written text must be backed by the OCR: the
        // model once reported "영수증에 '○○ 본점' 표기" on a receipt
        // that carried no such name. Unbacked claims are demoted, visibly.
        let haystack = ocrText.joined(separator: " ").filter { !$0.isWhitespace }.lowercased()
        var picks = raw.picks.compactMap { pick -> PlaceMatch.Pick? in
            guard candidates.indices.contains(pick.index - 1) else { return nil }
            let candidate = candidates[pick.index - 1]
            let citesText = pick.reason.range(of: "표기|영수증|간판|글자|매트|적혀|명함|컵|냅킨|메뉴판", options: .regularExpression) != nil
            var confidence = pick.confidence, reason = pick.reason
            let backed = Self.nameAppears(candidate.name, in: haystack) || hits.contains { $0.candidate.id == candidate.id && $0.ratio >= 0.7 }
            if citesText, !backed {
                confidence = confidence == "high" ? "medium" : confidence
                reason += " (사진 글자에서 확인되지 않음)"
            }
            return PlaceMatch.Pick(id: candidate.id, confidence: confidence, reason: reason)
        }
        // The kinds the model says could serve this food, nearest first — the
        // metres are measured here, not judged by the model. It read 12m and
        // 13m as a toss-up and called the further one "the nearest grill"
        // three times out of three. Metres between neighbours are real;
        // metres between two units of one building are Google's pin
        // placement. One restaurant sits in the same building as nine shops
        // that all measured 8m, and measured 48m
        // itself — so a building is as close as its closest unit, and within
        // a building nothing is nearer than anything else.
        var buildingDistance: [String: Double] = [:]
        for candidate in candidates {
            guard let building = candidate.building, candidate.distance >= 0 else { continue }
            buildingDistance[building] = min(buildingDistance[building] ?? .greatestFiniteMagnitude, candidate.distance)
        }
        func reach(_ candidate: PlaceCandidate) -> Double {
            guard let building = candidate.building, let near = buildingDistance[building] else { return candidate.distance }
            return near
        }
        // A place named after what it cooks is worth showing: a 칼국수
        // shop with 칼국수 in its name sat 24m from a table of 칼국수,
        // 빈대떡 and 만둣국 and was not among the three picks at all.
        //
        // Short words are how this goes wrong. A photo of 우니 once had the
        // app recommending a place with UNI in its name — two letters living
        // inside a word that had nothing to do with sea urchin. Three
        // characters is the floor, and the scripts are never crossed: 우니 may
        // not match "uni", which is the same mistake wearing a hat.
        //
        // So the model names it instead — it reads both scripts, and 함바그
        // and "Hamburg" are the same word to it while they are nothing alike
        // as characters. The app checks the half it can: the word must really
        // be in that place's name, and be a word, not a fragment. Whether the
        // word means the food is the model's to say.
        let namesakes: [String: String] = raw.namesake.reduce(into: [:]) { found, claim in
            guard candidates.indices.contains(claim.index - 1), !raw.dishes.isEmpty else { return }
            let candidate = candidates[claim.index - 1]
            let word = claim.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let flat = Self.normalize(word)
            guard flat.count >= 3, Self.normalize(candidate.name).contains(flat) else { return }
            found[candidate.id] = word
        }
        func named(_ candidate: PlaceCandidate) -> String? { namesakes[candidate.id] }
        // What the reviews actually show. The app has been buying them at
        // Google's dearest tier whenever the nearest candidate's category was
        // vague — and then ranking by metres anyway, so that 칼국수 shop lost
        // to a 7m place with no reviews at all while its own review said
        // "담백한 칼국수 … 접시만두". Replayed over 28 confirmed
        // places, ranking by this evidence found 20 against distance's 11.
        //
        // The model proposes, the app verifies: the quote must really be in
        // the review text that was sent, and must carry a dish the photos
        // showed. A quote from memory, or one that names nothing, is dropped.
        let readDishes3 = raw.dishes.filter { $0.confidence != "low" }
            .map { Self.normalize($0.name) }
            .filter { $0.count >= 3 }
        let serving: [(candidate: PlaceCandidate, quote: String)] = raw.serves.compactMap { serve in
            guard candidates.indices.contains(serve.index - 1) else { return nil }
            let candidate = candidates[serve.index - 1]
            guard let id = candidate.googlePlaceID, let text = reviews[id] else { return nil }
            let quote = serve.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let flatQuote = Self.normalize(quote), flatText = Self.normalize(text)
            guard !flatQuote.isEmpty, flatText.contains(flatQuote) else { return nil }
            guard readDishes3.contains(where: { flatQuote.contains($0) }) else { return nil }
            return (candidate, quote)
        }
        let servingIDs = Set(serving.map(\.candidate.id))
        var fitting = raw.fits
            .compactMap { candidates.indices.contains($0 - 1) ? candidates[$0 - 1] : nil }
            .sorted { reach($0) < reach($1) }
            .sorted { servingIDs.contains($0.id) && !servingIDs.contains($1.id) }
        // How far out to look before a further place may be offered: twice
        // what the phone says its own reading is worth, never less than 50m.
        // 80 and 150 were numbers picked out of the air; this one comes from
        // the photos. A clean outdoor fix (±5m) keeps the app to its own
        // block; a Wi-Fi fix indoors (±65m) lets it reach the restaurant
        // whose photos landed 100m away.
        let reachable = max(50, positionError * 2)
        let inner = fitting.filter { reach($0) <= reachable }
        if !inner.isEmpty { fitting = inner }
        // A listing nobody has ever photographed, or one Google says is shut,
        // never leads. It stays in the list — Google's data is not always
        // right about a small place — but the meal did not happen at a page
        // with nothing on it.
        let real = fitting.filter { !$0.unvisited && !$0.shut }
        if !real.isEmpty { fitting = real }
        // Metres only rank what the metres can tell apart. A sushi bar
        // (31m) beat a 함바그 house (38m) for a plate of 함바그카레 by seven metres
        // — inside a reading the phone itself only trusts to ±15m, so those
        // seven metres were never a fact. Within that band the evidence
        // leads instead: a review that shows the food beats a name that
        // claims it, and both beat being a little nearer. Outside the band
        // distance still wins, which is what keeps 우니 honest: a sushi bar
        // at 1m is not overtaken by a UNI 30m away.
        func evidence(_ candidate: PlaceCandidate) -> Int {
            if servingIDs.contains(candidate.id) { return 2 }
            if namesakes[candidate.id] != nil { return 1 }
            return 0
        }
        if let leader = fitting.first {
            let band = reach(leader) + positionError
            let tied = fitting.filter { reach($0) <= band }
            if let best = tied.max(by: { (evidence($0), -reach($0)) < (evidence($1), -reach($1)) }),
               best.id != leader.id, evidence(best) > evidence(leader) {
                fitting.removeAll { $0.id == best.id }
                fitting.insert(best, at: 0)
            }
        }
        if !fitting.isEmpty {
            // Name what the photos actually showed, not just the first word of
            // it: a 한정식 spread came back as 백반 · 생선구이 · 삼계탕 · 잡채,
            // the line quoted "백반" alone, and the person read that as the app
            // calling their 한정식 a 백반. Three names let a wrong read be seen
            // at a glance.
            let read = raw.dishes.prefix(3).map(\.name).joined(separator: " · ")
            let dish = read.isEmpty ? raw.cuisine : read
            // Ties are the normal case in a building, so "가장 가까워요" would
            // be claiming something the metres cannot support.
            let closest = reach(fitting[0])
            let tied = fitting.filter { abs(reach($0) - closest) < 1 }.count
            let nearest = fitting.map { candidate -> PlaceMatch.Pick in
                let first = candidate.id == fitting[0].id
                let byName = named(candidate)
                let serves = servingIDs.contains(candidate.id)
                let confidence = fitting.count == 1 || (serves && servingIDs.count == 1) ? "high"
                    : serves ? "medium"
                    : (first && tied == 1 && servingIDs.isEmpty ? "medium" : "low")
                let place = candidate.distance >= 0 && abs(reach(candidate) - candidate.distance) >= 1
                    ? String(localized: "같은 건물 (\(candidate.distanceLabel) 표시)")
                    : candidate.distanceLabel
                let reason: String
                if let quote = serving.first(where: { $0.candidate.id == candidate.id })?.quote {
                    let quoted = String(quote.prefix(40))
                    reason = String(localized: "손님 리뷰에 “\(quoted)” (\(place))")
                } else if let byName {
                    reason = String(localized: "가게 이름에 ‘\(byName)’가 있어요 (\(place))")
                } else if first, tied == 1 {
                    reason = String(localized: "\(dish)을(를) 파는 곳 중 가장 가까워요 (\(place))")
                } else {
                    reason = String(localized: "\(dish)을(를) 팔 수 있는 곳 (\(place))")
                }
                return PlaceMatch.Pick(id: candidate.id, confidence: confidence, reason: reason)
            }
            // A place named after the dish is shown even when it is not the
            // nearest — that 칼국수 shop, 24m from a table of 칼국수, never made
            // the list of three at all. It is NOT promoted above the
            // nearest: scored against the places the person actually
            // confirmed, promoting it got one answer wrong (another visit,
            // which
            // measured correctly) and none right. Offer it, do not pick it.
            var shown = Array(nearest.prefix(3))
            for candidate in fitting where named(candidate) != nil && !shown.contains(where: { $0.id == candidate.id }) {
                if let pick = nearest.first(where: { $0.id == candidate.id }) {
                    shown.insert(pick, at: min(1, shown.count))
                }
            }
            picks = Array(shown.prefix(4))
        }
        // One candidate's name is clearly in the photos' text: that decides,
        // whatever the model made of it. A second near-miss keeps it a lean.
        if let top = hits.first, top.ratio >= 0.8, hits.dropFirst().first.map({ $0.ratio < 0.6 }) ?? true {
            picks.removeAll { $0.id == top.candidate.id }
            let note = Self.normalize(top.line) == Self.normalize(Self.withoutBranch(top.candidate.name)) ? "표기" : "≈ 표기 (OCR 오독 감안)"
            picks.insert(PlaceMatch.Pick(id: top.candidate.id, confidence: "high", reason: "사진 글자 '\(top.line)' \(note)"), at: 0)
            picks = Array(picks.prefix(3))
        }
        return PlaceMatch(dishes: raw.dishes, cuisine: raw.cuisine, picks: picks)
    }

    /// Does a distinctive 3+ character token of the place name occur in the
    /// OCR text? Branch tokens (강남점, 본점, 직영점) do not count — every shop
    /// on the street shares them.
    private static func nameAppears(_ name: String, in haystack: String) -> Bool {
        let tokens = name.components(separatedBy: CharacterSet(charactersIn: " ()·/,-_"))
            .map { $0.lowercased() }.filter { $0.count >= 3 && !$0.hasSuffix("점") }
        return tokens.contains { haystack.contains($0) }
    }

    /// "○○커피 강남점" → "○○커피": the last token is a branch name
    /// when it ends in 점.
    private static func withoutBranch(_ name: String) -> String {
        var tokens = name.components(separatedBy: " ").filter { !$0.isEmpty }
        if tokens.count > 1, let last = tokens.last, last.hasSuffix("점") { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Best similarity of `needle` to any window of `line` of about its
    /// length — receipts put the name in a longer line.
    private static func bestWindowSimilarity(_ needle: String, in line: String) -> Double {
        let n = Array(needle), l = Array(line)
        guard !n.isEmpty, !l.isEmpty else { return 0 }
        var best = 0.0
        for width in max(2, n.count - 2)...(n.count + 2) where width <= l.count {
            for start in 0...(l.count - width) {
                let window = Array(l[start..<(start + width)])
                let d = levenshtein(n, window)
                best = max(best, 1 - Double(d) / Double(max(n.count, width)))
            }
        }
        if l.count < n.count - 2 { best = max(best, 1 - Double(levenshtein(n, l)) / Double(n.count)) }
        return best
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(1, a.count) where i <= a.count {
            cur[0] = i
            for j in 1...max(1, b.count) where j <= b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return b.isEmpty ? a.count : prev[b.count]
    }

    /// The Responses API nests the text inside output[].content[].text.
    private static func outputText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { return nil }
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }
}

/// Second stage of the place match: does the candidate actually sell what is
/// on the table? The model searches each nearby candidate's menu on the web
/// (official page, tabelog, blogs), nearest first, and names the first one
/// that really serves the dishes.
///
/// Why: judging by kind alone put a 우니동 lunch at a place
/// with Uni in its name 31m away over the sushi bar 1m away
/// — what matters is a shop that sells 우니, not one named
/// after it. Verified on that visit — the sushi bar's
/// こぼれうに丼, found in 5s.
enum MenuVerifier {
    struct Verdict {
        let candidate: PlaceCandidate
        let evidence: String
        /// What the search actually saw on that place's menu. The answer was
        /// being read and thrown away: the app confirmed the restaurant from
        /// its menu, then showed "이 가게 메뉴 없음" on the next screen and
        /// offered to go and buy the same menu again.
        let menu: [MenuItem]
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "picks": [
                "type": "array",
                "maxItems": 3,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "index": ["type": "integer"],
                        "serves": ["type": "boolean"],
                        "evidence": ["type": "string"],
                        "menu": [
                            "type": "array",
                            "maxItems": 40,
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "properties": [
                                    "name": ["type": "string"],
                                    "price": ["type": "string"],
                                ],
                                "required": ["name", "price"],
                            ],
                        ],
                    ],
                    "required": ["index", "serves", "evidence", "menu"],
                ],
            ],
        ],
        "required": ["picks"],
    ]

    private struct Raw: Decodable {
        struct Dish: Decodable { let name: String; let price: String }
        struct Pick: Decodable { let index: Int; let serves: Bool; let evidence: String; let menu: [Dish] }
        let picks: [Pick]
    }

    /// `candidates` nearest first. Returns the ones whose menu was found to
    /// carry the dishes, nearest first.
    static func verify(dishes: [String], candidates: [PlaceCandidate], key: String) async -> [Verdict] {
        let dishList = dishes.prefix(6).joined(separator: ", ")
        guard !dishList.isEmpty, !candidates.isEmpty else { return [] }
        let list = candidates.prefix(10).enumerated().map { index, c in
            "\(index + 1). \(c.name)" + (c.category.map { " · \($0)" } ?? "") + " · \(c.distanceLabel)"
        }.joined(separator: "\n")
        let prompt = """
        A diner ate these dishes: \(dishList).
        Below are food places near where the photos were taken, nearest first, with the distance from the photos.

        \(list)

        Search the web for the menus of the nearest candidates (official site, tabelog/naver/blogs, delivery apps) — check them in the order listed, at least the first five. Return every one you could confirm, with: index, serves (true only when you saw the dishes on THAT place's menu), evidence (one short Korean sentence naming the menu item and where you saw it), menu (every item you could read on THAT place's menu page, as printed, with its price as printed — empty string when no price was shown; leave the list empty when you never reached a menu). Copy the menu, do not invent it: an item you did not see on the page does not belong in the list. Never guess from the place's name — a name that mentions a dish proves nothing — and never mark serves true on a hunch that "a place like this would have it".
        """
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "tools": [["type": "web_search"]],
            "input": prompt,
            "text": ["format": ["type": "json_schema", "name": "menu_check", "strict": true, "schema": schema]],
            "max_output_tokens": 4000,
        ]
        guard let answer = await OpenAICall.text(body, key: key, tag: "MenuVerifier"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(answer.utf8)) else { return [] }
        // Nearest first is ours to decide, not the model's: the photos were
        // taken at the table, so among places whose menu carries the dishes
        // the nearest one is the visit.
        return raw.picks.compactMap { pick -> Verdict? in
            guard pick.serves, candidates.indices.contains(pick.index - 1) else { return nil }
            let evidence = pick.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            let menu = pick.menu.compactMap { dish -> MenuItem? in
                let name = dish.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return MenuItem(name: name, price: dish.price.trimmingCharacters(in: .whitespacesAndNewlines), section: "")
            }
            return Verdict(candidate: candidates[pick.index - 1],
                           evidence: evidence.isEmpty ? "메뉴에서 확인" : evidence,
                           menu: menu)
        }.sorted { $0.candidate.distance < $1.candidate.distance }
    }
}
