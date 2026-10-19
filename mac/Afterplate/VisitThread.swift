import AppKit

/// The feed as a conversation: for each visit the app shows the photos and
/// asks one thing at a time — the place, what was eaten, how each dish was,
/// which draft, whether to post — and every answer stays above as a record.
/// Nothing in the record is ever rewritten: going back is tapping an earlier
/// answer, which asks that question again at the bottom; the change is
/// written below as a summary line, and what depended on it is asked again
/// after it.
///
/// Kept in thread.json beside memory.json, never inside it.

enum Taste: String, Codable {
    case good, fine, bad, skipped
    var said: String {
        switch self {
        case .good: String(localized: "맛있었다")
        case .fine: String(localized: "괜찮았다")
        case .bad: String(localized: "별로였다")
        // "넘어가기" read as going on to the next visit.
        case .skipped: String(localized: "맛은 안 쓸게요")
        }
    }
}

struct ThreadEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case answer, change, note, closing }
    enum Key: String, Codable { case place, dishes, taste, scene, draft, post }
    var id = UUID()
    let kind: Kind
    var key: Key? = nil
    var question = ""
    var answer = ""
    var dish: String? = nil
    var label = ""
    var from = ""
    var to = ""
    var at = Date()
    /// Read in from what the old screens settled, not said here.
    var seeded: Bool? = nil
    /// The drafts turned down with 다 별로예요, kept as they were shown.
    var drafts: [Shown]? = nil
    struct Shown: Codable, Hashable {
        let genre: String
        let text: String
    }
}

/// What has been settled with the person.
struct ThreadFacts: Codable, Equatable {
    var place = false
    /// Put off for now ("나중에"), or not a meal at all.
    var later = false
    /// When it was last put off, for the order put-off visits come round
    /// in. Put off again right after coming round leaves no new answer, so
    /// the answer's time kept it first and it came straight back.
    var laterAt: Date? = nil
    var notMeal = false
    /// The dishes as answered; empty when the person did not remember.
    var dishes: [String]? = nil
    var tastes: [String: Taste] = [:]
    var draft = false
    /// The dishes and tastes the drafts on hand were written for.
    var draftsFor: String? = nil
    var posted = false
    /// Google's review form was opened from the post question.
    var formOpened = false
    /// Put off three times running at the same question: asked whether
    /// to put the visit away instead.
    var askArchive: Bool? = nil
    /// The place, after the dishes: 분위기 · 전망 · 서비스 picked, empty for
    /// none, nil until asked.
    var scene: [String]? = nil
}

struct VisitThread: Codable {
    var entries: [ThreadEntry] = []
    var facts = ThreadFacts()
    /// Whether what the old screens settled has been read in.
    var seeded = false
}

/// The question in front of the person.
enum ThreadStep: Equatable {
    case place, dishes, taste(String), scene, draft, post, done
    var key: ThreadEntry.Key? {
        switch self {
        case .place: .place
        case .dishes: .dishes
        case .taste: .taste
        case .scene: .scene
        case .draft: .draft
        case .post: .post
        case .done: nil
        }
    }
}

@MainActor
final class VisitThreads: ObservableObject {
    static let shared = VisitThreads()

    @Published private(set) var threads: [String: VisitThread] = [:]
    /// The latest answer to each question a visit had settled before a
    /// moment — place, menu, each dish's taste, the draft — in that order.
    func settled(_ id: String, before: Date? = nil) -> [ThreadEntry] {
        // "그대로" and putting off settle nothing.
        let nothing = [String(localized: "그대로"), String(localized: "나중에"), String(localized: "기다리는 동안 다음 방문"),
                       String(localized: "아직 아니에요"), String(localized: "보관")]
        let gone = moot(id, before: before)
        let answers = thread(id).entries.filter {
            $0.kind == .answer && $0.key != nil && $0.key != .post && !nothing.contains($0.answer) && (before == nil || $0.at < before!)
                && !gone.contains($0.id)
        }
        var latest: [String: ThreadEntry] = [:]
        var order: [String] = []
        for e in answers {
            let slot = "\(e.key!.rawValue)|\(e.key == .taste ? e.dish ?? "" : "")"
            if latest[slot] == nil { order.append(slot) }
            latest[slot] = e
        }
        return order.compactMap { latest[$0] }.sorted { Self.rank($0.key!) < Self.rank($1.key!) }
    }

    /// What a change of place or menu made moot: everything said about the
    /// visit before it from that step on — the old answer itself, and the
    /// menu, tastes, drafts and posting that hung on it. Folded under the
    /// change, never deleted (after one place was changed to another the
    /// old thread stayed in full and read as if it still held).
    func moot(by change: ThreadEntry, in id: String) -> [ThreadEntry] {
        guard change.label == ThreadActions.revisedLabel, !change.from.isEmpty,
              let key = change.key, key == .place || key == .dishes else { return [] }
        return thread(id).entries.filter { $0.at < change.at && ($0.key.map { Self.rank($0) >= Self.rank(key) } ?? true) }
    }

    func moot(_ id: String, before: Date? = nil) -> Set<UUID> {
        var gone: Set<UUID> = []
        for e in thread(id).entries where before == nil || e.at < before! {
            for m in moot(by: e, in: id) { gone.insert(m.id) }
        }
        return gone
    }

    static func rank(_ key: ThreadEntry.Key) -> Int {
        switch key { case .place: 0; case .dishes: 1; case .taste: 2; case .scene: 3; case .draft: 4; case .post: 5 }
    }

    /// The steps settled before one of this kind, as they stood at a
    /// moment (or now), earliest first.
    func before(_ id: String, key: ThreadEntry.Key, at: Date? = nil) -> [ThreadEntry] {
        var steps = settled(id, before: at).filter { Self.rank($0.key!) < Self.rank(key) }
        // A visit that got past the dishes before the place was asked about
        // (that question came in later) still has that step to go back to:
        // said as
        // not decided yet, never as an answer that was not given.
        if Self.rank(key) > Self.rank(.scene), thread(id).facts.scene == nil,
           !steps.contains(where: { $0.key == .scene }), steps.contains(where: { $0.key == .dishes }) {
            steps.append(ThreadEntry(kind: .answer, key: .scene, question: ThreadActions.sceneQuestion, answer: String(localized: "아직 안 정했어요")))
            steps.sort { Self.rank($0.key!) < Self.rank($1.key!) }
        }
        return steps
    }

    /// An earlier answer tapped: its question is asked again at the bottom.
    @Published var reopened: [String: ThreadStep] = [:] {
        didSet {
            for id in reopened.keys where oldValue[id] == nil { reopenOrder.removeAll { $0 == id }; reopenOrder.append(id) }
            for id in pressed.keys where reopened[id] == nil { pressed[id] = nil }
        }
    }
    /// The answer pressed to reopen it: while its question is asked again
    /// that answer is not shown — it has turned into the question, not
    /// been asked twice.
    @Published var pressed: [String: UUID] = [:]

    func isPressed(_ entry: ThreadEntry, of id: String) -> Bool { reopened[id] != nil && pressed[id] == entry.id }
    /// Which reopened visit was tapped last: its question is the one at the
    /// bottom.
    private(set) var reopenOrder: [String] = []
    /// Set aside while something long runs ("다음 방문 먼저"); it comes back
    /// right after the visit in front once the work is done.
    @Published var parked: Set<String> = []
    /// Places whose thin menu was searched again this session.
    var researched: Set<String> = []

    private let url = AppData.folder.appendingPathComponent("thread.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: VisitThread].self, from: data) {
            // "나중에" lasts: a launch does not bring the question straight
            // back; put-off visits come round again once
            // nothing else is left.
            threads = saved.mapValues { var t = $0
                // Written as notes on the first day, which could not be
                // tapped to take them back: now answers to the place question.
                t.entries = t.entries.map { e in
                    if e.kind == .change, let key = e.key {
                        let question: String = switch key {
                        case .place: ThreadActions.placeQuestion
                        case .dishes: ThreadActions.dishQuestion
                        case .taste: ThreadActions.tasteQuestion(e.dish ?? "")
                        case .scene: ThreadActions.sceneQuestion
                        case .draft: ThreadActions.draftQuestion
                        case .post: ThreadActions.postQuestion
                        }
                        return ThreadEntry(id: e.id, kind: .answer, key: key, question: ThreadActions.revised(key, question), answer: e.to, dish: e.dish,
                                           label: ThreadActions.revisedLabel, from: e.from, at: e.at)
                    }
                    // "다시 · 여기서 드셨어요?" read oddly: said
                    // as what is changed, then the question.
                    if e.kind == .answer, let key = e.key {
                        var e = e
                        if e.question.hasPrefix("다시 · ") {
                            e.question = ThreadActions.revised(key, String(e.question.dropFirst("다시 · ".count)))
                            e.label = ThreadActions.revisedLabel
                        }
                        e.question = e.question.replacingOccurrences(of: "여기서 드셨어요?", with: ThreadActions.placeQuestion)
                        return e
                    }
                    guard e.kind == .note, e.label == "나중에" || e.label == "밥 아님 · 보관" else { return e }
                    return ThreadEntry(id: e.id, kind: .answer, key: .place, question: ThreadActions.placeQuestion,
                                       answer: e.label == "나중에" ? e.label : "밥 아니에요 · 보관", at: e.at)
                }
                return t
            }
        }
    }

    func thread(_ id: String) -> VisitThread { threads[id] ?? VisitThread() }

    /// Visits something was said about here, in the order they were first
    /// talked about.
    var talkedAbout: [String] {
        threads.compactMap { id, t in t.entries.filter { $0.seeded != true }.map(\.at).min().map { (id, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    func taste(of dish: String, in id: String) -> Taste? { threads[id]?.facts.tastes[dish] }

    func update(_ id: String, _ change: (inout VisitThread) -> Void) {
        var thread = threads[id] ?? VisitThread()
        change(&thread)
        threads[id] = thread
        if let data = try? JSONEncoder().encode(threads) { try? data.write(to: url, options: .atomic) }
    }

    /// The next thing to ask; a reopened question first.
    func step(_ id: String) -> ThreadStep {
        if let again = reopened[id] { return again }
        let f = thread(id).facts
        if f.later || f.notMeal || f.posted { return .done }
        if !f.place { return .place }
        guard let dishes = f.dishes else { return .dishes }
        if let open = dishes.first(where: { f.tastes[$0] == nil }) { return .taste(open) }
        // Asked between the dishes and the cards; a draft already chosen
        // before this question existed is not asked back.
        if f.scene == nil && !f.draft { return .scene }
        if !f.draft { return .draft }
        return .post
    }

    /// What the dishes and tastes are now, to tell drafts written for
    /// something else.
    func draftKey(_ id: String) -> String {
        let f = thread(id).facts
        let dishes = (f.dishes ?? []).map { "\($0)=\(f.tastes[$0]?.rawValue ?? "")" }.joined(separator: "|")
        return (f.scene ?? []).isEmpty ? dishes : dishes + "|scene=" + f.scene!.joined(separator: ",")
    }
}

/// Answers, applied to the library and written into the thread.
@MainActor
struct ThreadActions {
    let library: PhotoLibrary
    let visit: Visit
    private var threads: VisitThreads { .shared }
    private var id: String { visit.id }

    /// What the old screens already settled is read in once, as answers.
    func seedIfNeeded() {
        closeIfPosted()
        guard !threads.thread(id).seeded else { return }
        threads.update(id) { t in
            t.seeded = true
            if let place = library.confirmedPlaces[id], !library.isTentative(visit) {
                t.facts.place = true
                t.entries.append(ThreadEntry(kind: .answer, key: .place, question: Self.placeQuestion, answer: place.name, seeded: true))
                let dishes = library.dishNames(for: visit)
                if !dishes.isEmpty {
                    t.facts.dishes = dishes
                    t.entries.append(ThreadEntry(kind: .answer, key: .dishes, question: Self.dishQuestion,
                                                 answer: dishes.map { library.reviewName(for: $0, in: visit) }.joined(separator: ", "), seeded: true))
                }
            }
            if library.posted[id] != nil { t.facts.posted = true }
        }
    }

    /// A visit finished with 올렸어요 before the app said its closing line
    /// gets it, counted as of when it was posted.
    private func closeIfPosted() {
        let t = threads.thread(id)
        guard t.facts.posted, let last = t.entries.last, last.kind == .answer, last.key == .post,
              last.answer == String(localized: "올렸어요"), let at = library.posted[id] else { return }
        threads.update(id) { $0.entries.append(Self.closing(library: library, id: id, count: library.posted.values.filter { $0 <= at }.count, at: last.at.addingTimeInterval(0.001))) }
    }

    static func closing(library: PhotoLibrary, id: String, count: Int, at: Date = Date()) -> ThreadEntry {
        let said = library.confirmedPlace(for: id).map { String(localized: "\(PlaceNames.shown($0.name)) 리뷰까지 마쳤어요. 지금까지 구글에 \(count)개 올렸어요.") }
            ?? String(localized: "이 방문 리뷰까지 마쳤어요. 지금까지 구글에 \(count)개 올렸어요.")
        return ThreadEntry(kind: .closing, answer: said, at: at)
    }

    static var placeQuestion: String { String(localized: "어디서 드셨어요?") }
    static var dishQuestion: String { String(localized: "뭐 드셨어요?") }
    static func tasteQuestion(_ dish: String) -> String { String(localized: "\(dish) 어땠어요?") }
    static var sceneQuestion: String { String(localized: "음식 말고도 좋았던 게 있어요?") }
    static var draftQuestion: String { String(localized: "어느 초안이 마음에 들어요?") }
    static var postQuestion: String { String(localized: "구글에 올릴까요?") }

    static func label(_ key: ThreadEntry.Key, dish: String?) -> String {
        switch key {
        case .place: String(localized: "가게")
        case .dishes: String(localized: "먹은 것")
        case .taste: dish ?? ""
        case .scene: String(localized: "분위기")
        case .draft: String(localized: "초안")
        case .post: String(localized: "구글")
        }
    }

    // MARK: Writing an answer

    /// A first answer is a line; an answer to a reopened question is a
    /// summary of the change, or "그대로". Returns whether anything changed.
    @discardableResult
    private func record(_ key: ThreadEntry.Key, question: String, before: String?, after: String, dish: String? = nil) -> Bool {
        let again = threads.reopened[id] != nil
        threads.reopened[id] = nil
        if again, let before {
            // Said again the way it was first said — a question and an
            // answer, pressable the same way — marked as asked again, with
            // what it was before struck through beside it (a summary pill
            // could not be pressed to change it once more).
            let same = before == after
            threads.update(id) { $0.entries.append(ThreadEntry(kind: .answer, key: key, question: Self.revised(key, question), answer: same ? String(localized: "그대로") : after,
                                                               dish: dish, label: Self.revisedLabel, from: same ? "" : before)) }
            return !same
        }
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .answer, key: key, question: question, answer: after, dish: dish)) }
        return before != after
    }

    func keepAsItWas() {
        guard let step = threads.reopened[id], let key = step.key else { return }
        if step == .done { threads.reopened[id] = nil; return }
        var dish: String? = nil
        if case .taste(let d) = step { dish = d }
        threads.reopened[id] = nil
        let (_, question, _) = Self.asked(step, library: library, visit: visit)
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .answer, key: key, question: Self.revised(key, question), answer: String(localized: "그대로"), dish: dish, label: Self.revisedLabel)) }
    }

    /// A reopened question is said as what is being changed, then the
    /// question, under the visit's photos and date ("다시 · 여기서 드셨어요?"
    /// read oddly).
    static func revised(_ key: ThreadEntry.Key, _ question: String) -> String {
        revisedLead(key) + " " + question
    }

    /// What the app says before a question asked again, naming what is
    /// being changed ("so you want to change this").
    static func revisedLead(_ key: ThreadEntry.Key) -> String {
        switch key {
        case .place: String(localized: "장소 수정할게요.")
        case .dishes: String(localized: "메뉴 수정할게요.")
        case .taste: String(localized: "다시 여쭤볼게요.")
        case .scene: String(localized: "가게 얘기 다시 할게요.")
        case .draft: String(localized: "글 수정할게요.")
        case .post: String(localized: "올리기 다시 할게요.")
        }
    }

    /// Marks an answer to a reopened question; it is shown under the visit.
    static let revisedLabel = "수정"

    /// A put-off answer pressed takes the visit up now; any other is asked
    /// again.
    func reopenOrTakeUp(_ entry: ThreadEntry) {
        if Self.putOff(entry) { takeUp() } else { reopen(entry) }
    }

    /// The visit put off, taken up now: the app says it is asking again,
    /// and that line, being the latest said, puts the visit in front; the
    /// one that was in front comes after it.
    func takeUp() {
        threads.parked.remove(id)
        threads.update(id) { t in
            t.facts.later = false
            t.facts.askArchive = nil
            t.entries.append(ThreadEntry(kind: .note, label: Self.askAgainLabel))
        }
    }

    func reopen(_ entry: ThreadEntry) {
        guard let key = entry.key, !threads.thread(id).facts.posted else { return }
        let step: ThreadStep = switch key {
        case .place: .place
        case .dishes: .dishes
        case .taste: .taste(entry.dish ?? "")
        case .scene: .scene
        case .draft: .draft
        case .post: .post
        }
        if threads.thread(id).facts.askArchive != nil { threads.update(id) { $0.facts.askArchive = nil } }
        threads.reopened[id] = step
        threads.pressed[id] = entry.id
    }

    // MARK: Place

    func choosePlace(_ place: PlaceCandidate) {
        resume()
        let facts = threads.thread(id).facts
        let before = facts.place ? library.confirmedPlaces[id]?.name : nil
        let samePlace = library.confirmedPlaces[id]?.googlePlaceID == place.googlePlaceID
        library.confirmPlace(place, for: visit)
        let changed = record(.place, question: Self.placeQuestion, before: before, after: place.name)
        threads.update(id) { t in
            t.facts.place = true
            if changed, before != nil {
                t.facts.dishes = nil; t.facts.tastes = [:]; t.facts.draft = false; t.facts.draftsFor = nil
            }
        }
        if !samePlace {
            library.forgetPreparation(for: visit)
            Task { await library.loadMenu(for: visit, again: true) }
        } else if !library.menuWasRead(for: visit) {
            Task { await library.loadMenu(for: visit) }
        }
    }

    /// Put off, as an answer to the question in front: tapping it later
    /// asks that question again (a "나중에" that was only
    /// a note could not be taken back).
    func later(at step: ThreadStep) {
        threads.reopened[id] = nil
        // Later again straight after being asked again: as if nothing had
        // been done — no second Later in the record. The one Later there was
        // moves to now, so the conversation shows this visit put off just
        // above the next one; left where it was, the last visit put off the
        // ordinary way stayed above every visit after.
        if let last = threads.thread(id).entries.last, last.kind == .note, last.label == Self.askAgainLabel {
            threads.update(id) { t in
                t.entries.removeLast()
                if let i = t.entries.lastIndex(where: { $0.kind == .answer && Self.putOff($0) }) {
                    var moved = t.entries.remove(at: i)
                    moved.at = Date()
                    t.entries.append(moved)
                }
                t.facts.later = true
                t.facts.laterAt = Date()
            }
            return
        }
        let (key, question, dish) = Self.asked(step, library: library, visit: visit)
        // Counted at this one question only: any other answer in between —
        // the place settled, then 나중에 at the menu — starts again at one.
        let streak = threads.thread(id).entries.filter { $0.kind == .answer }.reversed()
            .prefix { $0.answer == String(localized: "나중에") && $0.key == key && $0.dish == dish }.count
        let shown = step == .draft ? shownDrafts : nil
        threads.update(id) { t in
            t.entries.append(ThreadEntry(kind: .answer, key: key, question: question, answer: String(localized: "나중에"), dish: dish, drafts: shown))
            if streak + 1 >= 3 { t.facts.askArchive = true } else { t.facts.later = true; t.facts.laterAt = Date() }
        }
    }

    static let photoOutLabel = String(localized: "사진 하나 뺐어요")
    static let photoBackLabel = String(localized: "사진 되돌렸어요")

    /// Taken out, said as a line that can put it back.
    func removePhoto(_ photo: Photo) {
        library.removePhoto(photo, from: visit)
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .note, label: Self.photoOutLabel, from: photo.id)) }
    }

    func restorePhoto(_ id: String) {
        guard let photo = library.removedPhoto(id) else { return }
        library.restorePhoto(photo, to: visit)
        threads.update(self.id) { $0.entries.append(ThreadEntry(kind: .note, label: Self.photoBackLabel, from: id)) }
    }

    static let archiveQuestion = String(localized: "자꾸 미루시네요. 이 방문은 보관할까요?")

    /// Put away from the conversation, to 보관함, where it can be taken out.
    func archive(at step: ThreadStep) {
        let (key, _, dish) = Self.asked(step, library: library, visit: visit)
        library.setNotMeal(true, for: visit, verdict: false)
        threads.update(id) { t in
            t.facts.askArchive = nil
            t.facts.notMeal = true
            t.entries.append(ThreadEntry(kind: .answer, key: key, question: Self.archiveQuestion, answer: String(localized: "보관"), dish: dish))
        }
    }

    /// Not yet: put off as before, and the count starts again.
    func notYet(at step: ThreadStep) {
        let (key, _, dish) = Self.asked(step, library: library, visit: visit)
        threads.update(id) { t in
            t.facts.askArchive = nil
            t.facts.later = true
            t.facts.laterAt = Date()
            t.entries.append(ThreadEntry(kind: .answer, key: key, question: Self.archiveQuestion, answer: String(localized: "아직 아니에요"), dish: dish))
        }
    }

    /// Set aside while the app works on it, said as an answer so it stays
    /// in the record; the next visit comes in below.
    func park(at step: ThreadStep) {
        // A question asked again would keep the visit in front.
        threads.reopened[id] = nil
        let (key, question, dish) = Self.asked(step, library: library, visit: visit)
        let shown = step == .draft ? shownDrafts : nil
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .answer, key: key, question: question, answer: String(localized: "기다리는 동안 다음 방문"), dish: dish, drafts: shown)) }
        threads.parked.insert(id)
    }

    /// The drafts on screen, kept with the answer given to them so the
    /// record shows what was answered.
    private var shownDrafts: [ThreadEntry.Shown]? {
        let options = library.reviewOptions[id] ?? []
        return options.isEmpty ? nil : options.map { ThreadEntry.Shown(genre: $0.genre, text: $0.text) }
    }

    /// Put off, not answered: 나중에 and the next visit meanwhile. Nothing
    /// to take back, and the question is asked again later.
    static func putOff(_ entry: ThreadEntry) -> Bool {
        guard entry.kind == .answer else { return false }
        return ["나중에", "기다리는 동안 다음 방문"].contains { entry.answer == $0 || entry.answer == Bundle.main.localizedString(forKey: $0, value: nil, table: nil) }
    }

    func notAMeal(at step: ThreadStep) {
        threads.reopened[id] = nil
        library.setNotMeal(true, for: visit)
        let (key, question, dish) = Self.asked(step, library: library, visit: visit)
        threads.update(id) { t in
            t.facts.notMeal = true
            t.entries.append(ThreadEntry(kind: .answer, key: key, question: question, answer: String(localized: "밥 아니에요 · 보관"), dish: dish))
        }
    }

    static func asked(_ step: ThreadStep, library: PhotoLibrary, visit: Visit) -> (ThreadEntry.Key, String, String?) {
        switch step {
        case .dishes: (.dishes, dishQuestion, nil)
        case .taste(let d): (.taste, tasteQuestion(library.reviewName(for: d, in: visit)), d)
        case .scene: (.scene, sceneQuestion, nil)
        case .draft: (.draft, draftQuestion, nil)
        case .post: (.post, postQuestion, nil)
        case .place, .done: (.place, placeQuestion, nil)
        }
    }

    /// Answering anything takes a visit out of "나중에" and "밥 아님".
    private func resume() {
        let f = threads.thread(id).facts
        if f.notMeal { library.setNotMeal(false, for: visit) }
        if f.later || f.notMeal || f.askArchive != nil {
            threads.update(id) { $0.facts.later = false; $0.facts.notMeal = false; $0.facts.askArchive = nil }
        }
    }

    // MARK: Dishes

    func chooseDishes(_ picked: [String]) {
        resume()
        let facts = threads.thread(id).facts
        let shown = { (names: [String]) in
            names.isEmpty ? String(localized: "기억 안 나요") : names.map { library.reviewName(for: $0, in: visit) }.joined(separator: ", ")
        }
        let before = facts.dishes.map(shown)
        writeDishes(picked)
        let changed = record(.dishes, question: Self.dishQuestion, before: before, after: shown(picked))
        threads.update(id) { t in
            t.facts.dishes = picked
            if changed {
                t.facts.tastes = t.facts.tastes.filter { picked.contains($0.key) }
                t.facts.draft = false
            }
        }
    }

    /// A dish taken out comes off whichever photo had it; a new one goes on
    /// the first food photo without a name.
    private func writeDishes(_ picked: [String]) {
        let before = library.dishNames(for: visit)
        for name in before where !picked.contains(name) {
            for photo in visit.photos {
                let names = PhotoLibrary.dishParts(library.photoDishes[id]?[photo.id] ?? "")
                guard names.contains(name) else { continue }
                library.setPhotoDish(names.filter { $0 != name }.joined(separator: ", "), for: photo, in: visit)
            }
        }
        for name in picked where !before.contains(name) {
            let named = { (p: Photo) in !(library.photoDishes[id]?[p.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            let photo = visit.photos.first { !named($0) && (library.photoKinds[id]?[$0.id] ?? .food) != .place } ?? visit.photos.first
            guard let photo else { continue }
            let names = PhotoLibrary.dishParts(library.photoDishes[id]?[photo.id] ?? "")
            library.setPhotoDish((names + [name]).joined(separator: ", "), for: photo, in: visit)
        }
    }

    // MARK: Taste

    func chooseTaste(_ taste: Taste, for dish: String) {
        resume()
        let facts = threads.thread(id).facts
        let name = library.reviewName(for: dish, in: visit)
        library.setLiked(taste == .good, dish: dish, in: visit)
        let changed = record(.taste, question: Self.tasteQuestion(name), before: facts.tastes[dish]?.said, after: taste.said, dish: dish)
        threads.update(id) { t in
            t.facts.tastes[dish] = taste
            if changed { t.facts.draft = false }
        }
    }

    // MARK: Scene

    static func scenePhrase(_ tags: [String]) -> String {
        tags.isEmpty ? String(localized: "딱히 없어요") : tags.map(PhotoLibrary.tagPhrase).joined(separator: ", ")
    }

    func chooseScene(_ tags: [String]) {
        resume()
        let facts = threads.thread(id).facts
        let saved = library.tags[id] ?? []
        for tag in PhotoLibrary.placeTags where tags.contains(tag) != saved.contains(tag) { library.toggleTag(tag, for: visit) }
        let changed = record(.scene, question: Self.sceneQuestion, before: facts.scene.map(Self.scenePhrase), after: Self.scenePhrase(tags))
        threads.update(id) { t in
            t.facts.scene = tags
            if changed { t.facts.draft = false }
        }
    }

    // MARK: Draft

    /// Drafts on hand that were written for other dishes or tastes go, and
    /// new ones are written.
    func ensureDrafts() async {
        let key = threads.draftKey(id)
        if threads.thread(id).facts.draftsFor != key {
            library.dropDraftOptions(for: visit)
            threads.update(id) { $0.facts.draftsFor = key }
        }
        if (library.reviewOptions[id] ?? []).isEmpty, !library.drafting.contains(id) {
            await library.draftReview(for: visit)
        }
    }

    /// The drafts turned down stay where they were, with the answer under
    /// them, and the new ones come below (taking them
    /// away pulled the conversation down).
    func moreDrafts() async {
        let shown = (library.reviewOptions[id] ?? []).map { ThreadEntry.Shown(genre: $0.genre, text: $0.text) }
        threads.update(id) {
            // Kept in Korean, said in the app's language when shown.
            $0.entries.append(ThreadEntry(kind: .answer, question: "어느 초안이 마음에 들어요?", answer: "다 별로예요", drafts: shown))
            $0.entries.append(ThreadEntry(kind: .note, label: Self.redraftLabel))
        }
        await library.draftReview(for: visit, again: true)
    }

    /// Said before new drafts are written.
    /// Kept in Korean, said in the app's language when shown.
    static let redraftLabel = "알겠어요. 새 초안을 써 볼게요."
    static var redraftLine: String { String(localized: "알겠어요. 새 초안을 써 볼게요.") }
    /// Said, and kept, when a question put off comes up again: without it
    /// the record reads as the same question asked twice.
    static let askAgainLabel = "아까 미룬 질문, 다시 물어볼게요."
    static var askAgainLine: String { String(localized: "아까 미룬 질문, 다시 물어볼게요.") }

    func chooseDraft(_ option: GenreDraft) {
        resume()
        let before = threads.thread(id).facts.draft ? library.reviewDrafts[id]?.text : nil
        let drafts = shownDrafts
        library.chooseDraft(option, for: visit)
        defer {
            if let last = threads.thread(id).entries.last, last.key == .draft, last.drafts == nil {
                threads.update(id) { $0.entries[$0.entries.count - 1].drafts = drafts }
            }
        }
        let shown = option.text.isEmpty ? String(localized: "글 없이 사진만") : option.text
        record(.draft, question: Self.draftQuestion, before: before.map { $0.isEmpty ? String(localized: "글 없이 사진만") : $0 }, after: shown)
        threads.update(id) { $0.facts.draft = true }
    }

    // MARK: Post

    /// Posts that still get the how-to lines.
    static var guideLeft: Int {
        get { 3 - UserDefaults.standard.integer(forKey: "threadPostGuides") }
    }

    /// The person said Safari has one Google account: the form opens
    /// without the account chooser and the question is not asked again.
    static var oneAccount: Bool {
        get { UserDefaults.standard.bool(forKey: AppData.apart("googleOneAccount")) }
        set { UserDefaults.standard.set(newValue, forKey: AppData.apart("googleOneAccount")) }
    }

    /// Straight to Google's review form: the text on the clipboard, the
    /// photos in ~/Pictures/Afterplate for the form's file chooser.
    /// Through Google's account chooser when the person named an account,
    /// so a Safari signed in to several opens the form in that one. It was
    /// once dropped for a white review box;
    /// that turned out to be Safari's networking stuck on gstatic, not the
    /// chooser.
    func openGoogle(resumed: Bool = false) {
        let text = library.reviewDrafts[id]?.text ?? ""
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let keep = visit.photos.filter { photo in
            library.photoDishes[id]?[photo.id]?.isEmpty == false || library.isLiked(photo: photo, in: visit)
                || (library.photoKinds[id]?[photo.id] ?? .food) != .other
        }
        let url = library.confirmedPlace(for: id)?.reviewURL(language: AppLanguage.current.isEnglish ? "en" : "ko", account: library.googleAccount)
        library.markFormOpened(visit)
        if resumed || !threads.thread(id).facts.formOpened {
            record(.post, question: Self.postQuestion, before: nil, after: String(localized: "올리기"))
            threads.update(id) { $0.facts.formOpened = true }
        }
        // The form opens at once; the photos are copied meanwhile. Opening it
        // only after the copies were made looked like a button that did
        // nothing.
        Usage.local(tag: "리뷰창 열기", detail: url?.absoluteString ?? "주소 없음 — 구글 가게 아님", seconds: 0)
        if let url {
            if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Task { @MainActor in Usage.local(tag: "리뷰창 열기 실패", detail: error.localizedDescription, seconds: 0) } }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        // No Finder window: photos cannot be dragged into Safari's Google
        // review box. They are picked with the box's own
        // file chooser, from Pictures › Afterplate.
        Task { _ = await library.preparePost(photos: keep, for: visit) }
    }

    func posted() {
        resume()
        library.markPosted(visit)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "threadPostGuides") + 1, forKey: "threadPostGuides")
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .answer, key: .post, question: String(localized: "다 올렸어요?"), answer: String(localized: "올렸어요"))) }
        // The visit is finished — a big moment, so the app says so.
        let closing = Self.closing(library: library, id: id, count: library.posted.count)
        threads.update(id) { $0.entries.append(closing); $0.facts.posted = true }
    }

    /// After the posting sheet closes: posted or not.
    func postSheetClosed() {
        guard library.posted[id] != nil else { return }
        resume()
        record(.post, question: Self.postQuestion, before: nil, after: String(localized: "올렸어요"))
        threads.update(id) { $0.facts.posted = true }
    }

    func postLater() {
        record(.post, question: Self.postQuestion, before: nil, after: String(localized: "나중에"))
        threads.update(id) { $0.facts.later = true; $0.facts.laterAt = Date() }
    }
}
