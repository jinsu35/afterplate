import SwiftUI
import MapKit

/// The wait, made something to watch: while the first
/// cards are being prepared, what the preparation finds is written onto a
/// canvas — the visit's photos, the place and its 동네, a little map, menu
/// names, a line of the draft — under a rotating line about what the app is
/// up to. Finds are written one at a time even when many arrive at once
/// (names and the draft line type out, menu chips pop one by one).
struct PrepShowcase: View {
    @ObservedObject var prefetcher: Prefetcher
    /// Cards already ready; when there are some, a button goes to them.
    var ready = 0
    var showCards: () -> Void = {}
    @State private var lineIndex = Int.random(in: 0..<PrepShowcase.lines.count)

    static var lines: [String] {
        [
            String(localized: "메뉴판 몰래 훔쳐보는 중…"),
            String(localized: "사진 속 젓가락 세는 중…"),
            String(localized: "갈비에 어울리는 형용사 고르는 중…"),
            String(localized: "동네 이름 외우는 중…"),
            String(localized: "그날의 허기를 복원하는 중…"),
            String(localized: "소스 색깔로 메뉴 추리하는 중…"),
            String(localized: "리뷰 첫 문장 다듬는 중…"),
            String(localized: "구글 지도랑 눈치 싸움 중…"),
            String(localized: "트로트 박자 맞추는 중…"),
            String(localized: "김훈 선생님께 허락받는 중…"),
            String(localized: "치즈가 늘어난 길이 재는 중…"),
            String(localized: "젓가락 각도로 국적 맞히는 중…"),
            String(localized: "밥 한 공기 분량 계산 중…"),
            String(localized: "심야식당 마스터 섭외 중…"),
            String(localized: "맛슐랭 별 닦는 중…"),
        ]
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(Self.lines[lineIndex])
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(AppBrand.signal)
                .id(lineIndex)
                .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                        removal: .opacity))
                .padding(.top, 30)
            Text(prefetcher.preparing.isEmpty ? "찾은 것들을 정리하는 중이에요"
                 : "방문 \(prefetcher.preparing.count)개를 미리 준비하고 있어요")
                .font(.system(size: 14)).foregroundStyle(AppBrand.muted)

            StickerCanvas(source: { prefetcher.finds })

            if ready > 0 {
                Button(action: showCards) {
                    Text("준비된 \(ready)개 먼저 보기 →")
                        .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(AppBrand.ink)
                        .padding(.horizontal, 26).frame(height: 52)
                        .background(Capsule().fill(AppBrand.signal))
                }
                .buttonStyle(.plainHit)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    lineIndex = (lineIndex + 1 + Int.random(in: 0..<3)) % Self.lines.count
                }
            }
        }
    }
}

/// The first look through the library, made something to watch the same
/// way: each food photo it finds goes onto the canvas as a sticker, a few
/// taken together as one stack, and now and then a day or a place in big
/// puffy letters.
struct ScanShowcase: View {
    @ObservedObject var library: PhotoLibrary
    @State private var lineIndex = Int.random(in: 0..<ScanShowcase.lines.count)

    static var lines: [String] {
        [
            String(localized: "사진첩 넘기는 중…"),
            String(localized: "음식 사진 골라내는 중…"),
            String(localized: "셀카는 살짝 넘기는 중…"),
            String(localized: "빙수 녹기 전에 찾는 중…"),
            String(localized: "고양이 사진은 못 본 척하는 중…"),
            String(localized: "그날 먹은 거 떠올리는 중…"),
            String(localized: "메뉴판 사진은 빼 두는 중…"),
            String(localized: "야경 사진 지나가는 중…"),
            String(localized: "젓가락 보이면 멈추는 중…"),
            String(localized: "밥상 앞에서 찍은 것만 고르는 중…"),
        ]
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(Self.lines[lineIndex])
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(AppBrand.signal)
                .id(lineIndex)
                .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                        removal: .opacity))
                .padding(.top, 30)
            Text(library.toClassify > 0 ? String(localized: "사진 살펴보는 중 \(library.classified) / \(library.toClassify)")
                                        : String(localized: "사진 살펴보는 중"))
                .font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                .monospacedDigit()

            StickerCanvas(source: { library.scanFinds })
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    lineIndex = (lineIndex + 1 + Int.random(in: 0..<3)) % Self.lines.count
                }
            }
        }
    }
}

/// Finds stuck onto a canvas one beat at a time, like stickers: new rows
/// fill in at the bottom and the top row slides up and away, what is on it
/// drifts and trades places, and when nothing new has come in, earlier finds
/// are put down again so it never stands still. `source` is read on every
/// beat, so it sees finds that arrive while the canvas is up.
struct StickerCanvas: View {
    let source: () -> [Prefetcher.Find]
    @State private var rows: [CanvasRow] = []
    /// Finds already written once.
    @State private var written: Set<UUID> = []
    @State private var tick = 0

    /// Rows on the canvas at once; one more pushes the top one off.
    private static let visibleRows = 4
    /// One write every this long.
    private static let beat: Duration = .milliseconds(1100)

    struct CanvasRow: Identifiable {
        let id = UUID()
        var items: [Placed]
    }

    struct Placed: Identifiable {
        let id = UUID()
        let find: Prefetcher.Find
        var nudge: CGSize
        var tilt: Double
    }

    var body: some View {
        VStack(spacing: 26) {
            ForEach(rows) { row in
                // A row wider than the window drops scraps from its end
                // rather than squeezing them: squeezed, menu chips broke
                // mid-word ("America / no") and the edges were cut.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(stride(from: row.items.count, through: 1, by: -1)), id: \.self) { count in
                        HStack(alignment: .center, spacing: 24) {
                            ForEach(row.items.prefix(count)) { placed in
                                FindView(find: placed.find)
                                    .rotationEffect(.degrees(placed.tilt))
                                    .offset(placed.nudge)
                                    .transition(.scale(scale: 0.2, anchor: .center).combined(with: .opacity))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
        .clipped()
        .task { await write() }
    }

    // MARK: Writing

    /// The canvas's clock: each beat writes one find (a new one if any came
    /// in, else an earlier one again), and every beat something already on
    /// the canvas drifts or trades places.
    private func write() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.beat)
            tick += 1
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { stir() }
            guard let find = nextFind() else { continue }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { place(find) }
        }
    }

    private func nextFind() -> Prefetcher.Find? {
        let finds = source()
        if let fresh = finds.first(where: { !written.contains($0.id) }) {
            written.insert(fresh.id)
            return fresh
        }
        // Nothing new: write an earlier find again, one not on the canvas now
        // — never a stamp, whose words are each meant to come once.
        let onCanvas = Set(rows.flatMap(\.items).map(\.find.id))
        let again = finds.filter {
            if case .stamp = $0.kind { return false }
            return true
        }
        return again.filter { !onCanvas.contains($0.id) }.randomElement()
            ?? (rows.count < 2 ? again.randomElement() : nil)
    }

    /// Into the bottom row if it has room, else a new row; past the visible
    /// rows the top one goes.
    private func place(_ find: Prefetcher.Find) {
        let placed = Placed(find: find, nudge: Self.randomNudge(), tilt: Double.random(in: -4...4))
        if var last = rows.last, last.items.count < Self.room(for: last.items + [placed]) {
            last.items.append(placed)
            rows[rows.count - 1] = last
        } else {
            rows.append(CanvasRow(items: [placed]))
        }
        if rows.count > Self.visibleRows { rows.removeFirst(rows.count - Self.visibleRows) }
    }

    /// How many scraps a row takes: three small ones, two when one is wide,
    /// one when two would be.
    private static func room(for items: [Placed]) -> Int {
        let wide = items.filter {
            if case .line = $0.find.kind { return true }
            if case .menu = $0.find.kind { return true }
            // A stamp longer than a word or two is as wide as a menu row;
            // counted small, it lay across the photos beside it.
            if case .stamp(let word) = $0.find.kind, word.count > 6 { return true }
            return false
        }.count
        return wide >= 2 ? 1 : (wide == 1 ? 2 : 3)
    }

    /// Something on the canvas moves: a row trades two of its scraps, or one
    /// scrap drifts to a new spot and angle.
    private func stir() {
        guard !rows.isEmpty else { return }
        let r = Int.random(in: 0..<rows.count)
        if tick % 3 == 0, rows[r].items.count > 1 {
            rows[r].items.swapAt(0, rows[r].items.count - 1)
        } else if !rows[r].items.isEmpty {
            let i = Int.random(in: 0..<rows[r].items.count)
            rows[r].items[i].nudge = Self.randomNudge()
            rows[r].items[i].tilt = Double.random(in: -5...5)
        }
    }

    private static func randomNudge() -> CGSize {
        CGSize(width: Double.random(in: -26...26), height: Double.random(in: -10...10))
    }
}

/// The canvas in the conversation, while more visits are got ready after
/// the ones in front were all done or put off: the
/// same scraps at a smaller size, inside the conversation's box, scattered
/// across its width — each one stays where it is put, new ones join below
/// so the conversation only grows downward, and the working line sits
/// under them all, the way a chat app shows its thinking above the input.
struct PrepStrip: View {
    @ObservedObject var prefetcher: Prefetcher
    @State private var lineIndex = Int.random(in: 0..<PrepShowcase.lines.count)
    @State private var placed: [StickerCanvas.Placed] = []
    @State private var written: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !placed.isEmpty {
                WrapRow(spacing: 0, lineSpacing: 10) {
                    ForEach(placed) { item in
                        // The gap before and the drop are drawn once, when
                        // the scrap is put down; nothing moves after.
                        FindView(find: item.find, small: true)
                            .rotationEffect(.degrees(item.tilt))
                            .padding(.leading, item.nudge.width)
                            .padding(.top, item.nudge.height)
                            .transition(.scale(scale: 0.3, anchor: .center).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                TypingDots(label: nil)
                Text(PrepShowcase.lines[lineIndex])
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppBrand.signal)
                    .id(lineIndex)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // What is being prepared now was found just before this came up.
            written = Set(prefetcher.finds.filter { !prefetcher.preparing.contains($0.visit) }.map(\.id))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let find = prefetcher.finds.first(where: { !written.contains($0.id) }) else { continue }
                written.insert(find.id)
                let spot = CGSize(width: Double.random(in: 8...70), height: Double.random(in: 0...16))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    placed.append(StickerCanvas.Placed(find: find, nudge: spot, tilt: Double.random(in: -4...4)))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                withAnimation(.easeInOut(duration: 0.3)) {
                    lineIndex = (lineIndex + 1 + Int.random(in: 0..<3)) % PrepShowcase.lines.count
                }
            }
        }
    }
}

/// One find, drawn as a scrap on the canvas.
private struct FindView: View {
    let find: Prefetcher.Find
    /// The chat's version: everything at about 60%.
    var small = false
    private func z(_ v: CGFloat) -> CGFloat { small ? (v * 0.6).rounded() : v }

    var body: some View {
        switch find.kind {
        case .photos(let photos):
            HStack(spacing: z(-18)) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    PhotoTile(photo: photo)
                        .frame(width: z(96), height: z(96))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppBrand.ink, lineWidth: small ? 2 : 3))
                        .rotationEffect(.degrees(Double(index * 7 - 7)))
                }
            }
        case .stamp(let word):
            PuffyText(text: word, size: z(40))
        case .place(let name, let area, let at):
            HStack(spacing: z(14)) {
                if let at {
                    Map(initialPosition: .region(MKCoordinateRegion(center: at, span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.009))),
                        interactionModes: []) {
                        Marker("", coordinate: at).tint(AppBrand.signal)
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .frame(width: z(150), height: z(104))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    TypedText(text: name, perLetter: 0.06)
                        .font(.system(size: z(28), weight: .black, design: .rounded)).foregroundStyle(AppBrand.foreground)
                        .lineLimit(1).fixedSize()
                    if let area {
                        TypedText(text: "📍 " + area, perLetter: 0.05, delay: 0.06 * Double(name.count))
                            .font(.system(size: z(16), weight: .heavy, design: .rounded)).foregroundStyle(AppBrand.signal)
                    }
                }
            }
        case .menu(let names):
            // As many chips as fit, each on one line, never broken.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: names.count, through: 1, by: -1)), id: \.self) { count in
                    HStack(spacing: 8) {
                        ForEach(Array(names.prefix(count).enumerated()), id: \.offset) { index, name in
                            PoppingChip(name: name, index: index, small: small)
                        }
                    }
                }
            }
        case .line(let text):
            TypedText(text: "“" + text + "”", perLetter: 0.035)
                .font(.system(size: z(20), weight: .bold, design: .serif)).italic()
                .foregroundStyle(AppBrand.foreground)
                .frame(maxWidth: z(520), alignment: .leading)
                .padding(z(16))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        }
    }
}

/// Text that types itself out, letter by letter. The full text is laid out
/// from the start (the rest kept clear) so the scrap does not grow and shove
/// its neighbours while it types.
private struct TypedText: View {
    let text: String
    var perLetter: Double
    var delay: Double = 0
    @State private var shown = 0

    var body: some View {
        let letters = Array(text)
        (Text(String(letters.prefix(shown)))
            + Text(String(letters.dropFirst(shown))).foregroundColor(.clear))
            .task {
                try? await Task.sleep(for: .seconds(delay))
                while shown < letters.count, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(perLetter))
                    shown += 1
                }
            }
    }
}

/// A word in fat, puffy sticker letters: a deep fill inside a thick
/// white edge, the whole sticker dropped onto a darker shade of the fill,
/// popping in with a bounce. The colour is picked from the word, so the
/// same word keeps its colour. Emoji are drawn once beside the letters: the
/// edge is the word drawn around itself, and emoji keep their own colours,
/// so inside it they came out stacked many times over.
private struct PuffyText: View {
    let text: String
    let size: CGFloat
    @State private var on = false

    /// Deep enough to read inside a white edge; the light ones (the
    /// brand's lime, a pale blue) washed into it.
    private static let fills: [(Color, Color)] = [
        (Color(red: 0.96, green: 0.22, blue: 0.45), Color(red: 0.50, green: 0.04, blue: 0.20)),
        (Color(red: 0.13, green: 0.50, blue: 1.0), Color(red: 0.03, green: 0.20, blue: 0.52)),
        (Color(red: 1.0, green: 0.42, blue: 0.0), Color(red: 0.52, green: 0.18, blue: 0.0)),
        (Color(red: 0.52, green: 0.26, blue: 1.0), Color(red: 0.24, green: 0.08, blue: 0.56)),
        (Color(red: 0.0, green: 0.66, blue: 0.40), Color(red: 0.0, green: 0.30, blue: 0.16)),
    ]

    private static func isEmoji(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || (0x1F1E6...0x1F1FF).contains($0.value) }
    }

    /// The text in runs, letters and emoji apart, in order.
    private var runs: [(text: String, emoji: Bool)] {
        var runs: [(text: String, emoji: Bool)] = []
        for c in text {
            let emoji = Self.isEmoji(c)
            if c == " " { if !runs.isEmpty { runs[runs.count - 1].text.append(c) }; continue }
            if let last = runs.last, last.emoji == emoji { runs[runs.count - 1].text.append(c) }
            else { runs.append((String(c), emoji)) }
        }
        return runs.map { ($0.text.trimmingCharacters(in: .whitespaces), $0.emoji) }.filter { !$0.text.isEmpty }
    }

    var body: some View {
        let (fill, drop) = Self.fills[abs(text.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.fills.count]
        let edge = max(2, size / 10)
        HStack(spacing: size * 0.22) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                if run.emoji {
                    Text(run.text).font(.system(size: size * 1.1))
                        .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: edge)
                } else {
                    let letters = Text(run.text).font(.system(size: size, weight: .black, design: .rounded))
                    ZStack {
                        // The drop, then the white edge: the word drawn around itself.
                        ForEach(0..<12, id: \.self) { i in
                            let angle = Double(i) * .pi / 6
                            letters.foregroundStyle(drop)
                                .offset(x: cos(angle) * edge, y: sin(angle) * edge + edge * 1.3)
                        }
                        ForEach(0..<12, id: \.self) { i in
                            let angle = Double(i) * .pi / 6
                            letters.foregroundStyle(Color.white)
                                .offset(x: cos(angle) * edge, y: sin(angle) * edge)
                        }
                        letters.foregroundStyle(fill)
                        // A soft shine across the top of the letters.
                        letters.foregroundStyle(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                    }
                }
            }
        }
        .lineLimit(1).fixedSize()
        .padding(edge * 2)
        .scaleEffect(on ? 1 : 0.3)
        .opacity(on ? 1 : 0)
        .task { withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) { on = true } }
    }
}

/// A menu name that pops onto the canvas a beat after the one before it.
private struct PoppingChip: View {
    let name: String
    let index: Int
    var small = false
    @State private var on = false

    var body: some View {
        Text(name)
            .font(.system(size: CGFloat([17, 22, 19, 24, 18, 20][index % 6]) * (small ? 0.6 : 1), weight: .heavy, design: .rounded))
            .lineLimit(1).fixedSize()
            .foregroundStyle(index % 2 == 0 ? AppBrand.ink : AppBrand.foreground)
            .padding(.horizontal, small ? 8 : 12).padding(.vertical, small ? 4 : 6)
            .background(Capsule().fill(index % 2 == 0 ? AppBrand.signal : AppBrand.raisedSurface))
            .rotationEffect(.degrees(Double((index % 3) * 3 - 3)))
            .scaleEffect(on ? 1 : 0.2)
            .opacity(on ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(0.18 * Double(index)))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { on = true }
            }
    }
}
