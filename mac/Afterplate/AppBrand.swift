import SwiftUI

/// Shared visual language with the author's other apps: near-black ink, one
/// signal yellow, one violet state colour. Values are copied from a sibling
/// app's
/// AppBrand so the apps read as a family.
enum AppBrand {
    static let ink = Color(red: 0.025, green: 0.028, blue: 0.038)
    static let surface = Color(red: 0.065, green: 0.069, blue: 0.086)
    static let raisedSurface = Color(red: 0.095, green: 0.10, blue: 0.12)
    static let signal = Color(red: 0.91, green: 1.0, blue: 0.12)
    static let violet = Color(red: 0.48, green: 0.20, blue: 1.0)
    static let foreground = Color.white
    static let muted = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.34)
    static let line = Color.white.opacity(0.11)

    static let accent = signal
    static let accentSoft = signal.opacity(0.12)
}

struct BrandBackdrop: View {
    var routeOpacity = 0.16
    var showsRoute = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppBrand.ink
                GridLines().stroke(AppBrand.line, lineWidth: 0.7)
                if showsRoute {
                    SignalRoute().stroke(
                        AppBrand.signal.opacity(routeOpacity),
                        style: StrokeStyle(lineWidth: max(42, geometry.size.width * 0.14), lineCap: .butt, lineJoin: .bevel)
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = max(92, rect.width / 3.4)
        var x = spacing
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        var y = spacing
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return path
    }
}

private struct SignalRoute: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -rect.width * 0.18, y: rect.height * 0.83))
        path.addLine(to: CGPoint(x: rect.width * 0.27, y: rect.height * 0.64))
        path.addLine(to: CGPoint(x: rect.width * 0.51, y: rect.height * 0.64))
        path.addLine(to: CGPoint(x: rect.width * 0.79, y: rect.height * 0.46))
        path.addLine(to: CGPoint(x: rect.width * 1.18, y: rect.height * 0.20))
        return path
    }
}

struct BrandWordmark: View {
    var size: CGFloat = 21

    var body: some View {
        HStack(spacing: 0) {
            Text("after").foregroundStyle(AppBrand.foreground)
            Text("plate").foregroundStyle(AppBrand.signal)
        }
        .font(.system(size: size, weight: .black))
        .tracking(-1.1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Afterplate")
    }
}

struct BrandEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.black))
            .tracking(1.8)
            .foregroundStyle(AppBrand.signal)
    }
}

struct BrandPanel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppBrand.surface)
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(AppBrand.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(AppBrand.signal.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct BrandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AppBrand.foreground)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(AppBrand.raisedSurface.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppBrand.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
