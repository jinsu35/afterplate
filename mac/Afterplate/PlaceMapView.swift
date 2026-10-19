import SwiftUI
import CoreLocation
import MapKit

/// One picture with every pin on it. The place step used to offer two links
/// that each opened a map of one point, which left the person holding the
/// other in their head — and the gap between them is the whole question they
/// were asking.
///
/// The tiles are photographed once and the pins are laid over them, so running
/// the mouse down the candidate list moves a pin on this map at the speed of
/// the mouse — redrawing the map for each row would be a new snapshot every
/// few pixels.
struct PlaceMapView: View {
    let photo: CLLocationCoordinate2D
    let accuracy: Double
    /// The place being proposed or already confirmed.
    let place: PlaceCandidate?
    /// Everything else nearby, drawn small.
    var others: [PlaceCandidate] = []
    /// The row the mouse is on, if any.
    var highlighted: String? = nil

    private static let size = CGSize(width: 520, height: 300)

    @State private var shot: MKMapSnapshotter.Snapshot?
    @State private var pins: [String: CLLocationCoordinate2D] = [:]
    @State private var failed = false

    private func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let shot else { return nil }
        let raw = shot.point(for: coordinate)
        // MapKit measures from the bottom left on this platform; SwiftUI from
        // the top left.
        let flipped = CGPoint(x: raw.x, y: Self.size.height - raw.y)
        guard flipped.x > -40, flipped.x < Self.size.width + 40,
              flipped.y > -40, flipped.y < Self.size.height + 40 else { return nil }
        return flipped
    }

    private func spot(_ candidate: PlaceCandidate) -> CLLocationCoordinate2D? {
        candidate.coordinate ?? pins[candidate.id]
    }

    private var shownPlace: CLLocationCoordinate2D? { place.flatMap(spot) }

    private var metres: Int? {
        guard let there = shownPlace else { return nil }
        return Int(CLLocation(latitude: photo.latitude, longitude: photo.longitude)
            .distance(from: CLLocation(latitude: there.latitude, longitude: there.longitude)).rounded())
    }

    /// Google's page for whichever place the map is naming — the one under
    /// the mouse, or the one being proposed. Google's URL scheme carries a
    /// single marker, and where the photo was taken is already on this map,
    /// so the link is for what Google has and this map does not: the
    /// reviews, the photos, the hours.
    private var namedInGoogle: URL? {
        let target = highlighted.flatMap { id in others.first { $0.id == id } } ?? place
        guard let id = target?.googlePlaceID else { return nil }
        return URL(string: "https://www.google.com/maps/place/?q=place_id:\(id)")
    }

    /// What the mouse is on, or failing that what the app is proposing.
    private var caption: (name: String, metres: Int)? {
        if let id = highlighted, let one = others.first(where: { $0.id == id }) {
            return (PlaceNames.shown(one.name), Int(one.distance.rounded()))
        }
        guard let place, let metres else { return nil }
        return (PlaceNames.shown(place.name), metres)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let shot {
                let picture = ZStack(alignment: .topLeading) {
                    Image(nsImage: shot.image).resizable().frame(width: Self.size.width, height: Self.size.height)
                    if let here = point(photo) {
                        ring.position(here)
                        dot(.blue, big: true).position(here)
                    }
                    ForEach(others.filter { $0.id != place?.id }, id: \.id) { candidate in
                        if let spot = spot(candidate), let at = point(spot) {
                            dot(candidate.id == highlighted ? .orange : .secondary,
                                big: candidate.id == highlighted).position(at)
                        }
                    }
                    if let there = shownPlace, let at = point(there) {
                        dot(.red, big: true).position(at)
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))

                if let namedInGoogle {
                    Link(destination: namedInGoogle) { picture }.buttonStyle(.plain)
                        .help("구글 지도에서 \(caption?.name ?? "이 가게") 열기")
                } else {
                    picture
                }

                HStack(spacing: 12) {
                    Label { Text("사진 찍힌 자리") } icon: { Circle().fill(.blue).frame(width: 9, height: 9) }
                    if let caption {
                        Label { Text(caption.name).lineLimit(1) } icon: {
                            Circle().fill(highlighted == nil ? Color.red : .orange).frame(width: 9, height: 9)
                        }
                        Text("\(caption.metres)m · 오차 ±\(Int(accuracy))m")
                            .foregroundStyle(accuracy >= Double(caption.metres) ? .orange : .secondary)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: Self.size.width, alignment: .leading)

                // The one line worth saying out loud: inside the circle,
                // being a few metres nearer decided nothing.
                if let caption, accuracy >= Double(caption.metres) {
                    Text("오차 범위 안이에요 — 거리로는 옆집과 구별이 안 되는 자리")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            } else if !failed {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        // Keyed on the pins, never on the mouse: hovering must not cost a
        // new photograph of the map.
        .task(id: mapKey) { await draw() }
        // A place confirmed before candidates kept their coordinate has none
        // to plot. Asked for one at a time, only for the row being looked at.
        .task(id: highlighted ?? "") { await fetchMissingPin() }
    }

    private var mapKey: String {
        let known = ([place].compactMap { $0 } + others).compactMap { spot($0) }
            .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.sorted().joined(separator: ";")
        return String(format: "%.5f,%.5f,%.0f|", photo.latitude, photo.longitude, accuracy) + known
    }

    private func fetchMissingPin() async {
        var wanted: [PlaceCandidate] = []
        if let place, spot(place) == nil { wanted.append(place) }
        if let id = highlighted, let one = others.first(where: { $0.id == id }), spot(one) == nil { wanted.append(one) }
        for candidate in wanted {
            guard let id = candidate.googlePlaceID, let found = await PlaceLookup.pin(for: id) else { continue }
            pins[candidate.id] = found
        }
    }

    private var ring: some View {
        let radius = max(accuracy, 15)
        let metresPerPoint = spanMetres / Self.size.height
        let size = radius * 2 / metresPerPoint
        return Circle().fill(Color.blue.opacity(0.13))
            .overlay(Circle().stroke(Color.blue.opacity(0.5), lineWidth: 1.5))
            .frame(width: size, height: size)
    }

    /// Everything that has to fit: the phone's circle and every pin.
    private var spanMetres: Double {
        let hub = CLLocation(latitude: photo.latitude, longitude: photo.longitude)
        let far = ([place].compactMap { $0 } + others).compactMap { spot($0) }
            .map { hub.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.max() ?? 0
        return max(max(accuracy, 15) * 3, far * 2.4, 90)
    }

    private func dot(_ colour: Color, big: Bool) -> some View {
        Circle().fill(colour)
            .frame(width: big ? 13 : 8, height: big ? 13 : 8)
            .overlay(Circle().stroke(.white, lineWidth: big ? 2.5 : 1.5))
            .shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    private func draw() async {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: photo,
                                            latitudinalMeters: spanMetres, longitudinalMeters: spanMetres)
        options.size = Self.size
        options.showsBuildings = true
        options.pointOfInterestFilter = .includingAll
        let started = Date()
        guard let taken = try? await MKMapSnapshotter(options: options).start() else {
            Usage.failed(tag: "지도", model: "mapkit", reason: "snapshot",
                         seconds: Date().timeIntervalSince(started))
            failed = true
            return
        }
        Usage.local(tag: "지도", detail: "mapkit", seconds: Date().timeIntervalSince(started))
        shot = taken
    }
}
