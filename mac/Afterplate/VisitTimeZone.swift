import CoreLocation
import Foundation

/// The time zone a visit happened in, from where its photos were taken. A
/// breakfast abroad, nineteen hours behind, showed as 5 a.m. the next day
/// — the Mac's clock at home — instead of 10 a.m. there. Looked up once
/// per ~10km cell with Apple's geocoder and kept
/// beside memory.json; until a cell is known, the Mac's own zone is used.
enum VisitTimeZone {
    private static let url = AppData.folder.appendingPathComponent("timezones.json")
    private static var known: [String: String] = (try? Data(contentsOf: url))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

    static func key(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.1f,%.1f", coordinate.latitude, coordinate.longitude)
    }

    static func zone(at coordinate: CLLocationCoordinate2D?) -> TimeZone {
        guard let coordinate, let id = known[key(coordinate)], let zone = TimeZone(identifier: id) else { return .current }
        return zone
    }

    /// Cells not yet known, one geocoder request at a time — it throttles
    /// bursts. Returns whether anything new was learned.
    @MainActor
    static func resolve(_ coordinates: [CLLocationCoordinate2D]) async -> Bool {
        var todo: [String: CLLocationCoordinate2D] = [:]
        for c in coordinates where known[key(c)] == nil { todo[key(c)] = c }
        var learned = false
        for (cell, c) in todo {
            if Task.isCancelled { break }
            do {
                let mark = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
                if let zone = mark?.timeZone {
                    known[cell] = zone.identifier
                    learned = true
                }
            } catch {
                // Throttled or offline: the next launch tries again.
                break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        if learned, let data = try? JSONEncoder().encode(known) { try? data.write(to: url, options: .atomic) }
        return learned
    }
}
