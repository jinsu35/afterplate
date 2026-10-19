import SwiftUI

/// The step-by-step shell: one step per screen, a stepper on top, one big
/// primary action at the bottom right. Replaces the sidebar-plus-panels
/// layout, which read as cramped and directionless.
enum FlowStep: Int, CaseIterable, Identifiable {
    // The visit list is not a step any more: it is the left pane, always
    // there, and picking a card starts the review on the right.
    case place = 1, dishes, review, post
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .place: return String(localized: "가게")
        case .dishes: return String(localized: "메뉴")
        case .review: return String(localized: "리뷰")
        case .post: return String(localized: "올리기")
        }
    }
}

struct FlowStepper: View {
    let current: FlowStep
    /// Steps that can be jumped to by clicking their label (done ones).
    var onSelect: ((FlowStep) -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            ForEach(FlowStep.allCases) { step in
                let done = step.rawValue < current.rawValue
                let now = step == current
                Button { if done { onSelect?(step) } } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(now ? AppBrand.signal : (done ? Color.white.opacity(0.14) : AppBrand.raisedSurface))
                            .overlay(Circle().stroke(AppBrand.line, lineWidth: 1))
                            .frame(width: 28, height: 28)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue)").font(.system(size: 13, weight: .black))
                                .foregroundStyle(now ? AppBrand.ink : AppBrand.faint)
                        }
                    }
                    Text(step.title)
                        .font(.system(size: 15, weight: now ? .black : .semibold))
                        .foregroundStyle(now ? AppBrand.signal : (done ? .white : AppBrand.faint))
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit)
                .disabled(!done || onSelect == nil)
                .onHover { inside in if done, onSelect != nil { inside ? NSCursor.pointingHand.push() : NSCursor.pop() } }
                if step != .post {
                    Rectangle().fill(AppBrand.line).frame(width: 24, height: 1)
                }
            }
        }
    }
}

struct BigPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BigButtonBody(configuration: configuration, primary: true)
    }
}

struct BigSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BigButtonBody(configuration: configuration, primary: false)
    }
}

/// `.plain`, but the whole label is the button. Plain hit-tests only what is
/// drawn, so a button with an outline and no fill — 보관 — took clicks on
/// its letters and its 1pt border and nowhere else.
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PlainHitButtonStyle {
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

/// Both big buttons. A disabled one is drawn as disabled: the style ignored
/// `isEnabled`, so a dead 다음: 리뷰 쓰기 stayed bright yellow and was
/// pressed for nothing.
private struct BigButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let fill = !enabled ? AppBrand.raisedSurface.opacity(0.5)
            : primary ? AppBrand.signal : AppBrand.raisedSurface
        configuration.label
            .font(.system(size: primary ? 17 : 15, weight: primary ? .black : .bold))
            .foregroundStyle(!enabled ? AppBrand.faint : primary ? AppBrand.ink : AppBrand.foreground)
            .padding(.horizontal, primary ? 28 : 20)
            .frame(minHeight: 52)
            .background(fill.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay {
                if !primary || !enabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Header + scrolling body + footer. `primary` is the one thing to do next.
struct FlowScreen<Content: View, Footer: View>: View {
    let step: FlowStep
    let title: String
    /// One line under the title, for what the screen is about — the place and
    /// the time, say. Not prose: the screens carry as little text as they can.
    var subtitle: String? = nil
    var prose: String? = nil
    var right: String = ""
    var onHome: (() -> Void)? = nil
    var onStep: ((FlowStep) -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.flowVisitID) private var flowVisitID

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Closing the review and getting the list back was hidden in
                // the wordmark; say it out loud.
                if let onHome {
                    Button(action: onHome) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .black))
                            Text("지도").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(AppBrand.foreground)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppBrand.raisedSurface))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plainHit)
                    .help("Esc 로도 닫아요")
                }
                Spacer()
                FlowStepper(current: step, onSelect: onStep)
                Spacer()
                Text(right).font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                    .frame(minWidth: 160, alignment: .trailing)
                if let onHome, let id = flowVisitID {
                    // Back to the map with this visit's pin lit.
                    Button { library.mapFocus = id; onHome() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 12, weight: .bold))
                            Text("지도에서").font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(AppBrand.foreground)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(AppBrand.raisedSurface))
                        .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plainHit)
                    .help("이 방문을 지도에서 봐요")
                }
                if let onHome, let id = flowVisitID, let visit = library.visits.first(where: { $0.id == id }),
                   !library.notMeals.contains(id) {
                    // Here as well as on the card: a card that had left the
                    // list took the only 보관 with it.
                    Button { library.setNotMeal(true, for: visit); onHome() } label: {
                        Text("보관").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppBrand.muted)
                            .padding(.horizontal, 12).frame(height: 32)
                            .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plainHit)
                    .help("리뷰 안 쓸 방문은 보관함으로 치워요")
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 64)
            Divider().overlay(AppBrand.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 34, weight: .black))
                            .tracking(-1)
                            .foregroundStyle(AppBrand.foreground)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppBrand.muted)
                        }
                        if let prose {
                            Text(prose)
                                .font(.system(size: 15))
                                .foregroundStyle(AppBrand.muted)
                                .lineSpacing(4)
                                .frame(maxWidth: 760, alignment: .leading)
                        }
                    }
                    content
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }

            Divider().overlay(AppBrand.line)
            HStack {
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            // Grows with what it holds: the dishes step puts the review's
            // contents here, and a long list wraps.
            .frame(minHeight: 84)
            .background(AppBrand.ink)
        }
    }
}

/// A big titled panel — the flow's version of BrandPanel.
struct FlowPanel<Content: View>: View {
    var highlighted = false
    var padding: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppBrand.surface)
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(highlighted ? AppBrand.signal : AppBrand.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FlowNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15)).foregroundStyle(AppBrand.muted).lineSpacing(4)
    }
}

struct FlowChip: View {
    let text: String
    var on = false
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(on ? AppBrand.ink : AppBrand.foreground)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(on ? AppBrand.signal : AppBrand.raisedSurface))
            .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
    }
}

struct PhotoThumbnail: View {
    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo?
    var side: CGFloat = 120
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(AppBrand.raisedSurface)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipped()
            // Clear first: the list reuses these views as it scrolls, and a
            // tile that kept the previous photo while loading showed one
            // visit's food under another visit's date.
            .task(id: photo.map { "\($0.id)/\(library.rotation(of: $0))" }) {
                image = nil
                guard let photo else { return }
                image = await library.thumbnail(for: photo, side: side)
            }
    }
}

/// The visit whose flow is on screen, for the header's "지도에서".
private struct FlowVisitIDKey: EnvironmentKey { static let defaultValue: Visit.ID? = nil }
extension EnvironmentValues {
    var flowVisitID: Visit.ID? {
        get { self[FlowVisitIDKey.self] }
        set { self[FlowVisitIDKey.self] = newValue }
    }
    /// The step is open alone, as a sheet over a feed card: its button
    /// finishes the correction rather than going on to the next step.
    var oneStepSheet: Bool {
        get { self[OneStepSheetKey.self] }
        set { self[OneStepSheetKey.self] = newValue }
    }
}
private struct OneStepSheetKey: EnvironmentKey { static let defaultValue = false }
