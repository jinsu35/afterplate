import SwiftUI

/// The feed is one conversation across visits, in the order things were
/// said. Going back to an earlier visit never reopens it where it was: the
/// question is asked again at the bottom, under whatever came since, with
/// the visit named again above it (changing the past in
/// place is the time machine that confuses).

/// A visit's photos: in full the first time it comes up, as a small
/// reminder when the conversation returns to it.
struct ThreadHeader: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let compact: Bool

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                ForEach(Array(visit.photos.prefix(3)), id: \.id) { photo in
                    PhotoTile(photo: photo).frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .peekable(photo, in: visit)
                        .throwable(photo, from: visit)
                }
                Text([visit.fullTitle, library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.muted).lineLimit(1)
                VisitWhereButton(visit: visit, size: 13)
                Spacer()
            }
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(visit.fullTitle).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                    VisitWhereButton(visit: visit, size: 13)
                }
                HStack(spacing: 8) {
                    ForEach(Array(visit.photos.prefix(4).enumerated()), id: \.element.id) { index, photo in
                        PhotoTile(photo: photo)
                            .frame(maxWidth: index == 0 ? .infinity : 170, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .peekable(photo, in: visit)
                            .throwable(photo, from: visit)
                    }
                }
                .frame(height: 220)
                .onceTip(.photos, at: visit.id, symbol: "hand.draw",
                         text: String(localized: "사진을 밖으로 끌어 놓으면 리뷰에서 빠져요 · 누르면 크게 봐요"))
            }
        }
    }
}

/// One line of the record. An answer — the question and the reply together
/// — is one thing to press: either half asks it again at the bottom.
/// Each answer bubble's top in the conversation.
struct AnswerTops: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue()) { $1 } }
}

struct ThreadEntryView: View {
    static func bubbleID(_ id: UUID) -> String { "bubble/\(id.uuidString)" }

    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject private var threads = VisitThreads.shared
    let entry: ThreadEntry
    let visit: Visit
    let locked: Bool
    /// Shown above a question asked again: no visit line of its own.
    var under = false
    @Environment(\.goBack) private var goBack
    @State private var hovering = false
    /// Asking whether to answer it again.
    @State private var asking = false
    /// Held down: answered again without asking, and the click that ends
    /// the press does not ask afterwards.
    @State private var held = false

    /// What was said, in the app's language now: the record keeps the
    /// words as said, so a Korean thread read in English is said again from
    /// what each line was — the question from its step, a set answer from
    /// the catalog; names and written text stay as they are.
    private var said: (question: String, answer: String) {
        let raw = saidAsRecorded
        // The record keeps the listing's name; it is shown with its reading.
        return entry.key == .place ? (raw.question, PlaceNames.shown(raw.answer)) : raw
    }

    private var saidAsRecorded: (question: String, answer: String) {
        if AppLanguage.current.isEnglish, entry.key == nil {
            return (Bundle.main.localizedString(forKey: entry.question, value: nil, table: nil),
                    Bundle.main.localizedString(forKey: entry.answer, value: nil, table: nil))
        }
        guard AppLanguage.current.isEnglish, let key = entry.key else {
            // The record keeps "장소 수정할게요. 어디서 드셨어요?"; the first
            // half is said as the app's line above it.
            if entry.label == ThreadActions.revisedLabel, let key = entry.key {
                let lead = ThreadActions.revisedLead(key) + " "
                if entry.question.hasPrefix(lead) { return (String(entry.question.dropFirst(lead.count)), entry.answer) }
            }
            return (entry.question, entry.answer)
        }
        let step: ThreadStep = switch key {
        case .place: .place
        case .dishes: .dishes
        case .taste: .taste(entry.dish ?? "")
        case .scene: .scene
        case .draft: .draft
        case .post: .post
        }
        var question = ThreadActions.asked(step, library: library, visit: visit).1
        if entry.question.contains("보관할까요") { question = ThreadActions.archiveQuestion }
        if entry.question.contains("다 올렸어요") { question = String(localized: "다 올렸어요?") }
        return (question, Bundle.main.localizedString(forKey: entry.answer, value: nil, table: nil))
    }

    /// Going back is not something to do often: a click asks first, a
    /// press held down is the shortcut.
    private func press() {
        if held { held = false; return }
        asking = true
    }

    /// Asks it again at the bottom; that answer replaces this one, so what
    /// came before it is not brought back.
    private func again() {
        asking = false
        if let goBack { goBack(entry, visit) } else { ThreadActions(library: library, visit: visit).reopenOrTakeUp(entry) }
    }

    /// What this change made moot, folded away above it.
    private var folded: [ThreadEntry] { threads.moot(by: entry, in: visit.id) }

    /// The app saying what the change did, in place of the old thread.
    private var summary: String? {
        guard !folded.isEmpty else { return nil }
        switch entry.key {
        case .place: return String(localized: "장소를 \(entry.from)에서 \(Self.toward(entry.answer)) 바꿨어요. 메뉴부터 다시 정할게요.")
        case .dishes: return String(localized: "메뉴를 바꿨어요. 맛과 글은 다시 정할게요.")
        default: return nil
        }
    }

    /// "카페로", "식당으로": 으로 after a final consonant other than ㄹ.
    static func toward(_ name: String) -> String {
        if AppLanguage.current.isEnglish { return name }
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return name + "로" }
        let final = (last.value - 0xAC00) % 28
        return name + (final == 0 || final == 8 ? "로" : "으로")
    }

    var body: some View {
        switch entry.kind {
        case .answer:
            // Put off and still put off (its visit's last answer): pressed,
            // the visit is taken up now.
            let putOff = ThreadActions.putOff(entry)
            let live = !locked && entry.key != nil
                && (!putOff || threads.thread(visit.id).entries.last(where: { $0.kind == .answer })?.id == entry.id)
            VStack(alignment: .trailing, spacing: 10) {
            // Answered again: what the app said before asking, as it said
            // it at the bottom, so answering moves nothing (the visit and
            // a ⋯ over every change crowded the record).
            if entry.label == ThreadActions.revisedLabel, let key = entry.key {
                RevisedLead(key: key)
            }
            Button(action: press) {
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(said.question).font(.system(size: 17))
                            .foregroundStyle(hovering && live ? AppBrand.foreground : AppBrand.muted)
                        if !entry.from.isEmpty {
                            Text(entry.from).font(.system(size: 14)).strikethrough().foregroundStyle(AppBrand.faint).lineLimit(1)
                        }
                        if live {
                            Image(systemName: "arrow.uturn.down").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AppBrand.faint).opacity(hovering ? 1 : 0.6)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hovering && live ? AppBrand.raisedSurface : AppBrand.surface.opacity(0.6)))
                    // From the question pressed, not the middle of the
                    // row.
                    .popover(isPresented: $asking, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(ThreadActions.putOff(entry) ? "이 방문 지금 할까요?" : "이 질문에 다시 답할까요?").font(.system(size: 15, weight: .bold))
                            HStack(spacing: 10) {
                                Spacer()
                                Button("그대로 두기") { asking = false }.keyboardShortcut(.cancelAction)
                                Button(ThreadActions.putOff(entry) ? "지금 할게요" : "다시 답하기", action: again).keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(18).frame(width: 280)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let drafts = entry.drafts {
                        VStack(spacing: 8) {
                            ForEach(drafts, id: \.self) { draft in
                                DraftCard(genre: draft.genre, text: draft.text)
                            }
                        }
                        .opacity(0.7)
                        .padding(.trailing, 52)
                    }
                    Text(said.answer)
                        .font(.system(size: 17, weight: .bold)).lineSpacing(4)
                        .foregroundStyle(locked ? AppBrand.muted : AppBrand.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)
                            .fill(locked ? AppBrand.raisedSurface : AppBrand.signal))
                        .frame(maxWidth: 560, alignment: .trailing)
                        // Where the answer is, for the conversation to keep
                        // it in sight after it (see FeedView's follow).
                        // The copy above a question asked again is not the answer's place.
                        .id(under ? "under/\(entry.id.uuidString)" : Self.bubbleID(entry.id))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AnswerTops.self, value: under ? [:] : [entry.id: g.frame(in: .named(FeedView.feedSpace)).minY])
                        })
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .disabled(!live)
            .onHover { hovering = $0 }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard live else { return }
                held = true
                again()
            })
            // Said once: under the first answer that can be pressed, and
            // under the first visit put off.
            .onceTip(putOff ? .later : .answer, at: entry.id.uuidString, eligible: live && !under, alignment: .trailing,
                     symbol: "arrow.uturn.down",
                     text: putOff ? String(localized: "누르면 이 방문을 언제든 다시 할 수 있어요")
                                  : String(localized: "답을 누르면 다시 고를 수 있어요"))
            if !under, let summary {
                Text(summary).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            }
        case .change:
            HStack(spacing: 10) {
                Text(entry.label).font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.muted)
                Text(entry.from).strikethrough().foregroundStyle(AppBrand.faint).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(AppBrand.muted)
                Text(entry.to).font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.foreground).lineLimit(1)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        case .closing:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(AppBrand.signal)
                Text(entry.answer).font(.system(size: 20, weight: .black)).tracking(-0.3).foregroundStyle(AppBrand.foreground)
                Spacer()
            }
            .padding(.top, 6)
        case .note where entry.label == ThreadActions.redraftLabel || entry.label == ThreadActions.askAgainLabel:
            Text(entry.label == ThreadActions.redraftLabel ? ThreadActions.redraftLine : ThreadActions.askAgainLine).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note where entry.label == ThreadActions.photoOutLabel && !entry.from.isEmpty:
            HStack(spacing: 10) {
                Text(entry.label).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                if library.removedPhoto(entry.from) != nil {
                    Button { ThreadActions(library: library, visit: visit).restorePhoto(entry.from) } label: {
                        Text("되돌리기").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.muted).underline(color: AppBrand.faint)
                    }
                    .buttonStyle(.plainHit)
                }
            }
            .frame(maxWidth: .infinity)
        case .note:
            Text([entry.label, entry.to].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.system(size: 13)).foregroundStyle(AppBrand.faint)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The one question in front of the person, for one visit. Every question
/// offers the likely answers, a way to say something else, and a way past
/// — no dead ends.
struct ThreadQuestion: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject private var threads = VisitThreads.shared
    let visit: Visit
    /// The conversation came back to this visit from another one.
    var resumed = false
    @State private var picked: [String] = []
    @State private var typed = ""
    @State private var pickerOpen = false
    @State private var searching = false
    @State private var found: [PlaceCandidate] = []
    /// Redraws after the posting how-to is turned off.
    @State private var guideTick = 0
    /// Typing the dishes without waiting for the menu search.
    @State private var writeAnyway = false
    /// The place chips picked so far.
    @State private var sceneTags: [String] = []

    private var actions: ThreadActions { ThreadActions(library: library, visit: visit) }

    var body: some View {
        let step = threads.step(visit.id)
        Group {
            if step != .done { question(step) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Whatever question it is at: a thin menu is searched again once the
        // place is settled, so the dishes can be picked again from it.
        .task(id: library.confirmedPlaces[visit.id]?.googlePlaceID) { await researchThinMenu() }
        // A menu found only in English gets Korean chips before they are
        // shown; in the English app, a menu with no English gets English.
        .task(id: "\(library.confirmedPlaces[visit.id]?.googlePlaceID ?? "")|\(library.menuNames[visit.id]?.count ?? 0)") {
            await library.fillKoreanNames(for: visit)
            await library.fillEnglishNames(for: visit)
        }
        // At this level, not inside the question: the question gives way to
        // the waiting line once writing starts, and a task inside it would be
        // cancelled with the writing half done.
        .task(id: step == .draft ? threads.draftKey(visit.id) : "") {
            if threads.step(visit.id) == .draft { await actions.ensureDrafts() }
        }
        .onChange(of: stepID(step)) { _, _ in reset(for: step) }
        .task(id: stepID(step)) { reset(for: step) }
        // Readings for the names offered, in a script the reader may not read.
        .task(id: step == .place ? "\(visit.id)|\(library.placeCandidates[visit.id]?.count ?? 0)" : "") {
            guard threads.step(visit.id) == .place else { return }
            let offered = (library.placeMatches[visit.id]?.picks.map(\.id) ?? []).compactMap { id in library.placeCandidates[visit.id]?.first { $0.id == id }?.name }
                + (library.placeCandidates[visit.id] ?? []).prefix(8).map(\.name)
            await PlaceNames.fill(offered, library: library)
        }
    }

    private func stepID(_ step: ThreadStep) -> String {
        switch step {
        case .place: "place"
        case .dishes: "dishes"
        case .taste(let d): "taste/\(d)"
        case .scene: "scene"
        case .draft: "draft"
        case .post: "post"
        case .done: "done"
        }
    }

    private func reset(for step: ThreadStep) {
        typed = ""
        found = []
        pickerOpen = false
        writeAnyway = false
        showAllDishes = false
        showAllPlaces = false
        if step == .dishes {
            picked = threads.thread(visit.id).facts.dishes ?? library.dishNames(for: visit)
        }
        if step == .scene {
            sceneTags = threads.thread(visit.id).facts.scene ?? library.tags[visit.id] ?? []
        }
    }

    // MARK: The question

    @ViewBuilder
    private func question(_ step: ThreadStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if threads.thread(visit.id).facts.askArchive == true {
                archiveQuestion(step)
            } else {
            switch step {
            case .place: placeQuestion
            case .dishes: dishQuestion
            case .taste(let dish): tasteQuestion(dish)
            case .scene: sceneQuestion
            case .draft: draftQuestion
            case .post: postQuestion
            case .done: EmptyView()
            }
            }
        }
    }

    /// Put off three times running at this question.
    @ViewBuilder
    private func archiveQuestion(_ step: ThreadStep) -> some View {
        Color.clear.frame(height: 0).preference(key: AskedLine.self, value: ThreadActions.archiveQuestion)
        HStack(spacing: 10) {
            Button { actions.archive(at: step) } label: { Text("보관할게요") }.buttonStyle(BigPrimaryButtonStyle())
            Button { actions.notYet(at: step) } label: { Text("아직 아니에요") }.buttonStyle(BigSecondaryButtonStyle())
            Spacer()
        }
        Text("보관한 방문은 지난 리뷰 · 지도의 보관함에서 다시 꺼낼 수 있어요.")
            .font(.system(size: 14)).foregroundStyle(AppBrand.muted)
    }

    /// The question is said in the conversation above (`AskedLine`); here,
    /// over the answers, only the ways past it (the
    /// answers sit in a panel at the bottom, like a chat's keyboard).
    /// The question, said in the conversation above (`AskedLine`).
    private func asking(_ text: String) -> some View {
        Color.clear.frame(height: 0).preference(key: AskedLine.self, value: text)
    }

    /// The ways past a question, looking like what they are:
    /// buttons.
    private func ways(_ list: [(String, () -> Void)], step: ThreadStep) -> some View {
        let again = threads.reopened[visit.id] != nil
        let all = (again ? [(String(localized: "그대로 둘게요"), { actions.keepAsItWas() })] : []) + list
            + (again ? [] : [(String(localized: "이 방문은 나중에 할게요"), { actions.later(at: step) })])
        return HStack(spacing: 8) {
            ForEach(Array(all.enumerated()), id: \.offset) { _, way in
                Button(action: way.1) {
                    Text(way.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(Capsule().fill(AppBrand.surface))
                        .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            }
            Spacer()
        }
    }

    /// A question's choices, then keeping the answer (asked again) or
    /// coming back to the visit later.
    private func wayChoices(_ list: [Choice], step: ThreadStep, last: [Choice] = []) -> [Choice] {
        list + [threads.reopened[visit.id] != nil
            ? Choice(label: String(localized: "그대로 둘게요"), on: false) { actions.keepAsItWas() }
            : Choice(label: String(localized: "이 방문은 나중에 할게요"), on: false) { actions.later(at: step) }] + last
    }

    /// Last in the list, with a ? saying what it does: it takes the visit
    /// out of the reviews, not just this question.
    private var notMealChoice: Choice {
        Choice(label: String(localized: "밥 아니에요"), on: false,
               info: String(localized: "식당에서 먹은 방문이 아닐 때 눌러요 (집밥, 다른 사람 음식 사진 등). 이 방문은 보관함으로 가고 다시 묻지 않아요. 대화에 남은 이 답을 누르면 되돌릴 수 있어요.")) {
            actions.notAMeal(at: .place)
        }
    }

    private func row(over: String? = nil, _ label: String, meta: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if let over { Text(over).font(.system(size: 12, weight: .bold)).foregroundStyle(AppBrand.faint) }
                    Text(label).font(.system(size: 19, weight: .bold)).lineSpacing(4).foregroundStyle(AppBrand.foreground)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if let meta { Text(meta).font(.system(size: 14)).foregroundStyle(AppBrand.muted).lineLimit(1) }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
    }

    private func input(_ hint: String, ready: Bool, send: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            // Grows with what is written: a draft picked up to edit is
            // several lines.
            TextField(hint, text: $typed, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(4)
                .onSubmit(send)
                .padding(.horizontal, 18).padding(.vertical, 15).frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(ready ? AppBrand.ink : AppBrand.faint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(ready ? AppBrand.signal : AppBrand.raisedSurface))
            }
            .buttonStyle(.plainHit)
            .disabled(!ready)
            .accessibilityLabel(Text("보내기"))
        }
    }

    // MARK: Place

    @ViewBuilder
    private var placeQuestion: some View {
        let candidates = (library.placeCandidates[visit.id] ?? []).filter { $0.googlePlaceID != nil }
        let guess = library.placeMatches[visit.id]?.picks.first.flatMap { p in candidates.first { $0.id == p.id } }
            ?? (library.isTentative(visit) ? library.confirmedPlaces[visit.id] : nil)
        // Changing the place asks where, not "X에서?" again.
        let pick = threads.reopened[visit.id] != nil ? nil : guess
        let others = candidates.filter { $0.id != pick?.id }
        let checking = library.matching.contains(visit.id) || library.lookingUp.contains(visit.id)
        if checking && pick == nil {
            // Nothing to ask yet: the app's turn, with the clock, and what
            // can be done meanwhile.
            HStack(spacing: 16) {
                WaitingLine(label: String(localized: "사진으로 가게 확인 중"))
                Spacer()
                Button { pickerOpen = true } label: {
                    Text("이름으로 찾기").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.muted).underline(color: AppBrand.faint)
                }
                .buttonStyle(.plainHit)
                Button { actions.park(at: threads.step(visit.id)) } label: {
                    Text("기다리는 동안 다음 방문").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.muted).underline(color: AppBrand.faint)
                }
                .buttonStyle(.plainHit)
            }
            if pickerOpen { placeList(others) }
        } else if let pick {
            asking(String(localized: "\(PlaceNames.shown(pick.name))에서 드셨어요?"))
            // The place asked about, named in its own card: the answers
            // under it say what they answer ("Yes, it
            // was there" under no name read as nothing).
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlaceNames.shown(pick.name)).font(.system(size: 19, weight: .bold)).foregroundStyle(AppBrand.foreground)
                    Text(Self.meta(pick)).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                }
                Spacer(minLength: 8)
                GoogleMapsLink(place: pick)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            // One list of choices, as at the taste.
            ChoiceList(choices: wayChoices([
                Choice(label: String(localized: "맞아요"), on: false) { actions.choosePlace(pick) },
                Choice(label: String(localized: "다른 곳이에요"), on: pickerOpen) { pickerOpen = true },
            ], step: .place, last: [notMealChoice]))
            // Another place: the app answers, then the places as choices
            // with the search as the last of them.
            if pickerOpen {
                Text(others.isEmpty ? String(localized: "근처에서 찾은 가게가 없어요. 이름으로 찾아볼게요.")
                     : String(localized: "근처 가게 \(others.count)곳이에요."))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                placeList(others)
            }
        } else if others.isEmpty, library.lookupFailed.contains(visit.id) {
            // The nearby list never came: say why, and offer it again. Out of
            // searches, the name search is refused as well, so it is not
            // offered. This Mac's share is weekly and a spent one waits for
            // next week, when the visit is looked up again by itself
            // (no asking for more).
            let limit = PlaceLookup.limited
            switch limit {
            case .week(let until):
                asking(String(localized: "이번 주 가게 검색을 다 썼어요. \(until.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))에 다시 채워지면 이 방문부터 찾을게요. 설정에서 내 Google 지도 키를 넣으면 바로 쓸 수 있어요."))
                Color.clear.frame(height: 0).task(id: until) {
                    try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 0) + 60))
                    guard !Task.isCancelled else { return }
                    await library.lookupPlace(for: visit, again: true)
                    await library.matchPlace(for: visit)
                }
            case .day: asking(String(localized: "오늘 쓸 수 있는 가게 검색을 다 썼어요. 하루 지나면 다시 찾을 수 있어요."))
            case nil: asking(String(localized: "근처 가게 목록을 못 불러왔어요."))
            }
            if limit == nil { placeList(others) }
            ChoiceList(choices: wayChoices([
                Choice(label: String(localized: "다시 찾기"), on: false) {
                    Task { await library.lookupPlace(for: visit, again: true); await library.matchPlace(for: visit) }
                },
            ], step: .place, last: [notMealChoice]))
        } else {
            asking(String(localized: "어디서 드셨어요?"))
            placeList(others)
            ChoiceList(choices: wayChoices([], step: .place, last: [notMealChoice]))
        }
        // A lookup that never ran (a place restored without its nearby
        // list) is started here, not shown as checking forever.
        Color.clear.frame(height: 0)
            .task {
                if library.placeCandidates[visit.id] == nil, visit.coordinate != nil, !library.lookingUp.contains(visit.id) {
                    await library.lookupPlace(for: visit)
                    if library.confirmedPlaces[visit.id] == nil { await library.matchPlace(for: visit) }
                }
            }
    }

    /// The places to pick from, as choices: nearby ones (or what a search
    /// found), each with its Google Maps page, and the search by name as
    /// the last row.
    private func placeList(_ nearby: [PlaceCandidate]) -> some View {
        let searched = !found.isEmpty
        let list = searched ? found : nearby
        return VStack(spacing: 0) {
            if searched {
                HStack {
                    Text("‘\(searchedFor)’ 찾은 결과").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppBrand.muted)
                    Spacer()
                    Button { found = []; typed = ""; searchedFor = "" } label: {
                        Text("근처 가게 보기").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppBrand.muted).underline(color: AppBrand.faint)
                    }
                    .buttonStyle(.plainHit)
                }
                .padding(.horizontal, 14).frame(height: 32)
                Rectangle().fill(AppBrand.line).frame(height: 1)
            }
            // No scroll inside the conversation: the nearest five, the rest
            // a press away.
            let cut = searched || showAllPlaces ? list : Array(list.prefix(5))
                VStack(spacing: 0) {
                    ForEach(cut, id: \.id) { place in
                        HStack(spacing: 8) {
                            Button { actions.choosePlace(place) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(AppBrand.faint)
                                    Text(PlaceNames.shown(place.name)).font(.system(size: 14.5, weight: .medium)).foregroundStyle(AppBrand.foreground).lineLimit(1)
                                    Text(Self.meta(place)).font(.system(size: 12.5)).foregroundStyle(AppBrand.muted).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plainHit)
                            GoogleMapsLink(place: place)
                        }
                        .padding(.horizontal, 14)
                        Rectangle().fill(AppBrand.line).frame(height: 1)
                    }
                    if cut.count < list.count {
                        Button { showAllPlaces = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppBrand.faint)
                                Text("\(list.count - cut.count)곳 더 보기").font(.system(size: 14.5, weight: .medium)).foregroundStyle(AppBrand.muted)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).frame(height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHit)
                        Rectangle().fill(AppBrand.line).frame(height: 1)
                    }
                }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(AppBrand.faint)
                TextField(String(localized: "목록에 없으면 이름으로 찾기"), text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 14.5))
                    .onSubmit { search() }
                if searching { ProgressView().controlSize(.small) }
                else if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("찾기") { search() }.font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            if !searching, !typed.isEmpty, found.isEmpty, searchedFor == typed {
                Text("못 찾았어요. 동네 이름을 붙여 보세요.").font(.system(size: 12.5)).foregroundStyle(AppBrand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .background(AppBrand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var searchedFor = ""
    @State private var showAllDishes = false
    @State private var showAllPlaces = false

    private func search() {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            found = await PlaceLookup.searchText(text, near: visit.coordinate).filter { $0.googlePlaceID != nil }
            searchedFor = typed
            searching = false
        }
    }

    /// Something long under way: the clock, and the next visit meanwhile.
    /// The app's turn while something long runs: what it is doing and for
    /// how long, nothing left over from before, and two roomy ways on.
    private func waitingTurn(_ label: String, also: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            WaitingLine(label: label).scaleEffect(1.15, anchor: .leading)
            HStack(spacing: 12) {
                Button { actions.park(at: threads.step(visit.id)) } label: { Text("기다리는 동안 다음 방문") }.buttonStyle(BigSecondaryButtonStyle())
                if let also { Button(action: also.1) { Text(also.0) }.buttonStyle(BigSecondaryButtonStyle()) }
                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    static func meta(_ place: PlaceCandidate) -> String {
        [place.category, place.distanceLabel.isEmpty ? nil : place.distanceLabel].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Dishes

    @ViewBuilder
    private var dishQuestion: some View {
        // While a new menu is searched the old one is not shown; nor while
        // its names are put in English or the photos named from it — the
        // chips changed under the person as each part came in.
        let loading = library.menuLoading.contains(visit.id) || library.namingInEnglish.contains(visit.id)
            || library.naming.contains(visit.id)
        // Google's popular dishes first, then the rest as the menu lists them.
        let items = loading ? [] : library.menuItems(for: visit)
        let popular = library.menuHighlights(for: visit)
        let isPopular = { (item: MenuItem) in popular.contains { h in item.name.localizedCaseInsensitiveContains(h) || h.localizedCaseInsensitiveContains(item.name) } }
        let menu = (items.filter(isPopular) + items.filter { !isPopular($0) }).map(\.shown)
        // A guess in Korean (named while the app was Korean) is no name in
        // the English app (빵 among a Greek menu).
        let guesses = loading ? [] : visit.photos.flatMap { PhotoLibrary.dishParts(library.photoSuggestions[visit.id]?[$0.id] ?? "") }
            .filter(PhotoLibrary.isDish).filter { !(AppLanguage.current.isEnglish && MenuName.hasHangul($0)) }
        // Pressing a chip lights it where it is; only a name typed in, which
        // is on no list, joins at the end (a pressed chip
        // jumped to the front).
        let all = (guesses + menu + picked).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let noMenu = !loading && menu.isEmpty
        if loading && !writeAnyway {
            waitingTurn(library.menuLoading.contains(visit.id) ? String(localized: "메뉴 찾는 중")
                        : String(localized: "사진과 메뉴 맞춰 보는 중"), also: (String(localized: "직접 쓸게요"), { writeAnyway = true }))
        } else {
        asking(noMenu ? String(localized: "메뉴를 못 찾았어요. 뭐 드셨어요?") : ThreadActions.dishQuestion)
        // A few first — what the photos showed, then the popular — and the
        // rest a press away, in the conversation, not in a scroll inside
        // it. Typing leaves the chips as they are.
        let typedName = typed.trimmingCharacters(in: .whitespaces)
        let first = 10
        let shownChips = showAllDishes ? all
            : all.enumerated().filter { $0.offset < first || picked.contains($0.element) }.map(\.element)
        let more = showAllDishes ? 0 : all.count - shownChips.count
        if !shownChips.isEmpty || more > 0 {
                WrapRow(spacing: 8, lineSpacing: 8) {
                    ForEach(shownChips, id: \.self) { name in
                        let on = picked.contains(name)
                        Button {
                            if on { picked.removeAll { $0 == name } } else { picked.append(name) }
                        } label: {
                            let chip = library.chipName(for: name, in: visit)
                            DishChip(name: chip.name, printed: chip.printed, on: on)
                        }
                        .buttonStyle(.plainHit)
                        .help(Text(verbatim: { let c = library.chipName(for: name, in: visit); return [c.name, c.printed].compactMap { $0 }.joined(separator: "\n") }()))
                    }
                    if more > 0 {
                        Button { showAllDishes = true } label: {
                            Text("+ \(more)개 더").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppBrand.muted)
                                .padding(.horizontal, 18).frame(height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppBrand.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHit)
                    }
                }
        }
        // Return adds the name typed as a chip, lit; one already among the
        // chips is lit instead. The answer is one clear button that says
        // what it answers (the arrow beside the field did
        // not read as "next").
        input(String(localized: "목록에 없으면 직접 쓰기"), ready: !typedName.isEmpty) {
            guard !typedName.isEmpty else { return }
            let name = all.first { name in
                let chip = library.chipName(for: name, in: visit)
                return [name, chip.name, chip.printed ?? ""].contains { $0.caseInsensitiveCompare(typedName) == .orderedSame }
            } ?? typedName
            if !picked.contains(name) { picked.append(name) }
            typed = ""
        }
        if !picked.isEmpty {
            let names = picked.map { library.reviewName(for: $0, in: visit) }
            let said = names.count <= 3 ? names.joined(separator: ", ") : String(localized: "\(names[0]) 외 \(names.count - 1)개")
            HStack {
                Button { actions.chooseDishes(picked) } label: { Text("\(said) 먹었어요 →") }
                    .buttonStyle(BigPrimaryButtonStyle())
                Spacer()
            }
        }
        ways([(String(localized: "기억 안 나요"), { actions.chooseDishes([]) })], step: .dishes)
        }
    }

    /// A menu read before the food-only count (two dishes and three wines)
    /// is searched again once, with the deeper model behind it.
    private func researchThinMenu() async {
        guard let place = library.confirmedPlaces[visit.id], let placeID = place.googlePlaceID,
              library.menuWasRead(for: visit), !library.menuLoading.contains(visit.id),
              !threads.researched.contains(placeID),
              // Just searched (a new place): searching again finds the same.
              !library.menuSearchedThisSession(placeID),
              threads.step(visit.id) != .done,
              DishSearch.foodCount(library.menuItems(for: visit), category: place.category) <= 3 else { return }
        threads.researched.insert(placeID)
        await library.loadMenu(for: visit, again: true)
        // Cut off by moving on (나중에 pressed while it searched): searched
        // again when the visit comes back, not counted as done.
        if Task.isCancelled { threads.researched.remove(placeID) }
    }

    // MARK: Taste

    @ViewBuilder
    private func tasteQuestion(_ dish: String) -> some View {
        asking(ThreadActions.tasteQuestion(library.reviewName(for: dish, in: visit)))
        // Asked again, what was answered before is lit (nothing showed
        // which one had been picked).
        let now = threads.reopened[visit.id] != nil ? threads.thread(visit.id).facts.tastes[dish] : nil
        // One list, like a chat app's choices: how it tasted, leaving the
        // taste out, coming back later — not big buttons with the ways past
        // them in a second row.
        ChoiceList(choices: wayChoices([Taste.good, .fine, .skipped].map { taste in
            Choice(label: taste.said, on: now == taste) { actions.chooseTaste(taste, for: dish) }
        }, step: .taste(dish)))
    }

    // MARK: Draft

    /// What the wait for drafts says, by what the drafting is doing, in
    /// turn (not just "writing drafts" while it was
    /// finding out what a dish is).
    static func draftingLines(_ stage: ReviewDrafter.Stage?) -> [String] {
        switch stage {
        case .lookingUp(let dish)?:
            [String(localized: "\(dish), 어떤 음식인지 알아보는 중"), String(localized: "메뉴판 들여다보는 중")]
        case .searching(let dish)?:
            [String(localized: "\(dish) 레시피 연구 중"), String(localized: "현지 맛집 글 뒤지는 중"), String(localized: "\(dish) 정체 파악 중")]
        default:
            [String(localized: "초안 쓰는 중"), String(localized: "단어 고르는 중"), String(localized: "문장 다듬는 중")]
        }
    }

    @ViewBuilder
    private var draftQuestion: some View {
        let options = library.reviewOptions[visit.id] ?? []
        let writing = library.drafting.contains(visit.id)
        // While drafts are written, the app's turn, small: it goes once
        // they are there.
        if writing {
            ThinkingLine(lines: Self.draftingLines(library.draftStage[visit.id])) { actions.park(at: threads.step(visit.id)) }
        } else {
        // The question is said above; the drafts, then what to do with them,
        // then writing one's own, at the bottom.
        Color.clear.frame(height: 0).preference(key: AskedLine.self, value: ThreadActions.draftQuestion)
        if options.isEmpty {
            row(String(localized: "다시 써 보기")) { Task { await actions.ensureDrafts() } }
        }
        VStack(spacing: 8) {
            ForEach(options) { option in
                HStack(alignment: .center, spacing: 8) {
                    Button { actions.chooseDraft(option) } label: { DraftCard(genre: option.genre, text: option.text) }
                        .buttonStyle(.plainHit)
                    // Picked up into the field below, to go on writing from
                    // it.
                    Button { typed = option.text } label: {
                        Image(systemName: "pencil").font(.system(size: 16, weight: .bold)).foregroundStyle(AppBrand.muted)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(AppBrand.surface))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plainHit)
                    .help(Text("고쳐 쓰기"))
                }
            }
        }
        ways([(String(localized: "다 별로예요"), { Task { await actions.moreDrafts() } }),
              (String(localized: "글 없이 사진만"), { actions.chooseDraft(GenreDraft(genre: String(localized: "사진만"), note: "", text: "")) })], step: .draft)
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        input(String(localized: "직접 쓰기"), ready: !text.isEmpty) {
            guard !text.isEmpty else { return }
            actions.chooseDraft(GenreDraft(genre: String(localized: "직접"), note: "", text: text))
        }
        }
    }

    /// The place as well as the food, asked on its own between the dishes
    /// and the cards; each chip says itself.
    @ViewBuilder
    private var sceneQuestion: some View {
        asking(ThreadActions.sceneQuestion)
        HStack(spacing: 8) {
            ForEach(PhotoLibrary.placeTags, id: \.self) { tag in
                let lit = sceneTags.contains(tag)
                Button {
                    if lit { sceneTags.removeAll { $0 == tag } } else { sceneTags.append(tag) }
                } label: {
                    Text(PhotoLibrary.tagPhrase(tag)).font(.system(size: 17, weight: .bold)).foregroundStyle(lit ? AppBrand.ink : AppBrand.foreground)
                        .padding(.horizontal, 20).frame(height: 48)
                        .background(Capsule().fill(lit ? AppBrand.signal : AppBrand.surface))
                        .overlay(Capsule().stroke(lit ? AppBrand.signal : AppBrand.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            }
        }
        HStack {
            Button { actions.chooseScene(sceneTags) } label: {
                Text(sceneTags.isEmpty ? String(localized: "딱히 없어요 →") : String(localized: "이렇게 쓸게요 →"))
            }
            .buttonStyle(BigPrimaryButtonStyle())
            Spacer()
        }
        ways([], step: .scene)
    }

    // MARK: Post

    @ViewBuilder
    private var postQuestion: some View {
        // "다 올렸어요?" only right after the form was opened; coming back
        // to the visit later asks to open it again (it
        // came up again under another visit's 올렸어요).
        let opened = threads.thread(visit.id).facts.formOpened && !resumed
        if !opened && library.googleAccount.isEmpty && !ThreadActions.oneAccount {
            // Which Google account the form opens in, asked once: a Safari
            // signed in to several opened Maps in whichever was last
            // used.
            let email = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            asking(String(localized: "어느 구글 계정으로 올릴까요?"))
            Text("Safari에 구글 계정이 여러 개면, 리뷰창이 다른 계정으로 열릴 수 있어요. 올릴 계정의 이메일을 알려 주세요.")
                .font(.system(size: 16)).foregroundStyle(AppBrand.muted)
            ways([(String(localized: "계정이 하나예요"), { ThreadActions.oneAccount = true; guideTick += 1 })], step: .post)
            input(String(localized: "리뷰를 올릴 구글 이메일"), ready: !email.isEmpty) {
                guard !email.isEmpty else { return }
                library.setGoogleAccount(email)
                typed = ""
            }
        } else if !opened {
            asking(ThreadActions.postQuestion)
            // With the how-to lines, for the first few posts only; after
            // that the account is changed in Settings.
            if !library.googleAccount.isEmpty, ThreadActions.guideLeft > 0 + guideTick * 0 {
                Text("\(library.googleAccount) 계정으로 열어요. 바꾸려면 설정에서 바꿀 수 있어요.")
                    .font(.system(size: 16)).foregroundStyle(AppBrand.muted)
            }
            // How Google's form is filled, said before 올리기, for the first
            // few posts only. Said after it, it was never read: 올리기
            // brings Safari to the front over the conversation.
            if ThreadActions.guideLeft > 0 + guideTick * 0 {
                VStack(alignment: .leading, spacing: 8) {
                    // Stars and posting go unsaid (they
                    // know that part). The folder is in Finder's favorites,
                    // put there by the first 올리기 (PhotoLibrary.addToSidebar).
                    if !(library.reviewDrafts[visit.id]?.text ?? "").isEmpty {
                        Text("글은 복사해 둘게요. 리뷰 칸에 붙여 넣기만 하세요 (⌘V).")
                    }
                    Text("사진은 Afterplate 폴더에 넣어 둘게요. 리뷰창에서 사진 추가를 누르면 뜨는 파일 창의 왼쪽 즐겨찾기에 있어요.")
                }
                .font(.system(size: 16)).foregroundStyle(AppBrand.muted)
            }
            HStack(spacing: 8) {
                Button { actions.openGoogle(resumed: resumed) } label: { Text("올리기") }.buttonStyle(BigPrimaryButtonStyle())
                Spacer()
            }
            ways(ThreadActions.guideLeft > 0 ? [(String(localized: "설명 그만"), { UserDefaults.standard.set(3, forKey: "threadPostGuides"); guideTick += 1 })] : [],
                 step: .post)
        } else {
            asking(String(localized: "다 올렸어요?"))
            HStack(spacing: 8) {
                Button { actions.posted() } label: { Text("올렸어요") }.buttonStyle(BigPrimaryButtonStyle())
                Spacer()
            }
            ways([(String(localized: "리뷰창 다시 열기"), { actions.openGoogle() })], step: .post)
        }
    }
}

/// Something under way, with a clock counting up from when it showed: how
/// long it will take is not known, how long it has been is.
struct WaitingLine: View {
    let label: String
    @State private var since = Date()

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppBrand.muted)
            TimelineView(.periodic(from: since, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(since)))
                Text(String(format: "%d:%02d", s / 60, s % 60))
                    .font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(AppBrand.signal)
            }
        }
    }
}

/// The step before, cut in half above a ⋯: there was more before this.
/// Only a sign — nothing to press.
struct StepGlimpse: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text).font(.system(size: 17)).foregroundStyle(AppBrand.muted).lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 12, alignment: .bottom)
                .clipped()
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            Image(systemName: "ellipsis").font(.system(size: 26, weight: .black)).foregroundStyle(AppBrand.muted)
                .padding(.leading, 14).frame(height: 30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// What the app says before a question asked again: what is being
/// changed. The same above the question and, answered, in the record.
struct RevisedLead: View {
    let key: ThreadEntry.Key
    var body: some View {
        Text(ThreadActions.revisedLead(key)).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Going back from a line of the record, as the feed does it: down to the
/// bottom first, then the question asked again there.
private struct GoBackKey: EnvironmentKey {
    static let defaultValue: ((ThreadEntry, Visit) -> Void)? = nil
}
extension EnvironmentValues {
    var goBack: ((ThreadEntry, Visit) -> Void)? {
        get { self[GoBackKey.self] }
        set { self[GoBackKey.self] = newValue }
    }
}

/// The app about to say something: three dots, like being typed to.
/// The place on Google Maps, in the browser: the list comes from Google,
/// so its page shows the photos and reviews to tell places apart.
struct GoogleMapsLink: View {
    let place: PlaceCandidate

    private var url: URL? {
        var parts = URLComponents(string: "https://www.google.com/maps/search/")
        parts?.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: place.name)]
            + (place.googlePlaceID.map { [URLQueryItem(name: "query_place_id", value: $0)] } ?? [])
        return parts?.url
    }

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                    Text("구글 지도").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(AppBrand.muted)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(AppBrand.raisedSurface))
                .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plainHit)
            .help(Text("구글 지도에서 보기"))
        }
    }
}

struct Choice {
    let label: String
    let on: Bool
    /// What the choice does, behind a ? beside it.
    var info: String? = nil
    let action: () -> Void
}

/// Choices as one list of rows with a radio mark, the way chat apps offer
/// them: one press answers.
struct ChoiceList: View {
    let choices: [Choice]
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                if index > 0 { Rectangle().fill(AppBrand.line).frame(height: 1) }
                // The ? sits outside the row's button so pressing it does not
                // answer; the rest of the row, both sides of it, does.
                HStack(spacing: 0) {
                    Button(action: choice.action) {
                        HStack(spacing: 10) {
                            Image(systemName: choice.on ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(choice.on ? AppBrand.signal : AppBrand.faint)
                            Text(choice.label).font(.system(size: 14.5, weight: .medium)).foregroundStyle(AppBrand.foreground)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.leading, 14).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                    .layoutPriority(1)
                    if let info = choice.info { InfoMark(text: info).padding(.leading, 4) }
                    Button(action: choice.action) {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit)
                }
                .background(hovered == index ? AppBrand.raisedSurface : Color.clear)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            }
        }
        .background(AppBrand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        .frame(maxWidth: 380, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A ? that says what a choice does, on hover and on press.
struct InfoMark: View {
    let text: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(AppBrand.faint)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .help(Text(verbatim: text))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(verbatim: text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(width: 280, alignment: .leading)
        }
    }
}

/// A dish to pick: the name in the app's language, and under it, smaller,
/// the menu's own printing ("Agu Pork Green Onion Shabu-Shabu" over
/// 島豚あぐーのねぎしゃぶしゃぶ). Two lines rather than one long one, and no
/// wider than 260pt: a long name ends in … and the whole of it is in the
/// tooltip.
struct DishChip: View {
    let name: String
    let printed: String?
    let on: Bool

    var body: some View {
        CappedWidth(max: 260) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 16, weight: .bold)).lineLimit(1).truncationMode(.tail)
                if let printed {
                    Text(printed).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(on ? AppBrand.ink.opacity(0.65) : AppBrand.faint)
                }
            }
        }
        .foregroundStyle(on ? AppBrand.ink : AppBrand.foreground)
        .padding(.horizontal, 18).padding(.vertical, printed == nil ? 0 : 6).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(on ? AppBrand.signal : AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(on ? AppBrand.signal : AppBrand.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Its content at its own width, but never wider than `max`; a wrap row
/// asks for the ideal size, which a `.frame(maxWidth:)` does not cap.
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        let width = Swift.min(ideal.width, max, proposal.width ?? .infinity)
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct TypingDots: View {
    /// What the app is doing meanwhile, small, beside the dots.
    var label: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            dots
            if let label { Text(label).font(.system(size: 14)).foregroundStyle(AppBrand.muted) }
        }
    }

    private var dots: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle().fill(AppBrand.muted).frame(width: 8, height: 8)
                        .opacity(0.3 + 0.7 * max(0, sin((t * 2.4 - Double(i) * 0.35) * .pi)))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        }
    }
}

/// What the question at the bottom asks, said in the conversation.
struct AskedLine: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = nextValue() ?? value }
}

/// A review draft to pick: what kind it is, small, over its text, in the
/// weight the conversation is read in (not bold).
struct DraftCard: View {
    let genre: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(genre).font(.system(size: 12, weight: .bold)).foregroundStyle(AppBrand.faint)
            Text(text).font(.system(size: 17)).lineSpacing(4).foregroundStyle(AppBrand.foreground)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(minHeight: 60)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// The app at work, said small: dots, what it is doing, how long so far,
/// and the next visit meanwhile. It goes when the work is done.
struct ThinkingLine: View {
    /// Said in turn, a few seconds each, so a long wait reads as work.
    let lines: [String]
    let meanwhile: () -> Void
    @State private var since = Date()
    @State private var turn = 0
    var body: some View {
        HStack(spacing: 12) {
            TypingDots()
            let line = lines.isEmpty ? "" : lines[turn % lines.count]
            Text(line).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                .id(line)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                .task(id: lines) {
                    turn = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2.8))
                        withAnimation(.easeOut(duration: 0.3)) { turn += 1 }
                    }
                }
            TimelineView(.periodic(from: since, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(since)))
                Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 14).monospacedDigit()).foregroundStyle(AppBrand.faint)
            }
            Spacer()
            Button(action: meanwhile) {
                Text("기다리는 동안 다음 방문").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                    .padding(.horizontal, 14).frame(height: 32)
                    .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plainHit)
        }
    }
}
