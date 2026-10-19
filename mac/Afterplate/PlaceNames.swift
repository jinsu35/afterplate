import Foundation

/// A place's name in a script the app's reader can read. Google gives a
/// listing's own name when it has none in the asked language — a 쌈밥 house's
/// Hangul name in the English app, 一蘭 or ร้านเจ๊ไฝ anywhere — so such a
/// name is shown with a reading in front of it: "Ssambap House (쌈밥집)". The
/// original stays, since it is what the listing says on Google when the
/// review is posted (not only Korean: reviewers travel).
@MainActor
enum PlaceNames {
    /// Original name → reading, per app language, kept across launches.
    private static var readings: [String: String] = load()
    private static var asking: Set<String> = []

    private static var file: URL {
        AppData.folder.appendingPathComponent("place-readings-\(AppLanguage.current.isEnglish ? "en" : "ko").json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// The name as the app shows it.
    static func shown(_ name: String) -> String {
        guard let reading = readings[name], !reading.isEmpty, reading != name else { return name }
        return "\(reading) (\(name))"
    }

    /// Has letters outside what the app's reader reads: Latin for the English
    /// app, Hangul and Latin for the Korean one.
    nonisolated static func needsReading(_ name: String) -> Bool {
        let korean = !AppLanguage.current.isEnglish
        return name.unicodeScalars.contains { s in
            guard s.properties.isAlphabetic else { return false }
            let v = s.value
            let latin = v < 0x250 || (0x1E00...0x1EFF).contains(v) || (0xFF21...0xFF5A).contains(v)
            let hangul = (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
            return !(latin || (korean && hangul))
        }
    }

    /// Gets readings for the names that need one and have none, in one call.
    /// The views redraw through the library when they come in.
    static func fill(_ names: [String], library: PhotoLibrary? = nil) async {
        let all = Array(Set(names.filter { needsReading($0) && readings[$0] == nil && !asking.contains($0) })).sorted()
        // Forty names a call.
        for start in stride(from: 0, to: all.count, by: 40) {
            await ask(Array(all[start..<min(start + 40, all.count)]), library: library)
        }
    }

    private static func ask(_ wanted: [String], library: PhotoLibrary?) async {
        guard !wanted.isEmpty, let key = PlaceMatcher.openAIKey else { return }
        asking.formUnion(wanted)
        defer { asking.subtract(wanted) }
        let language = AppLanguage.current.isEnglish ? "English" : "Korean"
        let script = AppLanguage.current.isEnglish ? "the Latin alphabet" : "Hangul"
        let prompt = """
        These are restaurant and cafe names as their listings give them. For each, write how a \(language)-speaking diner would say the name, in \(script): the sound of the name in the usual romanization or transcription (Revised Romanization for Korean, Hepburn for Japanese, Pinyin for Mandarin, the common one for others), words separated and capitalised the way a sign would be (산골쌈밥 → Sangol Ssambap, 一蘭 → Ichiran). Keep a part already in \(script) as it is. Do not translate the name into a description and do not add anything.

        \(wanted.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["names": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "properties": ["name": ["type": "string"], "reading": ["type": "string"]],
                "required": ["name", "reading"],
            ]]],
            "required": ["names"],
        ]
        let body: [String: Any] = [
            "model": PlaceMatcher.smallModel,
            "reasoning": ["effort": "none"],
            "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "text": ["format": ["type": "json_schema", "name": "place_readings", "strict": true, "schema": schema]],
            "max_output_tokens": 2000,
        ]
        struct Raw: Decodable { struct Name: Decodable { let name: String; let reading: String }; let names: [Name] }
        guard let text = await OpenAICall.text(body, key: key, tag: "PlaceNames"),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return }
        for item in raw.names where wanted.contains(item.name) {
            let reading = item.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            // A reading still in the other script is no reading.
            if !reading.isEmpty, !needsReading(reading) { readings[item.name] = reading }
        }
        if let data = try? JSONEncoder().encode(readings) { try? data.write(to: file, options: .atomic) }
        library?.objectWillChange.send()
    }
}
