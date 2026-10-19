import SwiftUI

/// A photo held down shows big over everything, and goes when let
/// go.
@MainActor
final class PhotoPeek: ObservableObject {
    static let shared = PhotoPeek()
    @Published var photo: Photo?
    /// The visit whose photos are open as an album, and which one is shown.
    @Published var album: (visit: Visit, index: Int)?
    /// Dragged since pressed: the press was a throw, not a click.
    var dragged = false
}

struct Peekable: ViewModifier {
    let photo: Photo
    var visit: Visit? = nil
    @State private var hold: Task<Void, Never>?
    @State private var held = false

    func body(content: Content) -> some View {
        content.onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
            hold?.cancel()
            if pressing {
                held = false
                PhotoPeek.shared.dragged = false
                // A click is not a hold.
                hold = Task {
                    try? await Task.sleep(for: .milliseconds(220))
                    if !Task.isCancelled { held = true; withAnimation(.easeOut(duration: 0.15)) { PhotoPeek.shared.photo = photo } }
                }
            } else {
                withAnimation(.easeIn(duration: 0.12)) { PhotoPeek.shared.photo = nil }
                // A click opens the visit's photos as an album.
                if !held, !PhotoPeek.shared.dragged, let visit {
                    let index = visit.photos.firstIndex { $0.id == photo.id } ?? 0
                    withAnimation(.easeOut(duration: 0.18)) { PhotoPeek.shared.album = (visit, index) }
                }
            }
        })
    }
}

extension View {
    func peekable(_ photo: Photo, in visit: Visit? = nil) -> some View { modifier(Peekable(photo: photo, visit: visit)) }
}

/// The photo being held, as big as the window allows.
struct PeekOverlay: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject private var peek = PhotoPeek.shared
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let photo = peek.photo {
                Color.black.opacity(0.6).ignoresSafeArea()
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { ProgressView() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(40)
                .task(id: photo.id) {
                    image = nil
                    image = await library.thumbnail(for: photo, side: 1600)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dragged out of its row and let go, a photo is taken out of the visit —
/// thrown off like an app off the Dock. Let go nearby,
/// it springs back. The last photo of a visit stays.
struct Throwable: ViewModifier {
    @EnvironmentObject private var library: PhotoLibrary
    let photo: Photo
    let visit: Visit
    @State private var drag: CGSize = .zero
    @State private var gone = false
    static let reach: CGFloat = 80

    private var out: Bool { hypot(drag.width, drag.height) > Self.reach }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if out {
                    Image(systemName: "minus.circle.fill").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white, Color(red: 0.85, green: 0.25, blue: 0.2))
                        .offset(x: 6, y: -6)
                }
            }
            .scaleEffect(gone ? 0.2 : out ? 0.8 : drag == .zero ? 1 : 1.06)
            .opacity(gone ? 0 : out ? 0.75 : 1)
            .offset(drag)
            .zIndex(drag == .zero ? 0 : 10)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        PhotoPeek.shared.dragged = true
                        guard visit.photos.count > 1 else { return }
                        drag = value.translation
                        PhotoPeek.shared.photo = nil
                    }
                    .onEnded { _ in
                        if out {
                            withAnimation(.easeIn(duration: 0.2)) { gone = true }
                            Task {
                                try? await Task.sleep(for: .milliseconds(200))
                                ThreadActions(library: library, visit: visit).removePhoto(photo)
                                drag = .zero
                                gone = false
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero }
                        }
                    }
            )
    }
}

extension View {
    func throwable(_ photo: Photo, from visit: Visit) -> some View { modifier(Throwable(photo: photo, visit: visit)) }
}

/// A visit's photos as the Mac's own sheet, sliding down from the window's
/// top: one large, all of them small beneath; Done or Esc closes it (the
/// overlay was too big).
struct AlbumOverlay: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject private var peek = PhotoPeek.shared

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: Binding(get: { peek.album != nil }, set: { if !$0 { peek.album = nil } })) {
                AlbumSheet().environmentObject(library)
            }
    }
}

private struct AlbumSheet: View {
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject private var peek = PhotoPeek.shared
    @State private var image: NSImage?

    var body: some View {
        if let album = peek.album {
            let photos = album.visit.photos
            let index = min(album.index, photos.count - 1)
            VStack(spacing: 14) {
                HStack {
                    Text(album.visit.fullTitle).font(.system(size: 14, weight: .semibold))
                    Text("\(index + 1) / \(photos.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("완료") { peek.album = nil }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 10) {
                    step(-1, index: index, count: photos.count, symbol: "chevron.left")
                    Group {
                        if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    step(1, index: index, count: photos.count, symbol: "chevron.right")
                }
                if photos.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                                PhotoTile(photo: photo).frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(i == index ? Color.accentColor : .clear, lineWidth: 2))
                                    .opacity(i == index ? 1 : 0.6)
                                    .onTapGesture { peek.album = (album.visit, i) }
                            }
                        }
                        .padding(2)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 62)
                }
            }
            .padding(18)
            .frame(width: 720, height: 560)
            .task(id: photos[index].id) {
                image = nil
                image = await library.thumbnail(for: photos[index], side: 1600)
            }
        }
    }

    private func step(_ by: Int, index: Int, count: Int, symbol: String) -> some View {
        let to = index + by
        return Button {
            if let album = peek.album, (0..<count).contains(to) { peek.album = (album.visit, to) }
        } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .opacity((0..<count).contains(to) ? 1 : 0.25)
        .disabled(!(0..<count).contains(to))
        .keyboardShortcut(by < 0 ? .leftArrow : .rightArrow, modifiers: [])
    }
}
