import Foundation
import CoreLocation

/// Gets visits ready before anyone opens them, the way a feed loads the next
/// posts while you read this one: the place (the app's
/// own pick, held as tentative), the menu, a guess per photo and four review
/// drafts. A visit is ready when all of that is on hand, so its card opens
/// with nothing to wait for.
///
/// Runs on the ChatGPT plan only — never on a paid key — and stops when the
/// plan says its usage limit is reached. Up to ten visits are prepared at
/// once (fifty small calls at once went through in four seconds on the
/// plan), a new one starting as soon as one is done.
@MainActor
final class Prefetcher: ObservableObject {
    @Published private(set) var preparing: Set<Visit.ID> = []
    /// Visits the app could not get ready by itself: no place it could pick.
    @Published private(set) var needsPerson: Set<Visit.ID> = []
    @Published private(set) var stoppedForLimit = false

    /// What the preparation turned up, newest last, for the screen that
    /// shows the work while the first cards are not ready (make the
    /// wait fun — photos, the place, the area, a map,
    /// menu names, a line of the draft).
    struct Find: Identifiable {
        /// `stamp`: a word in big puffy letters — the scan's dates and places.
        enum Kind { case photos([Photo]), stamp(String), place(name: String, area: String?, at: CLLocationCoordinate2D?), menu([String]), line(String) }
        let id = UUID()
        let visit: Visit.ID
        let kind: Kind
    }
    @Published private(set) var finds: [Find] = []

    private func found(_ visit: Visit, _ kind: Find.Kind) {
        finds.append(Find(visit: visit.id, kind: kind))
        if finds.count > 40 { finds.removeFirst(finds.count - 40) }
    }

    /// "서울특별시 중구 명동 …" → 명동; else the first two words.
    static func area(of address: String?) -> String? {
        guard let address else { return nil }
        // Written the English way, anywhere: "12-3 Myeong-dong, Jung
        // District, Seoul" gave "12-3 Myeong-dong,". The
        // dong when there is one, else the first part that is not a street
        // number ("123 Main St, Brooklyn, NY" → Brooklyn).
        let parts = address.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 {
            if let dong = parts.flatMap({ $0.split(separator: " ") }).first(where: { w in ["-dong", "-eup", "-myeon", "-ga"].contains { w.hasSuffix($0) } }) {
                return String(dong)
            }
            return parts.first { !($0.first?.isNumber ?? true) } ?? parts[0]
        }
        let words = address.split(separator: " ").map(String.init)
        if let dong = words.first(where: { $0.hasSuffix("동") || $0.hasSuffix("읍") || $0.hasSuffix("면") || $0.hasSuffix("가") && $0.count > 2 }) { return dong }
        return words.prefix(2).joined(separator: " ")
    }

    private unowned let library: PhotoLibrary
    private var queue: [Visit.ID] = []
    /// Visits in the line, not started yet.
    var waiting: Set<Visit.ID> { Set(queue) }
    /// Visits started this run: one that could not be got ready is not
    /// tried over and over.
    private(set) var tried: Set<Visit.ID> = []
    /// Anything still to do: being prepared or in the line.
    /// Stopped by a limit with visits still in line is not busy: nothing is
    /// coming, and the canvas must not wait on it.
    var busy: Bool { !preparing.isEmpty || (!queue.isEmpty && !stoppedForLimit) }

    /// Visits prepared at once. Three: ten at once put dozens of calls in
    /// flight on the person's own subscription, and only one is on screen
    /// at a time. Ten are still kept ready ahead.
    var batchSize = 3
    /// How many visits are kept ready ahead. `-AfterplateAhead 2` at launch
    /// keeps fewer, so a test reaches the in-conversation canvas after two
    /// Laters.
    static let ahead: Int = {
        let asked = UserDefaults.standard.integer(forKey: "AfterplateAhead")
        return asked > 0 ? asked : 12
    }()

    init(library: PhotoLibrary) { self.library = library }

    func isReady(_ visit: Visit) -> Bool {
        // Drafts are written after the person has said what they ate and
        // how it was (the thread), so they are not made ahead.
        library.confirmedPlace(for: visit.id) != nil && library.menuWasRead(for: visit)
    }

    /// Put visits at the front of the line (the ones about to be shown), and
    /// start them if there is room. Visits already ready or being prepared
    /// are skipped.
    func want(_ visits: [Visit]) {
        let fresh = visits.map(\.id).filter { id in
            !preparing.contains(id) && !needsPerson.contains(id)
                && !(library.visits.first { $0.id == id }.map(isReady) ?? true)
        }
        queue.removeAll { fresh.contains($0) }
        queue.insert(contentsOf: fresh, at: 0)
        pump()
    }

    /// Starts visits from the line while fewer than `batchSize` are being
    /// prepared. Each one that finishes makes room for the next at once —
    /// a visit asked for (one more after each one done or put off) does
    /// not wait for a whole batch to end.
    private func pump() {
        guard Brain.subscriptionReady else { return }
        while preparing.count < batchSize, !queue.isEmpty {
            if let limited = OpenAITransport.planLimitedAt, Date().timeIntervalSince(limited) < 30 * 60 {
                stoppedForLimit = true
                return
            }
            stoppedForLimit = false
            let id = queue.removeFirst()
            guard let visit = library.visits.first(where: { $0.id == id }) else { continue }
            preparing.insert(id)
            tried.insert(id)
            Task { @MainActor in
                let started = Date()
                await OpenAITransport.$planOnly.withValue(true) { await self.prepare(visit) }
                self.preparing.remove(id)
                Usage.local(tag: "미리 준비", detail: "\(visit.title): \(self.isReady(visit) ? "준비됨" : "못 함")", seconds: -started.timeIntervalSinceNow)
                self.pump()
            }
        }
    }

    /// One visit, step by step; each step is skipped when already done.
    private func prepare(_ visit: Visit) async {
        found(visit, .photos(Array(visit.photos.prefix(3))))
        await library.restoreSaved(for: visit)
        if library.confirmedPlaces[visit.id] == nil {
            if library.placeCandidates[visit.id] == nil { await library.lookupPlace(for: visit) }
            if library.placeMatches[visit.id] == nil { await library.matchPlace(for: visit) }
            guard let pick = library.placeMatches[visit.id]?.picks.first,
                  let place = library.placeCandidates[visit.id]?.first(where: { $0.id == pick.id }) else {
                needsPerson.insert(visit.id)
                let why = library.placeCandidates[visit.id].map { $0.isEmpty ? "근처 가게 없음" : "추천 없음 (후보 \($0.count)곳)" } ?? "가게 찾기 실패"
                Usage.local(tag: "미리 준비 멈춤", detail: "\(visit.title): \(why)", seconds: 0)
                return
            }
            library.tentativelyConfirm(place, for: visit)
        }
        if let place = library.confirmedPlaces[visit.id] {
            await PlaceNames.fill([place.name], library: library)
            found(visit, .place(name: PlaceNames.shown(place.name), area: Self.area(of: place.address), at: place.coordinate ?? visit.coordinate))
        }
        if !library.menuWasRead(for: visit) { await library.loadMenu(for: visit, again: true) }
        let menu = (library.menuNames[visit.id] ?? []).prefix(6)
        if !menu.isEmpty { found(visit, .menu(Array(menu))) }

    }
}
