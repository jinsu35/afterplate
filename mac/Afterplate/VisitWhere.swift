import CoreLocation
import MapKit
import SwiftUI

/// The city a visit happened in, named in the app's language. Looked up
/// once per ~5km cell with Apple's geocoder (free, throttled in bursts) and
/// kept beside memory.json, like the time zones.
enum VisitCity {
    private static let url = AppData.folder.appendingPathComponent("cities.json")
    private static var known: [String: String] = (try? Data(contentsOf: url))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        let language = AppLanguage.current.isEnglish ? "en" : "ko"
        return String(format: "%@/%.2f,%.2f", language, (c.latitude * 20).rounded() / 20, (c.longitude * 20).rounded() / 20)
    }

    static func known(at c: CLLocationCoordinate2D) -> String? { known[key(c)] }

    @MainActor
    static func name(at c: CLLocationCoordinate2D) async -> String? {
        if let name = known[key(c)] { return name }
        let locale = Locale(identifier: AppLanguage.current.isEnglish ? "en_US" : "ko_KR")
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude), preferredLocale: locale).first
        else { return nil }
        let city = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea
        let name = [city, mark.country].compactMap { $0 }.joined(separator: ", ")
        guard !name.isEmpty else { return nil }
        known[key(c)] = name
        if let data = try? JSONEncoder().encode(known) { try? data.write(to: url, options: .atomic) }
        return name
    }
}

/// Where a visit was: the city, beside the date, and a press away from a
/// map of the spot.
struct VisitWhereButton: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    var size: CGFloat = 14
    @State private var city: String?
    @State private var open = false

    /// The restaurant's pin once it is chosen, else where the photos were.
    private var spot: CLLocationCoordinate2D? {
        if let place = library.confirmedPlace(for: visit.id), let lat = place.latitude, let lon = place.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return visit.coordinate
    }

    var body: some View {
        if let spot {
            Button { open = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: size - 1, weight: .semibold))
                    Text(city ?? String(localized: "지도")).font(.system(size: size, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(AppBrand.foreground)
                .padding(.horizontal, 10).frame(height: size + 14)
                .background(Capsule().fill(AppBrand.surface))
                .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plainHit)
            .help(Text("지도에서 보기"))
            .task(id: visit.id) {
                city = VisitCity.known(at: spot)
                if city == nil { city = await VisitCity.name(at: spot) }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VisitMap(spot: spot, name: library.confirmedPlaces[visit.id].map { PlaceNames.shown($0.name) }, city: city)
            }
        }
    }
}

private struct VisitMap: View {
    let spot: CLLocationCoordinate2D
    let name: String?
    let city: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Map(initialPosition: .region(MKCoordinateRegion(center: spot, latitudinalMeters: 900, longitudinalMeters: 900))) {
                Marker(name ?? city ?? "", coordinate: spot)
            }
            .frame(width: 420, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Text([name, city].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("지도 앱에서 열기") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: spot))
                    item.name = name
                    item.openInMaps()
                }
            }
        }
        .padding(12)
    }
}
