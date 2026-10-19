import Foundation

/// 딥서치 — what does this place actually sell?
///
/// The first attempt sent one photo and asked "what is this called here". It
/// came back with "초코 쿠키": a description of the picture, not a name from a
/// menu. Tested side by side on a bakery-café, the same model with the same
/// settings, asked about the PLACE in words and told to leave the online
/// store out, found five of its cookies and scones by name, each with a
/// source. Carrying the photo made the model
/// look at the photo instead of researching the shop.
///
/// So the search is about the place and the photos are matched afterwards by
/// the namer, which is cheap and already knows how to read a table. Three
/// searches is the cap: without it the model ran five for $0.13 and came back
/// with less (weaker names, more hedging).
enum DishSearch {
    struct Found {
        let items: [MenuItem]
        /// One line for the person: where these names came from.
        let evidence: String
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "items": [
                "type": "array",
                "maxItems": 40,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "section": ["type": "string"],
                        "source": ["type": "string"],
                    ],
                    "required": ["name", "section", "source"],
                ],
            ],
            "note": ["type": "string"],
        ],
        "required": ["items", "note"],
    ]

    private struct Raw: Decodable {
        struct Item: Decodable { let name: String; let section: String; let source: String }
        let items: [Item]
        let note: String
    }

    /// Several photos in one call, each answered separately.
    ///
    /// Per photo it is one web search apiece: measured over 14 calls,
    /// DishSearch costs $0.045 and 7.1s every time, so a five-photo table ran
    /// to $0.23. Asked together it is one search and one answer — the images
    /// add tokens, not searches.
    ///
    /// The photo-carrying question is still the weaker one (see above: with a
    /// picture in the context the model describes it instead of researching
    /// the shop), so this is for what is LEFT after the place-wide search and
    /// the namer have had their turn, and it is told what the menu already
    /// says so it can pick from it rather than invent.
    struct PerPhoto {
        /// Photo index (as passed in) → the menu names seen in it.
        let names: [Int: [String]]
        let items: [MenuItem]
        let evidence: String
    }

    private static let perPhotoSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "photos": [
                "type": "array",
                "maxItems": 12,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "photo": ["type": "integer"],
                        "names": ["type": "array", "maxItems": 6, "items": ["type": "string"]],
                        "section": ["type": "string"],
                        "source": ["type": "string"],
                    ],
                    "required": ["photo", "names", "section", "source"],
                ],
            ],
            "note": ["type": "string"],
        ],
        "required": ["photos", "note"],
    ]

    private struct RawPerPhoto: Decodable {
        struct Shot: Decodable { let photo: Int; let names: [String]; let section: String; let source: String }
        let photos: [Shot]
        let note: String
    }

    static func find(jpegs: [Data], place: PlaceCandidate, known: [String],
                     language: String, key: String) async -> PerPhoto? {
        guard !jpegs.isEmpty else { return nil }
        let whereAt = [place.address, place.category].compactMap { $0 }.joined(separator: " · ")
        var text = """
        These \(jpegs.count) photos were all taken at one meal at: \(place.name)\(whereAt.isEmpty ? "" : " — \(whereAt)").
        They are numbered 1 to \(jpegs.count), in the order they are attached.
        Search the web ONCE OR TWICE for this place's menu — its own site or Instagram, delivery apps, Korean review pages and blogs — and then name what is in each photo using the names that menu prints.
        photo: the photo's number. names: one menu name per DISH in that photo, in \(language) — no descriptions, no prices. Skip drinks standing beside the food, sauces and free side dishes; only what a review would be about. A photo showing no food gets an empty list, and so does a photo whose dish you cannot tie to this place's menu — the nearest-sounding item is not an answer.
        section: the kind, or "". source: where the names were seen, three or four words.
        note: one short line in \(language) on what you found and how solid it is.
        """
        if !known.isEmpty {
            text += "\n\nAlready read from this place's menu (use one of these when it fits, spelled exactly):\n" + known.prefix(40).joined(separator: ", ")
        }
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for jpeg in jpegs.prefix(12) {
            content.append(["type": "input_image", "detail": "high",
                            "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
        }
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "tools": [["type": "web_search"]],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "photo_menu", "strict": true, "schema": perPhotoSchema]],
            "max_output_tokens": 3000,
        ]
        guard let answer = await OpenAICall.text(body, key: key, tag: "DishSearch/batch"),
              let raw = try? JSONDecoder().decode(RawPerPhoto.self, from: Data(answer.utf8)) else { return nil }
        var names: [Int: [String]] = [:]
        var items: [MenuItem] = []
        var seen = Set<String>()
        for shot in raw.photos {
            let index = shot.photo - 1
            guard jpegs.indices.contains(index) else { continue }
            let clean = shot.names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { continue }
            names[index] = clean
            for name in clean where !seen.contains(name) {
                seen.insert(name)
                items.append(MenuItem(name: name, price: "", section: shot.section))
            }
        }
        guard !names.isEmpty else { return nil }
        return PerPhoto(names: names, items: items,
                        evidence: raw.note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One photo, asked about on its own. The place-wide search is the better
    /// question most of the time — with a photo in the context the model
    /// describes the picture instead of researching the shop — but when a
    /// single dish is still unnamed after the menu came back, this is what is
    /// left to try.
    static func find(jpeg: Data, place: PlaceCandidate, known: [String], language: String, key: String) async -> Found? {
        let whereAt = [place.address, place.category].compactMap { $0 }.joined(separator: " · ")
        var text = """
        This photo was taken at: \(place.name)\(whereAt.isEmpty ? "" : " — \(whereAt)").
        Name everything ordered in the photo, using the names this place prints on its own menu. Search the web for that menu — the place's own site or Instagram, delivery apps, Korean review pages and blogs. Two or three searches, no more.
        name: one menu name per DISH, in \(language). No descriptions, no prices. Skip the drinks standing beside the food, the sauces and the free side dishes — only what the review would be about.
        section: the kind, or "" when unknown.
        source: where the name was seen, in three or four words.
        Only names an actual source shows for THIS place. If nothing on its menu matches what you see, return an empty list rather than the nearest-sounding item.
        note: one short line in \(language) on what you found and how solid it is.
        """
        if !known.isEmpty {
            text += "\n\nAlready read from this place's menu (use one of these if it fits, spelled exactly):\n" + known.prefix(40).joined(separator: ", ")
        }
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "tools": [["type": "web_search"]],
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": text],
                ["type": "input_image", "detail": "high", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()],
            ]]],
            "text": ["format": ["type": "json_schema", "name": "place_menu", "strict": true, "schema": schema]],
            "max_output_tokens": 2000,
        ]
        return await ask(body, key: key)
    }

    /// The whole menu from one press: three searches at once, each from its
    /// own side — the place's or brand's own pages, Korean reviews and
    /// directories, delivery apps and map listings — merged by name. One
    /// search alone listed whatever its first two pages showed, so every
    /// press came back different (a coffee chain: 7 English names, then 26
    /// Korean ones from another branch) and the person pressed again hoping
    /// for more. Photos are matched afterwards against the merged list
    /// by the namer, which needs no search.
    struct FullMenu {
        let items: [MenuItem]
        /// Each side's own line on what it found.
        let notes: [String]
        /// Sides that answered, of three.
        let answered: Int
    }

    /// One search, the place's own pages first. Measured on ten posted
    /// visits (the dish names posted with them as the answer key): the
    /// official/brand search alone found 14 of 19, the review and delivery
    /// searches 14 and 12, and all three together still 14 — while waiting
    /// for the slowest of three took a median 42s against 28s for this one.
    private static let angle = "가게 공식 홈페이지·공식 인스타그램의 메뉴를 찾아. 체인점이면 그 브랜드의 한국 공식 메뉴도."

    /// Short on purpose: on the ChatGPT plan a reply is written at about 60
    /// tokens a second, and five fields per dish made the writing most of
    /// the wait. Names come in groups by kind; a Korean or review name only
    /// where it differs from the printed one; sources once.
    private static let compactSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "groups": [
                "type": "array",
                "maxItems": 12,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "section": ["type": "string"],
                        "names": ["type": "array", "maxItems": 40, "items": ["type": "string"]],
                    ],
                    "required": ["section", "names"],
                ],
            ],
            "renamed": [
                "type": "array",
                "maxItems": 40,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "korean": ["type": "string"],
                        "review": ["type": "string"],
                    ],
                    "required": ["name", "korean", "review"],
                ],
            ],
            "about": [
                "type": "array",
                "maxItems": 40,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "about": ["type": "string"],
                    ],
                    "required": ["name", "about"],
                ],
            ],
            "sources": ["type": "array", "maxItems": 4, "items": ["type": "string"]],
            "note": ["type": "string"],
        ],
        "required": ["groups", "renamed", "about", "sources", "note"],
    ]

    private struct RawCompact: Decodable {
        struct Group: Decodable { let section: String; let names: [String] }
        struct Renamed: Decodable { let name: String; let korean: String; let review: String }
        struct About: Decodable { let name: String; let about: String }
        let groups: [Group]
        let renamed: [Renamed]
        let about: [About]?
        let sources: [String]
        let note: String
    }

    /// Under trial: for a place in Korea, send the search to Naver Place
    /// and Kakao Map menu tabs first — the one model that found one
    /// restaurant's menu found it there, the others stopped at
    /// Catchtable's
    /// category list.
    @TaskLocal static var naverHint = false

    /// Dishes that count toward "enough of a menu". At a restaurant the
    /// drinks do not: a wine bistro came back with two dishes and three
    /// wines and passed as five. At a café or a bar they are
    /// the menu.
    nonisolated static func foodCount(_ items: [MenuItem], category: String?) -> Int {
        let dishes = items.filter { PhotoLibrary.isDish($0.name) }
        let drinksPlace = (category ?? "").range(of: "카페|커피|바$|바 |bar|pub|와인|주점|술집|호프|베이커리|제과|디저트|cafe|coffee|bakery|dessert|tea|찻집",
                                                options: [.regularExpression, .caseInsensitive]) != nil
        guard !drinksPlace else { return dishes.count }
        let drink = "와인|wine|음료|드링크|drink|beverage|주류|술|칵테일|cocktail|맥주|beer|사케|sake|소주|위스키|whisky|whiskey|커피|coffee|에이드|ade|주스|juice|차$|tea|하이볼|highball|막걸리|전통주|스피릿|spirit|샴페인|champagne|sparkling|스파클링"
        return dishes.filter { item in
            [item.section, item.name].allSatisfy { $0.range(of: drink, options: [.regularExpression, .caseInsensitive]) == nil }
        }.count
    }

    static func findFullMenu(place: PlaceCandidate, key: String) async -> FullMenu? {
        let first = await searchMenu(place: place, key: key)
        // On Grok, 4.20 finds three dishes or fewer at some places where 4.7
        // finds twenty-odd in two or three minutes; the feed has time for
        // that. A trial's pinned model is left alone.
        let found = { (menu: FullMenu?) in foodCount(menu?.items ?? [], category: place.category) }
        guard Brain.current == .grok, OpenAITransport.grokModel == nil, found(first) <= 3 else { return first }
        Usage.local(tag: "메뉴 다시 찾기", detail: "\(place.name): \(found(first))개 → grok-4.7", seconds: 0)
        let deeper = await OpenAITransport.$grokModel.withValue("grok-4.7") {
            await searchMenu(place: place, key: key, timeout: 360)
        }
        return found(deeper) > found(first) ? deeper : first
    }

    /// Names to use other than as printed. In the English app, `korean`
    /// carries the English name and `review` the English review's name.
    private static var renamedLine: String {
        AppLanguage.current.isEnglish
            ? "renamed: only names not to be used as printed — every name not in English, without exception. korean: the dish's name in English (Pan Con Tomate → Bread with Tomato), else empty. review: the name an English review would use — without the shop's name in front, without bracketed options, and a foreign name a reader would not follow made clear (Bistecca alla Fiorentina → Florentine T-bone steak), else empty."
            : "renamed: 이름 그대로 쓰면 안 되는 메뉴만 — 외국어(영어 포함) 이름은 하나도 빠짐없이 넣어. korean: 외국어 이름의 한국어 이름(Pan Con Tomate → 판콘 토마테), 아니면 빈 칸. review: 한국어 리뷰에 쓸 이름 — 앞에 붙은 가게 이름 빼고(담가 마늘갈비살 → 마늘갈비살), 괄호 옵션 빼고, 뜻 모를 외국어는 뜻이 통하게(Bistecca alla Fiorentina → 피렌체식 티본 스테이크), 아니면 빈 칸."
    }

    /// What a dish is, for names that do not say it (a house-named plate
    /// was found on the menu, then searched for by its bare
    /// name and taken for a book).
    private static var aboutLine: String {
        AppLanguage.current.isEnglish
            ? "about: for each dish whose name alone does not say what it is (a house name like 'House Special #1' or 'Big Island Trio', or a name an English diner would not know), one short line on what it is — main ingredients and form — in English, from the menu's own description or the page you found it on. Leave out dishes with no description there; never guess."
            : "about: 이름만으로 뭔지 모를 메뉴('House Special #1', 'Big Island Trio' 같은 가게식 이름, 낯선 외국 요리)마다 무엇으로 만든 어떤 음식인지 한 줄, 한국어로 — 메뉴판의 설명이나 찾은 페이지에 적힌 대로. 설명이 없는 메뉴는 빼. 추측하지 마."
    }

    private static func searchMenu(place: PlaceCandidate, key: String, timeout: Double = 180) async -> FullMenu? {
        let whereAt = [place.address, place.category].compactMap { $0 }.joined(separator: " · ")
        let inKorea = (place.address ?? "").range(of: "[가-힣]", options: .regularExpression) != nil
        let naver = naverHint && inKorea ? "\n한국 가게라 네이버 플레이스와 카카오맵의 메뉴 탭을 먼저 찾아." : ""
        let text = """
        \(place.name)\(whereAt.isEmpty ? "" : " (\(whereAt))") 메뉴 알려줘. 음료·디저트까지, 많으면 대표 메뉴 위주로 40개까지.
        \(angle) 검색은 \(ClaudeAPI.searchLimit == 1 ? "한 번만" : "세 번까지").\(naver)
        groups: 종류별(샌드위치, 빵, 음료처럼)로 묶은 메뉴 이름, 가게가 쓰는 대로. 설명·가격·사이즈 없이. 분류나 탭 이름(메뉴 전체, 식사류, 주류, 추천메뉴, pizza, pasta, Salad & Brunch 같은 제목)은 메뉴가 아니니 이름에 넣지 마. 카테고리 목록밖에 못 찾았으면 그건 빼고 실제 요리 이름만.
        이 가게 것으로 확인된 메뉴만 넣어. 못 찾았으면 지어내지 말고 groups를 비워 둬 — 비슷한 가게나 흔한 메뉴로 채우지 마.
        \(renamedLine)
        \(aboutLine)
        sources: 메뉴를 본 곳, 서너 단어씩. note: 찾은 것과 얼마나 확실한지 한 줄.
        """
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "tools": [["type": "web_search"]],
            // Left to choose, grok-4.5 answered from memory with no search
            // and found nothing (in a trial, searches 0).
            "tool_choice": "required",
            "input": text,
            "text": ["format": ["type": "json_schema", "name": "menu", "strict": true, "schema": compactSchema]],
            "max_output_tokens": 3000,
        ]
        guard let answer = await OpenAICall.text(body, key: key, tag: "DishSearch/menu", timeout: timeout),
              let raw = try? JSONDecoder().decode(RawCompact.self, from: Data(answer.utf8)) else { return nil }
        var extra: [String: RawCompact.Renamed] = [:]
        for r in raw.renamed { extra[r.name.trimmingCharacters(in: .whitespacesAndNewlines)] = r }
        var abouts: [String: String] = [:]
        for a in raw.about ?? [] {
            let line = a.about.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { abouts[a.name.trimmingCharacters(in: .whitespacesAndNewlines)] = line }
        }
        let english = AppLanguage.current.isEnglish
        let source = raw.sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
        var seen = Set<String>()
        var items: [MenuItem] = []
        for group in raw.groups {
            // A section of section names — "카테고리: pizza, pasta, Salad &
            // Brunch" — is the site's tab list, not food.
            if group.section.range(of: #"카테고리|분류|탭|메뉴판|category|categories|tabs?"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil { continue }
            for printed in group.names {
                let name = printed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let more = extra[name]
                let korean = (more?.korean ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let review = (more?.review ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // In the English app the "korean" field holds the English.
                let item = MenuItem(name: name, price: "", section: group.section.trimmingCharacters(in: .whitespacesAndNewlines),
                                    localName: english || korean.isEmpty || korean == name ? nil : korean,
                                    source: source.isEmpty ? nil : source,
                                    review: review.isEmpty ? nil : review,
                                    english: english && !korean.isEmpty ? korean : nil,
                                    about: abouts[name])
                // One dish once, whatever its sizes: 수육 소 and 수육 대.
                guard seen.insert(item.shown).inserted else { continue }
                items.append(item)
            }
        }
        let note = raw.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // A menu put together from other places is not this place's menu:
        // Grok filled a café's menu with "nearby cafés and typical local
        // café items" and said so in its note. Nothing is better
        // than that — a review would name food the place does not serve.
        if note.range(of: #"참고해|참고하여|유사한 (가게|카페|식당|매장)|비슷한 (가게|카페|식당|매장)|일반적인 .*(메뉴|음료)|추정해|지어냈|지어서|가상"#,
                      options: .regularExpression) != nil {
            Usage.local(tag: "메뉴 결과 버림", detail: "\(place.name): 다른 가게로 채운 메뉴 — \(note.prefix(120))", seconds: 0)
            return FullMenu(items: [], notes: [note], answered: 1)
        }
        return FullMenu(items: items, notes: note.isEmpty ? [] : [note], answered: 1)
    }

    static func find(place: PlaceCandidate, language: String, key: String) async -> Found? {
        let whereAt = [place.address, place.category].compactMap { $0 }.joined(separator: " · ")
        // Asked plainly. The old question — "what a customer can buy
        // standing in the shop: the counter, the display case, the fridge",
        // only names a source shows, two or three searches — came back from
        // a bakery with twelve breads and none of its sandwiches; "메뉴 알려줘.
        // 메뉴 이름 전부." found them on the same model.
        let prompt = """
        \(place.name)\(whereAt.isEmpty ? "" : " (\(whereAt))") 메뉴 알려줘. 메뉴 이름 전부.
        name: 메뉴 이름 하나씩, 가게가 쓰는 대로. 설명·가격·사이즈 없이.
        section: 샌드위치, 빵, 음료처럼 종류.
        source: 그 이름을 본 곳, 서너 단어.
        note: 찾은 것과 얼마나 확실한지 한 줄.
        """
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "tools": [["type": "web_search"]],
            "input": prompt,
            "text": ["format": ["type": "json_schema", "name": "place_menu", "strict": true, "schema": schema]],
            "max_output_tokens": 3000,
        ]
        return await ask(body, key: key)
    }

    private static func ask(_ body: [String: Any], key: String) async -> Found? {
        guard let answer = await OpenAICall.text(body, key: key, tag: "DishSearch"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(answer.utf8)) else { return nil }
        var seen = Set<String>()
        let items = raw.items.compactMap { item -> MenuItem? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return MenuItem(name: name, price: "", section: item.section.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let sources = raw.items.map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seenSource = Set<String>()
        let where_ = sources.filter { seenSource.insert($0).inserted }.prefix(3).joined(separator: ", ")
        let note = raw.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Found(items: items, evidence: where_.isEmpty ? note : note + " (" + where_ + ")")
    }
}
