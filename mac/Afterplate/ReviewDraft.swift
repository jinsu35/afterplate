import Foundation

/// A review the app wrote for a visit, for the user to pick, edit and post.
/// Korean is the source; English is a translation of whatever the user ends
/// up with, made on demand.
///
/// The writing is the v3 engine (`/v3/generate`) of an earlier review-writing
/// project — the predecessor engine below — ported as it was: no photos, no
/// facts about the place, no instructions about structure. Per dish, the
/// model is first asked what the dish is (two conversation turns, the answer
/// taken from a shipped dish dictionary when it has one), then given one line
/// — "넌 X 먹었어. 그리고 말했지 '맛있었다'. 그 말을 다르게 표현해봐" — plus a style name. (It said
/// 한마디 at first: six cards out of six reached for 한 모금, and the 한 in 한마디
/// looked like the prime.) Every constraint layered on top of that line
/// flattened the writing; the prompts below are the original wording with
/// nothing added. Two of its words are gone. 방금 was taken out (it came
/// straight back out of the model and opened a quarter of the drafts),
/// slipped back in with a rewrite the next day, and was taken out again later
/// (37 of 120 cards opened 방금 먹은).
/// 더 잘 became 다르게 the same day: 더 잘 read as "dramatize", and the
/// dramatized tasting instant is where "X 한입 베어 무는 순간" comes from
/// (mac/experiments/2026-09-28-*). 먹고 왔어 became 먹었어 the same evening:
/// with 방금 gone, 먹고 왔 took its place as the echoed opener (84 of 240).
/// The tag line still says 다녀왔어. Dishes are written one at a time and merged,
/// because one call asked to cover several spent itself on the first.
struct ReviewDraft: Codable {
    var text: String
    let dishes: [String]
    var genre: String? = nil
    /// Which model wrote it, so picks can be tallied by writer (mac/pick-tally.py).
    var model: String? = nil
    /// Matches GenreDraft.id, so the card the person picked stays lit.
    var takeID: String { (genre ?? "") + "/" + (model ?? "") }
}

struct GenreDraft: Codable, Identifiable {
    let genre: String
    let note: String
    let text: String
    /// Which model wrote it. nil on drafts written before the model
    /// comparisons (all gpt-5.4).
    var model: String? = nil
    var id: String { genre + "/" + (model ?? "") }
    /// Short tag for the card.
    var modelTag: String? {
        guard let model else { return nil }
        if model.hasPrefix("grok") { return "grok" }
        return model.contains("mini") ? "mini" : "5.4"
    }
}

struct ReviewGenre: Hashable {
    let name: String
    /// The tonal family, shown under the name so the user sees why three
    /// cards differ.
    let note: String

    /// What the writer is told, when the card's name would be read as a
    /// person to play. Told "맛슐랭 인스펙터", Grok wrote as the inspector —
    /// "맛슐랭 인스펙터로서…" in 6 of 6 lines; asked why, it said it took the
    /// style for a role to speak as. Told "미식 평론", 0 of 5, and still a
    /// critic's voice (this one only).
    /// The English card has the same trouble: "Inspector's notes:" opened 3
    /// of 3 English lines.
    var written: String { ["맛슐랭 인스펙터": "미식 평론", "Inspector's notes": "Food critique"][name] ?? name }
}

enum ReviewDrafter {
    /// What the drafting is doing, for the line the person watches ("writing
    /// drafts" while it was finding out what a dish is).
    enum Stage: Equatable, Sendable {
        case lookingUp(String)
        case searching(String)
        case writing
    }
    @TaskLocal static var report: (@Sendable (Stage) -> Void)?

    /// While the two models are being compared: every card is written by both
    /// and shown side by side, unlabelled and in a random order per card, so
    /// the pick is blind. Which model wrote the chosen one is kept in the
    /// draft and can be tallied afterwards. Set to nil to go back to one model.
    /// The writing then moved to Grok. On a 600-card
    /// sweep over all 30 styles, gpt-5.4 opened with "X 한 [단위] …" on 339
    /// cards and grok-4.20 on 184 (mac/experiments/2026-09-28-*). The pair
    /// was gpt-5.4 vs grok for an hour, then Grok alone; put gpt-5.4 back in
    /// the list to compare again. The dish descriptions still come from
    /// gpt-5.4; only the writing goes to Grok.
    static let comparing: [String]? = ["grok-4.20-non-reasoning"]
    static let model = PlaceMatcher.model
    private static let xaiEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    /// The plain card: the one line with no style at all. Shown on the
    /// first draw only; "다른 표현으로" gives three styled ones.
    static var plain: ReviewGenre {
        english ? ReviewGenre(name: "Plain", note: "Nothing added") : ReviewGenre(name: "담백", note: "덧붙인 것 없이")
    }

    /// The app is in English: the cards are written in English from the
    /// start, in English counterparts of the same styles.
    static var english: Bool { forcedEnglish ?? AppLanguage.current.isEnglish }
    /// Set by DescTrial to look a dish up in the other language.
    @TaskLocal static var forcedEnglish: Bool?

    /// Five styles beside 담백, chosen from what was actually picked: of
    /// 118 chosen drafts, 담백 45, 맛슐랭 7, 트로트 6, 심야식당 5, 김훈풍 + 극단적 간결 8; 광고
    /// 카피 kept over 블로그 체험단 by choice. The other 24 of the predecessor's
    /// 29 (three never
    /// picked, eight once) read as childish and are gone. A draw still takes
    /// one family per card, so two cards never share one.
    static var families: [[ReviewGenre]] { english ? englishFamilies : koreanFamilies }

    /// The same five, as an English reviewer would write them. 트로트 has no
    /// English twin; a country song is the nearest sentimental, sing-along
    /// register.
    static let englishFamilies: [[ReviewGenre]] = [
        [ReviewGenre(name: "Inspector's notes", note: "Critic")],
        [ReviewGenre(name: "Ad copy", note: "Persuasion")],
        // Not a late-night diner: it put every meal past midnight, true or
        // not. The Solitary Gourmet's inner voice instead.
        [ReviewGenre(name: "The Solitary Gourmet inner monologue", note: "Inner voice")],
        ["Hemingway-terse", "Bare minimum"].map { ReviewGenre(name: $0, note: "Dry, short") },
        [ReviewGenre(name: "Country song", note: "Lyrics")],
    ]

    static let koreanFamilies: [[ReviewGenre]] = [
        [ReviewGenre(name: "맛슐랭 인스펙터", note: "평론가")],
        [ReviewGenre(name: "광고 카피", note: "설득")],
        [ReviewGenre(name: "고독한 미식가 속마음", note: "혼잣말")],
        ["김훈풍", "극단적 간결"].map { ReviewGenre(name: $0, note: "건조·단문") },
        [ReviewGenre(name: "트로트 가사", note: "가사")],
    ]

    /// `count` styles from `count` different families, skipping families
    /// shown last time when enough remain.
    static func draw(_ count: Int, avoiding shown: Set<String>) -> [ReviewGenre] {
        var pool = families.filter { family in !family.contains { shown.contains($0.name) } }
        if pool.count < count { pool = families }
        return pool.shuffled().prefix(count).compactMap { $0.randomElement() }
    }

    // MARK: - Step 0: what each dish is

    /// The predecessor's shipped dictionary (464 dishes, one
    /// description each). The
    /// first sentence is always the definition; only that goes in — the full
    /// entry became the skeleton of every card.
    private static let koreanDictionary: [String: String] = load("dish-desc")["desc"] as? [String: String] ?? [:]
    /// The global edition, for writing in English: 613 dishes from English
    /// Wikipedia intros,
    /// made the way the Korean one was, and the menu and Korean names that
    /// lead to them.
    private static let englishFile = load("dish-desc-en")
    private static let englishDictionary: [String: String] = englishFile["desc"] as? [String: String] ?? [:]
    private static let englishAliases: [String: String] = englishFile["aliases"] as? [String: String] ?? [:]
    private static var dictionary: [String: String] { english ? englishDictionary : koreanDictionary }

    private static func load(_ name: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[ReviewDraft] \(name).json missing from the bundle")
            return [:]
        }
        return root
    }
    /// Every dish name the app knows, for fixing a typed slip: the shipped
    /// descriptions, the dishes it has learned, the short forms people type,
    /// and a menu-word list that exists only for spelling (the description
    /// dictionary came from Wikipedia and is thin on drinks and desserts —
    /// 50 of 95 everyday orders were missing).
    static var knownDishes: [String] {
        Array(koreanDictionary.keys) + Array(learnedKorean.keys) + Array(aliases.values) + spellingNames
    }
    private static let spellingNames: [String] = load("dish-names")["names"] as? [String] ?? []
    private static let compactIndex: [String: String] = {
        var index: [String: String] = [:]
        for key in koreanDictionary.keys { index[key.replacingOccurrences(of: " ", with: "")] = key }
        for key in englishDictionary.keys { index[key.replacingOccurrences(of: " ", with: "").lowercased()] = key }
        for (alias, key) in englishAliases { index[alias.replacingOccurrences(of: " ", with: "").lowercased()] = key }
        return index
    }()
    /// Short forms people type; the dictionary holds the canonical dish.
    private static let aliases: [String: String] = [
        "라떼": "카페라떼", "라테": "카페라떼", "카페 라떼": "카페라떼",
        "아메": "아메리카노", "아아": "아메리카노", "뜨아": "아메리카노",
        "아이스아메리카노": "아메리카노", "아이스 아메리카노": "아메리카노",
        "아바라": "바닐라 라떼", "아샷추": "아이스티",
    ]

    /// A Korean review says a menu printed only in another language in
    /// Korean: "BURRATA FRUIT SALAD는" came out word for word when the shop's
    /// menu was read before DishSearch gave Korean names. Any script, not
    /// only Latin letters: a Greek menu stayed Greek in the Korean app, as
    /// it had in the English one.
    /// Asked once per name and kept.
    static func koreanName(_ name: String) async -> String {
        guard !english, name.contains(where: \.isLetter),
              !name.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return name }
        if let known = koreanNames[name] { return known }
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "none"],
            "max_output_tokens": 60,
            "input": [["role": "user", "content": "\(name) - 한국어 메뉴판에 쓰는 이름으로 바꿔줘."]],
            "text": ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": [
                "type": "object", "additionalProperties": false,
                "properties": ["이름": ["type": "string"]], "required": ["이름"],
            ]]],
        ]
        guard let answer = await call(body, tag: "ReviewDraft/name"),
              let root = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: String],
              let korean = root["이름"]?.trimmingCharacters(in: .whitespacesAndNewlines), !korean.isEmpty,
              korean.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return name }
        koreanNames[name] = korean
        if let data = try? JSONEncoder().encode(koreanNames) { try? data.write(to: koreanNamesURL, options: .atomic) }
        return korean
    }
    /// The same for a whole menu at once, before any draft: a menu found
    /// only in English (an udon chain abroad: Nikutama, Kitsune, Tan
    /// Tan) showed English chips beside the photo's Korean "니쿠타마 우동".
    /// One call with no search; names already known are not
    /// asked again.
    static func koreanNames(_ names: [String]) async -> [String: String] {
        guard !english else { return [:] }
        let foreign = names.filter { name in
            name.contains(where: \.isLetter)
                && !name.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) })
        }
        var out = foreign.reduce(into: [String: String]()) { if let k = koreanNames[$1] { $0[$1] = k } }
        let ask = Array(Set(foreign.filter { out[$0] == nil })).sorted()
        guard !ask.isEmpty else { return out }
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "none"],
            "max_output_tokens": 40 * ask.count + 100,
            "input": [["role": "user", "content": "이 메뉴들을 한국어 메뉴판에 쓰는 이름으로 바꿔줘. 순서 그대로, 하나도 빼지 말고.\n" + ask.joined(separator: "\n")]],
            "text": ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": [
                "type": "object", "additionalProperties": false,
                "properties": ["이름": ["type": "array", "items": ["type": "string"]]], "required": ["이름"],
            ]]],
        ]
        guard let answer = await call(body, tag: "ReviewDraft/names"),
              let root = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: [String]],
              let korean = root["이름"], korean.count == ask.count else { return out }
        for (name, k) in zip(ask, korean) {
            let k = k.trimmingCharacters(in: .whitespacesAndNewlines)
            guard k.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { continue }
            koreanNames[name] = k
            out[name] = k
        }
        if let data = try? JSONEncoder().encode(koreanNames) { try? data.write(to: koreanNamesURL, options: .atomic) }
        return out
    }

    /// For the chips: the Korean name once a draft has asked for it.
    static func knownKoreanName(_ name: String) -> String? { english ? nil : koreanNames[name] }
    private static let koreanNamesURL = AppData.folder.appendingPathComponent("dish-names-ko.json")
    private static var koreanNames: [String: String] = (try? Data(contentsOf: koreanNamesURL))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

    /// Descriptions found for dishes the dictionary lacks, kept so a dish is
    /// looked up once — one file per language.
    private static func learnedURL(english: Bool) -> URL {
        AppData.folder
            .appendingPathComponent(english ? "dish-desc-learned-en.json" : "dish-desc-learned.json")
    }
    private static func readLearned(english: Bool) -> [String: String] {
        guard let data = try? Data(contentsOf: learnedURL(english: english)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
    private static var learnedKorean = readLearned(english: false)
    private static var learnedEnglish = readLearned(english: true)
    private static func remember(_ name: String, _ desc: String) {
        if english { learnedEnglish[name] = desc } else { learnedKorean[name] = desc }
        let map = english ? learnedEnglish : learnedKorean
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: learnedURL(english: english), options: .atomic) }
    }

    private static func firstSentence(_ desc: String) -> String {
        let text = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = english ? #"^(.*?[a-z0-9)\]])\.(?:\s|$)"# : #"^(.*?(?:다|요|음|됨|함))\.(?:\s|$)"#
        if let range = text.range(of: ending, options: .regularExpression) {
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The two turns held as conversation history before the review prompt.
    /// Inline, the model treated the description as the answer and returned
    /// an encyclopedia entry.
    ///
    /// The predecessor's order, all four steps (the fourth was left out when
    /// this was first ported): the shipped dictionary; what was
    /// learned before; asking the model with no search, which knows most
    /// dishes and says 없음 for the rest; and for those, a forced web search.
    /// Whatever the model or the search says is cleaned to what the dish is
    /// — or thrown out if it is about something else — and remembered.
    /// The answer the lookup settled on, and where it came from — for DescTrial.
    static func describe(_ dish: String) async -> String? {
        (await descriptionTurns(for: dish, model: model)).last?["content"] as? String
    }

    /// `about`: what the place's own menu says the dish is, used first.
    /// `place`: "Shop name, City", for the search — a house name
    /// searched alone ("House Trio") finds books and bands. The
    /// predecessor's "이름 - 질문" shape is kept: the place goes in brackets
    /// after the question, never glued to the name.
    private static func descriptionTurns(for dish: String, model: String, about: String? = nil, place: String = "") async -> [[String: Any]] {
        let lookup = aliases[dish] ?? dish
        let question = english ? "\(lookup) - do you know what this dish is?" : "\(lookup) - 어떤 음식인지 알어?"
        let turns = { (desc: String) -> [[String: Any]] in
            [["role": "user", "content": question], ["role": "assistant", "content": firstSentence(desc)]]
        }
        if let about = about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            print("[ReviewDraft] \(dish): menu (\(about.prefix(80)))")
            return turns(about)
        }
        let atPlace = place.isEmpty ? nil : "\(lookup) @ \(place)"
        let compact = lookup.replacingOccurrences(of: " ", with: "")
        if let desc = dictionary[lookup]
            ?? (english ? englishAliases[lookup].flatMap { englishDictionary[$0] } : nil)
            ?? compactIndex[english ? compact.lowercased() : compact].flatMap({ dictionary[$0] }) {
            print("[ReviewDraft] \(dish): dict")
            return turns(desc)
        }
        let learned = english ? learnedEnglish : learnedKorean
        if let desc = atPlace.flatMap({ learned[$0] }) ?? learned[lookup] { print("[ReviewDraft] \(dish): learned"); return turns(desc) }
        report?(.lookingUp(dish))
        let probe = english
            ? "\(lookup) - is this a menu item sold at restaurants or cafés (food, drink or dessert)? If you know for certain, describe it in two or three sentences. If you do not know or are not sure, write exactly 'none' as the description. Do not guess."
            : "\(lookup) - 식당이나 카페에서 파는 메뉴(음식·음료·디저트)야? 확실히 알면 어떤 메뉴인지 2~3문장으로 설명해줘. 모르거나 확실하지 않으면 설명에 정확히 '없음'이라고만 써. 추측해서 지어내지 마."
        if let said = await askDescription(probe, model: model, tag: "ReviewDraft/probe"),
           let desc = await distill(lookup, said, model: model) {
            print("[ReviewDraft] \(dish): probe")
            remember(lookup, desc)
            return turns(desc)
        }
        report?(.searching(dish))
        let searched = place.isEmpty ? question
            : question + (english ? " (on the menu at \(place))" : " (\(place) 메뉴)")
        let found = await askDescription(searched, model: model, tag: "ReviewDraft/search", search: true)
        print("[ReviewDraft] \(dish): search asked “\(searched)” → \(found.map { String($0.prefix(300)) } ?? "nothing")")
        if let found, let desc = await distill(place.isEmpty ? lookup : "\(lookup) (\(place))", found, model: model) {
            print("[ReviewDraft] \(dish): probe=없음 → search")
            // Found at this place: kept as this place's, not as every
            // dish of the name.
            remember(atPlace ?? lookup, desc)
            return turns(desc)
        }
        print("[ReviewDraft] \(dish): probe=없음 → search=실패")
        return []
    }

    /// One answer in a {설명} schema; nil when empty or 없음/none. With
    /// `search` the web search is forced: left to choose, the model skipped it
    /// and answered from memory (as the predecessor engine found).
    private static func askDescription(_ prompt: String, model: String, tag: String, search: Bool = false) async -> String? {
        var body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": prompt]],
            "text": ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": [
                "type": "object", "additionalProperties": false,
                "properties": ["설명": ["type": "string"]], "required": ["설명"],
            ]]],
        ]
        if search {
            body["tools"] = [["type": "web_search"]]
            body["tool_choice"] = "required"
        } else {
            body["max_output_tokens"] = 300
        }
        guard let answer = await call(body, tag: tag),
              let root = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: String],
              let desc = root["설명"].map(tidy), !desc.isEmpty,
              !["없음", "none"].contains(desc.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces).lowercased())
        else { return nil }
        return desc
    }

    /// The predecessor's verify-and-distill: keep what the dish is,
    /// made of what, how,
    /// tasting how; drop history, etymology, people, years, regions; 아님
    /// when the text is about something else (it caught 빠쓰 → a Busan
    /// pancake and 뭉티기 → Jeju horse meat).
    private static func distill(_ name: String, _ raw: String, model: String) async -> String? {
        let prompt = english
            ? "Below is a description of '\(name)'.\n\(raw)\nIf it is correct, rewrite it in two or three sentences with only the essentials — what it is made of, how, and how it tastes. Leave out history, origin, etymology, people, years and regions. Add nothing the text does not say. If the description is about something else or wrong, write exactly 'none'."
            : "아래는 '\(name)'에 대한 설명이다.\n\(raw)\n이 설명이 정확하면, 어떤 메뉴인지 핵심만 2~3문장으로 다시 써줘 — 무엇으로 어떻게 만든 어떤 맛의 메뉴인지만. 역사·유래·어원·인물·연도·지역 이야기는 빼. 원문에 없는 내용을 더하지 마. 설명이 다른 대상 이야기거나 틀렸으면 정확히 '아님'이라고만 써."
        guard let out = await askDescription(prompt, model: model, tag: "ReviewDraft/distill"),
              out.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces) != "아님" else { return nil }
        return out
    }

    /// Markdown, citation links and runs of space out; long answers cut at a
    /// sentence end near 800 characters (the predecessor's tidyDesc).
    private static func tidy(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\[\[\d+\]\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 800 {
            let cut = String(t.prefix(800))
            if let end = cut.lastIndex(where: { ".!?".contains($0) }), cut.distance(from: cut.startIndex, to: end) > 80 {
                t = String(cut[...end])
            } else { t = cut }
        }
        return t
    }

    // MARK: - Step 1: the one line

    /// ♥ → 정말 맛있었다; else 나쁘지 않았다 (this app's two tiers). The predecessor
    /// found
    /// "평범했다" read as a letdown and switched its unstarred line to
    /// "맛 평가 없이 뭘 먹었는지만 있는 그대로 적어봐"; keep an eye on whether
    /// 나쁘지 않았다 drifts the same way.
    /// What a tag line is allowed to say. With photos, only what is in them;
    /// without, nothing but the remark itself — no window, no rooftop, no
    /// room it has not seen.
    private static func photoRule(_ photos: [Data]) -> String {
        let language = english ? "English" : "Korean"
        return photos.isEmpty
            ? " (Write in \(language). You have not seen the place: say the remark in general terms, put a little differently. Invent nothing about it — not what the view looked out on, not the room, the furniture or the staff.)"
            : " (Write in \(language), from the attached photos of the place. Only what is actually visible in them: if the photos do not show a window, there is no window in the sentence. Never guess where this is — not a house, not a rooftop, not a floor number.)"
    }

    private static func lead(_ subject: Subject, setting: String = "") -> String {
        if english {
            return subject.byName
                ? "You ate \(subject.name). And you said: “\(subject.said)”. Say that differently"
                : "You went to that place\(setting.isEmpty ? "" : " (\(setting))"). And you said: “\(subject.said)”. Say that differently"
        }
        return subject.byName
            ? "넌 \(subject.name) 먹었어. 그리고 말했지 “\(subject.said)”. 그 말을 다르게 표현해봐"
            : "넌 그 집에 다녀왔어\(setting.isEmpty ? "" : " (\(setting))"). 그리고 말했지 “\(subject.said)”. 그 말을 다르게 표현해봐"
    }


    /// Several dishes as one remark: "A랑 B" and "둘 다 괜찮았다", or "A는
    /// 맛있었고 B는 괜찮았다" when they differ.
    private static func together(_ dishes: [Subject]) -> Subject {
        let names = dishes.map(\.name)
        let sameSaid = Set(dishes.map(\.said)).count == 1
        if english {
            let list = names.count == 2 ? names.joined(separator: " and ")
                : names.dropLast().joined(separator: ", ") + " and " + names.last!
            let said = sameSaid
                ? (names.count == 2 ? "Both " : "All of them ") + dishes[0].said.replacingOccurrences(of: "It was ", with: "were ")
                : dishes.map { $0.said.replacingOccurrences(of: "It", with: $0.name) }.joined(separator: ", and ")
            return Subject(name: list, said: said, byName: true)
        }
        let list = names.joined(separator: "랑 ")
        let said: String
        if sameSaid {
            said = (names.count == 2 ? "둘 다 " : "다 ") + dishes[0].said
        } else {
            said = dishes.enumerated().map { i, dish in
                let topic = dish.name + (hasBatchim(dish.name) ? "은 " : "는 ")
                return topic + (i == dishes.count - 1 ? dish.said : String(dish.said.dropLast()) + "고")
            }.joined(separator: " ")
        }
        return Subject(name: list, said: said, byName: true)
    }

    /// Whether the last letter is a Hangul syllable with a final consonant.
    private static func hasBatchim(_ word: String) -> Bool {
        guard let scalar = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        return (scalar.value - 0xAC00) % 28 != 0
    }

    /// Asks the model to mark its own wording, so the line can be lifted out
    /// cleanly (`firstCandidate`).
    private static var marker: String {
        english ? " Put *^ at the start and end of your wording." : " 너희 표현을 쓸때 시작과 끝에 *^를 넣어."
    }

    /// Dish names as the model should say them: the Korean form when the
    /// menu printed both ("Quattro Formaggi (콰트로 포르마지)").
    static func spoken(_ name: String) -> String {
        // In English the printed English half is what the review says.
        if english, let open = name.lastIndex(of: "("), name[..<open].contains(where: { $0.isLetter && $0.isASCII }) {
            return name[..<open].trimmingCharacters(in: .whitespaces)
        }
        if let open = name.lastIndex(of: "("), let close = name[open...].firstIndex(of: ")") {
            let inside = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if inside.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return inside }
            return name[..<open].trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// One card per style (`nil` = the plain card), all in parallel.
    /// Each card: one line per dish (up to four), merged when there are two
    /// or more; the user's note, if any, becomes its own sentence and is
    /// merged in last — the food line's frame bled a verdict into neutral
    /// facts when they shared a prompt.
    /// What a card is written about. A dish carries its own name into the
    /// sentence; a tag (전망, 분위기, 서비스) is a remark the person made about
    /// the place and names nothing — but both are the same shape by the time
    /// they reach the model: one remark, said better.
    struct Subject {
        let name: String
        let said: String
        /// Ask for the name in the sentence. True for dishes, false for tags —
        /// "전망을 문장에 넣어줘" would have the model write the word 전망.
        let byName: Bool
        /// Only dishes get the dictionary's two turns.
        var looksUp: Bool { byName }
    }

    static func drafts(
        dishes: [String],
        liked: Set<String>,
        /// "별로였다" from the thread's taste question.
        disliked: Set<String> = [],
        tags: [String] = [],
        /// What the place's menu says each dish is, by the name given.
        abouts: [String: String] = [:],
        /// "Shop name, City", for looking a dish up.
        place: String = "",
        /// The visit's own photos of the place, for the tag lines to write
        /// from. Without them a tag is an empty remark and gets filled in.
        placePhotos: [Data] = [],
        /// "저녁 · 이자카야": when and what kind of place, for the tag lines,
        /// which otherwise have nothing but the word to write from.
        setting: String = "",
        note: String?,
        styles: [ReviewGenre?],
        key: String,
        models: [String] = [model]
    ) async -> [GenreDraft]? {
        let names = Array(dishes.prefix(4))
        // One notch down on both: 정말 was being copied straight through — 8
        // of 41 drafts on disk used it twice in one sentence. 좋았다 → 괜찮았다 is
        // the riskier half and is not measured yet (좋았다 was chosen over 나쁘지
        // 않았다 by count: the lukewarm seed sent the model reaching for 기대 in
        // 7 of 18). The seed goes to the ledger so the next count can tell
        // them apart. (This is the line that runs; the same change sat in
        // an uncalled helper for a day.) Tags are one remark, not one line
        // each: two tag lines were merged by a call that knew no style, and
        // every card came out as the same "분위기와 서비스가 모두 좋아서 기분 좋게 즐겼다".
        let tagRemark: [Subject] = tags.isEmpty ? [] : {
            let picked = Array(tags.prefix(3))
            let said: String
            if english {
                let words = picked.map { ["전망": "the view", "분위기": "the atmosphere", "서비스": "the service"][$0] ?? $0 }
                let list = words.count == 1 ? words[0] : words.dropLast().joined(separator: ", ") + " and " + words.last!
                said = (list.prefix(1).uppercased() + list.dropFirst()) + (words.count == 1 ? " was great" : " were great")
            } else {
                said = picked.count == 1 ? "\(picked[0]) 좋았다" : picked.map { $0 + "도" }.joined(separator: " ") + " 좋았다"
            }
            return [Subject(name: picked.joined(separator: "·"), said: said, byName: false)]
        }()
        var written: [String: String] = [:]
        for name in names { written[name] = await koreanName(spoken(name)) }
        let said = names.map { name in
            Subject(name: written[name] ?? spoken(name),
                    said: english ? (liked.contains(name) ? "It was delicious" : disliked.contains(name) ? "It was disappointing" : "It was fine")
                                  : (liked.contains(name) ? "맛있었다" : disliked.contains(name) ? "별로였다" : "괜찮았다"), byName: true)
        } + tagRemark
        // No dish remembered and nothing else said: a light, general remark
        // about the meal still makes cards to start from (기억 안 나요 left the
        // draft question with nothing to pick).
        let parts = !said.isEmpty ? said
            : [Subject(name: english ? "the meal" : "식사", said: english ? "It was a good meal" : "잘 먹었다", byName: false)]
        Usage.local(tag: "초안 씨앗", detail: parts.map(\.said).joined(separator: " / "), seconds: 0)
        // The dish descriptions are fetched once and handed to every model, so
        // a side-by-side comparison differs only in the writing.
        var turns: [String: [[String: Any]]] = [:]
        await withTaskGroup(of: (String, [[String: Any]]).self) { group in
            for subject in parts where subject.looksUp {
                let about = abouts[subject.name] ?? written.first { $0.value == subject.name }.flatMap { abouts[$0.key] }
                group.addTask { (subject.name, await descriptionTurns(for: subject.name, model: model, about: about, place: place)) }
            }
            for await (name, t) in group { turns[name] = t }
        }
        report?(.writing)
        // The dishes are written about together, in one line from one
        // writer: written one by one and merged, two dishes came back opening
        // the same way and the merge kept both openings. Each
        // dish's description turn still comes first.
        let dishParts = parts.filter(\.byName)
        var subjects = parts
        if dishParts.count > 1 {
            let together = together(dishParts)
            turns[together.name] = dishParts.flatMap { turns[$0.name] ?? [] }
            subjects = [together] + parts.filter { !$0.byName }
        }
        let facts = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sharedTurns = turns
        let lineSubjects = subjects

        @Sendable func write(_ style: ReviewGenre?, _ writer: String) async -> GenreDraft? {
            // One card in seven is told to name the dish. Told every time,
            // the model opened every line with it ("마늘갈비살, …", 14 of 14);
            // never told, it wrote around it (13 of 14 without the name).
            // The mix: 6:1, at random, per card.
            let mentionName = Int.random(in: 0..<7) == 0
            var food: String
            if lineSubjects.count == 1 {
                let subject = lineSubjects[0]
                var prompt = lead(subject, setting: setting) + (english ? " In one or two lines." : " 한두줄로.")
                if subject.byName {
                    prompt += mentionName ? " (Mention \(subject.name) by name in the sentence. Write in \(english ? "English" : "Korean").)"
                        : " (Write in \(english ? "English" : "Korean").)"
                }
                else { prompt += photoRule(placePhotos) }
                if let style { prompt += (english ? " Style: \(style.written)." : " 문체는 \(style.written).") + " (Never mention the style name in the text.)" }
                prompt += marker
                food = await line(history: sharedTurns[subject.name] ?? [], prompt: prompt, style: style, tag: "food",
                                  photos: subject.byName ? [] : placePhotos, model: writer)
            } else {
                var lines: [String] = []
                await withTaskGroup(of: (Int, String).self) { lineGroup in
                    for (i, subject) in lineSubjects.enumerated() {
                        lineGroup.addTask {
                            var prompt = lead(subject, setting: setting) + (english ? " In one line." : " 한줄로.")
                            prompt += subject.byName
                                ? (mentionName ? " (Mention \(subject.name) by name in the sentence. Write the sentence in \(english ? "English" : "Korean").)"
                                    : " (Write the sentence in \(english ? "English" : "Korean").)")
                                : photoRule(placePhotos)
                            prompt += marker
                            if let style { prompt += (english ? " Style: \(style.written)." : " 다음 문체로: \(style.written).") + " (Never mention the style name in the text.)" }
                            return (i, await line(history: sharedTurns[subject.name] ?? [], prompt: prompt, style: style,
                                                  tag: subject.byName ? "dish\(i + 1)" : "tag/\(subject.name)",
                                                  photos: subject.byName ? [] : placePhotos, model: writer))
                        }
                    }
                    var ordered = [String](repeating: "", count: lineSubjects.count)
                    for await (i, text) in lineGroup { ordered[i] = text }
                    // A line that did not come back leaves the card out:
                    // the dish without the place is not what was said.
                    lines = ordered.contains(where: \.isEmpty) ? [] : ordered
                }
                if lines.count < 2 {
                    food = lines.first ?? ""
                } else {
                    let tongue = english ? "English" : "Korean"
                    var merge = "Below are one-line \(tongue) reviews of the same visit — each about a different dish, or about the place itself. Merge them into ONE natural \(tongue) review. Keep every dish name and its specific sensory details. Connect the sentences smoothly. Do not invent new facts, do not echo any wording from these instructions, and do not add framing like which restaurant or how it was ordered. Output \(tongue) only."
                    // The lines were written in a style; the merge keeps it.
                    // Without this every card's merge came out in one plain
                    // voice.
                    if let style { merge += " Keep the writing style of the lines: \(style.written). (Never mention the style name in the text.)" }
                    merge += "\n\n" + lines.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
                    let merged = await line(history: [], prompt: merge, style: style, tag: "merge", model: writer)
                    food = merged.isEmpty ? lines.joined(separator: " ") : merged
                }
            }
            guard !food.isEmpty else { return nil }
            var text = withoutDishHeading(food, names: parts.map(\.name))
            if !facts.isEmpty {
                var prompt = english
                    ? "(\(facts)) That is what happened. Write one or two lines about it for the review, in English."
                    : "(\(facts)) 이런 상황이었어. 후기에 넣을 문장 한두줄로 써봐."
                if let style { prompt += (english ? " Style: \(style.written)." : " 문체는 \(style.written).") + " (Never mention the style name in the text.)" }
                prompt += marker
                let context = await line(history: [], prompt: prompt, style: style, tag: "note", model: writer)
                if !context.isEmpty {
                    let merged = await line(history: [], prompt:
                        (english
                            ? "Merge the two sentences below into one natural review, in English. Keep the voice; add nothing that is not there." + (style.map { " Keep the style: \($0.written). (Never mention the style name in the text.)" } ?? "")
                            : "아래 두 문장을 자연스럽게 하나의 후기로 합쳐줘. 말투는 그대로 두고, 없는 내용 더하지 마." + (style.map { " 문체는 \($0.written) 그대로. (Never mention the style name in the text.)" } ?? ""))
                            + "\n\n1) \(food)\n2) \(context)",
                        style: style, tag: "merge-note", model: writer)
                    text = merged.isEmpty ? food + " " + context : merged
                }
            }
            let genre = style ?? plain
            return GenreDraft(genre: genre.name, note: genre.note, text: text,
                              model: writer)
        }

        // Shuffled per style: the same model must not always be on top, or
        // the blind pick turns into a position habit.
        let jobs = styles.enumerated().flatMap { index, style in
            models.shuffled().enumerated().map { (index * models.count + $0.offset, style, $0.element) }
        }
        let results: [GenreDraft?] = await withTaskGroup(of: (Int, GenreDraft?).self) { group in
            for (slot, style, writer) in jobs {
                group.addTask { (slot, await write(style, writer)) }
            }
            var ordered = [GenreDraft?](repeating: nil, count: jobs.count)
            for await (slot, draft) in group { ordered[slot] = draft }
            return ordered
        }
        let drafts = results.compactMap { $0 }
        return drafts.isEmpty ? nil : drafts
    }

    /// One call → one cleaned line. The prompt is logged verbatim so the
    /// exact wording that produced a card is always in app.log.
    private static func line(history: [[String: Any]], prompt: String, style: ReviewGenre?, tag: String,
                             photos: [Data] = [], model: String = ReviewDrafter.model) async -> String {
        print("[ReviewDraft/\(style?.name ?? "담백")/\(tag)] " + prompt.replacingOccurrences(of: "\n", with: " / "))
        // A dish carries its own meaning in its name. A tag does not: told only
        // "전망 좋았다", the model filled the gap itself — a window, a view from
        // a house it decided you were in. So the tag lines are shown the
        // photos and told to write from those.
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        for jpeg in photos.prefix(3) {
            content.append(["type": "input_image", "detail": "high",
                            "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
        }
        let message: [String: Any] = photos.isEmpty
            ? ["role": "user", "content": prompt]
            : ["role": "user", "content": content]
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "none"],
            "input": history + [message],
            "max_output_tokens": 400,
        ]
        guard let raw = await call(body, tag: "ReviewDraft/\(style?.name ?? "담백")/\(tag)") else { return "" }
        return stripGenreLabel(firstCandidate(raw), genre: style?.name ?? "")
    }

    /// The text between the *^ markers the prompt asks for; failing that,
    /// the whole answer without markdown dressing. Whitespace runs — line
    /// breaks included — collapse to one space, as the predecessor's
    /// parser did: a
    /// review is one paragraph unless the writer really changes subject,
    /// and a model's stray line break was carried into the English too.
    private static func firstCandidate(_ raw: String) -> String {
        if let range = raw.range(of: #"(?:\*\^|\^\*)([\s\S]*?)(?:\^\*|\*\^)"#, options: .regularExpression) {
            let inner = raw[range].dropFirst(2).dropLast(2)
            let cleaned = oneParagraph(inner.replacingOccurrences(of: "**", with: ""))
            if cleaned.count >= 4 { return cleaned }
        }
        return oneParagraph(raw.replacingOccurrences(of: "*^", with: "").replacingOccurrences(of: "^*", with: "")
            .replacingOccurrences(of: "**", with: ""))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    }

    private static func oneParagraph(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A model sometimes heads the text with the style ("정통 맛칼럼:",
    /// "[짧은 시]", a title line). The review must start with itself.
    /// A first line that is only the dish's name — a heading the model put
    /// above the review. It is removed only when the line IS the name (or the
    /// names joined), never when it is a sentence that begins with one, so a
    /// poem opening on the dish keeps its line.
    static func withoutDishHeading(_ text: String, names: [String]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return text }
        let head = lines[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t*#[]()「」【】:：-·,")).lowercased()
        guard !head.isEmpty else { return text }
        let flat = { (s: String) in s.filter { !$0.isWhitespace && $0 != "," }.lowercased() }
        let candidates = names.map(flat) + [flat(names.joined())]
        guard candidates.contains(flat(head)) else { return text }
        lines.removeFirst()
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    static func stripGenreLabel(_ text: String, genre: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first?.trimmingCharacters(in: .whitespaces) {
            let bare = first.trimmingCharacters(in: CharacterSet(charactersIn: "[]()「」【】*#:- ·"))
            if !genre.isEmpty, bare == genre || bare.isEmpty && lines.count > 1 { lines.removeFirst(); continue }
            if !genre.isEmpty, first.hasPrefix(genre + ":") || first.hasPrefix(genre + " :") || first.hasPrefix(genre + "：") || first.hasPrefix("[" + genre + "]") {
                lines[0] = String(first.drop(while: { $0 != ":" && $0 != "：" && $0 != "]" }).dropFirst()).trimmingCharacters(in: .whitespaces)
                break
            }
            if let range = first.range(of: #"^(?:문체|스타일|Style)\s*[:：]\s*"#, options: [.regularExpression, .caseInsensitive]) {
                lines[0] = String(first[range.upperBound...])
            }
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Korean → English, keeping the voice. English is a translation of the
    /// text the user actually chose and edited, so the two never disagree.
    static func translate(_ korean: String, dishes: [String] = [], key: String) async -> String? {
        // Kept apart from the review, and labelled. Run together under the
        // instruction, the model read the spellings as the first line of the
        // text and translated them into the top of the review — a menu name
        // alone above an English review that the Korean never had.
        let menuNames = dishes.isEmpty ? "" :
            "=== REFERENCE, NOT PART OF THE REVIEW — never translate or print these lines ===\n"
            + "Menu spellings (Korean = the menu's own English, where it printed one): "
            + dishes.joined(separator: "; ") + "\n"
        let instruction = """
        Translate this Korean restaurant review into natural English for Google Maps. Keep the meaning, the facts, the length and the voice (if it is a poem, keep it a poem; if it is deadpan, stay deadpan). Dish names: when the menu's own English is given below, use it, with four corrections. (1) Write "&" as "and" when it joins ingredients ("Meat and Chipotle Burrito Bowl"). (2) Fix a spelling mistake only when you are certain it is one ("Chicken Brest" → "Chicken Breast"); a name that could be a proper noun or a play on words stays exactly as printed. (3) For a set or combo, name the main dish and say it is a set ("Soft Taco set"), not the whole list. (4) Keep the Korean in parentheses the first time ONLY for a Korean dish whose English is a transliteration (jokbal (족발), bingsu (빙수)); never for a dish with an ordinary English name (no "Burrito Bowl (부리또 볼)"). When no English is given, use the common English name under the same four rules. Keep the source's line structure exactly: the same number of lines and paragraphs, one English sentence per Korean sentence where the Korean has one; never add line breaks the Korean does not have, and never split a paragraph into lines. Return only the translation.


        """
        let text = instruction + menuNames
            + "=== THE REVIEW TO TRANSLATE — output this and nothing else ===\n" + korean
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": [["type": "input_text", "text": text]]]],
            "max_output_tokens": 900,
        ]
        guard let english = await call(body, tag: "Translate")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return withoutReferenceHeading(english, dishes: dishes, lines: korean.split(separator: "\n").count)
    }

    /// The English came back one line longer than the Korean, and that extra
    /// first line was the reference list. Drop it — but only when the Korean
    /// really is shorter and the line really is the list.
    private static func withoutReferenceHeading(_ english: String, dishes: [String], lines: Int) -> String {
        var out = english.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard out.count > 1, let first = out.first else { return english }
        _ = lines
        // Only a line that IS the reference list. Mentioning a dish is not
        // enough — a translation mentions the dish, and this rule ate one
        // whole, leaving nothing behind but the visit date.
        let head = first.lowercased()
        let namesOnly = dishes.count > 1 && first.contains(";")
            && !first.contains(".") && first.count <= 200
        // A first line that is only a dish's name, in either language, is the
        // same heading the Korean side strips — "Baekban" sitting above its
        // own review.
        let flat = { (text: String) in text.filter { !$0.isWhitespace }.lowercased() }
        let names = dishes.flatMap { $0.split(separator: "=").map { String($0).trimmingCharacters(in: .whitespaces) } }
        let bareName = names.contains { !$0.isEmpty && flat($0) == flat(first) }
        guard head.hasPrefix("menu spelling") || head.hasPrefix("reference")
                || head.hasPrefix("===") || namesOnly || bareName else { return english }
        out.removeFirst()
        while let next = out.first, next.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        return out.joined(separator: "\n")
    }

    /// A Responses-API body rewritten for xAI's chat completions: turns become
    /// messages, input_text/input_image become text/image_url, the token cap
    /// and any JSON schema keep their meaning, and `reasoning` is dropped
    /// (the non-reasoning model has none).
    private static func xaiBody(_ body: [String: Any]) -> [String: Any] {
        let turns = body["input"] as? [[String: Any]] ?? []
        let messages: [[String: Any]] = turns.map { turn in
            var message: [String: Any] = ["role": turn["role"] ?? "user"]
            if let parts = turn["content"] as? [[String: Any]] {
                message["content"] = parts.compactMap { part -> [String: Any]? in
                    switch part["type"] as? String {
                    case "input_text": return ["type": "text", "text": part["text"] ?? ""]
                    case "input_image": return ["type": "image_url",
                                                "image_url": ["url": part["image_url"] ?? "", "detail": part["detail"] ?? "high"]]
                    default: return nil
                    }
                }
            } else {
                message["content"] = turn["content"] ?? ""
            }
            return message
        }
        var out: [String: Any] = ["model": body["model"] ?? "", "messages": messages]
        if let cap = body["max_output_tokens"] { out["max_tokens"] = cap }
        if let text = body["text"] as? [String: Any], let format = text["format"] as? [String: Any],
           format["type"] as? String == "json_schema" {
            out["response_format"] = ["type": "json_schema", "json_schema": [
                "name": format["name"] ?? "out", "strict": format["strict"] ?? true, "schema": format["schema"] ?? [:]]]
        }
        return out
    }

    private static func call(_ body: [String: Any], tag: String) async -> String? {
        let model = body["model"] as? String ?? ""
        let grok = model.hasPrefix("grok")
        let vendor = grok ? "xAI" : "OpenAI"
        guard let key = grok ? PlaceMatcher.xaiKey : PlaceMatcher.openAIKey else { print("[\(tag)] no \(vendor) key"); return nil }
        let started = Date()
        let answer: (Data, Int)?
        if grok {
            var request = URLRequest(url: xaiEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: xaiBody(body))
            request.timeoutInterval = 120
            answer = (try? await URLSession.shared.data(for: request)).map { ($0.0, ($0.1 as? HTTPURLResponse)?.statusCode ?? 0) }
        } else {
            // OpenAI calls go through the shared transport: on the ChatGPT
            // plan when signed in, on the key otherwise.
            answer = await OpenAITransport.post(body, apiKey: key, timeout: 120, tag: tag)
        }
        guard let (data, status) = answer else {
            Usage.failed(tag: tag, model: model, reason: Task.isCancelled ? "cancelled" : "unreachable", seconds: -started.timeIntervalSinceNow)
            print("[\(tag)] \(vendor) unreachable")
            return nil
        }
        let seconds = -started.timeIntervalSinceNow
        guard status == 200 else {
            Usage.failed(tag: tag, model: model, reason: "http \(status)", seconds: seconds)
            print("[\(tag)] \(vendor) HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[\(tag)] \(vendor) response did not decode")
            return nil
        }
        if grok {
            // Chat-completions shape; the usage block is renamed into the
            // Responses shape so Usage prices and logs it like the others.
            guard let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                print("[\(tag)] xAI response had no text")
                return nil
            }
            let u = root["usage"] as? [String: Any]
            let usage: [String: Any] = [
                "input_tokens": u?["prompt_tokens"] ?? 0,
                "output_tokens": u?["completion_tokens"] ?? 0,
                "input_tokens_details": ["cached_tokens": (u?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] ?? 0],
            ]
            Usage.openAI(tag: tag, model: root["model"] as? String ?? model, usage: usage, output: [], seconds: seconds)
            return text
        }
        guard let output = root["output"] as? [[String: Any]] else {
            print("[\(tag)] OpenAI response did not decode")
            return nil
        }
        Usage.openAI(tag: tag, model: root["model"] as? String ?? model,
                     usage: root["usage"] as? [String: Any], output: output, seconds: seconds)
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        print("[\(tag)] OpenAI response had no text")
        return nil
    }
}
