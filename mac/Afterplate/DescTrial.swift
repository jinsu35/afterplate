import Foundation

/// Runs the dish lookup (dictionary → learned → probe → forced search) on
/// names given in a file, so a dish missing from the dictionary can be
/// checked in both languages without waiting for a card.
///
/// `desc-trial.json` in the app's support folder:
/// `{"korean": ["…"], "english": ["…"]}`. Results go to
/// `desc-trial-results.json`; what is found is learned as in a draft.
enum DescTrial {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Afterplate", isDirectory: true)
    }

    struct Request: Decodable { let korean: [String]?; let english: [String]? }
    struct Result: Encodable { let dish: String; let english: Bool; let seconds: Double; let answer: String }

    @MainActor
    static func runIfAsked() async {
        let requestURL = folder.appendingPathComponent("desc-trial.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        try? FileManager.default.removeItem(at: requestURL)
        let asked = (request.korean ?? []).map { ($0, false) } + (request.english ?? []).map { ($0, true) }
        var results: [Result] = []
        for (dish, english) in asked {
            let started = Date()
            let answer = await ReviewDrafter.$forcedEnglish.withValue(english) { await ReviewDrafter.describe(dish) }
            let seconds = -started.timeIntervalSinceNow
            results.append(Result(dish: dish, english: english, seconds: (seconds * 10).rounded() / 10, answer: answer ?? "(못 찾음)"))
            Usage.local(tag: "음식 설명 확인", detail: "\(dish) · \(english ? "en" : "ko"): \(answer ?? "못 찾음")", seconds: seconds)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? encoder.encode(results).write(to: folder.appendingPathComponent("desc-trial-results.json"))
        }
    }
}
