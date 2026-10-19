import SwiftUI
import MapKit

/// The left pane: every visit, newest first, each with where it stands and
/// the one thing to do next. Picking a card starts the review on the right —
/// the list is not a step any more, it is always there.
struct VisitListScreen: View {
    @EnvironmentObject private var library: PhotoLibrary
    /// Nothing is open yet, so the list has the whole window; the cards stay
    /// the same, the column is simply centred.
    var wide: Bool = false
    /// The visit whose flow is open on the right.
    var selected: Visit.ID? = nil
    let open: (Visit?) -> Void

    /// Remembered across visits and launches: coming back to the list lands
    /// on the tab the person was working through.
    @AppStorage("visitListFilter") private var filterRaw: String = Filter.all.rawValue
    private var filter: Filter {
        get { Filter(rawValue: filterRaw) ?? .all }
        nonmutating set { filterRaw = newValue.rawValue }
    }

    enum Filter: String, CaseIterable {
        case all = "전부", place = "방문", ready = "작성중", posted = "리뷰 씀"
        case notMeal = "보관함"

        /// As shown. The raw value is what is saved (visitListFilter), so it
        /// stays Korean whatever the app's language.
        var label: String {
            switch self {
            case .all: return String(localized: "전부")
            case .place: return String(localized: "방문")
            case .ready: return String(localized: "작성중")
            case .posted: return String(localized: "리뷰 씀")
            case .notMeal: return String(localized: "보관함")
            }
        }
    }

    /// What the person waved off waits in its own tab. A visit with no
    /// 애플사진 (people at a table, a laid table with no dish the classifiers
    /// could name) is not listed at all unless the person vouched for it
    /// earlier or already worked on it — those are 노애플. A visit without
    /// GPS is not listed either. Only visits inside the map's view are
    /// listed. Always — a 지도 범위만 · 전체 switch looked like a second row of
    /// tabs; seeing everything is zooming out, or the map's 전체 보기.
    /// Opening a visit keeps it too: the list used to widen to the whole
    /// tab the moment a card was picked, so the card jumped away and the
    /// list no longer matched the map waiting behind ‹ 지도.
    /// The open visit itself is always listed, wherever it is.
    private var inMapView: ((Visit) -> Bool)? {
        guard let rect = library.mapRect else { return nil }
        let open = selected
        return { visit in
            guard visit.id != open, let c = visit.coordinate else { return true }
            return VisitMapView.contains(rect, c)
        }
    }

    /// The map is already showing the whole world's width: "지도 넓혀 보기"
    /// would ask for the same view again and nothing would happen.
    private var mapAtWidest: Bool {
        (library.mapRect?.size.width ?? 0) >= MKMapSize.world.width * 0.9
    }

    /// The card the person is working on stays where they found it. Opening a
    /// visit from 방문 and starting to name dishes moved it to 작성중 under
    /// them — they looked left to press 보관 and the card was gone. It holds
    /// its tab until another card is opened.
    @State private var pinned: (id: Visit.ID, tab: Filter)?

    /// The card at the top of the list as the person sees it. Moving the
    /// map adds or drops cards above it; the list scrolls back to it so the
    /// one they were looking at stays on top. A box, not
    /// state: it changes on every scrolled frame and must not redraw.
    @State private var topCard = TopCard()
    final class TopCard { var id: Visit.ID? }

    private func matches(_ visit: Visit, under f: Filter) -> Bool {
        guard let home = library.homeTab(of: visit) else { return false }
        if home == .notMeal { return f == .notMeal }
        // Only while it is still the open card. Moving on by "다음 방문 →"
        // never touches the list, and the pin used to strand the finished
        // visit in the tab it started in. Saying 리뷰 올렸어요 is the person
        // saying they are done with it, the way 보관 is — so it moves at
        // once, pin or no pin.
        if let pinned, visit.id == pinned.id, selected == pinned.id,
           library.posted[visit.id] == nil { return f == pinned.tab }
        return f == .all || f == home
    }

    private func count(_ f: Filter) -> Int {
        library.visits.filter { matches($0, under: f) }.count
    }


    /// The tab the open visit can actually be seen in. After "다 썼어요 · 다음
    /// 방문 →" the flow opens the next visit, which is usually a step behind
    /// the tab in view — so the right side showed a visit the left side did
    /// not list, and with no card there was no 보관 button either.
    /// 보관 used to leave the archived visit filling the detail pane: the
    /// card left the list and the review of it stayed on screen. The next
    /// card has to be worked out BEFORE the flag flips, because afterwards
    /// the visit is gone from this tab and there is nothing to count from.
    private func archive(_ visit: Visit) {
        let archiving = !library.notMeals.contains(visit.id)
        guard archiving, visit.id == selected else {
            library.setNotMeal(!library.notMeals.contains(visit.id), for: visit)
            return
        }
        let shown = library.visits.filter { matches($0, under: filter) }
        let next = shown.drop(while: { $0.id != visit.id }).dropFirst().first
            ?? shown.prefix(while: { $0.id != visit.id }).last
        library.setNotMeal(true, for: visit)
        open(next)
    }

    /// The open visit is always on the list. Opening it from its card pinned
    /// it to the tab in view; opening it from the map, 지도에서 or 다음 방문
    /// pinned nothing, so naming its place moved it 방문 → 작성중 and it left
    /// the list — 보관 and its yellow outline with it.
    /// Now any opened visit is pinned where it is seen, or the tab moves to
    /// where it is.
    private func follow(_ id: Visit.ID?) {
        guard let id, let visit = library.visits.first(where: { $0.id == id }) else { return }
        if matches(visit, under: filter) {
            if pinned?.id != id { pinned = (id, filter) }
            return
        }
        // 전부 is deliberately last — it matches everything, so searching in
        // order landed there every time.
        let order: [Filter] = [.ready, .place, .posted, .notMeal, .all]
        if let home = order.first(where: { matches(visit, under: $0) }) {
            filter = home
            pinned = (id, home)
        }
    }

    var body: some View {
        let inView = inMapView
        let matching = library.visits.filter { matches($0, under: filter) }
        let shown = matching.filter { inView?($0) ?? true }
        let outside = matching.count - shown.count
        let years = Dictionary(grouping: shown, by: \.year).sorted { $0.key > $1.key }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    BrandWordmark(size: 20)
                    // Settings in sight: the menu bar's 설정… was not
                    // found. ChatGPT sign-in and API keys.
                    SettingsLink {
                        Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppBrand.muted).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .help("설정 — ChatGPT 로그인, API 키")
                    Spacer()
                    Text(library.scanning
                         ? (library.toClassify > 0 ? "\(library.classified)/\(library.toClassify)장 훑는 중" : "사진 훑는 중")
                         : library.toSharpen > 0
                            ? "방문 \(count(.all))개 · 작게 본 사진 \(library.sharpened)/\(library.toSharpen)장 다시 보는 중"
                            : "방문 \(count(.all))개")
                        .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
                }
                // The tabs live above the map, which has the room; here the
                // list only says which one it is showing.
                Text(String(localized: "\(filter.label) \(shown.count)개") + (inView != nil ? String(localized: " · 지도에 보이는 곳") : ""))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppBrand.foreground)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .onChange(of: selected, initial: true) { _, id in follow(id) }
            Divider().overlay(AppBrand.line)

            if library.scanning && library.visits.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, 60)
                Spacer()
            } else if shown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if outside > 0 {
                        Text("지금 지도 안에는 없어요").font(.system(size: 16, weight: .bold)).foregroundStyle(AppBrand.foreground)
                        if selected == nil, !mapAtWidest {
                            Button("지도 밖에 \(outside)개 · 지도 넓혀 보기") { library.mapShowAll += 1 }
                                .buttonStyle(BigSecondaryButtonStyle())
                        } else {
                            FlowNote(text: String(localized: "지도 밖에 \(outside)개 있어요") + (mapAtWidest ? String(localized: " · 위 지역 메뉴에서 볼 수 있어요") : ""))
                        }
                    } else {
                        Text("여기 해당하는 방문이 없어요").font(.system(size: 16, weight: .bold)).foregroundStyle(AppBrand.foreground)
                        FlowNote(text: tabNote)
                    }
                }
                .padding(20)
                Spacer()
            } else {
                visitList(shown: shown, years: years, outside: outside)
            }
        }
    }


    /// The cards, by year; split out of `body`, which the compiler could no
    /// longer type-check in one piece.
    @ViewBuilder
    private func visitList(shown: [Visit], years: [(key: Int, value: [Visit])], outside: Int) -> some View {
                ScrollViewReader { proxy in
                ScrollView {
                        LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
                            ForEach(years, id: \.key) { year, visitsInYear in
                                Section {
                                    // One card per row, always: a grid put
                                    // four 104px photos in a 300px cell and
                                    // the cards spilled over each other.
                                    ForEach(visitsInYear) { visit in
                                        VisitCard(visit: visit,
                                                  wide: wide,
                                                  chosen: visit.id == selected,
                                                  lit: library.mapHover == visit.id,
                                                  notMeal: library.notMeals.contains(visit.id),
                                                  wave: { archive(visit) },
                                                  open: {
                                                      pinned = (visit.id, filter)
                                                      open(visit)
                                                  })
                                            .id(visit.id)
                                            // Where "keep this card on top"
                                            // scrolls to: a header's height
                                            // above the card, so the pinned
                                            // year does not cover its photos.
                                            .overlay(alignment: .top) {
                                                Color.clear.frame(height: 1)
                                                    .alignmentGuide(.top) { _ in 48 }
                                                    .id("top:" + visit.id)
                                            }
                                            .background(GeometryReader { g in
                                                Color.clear.preference(key: CardFrames.self,
                                                                       value: [visit.id: g.frame(in: .named("visitList"))])
                                            })
                                    }
                                } header: {
                                    Text("\(String(year))년")
                                        .font(.system(size: 17, weight: .black))
                                        .foregroundStyle(AppBrand.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8).padding(.horizontal, 20)
                                        .background(AppBrand.ink.opacity(0.94))
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        // With the whole window the list is a wide column of
                        // row cards; beside a review it is a narrow one.
                        .frame(maxWidth: wide ? 1100 : .infinity)
                        .frame(maxWidth: .infinity)
                        // Never hidden without a word: the map's view is a
                        // filter the person may have forgotten about.
                        if outside > 0 { OutsideMapRow(count: outside, canWiden: selected == nil && !mapAtWidest, atWidest: mapAtWidest) }
                }
                .coordinateSpace(name: "visitList")
                .onPreferenceChange(CardFrames.self) { frames in
                    // The first card not hidden under the pinned year header.
                    topCard.id = frames.filter { $0.value.maxY > 60 }.min { $0.value.minY < $1.value.minY }?.key
                }
                .onChange(of: library.mapRegion.map { "\($0.center.latitude),\($0.center.longitude),\($0.span.latitudeDelta)" }) { _, _ in
                    // However the map moved — a cluster clicked, zoomed or
                    // dragged by hand: the card that was on top stays on top
                    // if it is still in view; otherwise the list starts at
                    // its newest card in view.
                    guard selected == nil, let first = shown.first else { return }
                    let id = topCard.id.flatMap { id in shown.contains(where: { $0.id == id }) ? id : nil } ?? first.id
                    DispatchQueue.main.async { proxy.scrollTo("top:" + id, anchor: .top) }
                }
                // A pin under the mouse only lights its card if it is on
                // screen; scrolling to it made the list lurch whenever the
                // mouse crossed the map.
                }
    }

    private var tabNote: String {
        switch filter {
        case .notMeal: return String(localized: "보관한 방문이 여기 모여요. 목록을 정리하려고 치운 것들이에요.")
        default: return String(localized: "한 방문은 가게 → 메뉴 → 리뷰 → 올리기 순서로 끝냅니다.")
        }
    }
}

/// One visit in the left pane: three photos, where it stands, and two
/// actions — start it, or wave it off as not a meal.
private struct VisitCard: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    var wide: Bool = false
    let chosen: Bool
    /// Its pin is under the mouse on the map.
    var lit: Bool = false
    let notMeal: Bool
    let wave: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var status: (place: String, detail: String, cta: String) {
        let place = library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) }
        switch library.step(for: visit) {
        case 2: return (place ?? String(localized: "어느 가게였지?"), String(localized: "사진 \(visit.photoCount)장"), String(localized: "가게 찾기"))
        case 3: return (place ?? "", String(localized: "메뉴 이름 붙이는 중"), String(localized: "메뉴 적기"))
        case 4: return (place ?? "", String(localized: "초안 3개 준비됨"), String(localized: "리뷰 고르기"))
        case 5: return (place ?? "", String(localized: "문장 준비됨"), String(localized: "올리기"))
        default:
            let when = library.posted[visit.id].map { Self.dayFormatter.string(from: $0) } ?? ""
            return (place ?? "", when.isEmpty ? String(localized: "리뷰 씀") : String(localized: "\(when)에 리뷰 씀"), String(localized: "다시 보기"))
        }
    }

    var body: some View {
        let s = status
        // Two fixed shapes, never morphed into each other (the switch is not
        // animated): a big row card when the list has the window, a compact
        // stacked card beside a review.
        if wide {
            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    ForEach(Array(visit.photos.prefix(3)), id: \.id) { photo in
                        PhotoThumbnail(photo: photo, side: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(width: 376, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(visit.title).font(.system(size: 22, weight: .heavy)).tracking(-0.4).foregroundStyle(AppBrand.foreground)
                    if !s.place.isEmpty {
                        Text(s.place).font(.system(size: 17)).foregroundStyle(AppBrand.foreground).lineLimit(1)
                    }
                    Text(s.detail).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 10) {
                    actionButtons(big: true)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(chosen || hovering || lit ? AppBrand.raisedSurface : AppBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(chosen || lit ? AppBrand.signal : AppBrand.line, lineWidth: chosen ? 2 : 1))
            .padding(.horizontal, 28)
            .onHover { over in
                hovering = over
                if over { library.mapHover = visit.id } else if library.mapHover == visit.id { library.mapHover = nil }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        } else {
            compact(s)
        }
    }

    @ViewBuilder
    private func actionButtons(big: Bool) -> some View {
        let s = status
        Button(action: open) {
            Text("\(s.cta) →")
                .font(.system(size: big ? 16 : 13, weight: .black))
                .foregroundStyle(chosen ? AppBrand.ink : AppBrand.foreground)
                .padding(.horizontal, big ? 20 : 14).frame(height: big ? 44 : 34)
                .frame(minWidth: big ? 150 : nil)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chosen ? AppBrand.signal : AppBrand.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        }
        .buttonStyle(.plainHit)
        Button(action: wave) {
            Text(notMeal ? "꺼내기" : "보관")
                .font(.system(size: big ? 14 : 13, weight: .bold))
                .foregroundStyle(AppBrand.muted)
                .padding(.horizontal, big ? 16 : 12).frame(height: big ? 36 : 34)
                .frame(minWidth: big ? 150 : nil)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        }
        .buttonStyle(.plainHit)
        .help(notMeal ? "방문 목록으로 다시 올려요" : "리뷰 안 쓸 방문은 보관함으로 치워서 목록을 정리해요")
        // Posting happens in Safari and the person comes back to the list,
        // not to the step they left — so the only button that says "done"
        // was on a screen they never returned to, and a visit they had
        // posted sat in 방문 all evening.
        // Any visit that has got as far as a draft can be marked: the review
        // may have been posted from somewhere else entirely, and the app has
        // no way to know unless the person says so.
        if library.posted[visit.id] == nil,
           library.formOpened.contains(visit.id) || library.step(for: visit) >= 4 {
            Button(action: { library.markPosted(visit) }) {
                Text("리뷰 올렸어요 ✓")
                    .font(.system(size: big ? 14 : 13, weight: .bold))
                    .foregroundStyle(AppBrand.signal)
                    .padding(.horizontal, big ? 16 : 12).frame(height: big ? 36 : 34)
                    .frame(minWidth: big ? 150 : nil)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.signal.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plainHit)
            .help("구글에 올렸으면 눌러 주세요 — 리뷰 씀으로 옮겨요")
        }
    }

    private func compact(_ s: (place: String, detail: String, cta: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(visit.photos.prefix(3)), id: \.id) { photo in
                    PhotoThumbnail(photo: photo, side: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(visit.title).font(.system(size: 16, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                if !s.place.isEmpty {
                    Text(s.place).font(.system(size: 14)).foregroundStyle(AppBrand.foreground).lineLimit(1)
                }
                Text(s.detail).font(.system(size: 12)).foregroundStyle(AppBrand.muted)
            }
            HStack(spacing: 8) {
                actionButtons(big: false)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(chosen || hovering || lit ? AppBrand.raisedSurface : AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(chosen || lit ? AppBrand.signal : AppBrand.line, lineWidth: chosen ? 2 : 1))
        // 20, the year heading's own inset: at 16 the cards hung four points
        // to the left of the heading above them, which reads as the selected
        // card's outline running off the edge.
        .padding(.horizontal, 20)
        .onHover { over in
            hovering = over
            if over { library.mapHover = visit.id } else if library.mapHover == visit.id { library.mapHover = nil }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        if AppLanguage.current.isEnglish { f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d" }
        else { f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일" }
        return f
    }()
}

/// "지도 밖에 N개 더": matching visits the map's view is hiding from the list.
private struct OutsideMapRow: View {
    @EnvironmentObject private var library: PhotoLibrary
    let count: Int
    /// Only with the map up; inside a visit there is no map to widen.
    var canWiden = true
    var atWidest = false
    var body: some View {
        // A button only when pressing it does something. Unable to widen
        // (inside a visit, or the map already at full width) it is a plain
        // line: a yellow box that did nothing read as broken.
        if canWiden {
            Button { library.mapShowAll += 1 } label: {
                Text("지도 밖에 \(count)개 더 · 지도 넓혀 보기")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.signal)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            }
            .buttonStyle(.plainHit)
            .padding(.horizontal, 20).padding(.bottom, 16)
        } else {
            Text(String(localized: "지도 밖에 \(count)개 더") + (atWidest ? String(localized: " · 위 지역 메뉴에서 볼 수 있어요") : ""))
                .font(.system(size: 12.5)).foregroundStyle(AppBrand.faint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 16)
        }
    }
}

/// Each laid-out card's frame in the list's viewport.
private struct CardFrames: PreferenceKey {
    static var defaultValue: [Visit.ID: CGRect] = [:]
    static func reduce(value: inout [Visit.ID: CGRect], nextValue: () -> [Visit.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
