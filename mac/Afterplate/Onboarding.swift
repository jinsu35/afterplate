import SwiftUI

/// What a first-time person is shown: the photos on the first-run screen,
/// then which AI to think with, then each thing that is hard to find on
/// one's own, said once in the conversation where it first comes up — not
/// slides up front.

/// Which AI to think with, on the feed while none is connected. The three
/// as big cards, the chosen one's sign-in under them.
struct BrainSetup: View {
    @AppStorage(Brain.defaultsKey) private var brain = Brain.chatgpt.rawValue
    /// Asks the feed to look again (a key saved is not published anywhere).
    let changed: () -> Void

    private struct Option {
        let brain: Brain
        let name: String
        let cost: String
        let note: String
    }

    private var options: [Option] {
        [
            Option(brain: .chatgpt, name: "ChatGPT",
                   cost: String(localized: "유료 구독 · 추가 요금 없음"),
                   note: String(localized: "ChatGPT Plus 이상 구독 사용량에서 써요. 무료 계정은 안 돼요.")),
            Option(brain: .grok, name: "Grok",
                   cost: String(localized: "유료 구독 · 추가 요금 없음"),
                   note: String(localized: "SuperGrok 또는 X Premium+ 구독 사용량에서 써요. 무료 계정은 안 돼요.")),
            Option(brain: .claude, name: "Claude",
                   cost: String(localized: "내 API 키 · 쓴 만큼 요금"),
                   note: String(localized: "방문 하나에 약 $0.18")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("어떤 AI로 할까요?").font(.system(size: 30, weight: .black)).foregroundStyle(AppBrand.foreground)
                Text("가게와 메뉴 찾기, 리뷰 초안을 고른 AI가 해요. 나중에 설정에서 바꿀 수 있어요.")
                    .font(.system(size: 15)).foregroundStyle(AppBrand.muted)
            }
            HStack(spacing: 12) {
                ForEach(options, id: \.brain) { option in card(option) }
            }
            // As tall as the tallest card, not the window.
            .fixedSize(horizontal: false, vertical: true)
            BrainConnect(brain: Brain(rawValue: brain) ?? .chatgpt, changed: changed)
                .frame(maxWidth: 460, minHeight: 130, alignment: .topLeading)
        }
        .frame(maxWidth: 720)
        .padding(40)
    }

    private func card(_ option: Option) -> some View {
        let chosen = brain == option.brain.rawValue
        return Button { brain = option.brain.rawValue; changed() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: option.name).font(.system(size: 22, weight: .black))
                    Spacer()
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(chosen ? AppBrand.signal : AppBrand.faint)
                }
                .foregroundStyle(AppBrand.foreground)
                Text(option.cost).font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.foreground)
                Text(option.note).font(.system(size: 13)).foregroundStyle(AppBrand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(chosen ? AppBrand.raisedSurface : AppBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(chosen ? AppBrand.signal : AppBrand.line, lineWidth: chosen ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plainHit)
    }
}

/// The how-to lines said once each. A tip belongs to the first place it
/// came up (a visit or an answer) and stays there in the record; it is
/// never said anywhere else, so nothing appears or leaves above the
/// person later.
@MainActor
final class OnceTips: ObservableObject {
    static let shared = OnceTips()

    enum Tip: String {
        /// Under the first visit's photos: drag one out, click to see it big.
        case photos
        /// Under the first answer: press it to answer again.
        case answer
        /// Under the first visit put off: press it to take the visit up.
        case later
    }

    private static let key = AppData.apart("onceTips")
    @Published private var placed: [String: String]

    private init() {
        placed = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func shows(_ tip: Tip, at anchor: String) -> Bool { placed[tip.rawValue] == anchor }

    /// The tip goes to `anchor` unless it has been said already.
    func claim(_ tip: Tip, at anchor: String) {
        guard placed[tip.rawValue] == nil else { return }
        placed[tip.rawValue] = anchor
        UserDefaults.standard.set(placed, forKey: Self.key)
    }
}

/// A tip under the view it is about, claimed for that place when the view
/// first appears. Nothing is added where the tip is not said.
private struct OnceTipModifier: ViewModifier {
    @ObservedObject private var tips = OnceTips.shared
    let tip: OnceTips.Tip
    let anchor: String
    let eligible: Bool
    let alignment: HorizontalAlignment
    let symbol: String
    let text: String

    func body(content: Content) -> some View {
        VStack(alignment: alignment, spacing: 10) {
            content
            if tips.shows(tip, at: anchor) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                    Text(text).font(.system(size: 14))
                }
                .foregroundStyle(AppBrand.muted)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(AppBrand.surface))
                .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
            }
        }
        .onAppear { if eligible { tips.claim(tip, at: anchor) } }
    }
}

extension View {
    func onceTip(_ tip: OnceTips.Tip, at anchor: String, eligible: Bool = true, alignment: HorizontalAlignment = .leading,
                 symbol: String, text: String) -> some View {
        modifier(OnceTipModifier(tip: tip, anchor: anchor, eligible: eligible, alignment: alignment, symbol: symbol, text: text))
    }
}
