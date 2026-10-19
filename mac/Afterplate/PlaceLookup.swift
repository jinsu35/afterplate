import Foundation
import MapKit
import CoreLocation

/// A place that could be the restaurant a visit happened at.
struct PlaceCandidate: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let address: String?
    let category: String?
    /// Metres from the visit's coordinate. Photos are taken inside the
    /// restaurant, so the nearest food place is usually the right one.
    let distance: CLLocationDistance
    /// Google's own identifier, present only on Google candidates. It is what
    /// makes the review composer reachable without the user searching for the
    /// place by hand.
    let googlePlaceID: String?
    /// Photographs on the listing, and how many different people took them.
    /// A place people actually go to accumulates both; a listing nobody has
    /// been to has neither.
    var photos: Int = 0
    var photographers: Int = 0
    /// Not OPERATIONAL — closed for good or for now.
    var shut: Bool = false
    /// Where Google puts its pin. Received all along and thrown away once the
    /// metres were computed — but the metres are the disputed number, and the
    /// two points are what settles it.
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// Nobody has ever photographed it. Kept in the list, never led with:
    /// it is not where the meal was, and a review posted there would be the
    /// only thing on the page.
    var unvisited: Bool { photos == 0 }

    /// Written by hand because Swift's synthesized decoder ignores default
    /// values: a field added here is a field missing from every candidate
    /// already on disk, and one that throws takes the whole of memory.json
    /// with it. That is what happened once — photos/photographers/shut were
    /// added, every stored place failed to decode, memory came up
    /// empty and the next save wrote the empty over the real thing.
    init(id: String, name: String, address: String?, category: String?,
         distance: CLLocationDistance, googlePlaceID: String?,
         photos: Int = 0, photographers: Int = 0, shut: Bool = false,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.name = name; self.address = address; self.category = category
        self.distance = distance; self.googlePlaceID = googlePlaceID
        self.photos = photos; self.photographers = photographers; self.shut = shut
        self.latitude = latitude; self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        distance = try c.decodeIfPresent(CLLocationDistance.self, forKey: .distance) ?? -1
        googlePlaceID = try c.decodeIfPresent(String.self, forKey: .googlePlaceID)
        photos = try c.decodeIfPresent(Int.self, forKey: .photos) ?? 0
        photographers = try c.decodeIfPresent(Int.self, forKey: .photographers) ?? 0
        shut = try c.decodeIfPresent(Bool.self, forKey: .shut) ?? false
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Which building this place is in, as Google writes the address — road
    /// name and number, everything else dropped. Google pins every unit of a
    /// building to one point, so nine shops in one building's arcade all
    /// measured 8m from a table at one visit while a tenth, at the same
    /// address but pinned elsewhere, measured 48m. Between places that
    /// share a building, metres say nothing.
    var building: String? {
        guard let address else { return nil }
        let cleaned = address
            .replacingOccurrences(of: "대한민국", with: " ")
            .replacingOccurrences(of: "KR", with: " ")
            .replacingOccurrences(of: "서울특별시", with: " ")
            .replacingOccurrences(of: "번지", with: " ")
        // "110 세종대로 중구" and "중구 세종대로 110 ○○빌딩…" are the
        // same address written two ways: keep the road word and the number
        // next to it, in a fixed order.
        let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        // A road name first ("세종대로 110"); the old 동 form only when
        // there is no road, or "중구 태평로1가 세종대로 110" would key on 태평로1가,
        // which
        // has no number beside it, and the address would go unmatched.
        func number(beside index: Int) -> String? {
            [index + 1, index - 1].filter { words.indices.contains($0) }.compactMap { at -> String? in
                let head = words[at].prefix { $0.isNumber || $0 == "-" }
                return head.isEmpty ? nil : String(head)
            }.first
        }
        for suffixes in [["로", "길"], ["동"]] {
            for (index, word) in words.enumerated() where suffixes.contains(where: { word.hasSuffix($0) }) {
                if let number = number(beside: index) { return word + " " + number }
            }
        }
        return nil
    }

    var distanceLabel: String {
        if distance < 0 { return "" }   // found by name, no photo position to measure from
        return distance < 1000 ? "\(Int(distance.rounded()))m" : String(format: "%.1fkm", distance / 1000)
    }

    /// Google's "write a review" form for this exact place. The app's last
    /// step is a human posting a review, so identifying the place in Google's
    /// own namespace lets us open the right form instead of the user hunting
    /// for it. MapKit candidates carry no Google id and so have no link.
    var reviewURL: URL? { reviewURL(language: nil) }

    /// `language` ("ko"/"en") opens the composer in the language of the text
    /// being posted; nil leaves it to the Google account. The fill script
    /// reads no labels, so either works.
    /// With `account` (an email; a bare name is taken as @gmail.com) the form
    /// is reached through Google's account chooser, which switches a browser
    /// signed in to several accounts to that one and then continues to the
    /// form — `authuser` alone did not survive the writereview redirect.
    func reviewURL(language: String?, account: String? = nil) -> URL? {
        guard let id = googlePlaceID else { return nil }
        var components = URLComponents(string: "https://search.google.com/local/writereview")!
        var items = [URLQueryItem(name: "placeid", value: id)]
        if let language { items.append(URLQueryItem(name: "hl", value: language)) }
        let email = account.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : ($0.contains("@") ? $0 : $0 + "@gmail.com") }
        if let email { items.append(URLQueryItem(name: "authuser", value: email)) }
        components.queryItems = items
        guard let form = components.url else { return nil }
        guard let email else { return form }
        var chooser = URLComponents(string: "https://accounts.google.com/AccountChooser")!
        chooser.queryItems = [URLQueryItem(name: "Email", value: email), URLQueryItem(name: "continue", value: form.absoluteString)]
        return chooser.url
    }
}

/// Restaurant identification from coordinates alone — the first-choice
/// evidence in the extraction design, because it costs nothing and needs no
/// photo to leave the machine.
///
/// Two providers. Google Places is used when an API key is configured, for two
/// reasons. Coverage: Apple's POI data in Korea is thin, measured in central
/// Seoul as one food place within 150m and four within 500m of a block that
/// has dozens, and zero within 300m of a photo from a busy district.
/// Namespace: the
/// review this app drafts is posted to Google, so a place Google does not know
/// is a place the user cannot review anyway, and a place Google does know comes
/// with the id that opens its review form.
///
/// MapKit is the keyless fallback and is accurate outside Korea, measured at
/// 6-79m on real photos from several countries.
///
/// Google is Afterplate's to provide: the app calls it
/// through Afterplate's proxy (`PlacesProxy`), which holds the Maps
/// key. A key of one's own, for development, goes straight to Google:
/// `defaults write com.jinsukim.afterplate GoogleMapsAPIKey <key>`
/// (a Maps Platform key with the Places API enabled; only the coordinate is
/// sent).
/// Afterplate's Google Places proxy (a Cloudflare Worker, kept out of the
/// public source). The device registers once for a signed token — no account, no
/// personal data — and the proxy counts each device's and the whole day's
/// spend against its ceilings.
enum PlacesProxy {
    /// The deployed proxy; `PlacesProxyURL` in defaults overrides it (a
    /// local `wrangler dev`, for one).
    private static let deployed: String? = "https://afterplate-proxy.jinsukim.workers.dev"
    static var base: URL? {
        (UserDefaults.standard.string(forKey: "PlacesProxyURL") ?? deployed).flatMap(URL.init(string:))
    }

    /// A new person's test window is a Mac of its own to the proxy, with its
    /// own share.
    private static let tokenKey = AppData.apart("PlacesProxyToken")
    private static let deviceKey = AppData.apart("PlacesProxyDevice")
    nonisolated(unsafe) private static var held: String? = UserDefaults.standard.string(forKey: tokenKey)

    static func token() async -> String? {
        if let held { return held }
        guard let base, let url = URL(string: base.absoluteString + "/v1/device") else { return nil }
        let defaults = UserDefaults.standard
        let device = defaults.string(forKey: deviceKey) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: deviceKey)
            return new
        }()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceId": device])
        request.timeoutInterval = 20
        struct Answer: Decodable { let token: String }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let token = (try? JSONDecoder().decode(Answer.self, from: data))?.token else {
            print("[PlacesProxy] could not register this device")
            return nil
        }
        held = token
        defaults.set(token, forKey: tokenKey)
        return token
    }

    /// This Mac's place searches this week, how many it may make, and when
    /// the share comes back.
    static func allowance() async -> (used: Int, limit: Int, resets: Date?)? {
        struct Answer: Decodable { let used: Int; let limit: Int; let resets: String? }
        guard let data = await send("/v1/places/allowance", body: nil),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        return (answer.used, answer.limit, answer.resets.flatMap { ISO8601DateFormatter.withFraction.date(from: $0) })
    }

    private static func send(_ path: String, body: [String: Any]?) async -> Data? {
        guard let base, let url = URL(string: base.absoluteString + path), let token = await token() else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { forget() }
        return status == 200 ? data : nil
    }

    /// The proxy no longer takes the token (expired, or its secret changed):
    /// register again on the next call.
    static func forget() {
        held = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}

extension ISO8601DateFormatter {
    /// "2026-10-19T00:00:00.000Z", as JavaScript's toISOString writes it.
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum PlaceLookup {
    /// GPS in a building is typically off by 20-50m, so a tight radius would
    /// miss the actual restaurant; a wide one buries it in neighbours. Google
    /// is dense enough for the tight radius; MapKit needs a wider net.
    /// 80m: photo GPS has landed 6–79m from the actual place on verified
    /// visits abroad. 150m pulled in 82 places in one dense neighbourhood,
    /// which was too wide; anything under the observed error would drop real
    /// visits. 150m, not 80. Google returns the 20 nearest whatever the
    /// radius, so in a busy block this changes nothing — the same twenty come
    /// back. It only matters where there are fewer than twenty: one visit's
    /// photos read
    /// 100m from the restaurant they were taken in (a phone indoors falls back
    /// to Wi-Fi and cell), and at 80m the right answer was not in the list at
    /// all. Of 40 places confirmed so far, 3 sit beyond 80m and 2 beyond 150m
    /// — and those two are a 513m walk and a photo with a wild reading.
    static let googleRadius: CLLocationDistance = 150
    static let mapKitRadius: CLLocationDistance = 300
    /// Rows shown before the list is cut; the full set is kept for the
    /// extraction step to choose from.
    static let shownCandidates = 10

    static var searchRadius: CLLocationDistance { googleAvailable ? googleRadius : mapKitRadius }

    /// Where Google's pin is, for a place confirmed before the app started
    /// keeping the coordinate. Details asking for `location` alone is the
    /// cheapest thing Google sells — and it is asked once per place, then
    /// kept next to the drawn maps, so no visit pays for it twice.
    private static let pointsFile: URL? = {
        AppData.folder.appendingPathComponent("maps/pins.json")
    }()
    private static var points: [String: [Double]] = {
        guard let pointsFile, let data = try? Data(contentsOf: pointsFile),
              let kept = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return kept
    }()

    static func pin(for placeID: String) async -> CLLocationCoordinate2D? {
        if let kept = points[placeID], kept.count == 2 {
            return CLLocationCoordinate2D(latitude: kept[0], longitude: kept[1])
        }
        guard let request = await googleRequest("/v1/places/\(placeID)", fieldMask: "location") else { return nil }
        let started = Date()
        struct Answer: Decodable { struct Point: Decodable { let latitude: Double; let longitude: Double }
                                   let location: Point? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let point = (try? JSONDecoder().decode(Answer.self, from: data))?.location else {
            Usage.failed(tag: "가게 좌표", model: "places-essentials", reason: "no location",
                         seconds: Date().timeIntervalSince(started))
            return nil
        }
        Usage.local(tag: "가게 좌표", detail: placeID, seconds: Date().timeIntervalSince(started))
        points[placeID] = [point.latitude, point.longitude]
        if let pointsFile, let data = try? JSONEncoder().encode(points) { try? data.write(to: pointsFile) }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    /// One's own key (Settings, else defaults or the environment): straight
    /// to Google on that key's own free calls, no share to run out of.
    static var googleKey: String? {
        let key = Keys.get(.google) ?? UserDefaults.standard.string(forKey: "GoogleMapsAPIKey")
            ?? ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"]
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    static var googleAvailable: Bool { googleKey != nil || PlacesProxy.base != nil }

    /// A request to Google Places at `path` ("/v1/places:searchNearby"): on
    /// one's own key straight to Google, otherwise through the proxy. nil
    /// when neither is there (MapKit then).
    private static func googleRequest(_ path: String, fieldMask: String) async -> URLRequest? {
        var request: URLRequest
        if let key = googleKey, let url = URL(string: "https://places.googleapis.com" + path) {
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        } else if let base = PlacesProxy.base, let token = await PlacesProxy.token(),
                  let url = URL(string: base.absoluteString + "/v1/google" + path) {
            request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            return nil
        }
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        return request
    }

    /// Why Google last said no more searches: this Mac's share for the week
    /// on the proxy, or a daily stop (the proxy's, or one's own key's quota).
    /// A visit then showed only the name search, which was refused too, with
    /// no word why.
    enum Limit: Equatable { case day, week(until: Date) }
    nonisolated(unsafe) private static var limitedAt: (Limit, Date)?
    static var limited: Limit? {
        guard let (limit, at) = limitedAt else { return nil }
        switch limit {
        case .day: return Calendar.current.isDateInToday(at) ? limit : nil
        case .week(let until): return Date() < until ? limit : nil
        }
    }
    private static func noteLimit(_ status: Int, _ data: Data) {
        if status == 429 {
            struct Share: Decodable { let resets: String? }
            let resets = googleKey == nil
                ? (try? JSONDecoder().decode(Share.self, from: data))?.resets.flatMap { ISO8601DateFormatter.withFraction.date(from: $0) }
                : nil
            limitedAt = (resets.map { .week(until: $0) } ?? .day, Date())
        } else if status == 200 {
            limitedAt = nil
        }
    }

    /// `settled` says whether the answer came from a provider that actually
    /// replied, so a caller can remember it. A network failure or a rejected
    /// key still yields candidates (MapKit's) but must not be cached as the
    /// truth about that spot.
    ///
    /// When Google does not answer, nothing is offered in its place: Apple's
    /// places carry no Google listing, so a visit matched to one could get
    /// neither a menu nor a review link — out of searches, the app went on to
    /// the next visit with a bakery from Apple and "couldn't find a menu".
    /// The visit says why and offers a retry.
    static func candidates(near coordinate: CLLocationCoordinate2D) async -> (candidates: [PlaceCandidate], settled: Bool) {
        if googleAvailable {
            guard let found = await googleCandidates(near: coordinate) else { return ([], false) }
            if !found.isEmpty { return (found, true) }
            return (await mapKitCandidates(near: coordinate), true)
        }
        let found = await mapKitCandidates(near: coordinate)
        return (found, !found.isEmpty)
    }

    // MARK: - Google Places

    /// Nearby Search (New): POST with the key and a field mask in headers.
    /// https://developers.google.com/maps/documentation/places/web-service/nearby-search
    private static let nearbyPath = "/v1/places:searchNearby"

    /// photos and businessStatus ride along in the tier already paid for.
    /// Ratings would say the same thing more directly but sit in Google's
    /// Enterprise tier ($40 per 1,000 against $32), and the photographs
    /// separate the same places just as cleanly: on one beach block, the
    /// real restaurant had 10 photos from 9 people and the café the app
    /// offered over it had none from nobody.
    private static let googleFieldMask = [
        "places.id",
        "places.displayName",
        "places.shortFormattedAddress",
        "places.formattedAddress",
        "places.location",
        "places.primaryTypeDisplayName",
        "places.types",
        "places.photos",
        "places.businessStatus",
    ].joined(separator: ",")

    /// Nearby Search returns at most 20 places per call. One call with all
    /// food types found the 20 nearest of 71 food places within 150m of one
    /// visit and silently dropped the other 51, the nearest at 30m — inside
    /// the GPS error of a photo taken indoors. So: one call per type group
    /// (each under the cap in practice), then a union. The cap itself is not
    /// configurable — maxResultCount tops out at 20 and Nearby Search has no
    /// paging — so the only lever is asking more, narrower questions. An
    /// untyped fifth call was tried and dropped: it surfaced a
    /// designated-driver service and a shutter shop above the restaurants,
    /// and a place with no type gives the extraction step nothing to match
    /// food against. One page with every food type, nearest first. A Nearby
    /// Search costs the same whatever it asks for, so the old
    /// four-groups-plus-four-tiles fan-out billed six to eight requests per
    /// visit ($0.13–0.26) where one usually does: on 18 confirmed places,
    /// this single
    /// page already contained 16.
    private static let allFoodTypes = ["restaurant", "cafe", "bar", "bakery", "meal_takeaway", "ice_cream_shop"]

    /// When that page comes back full the block holds more than 20 food
    /// places, so one more page reaches deeper among restaurants alone. Two
    /// requests at most: the drink-side page and the four restaurant
    /// pages from 80m out made a city visit cost five or six requests,
    /// and Google's free calls a month cover every user at once.
    /// Replayed over 140 confirmed places with a nearby list, the first
    /// page holds 129 and the restaurant page 7 more; the 4 beyond (one
    /// at 64m, 39th
    /// nearest of 92) are found by name instead.
    private static let denseFollowUp = ["restaurant"]

    /// Google localises place names: asked in the app's language, not the
    /// Mac's. On an English-language Mac the system locale produced
    /// a romanised name for a Korean 설렁탕 place in the Korean app, and the
    /// English app named an American restaurant in Hangul.
    static var languageCode: String { AppLanguage.current.isEnglish ? "en" : "ko" }

    private struct GoogleResponse: Decodable {
        struct LocalizedText: Decodable { let text: String }
        struct LatLng: Decodable { let latitude: Double; let longitude: Double }
        struct Review: Decodable { let text: LocalizedText? }
        struct Place: Decodable {
            let id: String
            let displayName: LocalizedText?
            let shortFormattedAddress: String?
            let formattedAddress: String?
            let location: LatLng?
            let primaryTypeDisplayName: LocalizedText?
            let types: [String]?
            struct Photo: Decodable {
                struct Author: Decodable { let displayName: String? }
                let authorAttributions: [Author]?
            }
            let photos: [Photo]?
            let businessStatus: String?
            let reviews: [Review]?
            let editorialSummary: LocalizedText?
        }
        let places: [Place]?
    }

    /// nil means Google did not answer; [] means it answered "nothing here".
    /// One page of every food type, then — only if it is full — one of
    /// restaurants. Any call
    /// failing makes the whole answer nil so a partial list is never cached
    /// as the truth about that spot.
    private static func googleCandidates(
        near coordinate: CLLocationCoordinate2D
    ) async -> [PlaceCandidate]? {
        guard let centrePages = await pages(for: [(allFoodTypes, coordinate, googleRadius)]) else { return nil }

        var tilePages: [[GoogleResponse.Place]] = []
        if centrePages[0].count == 20 {
            guard let fetched = await pages(for: [(denseFollowUp, coordinate, googleRadius)]) else { return nil }
            tilePages = fetched
        }

        var merged: [String: GoogleResponse.Place] = [:]
        for page in centrePages + tilePages {
            for place in page { merged[place.id] = merged[place.id] ?? place }
        }

        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Printed on success too, so a log can prove which provider answered
        // for a visit: the fallback would otherwise be indistinguishable.
        let counts = { (pages: [[GoogleResponse.Place]]) in pages.map { String($0.count) }.joined(separator: "/") }
        print(String(format: "[PlaceLookup] Google Places: %d places within %.0fm of %.5f,%.5f (centre %@%@)",
                     merged.count, googleRadius, coordinate.latitude, coordinate.longitude,
                     counts(centrePages), tilePages.isEmpty ? "" : ", tiles " + counts(tilePages)))
        return merged.values
            .compactMap { place -> PlaceCandidate? in
                guard let name = place.displayName?.text, !name.isEmpty,
                      let point = place.location else { return nil }
                // The API returns a bare id; tolerate the "places/<id>"
                // resource-name form in case a field mask ever yields it,
                // because the review link is wrong with the prefix attached.
                let placeID = place.id.hasPrefix("places/")
                    ? String(place.id.dropFirst("places/".count))
                    : place.id
                let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
                return PlaceCandidate(
                    id: "google:\(placeID)",
                    name: name,
                    address: place.shortFormattedAddress ?? place.formattedAddress,
                    category: place.primaryTypeDisplayName?.text,
                    distance: here.distance(from: origin),
                    googlePlaceID: placeID,
                    photos: place.photos?.count ?? 0,
                    photographers: Set((place.photos ?? []).flatMap { ($0.authorAttributions ?? []).compactMap(\.displayName) }).count,
                    shut: place.businessStatus != nil && place.businessStatus != "OPERATIONAL",
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            }
            .sorted { $0.distance < $1.distance }
    }

    /// Google Maps search by name, for the visit whose photos were not taken
    /// at the restaurant — takeout eaten at home, a photo the next day. Biased
    /// towards the photos' position when there is one, else Korea-wide.
    static func searchText(_ query: String, near coordinate: CLLocationCoordinate2D?) async -> [PlaceCandidate] {
        let near = await searchText(query, near: coordinate, widened: false)
        if !near.isEmpty || coordinate == nil { return near }
        return await searchText(query, near: coordinate, widened: true)
    }

    private static func searchText(_ query: String, near coordinate: CLLocationCoordinate2D?, widened: Bool) async -> [PlaceCandidate] {
        guard var request = await googleRequest("/v1/places:searchText", fieldMask: googleFieldMask) else { return [] }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "textQuery": query,
            "languageCode": languageCode,
            "regionCode": "KR",
            "pageSize": 10,
        ]
        // The neighbourhood first, nearest first: with only a 20km bias,
        // "카레" or "돈까스" ranked by relevance across the city and the
        // place next door never showed. Widened to the bias
        // only when the neighbourhood has nothing.
        if let coordinate, !widened {
            let dLat = 1000.0 / 111_320
            let dLng = 1000.0 / (111_320 * cos(coordinate.latitude * .pi / 180))
            body["locationRestriction"] = ["rectangle": [
                "low": ["latitude": coordinate.latitude - dLat, "longitude": coordinate.longitude - dLng],
                "high": ["latitude": coordinate.latitude + dLat, "longitude": coordinate.longitude + dLng],
            ]]
            body["rankPreference"] = "DISTANCE"
        } else if let coordinate {
            body["locationBias"] = ["circle": ["center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude], "radius": 20_000]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let answer = try? await URLSession.shared.data(for: request)
        Usage.google(tag: "text-search", requests: 1, seconds: -started.timeIntervalSinceNow)
        guard let (data, response) = answer else {
            print("[PlaceLookup] text search unreachable"); return []
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        noteLimit(status, data)
        guard status == 200, let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data) else {
            print("[PlaceLookup] text search HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"); return []
        }
        let origin = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let found = (decoded.places ?? []).compactMap { place -> PlaceCandidate? in
            guard let name = place.displayName?.text, !name.isEmpty else { return nil }
            let placeID = place.id.hasPrefix("places/") ? String(place.id.dropFirst("places/".count)) : place.id
            let distance: CLLocationDistance
            if let origin, let point = place.location {
                distance = CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: origin)
            } else { distance = -1 }
            // The full address: a place found by name can be in another city,
            // and the short form ("중구 대종로…") drops the city.
            let full = place.formattedAddress.map { $0.replacingOccurrences(of: "대한민국 ", with: "") }
            return PlaceCandidate(id: "google:\(placeID)", name: name, address: full ?? place.shortFormattedAddress,
                                  category: place.primaryTypeDisplayName?.text, distance: distance, googlePlaceID: placeID,
                                  photos: place.photos?.count ?? 0,
                                  photographers: Set((place.photos ?? []).flatMap { ($0.authorAttributions ?? []).compactMap(\.displayName) }).count,
                                  shut: place.businessStatus != nil && place.businessStatus != "OPERATIONAL",
                                  latitude: place.location?.latitude, longitude: place.location?.longitude)
        }
        print("[PlaceLookup] text search '\(query)': \(found.count) places")
        // Nearest first, distance on every row (the row shows it).
        return found.sorted { ($0.distance < 0 ? .infinity : $0.distance) < ($1.distance < 0 ? .infinity : $1.distance) }
    }

    /// Runs the queries in parallel; nil if any of them failed.
    private static func pages(
        for queries: [(types: [String], centre: CLLocationCoordinate2D, radius: CLLocationDistance)]
    ) async -> [[GoogleResponse.Place]]? {
        let results: [[GoogleResponse.Place]?] = await withTaskGroup(of: (Int, [GoogleResponse.Place]?).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    (index, await googlePage(near: query.centre, radius: query.radius, types: query.types))
                }
            }
            var ordered = [[GoogleResponse.Place]?](repeating: nil, count: queries.count)
            for await (index, page) in group { ordered[index] = page }
            return ordered
        }
        guard results.allSatisfy({ $0 != nil }) else { return nil }
        return results.map { $0 ?? [] }
    }

    /// What people wrote about each place nearby, by place id. A second
    /// Nearby Search with the review fields, which Google bills at its
    /// dearest tier ($40/1,000 against $32, and only 1,000 free a month
    /// against 5,000) — so this runs only when the kinds alone cannot tell
    /// two candidates apart. Reviews name the dish: a soba shop 21m away
    /// was "음식점" like everything else until its reviews mentioned
    /// 오키나와 소바 and チャンプルー.
    static func reviews(near coordinate: CLLocationCoordinate2D) async -> [String: String] {
        guard var request = await googleRequest(nearbyPath, fieldMask: "places.id,places.reviews,places.editorialSummary") else { return [:] }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "includedTypes": allFoodTypes,
            "maxResultCount": 20,
            "rankPreference": "DISTANCE",
            "languageCode": languageCode,
            "locationRestriction": ["circle": [
                "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                "radius": googleRadius,
            ]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let started = Date()
        let answer = try? await URLSession.shared.data(for: request)
        Usage.google(tag: "reviews", requests: 1, enterprise: true, seconds: -started.timeIntervalSinceNow)
        guard let (data, response) = answer,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data) else {
            print("[PlaceLookup] reviews unavailable")
            return [:]
        }
        var byPlace: [String: String] = [:]
        for place in decoded.places ?? [] {
            let id = place.id.hasPrefix("places/") ? String(place.id.dropFirst("places/".count)) : place.id
            var parts: [String] = []
            if let summary = place.editorialSummary?.text, !summary.isEmpty { parts.append(summary) }
            parts += (place.reviews ?? []).compactMap { $0.text?.text }
            let joined = parts.joined(separator: " / ").replacingOccurrences(of: "\n", with: " ")
            if !joined.isEmpty { byPlace[id] = String(joined.prefix(500)) }
        }
        print("[PlaceLookup] reviews: \(byPlace.count) places have text")
        return byPlace
    }

    /// One Nearby Search page: up to 20 places of the given types (all types
    /// when nil), nearest first. nil on any failure.
    private static func googlePage(
        near coordinate: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        types: [String]
    ) async -> [GoogleResponse.Place]? {
        guard var request = await googleRequest(nearbyPath, fieldMask: googleFieldMask) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "includedTypes": types,
            "maxResultCount": 20,
            "rankPreference": "DISTANCE",
            "languageCode": languageCode,
            "locationRestriction": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": radius,
                ],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        // One retry on a connection that never answered. A visit's lookup
        // fires four to eight of these at once and the launch prefetches four
        // visits, so a single dropped request used to fail the whole search
        // and leave "근처에서 못 찾았어요" over a street full of restaurants.
        var attempt: (data: Data, response: URLResponse)?
        let started = Date()
        var sent = 0
        for round in 0..<2 {
            sent += 1
            if let result = try? await URLSession.shared.data(for: request) { attempt = result; break }
            if round == 0 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        // Google bills a request it received, so a retry counts twice even
        // when the first answer never came back.
        Usage.google(tag: "nearby/\(types.joined(separator: "+"))", requests: sent, seconds: -started.timeIntervalSinceNow)
        guard let (data, response) = attempt else {
            print("[PlaceLookup] Google Places unreachable (twice)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { PlacesProxy.forget() }
        noteLimit(status, data)
        guard status == 200 else {
            // A rejected key, a disabled Places API or a project without
            // billing all land here. Say it out loud: falling through to
            // MapKit in silence would look like thin Korean data again, which
            // is the exact problem Google was brought in to solve.
            print("[PlaceLookup] Google Places HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data) else {
            print("[PlaceLookup] Google Places response did not decode")
            return nil
        }
        return decoded.places ?? []
    }

    // MARK: - MapKit

    private static let foodCategories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket,
    ]

    private static func mapKitCandidates(near coordinate: CLLocationCoordinate2D) async -> [PlaceCandidate] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: mapKitRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: foodCategories)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            print("[PlaceLookup] MapKit failed: \(error.localizedDescription)")
            return []
        }
        print(String(format: "[PlaceLookup] MapKit: %d places within %.0fm of %.5f,%.5f",
                     items.count, mapKitRadius, coordinate.latitude, coordinate.longitude))

        return items
            .compactMap { item -> PlaceCandidate? in
                guard let name = item.name, !name.isEmpty else { return nil }
                let location = item.placemark.location ?? CLLocation(
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude
                )
                return PlaceCandidate(
                    id: Self.identifier(for: item, name: name),
                    name: name,
                    address: Self.shortAddress(of: item.placemark),
                    category: Self.label(for: item.pointOfInterestCategory),
                    distance: location.distance(from: origin),
                    googlePlaceID: nil,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            }
            .sorted { $0.distance < $1.distance }
    }

    /// MKMapItem has no stable public identifier before macOS 15, so a
    /// name-plus-coordinate key stands in for one.
    private static func identifier(for item: MKMapItem, name: String) -> String {
        let c = item.placemark.coordinate
        return String(format: "%@@%.5f,%.5f", name, c.latitude, c.longitude)
    }

    private static func shortAddress(of placemark: CLPlacemark) -> String? {
        let parts = [placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? placemark.locality : parts.joined(separator: " ")
    }

    private static func label(for category: MKPointOfInterestCategory?) -> String? {
        switch category {
        case .some(.restaurant): return "식당"
        case .some(.cafe): return "카페"
        case .some(.bakery): return "베이커리"
        case .some(.brewery): return "브루어리"
        case .some(.winery): return "와이너리"
        case .some(.foodMarket): return "식료품"
        default: return nil
        }
    }
}
