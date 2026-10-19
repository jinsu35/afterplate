import SwiftUI
import CoreLocation
import AVKit
import AppKit

/// Steps 2–5 for one visit: place → dishes → review → post. Opens at the
/// step the visit has reached; the wordmark goes back to the list.
struct VisitFlow: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visitID: Visit.ID
    let home: () -> Void
    /// Called when a visit is finished: opens the next one still to write.
    var openNext: (Visit) -> Void = { _ in }
    /// Opened as a sheet from the feed for one step only (가게, 메뉴 or
    /// 올리기): it starts there, and moving on closes the sheet instead of
    /// going to the next step.
    var only: FlowStep? = nil
    @State private var step: FlowStep = .place
    @State private var draggable: [String: URL] = [:]
    /// Skipped the review from the dishes step: the post step opens Google's
    /// form with the photos and no text.
    @State private var photosOnly = false

    private var visit: Visit? { library.visits.first { $0.id == visitID } }

    var body: some View {
        if let visit {
            Group {
                switch step {
                case .place: PlaceStep(visit: visit, home: home, jump: jump) { go(.dishes, visit) }
                case .dishes: DishesStep(visit: visit, home: home, jump: jump, draggable: draggable, back: { step = .place },
                                            skipReview: { photosOnly = true; step = .post }) { photosOnly = false; go(.review, visit) }
                case .review: ReviewStep(visit: visit, home: home, jump: jump, back: { step = .dishes }) { go(.post, visit) }
                default: PostStep(visit: visit, home: home, jump: jump, draggable: draggable, photosOnly: photosOnly,
                                  back: { step = photosOnly ? .dishes : .review }, done: { openNext(visit) })
                }
            }
            .environment(\.flowVisitID, visit.id)
            .environment(\.oneStepSheet, only != nil)
            .task(id: visit.id) {
                photosOnly = false
                // library.step(for:) counts the old way: 2 = place … 6 = posted.
                step = only ?? FlowStep(rawValue: min(max(library.step(for: visit) - 1, 1), 4)) ?? .place
                async let place: Void = library.lookupPlace(for: visit)
                draggable = await library.prepareForDrag(visit.photos)
                await place
                await library.matchPlace(for: visit)
                // The lookup may have answered after the match gave up.
                await library.matchIfPending(for: visit)
                if library.confirmedPlaces[visit.id] != nil {
                    // Menu reading is opt-in (a button on the dishes step):
                    // for a recent visit the user types faster than the app
                    // reads. Only what was already read is restored here.
                    await library.restoreMenu(for: visit)
                    if step.rawValue >= FlowStep.review.rawValue { await library.draftReview(for: visit) }
                }
            }
        } else {
            Color.clear.onAppear(perform: home)
        }
    }

    /// The stepper's labels: back to any finished step.
    private func jump(_ target: FlowStep) { step = target }

    private func go(_ next: FlowStep, _ visit: Visit) {
        if only != nil { home(); return }
        step = next
        Task {
            switch next {
            case .dishes: await library.restoreMenu(for: visit)
            case .review: await library.draftReview(for: visit)
            default: break
            }
        }
    }
}

// MARK: - 2 가게

private struct PlaceStep: View {
    @Environment(\.oneStepSheet) private var oneStepSheet
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let home: () -> Void
    let jump: (FlowStep) -> Void
    let advance: () -> Void
    @State private var query = ""
    @State private var googleQuery = ""
    @State private var googleResults: [PlaceCandidate] = []
    @State private var googleSearching = false
    @State private var showAll = false
    @State private var enlarged: Photo?

    var body: some View {
        // Only Google places are offered: the review goes on Google, and a
        // place without a Google id could not be posted to at the end.
        let candidates = library.placeCandidates[visit.id].map { $0.filter { $0.googlePlaceID != nil } }
        let picks = library.placeMatches[visit.id]?.picks ?? []
        let confirmed = library.confirmedPlaces[visit.id].flatMap { $0.googlePlaceID != nil ? $0 : nil }
        // Only a confirmed place or the matcher's pick gets the big card. The
        // nearest place used to stand in when the check had not answered —
        // a coffee chain 3m away over a pasta lunch — and read as the
        // answer.
        let top: PlaceCandidate? = confirmed ?? picks.first.flatMap { p in candidates?.first { $0.id == p.id } }
        let reason: String? = confirmed != nil ? nil : picks.first.map { $0.reason }
        let rest = (candidates ?? []).filter { $0.id != top?.id }

        FlowScreen(step: .place, title: confirmed == nil ? String(localized: "어느 가게였나요?") : String(localized: "가게"), right: visit.fullTitle, onHome: home, onStep: jump) {
            if visit.coordinate == nil, confirmed == nil {
                // No GPS: the photos still have to be on screen — they are
                // what the person recognises the place from.
                VStack(alignment: .leading, spacing: 18) {
                    VisitPhotoStrip(visit: visit, home: home, enlarged: $enlarged)
                    FlowPanel { VStack(alignment: .leading, spacing: 12) {
                        Text("📍 위치 정보가 없어요").font(.system(size: 22, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                        searchPanel
                    } }.frame(maxWidth: 640)
                }
            } else if candidates == nil {
                HStack(spacing: 10) { ProgressView().controlSize(.small); FlowNote(text: String(localized: "사진 위치로 가게를 찾는 중")) }
            } else if confirmed == nil, library.matching.contains(visit.id) || (library.placeMatches[visit.id] == nil && !(candidates ?? []).isEmpty && library.matchPending(visit)) {
                // Never show a "this is it" card before the photos have been
                // checked: the nearest place is often not the place, and a
                // card that flips a few seconds later reads as a wrong answer.
                VStack(alignment: .leading, spacing: 18) {
                    VisitPhotoStrip(visit: visit, home: home, enlarged: $enlarged)
                    FlowPanel(padding: 28) {
                        HStack(spacing: 14) {
                            ProgressView().controlSize(.regular)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("사진으로 가게를 확인하는 중").font(.system(size: 22, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                                FlowNote(text: String(localized: "📍 근처 \(candidates?.count ?? 0)곳 · 10초쯤 걸려요"))
                            }
                        }
                    }
                }
            } else if let top {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 18) {
                        VisitPhotoStrip(visit: visit, home: home, enlarged: $enlarged)
                        EarlierReviewNote(visit: visit)
                        FlowPanel(highlighted: true, padding: 28) {
                            VStack(alignment: .leading, spacing: 14) {
                                BrandEyebrow(text: confirmed != nil ? String(localized: "확정한 가게") : String(localized: "사진과 맞는 곳"))
                                Text(PlaceNames.shown(top.name)).font(.system(size: 30, weight: .black)).tracking(-0.8).foregroundStyle(AppBrand.foreground)
                                Text([top.category, top.distanceLabel.isEmpty ? nil : "📍 \(top.distanceLabel)", top.address].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 16)).foregroundStyle(AppBrand.muted)
                                if let reason {
                                    Text(reason).font(.system(size: 16)).lineSpacing(4).foregroundStyle(AppBrand.foreground)
                                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppBrand.raisedSurface))
                                }
                                HStack(spacing: 12) {
                                    // Once a place is chosen there is nothing to
                                    // press here: changing it is a row in the
                                    // list, and "다른 가게예요" only emptied the
                                    // card.
                                    if confirmed == nil {
                                        Button("이 가게 맞아요 →") { library.confirmPlace(top, for: visit); advance() }
                                            .buttonStyle(BigPrimaryButtonStyle())
                                    }
                                    // Google's own page for the place —
                                    // reviews, photos, hours. Where the photo
                                    // was taken is on the map to the left, so
                                    // it no longer needs a link of its own.
                                    if let id = top.googlePlaceID,
                                       let url = URL(string: "https://www.google.com/maps/place/?q=place_id:\(id)") {
                                        Link("구글 지도에서 보기", destination: url).font(.system(size: 15, weight: .bold))
                                            .help("구글 지도에서 이 가게의 리뷰와 사진을 봐요")
                                    }
                                }
                                // Both pins on one picture. Two links, each
                                // opening a map of one point, left the person
                                // holding the other in their head — and the
                                // distance between them is the whole
                                // question.
                                if let here = visit.coordinate {
                                    PlaceMapView(photo: here, accuracy: visit.positionError,
                                                 place: top, others: rest, highlighted: hoveredPlace)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        // Beside the list, because the list is what it
                        // changes. Under the map on the other side, pressing
                        // it moved names in a column half a window away and
                        // nothing connected the two.
                        if confirmed == nil { digButton }
                        FlowNote(text: String(localized: "아니면"))
                        searchPanel
                    }
                    .frame(width: 440)
                }
            } else if let candidates, !candidates.isEmpty {
                // Candidates, but no verdict: the check failed or was cut off.
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 18) {
                        VisitPhotoStrip(visit: visit, home: home, enlarged: $enlarged)
                        FlowPanel(padding: 28) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("사진으로는 못 정했어요").font(.system(size: 22, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                                FlowNote(text: String(localized: "오른쪽에서 고르거나, 다시 확인해요."))
                                HStack(spacing: 12) {
                                    Button("사진으로 다시 확인") { Task { await library.rematchPlace(for: visit) } }
                                        .buttonStyle(BigSecondaryButtonStyle())
                                    if let here = visit.coordinate,
                                       let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(here.latitude),\(here.longitude)") {
                                        Link("구글 지도에서 보기", destination: url)
                                            .font(.system(size: 15, weight: .bold))
                                            .help("사진을 찍은 자리를 지도에서 열어요")
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        searchPanel
                    }
                    .frame(width: 440)
                }
            } else {
                VisitPhotoStrip(visit: visit, home: home, enlarged: $enlarged)
                FlowPanel { VStack(alignment: .leading, spacing: 12) {
                    let failed = library.lookupFailed.contains(visit.id)
                    Text(failed ? "📍 지도를 못 불러왔어요" : "📍 근처에서 못 찾았어요")
                        .font(.system(size: 22, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                    if failed {
                        Button("다시 찾기") { Task { await library.lookupPlace(for: visit, again: true); await library.matchPlace(for: visit) } }
                            .buttonStyle(BigSecondaryButtonStyle())
                    }
                    searchPanel
                } }.frame(maxWidth: 640)
            }
        } footer: {
            Spacer()
            if confirmed != nil {
                Button(oneStepSheet ? "이 가게로 정하기 ✓" : "다음: 메뉴 이름 →") { advance() }.buttonStyle(BigPrimaryButtonStyle())
            }
        }
        .enlargeOverlay($enlarged, caption: nil)
    }

    /// Reads the nearby places' real menus and reorders the list by what
    /// they actually sell. What it costs is on the face of it: pressed by
    /// accident it is spent, and the visit only gets one.
    private var digButton: some View {
        let running = library.digging.contains(visit.id)
        let spent = library.dug.contains(visit.id)
        return VStack(alignment: .leading, spacing: 6) {
            DeepSearchChip(title: String(localized: "딥서치 — 이 음식 파는 곳 찾기"),
                           note: spent ? String(localized: "이 방문은 다 썼어요") : String(localized: "약 $0.05 · 10초 · 방문당 1번"),
                           running: running, ready: !running && !spent,
                           runningLabel: String(localized: "가게들 메뉴 뒤지는 중"),
                           act: { Task { await library.digIntoMenus(for: visit) } })
                .help(spent ? "이 방문에서는 이미 한 번 찾아봤어요"
                            : "근처 가게들의 실제 메뉴판을 웹에서 읽어서, 이 음식을 파는 곳을 위로 올려요")
            if library.digFailed.contains(visit.id) {
                FlowNote(text: String(localized: "메뉴에서는 못 찾았어요. 아래에서 골라 주세요."))
            }
        }
    }

    /// One search box for both: typing filters the nearby list; Return
    /// searches Google Maps by name (takeout at home, or a place the nearby
    /// list missed). The two boxes this replaces confused the user.
    private var searchPanel: some View {
        let candidates = (library.placeCandidates[visit.id] ?? []).filter { $0.googlePlaceID != nil }
        let picks = library.placeMatches[visit.id]?.picks ?? []
        let confirmed = library.confirmedPlaces[visit.id]
        // The app's own pick is the first row, marked 추천, always. It used to
        // be held out because it was the card on the left — and after a
        // mis-click put another place there, the pick was on screen nowhere
        // and could not be chosen back. Being there from
        // the start, it never shifts rows under the mouse.
        let pickID = picks.first?.id
        let rest = candidates.filter { $0.id == pickID } + candidates.filter { $0.id != pickID }
        let q = query.filter { !$0.isWhitespace }.lowercased()
        let filtered = q.isEmpty ? rest : rest.filter { $0.name.filter { !$0.isWhitespace }.lowercased().contains(q) }
        let shown = (showAll || !q.isEmpty) ? filtered : Array(filtered.prefix(5))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppBrand.faint)
                TextField("가게 이름", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .onSubmit { runGoogleSearch() }
                if googleSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            if !googleResults.isEmpty {
                candidateList(googleResults, eyebrow: String(localized: "구글 지도"))
            } else if !googleSearching, !googleQuery.isEmpty, googleSearched == googleQuery {
                FlowNote(text: String(localized: "구글 지도에 없어요. 동네를 붙여 보세요."))
            }
            if !rest.isEmpty {
                candidateList(shown, eyebrow: String(localized: "📍 근처"), recommended: pickID)
                if shown.isEmpty, !q.isEmpty {
                    FlowNote(text: String(localized: "근처엔 없어요. Return 하면 구글 지도에서 찾아요."))
                }
                if q.isEmpty, filtered.count > 5 {
                    Button(showAll ? "가까운 5곳만" : "\(filtered.count - 5)곳 더") { showAll.toggle() }
                        .buttonStyle(.link).font(.system(size: 14))
                }
            } else if rest.isEmpty, candidates.isEmpty, googleResults.isEmpty, visit.coordinate != nil {
                FlowNote(text: String(localized: "📍 근처에 등록된 가게가 없어요. 이름을 적고 Return."))
            }
        }
    }

    /// Nearby candidates as one grouped list, not a stack of separate boxes.
    private func candidateList(_ list: [PlaceCandidate], eyebrow: String, recommended: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandEyebrow(text: eyebrow).padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, candidate in
                    // Choosing from the list picks the place and stops there:
                    // the card and the map on the left switch to it, and the
                    // footer's 다음 is what leaves the screen. Jumping
                    // straight to the menu meant a mis-click was only visible
                    // one screen too late.
                    Button {
                        library.confirmPlace(candidate, for: visit)
                        hoveredPlace = nil
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if candidate.id == recommended {
                                        Text("추천").font(.system(size: 11, weight: .black)).foregroundStyle(AppBrand.ink)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Capsule().fill(AppBrand.signal))
                                    }
                                    Text(PlaceNames.shown(candidate.name)).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                                }
                                if let sub = [candidate.category, candidate.distance < 0 ? candidate.address : nil].compactMap({ $0 }).first {
                                    Text(sub).font(.system(size: 12)).foregroundStyle(AppBrand.faint).lineLimit(1)
                                }
                            }
                            Spacer()
                            if !candidate.distanceLabel.isEmpty {
                                Text(candidate.distanceLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(AppBrand.muted)
                            }
                            Image(systemName: library.confirmedPlaces[visit.id]?.id == candidate.id ? "checkmark.circle.fill" : "chevron.right")
                                .font(.system(size: library.confirmedPlaces[visit.id]?.id == candidate.id ? 14 : 11, weight: .bold))
                                .foregroundStyle(library.confirmedPlaces[visit.id]?.id == candidate.id ? AppBrand.foreground : AppBrand.faint)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .background(hoveredPlace == candidate.id || library.confirmedPlaces[visit.id]?.id == candidate.id
                                ? AppBrand.raisedSurface : .clear)
                    .onHover { inside in
                        if inside { hoveredPlace = candidate.id }
                        else if hoveredPlace == candidate.id { hoveredPlace = nil }
                    }
                    if index < list.count - 1 { Divider().overlay(AppBrand.line).padding(.leading, 14) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        }
    }

    /// The candidate row the mouse is on. The map on the left lights up the
    /// matching pin, so the list can be read as positions rather than
    /// names.
    @State private var hoveredPlace: String?

    @State private var googleSearched = ""

    private func runGoogleSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        googleQuery = text
        googleSearching = true
        Task {
            googleResults = await PlaceLookup.searchText(text, near: visit.coordinate)
            googleSearched = text
            googleSearching = false
        }
    }
}

// MARK: - 3 메뉴

/// One photo, one field, and the cursor never moves.
///
/// The old screen put a name field under every photo and a 43-item menu panel
/// down the right side: the eye and the hand travelled for every entry, the
/// menu took a third of the window whether or not it was wanted, and the names
/// ended up scattered across the grid where nobody could read them as a list.
///
/// Here the visit's photos come up one at a time on the left, the field sits
/// beside the current one with the namer's guess already in it, and the menu
/// is a row of suggestions under the field rather than a panel. ⏎ moves on,
/// ⇥ takes the suggestion. Under it all, one strip says what the review will
/// actually be about.
/// This place already has a review from another visit.
///
/// Google keeps one review per place per account, so writing a second one
/// does not add anything — it replaces what is there. That was only said on
/// the last screen, after the dishes were named and the review written; it
/// belongs at the start, with the old review readable, so the person can
/// decide what they are doing before doing it.
private struct EarlierReviewNote: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    /// Offered only where there is a draft to join it to — the post step.
    /// Gets the earlier review's text and the date of the visit it was for.
    var carry: ((_ korean: String, _ english: String, _ date: Date) -> Void)? = nil
    @State private var reading = false

    var body: some View {
        if let earlier = library.earlierPost(samePlaceAs: visit) {
            VStack(alignment: .leading, spacing: 10) {
                Text("✍️ 이 가게엔 \(earlier.visit.title) 방문으로 이미 리뷰를 올렸어요")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppBrand.foreground)
                Text("구글은 한 가게에 리뷰를 하나만 받아요. 예전 글에 이번 방문 문단을 이어 붙여 다시 올리는 게 보통이에요.")
                    .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
                HStack(spacing: 12) {
                    if !earlier.korean.isEmpty {
                        Button("그때 쓴 리뷰 보기") { reading = true }
                            .buttonStyle(BigSecondaryButtonStyle())
                    }
                    if let carry, !earlier.korean.isEmpty {
                        Button("예전 리뷰에 이어 쓰기") { carry(earlier.korean, earlier.english, earlier.visit.wallClock) }
                            .buttonStyle(BigPrimaryButtonStyle())
                            .help("최근 방문 문단을 위에, 예전 것을 아래에 두고 문단마다 방문 날짜를 붙여요. 입력창의 ‘예전 리뷰 빼기’로 되돌려요.")
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.signal.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.signal.opacity(0.35), lineWidth: 1))
            .sheet(isPresented: $reading) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(earlier.visit.title)에 올린 리뷰")
                        .font(.system(size: 20, weight: .black)).foregroundStyle(AppBrand.foreground)
                    ScrollView {
                        Text([earlier.korean, earlier.english].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                            .font(.system(size: 16)).lineSpacing(5).foregroundStyle(AppBrand.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack { Spacer(); Button("닫기") { reading = false }.buttonStyle(BigPrimaryButtonStyle()).keyboardShortcut(.cancelAction) }
                }
                .padding(24)
                .frame(width: 560, height: 420)
                .background(BrandBackdrop())
            }
        }
    }
}

/// Chips in a row that wraps instead of running off the window. SwiftUI has
/// no such stack; the menu names and the written list both need one, and a
/// single long name used to push the rest of the row out of sight.
struct WrapRow: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + lineSpacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// ⇥ takes the first suggestion. SwiftUI has no optional shortcut, so the
/// modifier is applied or not applied.
private struct TabShortcut: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(.tab, modifiers: []) } else { content }
    }
}

/// "딥서치" — the web asked about this place, then every photo named from
/// what comes back. The allowance is on the button rather than hidden in a
/// setting: the person should see what it costs them before pressing.
/// Every deep search wears the same face. They were three buttons with three
/// names — "메뉴까지 뒤져보기", "웹에서 메뉴 딥서치", "딥서치" — for one
/// ability: ask the web what a place sells. The name says 딥서치 and then what
/// this one is for; the note under it says what it costs before it is pressed,
/// which only the tooltip used to say.
struct DeepSearchChip: View {
    let title: String
    let note: String
    let running: Bool
    let ready: Bool
    var runningLabel: String = String(localized: "웹에서 찾는 중")
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: "sparkle.magnifyingglass").font(.system(size: 14, weight: .bold)) }
                Text(running ? runningLabel : title).font(.system(size: 14, weight: .black))
                Spacer(minLength: 8)
                if !note.isEmpty {
                    Text(note).font(.system(size: 12, weight: .bold)).foregroundStyle(AppBrand.faint)
                }
            }
            .foregroundStyle(ready ? AppBrand.signal : AppBrand.faint)
            .padding(.horizontal, 14).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ready ? AppBrand.signal.opacity(0.1) : AppBrand.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ready ? AppBrand.signal.opacity(0.4) : AppBrand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .disabled(!ready)
    }
}

/// The photos that are still unnamed, asked about together.
private struct DeepSearchButton: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit

    var body: some View {
        let running = library.deepSearching.contains(visit.id)
        let left = library.deepSearchesLeft
        let ready = library.confirmedPlaces[visit.id] != nil && left > 0 && !running
        DeepSearchChip(title: String(localized: "딥서치 — 이 가게 메뉴판 찾기"),
                       note: PhotoLibrary.metered ? String(localized: "주 \(PhotoLibrary.deepSearchLimit)번 중 \(left)번") : String(localized: "약 $0.06 · 15초"),
                       running: running, ready: ready,
                       act: { Task { await library.deepSearch(for: visit) } })
            .help(helpText(left: left))
    }

    private func helpText(left: Int) -> String {
        if library.confirmedPlaces[visit.id] == nil { return String(localized: "가게가 정해져야 딥서치할 수 있어요") }
        guard left > 0 else {
            guard let renews = library.deepSearchRenews else { return String(localized: "이번 주 딥서치를 다 썼어요") }
            let days = max(1, Int(renews.timeIntervalSinceNow / 86_400) + 1)
            return String(localized: "딥서치를 다 썼어요 — \(days)일 뒤에 한 번 다시 생겨요")
        }
        let note = String(localized: "이 가게가 파는 메뉴를 웹에서 찾아 목록에 채우고, 사진 이름도 다시 붙여요 (10초쯤)")
        return PhotoLibrary.metered ? note + String(localized: " · \(left)번 남음") : note
    }
}

/// A name that has been added, and the way to take it back out.
///
/// The × stays visible rather than waiting for a hover: a chip that only
/// reveals its own control on approach cannot be discovered by someone who
/// does not already know it is there, and there are never more than a few of
/// these. Quiet until the pointer arrives, when the whole chip turns into the
/// thing about to be removed.
private struct AddedChip: View {
    let name: String
    var note: String? = nil
    var filled: Bool = true
    /// A dish carries a heart: ♥ makes its line "맛있었다", unmarked is
    /// "괜찮았다". nil for a tag, which has no tiers.
    var liked: Bool? = nil
    var toggleLike: (() -> Void)? = nil
    let remove: () -> Void
    @State private var over = false

    var body: some View {
        HStack(spacing: 0) {
            if let liked, let toggleLike {
                Button(action: toggleLike) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(liked ? Color.red : AppBrand.faint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .help(liked ? "맛있었다 — 눌러서 괜찮았다로" : "괜찮았다 — 눌러서 맛있었다로")
                .padding(.leading, 4)
            }
            Button(action: remove) {
                HStack(spacing: 7) {
                    Text(name).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(over ? AppBrand.muted : AppBrand.signal)
                        .strikethrough(over, color: AppBrand.muted)
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(AppBrand.faint)
                            .strikethrough(over, color: AppBrand.muted)
                    }
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(over ? AppBrand.foreground : AppBrand.faint)
                }
                .padding(.leading, liked == nil ? 12 : 4).padding(.trailing, 12).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .onHover { over = $0 }
            .help("리뷰에서 빼기")
        }
        .background(Capsule().fill(over ? AppBrand.raisedSurface : (filled ? AppBrand.signal.opacity(0.12) : Color.clear)))
        .overlay(Capsule().stroke(over ? AppBrand.line : AppBrand.signal.opacity(0.5), lineWidth: 1))
    }
}

private struct DishesStep: View {
    @Environment(\.oneStepSheet) private var oneStepSheet
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let home: () -> Void
    let jump: (FlowStep) -> Void
    let draggable: [String: URL]
    let back: () -> Void
    let skipReview: () -> Void
    let advance: () -> Void

    @State private var at = 0
    @State private var typed = ""
    /// The menu kind being browsed; nil follows this photo's guess.
    @State private var section: String?
    @State private var enlarged: Photo?
    @FocusState private var writing: Bool

    private var photos: [Photo] { visit.photos }
    private var here: Photo? { photos.indices.contains(at) ? photos[at] : nil }
    private var chosenTags: [String] { library.tags[visit.id] ?? [] }

    /// What the review will be about: every name typed, plus the tags.
    private var written: [(text: String, tag: Bool)] {
        let names = library.dishNames(for: visit).map { (text: $0, tag: false) }
        return names + chosenTags.map { (text: $0, tag: true) }
    }

    var body: some View {
        FlowScreen(step: .dishes,
                   title: library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) } ?? String(localized: "뭘 드셨나요"),
                   subtitle: visit.fullTitle,
                   onHome: home, onStep: jump) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 32) {
                    photoColumn
                    entryColumn
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 18)
                RemovedStrip(visit: visit)
            }
        } footer: {
            Button("← 가게") { back() }.buttonStyle(BigSecondaryButtonStyle())
            // In the fixed bottom bar, not the scrolling page: at the page's
            // end it was cut off whenever the menu panel made the page
            // tall.
            writtenStrip.padding(.horizontal, 12)
            let ready = !written.isEmpty
            // Quiet on purpose: writing is the main road, this is the side
            // door for a visit whose photos are all there is to say.
            Button("건너뛰고 사진만 올리기") { commit(); skipReview() }
                .buttonStyle(.plainHit)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.muted)
                .padding(.horizontal, 8)
                .help("리뷰 문장 없이 사진만 구글에 올려요")
            if !ready {
                // Said beside the button, not only in a tooltip.
                Text("메뉴 이름이나\n태그를 하나 골라 주세요")
                    .font(.system(size: 12)).foregroundStyle(AppBrand.faint).multilineTextAlignment(.trailing)
            }
            Button(oneStepSheet ? "이 메뉴로 정하기 ✓" : "다음: 리뷰 쓰기 →") { commit(); advance() }
                .buttonStyle(BigPrimaryButtonStyle())
                .disabled(!ready)
        }
        .enlargeOverlay($enlarged, caption: here.flatMap { library.photoDishes[visit.id]?[$0.id] })
        .onChange(of: visit.id, initial: true) { _, _ in
            at = firstUnnamed()
            typed = ""
            writing = true
        }
        .onChange(of: at) { _, _ in typed = ""; writing = true; section = nil }
    }

    // MARK: 왼쪽 — 지금 사진

    private var photoColumn: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let photo = here {
                DraggablePhoto(photo: photo, fileURL: draggable[photo.id],
                               remove: { skip(remove: true) }, reorder: .constant(nil), visit: visit)
                    .frame(width: 300)
                    // One click: a double click was the only way in, and a
                    // single one did nothing. Dragging
                    // still drags.
                    .onTapGesture { enlarged = photo }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(AppBrand.foreground)
                            .padding(6).background(Circle().fill(AppBrand.ink.opacity(0.7)))
                            .padding(8).allowsHitTesting(false)
                    }
            }
            HStack(spacing: 6) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button { commit(); at = index } label: {
                        PhotoTile(photo: photo)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .opacity(index == at ? 1 : 0.42)
                            .overlay {
                                if named(photo), index != at {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(AppBrand.ink.opacity(0.55))
                                        .overlay(Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(AppBrand.signal))
                                }
                            }
                            .overlay {
                                if index == at {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(AppBrand.signal, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plainHit)
                }
            }
            .frame(width: 300, alignment: .leading)
            Text("\(at + 1) / \(photos.count)장")
                .font(.system(size: 12)).foregroundStyle(AppBrand.faint)
            placeCard.padding(.top, 10)
            HStack(spacing: 12) {
                key("⏎", String(localized: "다음 사진"))
                key("⌥⏎", String(localized: "빼기"))
                key("⌘⏎", String(localized: "다 적었어요"))
            }
            .padding(.top, 6)
        }
        .frame(width: 300, alignment: .leading)
    }

    /// The visit as a whole, not this photo: 전망, 분위기, 서비스. They sat
    /// in a row between the photo's suggestions and the menu, where they
    /// read as more menu and were missed; here, under the photos, they are
    /// what they are — about the place.
    private var placeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("음식 말고, 이 가게는").font(.system(size: 14, weight: .black)).foregroundStyle(AppBrand.foreground)
            WrapRow(spacing: 8, lineSpacing: 8) {
                ForEach(PhotoLibrary.placeTags, id: \.self) { tag in
                    let on = chosenTags.contains(tag)
                    Button { library.toggleTag(tag, for: visit) } label: {
                        HStack(spacing: 6) {
                            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .black)) }
                            Text(PhotoLibrary.tagPhrase(tag)).font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(on ? AppBrand.ink : AppBrand.foreground)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(on ? AppBrand.signal : AppBrand.raisedSurface))
                        .overlay(Capsule().stroke(on ? AppBrand.signal : AppBrand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plainHit)
                }
            }
            Text("고르면 리뷰에 한 줄로 들어가요.").font(.system(size: 11.5)).foregroundStyle(AppBrand.faint)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
    }

    // MARK: 오른쪽 — 칸 하나

    private var entryColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kindHere == .place ? "이 사진은 가게 모습이네요" : "이건 뭐였어요?")
                    .font(.system(size: 21, weight: .black)).foregroundStyle(AppBrand.foreground)
                Text("하나씩 적고 ⏎. 다 적었으면 빈 칸에서 ⏎로 다음 사진.")
                    .font(.system(size: 12.5)).foregroundStyle(AppBrand.faint)
            }

            // One thing at a time. The field is a place to add to a list, not a
            // line to compose in: typing raises 추가하기, ⏎ does the same, and
            // the field empties itself for the next one. ⏎ on an empty field
            // moves to the next photo.
            HStack(spacing: 10) {
                TextField("", text: $typed, prompt: Text("메뉴 이름").foregroundStyle(AppBrand.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .bold))
                    .focused($writing)
                    .onSubmit { typed.trimmingCharacters(in: .whitespaces).isEmpty ? step(1) : add() }
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: add) {
                        HStack(spacing: 6) {
                            Text("추가하기").font(.system(size: 13, weight: .black))
                            Text("⏎").font(.system(size: 11, weight: .black)).foregroundStyle(AppBrand.ink.opacity(0.55))
                        }
                        .foregroundStyle(AppBrand.ink)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(Capsule().fill(AppBrand.signal))
                    }
                    .buttonStyle(.plainHit)
                }
            }
            .padding(.horizontal, 16).frame(height: 58).frame(maxWidth: 620)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.signal, lineWidth: 2))

            if !namesHere.isEmpty {
                WrapRow {
                    ForEach(namesHere, id: \.self) { name in
                        AddedChip(name: name) { remove(name) }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
            }

            guessCard
            menuCard
        }
        // A fixed width: sized by its contents, the column grew and shrank with
        // each menu tab and pushed the whole page about.
        .frame(width: 620, alignment: .leading)
    }

    /// This photo's guess, set apart and in sight: a dashed-yellow box with
    /// the dishes it names, the first taken with ⇥. It used to be a small
    /// "추천" row easy to miss among the chips.
    @ViewBuilder
    private var guessCard: some View {
        let open = guessHere.filter { !namesHere.contains($0) }
        if !open.isEmpty, typed.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("이 사진, 이거였나요?").font(.system(size: 15, weight: .black)).foregroundStyle(AppBrand.signal)
                WrapRow(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(open.enumerated()), id: \.element) { index, name in
                        Button { typed = name; add() } label: {
                            HStack(spacing: 8) {
                                if index == 0 {
                                    Text("⇥").font(.system(size: 11, weight: .black)).foregroundStyle(AppBrand.ink.opacity(0.55))
                                }
                                Text(name).font(.system(size: 16, weight: .black))
                            }
                            .foregroundStyle(AppBrand.ink)
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(Capsule().fill(AppBrand.signal))
                        }
                        .buttonStyle(.plainHit)
                        .modifier(TabShortcut(on: index == 0))
                    }
                }
                Text("앱의 추측이에요. 맞으면 눌러서 넣어요.").font(.system(size: 11.5)).foregroundStyle(AppBrand.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.signal.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppBrand.signal.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        }
    }

    /// The menu, one kind at a time: tabs for the kinds, the chosen kind's
    /// names below. Everything at once was a wall of chips. Typing
    /// turns it into a search across every kind.
    @ViewBuilder
    private var menuCard: some View {
        let items = library.menuItems(for: visit)
        let place = library.confirmedPlaces[visit.id]?.name ?? ""
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(items.isEmpty ? "이 가게 메뉴" : "이 가게 메뉴 \(items.count)")
                    .font(.system(size: 15, weight: .black)).foregroundStyle(AppBrand.foreground)
                Spacer()
                menuStatus
            }
            if !items.isEmpty, !library.menuLoading.contains(visit.id) {
                let kinds = items.reduce(into: [String]()) { out, item in
                    let k = item.section.isEmpty ? String(localized: "그 외") : item.section
                    if !out.contains(k) { out.append(k) }
                }
                let query = typed.filter { !$0.isWhitespace }.lowercased()
                let guessKind = items.first { guessHere.contains($0.shown) }.map { $0.section.isEmpty ? String(localized: "그 외") : $0.section }
                let current = section.flatMap { kinds.contains($0) ? $0 : nil } ?? guessKind ?? kinds.first ?? ""
                if query.isEmpty {
                    // Tabs, not chips: plain words with an underline on the
                    // one open, over a rule — the kinds and the dishes were
                    // two rows of identical capsules.
                    VStack(alignment: .leading, spacing: 0) {
                        WrapRow(spacing: 18, lineSpacing: 4) {
                            ForEach(kinds, id: \.self) { kind in
                                let count = items.filter { ($0.section.isEmpty ? String(localized: "그 외") : $0.section) == kind }.count
                                Button { section = kind } label: {
                                    VStack(spacing: 5) {
                                        HStack(spacing: 4) {
                                            Text(kind).font(.system(size: 14, weight: kind == current ? .black : .semibold))
                                            Text("\(count)").font(.system(size: 11, weight: .bold)).foregroundStyle(AppBrand.faint)
                                        }
                                        .foregroundStyle(kind == current ? AppBrand.foreground : AppBrand.muted)
                                        Rectangle().fill(kind == current ? AppBrand.signal : Color.clear).frame(height: 3)
                                    }
                                    .fixedSize()
                                }
                                .buttonStyle(.plainHit)
                            }
                        }
                        Divider().overlay(AppBrand.line)
                    }
                }
                let shown = query.isEmpty
                    ? items.filter { ($0.section.isEmpty ? String(localized: "그 외") : $0.section) == current }
                    : items.filter { item in
                        [item.shown, item.name, item.review ?? ""].contains { $0.filter { !$0.isWhitespace }.lowercased().contains(query) }
                    }
                if !query.isEmpty {
                    Text(shown.isEmpty ? "메뉴에 없어요. ⏎로 적은 그대로 넣어요." : "‘\(typed)’ 들어간 메뉴")
                        .font(.system(size: 12)).foregroundStyle(AppBrand.faint)
                }
                WrapRow(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.element.name) { index, item in
                        menuChip(item, place: place, tab: !query.isEmpty && index == 0)
                    }
                }
                let sources = items.compactMap(\.source).flatMap { $0.components(separatedBy: ", ") }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !sources.isEmpty {
                    Text(String(localized: "출처: ") + sources.prefix(5).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(AppBrand.faint)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
    }

    /// One menu name: on the photo (yellow), the guess (dashed), or neither.
    /// Pressed again, it comes off the photo.
    private func menuChip(_ item: MenuItem, place: String, tab: Bool) -> some View {
        let name = item.shown
        let review = PhotoLibrary.reviewName(name, place: place)
        let on = namesHere.contains(name) || namesHere.contains(review)
        let guessed = !on && guessHere.contains(name)
        return Button {
            if on { remove(namesHere.contains(name) ? name : review) } else { typed = review; add() }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .semibold))
                if guessed {
                    Text("추측").font(.system(size: 10, weight: .bold)).foregroundStyle(AppBrand.signal)
                } else if let other = item.printedOther {
                    Text(other).font(.system(size: 10)).foregroundStyle(on ? AppBrand.ink.opacity(0.6) : AppBrand.faint)
                }
            }
            .foregroundStyle(on ? AppBrand.ink : AppBrand.foreground)
            .padding(.horizontal, 13).padding(.vertical, 7).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(on ? AppBrand.signal : AppBrand.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(on || guessed ? AppBrand.signal : AppBrand.line, style: StrokeStyle(lineWidth: 1, dash: guessed ? [3, 2] : [])))
        }
        .buttonStyle(.plainHit)
        .modifier(TabShortcut(on: tab))
        .help(on ? "다시 누르면 이 사진에서 빼요" : "이 사진에 \(review) 추가")
    }

    /// The menu card's right corner: searching, naming, or the one button.
    @ViewBuilder
    private var menuStatus: some View {
        let menu = library.menuNames[visit.id] ?? []
        let read = library.menuWasRead(for: visit)
        if library.menuLoading.contains(visit.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("웹에서 메뉴 찾는 중").font(.system(size: 12.5)).foregroundStyle(AppBrand.faint)
            }
        } else if library.naming.contains(visit.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("사진마다 맞춰 보는 중").font(.system(size: 12.5)).foregroundStyle(AppBrand.faint)
            }
        } else if menu.isEmpty {
            HStack(spacing: 8) {
                if let hint = library.menuHint[visit.id], !hint.isEmpty {
                    Text(hint).font(.system(size: 12)).foregroundStyle(AppBrand.faint).lineLimit(1)
                }
                // One press is the whole menu; only a search that found
                // nothing or failed offers it again.
                Button(read ? "다시 시도" : "메뉴 찾기") {
                    Task { await library.loadMenu(for: visit, again: true) }
                }
                .buttonStyle(BigSecondaryButtonStyle())
                .help("웹에서 이 가게 메뉴를 찾고, 사진마다 추측을 붙여요.")
            }
        }
    }

    private func key(_ stroke: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(stroke).font(.system(size: 11, weight: .black)).foregroundStyle(AppBrand.muted)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            Text(what).font(.system(size: 11.5)).foregroundStyle(AppBrand.faint)
        }
    }

    // MARK: 아래 — 리뷰에 들어갈 것

    private var writtenStrip: some View {
        WrapRow(spacing: 8, lineSpacing: 8) {
            Text("리뷰에 들어갈 것").font(.system(size: 12)).foregroundStyle(AppBrand.faint)
                .frame(height: 30)
            if written.isEmpty {
                Text("아직 없어요").font(.system(size: 13)).foregroundStyle(AppBrand.faint).frame(height: 30)
            }
            ForEach(written, id: \.text) { item in
                // Removable here too: this strip is the review's contents, and
                // the photo a name was typed under may be pages away by the
                // time the person reads the list back.
                AddedChip(name: item.tag ? PhotoLibrary.tagPhrase(item.text) : item.text, note: nil, filled: !item.tag,
                          liked: item.tag ? nil : library.isLiked(item.text, in: visit),
                          toggleLike: item.tag ? nil : { library.toggleLike(dish: item.text, in: visit) }) {
                    item.tag ? library.toggleTag(item.text, for: visit) : dropName(item.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
    }

    // MARK: 움직임

    private var current: String { here.flatMap { library.photoDishes[visit.id]?[$0.id] } ?? "" }
    private var kindHere: DishNaming.Kind? { here.flatMap { library.photoKinds[visit.id]?[$0.id] } }

    private func named(_ photo: Photo) -> Bool {
        !(library.photoDishes[visit.id]?[photo.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func firstUnnamed() -> Int {
        photos.firstIndex { !named($0) && (library.photoKinds[visit.id]?[$0.id] ?? .food) != .place } ?? 0
    }

    /// The app's guess for this photo, one name per dish — offered, not added.
    private var guessHere: [String] {
        // A kind is not a dish: "스무디" offered as this photo's guess was
        // the menu's own heading.
        let kinds = Set(library.menuItems(for: visit).map { $0.section.filter { !$0.isWhitespace } })
        return PhotoLibrary.dishParts(here.flatMap { library.photoSuggestions[visit.id]?[$0.id] } ?? "")
            .filter { PhotoLibrary.isDish($0) && !kinds.contains($0.filter { !$0.isWhitespace }) }
    }

    /// What has been added for this photo.
    private var namesHere: [String] { PhotoLibrary.dishParts(current) }

    private func add() {
        guard let photo = here else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var names = namesHere
        if !names.contains(name) { names.append(name) }
        library.setPhotoDish(names.joined(separator: ", "), for: photo, in: visit)
        typed = ""
        writing = true
    }

    /// Take a name out of the review from the bottom strip, wherever it was
    /// typed: the photo it belongs to is found and only that one is changed.
    private func dropName(_ name: String) {
        for photo in visit.photos {
            let names = PhotoLibrary.dishParts(library.photoDishes[visit.id]?[photo.id] ?? "")
            guard names.contains(name) else { continue }
            library.setPhotoDish(names.filter { $0 != name }.joined(separator: ", "), for: photo, in: visit)
        }
    }

    private func remove(_ name: String) {
        guard let photo = here else { return }
        library.setPhotoDish(namesHere.filter { $0 != name }.joined(separator: ", "), for: photo, in: visit)
    }

    /// Anything half-typed when the photo changes is kept, not dropped.
    private func commit() {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        add()
    }

    private func step(_ by: Int) {
        let next = at + by
        guard photos.indices.contains(next) else { writing = false; return }
        at = next
    }

    private func skip(remove: Bool) {
        guard let photo = here else { return }
        if remove { library.removePhoto(photo, from: visit) }
        at = min(at, max(photos.count - 2, 0))
    }
}

// MARK: - 4 리뷰

private struct ReviewStep: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let home: () -> Void
    let jump: (FlowStep) -> Void
    let back: () -> Void
    let advance: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    /// A draw was tried for the current empty state and came back with
    /// nothing; only then is a button offered.
    @State private var triedEmpty = false

    var body: some View {
        let options = library.reviewOptions[visit.id] ?? []
        // A draft edited by hand (or joined to an earlier review) is no card's
        // text any more; showing ✓ on the card it started from made it look
        // as if picking that card would change nothing.
        let chosen = library.reviewDrafts[visit.id].flatMap { draft in
            options.contains { $0.id == draft.takeID && draft.text.hasPrefix($0.text) } ? draft.takeID : nil
        }
        // While the two models are compared, the cards are grouped by style so
        // the two versions of the same style sit next to each other.
        let byGenre = options.reduce(into: [(genre: String, note: String, takes: [GenreDraft])]()) { acc, draft in
            if let i = acc.firstIndex(where: { $0.genre == draft.genre }) { acc[i].takes.append(draft) }
            else { acc.append((draft.genre, draft.note, [draft])) }
        }
        FlowScreen(step: .review, title: String(localized: "리뷰"),
                   prose: String(localized: "마음에 드는 표현을 고르세요. 다음 화면에서 고쳐 쓸 수 있고, 영어로도 볼 수 있어요."),
                   right: (library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) } ?? "") + " · " + visit.fullTitle, onHome: home, onStep: jump) {
            if let draft = library.reviewDrafts[visit.id], chosen == nil {
                // What was picked before the dishes or likes changed stays in
                // view, and in the post step, until another card is picked.
                VStack(alignment: .leading, spacing: 6) {
                    Text("전에 고른 문장").font(.system(size: 12, weight: .bold)).foregroundStyle(AppBrand.faint)
                    Text(draft.text).font(.system(size: 15)).foregroundStyle(AppBrand.muted).lineSpacing(3)
                }
                .padding(14).frame(maxWidth: 760, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.raisedSurface.opacity(0.5)))
            }
            if library.drafting.contains(visit.id) || (options.isEmpty && !triedEmpty) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    FlowNote(text: library.reviewDrafts[visit.id] != nil ? String(localized: "메뉴나 좋아요가 바뀌어서 새로 쓰는 중") : String(localized: "세 가지로 써보는 중"))
                }
            } else if options.isEmpty {
                Button("다시 써보기") { Task { await library.draftReview(for: visit, again: true) } }
                    .buttonStyle(BigPrimaryButtonStyle())
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(byGenre, id: \.genre) { card in
                        GenreCard(genre: card.genre, note: card.note, takes: card.takes, chosen: chosen) {
                            library.chooseDraft($0, for: visit)
                        }
                    }
                }
                HStack {
                    FlowNote(text: String(localized: "먹은 것만, 세 가지 표현으로."))
                    Button("다른 표현으로 ↻") { Task { await library.draftReview(for: visit, again: true) } }
                        .buttonStyle(.link).font(.system(size: 15, weight: .bold))
                    Spacer()
                }
            }
        } footer: {
            Button("← 메뉴") { back() }.buttonStyle(BigSecondaryButtonStyle())
            Spacer()
            Button("다음: 올리기 →") { advance() }
                .buttonStyle(BigPrimaryButtonStyle())
                .disabled(library.reviewDrafts[visit.id] == nil)
        }
        // Whatever way the screen was reached — the stepper too — no cards
        // means write them. Only 다음: 리뷰 쓰기 used to start a draw, so a
        // like changed on the dishes step left this screen waiting on a
        // button.
        .task(id: options.isEmpty) {
            guard options.isEmpty else { triedEmpty = false; return }
            await library.draftReview(for: visit)
            triedEmpty = (library.reviewOptions[visit.id] ?? []).isEmpty
        }
    }
}

// MARK: - 5 올리기

private struct PostStep: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let home: () -> Void
    let jump: (FlowStep) -> Void
    let draggable: [String: URL]
    /// Came here by 건너뛰고 사진만 올리기: an empty text is meant.
    var photosOnly = false
    let back: () -> Void
    let done: () -> Void
    @State private var draftText = ""
    @State private var language: Language = .korean
    /// The language the draft itself is written in: the app's. In English
    /// the cards are written in English from the start, so the editor's
    /// text is the English and there is nothing to translate.
    private var draftLanguage: Language { AppLanguage.current.isEnglish ? .english : .korean }
    /// The text's language as it will be posted.
    private var postLanguage: Language { language == .korean ? draftLanguage : .english }
    @State private var googleAccount = ""
    /// Google's form has no "when did you go" field, so people put it in the
    /// text. Off by default, remembered once switched on.
    @AppStorage("includeVisitDate") private var includeVisitDate = false
    /// True once the person chose to carry the earlier review forward and
    /// edit it rather than write a fresh one. It decides one thing: whether
    /// the date line says 방문 or 재방문.
    @State private var editingEarlier = false
    @State private var englishText = ""
    @State private var dragging: String?
    enum Language { case korean, english }

    /// The namer calls a photo "other" when it is neither the food, the table
    /// nor the room — a receipt, say. It also called a named 아보카도 photo
    /// "other" and the post step then dropped it, so a photo the person named
    /// or liked is kept whatever the namer decided.
    private func keep(_ photo: Photo) -> Bool {
        if (library.photoDishes[visit.id]?[photo.id]?.isEmpty == false) { return true }
        if library.isLiked(photo: photo, in: visit) { return true }
        return (library.photoKinds[visit.id]?[photo.id] ?? .food) != .other
    }

    var body: some View {
        let place = library.confirmedPlaces[visit.id]
        let english = library.translation(of: draftText)
        let opened = library.formOpened.contains(visit.id)
        let body = language == .korean ? draftText : (english ?? "")
        let dateLine = Self.visitLine(visit.wallClock, language: postLanguage, again: editingEarlier)
        // The line is put into the text itself rather than appended on copy:
        // the editor has to show what gets pasted.
        let postText = body
        let alreadyPosted = library.posted[visit.id] != nil
        FlowScreen(step: .post, title: alreadyPosted ? String(localized: "리뷰 씀") : String(localized: "올리기"), right: (place.map { PlaceNames.shown($0.name) } ?? "") + " · " + visit.fullTitle, onHome: home, onStep: jump) {
            HStack(alignment: .top, spacing: 32) {
                FlowPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        // No stars here: they are pressed in Google's form (by
                        // design — the app has nothing to do with them).
                        HStack {
                            BrandEyebrow(text: String(localized: "문장"))
                            Spacer()
                            // Korean drafts can be shown in English too; an
                            // English draft already is.
                            if draftLanguage == .korean {
                                Picker("", selection: $language) {
                                    Text(verbatim: "한국어").tag(Language.korean); Text(verbatim: "English").tag(Language.english)
                                }
                                .pickerStyle(.segmented).frame(width: 180)
                                .onChange(of: language) { _, value in if value == .english { Task { await library.translate(for: visit) } } }
                            }
                        }
                        if language == .korean {
                            TextEditor(text: $draftText)
                                .font(.system(size: 17)).lineSpacing(5)
                                .scrollContentBackground(.hidden)
                                // A fixed box that scrolls: with only a floor, carrying
                                // an earlier review in stretched the panel down the
                                // screen.
                                .frame(minHeight: 220, maxHeight: 300)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.raisedSurface))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
                                .onChange(of: draftText) { _, text in library.updateDraft(text, for: visit) }
                        } else if let english {
                            TextEditor(text: $englishText)
                                .font(.system(size: 17)).lineSpacing(5)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220, maxHeight: 300)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.raisedSurface))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
                                .onAppear { englishText = english }
                                .onChange(of: english) { _, value in if englishText != value, !value.isEmpty { englishText = value } }
                                .onChange(of: englishText) { _, text in library.setTranslation(text, for: visit) }
                        } else {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); FlowNote(text: String(localized: "한국어 문장을 영어로 옮기는 중")) }
                                .frame(minHeight: 220)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            FlowNote(text: draftLanguage == .english ? String(localized: "여기서 고치면 저장돼요.")
                                : language == .korean
                                ? String(localized: "여기서 고치면 저장돼요. 영어는 이 문장을 그대로 옮깁니다.")
                                : String(localized: "한국어 최종 문장을 옮긴 영어예요. 여기서 고쳐도 되고, 한국어를 고치면 새로 옮깁니다."))
                            if carried != nil {
                                Spacer(minLength: 0)
                                Button("예전 리뷰 빼기") { removeEarlier() }
                                    .buttonStyle(BigSecondaryButtonStyle())
                                    .help("이어 붙인 예전 문단과 그 날짜 줄을 뺍니다. 이번 방문 문장만 남아요.")
                            }
                        }
                        Toggle(isOn: $includeVisitDate) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("방문 날짜 한 줄 붙이기").font(.system(size: 15, weight: .bold)).foregroundStyle(AppBrand.foreground)
                                Text("구글 리뷰엔 방문 날짜 칸이 없어서 본문에 적어요 — “\(dateLine)”")
                                    .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .onChange(of: includeVisitDate) { _, on in setDateLine(on) }
                        BrandEyebrow(text: String(localized: "사진"))
                        HStack(spacing: 10) {
                            ForEach(visit.photos.filter { keep($0) }.prefix(6)) { photo in
                                DraggablePhoto(photo: photo, fileURL: draggable[photo.id], remove: nil, reorder: $dragging, visit: visit)
                                    .frame(width: 120)
                            }
                        }
                        FlowNote(text: String(localized: "이 순서(왼쪽부터)로 폴더에 번호가 붙어요. 끌어서 순서를 바꿀 수 있어요."))
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    if !alreadyPosted {
                        EarlierReviewNote(visit: visit) { korean, english, date in
                            carryEarlier(korean: korean, english: english, date: date)
                        }
                    }
                    Text("진행 순서").font(.system(size: 18, weight: .black)).foregroundStyle(AppBrand.foreground)
                    VStack(alignment: .leading, spacing: 6) {
                        BrandEyebrow(text: String(localized: "구글 계정 (선택)"))
                        TextField("Safari에 계정이 여러 개면 리뷰를 올릴 이메일", text: $googleAccount)
                            .textFieldStyle(.plain).font(.system(size: 15))
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppBrand.raisedSurface))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
                            .onSubmit { library.setGoogleAccount(googleAccount) }
                            .onChange(of: googleAccount) { _, value in library.setGoogleAccount(value) }
                    }
                    step(1, String(localized: "리뷰창 열기"), String(localized: "문장이 복사된 채로 Safari에 구글 리뷰창이 열려요. 별점을 누르고 ⌘V."), done: opened)
                    step(2, String(localized: "사진 넣기"), String(localized: "‘사진 및 동영상 추가’ → 파일창 왼쪽 즐겨찾기의 Afterplate → 전체 선택(⌘A). 이 폴더엔 지금 이 방문 사진만 있어요. Finder에 선택된 사진을 끌어다 놓아도 돼요."), done: false)
                    if library.postFolder(for: visit) != nil {
                        Button("사진 다시 띄우기") { revealPhotos() }
                            .buttonStyle(BigSecondaryButtonStyle())
                            .help("Finder에 이 방문 사진을 선택된 채로 엽니다")
                    }
                    step(3, String(localized: "게시"), String(localized: "리뷰창을 한 번 훑어보고 게시(Post)를 눌러요. 누르고 오면 아래 ‘리뷰 썼어요’로 이 방문을 마무리해요."), done: alreadyPosted)
                }
                .frame(width: 420)
            }
        } footer: {
            Button(photosOnly ? "← 메뉴" : "← 리뷰") { back() }.buttonStyle(BigSecondaryButtonStyle())
            Spacer()
            if alreadyPosted {
                // Google keeps one review per place per account and opens the
                // existing one for editing, so a written visit is never done
                // with — going back to the list is what the sidebar is for.
                Button("리뷰 다시 올리기 →") { openForm(place, text: postText) }
                    .buttonStyle(BigPrimaryButtonStyle())
                    .disabled(postText.isEmpty || place?.reviewURL == nil)
                    .help("같은 리뷰창이 열려요. 쓴 리뷰가 채워져 있고, 고쳐서 게시하면 덮어써요.")
                Spacer().frame(width: 24)
                Button("아직 안 썼어요") { library.unmarkPosted(visit) }.buttonStyle(BigSecondaryButtonStyle())
            } else {
                let photoOnly = photosOnly && postText.isEmpty
                let ready = (photoOnly || !postText.isEmpty) && place?.reviewURL != nil
                if photoOnly, ready {
                    FlowNote(text: String(localized: "문장 없이 사진만 올려요. 리뷰창에서 별점과 사진만 넣으면 돼요."))
                }
                if !ready {
                    FlowNote(text: place?.reviewURL == nil ? String(localized: "구글에 등록된 가게가 아니라 리뷰창을 열 수 없어요. 가게 단계에서 구글 지도로 찾아 주세요.")
                             : language == .english ? String(localized: "영어 문장이 아직 없어요 — 옮기는 중이거나 한국어 문장이 비어 있어요.") : String(localized: "리뷰 단계에서 문장을 먼저 골라 주세요."))
                }
                VStack(alignment: .trailing, spacing: 6) {
                    Button(opened ? "리뷰창 다시 열기" : photoOnly ? "Safari에서 리뷰창 열기 →" : "복사하고 Safari에서 리뷰창 열기 →") { openForm(place, text: postText) }
                        .buttonStyle(ReviewOpenButtonStyle(primary: true)).disabled(!ready)
                    if !library.googleAccount.isEmpty, ready {
                        HStack(spacing: 8) {
                            Text("\(library.googleAccount) 계정으로 열려요")
                                .font(.system(size: 11)).foregroundStyle(AppBrand.faint)
                            Button("계정 선택 없이 열기") { openForm(place, text: postText, bare: true) }
                                .buttonStyle(.link).font(.system(size: 11, weight: .bold))
                                .help("로그인 화면에서 멈추면: Safari에 로그인된 계정으로 바로 열어요")
                        }
                    }
                }
                // Opening the form stays the big button, even after the first
                // open: making "리뷰 썼어요" the primary one put the finish
                // button where the open button had just been, and it was hit
                // by mistake twice — once mid-draft, once instead of opening
                // the form. Finishing is a quieter button, set
                // apart, and it says what it does next.
                if opened {
                    Spacer().frame(width: 24)
                    Button("다 썼어요 · 다음 방문 →") { library.markPosted(visit); done() }
                        .buttonStyle(BigSecondaryButtonStyle())
                        .help("이 방문을 리뷰 씀으로 표시하고 다음 방문을 엽니다")
                }
            }
        }
        .onChange(of: visit.id, initial: true) { _, _ in
            draftText = library.reviewDrafts[visit.id]?.text ?? ""
            language = .korean
            googleAccount = library.googleAccount
            // The checkbox is remembered between visits; the line has to be in
            // the text of this one too, not only when the box is clicked.
            editingEarlier = false
            if includeVisitDate { setDateLine(true) }
        }
        .onChange(of: library.reviewDrafts[visit.id]?.text) { _, text in
            // Our own edits go out through updateDraft and come back equal;
            // anything else — a card picked on the review step, a restore —
            // replaces what is in the box.
            if let text, text != draftText {
                draftText = text
                if includeVisitDate { setDateLine(true) }
            }
        }
    }

    /// "2025년 1월 2일 방문" / "Visited on 2 January 2025". Copy the text, write
    /// the photo folder and open Google's form — the same three steps
    /// whether this is the first time or a rewrite. `bare`: straight to the
    /// form, without Google's account chooser — for when the chooser stops
    /// at a sign-in page although Safari is signed in.
    private func openForm(_ place: PlaceCandidate?, text: String, bare: Bool = false) {
        // Photos only: leave the clipboard as it was.
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let eligible = visit.photos.filter { keep($0) }
        let url = place?.reviewURL(language: postLanguage == .korean ? "ko" : "en", account: bare ? nil : library.googleAccount)
        library.markFormOpened(visit)
        Task {
            _ = await library.preparePost(photos: eligible, for: visit)
            // The photos come to the person, selected in Finder, ready to drag
            // onto Google's photo box. Safari's file dialog remembers its own
            // last folder and cannot be pointed at ours without a permission
            // ruled out by design; it kept opening somewhere else.
            revealPhotos()
            if let url { Self.open(url) }
        }
    }

    /// This visit's copies in ~/Pictures/Afterplate, selected in a Finder window.
    private func revealPhotos() {
        let folder = library.postFolderURL(for: visit)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(library.postFileStem(for: visit)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [folder] : files)
    }

    /// Put the visit line into both texts, or take it out of both, so the
    /// editor shows exactly what will be pasted into Google's form.
    /// The text without the date line the app itself put on it for `date` —
    /// wherever that line sits, since with two visits in one review the
    /// current visit's line is not always the last one.
    private static func withoutDateLine(_ text: String, of date: Date) -> String {
        let lines = Set(visitLines(date))
        var kept = text.components(separatedBy: "\n")
            .filter { !lines.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
        while kept.contains("\n\n\n") { kept = kept.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasDateLine(_ text: String, of date: Date) -> Bool {
        let lines = Set(visitLines(date))
        return text.components(separatedBy: "\n").contains { lines.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Google keeps one review per place, shows only the date it was last
    /// edited, and folds a long review behind 더보기 after a few lines. So
    /// the way people update one is a paragraph per visit, each with its
    /// own date, the latest visit on top where it is read first and the
    /// earlier one under it; whichever visit came later says 재방문.
    private func carryEarlier(korean: String, english: String, date: Date) {
        // Every visit is its own dated paragraph, however many there were:
        // the earlier review is read back into paragraphs by their date
        // lines, this visit's text joins them, and they are laid out again
        // newest first — the first visit says 방문, every later one 재방문.
        // Written for two visits, it treated a review that already held two
        // as one paragraph and a third visit came out shuffled with one
        // 재방문.
        func joined(_ old: String, _ mine: String, _ language: Language) -> String {
            var byDay: [Date: String] = [:]
            // A paragraph with no date line of its own is the earlier
            // visit's (a review posted before dates were added).
            let earlierDay = Calendar.current.startOfDay(for: date)
            for para in Self.paragraphs(of: old) {
                let day = para.day ?? earlierDay
                byDay[day] = [byDay[day], para.body].compactMap { $0 }.joined(separator: "\n\n")
            }
            // This visit: its undated text plus anything under its own date,
            // with any earlier paragraph already carried in left out.
            let oldBodies = Set(byDay.values)
            let myDay = Calendar.current.startOfDay(for: visit.wallClock)
            let myBody = Self.paragraphs(of: mine)
                .filter { ($0.day == nil || $0.day == myDay) && !oldBodies.contains($0.body) }
                .map(\.body).joined(separator: "\n\n")
            if !myBody.isEmpty { byDay[myDay] = myBody }
            let first = byDay.keys.min()
            return byDay.keys.sorted(by: >).map { day in
                byDay[day]! + "\n\n" + Self.visitLine(day, language: language, again: day != first)
            }.joined(separator: "\n\n")
        }
        draftText = joined(korean, draftText, draftLanguage)
        editingEarlier = Self.paragraphs(of: draftText).compactMap(\.day).min().map { $0 < Calendar.current.startOfDay(for: visit.wallClock) } ?? false
        library.updateDraft(draftText, for: visit)
        if !english.isEmpty, !englishText.isEmpty {
            englishText = joined(english, englishText, .english)
            library.setTranslation(englishText, for: visit)
        }
        if !includeVisitDate { includeVisitDate = true }
    }

    /// A review read back as paragraphs, each closed by a visit line the app
    /// writes ("2025년 1월 2일 재방문", "Visited on 2 January 2025"); text
    /// after
    /// the last line is a paragraph with no date.
    private static func paragraphs(of text: String) -> [(body: String, day: Date?)] {
        var out: [(String, Date?)] = []
        var lines: [String] = []
        func close(_ day: Date?) {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty || day != nil { out.append((body, day)) }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            if let day = visitDay(line.trimmingCharacters(in: .whitespaces)) { close(day) } else { lines.append(line) }
        }
        close(nil)
        return out.filter { !$0.0.isEmpty }
    }

    /// The day a visit line names, or nil if the line is not one.
    private static func visitDay(_ line: String) -> Date? {
        let korean = DateFormatter()
        korean.locale = Locale(identifier: "ko_KR"); korean.dateFormat = "yyyy년 M월 d일"
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US"); english.dateFormat = "d MMMM yyyy"
        for suffix in [" 재방문", " 방문"] where line.hasSuffix(suffix) {
            if let d = korean.date(from: String(line.dropLast(suffix.count))) { return Calendar.current.startOfDay(for: d) }
        }
        for prefix in ["Updated after visiting again on ", "Visited on "] where line.hasPrefix(prefix) {
            if let d = english.date(from: String(line.dropFirst(prefix.count))) { return Calendar.current.startOfDay(for: d) }
        }
        return nil
    }

    /// The earlier review, if one was carried into this draft.
    private var carried: (korean: String, english: String, date: Date)? {
        guard let earlier = library.earlierPost(samePlaceAs: visit) else { return nil }
        // Carried when every paragraph of it is in the draft — its date
        // lines may have been relabelled on the way in.
        let bodies = Self.paragraphs(of: earlier.korean).map(\.body)
        guard !bodies.isEmpty, bodies.allSatisfy({ draftText.contains($0) }) else { return nil }
        return (earlier.korean, earlier.english, earlier.visit.wallClock)
    }

    /// Undo of 이어 쓰기: the earlier paragraph and its date line go, this
    /// visit's line goes back to plain 방문.
    private func removeEarlier() {
        guard let carried else { return }
        func without(_ text: String, _ old: String) -> String {
            let oldBodies = Set(Self.paragraphs(of: old).map(\.body))
            return Self.paragraphs(of: text).filter { !oldBodies.contains($0.body) }.map(\.body)
                .joined(separator: "\n\n")
        }
        editingEarlier = false
        draftText = without(draftText, carried.korean)
        library.updateDraft(draftText, for: visit)
        if !englishText.isEmpty {
            englishText = without(englishText, carried.english)
            library.setTranslation(englishText, for: visit)
        }
        if includeVisitDate { setDateLine(true) }
    }

    private func setDateLine(_ on: Bool) {
        func apply(_ text: String, _ line: String) -> String {
            // Already there (possibly mid-text, after a carried review): leave it.
            if on, Self.hasDateLine(text, of: visit.wallClock) { return text }
            let body = Self.withoutDateLine(text, of: visit.wallClock)
            guard on, !body.isEmpty else { return body }
            return body + "\n\n" + line
        }
        let korean = apply(draftText, Self.visitLine(visit.wallClock, language: draftLanguage, again: editingEarlier))
        if korean != draftText { draftText = korean; library.updateDraft(korean, for: visit) }
        if !englishText.isEmpty {
            let english = apply(englishText, Self.visitLine(visit.wallClock, language: .english, again: editingEarlier))
            if english != englishText { englishText = english; library.setTranslation(english, for: visit) }
        }
    }

    /// Google takes one review per place, so a second visit is an edit of the
    /// first — and the convention among reviewers is to say so with a date
    /// rather than to quietly replace the text. `again` writes that line.
    private static func visitLine(_ date: Date, language: Language, again: Bool = false) -> String {
        let formatter = DateFormatter()
        if language == .korean {
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월 d일"
            return formatter.string(from: date) + (again ? " 재방문" : " 방문")
        }
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMMM yyyy"
        return (again ? "Updated after visiting again on " : "Visited on ") + formatter.string(from: date)
    }

    /// Every wording the line has ever had, so switching the checkbox off
    /// removes whichever one is in the text.
    private static func visitLines(_ date: Date) -> [String] {
        [(Language.korean, false), (.korean, true), (.english, false), (.english, true)]
            .map { visitLine(date, language: $0.0, again: $0.1) }
    }

    private func step(_ n: Int, _ title: String, _ body: String, done: Bool) -> some View {
        // Plain numerals, not circles: the circles read as buttons.
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if done {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .black)).foregroundStyle(AppBrand.signal).frame(width: 22)
            } else {
                Text("\(n)").font(.system(size: 17, weight: .black)).foregroundStyle(AppBrand.faint).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .heavy)).foregroundStyle(AppBrand.foreground)
                Text(body).font(.system(size: 14)).foregroundStyle(AppBrand.muted).lineSpacing(3)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
    }

    /// Safari: the review form needs the user's own Google session, which
    /// lives in their browser.
    private static func open(_ url: URL) {
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Shared pieces

/// One style, with every take on it — two while the models are compared.
struct GenreCard: View {
    let genre: String
    let note: String
    let takes: [GenreDraft]
    let chosen: String?
    let choose: (GenreDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(genre).font(.system(size: 17, weight: .black)).foregroundStyle(AppBrand.foreground)
                Text(note).font(.system(size: 12)).foregroundStyle(AppBrand.faint)
                Spacer()
            }
            ForEach(takes) { take in
                GenreTake(take: take, chosen: chosen == take.id) { choose(take) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
    }
}

private struct GenreTake: View {
    let take: GenreDraft
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                Text(take.text)
                    .font(.system(size: 15)).lineSpacing(5)
                    .foregroundStyle(chosen ? AppBrand.foreground : AppBrand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(chosen ? "이 표현으로 ✓" : "이 표현으로")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(chosen ? AppBrand.ink : AppBrand.foreground)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(chosen ? AppBrand.signal : AppBrand.raisedSurface))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hovering || chosen ? AppBrand.raisedSurface : AppBrand.ink.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(chosen ? AppBrand.signal : AppBrand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { hovering = $0 }
    }
}

/// A photo that can be dragged straight into another app — the browser's
/// review composer — with an optional ✕ to take it out of the visit.
struct DraggablePhoto: View {
    static func length(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo
    let fileURL: URL?
    let remove: (() -> Void)?
    /// No "preparing" spinner — for strips that never drag.
    var quiet = false
    /// Drag-and-drop reordering within `visit`: the parent's record of which
    /// photo is being dragged, shared by every tile in the row.
    var reorder: Binding<String?>? = nil
    var visit: Visit? = nil
    @State private var hovering = false

    var body: some View {
        PhotoTile(photo: photo)
            .overlay(alignment: .topTrailing) {
                if fileURL == nil, !quiet { ProgressView().controlSize(.small).padding(8) }
            }
            .overlay(alignment: .topLeading) {
                if hovering, let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AppBrand.foreground)
                            .frame(width: 22, height: 22).background(Circle().fill(AppBrand.ink.opacity(0.85)))
                    }
                    .buttonStyle(.plainHit).padding(8).help("이 방문에서 빼기")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .black))
                        Text(Self.length(photo.duration)).font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(AppBrand.foreground)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(AppBrand.ink.opacity(0.8)))
                    .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Button { library.rotate(photo) } label: {
                        Image(systemName: "rotate.right").font(.system(size: 11, weight: .bold)).foregroundStyle(AppBrand.foreground)
                            .frame(width: 24, height: 24).background(Circle().fill(AppBrand.ink.opacity(0.85)))
                    }
                    .buttonStyle(.plainHit).padding(8).help("시계 방향으로 돌리기 — 올릴 때 이 방향으로 나가요")
                }
            }
            .onHover { hovering = $0 }
            .opacity(reorder?.wrappedValue == photo.id ? 0.4 : 1)
            .onDrag {
                if let reorder {
                    // Reordering: the tile itself is what moves.
                    reorder.wrappedValue = photo.id
                    return NSItemProvider(object: photo.id as NSString)
                }
                // A file that already exists, not a promise: browsers accept
                // this, and a promised-file provider is why dragging into the
                // Google review composer once did nothing.
                guard let fileURL, let provider = NSItemProvider(contentsOf: fileURL) else { return NSItemProvider() }
                provider.suggestedName = fileURL.lastPathComponent
                return provider
            }
            .onDrop(of: [.text], delegate: ReorderDrop(target: photo, visit: visit, dragging: reorder, library: library))
    }
}

/// Reordering by drag: as the dragged tile passes over another, it takes
/// that slot — the row rearranges live, and the drop just ends it.
struct ReorderDrop: DropDelegate {
    let target: Photo
    let visit: Visit?
    let dragging: Binding<String?>?
    let library: PhotoLibrary

    func dropEntered(info: DropInfo) {
        guard let visit, let dragged = dragging?.wrappedValue, dragged != target.id else { return }
        library.movePhoto(dragged, over: target.id, in: visit)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging?.wrappedValue = nil; return true }
    func dropExited(info: DropInfo) {}
}

/// All of a visit's photos, small: hover for ✕, click to see one large, and
/// a cut offered wherever twenty minutes or more passed between shots.
struct VisitPhotoStrip: View {
    @EnvironmentObject private var library: PhotoLibrary
    @State private var dragging: String?
    let visit: Visit
    let home: () -> Void
    @Binding var enlarged: Photo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        // The reverse of "여기서 나누기": one lunch that GPS drift cut into
        // three visits, all at 오전 10시, joins back up here.
        if let earlier = library.previousVisit(before: visit) {
            Button {
                library.mergeWithPrevious(visit); home()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.merge").font(.system(size: 12, weight: .bold))
                    Text("앞 방문과 합치기 — \(earlier.title), 사진 \(earlier.photos.count)장")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(AppBrand.signal)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(AppBrand.signal.opacity(0.1)))
                .overlay(Capsule().stroke(AppBrand.signal.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plainHit)
            .help("한 끼인데 둘로 나뉘었으면 눌러 주세요. 실내에서 GPS가 흔들리면 이렇게 갈라져요.")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Array(visit.photos.enumerated()), id: \.element.id) { index, photo in
                let pause = index > 0 ? photo.takenAt.timeIntervalSince(visit.photos[index - 1].takenAt) : 0
                VStack(spacing: 6) {
                    DraggablePhoto(photo: photo, fileURL: nil, remove: { library.removePhoto(photo, from: visit) }, quiet: true, reorder: $dragging, visit: visit)
                        .onTapGesture { enlarged = photo }
                    if pause >= 20 * 60 {
                        Button {
                            library.splitVisit(visit, at: photo); home()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors").font(.system(size: 10, weight: .bold))
                                Text("\(Int(pause / 60))분 뒤 · 여기서 나누기").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(AppBrand.signal)
                        }
                        .buttonStyle(.plainHit)
                    } else {
                        // Shots seconds apart need no label; "+0분" was noise.
                        if index > 0, pause >= 60 { Text("+\(Int(pause / 60))분").font(.system(size: 11)).foregroundStyle(AppBrand.faint) }
                    }
                }
            }
        }
        // The × is on these tiles as well as the dishes step's, so the way
        // back belongs here too — a photo taken out on the place screen had
        // nowhere to come back from.
        RemovedStrip(visit: visit)
        }
    }
}

extension View {
    /// The in-place enlarged photo: dimmed backdrop, Esc or click to close.
    func enlargeOverlay(_ photo: Binding<Photo?>, caption: String?) -> some View {
        overlay {
            if let shown = photo.wrappedValue {
                ZStack {
                    Color.black.opacity(0.82).ignoresSafeArea().onTapGesture { photo.wrappedValue = nil }
                    VStack(spacing: 14) {
                        LargePhoto(photo: shown)
                        Text(String(localized: "클릭하거나 Esc로 닫기") + (caption.map { $0.isEmpty ? "" : " · \($0)" } ?? ""))
                            .font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                    }
                    .padding(40)
                }
                .onExitCommand { photo.wrappedValue = nil }
            }
        }
    }
}

/// The enlarged view: the photo at up to 1600px, fitted to the window.
struct LargePhoto: View {
    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    /// The clip's own width ÷ height as it plays upright. A fixed 16:9 box
    /// put a portrait clip in a landscape frame.
    @State private var videoAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        Group {
            if photo.isVideo, let player {
                // AppKit's player view, not SwiftUI's VideoPlayer: the
                // SwiftUI one crashed the app on open — the Swift runtime
                // could not build _AVKit_SwiftUI's class metadata and called
                // fatalError. Turned by the same ↻ as its tile, so what
                // plays is what the tile shows and what gets posted.
                let turn = library.rotation(of: photo)
                let sideways = turn == 90 || turn == 270
                GeometryReader { box in
                    PlayerView(player: player)
                        .frame(width: sideways ? box.size.height : box.size.width,
                               height: sideways ? box.size.width : box.size.height)
                        .rotationEffect(.degrees(Double(turn)))
                        .frame(width: box.size.width, height: box.size.height)
                }
                .aspectRatio(sideways ? 1 / videoAspect : videoAspect, contentMode: .fit)
                .onAppear { player.play() }
                .onDisappear { player.pause() }
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: 1400, maxHeight: 760)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: "\(photo.id)/\(library.rotation(of: photo))") {
            image = nil
            player = nil
            if photo.isVideo, let item = await library.playerItem(for: photo) {
                if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let upright = size.applying(transform)
                    if abs(upright.height) > 0 { videoAspect = abs(upright.width) / abs(upright.height) }
                }
                player = AVPlayer(playerItem: item)
            } else {
                image = await library.thumbnail(for: photo, side: 1600)
            }
        }
    }
}

/// AVKit's own view, wrapped. It brings the standard transport controls and
/// carries no SwiftUI overlay to fail to load.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Photos taken out of this visit, to put back.
struct RemovedStrip: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    @State private var expanded = false

    /// Seven taken-out photos in a row ran off the side of the screen and
    /// under the menu panel. Closed, they are a stack with a count; opened,
    /// they wrap.
    var body: some View {
        let removed = library.removedPhotos(from: visit)
        if !removed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if !expanded {
                        HStack(spacing: -22) {
                            ForEach(removed.prefix(3)) { photo in
                                PhotoTile(photo: photo)
                                    .frame(width: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(AppBrand.surface, lineWidth: 2))
                                    .opacity(0.55)
                            }
                        }
                    }
                    Text("뺀 사진 \(removed.count)장")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(AppBrand.faint)
                    Button(expanded ? "접기" : "보기") { expanded.toggle() }
                        .buttonStyle(.link).font(.system(size: 13, weight: .bold))
                    if removed.count > 1 {
                        Button("모두 되돌리기") { library.restoreAll(to: visit) }
                            .buttonStyle(.link).font(.system(size: 13, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
                if expanded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(removed) { photo in
                            Button { library.restorePhoto(photo, to: visit) } label: {
                                PhotoTile(photo: photo)
                                    .frame(width: 72)
                                    .opacity(0.5)
                                    .overlay {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(AppBrand.foreground)
                                    }
                            }
                            .buttonStyle(.plainHit)
                            .help("이 방문에 다시 넣기")
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct PhotoTile: View {
    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(AppBrand.raisedSurface)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: "\(photo.id)/\(library.rotation(of: photo))") {
                image = nil
                image = await library.thumbnail(for: photo, side: 480)
            }
    }
}


/// The open-form button: primary until the form has been opened once, then
/// secondary so 올렸어요 leads.
struct ReviewOpenButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        if primary { BigPrimaryButtonStyle().makeBody(configuration: configuration) }
        else { BigSecondaryButtonStyle().makeBody(configuration: configuration) }
    }
}
