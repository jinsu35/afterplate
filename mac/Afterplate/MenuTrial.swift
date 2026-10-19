import Foundation

/// A side-by-side of Grok models on the menu search, run inside the app so it
/// goes on the linked Grok subscription.
///
/// Asked for by a file, `menu-trial.json` in the app's support folder:
/// `{"visits": ["<visit id>", …], "models": ["grok-4.20-non-reasoning", …]}`.
/// At launch the app runs the search once per visit and model, one at a time
/// so the timings are comparable, writes `menu-trial-results.json` beside it,
/// and removes the request. Nothing found here is saved as a menu.
enum MenuTrial {
    private static var folder: URL { AppData.folder }

    struct Request: Decodable {
        let visits: [String]
        let models: [String]
        /// "base" and/or "naver" (the Naver Place hint), "one" (one web
        /// search, not three), "haiku" (Claude Haiku in place of Sonnet);
        /// base when absent.
        let variants: [String]?
        /// Places given outright, for a trial over places confirmed in
        /// another data folder.
        let places: [PlaceCandidate]?
    }

    struct Result: Encodable {
        let place: String
        let model: String
        let variant: String
        let seconds: Double
        let count: Int
        let sections: [String: Int]
        let names: [String]
        let note: String
        let failed: Bool
    }

    @MainActor
    static func runIfAsked(_ library: PhotoLibrary) async {
        let requestURL = folder.appendingPathComponent("menu-trial.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        try? FileManager.default.removeItem(at: requestURL)
        let places = (request.places ?? []) + request.visits.compactMap { library.confirmedPlace(for: $0) }
        Usage.local(tag: "메뉴 비교 시작", detail: "\(places.count)곳 × \(request.models.count)개 모델", seconds: 0)
        var results: [Result] = []
        for place in places {
            for model in request.models { for variant in request.variants ?? ["base"] {
                let started = Date()
                let menu = await OpenAITransport.$grokModel.withValue(model.isEmpty ? nil : model) {
                    await ClaudeAPI.$modelOverride.withValue(variant == "haiku" ? "claude-haiku-4-5" : nil) {
                        await ClaudeAPI.$searchLimit.withValue(variant == "one" ? 1 : 5) {
                            await DishSearch.$naverHint.withValue(variant == "naver") {
                                await DishSearch.findFullMenu(place: place, key: PlaceMatcher.openAIKey ?? "")
                            }
                        }
                    }
                }
                let seconds = -started.timeIntervalSinceNow
                let items = (menu?.items ?? []).filter { PhotoLibrary.isDish($0.name) }
                let sections = Dictionary(grouping: items, by: \.section).mapValues(\.count)
                let result = Result(place: place.name, model: model, variant: variant, seconds: (seconds * 10).rounded() / 10,
                                    count: items.count, sections: sections, names: items.map(\.shown),
                                    note: menu?.notes.first ?? "", failed: menu == nil)
                results.append(result)
                Usage.local(tag: "메뉴 비교", detail: "\(place.name) · \(model) · \(variant): \(menu == nil ? "실패" : "\(items.count)개")",
                            seconds: seconds)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try? encoder.encode(results).write(to: folder.appendingPathComponent("menu-trial-results.json"))
            } }
        }
        Usage.local(tag: "메뉴 비교 끝", detail: "\(results.count)번", seconds: 0)
    }
}
