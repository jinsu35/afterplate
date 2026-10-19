import Foundation

/// A menu item as read off a menu photo.
struct MenuItem: Codable, Hashable {
    /// Exactly as the menu prints it, whatever language that is.
    let name: String
    let price: String
    let section: String
    /// The same dish in the app's language, when the printed name is in
    /// another one — a Japanese menu read in Tokyo is unreadable in a Korean
    /// review. Empty when the printed name is already Korean.
    var localName: String? = nil
    /// Where the name was seen (공식 홈페이지, 뽈레, 배민…), when it came from
    /// the web search.
    var source: String? = nil
    /// What a Korean review calls it, from the menu search: no shop name in
    /// front, no option in brackets, and a meaning for a name a Korean
    /// diner would not follow — Bistecca alla Fiorentina → 피렌체식 티본
    /// 스테이크. Nil for menus read before it existed.
    var review: String? = nil
    /// The dish in English, for the English app, when the menu was read in
    /// Korean or printed in another script (島豚あぐーのねぎしゃぶしゃぶ →
    /// Agu Pork Green Onion Shabu-Shabu). Filled once per menu by
    /// `MenuEnglish`; nil until then.
    var english: String? = nil
    /// What the dish is, in a line, from the menu or the page it was found
    /// on, for a name that does not say it ("House Trio" → Portuguese
    /// sausage, Spam and bacon with eggs and rice). The draft's
    /// description of the dish starts from it.
    var about: String? = nil

    /// What the app shows and writes: the Korean name when the menu printed
    /// one, otherwise the app-language rendering, otherwise as printed —
    /// without a bracketed option or note ("곱창 라면 (매운맛)" → 곱창 라면).
    var shown: String {
        // The English app shows the English the menu printed, or an English
        // reading, never the Korean one.
        if AppLanguage.current.isEnglish {
            let split = MenuName.split(name)
            if !split.english.isEmpty, !split.korean.isEmpty { return MenuName.withoutNote(split.english) }
            if let english, !english.isEmpty { return MenuName.withoutNote(english) }
            if let localName, !localName.isEmpty, !MenuName.hasHangul(localName) { return MenuName.withoutNote(localName) }
            return MenuName.withoutNote(name)
        }
        if let korean = MenuName.bracketKorean(name) { return korean }
        let split = MenuName.split(name)
        if !split.korean.isEmpty { return MenuName.withoutNote(split.korean) }
        if let localName, !localName.isEmpty { return MenuName.withoutNote(localName) }
        return MenuName.withoutNote(name)
    }

    /// The printed name when it is not what `shown` says — "Pan Con
    /// Tomate" under 판콘 토마테, "곱창 라면 (매운맛)" under 곱창 라면 — for the
    /// small line under a menu chip.
    var printedOther: String? {
        // English app: the name as printed, when it is not the English shown.
        if AppLanguage.current.isEnglish {
            let printed = MenuName.withoutNote(name)
            return printed.isEmpty || printed == shown || MenuName.hasHangul(printed) ? nil : printed
        }
        let split = MenuName.split(name)
        let other = split.korean.isEmpty ? name : (split.english.isEmpty ? name : split.english)
        return other.isEmpty || other == shown ? nil : other
    }
}

/// Reads menu photos into items. Verified on a pizzeria's four
/// user-uploaded
/// menu photos: 24 items with sections and prices, nothing invented.
enum MenuReader {
    private static var prompt: String {
        guard AppLanguage.current.isEnglish else { return korean }
        return korean.replacingOccurrences(of: "localName: the same dish written in Korean, short, the way a Korean diner would say it (ミートソーススパゲティ → 미트소스 스파게티). Leave it empty when the printed name is already Korean.",
                                           with: "localName: the same dish written in English, short (ミートソーススパゲティ → Meat Sauce Spaghetti). Leave it empty when the printed name is already English.")
    }
    private static let korean = """
    These are photos of one restaurant's menu. Return every menu item exactly as printed (keep both languages if both are printed, e.g. "Quattro Funghi (콰트로 풍기)"), its price as printed or an empty string, and the section heading it sits under or an empty string. Skip descriptions and ingredients. Deduplicate across photos. Do not add anything that is not printed.

    localName: the same dish written in Korean, short, the way a Korean diner would say it (ミートソーススパゲティ → 미트소스 스파게티). Leave it empty when the printed name is already Korean. This is a reading of the printed name, not a new dish: never add an item that is not on the menu.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "items": [
                "type": "array",
                "maxItems": 120,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "price": ["type": "string"],
                        "section": ["type": "string"],
                        "localName": ["type": "string"],
                    ],
                    "required": ["name", "price", "section", "localName"],
                ],
            ],
        ],
        "required": ["items"],
    ]

    private struct Raw: Decodable { let items: [MenuItem] }

    static func read(jpegs: [Data], key: String) async -> [MenuItem]? {
        guard !jpegs.isEmpty else { return [] }
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        for jpeg in jpegs {
            content.append(["type": "input_image", "detail": "high", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
        }
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "menu_items", "strict": true, "schema": schema]],
            "max_output_tokens": 3000,
        ]
        guard let text = await OpenAICall.text(body, key: key, tag: "MenuReader"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        return raw.items
    }
}

/// Names the dishes in a visit's photos with the restaurant's own menu words.
///
/// The menu comes from the place's Google Maps page (`MenuFetcher`): the
/// popular-dish highlights and the user-uploaded menu photos, which
/// `MenuReader` turns into items. Each photo is judged on its own: what kind
/// of photo it is, and the ONE dish it is mainly of. A dish gets a menu name
/// only when it clearly matches; otherwise a plain description that the user
/// sees as a suggestion, not a fact. Nothing is invented.
///
/// Why per photo rather than per dish: the first pass named dishes and listed
/// photos per dish; the salad "appeared" in the corner of the pizza photo,
/// claimed it first, and the pizza photo ended up captioned 시저샐러드.
///
/// Why several names per photo: a tray at a bakery-café held a chocolate
/// cookie, a latte and a pistachio drink, and the prompt asked for "the
/// ONE dish the photo is mainly of" — so the review would have mentioned
/// the cookie and forgotten what was drunk with it.
struct DishNaming: Codable {
    enum Kind: String, Codable {
        case food       // a dish, served
        case eaten      // the same table after eating — plates, crumbs
        case place      // the room, the front, the view, people
        case other
    }
    struct Dish: Codable {
        let name: String
        /// What a review calls it: the menu name without the shop's own name
        /// in front, with the dish's form when the name leaves it out —
        /// "Daybreak Breakfast Grilled Chicken" → 그릴드 치킨 샌드위치.
        var review: String? = nil
        var reviewName: String { (review?.isEmpty == false ? review : nil) ?? name }
        /// true when the name is a menu item or highlight, verbatim, and the
        /// photo bears it out. False marks it as the model's own description.
        let fromMenu: Bool
        /// What in the photo decided it, in a few words. Written before the
        /// call is made: a name a person could not defend out loud is a guess.
        let shows: String
    }
    struct PhotoNaming: Codable {
        let photoID: String
        let kind: Kind
        /// Everything ordered in this photo, in the order it reads — empty for
        /// place/other, or when nothing is recognisable.
        let dishes: [Dish]
        /// true when every name came off the menu.
        var fromMenu: Bool { !dishes.isEmpty && dishes.allSatisfy(\.fromMenu) }
        /// Degrees to turn the photo clockwise so it reads naturally
        /// (0/90/180/270). Phones held flat over a table tag such shots by
        /// their last known orientation, and the file stays wrong forever.
        let rotate: Int
    }
    let photos: [PhotoNaming]
}

enum MenuNamer {
    /// In the app's language: the English app's own names and review names
    /// are English (Korean dish names in the English app).
    private static var prompt: String {
        guard AppLanguage.current.isEnglish else { return korean }
        return [
            ("your own plain Korean name", "your own plain English name"),
            ("your own plain Korean words", "your own plain English words"),
            ("(스무디, 음료, 디저트, 커피)", "(smoothie, drink, dessert, coffee)"),
            ("The name to write in a Korean review, in Korean:", "The name to write in an English review, in English:"),
            ("\"그릴드 치킨 샌드위치\"", "\"Grilled Chicken Sandwich\""),
            ("in three or four Korean words (택에 적힌 글자, 위에 올린 견과, 접시에 남은 뼈…)", "in three or four English words (the text on a tag, the nuts on top, the bones left on the plate…)"),
            ("(예: ", "(e.g. "),
        ].reduce(korean) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
    private static let korean = """
    These photos are from one visit to the restaurant below. After them comes the restaurant's menu (from its Google Maps page: menu-photo items with prices, and popular dishes — or, when Google Maps has none, item names found on the web).

    Judge each photo on its own and return one entry per photo, in order:
    - kind: "food" if it mainly shows a dish as served, or a drink on its own (a smoothie, a latte, a cocktail — at a cafe or bar the drink is what the review is about); "eaten" if it mainly shows the table after eating (empty or mostly empty plates, crumbs, leftovers); "place" if it mainly shows the room, the storefront, the view, or people rather than food; "other" for anything else (receipt, menu board).
    - dishes: for "food", every DISH in the photo, one name each, the biggest first. A table with three plates is three names, not one. Leave out everything that is not a dish: water, cutlery, napkins, the free side dishes (반찬) that come with a Korean meal, sauces and dips, and the drinks standing beside the food — a coffee or a cola next to a meal is not what the review is about, and the person adds it themselves if it was. A drink photographed on its own IS the dish: name it. For "eaten", what was eaten if it is recognisable from what is left, else empty. For "place"/"other", empty.
    - each dish carries its own from_menu. true ONLY when the photo bears the menu name out — a label readable in the picture, printed ingredients that match what is visible, an unmistakable look — and then write the name verbatim as printed, keeping both spellings when both are printed (예: "Quattro Formaggi (콰트로 포르마지)").
      When the menu has nothing you can confirm for something in the photo, give your own plain Korean name for what you can see, with from_menu false. Do NOT reach for the nearest menu item to fill the gap: a menu name is read as fact, and a wrong one is worse than an honest description, which the user sees marked as a guess and can correct. Menus also carry names that say nothing about the thing (a drink called 배드오렌지), so the absence of a matching name means nothing is confirmed — not that you should pick the closest.
      Never leave dishes empty for a "food" photo, and never claim from_menu for a name that is not on the menu.
    - a name is EITHER a menu name you can confirm (from_menu true) OR your own plain Korean words for what you can see (from_menu false). Never copy a menu name into a from_menu false entry: a menu name with a question mark on it still puts that dish in the review, and the person reading the card cannot tell it was never on the table. Your own words say exactly as much as you know, and are corrected in one tap.
    - review: never a kind or heading on its own (스무디, 음료, 디저트, 커피) when the menu lists the specific item — name the item. The name to write in a Korean review, in Korean: the name without the restaurant's own name in front of it, and with the dish's form added when the name does not say it but the photo does ("Sunrise Breakfast Grilled Chicken" in a bun → "그릴드 치킨 샌드위치"). Same as name when nothing needs changing.
    - shows: the thing in the PHOTO that decides the name, in three or four Korean words (택에 적힌 글자, 위에 올린 견과, 접시에 남은 뼈…). Write it before deciding from_menu, and set from_menu true only if what you wrote would convince someone who cannot see the menu. A closed cup, something you cannot see into, or a colour several menu items share is not enough.
    - rotate: degrees (0, 90, 180 or 270) to turn the photo CLOCKWISE so it reads naturally. For a shot taken from above a table, natural means the diner's side at the bottom: chopsticks or cutlery lying along the bottom edge, the near edge of the tray or table at the bottom, a lap or body at the bottom, a facing seat at the top; text and logos readable. For other shots, gravity down (walls vertical, glasses upright, horizons level). 0 when it already reads naturally. Be decisive; most photos are 0.
    """

    private static let schema: [String: Any] = [
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
                        "index": ["type": "integer"],
                        "kind": ["type": "string", "enum": ["food", "eaten", "place", "other"]],
                        "dishes": [
                            "type": "array",
                            "maxItems": 4,
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "properties": [
                                    "name": ["type": "string"],
                                    "shows": ["type": "string"],
                                    "from_menu": ["type": "boolean"],
                                    "review": ["type": "string"],
                                ],
                                "required": ["name", "shows", "from_menu", "review"],
                            ],
                        ],
                        "rotate": ["type": "integer", "enum": [0, 90, 180, 270]],
                    ],
                    "required": ["index", "kind", "dishes", "rotate"],
                ],
            ],
        ],
        "required": ["photos"],
    ]

    private struct Raw: Decodable {
        struct Photo: Decodable {
            struct Dish: Decodable { let name: String; let shows: String; let from_menu: Bool; let review: String }
            let index: Int; let kind: String; let dishes: [Dish]; let rotate: Int
        }
        let photos: [Photo]
    }

    /// `photos` are (id, jpeg) in the order sent; indices in the answer refer to them 1-based.
    static func name(
        photos: [(id: String, jpeg: Data)],
        place: PlaceCandidate,
        items: [MenuItem],
        highlights: [String],
        key: String
    ) async -> DishNaming? {
        var text = prompt + "\n\nRestaurant: \(place.name)"
        if let category = place.category { text += " (\(category))" }
        if !items.isEmpty {
            text += "\n\nMenu items:\n" + items.map { item in
                var line = "- \(item.name)"
                if AppLanguage.current.isEnglish, let english = item.english, !english.isEmpty { line += " (\(english))" }
                if !item.price.isEmpty { line += " \(item.price)" }
                if !item.section.isEmpty { line += " [\(item.section)]" }
                return line
            }.joined(separator: "\n")
        }
        if !highlights.isEmpty {
            text += "\n\nPopular dishes:\n" + highlights.map { "- \($0)" }.joined(separator: "\n")
        }
        text += "\n\nPhotos are numbered 1…\(photos.count) in the order given."
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for photo in photos {
            content.append(["type": "input_image", "detail": "high", "image_url": "data:image/jpeg;base64," + photo.jpeg.base64EncodedString()])
        }
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "photo_naming", "strict": true, "schema": schema]],
            "max_output_tokens": 900,
        ]
        guard let answer = await OpenAICall.text(body, key: key, tag: "MenuNamer"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(answer.utf8)) else { return nil }
        return DishNaming(photos: raw.photos.compactMap { entry in
            guard photos.indices.contains(entry.index - 1) else { return nil }
            var seen = Set<String>()
            let dishes = entry.dishes.compactMap { dish -> DishNaming.Dish? in
                let name = dish.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { return nil }
                return DishNaming.Dish(name: name,
                                       review: dish.review.trimmingCharacters(in: .whitespacesAndNewlines),
                                       fromMenu: dish.from_menu,
                                       shows: dish.shows.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return DishNaming.PhotoNaming(
                photoID: photos[entry.index - 1].id,
                kind: DishNaming.Kind(rawValue: entry.kind) ?? .other,
                dishes: dishes,
                rotate: [0, 90, 180, 270].contains(entry.rotate) ? entry.rotate : 0
            )
        })
    }
}

/// English names for a menu read in Korean or printed in another script,
/// for the English app (a Japanese menu found by the
/// Korean app showed its Japanese names). One small call per menu, only
/// the printed names sent; nothing is added that is not on the menu.
enum MenuEnglish {
    /// Whether the English app has nothing English to show for the item.
    static func needs(_ item: MenuItem) -> Bool {
        guard item.english?.isEmpty != false else { return false }
        let split = MenuName.split(item.name)
        if !split.english.isEmpty, !split.korean.isEmpty { return false }
        if let local = item.localName, !local.isEmpty, !MenuName.hasHangul(local) { return false }
        // Any script: Italian in Latin letters is no more English than
        // Greek is. A name already English comes back
        // as it is, and then it is not asked again.
        return true
    }

    /// Letters outside the Latin alphabets — Greek, Cyrillic, kana, Hangul,
    /// Han… (a Greek menu was taken for English, the first
    /// test only looked above the CJK range).
    static func notLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { c in
            c.properties.isAlphabetic && !(c.value < 0x0250 || (0x1E00...0x1EFF).contains(c.value))
        }
    }

    private struct Raw: Decodable { struct Item: Decodable { let printed: String; let english: String }; let items: [Item] }

    /// printed name → English, for the names asked about.
    static func names(_ printed: [String], place: String, key: String) async -> [String: String]? {
        guard !printed.isEmpty else { return [:] }
        let prompt = """
        These are menu items printed at \(place). For each, give the dish's name in English, short, the way an English menu would print it (島豚あぐーのねぎしゃぶしゃぶ → Agu Pork Green Onion Shabu-Shabu; 紅いもコロッケ → Purple Sweet Potato Croquette). Keep a proper name a diner would order by (Rafute, Champuru) and leave out promotions or notes around the dish (〖2H飲み放題付き♪〗, 期間限定). A name in another language written in Latin letters is translated the same way, keeping the dish's own name only where English diners know it by that name (Pizza Margherita, Spaghetti Carbonara, Tiramisu stay; Ribollita → Tuscan Bread and Vegetable Soup; Fiori di zucca fritti → Fried Zucchini Flowers). A name already in English is returned unchanged. Return every item, its printed name copied exactly.

        \(printed.joined(separator: "\n"))
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["items"],
            "properties": ["items": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["printed", "english"],
                "properties": ["printed": ["type": "string"], "english": ["type": "string"]],
            ] as [String: Any]] as [String: Any]],
        ]
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "text": ["format": ["type": "json_schema", "name": "menu_english", "strict": true, "schema": schema]],
            "max_output_tokens": 4000,
        ]
        guard let text = await OpenAICall.text(body, key: key, tag: "MenuEnglish"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        var out: [String: String] = [:]
        for item in raw.items where !item.english.trimmingCharacters(in: .whitespaces).isEmpty {
            out[item.printed] = item.english.trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

/// One Responses API call, returning the model's text. Shared by the menu
/// reader and namer; the matcher and drafter predate it and keep their own.
enum OpenAICall {
    static func text(_ body: [String: Any], key: String, tag: String, timeout: Double = 180) async -> String? {
        let started = Date()
        guard let (data, status) = await OpenAITransport.post(body, apiKey: key, timeout: timeout, tag: tag) else {
            Usage.failed(tag: tag, model: body["model"] as? String ?? "", reason: Task.isCancelled ? "cancelled" : "unreachable", seconds: -started.timeIntervalSinceNow)
            print("[\(tag)] OpenAI unreachable")
            return nil
        }
        let seconds = -started.timeIntervalSinceNow
        guard status == 200 else {
            Usage.failed(tag: tag, model: body["model"] as? String ?? "", reason: "http \(status)", seconds: seconds)
            print("[\(tag)] OpenAI HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            print("[\(tag)] OpenAI response did not decode")
            return nil
        }
        Usage.openAI(tag: tag, model: root["model"] as? String ?? body["model"] as? String ?? "",
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
