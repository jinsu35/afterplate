import SwiftUI
import CoreLocation

/// The home screen: one prepared visit at a time, like a feed. The app
/// picks what comes next; the person checks the place, the dishes and a
/// draft, and posts — or swipes on. Corrections open as sheets over the
/// card. The map and the list are for looking back (지난 리뷰).
struct FeedView: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject var prefetcher: Prefetcher
    let openLibrary: () -> Void

    /// The visit the person last worked on; what comes next is chosen near
    /// it (same day, same trip, close by) rather than simply newest.
    @State private var anchor: Visit.ID?
    /// The order, fixed while scrolling so cards never reshuffle underfoot;
    /// rebuilt from the card in view onwards when the anchor moves.
    @State private var order: [Visit.ID] = []
    /// Cards being prepared again after a correction (a new place, other
    /// dishes). They keep their place in the feed — scrolling back shows
    /// them, working — instead of leaving it.

    /// What a card says about a correction just made: what was done, what is
    /// being done now, and when it is done.
    @ObservedObject private var threads = VisitThreads.shared
    @State private var sheet: FeedSheet?
    /// The preparation stays on screen until three cards are ready, or until
    /// the cards are asked for: one ready card used to cut the show off after
    /// twenty seconds, before any menu or draft line had come up.
    @State private var watching = true
    /// The first canvas waits for the whole twelve, not three; its button
    /// still lets the person start on those ready.
    private static let showUntil = ahead
    /// Redraws once an AI is connected from the setup or from Settings
    /// (nothing publishes that).
    @State private var brainReady = Brain.subscriptionReady

    struct FeedSheet: Identifiable {
        let visit: Visit.ID
        let step: FlowStep
        /// The place when the sheet opened, to tell a changed place.
        let placeBefore: String?
        /// The dishes when the sheet opened, to tell changed dishes.
        let dishesBefore: [String]
        var id: String { visit + "/\(step.rawValue)" }
    }

    private var ready: [Visit] {
        // A visit the app could not place by itself is ready too: the first
        // question is the place, and the person answers it.
        library.feedCandidates.filter { prefetcher.isReady($0) || prefetcher.needsPerson.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if order.isEmpty || watching && ready.count < Self.showUntil && !prefetcher.preparing.isEmpty {
                waiting
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        let line = timeline
                        // Not lazy: rows measured as they scroll in moved the
                        // conversation under the person.
                      VStack(spacing: 0) {
                       VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(line.segments) { segment in
                                if revealed.contains(Self.leadID(segment, in: line.segments)) {
                                    if !segment.compact, segment.id != line.segments.first?.id {
                                        Divider().overlay(AppBrand.line).padding(.vertical, 18)
                                    }
                                    if let lead = segment.lead {
                                        // Said in passing, the way the app talks
                                        // (not a headline).
                                        Text(lead).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                                            .transition(Self.arrival)
                                    }
                                }
                                // Never below its own lead: a visit's photos
                                // and record already shown under another
                                // count came in before "… 이어서 할게요" (it is a
                                // conversation, top first).
                                let leadIn = revealed.contains(Self.leadID(segment, in: line.segments))
                                if leadIn, revealed.contains(Self.headID(segment, in: line.segments)) {
                                    Group {
                                        if segment.header { ThreadHeader(visit: segment.visit, compact: segment.compact) }
                                        if let glimpse = segment.glimpse { StepGlimpse(text: glimpse) }
                                    }
                                    .transition(Self.arrival)
                                }
                                ForEach(Self.rows(segment, threads: threads).filter { leadIn && revealed.contains("e/" + $0.id.uuidString) }) { entry in
                                    ThreadEntryView(entry: entry, visit: segment.visit, locked: threads.thread(segment.visit.id).facts.posted)
                                        .transition(Self.arrival)
                                }
                            }
                            if typing {
                                TypingDots().transition(.opacity)
                            } else if let pondering {
                                TypingDots(label: pondering).transition(.opacity)
                            } else if let focus = line.focus,
                                      line.segments.last(where: { $0.visit.id == focus.id }).map({ revealed.contains(Self.leadID($0, in: line.segments)) }) ?? true {
                                // The question too waits for its visit's lead.
                                if let key = threads.reopened[focus.id].flatMap(\.key), revealed.contains(contextID(focus)) {
                                    // The step before the one asked again, to
                                    // press next: back one step at a time
                                    // (once dropped by mistake with the
                                    // visit line).
                                    if let previous = threads.before(focus.id, key: key).last {
                                        ThreadEntryView(entry: previous, visit: focus, locked: false, under: true)
                                            .transition(Self.arrival)
                                    }
                                    RevisedLead(key: key).transition(Self.arrival)
                                }
                                focusQuestion(focus, resumed: line.resumed)
                            } else if prefetcher.busy {
                                // Everything in front done or put off, and
                                // more on the way: those are got ready before
                                // anything put off is asked again. Said
                                // first, as a line of the conversation, then
                                // the canvas inside it, its working line
                                // last.
                                VStack(alignment: .leading, spacing: 22) {
                                    Text("방문 몇 개 더 살펴보고, 찾은 걸 챙겨서 올게요.")
                                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    PrepStrip(prefetcher: prefetcher)
                                }
                                .transition(Self.arrival)
                            } else if putOff.isEmpty {
                                Text(prefetcher.preparing.isEmpty ? String(localized: "지금은 남은 방문이 없어요.") : String(localized: "다음 방문 준비하는 중이에요."))
                                    .font(.system(size: 20, weight: .black)).foregroundStyle(AppBrand.muted)
                            } else if putOff.count > 1 {
                                // Everything in front was put off: go round
                                // again from the first one put off, never the
                                // one just put off (나중에 on the last visit
                                // left the screen with nothing to answer,
                                // and later
                                // brought the same question straight back).
                                Color.clear.frame(height: 1).onAppear(perform: comeBackAround)
                            } else {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("남은 방문은 이것뿐이라 미뤄 뒀어요.").font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                                    HStack {
                                        Button(action: comeBackAround) { Text("지금 할게요") }.buttonStyle(BigSecondaryButtonStyle())
                                        Spacer()
                                    }
                                }
                                .transition(Self.arrival)
                            }
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40).padding(.top, 40)
                        Color.clear.frame(height: 46).id(Self.lastID)
                       }
                        .coordinateSpace(name: Self.feedSpace)
                        .onPreferenceChange(AnswerTops.self) { mark.answerTops = $0 }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; mark.contentHeight = $0 }
                        // Room below while a question gives way to a shorter
                        // one, so the conversation is not pulled down and
                        // pushed back up.
                        Color.clear.frame(height: endRoom)
                      }
                    }
                    .scrollIndicators(.hidden)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { viewHeight = g.size.height; mark.screen = g.size.height }
                            .onChange(of: g.size.height) { _, h in viewHeight = h; mark.screen = h }
                    })
                    // Opens where the conversation is — the bottom — not at
                    // its first line. The visits come in a moment after the
                    // window, so it is asked again then. At the end, the
                    // end stays at the screen's bottom as lines come in;
                    // scrolled up, nothing moves and the arrow says there
                    // is more.
                    .modifier(HoldScroll(mark: mark, room: endRoom) { follow(reader) })
                    .onChange(of: contentHeight) { old, new in
                        if new < old { keep = max(keep, old + 60) }
                        // Grown into the room held below: the scroll's own
                        // size did not change, so it is followed from here.
                        if new > old, mark.atEnd, keep > 0 { follow(reader) }
                        settle()
                    }
                    // The arrow watches the scroll on its own: drawn by the
                    // conversation, each time it came and went at the end
                    // the whole conversation was drawn again, and scrolling
                    // there stuttered.
                    .overlay(alignment: .bottom) {
                        MoreBelow(mark: mark) {
                            withAnimation(.easeInOut(duration: 0.35)) { reader.scrollTo(Self.lastID, anchor: .bottom) }
                        }
                    }
                    // One line at a time, like being typed to (after 올렸어요
                    // the closing, the next visit,
                    // its place and menu and the question all came at once).
                    .onChange(of: rowIDs, initial: true) { _, ids in say(ids, reader) }
                    .onChange(of: timeline.focus?.id, initial: true) { _, id in sayAskedAgain(id) }
                    .task {
                        reader.scrollTo(Self.lastID, anchor: .bottom)
                        for wait in [0.3, 1.0, 2.5] {
                            try? await Task.sleep(for: .seconds(wait))
                            reader.scrollTo(Self.lastID, anchor: .bottom)
                        }
                    }
                    .environment(\.goBack) { entry, visit in goBack(entry, of: visit, reader) }
                }
            }
        }
        .background(AppBrand.ink)
        .overlay { PeekOverlay() }
        .overlay { AlbumOverlay() }
        .onAppear(perform: rebuild)
        .onChange(of: ready.map(\.id)) { _, ids in
            merge()
            if ids.count >= Self.showUntil { watching = false }
        }
        .onChange(of: parkedBusy) { _, _ in unparkFinished() }
        .onChange(of: threads.parked) { _, _ in unparkFinished() }
        .onChange(of: shown, initial: true) { _, ids in
            // What was saved for a visit is read back before it is talked
            // about: after a relaunch a visit the preparation skipped had no
            // place in hand, so its review form had no address and its draft
            // was not copied.
            Task {
                for id in ids {
                    guard let v = library.visits.first(where: { $0.id == id }) else { continue }
                    await library.restoreSaved(for: v)
                    ThreadActions(library: library, visit: v).seedIfNeeded()
                }
            }
        }
        .onChange(of: shown.last) { _, id in
            anchor = id
            lookAhead()
        }
        .onChange(of: aheadCount) { _, _ in lookAhead() }
        .sheet(item: $sheet, onDismiss: closedSheet) { item in
            VisitFlow(visitID: item.visit, home: { sheet = nil }, openNext: { _ in sheet = nil }, only: item.step)
                .environmentObject(library)
                .frame(minWidth: 1100, minHeight: 760)
                .background(BrandBackdrop())
        }
    }

    /// The visits in the conversation: every one finished in this session,
    /// then the one being worked on. The next comes in below when that one
    /// is done.
    private var shown: [Visit.ID] {
        var list: [Visit.ID] = []
        var next = false
        for id in order {
            // Set aside while its work runs: what was said stays in the
            // conversation (parking it wiped the thread as if a new window
            // had opened), and the next visit comes in below. Visits already
            // talked about stay, finished or not, wherever they are in line:
            // a set-aside visit whose work finished is put behind the one in
            // front, and stopping at the first one not yet started dropped
            // it, with everything said, from the conversation.
            let started = threads.parked.contains(id) || threads.step(id) == .done
                || threads.thread(id).entries.contains(where: { $0.seeded != true })
            if started { list.append(id) } else if !next { list.append(id); next = true }
        }
        return list
    }

    struct Segment: Identifiable {
        let id: String
        let visit: Visit
        let compact: Bool
        /// Off when the first entry names the visit itself (a correction).
        let header: Bool
        /// What the app says as the conversation moves to this visit.
        let lead: String?
        /// Coming back: the latest of what the visit had settled, then
        /// whatever was said this time.
        var recap: [ThreadEntry] = []
        /// The step before the recap, cut above a ⋯.
        var glimpse: String? = nil
        let entries: [ThreadEntry]
    }

    /// Everything said, in the order it was said, cut where the visit
    /// changes; and the visit whose question is at the bottom: the one last
    /// reopened, else the one last answered while it still has a question,
    /// else the first in line not finished.
    private var timeline: (segments: [Segment], focus: Visit?, resumed: Bool) {
        let visits = shown.compactMap { id in library.visits.first { $0.id == id } }
        // What the old screens settled is read in when a visit is seeded,
        // which can be while another visit is being talked about; it is said
        // where the conversation reaches the visit, not when it was read in
        // (the next visit's place showed up under an answer).
        var settled: [String: [ThreadEntry]] = [:]
        var said: [(Visit, ThreadEntry)] = []
        for v in visits {
            let gone = threads.moot(v.id)
            for e in threads.thread(v.id).entries where !gone.contains(e.id) {
                if e.seeded == true { settled[v.id, default: []].append(e) } else { said.append((v, e)) }
            }
        }
        said.sort { $0.1.at < $1.1.at }
        var segments: [Segment] = []
        var seen: Set<String> = []
        var run: [ThreadEntry] = []
        var current: Visit?
        func add(_ visit: Visit, _ entries: [ThreadEntry], recapped: Bool = true) {
            let compact = seen.contains(visit.id)
            let place = library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) }
            let lead: String? = segments.isEmpty ? nil
                : !compact ? String(localized: "다음 방문이에요.")
                : place.map { String(localized: "\($0) 이어서 할게요.") } ?? String(localized: "이 방문 이어서 할게요.")
            let id = "\(visit.id)#\(segments.count)"
            // Coming back, the last thing settled is said again where it can
            // be pressed, under a ⋯ saying there was more; pressing it shows
            // the step before above its question, one step at a time (a
            // visit came back at "구글에 올릴까요?" with its
            // menu far above and no way back to it).
            var recap: [ThreadEntry] = []
            var glimpse: String?
            if compact, recapped {
                let all = settledNow(visit.id, before: entries.first?.at)
                recap = Array(all.suffix(1))
                glimpse = all.count >= 2 ? all[all.count - 2].question : nil
            }
            segments.append(Segment(id: id, visit: visit, compact: compact, header: true, lead: lead, recap: recap, glimpse: glimpse,
                                    entries: (compact ? [] : settled[visit.id] ?? []) + entries))
            seen.insert(visit.id)
        }
        func close() {
            guard let current, !run.isEmpty else { return }
            add(current, run)
        }
        for (visit, entry) in said {
            if current?.id != visit.id { close(); current = visit; run = [] }
            run.append(entry)
        }
        close()
        let open = { (id: String) in threads.step(id) != .done }
        let focusID = threads.reopenOrder.last(where: { threads.reopened[$0] != nil && shown.contains($0) })
            // Not one just set aside or put off: its work finishing does not
            // pull it back over the visit taken up meanwhile.
            ?? said.last.flatMap { open($0.0.id) && !threads.parked.contains($0.0.id) && !ThreadActions.putOff($0.1) ? $0.0.id : nil }
            // Nor one put off: it comes round again only once nothing new is
            // being got ready (comeBackAround clears its Later); taken here,
            // it skipped the canvas.
            ?? shown.first(where: { open($0) && !threads.parked.contains($0) && !threads.thread($0).facts.later })
        let focus = focusID.flatMap { id in visits.first { $0.id == id } }
        // Come back to after something else was said: what was left open
        // then (Google's form) is not open any more.
        let resumed = focus.map { f in segments.last?.visit.id != f.id && seen.contains(f.id) && threads.reopened[f.id] == nil } ?? false
        // Coming back to a visit — to go on, or to change something pressed
        // far above — opens with the line, the visit and its recap.
        // Come back to change something, the visit is named without its
        // last step: that step may come after the one being changed (a
        // draft chosen above "where did you eat?"), and the line naming
        // the change says where it stands.
        if let focus, segments.last?.visit.id != focus.id, seen.contains(focus.id) || threads.reopened[focus.id] == nil {
            add(focus, [], recapped: threads.reopened[focus.id] == nil)
        }
        return (segments, focus, resumed)
    }

    // MARK: Saying it line by line

    /// What is on screen; what is not yet in it comes in one at a time.
    @State private var revealed: Set<String> = []
    @State private var queue: [String] = []
    @State private var saying = false
    /// Opening the window shows what was already said all at once.
    @State private var openedAt: Date?

    static let arrival: AnyTransition = .opacity.combined(with: .offset(y: 14))

    /// A visit's nth segment: the same lead and header before and after
    /// the conversation reaches it.
    private static func nth(_ segment: Segment, in segments: [Segment]) -> Int {
        segments.prefix { $0.id != segment.id }.filter { $0.visit.id == segment.visit.id }.count
    }
    static func leadID(_ segment: Segment, in segments: [Segment]) -> String { "l/\(segment.visit.id)/\(nth(segment, in: segments))" }
    static func headID(_ segment: Segment, in segments: [Segment]) -> String { "h/\(segment.visit.id)/\(nth(segment, in: segments))" }
    static func rows(_ segment: Segment, threads: VisitThreads) -> [ThreadEntry] {
        (segment.recap + segment.entries).filter { !threads.isPressed($0, of: segment.visit.id) }
    }
    private func questionID(_ visit: Visit) -> String { "q/\(visit.id)/\(String(describing: threads.step(visit.id)))/\(redrafts(visit))" }
    /// New drafts asked for: the question is said again after them.
    private func redrafts(_ visit: Visit) -> Int { threads.thread(visit.id).entries.filter { $0.label == ThreadActions.redraftLabel }.count }
    private func contextID(_ visit: Visit) -> String { "c/\(visit.id)/\(threads.reopened[visit.id].map { String(describing: $0) } ?? "")" }
    private func askedID(_ visit: Visit, _ asked: String) -> String { "a/\(visit.id)/\(asked)" }
    /// What the question at the bottom asks, as it says it.
    @State private var asked: String?

    private var rowIDs: [String] {
        let line = timeline
        var ids: [String] = []
        for segment in line.segments {
            ids.append(Self.leadID(segment, in: line.segments))
            ids.append(Self.headID(segment, in: line.segments))
            ids += Self.rows(segment, threads: threads).map { "e/" + $0.id.uuidString }
        }
        if let focus = line.focus {
            if threads.reopened[focus.id] != nil { ids.append(contextID(focus)) }
            if let asked { ids.append(askedID(focus, asked)) }
            ids.append(questionID(focus))
        }
        return ids
    }

    private func say(_ ids: [String], _ reader: ScrollViewProxy) {
        let opened = openedAt ?? Date()
        if openedAt == nil { openedAt = opened }
        let new = ids.filter { !revealed.contains($0) && !queue.contains($0) }
        guard !new.isEmpty else { return }
        // Still opening: what loads in the first moments was already said.
        if Date().timeIntervalSince(opened) < 1.5 { revealed.formUnion(new); return }
        // The person just answered at the bottom: what follows may be
        // followed again, up to a screen.
        // The person's own answer starts a turn: what follows is followed
        // while it fits under the answer, and past that the answer stays
        // near the top with the arrow below.
        if let first = new.first, first.hasPrefix("e/"), let id = UUID(uuidString: String(first.dropFirst(2))) { mark.turn = id }
        // The question's words are known only once its answers are drawn,
        // so they can come in after the answers were put in line: they go
        // before them ("About the place again", the
        // buttons, and only then "Anything good besides the food?").
        for id in new {
            if id.hasPrefix("a/"), let answers = queue.firstIndex(where: { $0.hasPrefix("q/") }) {
                queue.insert(id, at: answers)
            } else {
                queue.append(id)
            }
        }
        guard !saying else { return }
        saying = true
        Task { @MainActor in
            // Going back: the dots first, then what is said.
            if let until = holdUntil, until > Date() { try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow)) }
            var first = true
            while !queue.isEmpty {
                let id = queue.removeFirst()
                // The person's own answer at once; what the app says after
                // it, a beat apart.
                // A beat apart, enough to be read as said one after
                // another (it all came at once). Moving to another visit: a
                // beat to read what was just said, the app saying what it is
                // doing, then the visit, and room to take in its photos
                // before the question (after Later, "Back to …" and
                // everything with it
                // came in a blink).
                if id.hasPrefix("l/") {
                    try? await Task.sleep(for: .milliseconds(first ? 400 : 700))
                    withAnimation(.easeOut(duration: 0.2)) { pondering = Self.ponderLines[revealed.count % Self.ponderLines.count] }
                    try? await Task.sleep(for: .milliseconds(1500))
                    withAnimation(.easeOut(duration: 0.2)) { pondering = nil }
                } else if !first {
                    try? await Task.sleep(for: .milliseconds(id.hasPrefix("h/") ? 900 : id.hasPrefix("a/") ? 1000 : 700))
                }
                first = false
                withAnimation(.easeOut(duration: 0.3)) { _ = revealed.insert(id) }
            }
            saying = false
            settle()
        }
    }

    /// The question in front: the line it asks, then its choices.
    @ViewBuilder
    private func focusQuestion(_ focus: Visit, resumed: Bool) -> some View {
        if let asked, revealed.contains(askedID(focus, asked)) {
            Text(asked).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppBrand.surface))
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(Self.arrival)
        }
        // The answers under it. Laid out at once but shown only after what
        // the app says before it, so the conversation does not shrink and
        // grow back while it is said.
        let ready = revealed.contains(questionID(focus))
        ThreadQuestion(visit: focus, resumed: resumed)
            .id(focus.id)
            .opacity(ready ? 1 : 0)
            .allowsHitTesting(ready)
            .animation(.easeOut(duration: 0.25), value: ready)
            .onPreferenceChange(AskedLine.self) { asked = $0 }
    }

    @State private var viewHeight: CGFloat = 700
    static let lastID = "last"
    static let feedSpace = "feed"
    /// Lines below the screen's bottom edge, for the arrow.
    @State private var mark = ScrollMark()
    @State private var contentHeight: CGFloat = 0
    /// The height held while the conversation shrinks and grows back.
    @State private var keep: CGFloat = 0
    @State private var settling = 0
    private var endRoom: CGFloat { max(60, keep - contentHeight) }

    /// Keeps up with what is said at the end. Past a screen under the
    /// person's answer, the answer goes near the top and stays there; the
    /// arrow says there is more (after Later at the
    /// drafts, the drafts were left mid-screen and the rest out of sight).
    private func follow(_ reader: ScrollViewProxy) {
        if let turn = mark.turn, let top = mark.answerTops[turn], mark.contentHeight - top > mark.screen - 40 {
            withAnimation(.easeOut(duration: 0.3)) { reader.scrollTo(ThreadEntryView.bubbleID(turn), anchor: UnitPoint(x: 0.5, y: 0.04)) }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { reader.scrollTo(Self.lastID, anchor: .bottom) }
        }
    }

    /// Once nothing more is being said, the room held goes, and the end of
    /// the conversation comes back to the screen's bottom.
    private func settle() {
        settling += 1
        let token = settling
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard token == settling, !saying, !typing, keep > 0 else { return }
            withAnimation(.easeInOut(duration: 0.35)) { keep = 0 }
        }
    }
    /// Going back: the app's turn, before the question is asked again.
    @State private var typing = false
    /// Moving to another visit: what the app is doing, beside the dots.
    @State private var pondering: String?
    static var ponderLines: [String] {
        [String(localized: "다음 차례 찾는 중…"), String(localized: "다음 끼니 꺼내 오는 중…"), String(localized: "사진첩 넘기는 중…")]
    }
    @State private var holdUntil: Date?

    /// Going back from a line far up: the conversation is seen going down
    /// to its end, the app takes its turn, and only then is the question
    /// asked again there — never changed in place, never appearing first
    /// and scrolled to after.
    private func goBack(_ entry: ThreadEntry, of visit: Visit, _ reader: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(.easeInOut(duration: 0.7)) { reader.scrollTo(Self.lastID, anchor: .bottom) }
            try? await Task.sleep(for: .milliseconds(750))
            holdUntil = Date().addingTimeInterval(0.9)
            withAnimation(.easeOut(duration: 0.2)) { typing = true }
            ThreadActions(library: library, visit: visit).reopenOrTakeUp(entry)
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.2)) { typing = false }
            settle()
        }
    }

    /// Visits in the conversation put off with 나중에, the first put off first.
    private var putOff: [Visit.ID] {
        let later = shown.filter { threads.thread($0).facts.later && !threads.thread($0).facts.posted && !threads.thread($0).facts.notMeal }
        let when = { (id: String) in
            threads.thread(id).facts.laterAt ?? threads.thread(id).entries.last(where: { $0.kind == .answer })?.at ?? .distantPast
        }
        return later.sorted { when($0) < when($1) }
    }

    /// A visit whose last word was 나중에 coming up again: the app says it
    /// is asking again, in the record, before the question.
    private func sayAskedAgain(_ id: Visit.ID?) {
        guard let id, threads.reopened[id] == nil else { return }
        let entries = threads.thread(id).entries
        guard let last = entries.last, ThreadActions.putOff(last) else { return }
        threads.update(id) { $0.entries.append(ThreadEntry(kind: .note, label: ThreadActions.askAgainLabel)) }
    }

    private func comeBackAround() {
        guard let id = putOff.first else { return }
        threads.update(id) { $0.facts.later = false }
    }

    /// The latest answer to each question a visit has settled — place,
    /// menu, each dish's taste, the draft — in that order.
    private func settledNow(_ id: String, before: Date? = nil) -> [ThreadEntry] {
        threads.settled(id, before: before)
    }

    /// Set-aside visits still working; when one is done it is moved to just
    /// after the visit in front, so it is the next to come up.
    private var parkedBusy: Set<Visit.ID> {
        threads.parked.filter { id in
            library.matching.contains(id) || library.lookingUp.contains(id)
                || library.menuLoading.contains(id) || library.drafting.contains(id)
        }
    }

    private func unparkFinished() {
        for id in threads.parked where !parkedBusy.contains(id) {
            threads.parked.remove(id)
            order.removeAll { $0 == id }
            let front = shown.first { threads.step($0) != .done && !threads.parked.contains($0) }
            let at = front.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.endIndex
            order.insert(id, at: min(at, order.endIndex))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        AppTopBar(prefetcher: prefetcher, inLibrary: false, toggle: openLibrary)
    }

    @ViewBuilder
    private var waiting: some View {
        if !library.feedCandidates.isEmpty, brainReady {
            // The wait as something to watch: what the preparation finds.
            PrepShowcase(prefetcher: prefetcher, ready: order.count, showCards: { watching = false })
        } else if brainReady, library.scanning, library.feedCandidates.isEmpty, library.toClassify > 0 {
            // The first look through the library, the same way: the food
            // photos it finds, as stickers.
            ScanShowcase(library: library)
        } else {
            VStack(spacing: 14) {
                Spacer()
                if !brainReady, !library.feedCandidates.isEmpty || library.scanning {
                    // The first thing after the photos: which AI to think
                    // with, here rather than only in Settings, chosen while
                    // the photos are still being looked through.
                    BrainSetup(changed: checkBrain)
                } else if library.scanning {
                    Text("사진에서 밥 먹은 곳을 찾고 있어요").font(.system(size: 26, weight: .black)).foregroundStyle(AppBrand.foreground)
                } else if library.feedCandidates.isEmpty {
                    Text("쓸 방문이 없어요").font(.system(size: 26, weight: .black)).foregroundStyle(AppBrand.foreground)
                }
                Spacer()
                // A first look through the whole library takes a while; it
                // was "no visits" until it was done.
                if library.scanning, library.feedCandidates.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(library.toClassify > 0 ? String(localized: "사진 살펴보는 중 \(library.classified) / \(library.toClassify)")
                                                    : String(localized: "사진 살펴보는 중"))
                            .font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                    }
                    .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity)
            // Signing in finishes in the browser or on x.ai; look until it has.
            .task(id: brainReady) {
                while !brainReady, !Task.isCancelled {
                    checkBrain()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Once an AI is connected, the preparation starts.
    private func checkBrain() {
        guard Brain.subscriptionReady != brainReady else { return }
        brainReady = Brain.subscriptionReady
        if brainReady { prefetcher.want(Array(library.feedCandidates.prefix(Prefetcher.ahead))) }
    }

    // MARK: Order

    /// The visits already in the conversation stay where they are; what is
    /// ready behind them is ordered by how close it is to the last one.
    private func rebuild() {
        let readyIDs = ready.map(\.id)
        let known = Set(library.visits.map(\.id))
        let keep = order.isEmpty ? threads.talkedAbout.filter { known.contains($0) } : shown
        // A conversation already under way is shown, not the wait.
        if !keep.isEmpty { watching = false }
        let rest = readyIDs.filter { !keep.contains($0) }
        order = keep + sortedByNearness(rest)
        lookAhead()
    }

    /// Visits that just became ready join the end. Nothing already in the
    /// conversation ever leaves it, finished or not.
    private func merge() {
        let readyIDs = ready.map(\.id)
        // What was talked about before a relaunch is still the conversation
        // (posted visits left it on relaunch, and with them what
        // came before the visit in front).
        let known = Set(library.visits.map(\.id))
        let talked = threads.talkedAbout.filter { known.contains($0) }
        if order.isEmpty { order = talked }
        let inThread = Set(shown).union(threads.parked).union(talked)
        order.removeAll { !readyIDs.contains($0) && !inThread.contains($0) }
        let new = readyIDs.filter { !order.contains($0) }
        order.append(contentsOf: sortedByNearness(new))
    }

    private func sortedByNearness(_ ids: [Visit.ID]) -> [Visit.ID] {
        let visits = ids.compactMap { id in library.visits.first { $0.id == id } }
        guard let anchorID = anchor, let base = library.visits.first(where: { $0.id == anchorID }) else {
            return visits.sorted { $0.takenAt > $1.takenAt }.map(\.id)
        }
        func rank(_ v: Visit) -> (Int, Double) {
            let hours = abs(v.takenAt.timeIntervalSince(base.takenAt)) / 3600
            let km: Double = {
                guard let a = v.coordinate, let b = base.coordinate else { return 9_999 }
                return CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1000
            }()
            if Calendar.current.isDate(v.takenAt, inSameDayAs: base.takenAt) { return (0, hours) }
            if hours < 72, km < 50 { return (1, hours) }
            return (2, km + hours / 24)
        }
        return visits.sorted { rank($0) < rank($1) }.map(\.id)
    }

    /// Twelve visits kept ready ahead of the person, counting the ones on the
    /// way: each one finished or put off starts one more at once,
    /// nearest the visit in view first.
    private static let ahead = Prefetcher.ahead
    /// Ready visits still to be answered. One put off with Later does not
    /// count: it is waiting behind the new ones, so one more is got ready in
    /// its place (two Laters showed no canvas).
    private var openReady: Int {
        ready.filter { threads.step($0.id) != .done && !threads.thread($0.id).facts.later }.count
    }
    private var aheadCount: Int { openReady * 10_000 + prefetcher.preparing.count * 100 + prefetcher.waiting.count }

    private func lookAhead() {
        let need = Self.ahead - openReady - prefetcher.preparing.count - prefetcher.waiting.count
        guard need > 0 else { return }
        let next = library.feedCandidates.filter { v in
            !prefetcher.isReady(v) && !prefetcher.needsPerson.contains(v.id) && !prefetcher.tried.contains(v.id)
                && !prefetcher.preparing.contains(v.id) && !prefetcher.waiting.contains(v.id)
        }
        let picked = sortedByNearness(next.map(\.id)).prefix(need)
        prefetcher.want(picked.compactMap { id in next.first { $0.id == id } })
    }

    // MARK: Sheets

    private func openPost(_ visit: Visit) {
        let opened = FeedSheet(visit: visit.id, step: .post, placeBefore: nil, dishesBefore: [])
        lastSheet = opened
        sheet = opened
    }

    private func closedSheet() {
        guard let last = lastSheet, let visit = library.visits.first(where: { $0.id == last.visit }) else { return }
        lastSheet = nil
        ThreadActions(library: library, visit: visit).postSheetClosed()
    }

    @State private var lastSheet: FeedSheet?
}

/// Opens at the bottom. Seen to the end, lines coming in below are
/// followed (`follow`); scrolled up, what is on screen stays where it is
/// and `below` says there is more under the screen's edge (macOS 15 and
/// later; earlier, no arrow).
private struct HoldScroll: ViewModifier {
    struct Probe: Equatable {
        let height: CGFloat
        let below: Bool
        let short: Bool
    }
    let mark: ScrollMark
    let room: CGFloat
    let follow: () -> Void
    @State private var quietUntil = Date.distantPast
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                // Read as three facts that change rarely, not every frame
                // of a scroll: each change redraws the conversation, and
                // redrawing it on every frame made scrolling stutter.
                .onScrollGeometryChange(for: Probe.self) { g in
                    let end = g.contentSize.height - room
                    let seen = g.visibleRect.maxY
                    return Probe(height: g.contentSize.height.rounded(), below: seen < end - 40, short: seen < end - 8)
                } action: { old, now in
                    if mark.below != now.below { withAnimation(.easeOut(duration: 0.2)) { mark.below = now.below } }
                    if old.height == now.height {
                        // Scrolled: by the person, or by following.
                        if Date() > quietUntil, mark.atEnd != !now.below { mark.atEnd = !now.below }
                    } else if mark.atEnd, now.height > old.height, now.short {
                        quietUntil = Date().addingTimeInterval(0.4)
                        follow()
                    }
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// The bar along the top, the same on the conversation and on past
/// reviews · map: the button at its right end goes to the other one, so
/// going there and back is the same place under the pointer (the
/// way back had moved to the left of the window).
struct AppTopBar: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject var prefetcher: Prefetcher
    let inLibrary: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            BrandWordmark(size: 22)
            Scoreboard()
            if !prefetcher.preparing.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(prefetcher.preparing.count)개 준비 중").font(.system(size: 13)).foregroundStyle(AppBrand.faint)
                }
            }
            if prefetcher.stoppedForLimit {
                Text(Brain.current == .claude ? (ClaudeAPI.creditOut ? "Claude API 크레딧을 다 써서 멈췄어요" : "Claude 준비 예산 $1을 다 써서 멈췄어요") : Brain.current == .grok ? "Grok 사용 한도에 닿아 준비를 멈췄어요" : "ChatGPT 사용 한도에 닿아 준비를 멈췄어요")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppBrand.muted).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            Button(action: toggle) {
                Text(inLibrary ? "대화로 돌아가기" : "지난 리뷰 · 지도").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppBrand.foreground)
                    .padding(.horizontal, 14).frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
            }
            .buttonStyle(.plainHit)
        }
        .padding(.horizontal, 28).frame(height: 60)
        .overlay(alignment: .bottom) { Divider().overlay(AppBrand.line) }
    }
}

/// The count beside the wordmark, turning over like a scoreboard: what is
/// left, what is done today, what is done in all.
private struct Scoreboard: View {
    @EnvironmentObject private var library: PhotoLibrary
    @State private var at = 0

    private var lines: [String] {
        let today = library.posted.values.filter { Calendar.current.isDateInToday($0) }.count
        return [String(localized: "남은 방문 \(library.feedCandidates.count)")]
            + (today > 0 ? [String(localized: "오늘 올린 리뷰 \(today)")] : [])
            + [String(localized: "지금까지 올린 리뷰 \(library.posted.count)")]
    }

    var body: some View {
        let lines = lines
        let line = lines[at % lines.count]
        ZStack(alignment: .leading) {
            Text(line).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(AppBrand.muted)
                .id(line)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        // Plain text, not a box: boxed, it read as a button.
        .frame(height: 20).clipped()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(at % lines.count == 0 ? 6 : 3.5))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { at += 1 }
            }
        }
    }
}

/// Whether there is more below the screen's edge, kept apart from the
/// conversation so that only the arrow is drawn again when it changes.
@MainActor final class ScrollMark: ObservableObject {
    @Published var below = false
    /// The person's latest answer, where each answer bubble's top is in the
    /// conversation, and the sizes followed against; not drawn.
    var turn: UUID?
    /// Whether the person was at the end before the conversation grew.
    var atEnd = true
    var answerTops: [UUID: CGFloat] = [:]
    var contentHeight: CGFloat = 0
    var screen: CGFloat = 700
}

/// The arrow saying there is more below.
private struct MoreBelow: View {
    @ObservedObject var mark: ScrollMark
    let go: () -> Void
    var body: some View {
        if mark.below {
            Button(action: go) {
                Image(systemName: "arrow.down").font(.system(size: 17, weight: .bold)).foregroundStyle(AppBrand.foreground)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(AppBrand.raisedSurface))
                    .overlay(Circle().stroke(AppBrand.line, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plainHit)
            .help(Text("아래에 더 있어요"))
            .padding(.bottom, 20)
            .transition(.opacity)
        }
    }
}
