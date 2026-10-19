import SwiftUI
import MapKit
import CoreLocation

/// The home screen: every listed visit with GPS as a pin, coloured by the
/// tab it sits in. The sidebar and this map share one filter and one
/// viewport — pan the map and the list narrows to what is in view; hover a
/// card or a pin and both light up.
/// Clicking a pin opens the visit; hovering shows the preview card; 보관 is
/// on the right-click menu.
struct VisitMapView: View {
    @EnvironmentObject private var library: PhotoLibrary
    let open: (Visit) -> Void

    @AppStorage("visitListFilter") private var filterRaw: String = VisitListScreen.Filter.all.rawValue
    private var filter: VisitListScreen.Filter {
        get { VisitListScreen.Filter(rawValue: filterRaw) ?? .all }
        nonmutating set { filterRaw = newValue.rawValue }
    }

    @State private var camera: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var fitted = false
    /// The circle under the mouse: its visits, newest first.
    @State private var hoveredGroup: [Pin]?
    /// Area names for the region chips, from reverse geocoding, cached by cell.
    /// Kept across launches: the geocoder throttles, and asking again for
    /// every cell on every launch is what made it fail.
    @AppStorage("mapAreaNames") private var areaNamesJSON: String = "{}"
    private var areaNames: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(areaNamesJSON.utf8))) ?? [:]
    }
    private func remember(_ name: String, for key: String) {
        var all = areaNames; all[key] = name
        if let data = try? JSONEncoder().encode(all) { areaNamesJSON = String(decoding: data, as: UTF8.self) }
    }

    // MARK: - What is on the map

    private struct Pin: Identifiable {
        let visit: Visit
        let coordinate: CLLocationCoordinate2D
        let tab: VisitListScreen.Filter
        var id: Visit.ID { visit.id }
    }

    private struct Mark: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let pins: [Pin]
        var single: Pin? { pins.count == 1 ? pins[0] : nil }
        var color: Color {
            let tabs = pins.map(\.tab)
            let top = [VisitListScreen.Filter.ready, .place, .posted, .notMeal].max { a, b in tabs.filter { $0 == a }.count < tabs.filter { $0 == b }.count }
            return VisitMapView.color(top ?? .place)
        }
    }

    static func color(_ tab: VisitListScreen.Filter) -> Color {
        switch tab {
        case .ready: return AppBrand.signal
        case .posted: return Color(red: 0.37, green: 0.85, blue: 0.80)
        case .notMeal: return Color(red: 0.36, green: 0.34, blue: 0.33)
        default: return Color(red: 0.55, green: 0.55, blue: 0.58)
        }
    }

    /// Every visit on the map, whatever the tab, so the chips can count.
    /// A snapshot, rebuilt only when `signature` changes: computed on every
    /// redraw it took each visit's median position dozens of times per frame,
    /// and during a photo scan the window hung at 100% CPU.
    @State private var snapshot: [Pin] = []
    private var allPins: [Pin] { snapshot }

    private var signature: String {
        "\(library.visits.count)/\(library.posted.count)/\(library.notMeals.count)/\(library.confirmedPlaces.count)"
            + "/\(library.reviewDrafts.count)/\(library.reviewOptions.count)/\(library.photoDishes.count)/\(library.sureMeals.count)"
    }

    private func rebuild() {
        snapshot = library.visits.compactMap { visit in
            guard let tab = library.homeTab(of: visit), let c = visit.coordinate else { return nil }
            return Pin(visit: visit, coordinate: c, tab: tab)
        }
        fit()
    }

    private var pins: [Pin] {
        // 전부 is every visit still in play; archived ones show only under
        // their own tab.
        allPins.filter { filter == .all ? $0.tab != .notMeal : $0.tab == filter }
    }

    /// Pins closer together than a few dozen points at the current zoom are
    /// one mark with a count; clicking it zooms in on them.
    private var marks: [Mark] {
        // By distance, not grid cells: cells cut one neighbourhood into
        // several circles that sat on top of each other. A pin joins the
        // first group whose centre is within an eleventh of the view.
        let span = region?.span ?? MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
        let reachLat = span.latitudeDelta / 11, reachLng = span.longitudeDelta / 11
        var groups: [(lat: Double, lng: Double, pins: [Pin])] = []
        for pin in pins.sorted(by: { $0.visit.takenAt > $1.visit.takenAt }) {
            let c = pin.coordinate
            if let i = groups.firstIndex(where: { abs($0.lat - c.latitude) < reachLat && abs($0.lng - c.longitude) < reachLng }) {
                let n = Double(groups[i].pins.count)
                groups[i].lat = (groups[i].lat * n + c.latitude) / (n + 1)
                groups[i].lng = (groups[i].lng * n + c.longitude) / (n + 1)
                groups[i].pins.append(pin)
            } else {
                groups.append((c.latitude, c.longitude, [pin]))
            }
        }
        return groups.map { g in
            Mark(id: g.pins.map(\.id).sorted().joined(separator: ","),
                 coordinate: CLLocationCoordinate2D(latitude: g.lat, longitude: g.lng), pins: g.pins)
        }
    }

    private func count(_ tab: VisitListScreen.Filter) -> Int {
        tab == .all ? allPins.filter { $0.tab != .notMeal }.count : allPins.filter { $0.tab == tab }.count
    }

    // MARK: - Where to look

    private static func region(around coordinates: [CLLocationCoordinate2D], padding: Double = 1.4) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        let lats = coordinates.map(\.latitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        // The shortest stretch of longitude that holds every pin: Seoul and
        // Honolulu are 76° apart across the Pacific, not 284° across
        // Europe. Plain min/max asked MapKit for a span wider than the
        // world, which it does not show.
        let lngs = coordinates.map(\.longitude).sorted()
        var west = lngs[0], width = lngs[lngs.count - 1] - lngs[0]
        for i in lngs.indices.dropFirst() {
            let wrapped = 360 - (lngs[i] - lngs[i - 1])
            if wrapped < width { width = wrapped; west = lngs[i] }
        }
        var centerLng = west + width / 2
        if centerLng > 180 { centerLng -= 360 }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: centerLng)
        let span = MKCoordinateSpan(latitudeDelta: min(max((maxLat - minLat) * padding, 0.004), 170),
                                    longitudeDelta: min(max(width * padding, 0.006), 359))
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Whether a coordinate is drawn inside the map's rect — the point or one
    /// of its copies a world to either side, so the date line and a map wider
    /// than the world both hold.
    static func contains(_ rect: MKMapRect, _ c: CLLocationCoordinate2D) -> Bool {
        let p = MKMapPoint(c)
        let world = MKMapSize.world.width
        if rect.size.width >= world { return p.y >= rect.minY && p.y <= rect.maxY }
        return [0, world, -world].contains { rect.contains(MKMapPoint(x: p.x + $0, y: p.y)) }
    }

    /// Whether a coordinate is inside a region, across the date line too.
    static func contains(_ region: MKCoordinateRegion, _ c: CLLocationCoordinate2D) -> Bool {
        let dLat = abs(c.latitude - region.center.latitude)
        let dLng = abs((c.longitude - region.center.longitude + 540).truncatingRemainder(dividingBy: 360) - 180)
        return dLat <= region.span.latitudeDelta / 2 && (region.span.longitudeDelta >= 359 || dLng <= region.span.longitudeDelta / 2)
    }

    private func fit() {
        guard !fitted, !allPins.isEmpty else { return }
        fitted = true
        if let focus = library.mapFocus, let pin = allPins.first(where: { $0.id == focus }) {
            camera = .region(MKCoordinateRegion(center: pin.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.018)))
            library.mapHover = focus
            library.mapFocus = nil
        } else if let r = library.mapRegion {
            camera = .region(r)
        } else if let r = Self.region(around: biggestCluster) {
            // Set after the map's first layout: set earlier, the automatic
            // camera fits every annotation over it and opens on the world.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { camera = .region(r) }
        }
    }

    /// Where most of the eating happened: the 0.5° cell with the most pins
    /// plus its neighbours — Seoul, not the whole Pacific.
    private var biggestCluster: [CLLocationCoordinate2D] {
        let key: (CLLocationCoordinate2D) -> (Int, Int) = { (Int(floor($0.latitude * 2)), Int(floor($0.longitude * 2))) }
        var counts: [String: Int] = [:]
        for p in allPins { let k = key(p.coordinate); counts["\(k.0)/\(k.1)", default: 0] += 1 }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        let parts = top.split(separator: "/").compactMap { Int($0) }
        return allPins.map(\.coordinate).filter { c in
            let k = key(c); return abs(k.0 - parts[0]) <= 1 && abs(k.1 - parts[1]) <= 1
        }
    }

    /// Equal to within a hair: MapKit's reported region jitters in the last
    /// digits between two reports of a camera that did not move.
    static func same(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion?) -> Bool {
        guard let b else { return false }
        let tol = max(a.span.latitudeDelta, 0.0001) * 0.001
        return abs(a.center.latitude - b.center.latitude) < tol && abs(a.center.longitude - b.center.longitude) < tol
            && abs(a.span.latitudeDelta - b.span.latitudeDelta) < tol && abs(a.span.longitudeDelta - b.span.longitudeDelta) < tol
    }

    private func look(at coordinates: [CLLocationCoordinate2D]) {
        if let r = Self.region(around: coordinates) { withAnimation(.easeInOut(duration: 0.5)) { camera = .region(r) } }
    }

    /// Visits grouped by rough area (a degree of latitude and longitude),
    /// biggest first: home, then the trips.
    private var cells: [(key: String, coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D])] {
        var cells: [String: [CLLocationCoordinate2D]] = [:]
        for pin in allPins where pin.tab != .notMeal {
            let key = "\(Int(floor(pin.coordinate.latitude)))/\(Int(floor(pin.coordinate.longitude)))"
            cells[key, default: []].append(pin.coordinate)
        }
        return cells.map { key, cs in
            let lat = cs.map(\.latitude).reduce(0, +) / Double(cs.count)
            let lng = cs.map(\.longitude).reduce(0, +) / Double(cs.count)
            return (key, CLLocationCoordinate2D(latitude: lat, longitude: lng), cs)
        }
    }

    /// The cells merged by the name they geocode to, so Seoul — which the
    /// 127° line cuts in two — is one chip. Biggest first.
    private var areas: [(key: String, name: String?, coordinates: [CLLocationCoordinate2D])] {
        var groups: [String: [CLLocationCoordinate2D]] = [:]
        var order: [String] = []
        for cell in cells {
            let label = areaNames[cell.key] ?? "#" + cell.key
            if groups[label] == nil { order.append(label) }
            groups[label, default: []] += cell.coordinates
        }
        return order.map { ($0, $0.hasPrefix("#") ? nil : $0, groups[$0] ?? []) }
            .sorted { $0.coordinates.count > $1.coordinates.count }
    }

    private var years: [Int] {
        Array(Set(allPins.map { Calendar.current.component(.year, from: $0.visit.takenAt) })).sorted(by: >)
    }

    /// Province or state, in Korean: 서울특별시, 부산광역시, 도쿄도.
    /// One geocoder request at a time — it throttles bursts.
    private func nameCells() async {
        // Biggest first, so a throttled run still names the places that matter.
        let todo = cells.filter { areaNames[$0.key] == nil }.sorted { $0.coordinates.count > $1.coordinates.count }
        for cell in todo {
            let location = CLLocation(latitude: cell.coordinate.latitude, longitude: cell.coordinate.longitude)
            do {
                let mark = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ko_KR")).first
                // A US state comes back as "HI"/"CA": the city says more there.
                let name = mark?.isoCountryCode == "US" ? (mark?.locality ?? mark?.administrativeArea) : mark?.administrativeArea
                if let name = name ?? mark?.country { remember(name, for: cell.key) }
            } catch {
                // Throttled or offline: leave it unnamed and try again later,
                // never file it under a catch-all name.
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("어디서 먹었나요").font(.system(size: 30, weight: .black)).tracking(-0.8).foregroundStyle(AppBrand.foreground)
                    Text("핀에 올리면 미리보기, 누르면 바로 그 방문. 왼쪽 목록은 지도에 보이는 곳만 보여줘요.")
                        .font(.system(size: 14)).foregroundStyle(AppBrand.muted)
                }
                Spacer()
                HStack(spacing: 8) {
                    // Menus, not chips: a row of chips runs out of room as the
                    // places and years grow.
                    Menu {
                        ForEach(areas, id: \.key) { area in
                            Button("\(area.name ?? "이름 찾는 중") · \(area.coordinates.count)") { look(at: area.coordinates) }
                        }
                    } label: { menuLabel(String(localized: "지역")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Menu {
                        ForEach(years, id: \.self) { year in
                            let inYear = pins.filter { Calendar.current.component(.year, from: $0.visit.takenAt) == year }
                            Button("\(String(year))년 · \(inYear.count)") { look(at: inYear.map(\.coordinate)) }
                        }
                    } label: { menuLabel(String(localized: "연도")) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            HStack {
                HStack(spacing: 8) {
                    ForEach(VisitListScreen.Filter.allCases, id: \.self) { tab in
                        Button { filter = tab } label: {
                            HStack(spacing: 8) {
                                Circle().fill(tab == .all ? AppBrand.foreground : Self.color(tab)).frame(width: 10, height: 10)
                                Text(verbatim: "\(tab.label) \(count(tab))")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(filter == tab ? AppBrand.ink : AppBrand.foreground)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(filter == tab ? AppBrand.signal : AppBrand.raisedSurface))
                            .overlay(Capsule().stroke(filter == tab ? AppBrand.signal : AppBrand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plainHit)
                    }
                }
                Spacer()
            }

            ZStack(alignment: .topTrailing) {
                Map(position: $camera, interactionModes: .all) {
                    ForEach(marks) { mark in
                        if let pin = mark.single {
                            Annotation("", coordinate: pin.coordinate, anchor: .center) {
                                PinDot(color: Self.color(pin.tab), lit: library.mapHover == pin.id)
                                    .onHover { over in
                                        if over { library.mapHover = pin.id }
                                        else if library.mapHover == pin.id { library.mapHover = nil }
                                    }
                                    .onTapGesture { open(pin.visit) }
                                    .contextMenu {
                                        Button("열기") { open(pin.visit) }
                                        Button(pin.tab == .notMeal ? "보관 풀기" : "보관") { library.setNotMeal(pin.tab != .notMeal, for: pin.visit) }
                                    }
                                    .help(pin.visit.fullTitle + (library.confirmedPlace(for: pin.id).map { " · " + PlaceNames.shown($0.name) } ?? ""))
                            }
                            .annotationTitles(.hidden)
                        } else {
                            Annotation("", coordinate: mark.coordinate, anchor: .center) {
                                let lit = mark.pins.contains { $0.id == library.mapHover }
                                // Lit like a pin under the mouse: bigger, with a
                                // ring — it gave no sign at all.
                                // A card hovered in the list lights its circle too.
                                Text("\(mark.pins.count)")
                                    .font(.system(size: lit ? 16 : 14, weight: .black)).foregroundStyle(AppBrand.ink)
                                    .frame(width: lit ? 46 : 38, height: lit ? 46 : 38)
                                    .background(Circle().fill(mark.color))
                                    .overlay(Circle().stroke(AppBrand.ink, lineWidth: 3))
                                    .overlay(Circle().stroke(lit ? mark.color : mark.pins.contains { $0.tab == .ready } ? AppBrand.signal : .clear,
                                                             lineWidth: lit ? 3 : 2).padding(lit ? -4 : -3))
                                    .shadow(color: lit ? mark.color.opacity(0.5) : .clear, radius: 8)
                                    .contentShape(Circle())
                                    .animation(.easeOut(duration: 0.12), value: lit)
                                    .onTapGesture { look(at: mark.pins.map(\.coordinate)) }
                                // A circle shows its newest visit like a pin
                                // does, with the rest counted below — hovering
                                // it used to do nothing.
                                .onHover { over in
                                    if over { hoveredGroup = mark.pins; library.mapHover = mark.pins[0].id }
                                    else if hoveredGroup?.first?.id == mark.pins.first?.id { hoveredGroup = nil; library.mapHover = nil }
                                }
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .mapControls { MapCompass(); MapZoomStepper() }
                .onMapCameraChange(frequency: .onEnd) { context in
                    // MapKit reports the camera again after every redraw even
                    // when it has not moved; storing that each time redrew,
                    // which reported again — one loop per frame at 100% CPU.
                    let r = context.region
                    guard !Self.same(r, region) else { return }
                    region = r
                    if fitted { library.mapRect = context.rect; library.mapRegion = r }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppBrand.line, lineWidth: 1))

                // A map control, not a tab: square, dark, on the map itself.
                // Tabs sort the visits; this only moves the
                // camera.
                VStack {
                    HStack {
                        Button { look(at: pins.map(\.coordinate)) } label: {
                            Label("전체 보기", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.foreground)
                                .padding(.horizontal, 12).frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppBrand.ink.opacity(0.88)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plainHit)
                        .help("이 탭의 방문이 모두 보이게 지도를 넓혀요")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(14)

                if let group = hoveredGroup, let newest = group.first {
                    PreviewCard(visit: newest.visit, tab: newest.tab, others: group.dropFirst().map(\.visit))
                        .padding(14)
                        .allowsHitTesting(false)
                } else if let id = library.mapHover, let pin = allPins.first(where: { $0.id == id }) {
                    PreviewCard(visit: pin.visit, tab: pin.tab)
                        .padding(14)
                        .allowsHitTesting(false)
                }

                VStack { Spacer(); HStack(alignment: .bottom) { legend; Spacer(); footnote } }.padding(14).allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 22)
        // The map comes up before the visits have loaded; rebuild (and fit
        // once) whenever what the pins depend on changes.
        .onChange(of: signature, initial: true) { _, _ in rebuild() }
        .task(id: snapshot.count) { await nameCells() }
        // A tab picked here or in the sidebar widens the map to that tab's
        // visits: following the viewport had hidden a 작성중 visit abroad
        // while the map sat on home.
        .onChange(of: filterRaw) { _, _ in if fitted { look(at: pins.map(\.coordinate)) } }
        .onChange(of: library.mapShowAll) { _, _ in look(at: pins.map(\.coordinate)) }
        .onDisappear { hoveredGroup = nil; if library.mapHover != nil { library.mapHover = nil } }
        // Clicking a circle zooms in and splits it; its hover never ends.
        .onChange(of: region?.span.latitudeDelta) { _, _ in
            if hoveredGroup != nil { hoveredGroup = nil; library.mapHover = nil }
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .black))
        }
        .font(.system(size: 14, weight: .bold)).foregroundStyle(AppBrand.foreground)
        .padding(.horizontal, 14).frame(height: 36)
        .background(Capsule().fill(AppBrand.raisedSurface))
        .overlay(Capsule().stroke(AppBrand.line, lineWidth: 1))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([VisitListScreen.Filter.place, .ready, .posted], id: \.self) { tab in
                HStack(spacing: 6) {
                    Circle().fill(Self.color(tab)).frame(width: 10, height: 10)
                    Text(tab.label)
                }
            }
            Text("숫자 = 겹친 핀").foregroundStyle(AppBrand.faint)
        }
        .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppBrand.ink.opacity(0.82)))
    }

    private var footnote: some View {
        let missing = library.unwrittenWithoutLocation
        return Text(String(localized: "\(pins.count)곳") + (missing > 0 ? String(localized: " · 위치 없는 방문 \(missing)개는 목록에서만") : ""))
            .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppBrand.ink.opacity(0.82)))
    }
}

/// One visit's pin. Lit while its card or itself is under the mouse.
private struct PinDot: View {
    let color: Color
    let lit: Bool
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: lit ? 26 : 18, height: lit ? 26 : 18)
            .overlay(Circle().stroke(AppBrand.ink, lineWidth: 3))
            .overlay(Circle().stroke(lit ? color : .clear, lineWidth: 3).padding(-4))
            .shadow(color: lit ? color.opacity(0.5) : .clear, radius: 8)
            .contentShape(Circle().scale(1.6))
            .animation(.easeOut(duration: 0.12), value: lit)
    }
}

/// What a pin is, without leaving the map: photos, when, where, how far it
/// has got, and whether this place already has a review up.
private struct PreviewCard: View {
    @EnvironmentObject private var library: PhotoLibrary
    let visit: Visit
    let tab: VisitListScreen.Filter
    /// The rest of a circle's visits, newest first; empty for a single pin.
    var others: [Visit] = []

    var body: some View {
        let place = library.confirmedPlace(for: visit.id).map { PlaceNames.shown($0.name) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(visit.fullTitle).font(.system(size: 18, weight: .black)).foregroundStyle(AppBrand.foreground)
                    Text([place, library.statusLine(for: visit)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(AppBrand.muted)
                }
                Spacer(minLength: 12)
                Text(others.isEmpty ? String(localized: "누르면 ") + library.nextAction(for: visit) + " →" : String(localized: "누르면 확대"))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(VisitMapView.color(tab))
            }
            HStack(spacing: 8) {
                ForEach(visit.photos.prefix(3)) { photo in
                    PhotoTile(photo: photo).frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            if let earlier = library.earlierPost(samePlaceAs: visit) {
                Text("✍️ \(earlier.visit.title) 방문으로 이미 리뷰를 올린 가게예요")
                    .font(.system(size: 13)).foregroundStyle(AppBrand.foreground)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppBrand.signal.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppBrand.signal.opacity(0.35), lineWidth: 1))
            }
            if !others.isEmpty {
                Divider().overlay(AppBrand.line)
                Text("이 근처 \(others.count)곳 더").font(.system(size: 13, weight: .bold)).foregroundStyle(AppBrand.muted)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(others.prefix(3)) { other in
                        VStack(alignment: .leading, spacing: 4) {
                            if let photo = other.photos.first {
                                PhotoTile(photo: photo).frame(width: 64, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Text(other.title).font(.system(size: 11)).foregroundStyle(AppBrand.muted).lineLimit(1)
                        }
                        .frame(width: 64, alignment: .leading)
                    }
                    if others.count > 3 {
                        Text("+\(others.count - 3)")
                            .font(.system(size: 16, weight: .black)).foregroundStyle(AppBrand.foreground)
                            .frame(width: 64, height: 48)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppBrand.raisedSurface))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppBrand.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }
}
