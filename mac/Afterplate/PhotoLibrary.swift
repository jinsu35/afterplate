import Foundation
import CoreServices
import AVKit
import Photos
import AppKit
import ImageIO
import Vision
import UniformTypeIdentifiers
import CoreLocation
import MapKit
import CryptoKit

/// One photo, wherever it came from. macOS grants photo-library access as
/// all-or-nothing (verified: the Photos privacy pane shows a single toggle, no
/// "Select Photos" as on iOS), so a folder has to be a first-class source for
/// anyone who will not hand over the whole library.
struct Photo: Identifiable, Hashable {
    enum Origin: Hashable {
        case asset(String)   // PHAsset.localIdentifier
        case file(URL)
    }

    let origin: Origin
    let takenAt: Date
    /// A video from the library. Everything treats it as a photo — it is
    /// scored, grouped and named from its poster frame — except the copy
    /// handed to Google, which is the movie itself.
    var isVideo = false
    var duration: TimeInterval = 0
    /// The best confidence among Vision's 52 food labels. Vision ranks 1,303
    /// general labels, so "food" takes 0.12 on a plated steak while
    /// "tableware" takes 0.94 — the number means "how strongly food, next to
    /// everything else in the frame", not "is there food". Measured against
    /// 265 judged visits: at 0.02 it keeps 221 of 237 real meals and lets 6
    /// of 28 non-meals through; Vision's own calibrated thresholds keep only
    /// 125, and a raw 0.5 (the rule until today) also counted "license_plate"
    /// and "rice_field" as food because the words were matched as substrings.
    var foodScore: Float = 0
    /// SigLIP's probability that this is an 애플사진 — a photo from a
    /// meal visit, as opposed to food merely being visible. See AppleClassifier.
    var appleScore: Float = 0
    /// SigLIP's probability that food is the subject of the frame rather
    /// than a person, a place or an object.
    var mainlyFoodScore: Float = 0
    /// An 애플사진: either the Vision rules passed it (foodScore > 0, the bar
    /// and the vetoes already applied) or SigLIP called it one with food
    /// as the subject. Either alone misses things the other catches: Vision
    /// lost a laid outdoor table and a 빙수, the image-text model a burger tray
    /// and a sandwich. Without the subject test it also pulled in 150 visits of
    /// people sitting at restaurant tables, which are not 애플.
    var isFood: Bool {
        foodScore > 0 || (appleScore >= AppleClassifier.threshold && mainlyFoodScore >= AppleClassifier.threshold)
    }
    /// "요조" (요기조기): SigLIP thinks this was taken at a meal but the subject
    /// is a person, not the food — a place the user ate at, kept for a
    /// future "내가 간 음식점" list. Not shown anywhere yet; the 요조 rules
    /// (menu boards, storefronts, cafe interiors) are still to be fixed.
    var isYojo: Bool { !isFood && appleScore >= AppleClassifier.threshold }
    /// Plates, bowls, cups, cutlery — a table laid for a meal. Vision is sure
    /// about these even when it cannot name the food (a dim steak scored
    /// tableware 0.95, food 0.10), but they also fire on an empty table or a
    /// person holding a cup, so they only decide whether a visit exists at
    /// all: the list keeps such visits in their own tab.
    var tableScore: Float = 0
    var isTable: Bool { tableScore >= 0.5 }
    /// How sure Vision is there are people in the frame. A laid table with
    /// no food label but people at the centre is a day out at a restaurant
    /// — the list files those as 추억 rather than meals to review.
    var peopleScore: Float = 0
    /// The strongest food label before any bar or veto. A dim burger, a
    /// bowl of 빙수 or 떡볶이 read 0.05–0.14, and a bagel on a printed bag
    /// was vetoed as print; 20 such meals were lost outright.
    var rawFoodScore: Float = 0
    /// Some food label fired but not enough to be sure: the visit goes to
    /// "이게 밥인가?" for the person to judge rather than disappearing.
    var isMaybeFood: Bool { !isFood && rawFoodScore >= 0.05 }
    /// Worth keeping as a visit at all.
    var isMealish: Bool { isFood || tableScore >= 0.65 || isMaybeFood }
    /// A laid table with people at the centre and no food Vision could name.
    var isMemory: Bool { !isFood && tableScore >= 0.65 && peopleScore >= 0.5 }
    /// Where the photo was taken. A photo taken at a place has coordinates; a
    /// screenshot or a download does not. Together with foodScore this is what
    /// distinguishes a real visit from a saved picture of food — and it is the
    /// first-choice evidence for naming the restaurant, which costs nothing.
    var latitude: Double?
    var longitude: Double?
    /// The radius the phone itself gives for that position, in metres. Indoors
    /// it is what says whether 20m between two candidates is a difference or
    /// noise; negative or missing means the phone would not say.
    var accuracy: Double?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var id: String {
        switch origin {
        case .asset(let identifier): return identifier
        case .file(let url): return url.path
        }
    }
}

/// One restaurant visit: photos taken close together in time.
struct Visit: Identifiable {
    let id: String
    var photos: [Photo]
    var takenAt: Date

    /// Where the visit happened, so its clock is the one on the wall there.
    var timeZone: TimeZone { VisitTimeZone.zone(at: coordinate) }
    /// The calendar in that zone: hours, days and years read in it.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    var title: String {
        Self.dayFormatter.timeZone = timeZone
        return Self.dayFormatter.string(from: takenAt)
    }
    /// With the year, for screens that show one visit (the list shows the
    /// year once, in a header that sticks while scrolling).
    var fullTitle: String {
        Self.yearFormatter.timeZone = timeZone
        return Self.yearFormatter.string(from: takenAt) + " " + title
    }
    var year: Int { calendar.component(.year, from: takenAt) }
    /// The time the clock there read, as a date on this Mac's calendar: for
    /// a line naming the day, which carries no zone ("Visited on 2
    /// January 2025" for an evening abroad, not the next morning at
    /// home).
    var wallClock: Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: takenAt)
        return Calendar.current.date(from: parts) ?? takenAt
    }
    var photoCount: Int { photos.count }
    /// The best the classifier scored any photo here. Under 0.75 the visit is
    /// a coin toss — measured over 265 visits, 20-37% of those were not meals
    /// at all, against 2-8% above it — so the list keeps them in their own tab.

    /// Where the visit happened: the median position of the *food* photos
    /// that carry GPS — that is where the table was. Since a visit keeps the
    /// whole cluster, the walk up and the street outside are in it too, and
    /// they count only when no food photo has GPS. Median, not mean: one
    /// photo taken at the door drags a mean tens of metres, and in a block
    /// with 99 food places within 150m that is the difference between lists.
    var coordinate: CLLocationCoordinate2D? {
        Self.centroid(of: photos.filter { $0.isFood }) ?? Self.centroid(of: photos)
    }

    /// How far off the visit's position could be, by the phone's own account.
    /// Two candidates closer together than this are not ranked by metres —
    /// the measurement cannot tell them apart. 15m is the floor: a phone
    /// indoors reports single-digit accuracy it does not have.
    var positionError: Double {
        let reported = photos.compactMap(\.accuracy).sorted()
        guard !reported.isEmpty else { return 30 }
        return max(15, reported[reported.count / 2])
    }

    static func centroid(of photos: [Photo]) -> CLLocationCoordinate2D? {
        let located = photos.compactMap(\.coordinate)
        guard !located.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
        return CLLocationCoordinate2D(
            latitude: median(located.map(\.latitude)),
            longitude: median(located.map(\.longitude))
        )
    }

    // In the app's language: "1월 2일 (목) 오후 1시" / "Thu, Jan 2, 1 PM".
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        if AppLanguage.current.isEnglish {
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEE, MMM d, h a"
        } else {
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "M월 d일 (E) a h시"
        }
        return formatter
    }()
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current.isEnglish ? "en_US" : "ko_KR")
        formatter.dateFormat = AppLanguage.current.isEnglish ? "yyyy" : "yyyy년"
        return formatter
    }()
}

@MainActor
final class PhotoLibrary: ObservableObject {
    enum Access { case unknown, denied, granted, folder }

    @Published private(set) var access: Access = .unknown
    /// `-AfterplateShowFirstRun YES`: the first-run screen on a Mac whose
    /// photo access was granted long ago, until one of its buttons is used.
    @Published private(set) var firstRunPreview = UserDefaults.standard.bool(forKey: "AfterplateShowFirstRun")
    @Published private(set) var visits: [Visit] = []

    // MARK: Map home
    /// The map's last visible region: the sidebar narrows to it while the
    /// map is showing.
    @Published var mapRegion: MKCoordinateRegion?
    /// What the map actually draws, in map points. The region MapKit reports
    /// stops matching the drawing once the view is zoomed out past the
    /// world, and the list counted pins on screen as outside.
    @Published var mapRect: MKMapRect?
    /// The visit under the mouse, on a pin or on a list card; both light up.
    @Published var mapHover: Visit.ID?
    /// "지도에서" inside a visit: the map opens on this pin, lit.
    @Published var mapFocus: Visit.ID?
    /// Bumped to ask the map to show every pin under the current filter —
    /// the list's "지도 밖에 N개 더" and the map's 전체 보기.
    @Published var mapShowAll = 0
    @Published private(set) var scanning = false
    @Published private(set) var total = 0
    @Published private(set) var folderName: String?
    @Published private(set) var foodCount = 0
    /// Library classification progress: photos scored so far out of those
    /// that still needed a score. toClassify is zero when nothing is pending.
    @Published private(set) var classified = 0
    @Published private(set) var toClassify = 0
    /// Food photos the first look has just found, a few at a time, for the
    /// sticker canvas on the scanning screen. The latest 40 only.
    @Published private(set) var scanFinds: [Prefetcher.Find] = []
    /// Small-scored photos being fetched from iCloud and scored again.
    @Published private(set) var sharpened = 0
    @Published private(set) var toSharpen = 0
    private var sharpening = false
    /// Restaurant candidates found from GPS, keyed by visit. Empty array means
    /// the lookup ran and found nothing; missing means it has not run.
    @Published private(set) var placeCandidates: [Visit.ID: [PlaceCandidate]] = [:]
    /// The candidate the user tapped to confirm — or the sole candidate,
    /// which needs no confirmation.
    @Published private(set) var confirmedPlaces: [Visit.ID: PlaceCandidate] = [:]
    /// What the photos say about the place, keyed by visit. See PlaceMatch.
    @Published private(set) var placeMatches: [Visit.ID: PlaceMatch] = [:]
    @Published private(set) var matching: Set<Visit.ID> = []
    /// The review draft per visit, editable by the user. See ReviewDraft.
    @Published private(set) var reviewDrafts: [Visit.ID: ReviewDraft] = [:]
    @Published private(set) var drafting: Set<Visit.ID> = []
    /// What each visit's drafting is doing now.
    @Published private(set) var draftStage: [Visit.ID: ReviewDrafter.Stage] = [:]
    /// Three genre takes to choose from, per visit.
    @Published private(set) var reviewOptions: [Visit.ID: [GenreDraft]] = [:]
    /// English translations by SHA-256 of the Korean text.
    @Published private(set) var translations: [String: String] = [:]
    @Published private(set) var translating: Set<Visit.ID> = []
    /// Committed dish name per photo, per visit — what the drafts call the food.
    @Published private(set) var photoDishes: [Visit.ID: [String: String]] = [:]
    /// The namer's suggestion per photo when it was not sure enough to commit.
    /// Since the redesign these are also written into `photoDishes` as the
    /// caption — a best guess beats an empty field —
    /// and this map is what marks them as guesses in the UI.
    @Published private(set) var photoSuggestions: [Visit.ID: [String: String]] = [:]
    /// Visits the user has posted, with when.
    @Published private(set) var posted: [Visit.ID: Date] = [:]
    /// Dishes the user marked ♥ per visit — the "정말 맛있었다" tier; the rest
    /// are written as "나쁘지 않았다". The original product's two levels.
    @Published private(set) var likes: [Visit.ID: Set<String>] = [:]
    /// ♥ per dish name. The photo heart went with the naming screen's
    /// rewrite and nobody could mark a dish for six
    /// days; the review strip now carries one heart per dish.
    @Published private(set) var likedDishes: [Visit.ID: Set<String>] = [:]
    /// What kind of photo each one is (food / eaten / place / other).
    @Published private(set) var photoKinds: [Visit.ID: [String: DishNaming.Kind]] = [:]
    @Published private(set) var photoRotations: [String: Int] = [:]
    @Published private(set) var formOpened: Set<String> = []
    /// Visits the person waved off as not meals; the list keeps them in
    /// their own tab so a mistake can be undone.
    @Published private(set) var notMeals: Set<Visit.ID> = []
    /// Visits from "이게 밥인가?" the person vouched for.
    @Published private(set) var sureMeals: Set<Visit.ID> = []
    /// Menu names known for a visit's confirmed place, for the chips.
    @Published private(set) var menuNames: [Visit.ID: [String]] = [:]
    @Published private(set) var menuLoading: Set<Visit.ID> = []
    @Published private(set) var naming: Set<Visit.ID> = []
    /// Menus whose English names were asked for in this run.
    private var englishAsked: Set<String> = []
    /// Visits whose menu is being named in English right now.
    @Published private(set) var namingInEnglish: Set<Visit.ID> = []
    private var menuAliases: [String: [String: MenuItem]] = [:]
    private var chipNames: [String: (name: String, printed: String?)] = [:]
    private var awaitingMenu: [String: Set<Visit.ID>] = [:]
    /// Shown under the photo grid when the menu could not be read.
    @Published private(set) var menuHint: [Visit.ID: String] = [:]
    /// Photos whose deep search is running, and what the last one found.
    /// 전망 · 분위기 · 서비스 by visit, in the order they were pressed.
    @Published private(set) var tags: [Visit.ID: [String]] = [:]
    static let placeTags = ["전망", "분위기", "서비스"]

    /// A place tag as shown: "분위기 좋았다" / "Great atmosphere". The stored
    /// tag stays Korean.
    static func tagPhrase(_ tag: String) -> String {
        switch tag {
        case "전망": return String(localized: "전망 좋았다")
        case "분위기": return String(localized: "분위기 좋았다")
        case "서비스": return String(localized: "서비스 좋았다")
        default: return tag
        }
    }

    func toggleTag(_ tag: String, for visit: Visit) {
        var chosen = memory.tags[visit.id] ?? []
        if let at = chosen.firstIndex(of: tag) { chosen.remove(at: at) } else { chosen.append(tag) }
        memory.tags[visit.id] = chosen.isEmpty ? nil : chosen
        tags[visit.id] = chosen
        invalidateDraftOptions(for: visit)
        saveMemory()
    }

    @Published private(set) var deepSearching: Set<String> = []
    @Published private(set) var deepSearchNote: [String: String] = [:]
    /// Where the photos for posting were put, per visit.
    @Published private(set) var postFolders: [Visit.ID: URL] = [:]

    init() {
        // Test hook: AFTERPLATE_TEST_MENU=<placeId> reads that place's menu at
        // launch and logs it, without opening a visit.
        if let placeID = ProcessInfo.processInfo.environment["AFTERPLATE_TEST_MENU"], !placeID.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let menu = await self.fetcher.fetch(placeID: placeID)
                print("[MenuFetcher] TEST \(placeID): " + (menu.map { "\($0.name): \($0.highlights.joined(separator: ", ")) · \($0.menuPhotos.count) photos" } ?? "nil"))
            }
        }
    }


    /// Photos more than this far apart in time start a new visit.
    private let visitGap: TimeInterval = 2 * 60 * 60
    /// Photos more than this far from the visit's centre start a new visit
    /// even inside the time gap. Measured on one afternoon: three photos
    /// at one restaurant table lay within 9m of each other, three at the cafe
    /// next visit within 10m, the two groups 77m apart, the cafe's receipt
    /// 12m from the cafe photos and 73m from the meal — and a 150m rule
    /// merged all seven into one visit. 50m keeps a table together with room
    /// for indoor jitter and separates the next place; a wrongly split visit
    /// is two reviews of one place, a wrongly merged one is a review with the
    /// wrong photos, and the second is worse. (The 6–79m figure elsewhere in
    /// this repo is photo-centroid-to-POI error, not table spread.)
    private let visitSpread: CLLocationDistance = 50
    private var assetsByIdentifier: [String: PHAsset] = [:]
    private var draggableURLs: [String: URL] = [:]
    /// Every photo of the last scan, so visits can be regrouped without one.
    private var scanned: [Photo] = []

    /// What survives a relaunch: food scores, so a library of thousands
    /// of photos is
    /// classified once rather than on every start, and photos the user took
    /// out of a visit, so a rescan does not put them back.
    private struct Memory: Codable {
        /// Bumped when scoring changes, so stale scores are thrown away while
        /// the user's hidden photos are kept.
        /// 11: classified at 640px instead of 320.
        /// 12–13: herb-only food labels under foliage are a plant.
        /// 14: the raw food label is kept, for "maybe food".
        /// 15: MobileCLIP 애플사진 score added.
        /// 16: "mainly food" subject score added.
        /// 17: SigLIP instead of MobileCLIP for both.
        static let currentVersion = 17
        var version: Int? = currentVersion
        var foodScores: [String: Float] = [:]
        var tableScores: [String: Float] = [:]
        var peopleScores: [String: Float] = [:]
        /// The long side of the image each score was taken from. A photo
        /// kept only in iCloud has no local 640px rendition and was scored
        /// small; these are fetched and scored again. Missing = not known.
        var scoredPixels: [String: Int] = [:]
        var rawFoodScores: [String: Float] = [:]
        var appleScores: [String: Float] = [:]
        var mainlyFoodScores: [String: Float] = [:]
        /// Photos already fetched from iCloud that still came back small;
        /// asking again every launch gets the same answer.
        var iCloudTried: Set<String> = []
        var hidden: Set<String> = []
        /// Place lookups by ~11m cell, so a relaunch — or a second visit to the
        /// same table — asks Google nothing.
        var places: [String: CachedPlaces] = [:]
        /// The candidate the user confirmed, by visit.
        var confirmed: [String: PlaceCandidate] = [:]
        /// Vision matches, keyed by a digest of visit + photos + candidates so
        /// a changed photo set or candidate list asks again.
        var matches: [String: PlaceMatch] = [:]
        /// Drafts by visit, with the user's edits.
        var drafts: [String: ReviewDraft] = [:]
        /// On-device OCR lines per visit (by photo-set digest).
        var ocr: [String: [String]] = [:]
        /// Photos at which the user cut a visit in two.
        var splits: Set<String> = []
        /// Photos the user said belong with the visit before them, whatever
        /// the metres say — the answer to a GPS reading that wandered
        /// indoors and split one lunch into three.
        var merges: Set<String> = []
        var options: [String: [GenreDraft]] = [:]
        var notes: [String: String] = [:]
        var ratings: [String: Int] = [:]
        /// The Google account (email) the review form should open under —
        /// Safari may hold several; Google picks its default otherwise.
        var googleAccount: String = ""
        var translations: [String: String] = [:]
        /// What the extension read from Google Maps, by place id, dated.
        var googleMenus: [String: CachedGoogleMenu] = [:]
        /// Dish name per photo, per visit, as the user left it.
        var photoDishes: [String: [String: String]] = [:]
        /// The namer's uncommitted suggestions, so a relaunch does not ask again.
        var photoSuggestions: [String: [String: String]] = [:]
        var photoKinds: [String: [String: DishNaming.Kind]] = [:]
        /// Clockwise degrees to turn a photo (by photo id): the model's call
        /// at naming, or the user's ↻ on a tile. Applied to tiles and copies.
        var photoRotations: [String: Int] = [:]
        /// Visits whose photos have been judged for rotation (the judgement
        /// arrived after naming existed, so older namings are redone once).
        var rotationJudged: Set<String> = []
        /// Visits whose Google form was opened at least once (so 올렸어요 can
        /// be offered later without ever showing before the first open).
        var formOpened: Set<String> = []
        /// Visits whose place the app chose ahead of time for the feed and
        /// the person has not looked at yet. Kept apart from a real
        /// confirmation: the match scorecard grades only what a person chose.
        var autoConfirmed: Set<String> = []
        /// The user's own order of a visit's photos (photo ids); unlisted
        /// photos follow in time order.
        var photoOrder: [String: [String]] = [:]
        /// Visits the person said are not visits to review ("이건 방문 아니에요").
        var notMeals: Set<String> = []
        /// Visits Vision was unsure about that the person said are meals.
        var sureMeals: Set<String> = []
        var posted: [String: Date] = [:]
        var likes: [String: Set<String>] = [:]
        var likedDishes: [String: Set<String>] = [:]
        /// 전망 · 분위기 · 서비스 — what the person wants said about the place
        /// itself. Each one becomes a remark ("전망 좋았다") the writer is asked
        /// to say better, exactly as a dish does.
        var tags: [String: [String]] = [:]
        /// When each photo deep search ran. The allowance is a rolling week,
        /// so the dates are kept rather than a count.
        var deepSearches: [Date] = []
        /// What a deep search reported, by photo, so the person can still see
        /// where a name came from after a relaunch.
        var deepSearchNotes: [String: String] = [:]

        struct CachedGoogleMenu: Codable {
            var fetchedAt: Date
            var highlights: [String]
            var photoURLs: [String]
            var items: [MenuItem]
            /// true when the items came from a web search (no menu on Google Maps).
            var fromWeb: Bool? = nil
        }

        struct CachedPlaces: Codable {
            var fetchedAt: Date
            var candidates: [PlaceCandidate]
        }

        init(hidden: Set<String> = []) { self.hidden = hidden }

        // Fields added after the first release decode as empty when absent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            foodScores = try c.decodeIfPresent([String: Float].self, forKey: .foodScores) ?? [:]
            tableScores = try c.decodeIfPresent([String: Float].self, forKey: .tableScores) ?? [:]
            peopleScores = try c.decodeIfPresent([String: Float].self, forKey: .peopleScores) ?? [:]
            scoredPixels = try c.decodeIfPresent([String: Int].self, forKey: .scoredPixels) ?? [:]
            rawFoodScores = try c.decodeIfPresent([String: Float].self, forKey: .rawFoodScores) ?? [:]
            appleScores = try c.decodeIfPresent([String: Float].self, forKey: .appleScores) ?? [:]
            mainlyFoodScores = try c.decodeIfPresent([String: Float].self, forKey: .mainlyFoodScores) ?? [:]
            iCloudTried = try c.decodeIfPresent(Set<String>.self, forKey: .iCloudTried) ?? []
            hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            places = try c.decodeIfPresent([String: CachedPlaces].self, forKey: .places) ?? [:]
            confirmed = try c.decodeIfPresent([String: PlaceCandidate].self, forKey: .confirmed) ?? [:]
            matches = try c.decodeIfPresent([String: PlaceMatch].self, forKey: .matches) ?? [:]
            drafts = try c.decodeIfPresent([String: ReviewDraft].self, forKey: .drafts) ?? [:]
            ocr = try c.decodeIfPresent([String: [String]].self, forKey: .ocr) ?? [:]
            splits = try c.decodeIfPresent(Set<String>.self, forKey: .splits) ?? []
            merges = try c.decodeIfPresent(Set<String>.self, forKey: .merges) ?? []
            options = try c.decodeIfPresent([String: [GenreDraft]].self, forKey: .options) ?? [:]
            notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
            ratings = try c.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
            googleAccount = try c.decodeIfPresent(String.self, forKey: .googleAccount) ?? ""
            translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
            googleMenus = try c.decodeIfPresent([String: CachedGoogleMenu].self, forKey: .googleMenus) ?? [:]
            photoDishes = try c.decodeIfPresent([String: [String: String]].self, forKey: .photoDishes) ?? [:]
            photoSuggestions = try c.decodeIfPresent([String: [String: String]].self, forKey: .photoSuggestions) ?? [:]
            photoKinds = try c.decodeIfPresent([String: [String: DishNaming.Kind]].self, forKey: .photoKinds) ?? [:]
            photoRotations = try c.decodeIfPresent([String: Int].self, forKey: .photoRotations) ?? [:]
            rotationJudged = try c.decodeIfPresent(Set<String>.self, forKey: .rotationJudged) ?? []
            formOpened = try c.decodeIfPresent(Set<String>.self, forKey: .formOpened) ?? []
            autoConfirmed = try c.decodeIfPresent(Set<String>.self, forKey: .autoConfirmed) ?? []
            photoOrder = try c.decodeIfPresent([String: [String]].self, forKey: .photoOrder) ?? [:]
            notMeals = try c.decodeIfPresent(Set<String>.self, forKey: .notMeals) ?? []
            sureMeals = try c.decodeIfPresent(Set<String>.self, forKey: .sureMeals) ?? []
            posted = try c.decodeIfPresent([String: Date].self, forKey: .posted) ?? [:]
            likes = try c.decodeIfPresent([String: Set<String>].self, forKey: .likes) ?? [:]
            likedDishes = try c.decodeIfPresent([String: Set<String>].self, forKey: .likedDishes) ?? [:]
            tags = try c.decodeIfPresent([String: [String]].self, forKey: .tags) ?? [:]
            deepSearches = try c.decodeIfPresent([Date].self, forKey: .deepSearches) ?? []
            deepSearchNotes = try c.decodeIfPresent([String: String].self, forKey: .deepSearchNotes) ?? [:]
        }
    }
    private var memory = Memory()
    /// Restaurants open and close, so a cached answer is refreshed after this.
    private static let placeCacheLife: TimeInterval = 30 * 24 * 60 * 60

    private static func placeKey(_ c: CLLocationCoordinate2D) -> String {
        // "v7": photo counts came with the candidates. "v6": 150m radius. v4 was 150m with tiles, v1–v3 earlier shapes.
        String(format: "%@/v7:%.4f,%.4f", PlaceLookup.languageCode, c.latitude, c.longitude)
    }
    private static let memoryURL: URL = {
        AppData.folder.appendingPathComponent("memory.json")
    }()

    private func loadMemory() {
        guard let data = try? Data(contentsOf: Self.memoryURL) else { return }
        let stored: Memory
        do {
            stored = try JSONDecoder().decode(Memory.self, from: data)
        } catch {
            // Never carry on with an empty memory over a file that has
            // something in it: the next save would write the emptiness back.
            // One added field with no default on disk did exactly that
            // once and took dozens of confirmed places with it.
            let kept = Self.memoryURL.deletingLastPathComponent()
                .appendingPathComponent("memory-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: kept)
            print("[PhotoLibrary] memory.json did not decode (\(error)); kept a copy at \(kept.lastPathComponent)")
            Usage.local(tag: "memory 읽기 실패", detail: "\(error)".prefix(160).description, seconds: 0)
            refusesToSave = true
            return
        }
        // A version bump means the SCORES are stale — never the person's work.
        // Once, two bumps in a row threw away every confirmed place,
        // draft, note, like, rotation and posted mark in this file, because
        // this branch rebuilt Memory from `hidden` alone.
        memory = stored
        if stored.version != Memory.currentVersion {
            memory.version = Memory.currentVersion
            memory.foodScores = [:]
            memory.tableScores = [:]
            memory.peopleScores = [:]
            memory.scoredPixels = [:]
            memory.rawFoodScores = [:]
            memory.appleScores = [:]
            memory.mainlyFoodScores = [:]
            memory.iCloudTried = []
            print("[PhotoLibrary] memory: rescoring from version \(stored.version.map(String.init) ?? "1"); \(stored.confirmed.count) confirmed places kept")
        }
        posted = memory.posted
        likes = memory.likes
        likedDishes = memory.likedDishes
        photoRotations = memory.photoRotations
        formOpened = memory.formOpened
        notMeals = memory.notMeals
        sureMeals = memory.sureMeals
        tags = memory.tags
        deepSearchNote = memory.deepSearchNotes
        uncommitOldGuesses()
    }

    /// Once: guesses the namer wrote straight onto photos (the old way)
    /// go back to being suggestions, on visits still being worked on — a
    /// visit already posted or with a chosen draft keeps them, since the
    /// person went on with those names. Only names still exactly as guessed.
    private func uncommitOldGuesses() {
        let flag = "guessesUncommitted-2026-10-06"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        var moved = 0
        for (visitID, guesses) in memory.photoSuggestions {
            guard memory.posted[visitID] == nil, memory.drafts[visitID] == nil,
                  var names = memory.photoDishes[visitID] else { continue }
            for (photoID, guess) in guesses where names[photoID] == guess {
                names[photoID] = nil
                moved += 1
            }
            memory.photoDishes[visitID] = names
        }
        UserDefaults.standard.set(true, forKey: flag)
        if moved > 0 { saveMemory() }
        Usage.local(tag: "추측 되돌림", detail: "\(moved)장", seconds: 0)
    }

    /// Set when the file on disk could not be read. Saving then would replace
    /// what is there with whatever this launch happens to hold.
    private var refusesToSave = false

    private func saveMemory() {
        guard !refusesToSave else { return }
        let url = Self.memoryURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Library source

    func requestAccess() async {
        firstRunPreview = false
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        print("[PhotoLibrary] Photos access requested → \(status.rawValue) (3 = authorized, 2 = denied, 0 = not determined)")
        // macOS has no limited mode, but treat it as granted if it ever appears.
        access = (status == .authorized || status == .limited) ? .granted : .denied
        if access == .granted { await scanLibrary() }
    }

    func refreshAccess() {
        guard access != .folder else { return }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            access = .granted
            print("[PhotoLibrary] Photos access already granted")
            // Permission was granted on an earlier launch. Nothing else starts
            // the library scan, so without this the browser opens on zero
            // visits and stays there.
            if visits.isEmpty, !scanning { Task { await scanLibrary() } }
        case .notDetermined:
            access = .unknown
            print("[PhotoLibrary] Photos access not determined — first-run screen")
        default:
            access = .denied
            print("[PhotoLibrary] Photos access denied")
        }
    }

    func scanLibrary() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let options = PHFetchOptions()
        // Screenshots are never a meal — a screenshot of someone else's 우니
        // is not a visit. Photos knows which assets are screenshots, so they
        // never reach the classifier.
        // Videos count as well: a dish is often filmed rather than shot, and
        // Google's review form takes video. Screenshots and screen recordings
        // stay out — a screenshot of someone else's 우니 is not a visit.
        options.predicate = NSPredicate(
            format: "(mediaType == %d AND (mediaSubtypes & %d) == 0) OR (mediaType == %d AND (mediaSubtypes & %d) == 0)",
            PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue,
            PHAssetMediaType.video.rawValue, PHAssetMediaSubtype.videoScreenRecording.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched = PHAsset.fetchAssets(with: options)

        var photos: [Photo] = []
        var byIdentifier: [String: PHAsset] = [:]
        photos.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            guard let takenAt = asset.creationDate else { return }
            var photo = Photo(origin: .asset(asset.localIdentifier), takenAt: takenAt)
            photo.isVideo = asset.mediaType == .video
            photo.duration = asset.duration
            if let location = asset.location {
                photo.latitude = location.coordinate.latitude
                photo.longitude = location.coordinate.longitude
                photo.accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            }
            photos.append(photo)
            byIdentifier[asset.localIdentifier] = asset
        }
        assetsByIdentifier = byIdentifier
        total = photos.count
        let allImages = PHAsset.fetchAssets(with: .image, options: nil).count
        let allVideos = PHAsset.fetchAssets(with: .video, options: nil).count
        let videosRead = photos.filter(\.isVideo).count
        print("[PhotoLibrary] library: \(photos.count) items fetched — \(photos.count - videosRead) photos of \(allImages), \(videosRead) videos of \(allVideos); screenshots and screen recordings skipped")

        // The library path used to skip classification, so every photo with
        // GPS became a visit: thousands of photos turned into well over a
        // thousand "visits", most of
        // them not meals. Score what has not been scored, from the thumbnails
        // Photos already keeps, and remember the scores.
        loadMemory()
        PhotoExport.runIfAsked(Array(memory.foodScores.keys))
        let pending = photos.filter { memory.foodScores[$0.id] == nil }
        toClassify = pending.count
        classified = 0
        let scanStarted = Date()
        await classify(pending)
        if !pending.isEmpty {
            Usage.local(tag: "사진 훑기", detail: "\(pending.count)장", seconds: -scanStarted.timeIntervalSinceNow)
        }
        toClassify = 0
        applyScores(to: &photos)
        foodCount = photos.filter { $0.isFood }.count
        scanned = photos
        regroup()
        print("[PhotoLibrary] library: \(pending.count) newly scored, \(foodCount) food, \(visits.count) visits")
        let located = visits.filter { $0.coordinate != nil }
        let withFood = located.filter { $0.photos.contains(where: \.isFood) }.count
        let memories = located.filter { v in !v.photos.contains(where: \.isFood) && v.photos.contains(where: \.isMemory) }.count
        // Per year: photos read, food photos, visits — to see that old years
        // are in the scan at all.
        let calendar = Calendar.current
        let byYear = Dictionary(grouping: photos) { calendar.component(.year, from: $0.takenAt) }
        let visitYears = Dictionary(grouping: visits) { calendar.component(.year, from: $0.takenAt) }
        print("[PhotoLibrary] years: " + byYear.keys.sorted().map { year in
            "\(year) \(byYear[year]!.count)장/음식 \(byYear[year]!.filter(\.isFood).count)/방문 \(visitYears[year]?.count ?? 0)"
        }.joined(separator: ", "))
        print("[PhotoLibrary] tabs: food \(withFood), 추억 \(memories), 애매 \(located.count - withFood - memories), 위치 없음 \(visits.count - located.count)")
        Self.describe(visits.prefix(2))
        if let dir = ProcessInfo.processInfo.environment["AFTERPLATE_AUDIT"], !dir.isEmpty {
            Task { await auditVisits(into: URL(fileURLWithPath: dir)) }
        }
        Task { await prefetchPlaces() }
        Task { await sharpenSmallScores() }
        // Debug hook: AFTERPLATE_DAY=yyyy-MM-dd prints every photo of that day
        // with the two things grouping turns on — the gap since the photo
        // before it and its distance from the running group's centre — and
        // which visit it ended up in. For asking why one afternoon came out
        // as two visits instead of one.
        // Read from defaults, not the environment: the app is launched with
        // `open`, which passes none. `defaults write com.jinsukim.afterplate
        // DumpDay 2025-01-02` and the report lands in ~/Library/Application
        // Support/Afterplate/day-<date>.txt.
        if let day = ProcessInfo.processInfo.environment["AFTERPLATE_DAY"]
            ?? UserDefaults.standard.string(forKey: "DumpDay"), !day.isEmpty {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = .current
            if let start = parser.date(from: day) {
                let end = start.addingTimeInterval(24 * 3600)
                let stamp = DateFormatter()
                stamp.dateFormat = "HH:mm:ss"
                let ofDay = scanned.filter { $0.takenAt >= start && $0.takenAt < end }.sorted { $0.takenAt < $1.takenAt }
                var report = ["[Day] \(day): \(ofDay.count) photos, gap \(Int(visitGap / 60))분, spread \(Int(visitSpread))m"]
                print(report[0])
                var previous: Photo?
                for photo in ofDay {
                    let visit = visits.first { $0.photos.contains { $0.id == photo.id } }
                    let since = previous.map { Int(photo.takenAt.timeIntervalSince($0.takenAt)) } ?? 0
                    var apart = "—"
                    if let visit, let centre = Visit.centroid(of: visit.photos), let here = photo.coordinate {
                        let metres = CLLocation(latitude: here.latitude, longitude: here.longitude)
                            .distance(from: CLLocation(latitude: centre.latitude, longitude: centre.longitude))
                        apart = String(format: "%.0fm", metres)
                    }
                    let where_ = photo.coordinate.map { String(format: "[%.5f,%.5f]", $0.latitude, $0.longitude) } ?? "[no gps]"
                    let line = String(format: "  %@  +%4dm  %@ %@  food %.2f apple %.2f table %.2f  %@ → %@",
                                      stamp.string(from: photo.takenAt), since / 60, where_, apart,
                                      photo.foodScore, photo.appleScore, photo.tableScore,
                                      photo.isVideo ? "video" : "photo",
                                      visit.map { $0.title + " (\($0.photos.count)장)" } ?? "어느 방문에도 없음")
                    print(line)
                    report.append(line)
                    previous = photo
                }
                let out = Self.memoryURL.deletingLastPathComponent()
                    .appendingPathComponent("day-\(day).txt")
                try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                print("[Day] written to \(out.path)")
            }
        }
        // Debug hook: AFTERPLATE_MISSES=<dir> looks for food the app may have
        // lost: meal-ish photos that ended up in no visit (and why), and
        // photos scored 0 although some food label fired. Writes a TSV and a
        // 300px copy of each, for looking at. Nothing is saved to memory.
        if let dir = ProcessInfo.processInfo.environment["AFTERPLATE_MISSES"], !dir.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let root = URL(fileURLWithPath: dir)
                try? FileManager.default.createDirectory(at: root.appendingPathComponent("near"), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: root.appendingPathComponent("lost"), withIntermediateDirectories: true)
                var lines = ["kind\tid\tdate\tgps\tfood\ttable\tpeople\treason\tlabels"]
                let inVisit = Set(self.visits.flatMap { $0.photos.map(\.id) })
                let visible = self.scanned.filter { !self.memory.hidden.contains($0.id) }
                // Lost: meal-ish but in no visit.
                let lost = self.scanned.filter { $0.isMealish && !inVisit.contains($0.id) }
                for photo in lost {
                    let reason: String
                    if self.memory.hidden.contains(photo.id) { reason = "hidden by user" }
                    else {
                        let groups = Self.rawGroups(visible, gap: self.visitGap, spread: self.visitSpread,
                                                    splits: self.memory.splits, merges: self.memory.merges)
                        let g = groups.first { $0.contains { $0.id == photo.id } } ?? []
                        reason = g.count > 120 ? "group of \(g.count) > 120" : (g.count < 2 && !photo.hasLocation ? "alone without GPS" : "group of \(g.count)")
                    }
                    lines.append("lost\t\(photo.id)\t\(photo.takenAt)\t\(photo.hasLocation)\t\(photo.foodScore)\t\(photo.tableScore)\t\(photo.peopleScore)\t\(reason)\t")
                    if let jpeg = await self.reducedJPEG(for: photo, maxPixel: 300) {
                        try? jpeg.write(to: root.appendingPathComponent("lost").appendingPathComponent(photo.id.replacingOccurrences(of: "/", with: "_") + ".jpg"))
                    }
                }
                print("[Misses] lost: \(lost.count)")
                // Near: scored 0 but a food label reached 0.05.
                let zero = self.scanned.filter { !$0.isMealish }
                let assets = self.assetsByIdentifier
                var near = 0
                for chunk in stride(from: 0, to: zero.count, by: 8) {
                    let part = Array(zero[chunk..<min(chunk + 8, zero.count)])
                    let found = await withTaskGroup(of: (Photo, String)?.self) { group in
                        for photo in part {
                            group.addTask {
                                guard case .asset(let identifier) = photo.origin, let asset = assets[identifier],
                                      let image = await Self.classificationImage(asset, side: 640) else { return nil }
                                let request = VNClassifyImageRequest()
                                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                                let results = request.results ?? []
                                let top = results.filter { Self.foodIdentifiers.contains($0.identifier.lowercased()) }
                                    .map(\.confidence).max() ?? 0
                                guard top >= 0.05 else { return nil }
                                let labels = results.filter { $0.confidence >= 0.03 }.sorted { $0.confidence > $1.confidence }.prefix(14)
                                    .map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
                                return (photo, String(format: "%.2f\t", top) + labels)
                            }
                        }
                        var out: [(Photo, String)] = []
                        for await r in group { if let r { out.append(r) } }
                        return out
                    }
                    for (photo, info) in found {
                        near += 1
                        let parts = info.split(separator: "\t", maxSplits: 1).map(String.init)
                        lines.append("near\t\(photo.id)\t\(photo.takenAt)\t\(photo.hasLocation)\t\(parts[0])\t\(photo.tableScore)\t\(photo.peopleScore)\t\t\(parts.count > 1 ? parts[1] : "")")
                        if let jpeg = await self.reducedJPEG(for: photo, maxPixel: 300) {
                            try? jpeg.write(to: root.appendingPathComponent("near").appendingPathComponent(photo.id.replacingOccurrences(of: "/", with: "_") + ".jpg"))
                        }
                    }
                }
                try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("misses.tsv"), atomically: true, encoding: .utf8)
                print("[Misses] near: \(near) of \(zero.count) zero-scored → \(root.path)")
            }
        }
        // Debug hook: AFTERPLATE_EXPORT_ALL=<dir> writes every scanned photo
        // as the classifier sees it (local 640px, 320 fallback) plus a TSV of
        // its Vision scores, place, time, visit and the person's verdicts —
        // for comparing the Vision rules with another model offline.
        if let dir = ProcessInfo.processInfo.environment["AFTERPLATE_EXPORT_ALL"], !dir.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let root = URL(fileURLWithPath: dir)
                let images = root.appendingPathComponent("img")
                try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                var visitOf: [String: Visit] = [:]
                for v in self.visits { for p in v.photos { visitOf[p.id] = v } }
                let tab: (Visit) -> String = { v in
                    if self.notMeals.contains(v.id) { return "notMeal" }
                    if v.coordinate == nil { return "noGPS" }
                    if v.photos.contains(where: \.isFood) { return "food" }
                    if self.sureMeals.contains(v.id) { return "sureMeal" }
                    return v.photos.contains(where: \.isMemory) ? "memory" : "unsure"
                }
                var lines = ["file\tid\ttime\tlat\tlon\tfood\traw\tapple\tmainly\ttable\tpeople\thidden\tvisit\ttab\tsure\tnot"]
                let photos = self.scanned
                let assets = self.assetsByIdentifier
                let start = Date()
                var written = 0
                for chunk in stride(from: 0, to: photos.count, by: 8) {
                    let part = Array(photos[chunk..<min(chunk + 8, photos.count)])
                    let done = await withTaskGroup(of: (Photo, String?).self) { group in
                        for (offset, photo) in part.enumerated() {
                            let name = String(format: "%05d.jpg", chunk + offset)
                            group.addTask {
                                guard case .asset(let identifier) = photo.origin, let asset = assets[identifier] else { return (photo, nil) }
                                var image = await Self.classificationImage(asset, side: 640)
                                if image == nil { image = await Self.classificationImage(asset, side: 320) }
                                guard let image,
                                      let dest = CGImageDestinationCreateWithURL(images.appendingPathComponent(name) as CFURL, "public.jpeg" as CFString, 1, nil) else { return (photo, nil) }
                                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                                return (photo, CGImageDestinationFinalize(dest) ? name : nil)
                            }
                        }
                        var out: [(Photo, String?)] = []
                        for await r in group { out.append(r) }
                        return out
                    }
                    for (photo, name) in done {
                        let v = visitOf[photo.id]
                        written += name == nil ? 0 : 1
                        var fields: [String] = [name ?? "", photo.id, String(photo.takenAt.timeIntervalSince1970)]
                        fields.append(photo.latitude.map { String($0) } ?? "")
                        fields.append(photo.longitude.map { String($0) } ?? "")
                        fields.append(String(photo.foodScore))
                        fields.append(String(photo.rawFoodScore))
                        fields.append(String(photo.appleScore))
                        fields.append(String(photo.mainlyFoodScore))
                        fields.append(String(photo.tableScore))
                        fields.append(String(photo.peopleScore))
                        fields.append(self.memory.hidden.contains(photo.id) ? "1" : "0")
                        fields.append(v?.id ?? "")
                        fields.append(v.map(tab) ?? "")
                        let sure: Bool = v.map { self.sureMeals.contains($0.id) } ?? false
                        let not: Bool = v.map { self.notMeals.contains($0.id) } ?? false
                        fields.append(sure ? "1" : "0")
                        fields.append(not ? "1" : "0")
                        lines.append(fields.joined(separator: "\t"))
                    }
                }
                try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("photos.tsv"), atomically: true, encoding: .utf8)
                print(String(format: "[ExportAll] %d of %d photos written in %.0fs → %@", written, photos.count, Date().timeIntervalSince(start), root.path))
            }
        }
        // Debug hook: AFTERPLATE_BENCH=<n> times the whole classify path
        // (PhotoKit render + Vision + OCR where it applies) on n photos at
        // 320px and at 640px, four at a time like the real scan. Nothing is saved.
        if let n = Int(ProcessInfo.processInfo.environment["AFTERPLATE_BENCH"] ?? ""), n > 0 {
            let assets = Array(assetsByIdentifier.values.shuffled().prefix(n))
            Task.detached {
                for side in [640, 320, 640, 320] as [CGFloat] {
                    let start = Date()
                    let got = await withTaskGroup(of: (Bool, Bool).self) { group -> (Int, Int) in
                        var next = 0, ok = 0, ocr = 0
                        func enqueue() {
                            guard next < assets.count else { return }
                            let asset = assets[next]; next += 1
                            group.addTask {
                                guard let image = await Self.classificationImage(asset, side: side) else { return (false, false) }
                                let scored = Self.scores(of: image)
                                var read = false
                                if scored.food > 0, !scored.byTable { _ = Self.textBesideSubject(image); read = true }
                                return (true, read)
                            }
                        }
                        for _ in 0..<4 { enqueue() }
                        for await (done, read) in group {
                            if done { ok += 1 }
                            if read { ocr += 1 }
                            enqueue()
                        }
                        return (ok, ocr)
                    }
                    let seconds = Date().timeIntervalSince(start)
                    print(String(format: "[bench] %.0fpx: %d photos (%d scored, %d OCR) in %.1fs → %.1f ms each",
                                 side, assets.count, got.0, got.1, seconds, seconds * 1000 / Double(assets.count)))
                }
            }
        }
        // Debug hook: AFTERPLATE_SIZES=1 asks every photo for its 640px
        // rendition and counts what size actually comes back, then times an
        // iCloud fetch for a few of the short ones. Nothing is saved.
        if ProcessInfo.processInfo.environment["AFTERPLATE_SIZES"] != nil {
            let assets = Array(assetsByIdentifier.values)
            Task.detached {
                var buckets: [String: Int] = [:]
                var short: [PHAsset] = []
                for chunk in stride(from: 0, to: assets.count, by: 8) {
                    let part = Array(assets[chunk..<min(chunk + 8, assets.count)])
                    let sizes = await withTaskGroup(of: (PHAsset, Int).self) { group in
                        for a in part { group.addTask { (a, await Self.classificationImage(a, side: 640).map { max($0.width, $0.height) } ?? 0) } }
                        var out: [(PHAsset, Int)] = []
                        for await r in group { out.append(r) }
                        return out
                    }
                    for (a, px) in sizes {
                        let key = px == 0 ? "none" : px >= 600 ? "640" : px >= 400 ? "400-599" : "200-399"
                        buckets[key, default: 0] += 1
                        if px < 600 { short.append(a) }
                    }
                }
                print("[sizes] \(assets.count) photos asked at 640: \(buckets.sorted { $0.key < $1.key })")
                let sample = Array(short.shuffled().prefix(40))
                let start = Date()
                var got: [String: Int] = [:]
                for a in sample {
                    let px = await Self.classificationImage(a, side: 640, network: true).map { max($0.width, $0.height) } ?? 0
                    got[px >= 600 ? "640" : "\(px)", default: 0] += 1
                }
                print(String(format: "[sizes] iCloud fetch of %d short photos: %.1fs, sizes %@", sample.count, Date().timeIntervalSince(start), "\(got)"))
            }
        }
        // One-time recovery: AFTERPLATE_RESTORE=<json> puts back what a
        // memory-version bump once threw away, read out of the app's
        // own log — the confirmed place, the dish names and the drafts.
        if let path = ProcessInfo.processInfo.environment["AFTERPLATE_RESTORE"], !path.isEmpty {
            Task { await restore(from: URL(fileURLWithPath: path)) }
        }
        // Debug hook: AFTERPLATE_UNSURE=<dir> writes every photo of the visits
        // in "이게 밥인가?" (located, no food, not a 추억) with their labels.
        if let dir = ProcessInfo.processInfo.environment["AFTERPLATE_UNSURE"], !dir.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let root = URL(fileURLWithPath: dir)
                var lines = ["verdict\tvisit\tfolder\tphoto\traw\ttable\tpeople\tlabels"]
                let unsure = self.visits.filter { v in
                    v.coordinate != nil && !v.photos.contains(where: \.isFood) && !v.photos.contains(where: \.isMemory)
                }
                for (number, visit) in unsure.enumerated() {
                    let verdict = self.sureMeals.contains(visit.id) ? "meal" : (self.notMeals.contains(visit.id) ? "not" : "unmarked")
                    let name = String(format: "%@-%03d", verdict, number)
                    let folder = root.appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (index, photo) in visit.photos.enumerated() {
                        guard case .asset(let identifier) = photo.origin,
                              let asset = self.assetsByIdentifier[identifier],
                              let image = await Self.classificationImage(asset, side: 640, network: true) else { continue }
                        let request = VNClassifyImageRequest()
                        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        let labels = (request.results ?? []).filter { $0.confidence >= 0.01 }
                            .sorted { $0.confidence > $1.confidence }.prefix(60)
                            .map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
                        if let jpeg = await self.reducedJPEG(for: photo, maxPixel: 480) {
                            try? jpeg.write(to: folder.appendingPathComponent(String(format: "%02d.jpg", index + 1)))
                        }
                        lines.append("\(verdict)\t\(visit.fullTitle)\t\(name)\t\(index + 1)\t\(photo.rawFoodScore)\t\(photo.tableScore)\t\(photo.peopleScore)\t\(labels)")
                    }
                }
                try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("unsure.tsv"), atomically: true, encoding: .utf8)
                print("[Unsure] written: \(unsure.count) visits")
            }
        }
        // Debug hook: AFTERPLATE_VERDICTS=<dir> writes every photo of the
        // visits the person judged ("밥 아님" / "밥 맞음") with Vision's labels,
        // for working out what the rules got wrong.
        if let dir = ProcessInfo.processInfo.environment["AFTERPLATE_VERDICTS"], !dir.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let root = URL(fileURLWithPath: dir)
                var lines = ["verdict\tvisit\tid\tphoto\tfood\ttable\tpeople\tpixels\tlabels"]
                for (verdict, ids) in [("not", self.notMeals), ("sure", self.sureMeals)] {
                    for visit in self.visits where ids.contains(visit.id) {
                        let folder = root.appendingPathComponent(verdict).appendingPathComponent(visit.title.replacingOccurrences(of: " ", with: "_"))
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        for (index, photo) in visit.photos.enumerated() {
                            guard case .asset(let identifier) = photo.origin,
                                  let asset = self.assetsByIdentifier[identifier],
                                  let image = await Self.classificationImage(asset, side: 640, network: true) else { continue }
                            let request = VNClassifyImageRequest()
                            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                            let labels = (request.results ?? []).filter { $0.confidence >= 0.02 }
                                .sorted { $0.confidence > $1.confidence }.prefix(20)
                                .map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
                            if let jpeg = await self.reducedJPEG(for: photo, maxPixel: 480) {
                                try? jpeg.write(to: folder.appendingPathComponent(String(format: "%02d.jpg", index + 1)))
                            }
                            lines.append("\(verdict)\t\(visit.fullTitle)\t\(visit.id)\t\(index + 1)\t\(String(format: "%.2f", photo.foodScore))\t\(String(format: "%.2f", photo.tableScore))\t\(String(format: "%.2f", photo.peopleScore))\t\(self.memory.scoredPixels[photo.id] ?? 0)\t\(labels)")
                        }
                    }
                }
                try? lines.joined(separator: "\n").write(to: root.appendingPathComponent("verdicts.tsv"), atomically: true, encoding: .utf8)
                print("[Verdicts] written: \(lines.count - 1) photos → \(root.path)")
            }
        }
        // Debug hook: AFTERPLATE_LABELS=<visit title> logs every label Vision
        // returns for each photo of that visit, at the size the app scores.
        if let title = ProcessInfo.processInfo.environment["AFTERPLATE_LABELS"], !title.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let dir = ProcessInfo.processInfo.environment["AFTERPLATE_LABELS_DIR"]
                for visit in self.visits where visit.title == title {
                    print("[Labels] \(visit.title): \(visit.photos.count) photos")
                    for (index, photo) in visit.photos.enumerated() {
                        let size = CGFloat(Double(ProcessInfo.processInfo.environment["AFTERPLATE_LABELS_SIZE"] ?? "") ?? 600)
                        if let dir, let jpeg = await self.reducedJPEG(for: photo, maxPixel: size) {
                            let file = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%@-%02d.jpg", title.replacingOccurrences(of: " ", with: "_"), index + 1))
                            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
                            try? jpeg.write(to: file)
                        }
                        guard case .asset(let identifier) = photo.origin,
                              let asset = self.assetsByIdentifier[identifier],
                              let image = await Self.classificationImage(asset, side: 320) else { continue }
                        let request = VNClassifyImageRequest()
                        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        let all = (request.results ?? []).filter { $0.confidence >= 0.01 }
                            .sorted { $0.confidence > $1.confidence }
                        print("[Labels] \(index + 1)/\(visit.photos.count) food \(String(format: "%.2f", photo.foodScore)) table \(String(format: "%.2f", photo.tableScore)): "
                              + all.map { "\($0.identifier)=\(String(format: "%.3f", $0.confidence))" }.joined(separator: ", "))
                    }
                }
            }
        }
        // Debug hook: AFTERPLATE_SHOW=<photo id>[|<out.jpg>] writes that photo
        // out and logs what Vision makes of it.
        if let arg = ProcessInfo.processInfo.environment["AFTERPLATE_SHOW"], !arg.isEmpty {
            Task { [weak self] in
                let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
                let id = parts[0]
                let out = parts.count > 1 ? parts[1] : NSTemporaryDirectory() + "afterplate-show.jpg"
                guard let self, let photo = self.scanned.first(where: { $0.id == id }) else {
                    print("[Show] \(id): not in the library"); return
                }
                if let jpeg = await self.reducedJPEG(for: photo, maxPixel: 640) {
                    try? jpeg.write(to: URL(fileURLWithPath: out))
                    print("[Show] \(id) → \(out), taken \(photo.takenAt), food \(photo.foodScore), table \(photo.tableScore)")
                    if let visit = self.visits.first(where: { $0.photos.contains(where: { $0.id == id }) }) {
                        print("[Show] visit: \(visit.title), \(visit.photos.count) photos")
                    }
                } else {
                    print("[Show] \(id): could not render")
                }
            }
        }
        // Test hook: AFTERPLATE_TEST_MATCH=<visit title> re-runs the place
        // match for that visit and logs it.
        if let title = ProcessInfo.processInfo.environment["AFTERPLATE_TEST_MATCH"], !title.isEmpty {
            Task {
                for visit in visits where visit.title == title {
                    await lookupPlace(for: visit)
                    await rematchPlace(for: visit)
                }
            }
        }
    }



    /// Debug: for every visit, its best-scoring photo as a small JPEG named
    /// by score, plus a TSV of the Vision labels behind that score — to judge
    /// which "food" visits are really people or rooms.
    private func auditVisits(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows = ["index\tvisit\tphotos\tfoodPhotos\tbest\tlabels"]
        for (index, visit) in visits.enumerated() {
            guard let best = visit.photos.max(by: { $0.foodScore < $1.foodScore }) else { continue }
            let foodPhotos = visit.photos.filter { $0.isFood }.count
            guard let image = await thumbnail(for: best, side: 160),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            let labels = (request.results ?? [])
                .filter { $0.hasMinimumRecall(0.5, forPrecision: 0.3) && $0.confidence > 0.1 }
                .prefix(6).map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
            if ProcessInfo.processInfo.environment["AFTERPLATE_AUDIT_ALL"] != nil {
                let folder = dir.appendingPathComponent(String(format: "%03d", index), isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (n, photo) in visit.photos.enumerated() {
                    guard let shot = await thumbnail(for: photo, side: 160),
                          let cgShot = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                    let rep = NSBitmapImageRep(cgImage: cgShot)
                    let file = String(format: "%02d_%.2f.jpg", n, photo.foodScore)
                    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: folder.appendingPathComponent(file))
                }
            }
            let name = String(format: "%03d_%.2f_%d-of-%d.jpg", index, best.foodScore, foodPhotos, visit.photos.count)
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: dir.appendingPathComponent(name))
            rows.append("\(index)\t\(visit.title)\t\(visit.photos.count)\t\(foodPhotos)\t\(String(format: "%.2f", best.foodScore))\t\(labels)")
        }
        try? rows.joined(separator: "\n").write(to: dir.appendingPathComponent("audit.tsv"), atomically: true, encoding: .utf8)
        print("[PhotoLibrary] audit written: \(rows.count - 1) visits → \(dir.path)")
    }

    /// Scores library assets a few at a time off the main actor. Saves every
    /// so often so a quit half-way keeps what was done. An asset whose
    /// thumbnail is not available locally is left unscored and retried next
    /// launch rather than remembered as "not food".
    private func applyScores(to photos: inout [Photo]) {
        for index in photos.indices {
            photos[index].foodScore = memory.foodScores[photos[index].id] ?? 0
            photos[index].tableScore = memory.tableScores[photos[index].id] ?? 0
            photos[index].peopleScore = memory.peopleScores[photos[index].id] ?? 0
            photos[index].rawFoodScore = memory.rawFoodScores[photos[index].id] ?? 0
            photos[index].appleScore = memory.appleScores[photos[index].id] ?? 0
            photos[index].mainlyFoodScore = memory.mainlyFoodScores[photos[index].id] ?? 0
        }
    }

    /// The first pass stays local so the list shows up in under a minute,
    /// and about one photo in six came back smaller than 640px there — the
    /// size
    /// where a dim steak dropped out of "food" before. After the list is up,
    /// fetch those from iCloud (about 1.5s each) and score them again.
    private func sharpenSmallScores() async {
        guard !assetsByIdentifier.isEmpty, !sharpening else { return }
        sharpening = true
        defer { sharpening = false }
        // Scores from before sizes were recorded: look again locally first;
        // most were taken at 640 and only get their size written down.
        let unknown = scanned.filter { memory.foodScores[$0.id] != nil && memory.scoredPixels[$0.id] == nil }
        if !unknown.isEmpty { await classify(unknown) }
        // A photo whose original is itself small cannot be fetched bigger.
        let small = scanned.filter { photo in
            guard (memory.scoredPixels[photo.id] ?? 0) < 600, memory.foodScores[photo.id] != nil,
                  !memory.iCloudTried.contains(photo.id),
                  case .asset(let identifier) = photo.origin,
                  let asset = assetsByIdentifier[identifier] else { return false }
            return max(asset.pixelWidth, asset.pixelHeight) >= 600
        }
        guard !small.isEmpty else { return }
        let before = Set(scanned.filter(\.isMealish).map(\.id))
        toSharpen = small.count
        sharpened = 0
        await classify(small, fromICloud: true)
        toSharpen = 0
        applyScores(to: &scanned)
        foodCount = scanned.filter { $0.isFood }.count
        regroup()
        let after = Set(scanned.filter(\.isMealish).map(\.id))
        print("[PhotoLibrary] sharpen: \(small.count) small photos rescored from iCloud; \(after.subtracting(before).count) now meal-ish, \(before.subtracting(after).count) no longer")
    }

    private func classify(_ pending: [Photo], fromICloud: Bool = false) async {
        // 640, not 320: a dim steak scored food 0.08 at 320px and 0.29 at
        // 640 (0.27 at full size) — at 320 the dish is a smear and the
        // plates and cutlery win. 640 is where the score stops moving.
        let side: CGFloat = 640
        // iCloud fetches mostly wait on the network, so run more at once.
        let width = fromICloud ? 8 : 4
        // Resolve assets up front: the task group's nested function is not
        // main-actor isolated and may not touch assetsByIdentifier.
        let byIdentifier = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var stack: [Photo] = []
        let jobs: [(identifier: String, asset: PHAsset)] = pending.compactMap { photo in
            guard case .asset(let identifier) = photo.origin,
                  let asset = assetsByIdentifier[identifier] else { return nil }
            return (identifier, asset)
        }
        var next = 0
        var done = 0
        var unavailable = 0
        await withTaskGroup(of: (String, Scores?, Int).self) { group in
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask { [asset = job.asset, identifier = job.identifier] in
                    // A photo kept only in iCloud may have no local 640px
                    // rendition (about one in six); its smaller one still
                    // beats leaving it unscored.
                    var image = await Self.classificationImage(asset, side: side, network: fromICloud)
                    if image == nil, !fromICloud { image = await Self.classificationImage(asset, side: 320) }
                    let pixels = image.map { max($0.width, $0.height) } ?? 0
                    guard let image else { return (identifier, nil, pixels) }
                    var scored = Self.scores(of: image)
                    // A food label beside a block of text is a printed dish —
                    // a menu board, a tablet menu, a poster. Only these few
                    // photos are read, at a size OCR can use.
                    if scored.food > 0, !scored.byTable,
                       Self.textBesideSubject(image) >= 0.08 {
                        scored.food = 0
                    }
                    if let verdict = AppleClassifier.score(image, people: scored.people) {
                        scored.apple = verdict.apple
                        scored.mainlyFood = verdict.mainlyFood
                    }
                    return (identifier, scored, pixels)
                }
            }
            for _ in 0..<width { enqueue() }
            for await (identifier, score, pixels) in group {
                if let score {
                    memory.foodScores[identifier] = score.food
                    memory.tableScores[identifier] = score.table
                    memory.peopleScores[identifier] = score.people
                    memory.scoredPixels[identifier] = pixels
                    memory.rawFoodScores[identifier] = score.raw
                    memory.appleScores[identifier] = score.apple
                    memory.mainlyFoodScores[identifier] = score.mainlyFood
                    if fromICloud { memory.iCloudTried.insert(identifier) }
                    if !fromICloud, score.food > 0 || (score.apple >= AppleClassifier.threshold && score.mainlyFood >= AppleClassifier.threshold),
                       let photo = byIdentifier[identifier] {
                        foundWhileScanning(photo, in: &stack)
                    }
                } else { unavailable += 1 }
                done += 1
                if done <= 5 { print("[PhotoLibrary] classify sample: \(pixels)px → \(score.map { String(format: "food %.2f table %.2f apple %.2f mainly %.2f", $0.food, $0.table, $0.apple, $0.mainlyFood) } ?? "unavailable")") }
                if done % 20 == 0 { if fromICloud { sharpened = done } else { classified = done } }
                if done % 500 == 0 { saveMemory() }
                enqueue()
            }
        }
        if !fromICloud { classified = done; flushScanGroup(&stack) }
        saveMemory()
        let food = memory.foodScores.values.filter { $0 > 0 }.count
        print("[PhotoLibrary] classify: \(done) requested, \(unavailable) unavailable, \(food) food in memory")
    }

    /// Food photos found close together in time go onto the canvas as one
    /// stack, up to three. After most stacks, at random, a stamp follows:
    /// where they were taken (the city, and the country's flag), when (said a
    /// different way each time), or a short line with an emoji. A date under
    /// every stack was too much, and dates alone in one format were dull; a
    /// stamp after fewer than half the stacks was too few.
    /// The short lines not yet used this run; none comes twice.
    private lazy var cheersLeft = ScanCheers.all.shuffled()
    /// The country of the last place stamp: its flag shows only when this
    /// changes.
    private var lastStampCountry: String?

    private func foundWhileScanning(_ photo: Photo, in group: inout [Photo]) {
        if let last = group.last, abs(photo.takenAt.timeIntervalSince(last.takenAt)) > 2 * 3600 || group.count >= 3 {
            flushScanGroup(&group)
        }
        group.append(photo)
    }

    private func flushScanGroup(_ group: inout [Photo]) {
        guard let first = group.first else { return }
        scanFinds.append(Prefetcher.Find(visit: first.id, kind: .photos(group)))
        group = []
        trimScanFinds()
        guard Double.random(in: 0..<1) < 0.6 else { return }
        let roll = Double.random(in: 0..<1)
        if roll < 0.4, let at = first.coordinate {
            // The geocoder is throttled in bursts; one lookup per stamp is
            // well under it, and a known cell needs none.
            Task {
                guard let name = await VisitCity.name(at: at) else { return }
                stamp(placeWord(name), for: first)
            }
        } else if roll < 0.7 {
            stamp(Self.dayWord(first.takenAt), for: first)
        } else if let line = cheersLeft.popLast() {
            stamp(line, for: first)
        } else {
            stamp(Self.dayWord(first.takenAt), for: first)
        }
    }

    private func stamp(_ word: String, for photo: Photo) {
        guard !word.isEmpty else { return }
        scanFinds.append(Prefetcher.Find(visit: photo.id, kind: .stamp(word)))
        trimScanFinds()
    }

    private func trimScanFinds() {
        if scanFinds.count > 40 { scanFinds.removeFirst(scanFinds.count - 40) }
    }

    /// "서울특별시, 대한민국" → 서울, with 🇰🇷 when the country is not the
    /// one the last place stamp was in. The country is only ever its flag.
    /// The geocoder gives some towns only in their own script ("Διβαράτα");
    /// in the Korean app those are the flag alone, or nothing.
    private func placeWord(_ name: String) -> String {
        let parts = name.components(separatedBy: ", ")
        let country = parts.count > 1 ? parts[parts.count - 1] : nil
        let flag = country.flatMap { $0 == lastStampCountry ? nil : Self.flag(of: $0) }
        if let country { lastStampCountry = country }
        var city = parts[0]
        // 서울특별시 → 서울, 후쿠오카시 → 후쿠오카, 양평군 → 양평; a name
        // that would be one letter keeps its ending (중구).
        if let suffix = ["특별자치시", "특별자치도", "특별시", "광역시", "시", "구", "군"].first(where: { city.hasSuffix($0) }),
           city.count > suffix.count + 1 {
            city = String(city.dropLast(suffix.count))
        }
        let cityReads = AppLanguage.current.isEnglish
            || city.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        guard cityReads else { return flag.map { [$0, "✈️ " + $0].randomElement() ?? $0 } ?? "" }
        guard let flag else { return ["📍 " + city, city].randomElement() ?? city }
        return [city + " " + flag, flag + " " + city].randomElement() ?? city
    }

    /// A country's flag from its name as the geocoder writes it, in Korean
    /// or English ("미 합중국" is its Korean for the United States).
    private static let regionCodes: [String: String] = {
        var codes = ["미 합중국": "US"]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            for language in ["ko_KR", "en_US"] {
                if let name = Locale(identifier: language).localizedString(forRegionCode: region.identifier) {
                    codes[name] = region.identifier
                }
            }
        }
        return codes
    }()

    private static func flag(of country: String) -> String? {
        guard let code = regionCodes[country] else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }

    /// The day, said one of several ways.
    private static func dayWord(_ date: Date) -> String {
        let month = Calendar.current.component(.month, from: date)
        let hour = Calendar.current.component(.hour, from: date)
        let season: String = switch month {
        case 3...5: String(localized: "봄")
        case 6...8: String(localized: "여름")
        case 9...11: String(localized: "가을")
        default: String(localized: "겨울")
        }
        let meal: String = switch hour {
        case 5..<11: String(localized: "아침")
        case 11..<15: String(localized: "점심")
        case 15..<17: String(localized: "간식")
        case 17..<22: String(localized: "저녁")
        default: String(localized: "야식")
        }
        // In the app's language, not the Mac's, like every other date here.
        let locale = Locale(identifier: AppLanguage.current.isEnglish ? "en_US" : "ko_KR")
        let year = date.formatted(.dateTime.year().locale(locale))
        let weekday = date.formatted(.dateTime.weekday(.wide).locale(locale))
        return [
            date.formatted(.dateTime.year().month().day().locale(locale)),
            date.formatted(.dateTime.month().day().locale(locale)),
            String(localized: "\(year) \(season)"),
            String(localized: "\(weekday) \(meal)"),
            date.formatted(.dateTime.year().month().locale(locale)),
            "🗓️ " + year,
        ].randomElement() ?? year
    }

    /// The image the classifier sees. 320px looked enough on bright,
    /// close-up food (within 0.04 of full size) but not on a dim restaurant
    /// table, where it lost the dish entirely; 640px tracks full size.
    /// 64px scores 0.
    /// `.fastFormat` handed back placeholders that small and 5,447 of the
    /// first 5,500 photos scored exactly 0, so ask for quality, stay local,
    /// and refuse anything under 200px rather than remember it as "not food".
    nonisolated private static func classificationImage(_ asset: PHAsset, side: CGFloat, network: Bool = false) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = network
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      max(cgImage.width, cgImage.height) >= 200 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: cgImage)
            }
        }
    }

    // MARK: - Folder source

    func chooseFolder() {
        firstRunPreview = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "이 폴더 읽기")
        panel.message = String(localized: "음식 사진이 들어 있는 폴더를 고르세요. 하위 폴더까지 함께 읽습니다.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await scanFolder(url) }
    }

    func scanFolder(_ root: URL) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]
        let found: [Photo] = await Task.detached(priority: .userInitiated) {
            Self.collectPhotos(in: root, extensions: extensions)
        }.value
        total = found.count
        let photos: [Photo] = await Task.detached(priority: .userInitiated) {
            found.map(Self.inspect)
        }.value

        assetsByIdentifier = [:]
        access = .folder
        folderName = root.lastPathComponent
        foodCount = photos.filter { $0.isFood }.count
        loadMemory()
        scanned = photos
        regroup()
    }

    nonisolated private static func collectPhotos(in root: URL, extensions: Set<String>) -> [Photo] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [Photo] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(Photo(origin: .file(url), takenAt: captureDate(of: url)))
        }
        return found.sorted { $0.takenAt < $1.takenAt }
    }

    /// EXIF capture time when the file has one; the file's own date otherwise —
    /// copied and exported files often lose EXIF, and a wrong-but-ordered date
    /// still groups a meal correctly.
    nonisolated private static func captureDate(of url: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: original) { return date }
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    // MARK: - Grouping

    /// Classify and read location for a batch of files, off the main actor.
    nonisolated static func inspect(_ photo: Photo) -> Photo {
        guard case .file(let url) = photo.origin else { return photo }
        var updated = photo
        var scored = scores(of: url)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            if let verdict = AppleClassifier.score(image, people: scored.people) {
                scored.apple = verdict.apple
                scored.mainlyFood = verdict.mainlyFood
            }
        }
        updated.foodScore = scored.food
        updated.appleScore = scored.apple
        updated.mainlyFoodScore = scored.mainlyFood
        updated.tableScore = scored.table
        updated.peopleScore = scored.people
        updated.rawFoodScore = scored.raw
        (updated.latitude, updated.longitude) = coordinate(of: url)
        return updated
    }

    /// Every food and drink label in Vision's taxonomy (of its 1,303) —
    /// except "liquid", which Vision puts at 0.96 on the sea, a lake, a pool
    /// and snow, and which turned forty holiday visits into meals.
    /// Otherwise: every food and drink label in Vision's taxonomy,
    /// not a hand-written handful — a dish may come back as "sushi",
    /// "spaghetti", "roe" or nothing more specific than "food". Whole names
    /// only: matching by substring made "license_plate" a plate and
    /// "rice_field" rice.
    nonisolated private static let foodIdentifiers: Set<String> = [
        "baked_goods",
        "acorn", "almond", "anchovy", "apple", "avocado", "bacon", "bagel", "banana",
        "bean", "beef", "beer", "berry", "birthday_cake", "biscuit", "blackberry", "blueberry",
        "bread", "broccoli", "bubble_tea", "burrito", "butter", "cake", "cake_regular", "candy",
        "candy_cane", "candy_other", "carrot", "cereal", "cheese", "cheesecake", "chocolate", "chocolate_chip",
        "citrus_fruit", "clam", "cocktail", "coffee", "coffee_bean", "condiment", "cookie", "corn",
        "crab", "cranberry", "croissant", "cucumber", "cupcake", "curry", "dessert", "donut",
        "drink", "dumpling", "egg", "eggplant", "fish", "food", "fried_chicken", "fried_egg",
        "fries", "frozen_dessert", "fruit", "fruitcake", "garlic", "gingerbread", "grape", "grapefruit",
        "green_beans", "grilled_chicken", "ham", "hamburger", "herb", "honey", "honeydew", "ice_cream",
        "juice", "kebab", "kiwi", "lemon", "lemongrass", "lettuce", "lime",
        "liquor", "lobster", "mango", "mangosteen", "margarita", "martini", "meat", "meatball",
        "melon", "milkshake", "mojito", "muffin", "mushroom", "mussel", "oatmeal", "onion",
        "oranges", "oyster", "paella", "pancake", "passionfruit", "pasta", "pastry", "peach",
        "peanut", "pear", "pepper_veggie", "pie", "pierogi", "pineapple", "pizza", "popcorn",
        "potato", "pudding", "pumpkin", "radish", "ramen", "raspberry", "red_wine", "rice",
        "risotto", "roe", "salad", "salmon", "sandwich", "sardine", "sausage", "scallop",
        "scone", "scrambled_eggs", "seafood", "seasonings", "shellfish", "shellfish_prepared", "smoothie", "soda",
        "soup", "spaghetti", "spareribs", "sparkling_wine", "spice", "spinach", "starfruit", "steak",
        "strawberry", "sugar_cube", "sushi", "taco", "tapioca_pearls", "tea_drink", "tomato", "tuna",
        "vegetable", "waffle", "watermelon", "wedding_cake", "white_bread", "white_wine", "wine", "yogurt",
    ]

    /// What owns the frame when a photo is not a meal: art in a gallery, a
    /// forest, a page of a book, a shop sign, a bottle on a shelf, a stage.
    /// Vision is confident about these while the food label flickers at 0.05
    /// — a sunscreen bottle read as "drink 0.16" with "bottle 0.83" over it,
    /// an orange hoodie in a dark room as "pumpkin 0.12" under "people 0.57",
    /// a lit-up building as "easter_egg 0.05" under "ball 0.12".
    nonisolated private static let notAMealIdentifiers: Set<String> = [
        "aircraft", "amusement_park", "animal", "apartment", "appliance", "arch", "art", "automobile",
        "backpack", "balloon", "banner", "beach", "beanie", "bicycle", "billboards", "bird",
        "blue_sky", "book", "bookshelf", "bottle", "bridge", "building", "bus", "canyon",
        "car", "carton", "casino", "cat", "cello", "chandelier", "christmas_decoration", "christmas_tree",
        "clothing", "cloudy", "computer", "consumer_electronics", "container", "daisy", "decorative_plant", "desert",
        "diorama", "disco_ball", "document", "dog", "doll", "door", "drum", "elevator",
        "entertainer", "escalator", "eucalyptus_tree", "eyeglasses", "fence", "ferris_wheel", "figurine", "flower",
        "flower_arrangement", "foliage", "footwear", "forest", "fountain", "frame", "garden", "graffiti",
        "grass", "guitar", "hammer", "handwriting", "hat", "headgear", "hill", "hoodie",
        "illustrations", "island", "jack_o_lantern", "jacket", "jar", "jeans", "jewelry", "lake",
        "land", "laptop", "luggage", "machine", "magazine", "maple_tree", "microphone", "motorcycle",
        "mountain", "museum", "music", "musical_instrument", "newspaper", "night_sky", "oak_tree", "ocean",
        "painting", "palm_tree", "park", "parking_lot", "path", "performance", "phone", "piano",
        "plant", "portal", "printed_page", "purse", "raw_glass", "receipt", "recreation", "river",
        "rocks", "rose", "sand", "sand_dune", "sandal", "screenshot", "screwdriver", "shoes",
        "sign", "singer", "sky", "skyscraper", "sneaker", "snow", "sport", "spotlight",
        "stained_glass", "stairs", "statue", "sticky_note", "storefront", "street", "street_sign", "string_instrument",
        "suit", "sunflower", "sunglasses", "sunset_sunrise", "television", "timepiece", "tool", "toy",
        "trail", "train", "tree", "truck", "tulip", "vehicle", "videogame", "watercraft",
        "waterfall", "wetland", "window", "wood_natural",
    ]

    /// Plates and cutlery: raw confidence, because Vision is sure about them.
    /// A laid table. NOT "utensil": Vision files umbrellas under it, so a
    /// beach parasol and a lady's sun umbrella came back as tableware 0.62
    /// and 0.89 — two holiday visits entered the queue as meals.
    nonisolated private static let tableIdentifiers: Set<String> = [
        "tableware", "plate", "bowl", "cup", "mug", "drinking_glass",
        "chopsticks", "fork", "spoon", "knife", "cakestand", "teapot",
    ]

    struct Scores: Sendable {
        var food: Float
        var table: Float
        var people: Float
        /// Strongest food label before bars and vetoes.
        var raw: Float = 0
        /// SigLIP's 애플사진 probability; 0 when the model is absent.
        var apple: Float = 0
        var mainlyFood: Float = 0
        /// The food label only counted because the table was laid.
        var byTable: Bool
    }

    nonisolated private static func scores(of url: URL) -> Scores {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(url: url, options: [:]).perform([request])
        var scored = scores(from: request.results)
        if scored.food > 0, !scored.byTable, textBesideSubject(url: url) >= 0.08 { scored.food = 0 }
        return scored
    }

    nonisolated private static func scores(of image: CGImage) -> Scores {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return scores(from: request.results)
    }

    /// Share of the area around the photo's main subject covered by text.
    /// A dish on a menu board or a tablet sits in a block of writing (0.12,
    /// 0.16 measured); a dish on a table does not. Not applied to a laid
    /// table: a dessert plate with "Happy Birthday" piped on it reads 0.13.
    nonisolated private static func textBesideSubject(_ image: CGImage) -> CGFloat {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        return textBesideSubject(handler)
    }

    nonisolated private static func textBesideSubject(url: URL) -> CGFloat {
        textBesideSubject(VNImageRequestHandler(url: url, options: [:]))
    }

    nonisolated private static func textBesideSubject(_ handler: VNImageRequestHandler) -> CGFloat {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["ko-KR", "ja-JP", "en-US"]
        text.usesLanguageCorrection = false
        let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([text, salient])
        let objects = (salient.results?.first?.salientObjects ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        var subject = objects.first?.boundingBox ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        subject = subject.insetBy(dx: -subject.width * 0.2, dy: -subject.height * 0.2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        var near: CGFloat = 0
        for observation in text.results ?? [] {
            guard let top = observation.topCandidates(1).first, top.confidence >= 0.3, top.string.count >= 2 else { continue }
            let overlap = observation.boundingBox.intersection(subject)
            if !overlap.isNull { near += overlap.width * overlap.height }
        }
        return near / max(subject.width * subject.height, 0.01)
    }

    /// Sweets in a wrapper are not a meal; a straw on its own is a prop.
    nonisolated private static let notReallyFood: Set<String> = [
        "candy", "candy_cane", "candy_other", "lollipop",
    ]

    nonisolated private static func scores(from results: [VNClassificationObservation]?) -> Scores {
        guard let results else { return Scores(food: 0, table: 0, people: 0, byTable: false) }
        let foodHits = results.filter {
            let id = $0.identifier.lowercased()
            return foodIdentifiers.contains(id) && !notReallyFood.contains(id)
        }
        var food = foodHits.map(\.confidence).max() ?? 0
        let raw = food
        // "drink" riding on "straw_drinking" alone was a carousel ornament.
        let straw = results.first { $0.identifier == "straw_drinking" }?.confidence ?? 0
        let drinkOnly = foodHits.allSatisfy { ["drink", "beverage"].contains($0.identifier.lowercased()) }
        if drinkOnly, straw > 0, abs(straw - food) < 0.02 { food = 0 }
        let people = results.filter { ["people", "adult"].contains($0.identifier.lowercased()) }
            .map(\.confidence).max() ?? 0
        let table = results
            .filter { tableIdentifiers.contains($0.identifier.lowercased()) }
            .filter { $0.hasMinimumRecall(0.5, forPrecision: 0.3) }
            .map(\.confidence)
            .max() ?? 0
        // Something else owns the frame: not a meal. A laid table is the
        // exception — plates and bowls at 0.65+ with any food at all is a
        // meal Vision could not name (a 생선구이 정식 scored food 0.26 under
        // tableware 0.87, an iced latte food 0.20 under plant 0.34).
        let against = results
            .filter { notAMealIdentifiers.contains($0.identifier.lowercased()) }
            .map(\.confidence)
            .max() ?? 0
        // A food label at 0.20 stands on its own: a terrace lunch under a
        // 0.98 sky, a café table beside a 0.86 plant, a dessert under a 0.51
        // painting are all meals, and the veto was throwing them out.
        let laidTable = table >= 0.65 && food >= 0.10
        // Vision reads leaves as "herb"/"seasonings": a patch of wildflowers
        // scored food 0.33 under foliage 0.75. Herbs alone are not a dish.
        // Vision returns every label, most near zero; only the ones carrying
        // the food score say what the food is.
        let specific = foodHits.filter { $0.confidence >= food * 0.5 }
            .map { $0.identifier.lowercased() }.filter { $0 != "food" }
        let herbsOnly = !specific.isEmpty && specific.allSatisfy { ["herb", "seasonings", "spice", "lemongrass"].contains($0) }
        let clearlyFood = food >= 0.20 && !herbsOnly
        if !laidTable, !clearlyFood, food < 0.15 || (against >= 0.20 && against > food) { food = 0 }
        return Scores(food: food, table: table, people: people, raw: raw, byTable: laidTable && !clearlyFood)
    }

    /// EXIF stores magnitude and hemisphere separately, so a southern or western
    /// coordinate is only correct once the reference letter is applied.
    nonisolated private static func coordinate(of url: URL) -> (Double?, Double?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return (nil, nil) }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return (south ? -latitude : latitude, west ? -longitude : longitude)
    }

    private func regroup() {
        let grouped = Self.group(scanned.filter { !memory.hidden.contains($0.id) }, gap: visitGap, spread: visitSpread,
                                 splits: memory.splits, merges: memory.merges,
                                 worked: { group in group.contains { self.hasWork(under: $0.id) } })
        visits = joinDrifted(grouped).map { ordered($0) }
        adoptStrandedWork()
        writeVisitIndex()
        resolveTimeZones()
    }

    private var zoneTask: Task<Void, Never>?

    /// Each visit's clock is where it happened; a zone learned redraws the
    /// dates (Visit reads them from VisitTimeZone).
    private func resolveTimeZones() {
        guard zoneTask == nil else { return }
        let places = visits.compactMap(\.coordinate)
        zoneTask = Task { [weak self] in
            if await VisitTimeZone.resolve(places) { self?.objectWillChange.send() }
            self?.zoneTask = nil
        }
    }

    /// Every visit as the app sees it, written beside memory.json on each
    /// regroup. Nothing in the app reads it: it exists so that "why is this
    /// visit not in the list" can be answered by looking instead of
    /// guessing.
    private func writeVisitIndex() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = visits.map { visit -> String in
            let marks = [
                memory.confirmed[visit.id] != nil ? "가게" : nil,
                memory.photoDishes[visit.id] != nil ? "메뉴" : nil,
                memory.drafts[visit.id] != nil ? "초안" : nil,
                memory.posted[visit.id] != nil ? "올림" : nil,
                memory.notMeals.contains(visit.id) ? "보관" : nil,
                visit.photos.contains(where: \.isFood) ? nil : "음식없음",
                visit.coordinate == nil ? "위치없음" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            let clock = DateFormatter(); clock.dateFormat = "HH:mm"
            let last = visit.photos.map(\.takenAt).max().map { clock.string(from: $0) } ?? ""
            let touched = untouched(visit) ? "" : "손댐"
            // Every photo's id, not just the visit's own: work is filed under
            // whichever photo happened to be first, so this is how a piece of
            // it can be traced when the grouping moves.
            let members = visit.photos.map { String($0.id.prefix(8)) }.joined(separator: " ")
            let where_ = visit.coordinate.map { String(format: "%.5f,%.5f ±%.0fm", $0.latitude, $0.longitude, visit.positionError) } ?? "위치없음"
            return "\(stamp.string(from: visit.takenAt))–\(last)  step \(step(for: visit))  사진 \(visit.photos.count)  \(marks)\(touched.isEmpty ? "" : "," + touched)  \(memory.confirmed[visit.id]?.name ?? "")  [\(visit.id.prefix(8))]  \(where_)  { \(members) }"
        }
        let url = Self.memoryURL.deletingLastPathComponent().appendingPathComponent("visits.txt")
        do {
            try (["\(visits.count) visits"] + lines).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            Usage.local(tag: "방문 목록", detail: "\(visits.count)개", seconds: 0)
            writeGPSReport()
        } catch {
            Usage.local(tag: "방문 목록 실패", detail: "\(error)", seconds: 0)
        }
    }

    /// What the phone says its own reading is worth, next to how far that
    /// reading landed from the restaurant. "GPS는 5~10m 아니야?" — it is,
    /// outdoors under open sky, and none of these photos were taken there.
    /// Three numbers per visit tell the three stories apart: what the phone
    /// CLAIMED (±), how far its own photos of one meal scatter from each
    /// other (흩어짐 — the phone against itself, no Google involved), and how
    /// far the result sits from Google's pin (핀). A tight scatter with a far
    /// pin is Google's marker sitting on a building, not the phone being
    /// wrong.
    private func writeGPSReport() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = ["방문  |  아이폰이 적은 오차  |  한 끼 사진끼리 흩어짐  |  구글 핀까지  |  가게"]
        for visit in visits {
            guard let place = memory.confirmed[visit.id], place.distance >= 0 else { continue }
            let reported = visit.photos.compactMap(\.accuracy)
            let claim = reported.isEmpty ? "모름"
                : reported.count == 1 ? String(format: "±%.0fm", reported[0])
                : String(format: "±%.0f–%.0fm", reported.min()!, reported.max()!)
            let spread: String
            let located = visit.photos.compactMap(\.coordinate)
            if located.count > 1, let centre = visit.coordinate {
                let hub = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
                let far = located.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: hub) }.max()!
                spread = String(format: "%.0fm (사진 %d장)", far, located.count)
            } else {
                spread = "사진 1장"
            }
            lines.append(String(format: "%@  |  %@  |  %@  |  %.0fm  |  %@",
                                stamp.string(from: visit.takenAt), claim, spread, place.distance, place.name))
        }
        let url = Self.memoryURL.deletingLastPathComponent().appendingPathComponent("gps.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        Usage.local(tag: "GPS 보고서", detail: "\(lines.count - 1)곳", seconds: 0)
    }

    /// A visit is named after its first photo, so a visit that gains or loses
    /// a photo at the front is renamed — and everything the person filed
    /// under the old name is stranded. It happened twice in one day: a photo
    /// with no position bridged two visits into one, and another visit's
    /// restaurant, typed in by hand, vanished with the name it was filed
    /// under. Rather than trust the grouping never to change again, each
    /// visit looks for work filed under any of its own photos and takes it.
    private func adoptStrandedWork() {
        var moved = 0
        for visit in visits {
            let ids = visit.photos.map(\.id).filter { $0 != visit.id }
            guard !ids.isEmpty else { continue }
            for old in ids {
                if memory.confirmed[visit.id] == nil, let place = memory.confirmed[old] {
                    memory.confirmed[visit.id] = place; memory.confirmed[old] = nil; moved += 1
                }
                if memory.photoDishes[visit.id] == nil, let dishes = memory.photoDishes[old] {
                    memory.photoDishes[visit.id] = dishes; memory.photoDishes[old] = nil; moved += 1
                }
                if memory.photoSuggestions[visit.id] == nil, let guesses = memory.photoSuggestions[old] {
                    memory.photoSuggestions[visit.id] = guesses; memory.photoSuggestions[old] = nil
                }
                if memory.photoKinds[visit.id] == nil, let kinds = memory.photoKinds[old] {
                    memory.photoKinds[visit.id] = kinds; memory.photoKinds[old] = nil
                }
                if memory.drafts[visit.id] == nil, let draft = memory.drafts[old] {
                    memory.drafts[visit.id] = draft; memory.drafts[old] = nil; moved += 1
                }
                if memory.options[visit.id] == nil, let options = memory.options[old] {
                    memory.options[visit.id] = options; memory.options[old] = nil
                }
                if memory.notes[visit.id] == nil, let note = memory.notes[old] {
                    memory.notes[visit.id] = note; memory.notes[old] = nil
                }
                if memory.posted[visit.id] == nil, let when = memory.posted[old] {
                    memory.posted[visit.id] = when; memory.posted[old] = nil; moved += 1
                }
                if memory.likes[visit.id] == nil, let liked = memory.likes[old] {
                    memory.likes[visit.id] = liked; memory.likes[old] = nil
                }
                if memory.likedDishes[visit.id] == nil, let liked = memory.likedDishes[old] {
                    memory.likedDishes[visit.id] = liked; memory.likedDishes[old] = nil
                }
                if memory.formOpened.contains(old) { memory.formOpened.insert(visit.id); memory.formOpened.remove(old) }
                if memory.notMeals.contains(old) { memory.notMeals.insert(visit.id); memory.notMeals.remove(old) }
                if memory.sureMeals.contains(old) { memory.sureMeals.insert(visit.id); memory.sureMeals.remove(old) }
            }
        }
        // Second pass: work filed under a photo that is in no visit at all —
        // because the person took that photo out, and it happened to be the
        // one the visit was named after. The meal it was taken at is still
        // there; the work goes back to it.
        let living = Set(visits.map(\.id))
        let byID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var stranded = Set(memory.confirmed.keys)
        stranded.formUnion(memory.photoDishes.keys)
        stranded.formUnion(memory.drafts.keys)
        stranded.formUnion(memory.options.keys)
        stranded.formUnion(memory.posted.keys)
        for old in stranded where !living.contains(old) {
            guard let photo = byID[old] else { continue }
            let near = visits
                .map { (visit: $0, apart: abs($0.takenAt.timeIntervalSince(photo.takenAt))) }
                .filter { $0.apart <= visitGap }
                .min { $0.apart < $1.apart }
            guard let home = near?.visit else { continue }
            var took = false
            if memory.confirmed[home.id] == nil, let place = memory.confirmed[old] {
                memory.confirmed[home.id] = place; memory.confirmed[old] = nil; took = true
            }
            if memory.photoDishes[home.id] == nil, let dishes = memory.photoDishes[old] {
                memory.photoDishes[home.id] = dishes; memory.photoDishes[old] = nil; took = true
            }
            if memory.drafts[home.id] == nil, let draft = memory.drafts[old] {
                memory.drafts[home.id] = draft; memory.drafts[old] = nil; took = true
            }
            if memory.options[home.id] == nil, let options = memory.options[old] {
                memory.options[home.id] = options; memory.options[old] = nil; took = true
            }
            if memory.posted[home.id] == nil, let when = memory.posted[old] {
                memory.posted[home.id] = when; memory.posted[old] = nil; took = true
            }
            if took {
                moved += 1
                print("[PhotoLibrary] \(memory.confirmed[home.id]?.name ?? "work") went back to \(home.title)")
            }
        }
        guard moved > 0 else { return }
        print("[PhotoLibrary] adopted \(moved) pieces of work whose visit had been renamed")
        confirmedPlaces = memory.confirmed
        photoDishes = memory.photoDishes
        photoSuggestions = memory.photoSuggestions
        photoKinds = memory.photoKinds
        posted = memory.posted
        likes = memory.likes
        likedDishes = memory.likedDishes
        formOpened = memory.formOpened
        notMeals = memory.notMeals
        sureMeals = memory.sureMeals
        saveMemory()
    }

    /// Two visits twenty minutes apart are one meal whose GPS wandered.
    ///
    /// The 50m rule cannot be loosened — it is what keeps the cafe next door
    /// out (77m, measured) — but that cafe was a separate
    /// outing, and nobody changes restaurants in a quarter of an hour. So the
    /// metres stay strict and time does the joining, and only where there is
    /// nothing to lose: a visit the person has touched (a place chosen, a
    /// name typed, a review, an archive, a split) is never moved, because
    /// merging renames the visit and the work is filed under the old name.
    private func joinDrifted(_ visits: [Visit]) -> [Visit] {
        // 20 minutes, not 15: one lunch had a 19-minute quiet spell in the
        // middle of it — food comes when it comes — and came out as two
        // visits.
        let close: TimeInterval = 20 * 60
        var out: [Visit] = []
        // The list runs newest first; walk it oldest first so each visit joins
        // the one before it in time.
        for visit in visits.reversed() {
            guard let previous = out.last, untouched(previous), untouched(visit),
                  let end = previous.photos.last?.takenAt, let start = visit.photos.first?.takenAt,
                  start.timeIntervalSince(end) <= close else {
                out.append(visit)
                continue
            }
            out[out.count - 1] = Visit(id: previous.id, photos: previous.photos + visit.photos, takenAt: previous.takenAt)
        }
        return out.reversed()
    }

    /// Something of the person's is filed under this id — the id being
    /// whichever photo happened to be first when they did the work.
    private func hasWork(under id: String) -> Bool {
        memory.confirmed[id] != nil || memory.photoDishes[id] != nil || memory.drafts[id] != nil
            || memory.options[id] != nil || memory.posted[id] != nil || memory.tags[id] != nil
            || memory.notes[id] != nil || memory.sureMeals.contains(id)
    }

    /// Nothing of the person's is filed under this visit. "이건 밥이에요"
    /// (sureMeals) does not count: it says the photos are a meal, not that the
    /// meal's edges are settled, and the mark follows the photos into the
    /// merged visit anyway. Holding it back left one lunch as three visits,
    /// all of them 오전 10시, each one vouched for separately.
    private func untouched(_ visit: Visit) -> Bool {
        memory.confirmed[visit.id] == nil && memory.photoDishes[visit.id] == nil
            && memory.drafts[visit.id] == nil && memory.options[visit.id] == nil
            && memory.posted[visit.id] == nil && !memory.notMeals.contains(visit.id)
            && memory.photoOrder[visit.id] == nil
            && !visit.photos.contains { memory.splits.contains($0.id) }
    }

    /// A visit's photos in the order the user arranged them, the rest after
    /// in time order. The order is what the dishes grid, the strip and the
    /// posting folder all follow.
    private func ordered(_ visit: Visit) -> Visit {
        guard let order = memory.photoOrder[visit.id], !order.isEmpty else { return visit }
        var copy = visit
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        copy.photos = visit.photos.enumerated().sorted { a, b in
            let ra = rank[a.element.id], rb = rank[b.element.id]
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        return copy
    }

    /// Drag-and-drop reorder: the dragged photo takes the slot of the one
    /// it is dragged over; remembered per visit.
    func movePhoto(_ photoID: String, over targetID: String, in visit: Visit) {
        guard photoID != targetID,
              let index = visits.firstIndex(where: { $0.id == visit.id }),
              let from = visits[index].photos.firstIndex(where: { $0.id == photoID }),
              let to = visits[index].photos.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = visits[index].photos.remove(at: from)
        visits[index].photos.insert(moved, at: to)
        memory.photoOrder[visit.id] = visits[index].photos.map(\.id)
        saveMemory()
    }

    func markFormOpened(_ visit: Visit) {
        formOpened.insert(visit.id)
        memory.formOpened.insert(visit.id)
        saveMemory()
    }

    /// The person edited the English; it replaces the translation of the
    /// current Korean text (a new Korean text gets a fresh translation).
    func setTranslation(_ english: String, for visit: Visit) {
        guard let korean = reviewDrafts[visit.id]?.text, !korean.isEmpty else { return }
        let digest = Self.digest([korean])
        guard translations[digest] != english else { return }
        translations[digest] = english
        memory.translations[digest] = english
        saveMemory()
    }

    /// Cut a visit in two at `photo`: it and everything after become their
    /// own visit. For the case GPS cannot see — a cafe next door, thirty
    /// minutes after the meal. Remembered across relaunches.
    func splitVisit(_ visit: Visit, at photo: Photo) {
        memory.splits.insert(photo.id)
        memory.merges.remove(photo.id)
        saveMemory()
        regroup()
        print("[PhotoLibrary] split \(visit.title) at \(photo.id.prefix(8))")
    }

    /// The visit that ends just before this one starts, when the two are close
    /// enough in time to have been one meal. GPS indoors wanders — a 2022
    /// lunch came out as three visits all at 오전 10시 — and the metres cannot
    /// be loosened without merging the cafe next door.
    func previousVisit(before visit: Visit) -> Visit? {
        guard let index = visits.firstIndex(where: { $0.id == visit.id }), index + 1 < visits.count else { return nil }
        let earlier = visits[index + 1]   // the list runs newest first
        guard let mine = visit.photos.first?.takenAt, let theirs = earlier.photos.last?.takenAt,
              mine.timeIntervalSince(theirs) <= visitGap else { return nil }
        return earlier
    }

    func mergeWithPrevious(_ visit: Visit) {
        guard let first = visit.photos.first, let earlier = previousVisit(before: visit) else { return }
        memory.splits.remove(first.id)
        memory.merges.insert(first.id)
        // The two halves' work belongs to whichever visit survives, which is
        // the earlier one: its id is the merged visit's id.
        if memory.confirmed[earlier.id] == nil, let place = memory.confirmed[visit.id] {
            memory.confirmed[earlier.id] = place
            confirmedPlaces[earlier.id] = place
        }
        for (photoID, name) in memory.photoDishes[visit.id] ?? [:] {
            memory.photoDishes[earlier.id, default: [:]][photoID] = name
        }
        memory.photoDishes[visit.id] = nil
        photoDishes[visit.id] = nil
        saveMemory()
        regroup()
        print("[PhotoLibrary] merged \(visit.title) into \(earlier.title)")
    }

    private static func rawGroups(_ photos: [Photo], gap: TimeInterval, spread: CLLocationDistance,
                                  splits: Set<String> = [], merges: Set<String> = []) -> [[Photo]] {
        // A visit is every photo taken in one place at one time — the dish,
        // the receipt, the room, the company. Whether it is a *restaurant*
        // visit is decided afterwards by food being in it. A non-food photo
        // needs GPS to join, which keeps screenshots and downloads out: 370
        // real photos once grouped into 47 "visits", four of them meals.
        let candidates = photos.filter { $0.isMealish || $0.hasLocation }
        // A photo with no coordinates and nothing the classifier called food
        // is left out above — that filter keeps screenshots and downloads from
        // becoming visits. But a phone sometimes writes no position for one
        // shot in a set, and that shot then vanished from the meal it was
        // taken in. It may join a visit already under way when it falls within
        // 20 minutes of the photo before it; it can never start one.
        let close: TimeInterval = 20 * 60
        let orphans = photos.filter { !$0.isMealish && !$0.hasLocation }
        var grouped: [[Photo]] = []
        // The photo each group is measured from: the last one that had a
        // position or was food. A passenger must not become the anchor, or it
        // bridges a gap that should have ended the visit — one such photo
        // swallowed a whole visit into the one before it, and with the
        // visit's id went the restaurant the person had typed in.
        var anchors: [Photo] = []
        for photo in (candidates + orphans).sorted(by: { $0.takenAt < $1.takenAt }) {
            if !photo.isMealish, !photo.hasLocation {
                guard let anchor = anchors.last, !grouped.isEmpty,
                      photo.takenAt.timeIntervalSince(anchor.takenAt) <= close else { continue }
                grouped[grouped.count - 1].append(photo)
                continue
            }
            if !splits.contains(photo.id), let last = grouped.last, let anchor = anchors.last,
               merges.contains(photo.id)
                || (photo.takenAt.timeIntervalSince(anchor.takenAt) <= gap
                    && isNearby(photo, to: last, within: spread)) {
                grouped[grouped.count - 1].append(photo)
            } else {
                grouped.append([photo])
            }
            anchors.append(photo)
        }
        return grouped
    }

    private static func group(_ photos: [Photo], gap: TimeInterval, spread: CLLocationDistance,
                              splits: Set<String> = [], merges: Set<String> = [],
                              worked: ([Photo]) -> Bool = { _ in false }) -> [Visit] {
        let grouped = rawGroups(photos, gap: gap, spread: spread, splits: splits, merges: merges)
        // One photo is a visit when it was taken somewhere — people do
        // photograph a single dish. Without coordinates a lone photo is more
        // often a saved picture than a meal, so it needs company.
        return grouped
            .filter { group in
                // No food, no restaurant visit — this is the test. The
                // size cap guards against dumps; whole-day
                // clusters now include non-food photos, so it is generous.
                guard group.count <= 120 else { return false }
                // A visit the person has worked on is never dropped, whatever
                // the classifier makes of what is left in it. One visit — a
                // place confirmed, a review begun — vanished from the list
                // when the photos that scored as food were taken out of it by
                // hand, and its work went with it.
                if worked(group) { return true }
                guard group.contains(where: { $0.isMealish }) else { return false }
                return group.count >= 2 || group.contains { $0.hasLocation }
            }
            .compactMap { group in
                guard let first = group.first else { return nil }
                return Visit(id: first.id, photos: group, takenAt: first.takenAt)
            }
            .sorted { $0.takenAt > $1.takenAt }
    }

    /// Log of how the newest visits were assembled — per photo: minutes from
    /// the first shot, food score, GPS presence, metres from the visit's
    /// food centroid. For judging the grouping rules against real days.
    private static func describe(_ visits: ArraySlice<Visit>) {
        for visit in visits {
            let start = visit.photos.first?.takenAt ?? Date()
            let centre = visit.coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            let lines = visit.photos.map { photo -> String in
                let minutes = Int(photo.takenAt.timeIntervalSince(start) / 60)
                let dist = photo.coordinate.flatMap { c in centre.map { Int(CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: $0)) } }
                let gps = photo.coordinate.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "noGPS"
                return String(format: "+%dm food=%.2f %@ [%@]", minutes, photo.foodScore, dist.map { "\($0)m" } ?? "noGPS", gps)
            }
            print("[PhotoLibrary] \(visit.title): " + lines.joined(separator: " | "))
        }
    }

    /// A photo belongs with a group unless there is location evidence against
    /// it: a photo without GPS, or a group without any, cannot be told apart.
    private static func isNearby(_ photo: Photo, to group: [Photo], within spread: CLLocationDistance) -> Bool {
        guard let here = photo.coordinate, let there = Visit.centroid(of: group) else { return true }
        let a = CLLocation(latitude: here.latitude, longitude: here.longitude)
        let b = CLLocation(latitude: there.latitude, longitude: there.longitude)
        return a.distance(from: b) <= spread
    }

    // MARK: - Place

    /// Look up the restaurant for a visit from its coordinates. Once per
    /// visit per session, and once per ~11m cell per month on disk.
    /// Visits whose nearby search could not reach Google. Their candidate
    /// list is empty but the place is not: one visit read as "근처에서
    /// 못 찾았어요" while Google had ten restaurants at that very spot.
    @Published private(set) var lookupFailed: Set<Visit.ID> = []

    func lookupPlace(for visit: Visit, again: Bool = false) async {
        lookingUp.insert(visit.id)
        defer { lookingUp.remove(visit.id) }
        await Usage.stage(visit.title, "가게 찾기") { await lookupPlaceWork(for: visit, again: again) }
    }
    /// Places being looked up around a visit right now.
    @Published private(set) var lookingUp: Set<Visit.ID> = []

    private func lookupPlaceWork(for visit: Visit, again: Bool = false) async {
        if again {
            placeCandidates[visit.id] = nil
            lookupFailed.remove(visit.id)
        }
        guard placeCandidates[visit.id] == nil, let coordinate = visit.coordinate else { return }
        let key = Self.placeKey(coordinate)
        if let cached = memory.places[key], Date().timeIntervalSince(cached.fetchedAt) < Self.placeCacheLife {
            print("[PlaceLookup] cache hit \(key): \(cached.candidates.count) candidates")
            apply(cached.candidates, to: visit)
            return
        }
        let result = await PlaceLookup.candidates(near: coordinate)
        if result.settled {
            memory.places[key] = Memory.CachedPlaces(fetchedAt: Date(), candidates: result.candidates)
            saveMemory()
            lookupFailed.remove(visit.id)
        } else {
            print("[PlaceLookup] unsettled at \(key) — nothing cached, offering a retry")
            lookupFailed.insert(visit.id)
        }
        apply(result.candidates, to: visit)
    }

    private func apply(_ found: [PlaceCandidate], to visit: Visit) {
        var list = found
        // A place the person chose is theirs, whether or not it is in the
        // list that came back. It often is not: one found by name is not in
        // the neighbourhood's own results, and a cache key change refetches
        // the neighbourhood. Dropping it made a settled visit look unstarted
        // — out of 작성중, and back to "사진으로 가게를 확인하는 중", which is
        // the app re-deciding something the person already decided.
        if let remembered = memory.confirmed[visit.id] {
            if !list.contains(where: { $0.id == remembered.id }) { list.insert(remembered, at: 0) }
            confirmedPlaces[visit.id] = remembered
        } else if list.count == 1, let only = list.first {
            confirmedPlaces[visit.id] = only
        }
        placeCandidates[visit.id] = list
        print("[PlaceLookup] \(visit.title): \(list.count) candidates: " + list.prefix(PlaceLookup.shownCandidates).map { "\($0.name) \($0.distanceLabel)" }.joined(separator: " | "))
    }

    /// Ask the vision model which candidate the photos belong to. Runs once
    /// per (visit, photos, candidates) and is remembered on disk; skipped when
    /// there is nothing to choose between or no key.
    /// True while a match is still to come for this visit: candidates exist,
    /// no match yet, and nothing has ruled one out (no key, no photos).
    func matchPending(_ visit: Visit) -> Bool {
        guard let candidates = placeCandidates[visit.id], candidates.count > 1, placeMatches[visit.id] == nil else { return false }
        return PlaceMatcher.openAIKey != nil && !matchFailed.contains(visit.id)
    }
    private var matchFailed: Set<Visit.ID> = []

    func matchFailed(_ visit: Visit) -> Bool { matchFailed.contains(visit.id) }

    /// "다시 확인": forget a failed or finished attempt and ask again.
    func rematchPlace(for visit: Visit) async {
        matchFailed.remove(visit.id)
        placeMatches[visit.id] = nil
        await matchPlace(for: visit)
    }

    func matchPlace(for visit: Visit) async {
        await Usage.stage(visit.title, "가게 맞추기") { await matchPlaceWork(for: visit) }
    }

    private func matchPlaceWork(for visit: Visit) async {
        // Nothing to work out for a place the person already chose. Without
        // this, opening a finished visit again — place confirmed, dishes
        // named, review written — asked the model twice and Google once
        // more, $0.044 to re-decide a settled question.
        guard confirmedPlaces[visit.id] == nil, memory.confirmed[visit.id] == nil else { return }
        guard let candidates = placeCandidates[visit.id], candidates.count > 1,
              placeMatches[visit.id] == nil, !matching.contains(visit.id) else { return }
        guard let key = PlaceMatcher.openAIKey else {
            print("[PlaceMatch] no OpenAI key — defaults write com.jinsukim.afterplate OpenAIAPIKey <key>")
            return
        }
        // "match-v5": the model lists the kinds that fit and the app takes the
        // nearest. Changing the rules must not serve old answers.
        // The photo ids are deliberately not in the key: adding videos to the
        // library changed a visit's photo set, the cached answer no longer
        // applied, and the fresh one flipped to a different restaurant.
        // Sorted: Google hands the same neighbourhood back in a slightly
        // different order between a live fetch and the cache, and an order
        // that means nothing here was making the cached answer unreachable.
        let digest = Self.digest(["match-v5", visit.id] + candidates.map(\.id).sorted())
        if let cached = memory.matches[digest] {
            placeMatches[visit.id] = cached
            print("[PlaceMatch] cache hit for \(visit.title)")
            return
        }
        matching.insert(visit.id)
        defer { matching.remove(visit.id) }

        // The food photos carry the dishes; a couple of non-food photos may
        // carry the receipt or the sign, which the classifier scores low.
        let food = visit.photos.filter { $0.isFood }.prefix(4)
        let other = visit.photos.filter { !$0.isFood }.prefix(2)
        let sending = Array(food) + Array(other)
        // Six photos fetched one after another was most of the wait before the
        // model was even asked: 9 of the 17 seconds on one visit.
        // Each fetch is mostly waiting on PhotoKit (and on iCloud), so they
        // overlap; the order still has to be the order sent.
        let jpegs = await Usage.timing("사진 준비", detail: "\(sending.count)장") {
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, photo) in sending.enumerated() {
                    group.addTask { (index, await self.reducedJPEG(for: photo, maxPixel: 768)) }
                }
                var ordered = [Data?](repeating: nil, count: sending.count)
                for await (index, jpeg) in group { ordered[index] = jpeg }
                return ordered.compactMap { $0 }
            }
        }
        guard !jpegs.isEmpty else { matchFailed.insert(visit.id); return }
        // No OCR pass. Reading twelve photos out of Photos and running Vision
        // over them was most of the wait before the model was even asked, and
        // the model is looking at the same photos — it can read the signboard
        // and the receipt itself.
        let ocr: [String] = []
        print("[PlaceMatch] asking about \(visit.title): \(jpegs.count) photos, \(candidates.count) candidates, \(ocr.count) OCR lines")
        let started = Date()
        guard var first = await PlaceMatcher.match(jpegs: jpegs, candidates: candidates, ocrText: ocr,
                                                  positionError: visit.positionError, key: key) else {
            matchFailed.insert(visit.id)
            return
        }
        // Kinds alone often cannot separate the two nearest: 12m and 13m, both
        // 한식당; or a 오키나와 소바집 filed as plain "음식점". Only then is it
        // worth Google's dearest tier — a second nearby call carrying what
        // people wrote about each place.
        if Self.needsReviews(first, candidates: candidates), let coordinate = visit.coordinate {
            let reviews = await PlaceLookup.reviews(near: coordinate)
            if !reviews.isEmpty,
               let better = await PlaceMatcher.match(jpegs: jpegs, candidates: candidates, ocrText: ocr, reviews: reviews,
                                                     positionError: visit.positionError, key: key) {
                print("[PlaceMatch] \(visit.title): asked again with \(reviews.count) places' reviews")
                first = better
            }
        }
        // Second stage: check the nearby candidates' real menus, unless the
        // photos' own text already named the place.
        let match = first
        print(String(format: "[PlaceMatch] %@: photos %.1fs", visit.title, Date().timeIntervalSince(started)))
        memory.matches[digest] = match
        saveMemory()
        placeMatches[visit.id] = match
        let names = match.picks.map { pick in
            (candidates.first { $0.id == pick.id }?.name ?? "?") + " (\(pick.confidence): \(pick.reason))"
        }
        print("[PlaceMatch] \(visit.title): \(match.cuisine) · " + match.dishes.map { "\($0.name)/\($0.confidence)" }.joined(separator: ", ")
              + " → " + (names.isEmpty ? "no pick" : names.joined(separator: " | ")))
    }

    /// Two picks whose distance is within 10m of each other, or a top pick
    /// whose category says nothing about what it cooks.
    private static let vagueCategories: Set<String> = ["음식점", "식당", "간이음식점", "고급 음식점", "테이크아웃 전문 레스토랑"]

    private static func needsReviews(_ match: PlaceMatch, candidates: [PlaceCandidate]) -> Bool {
        let picked = match.picks.compactMap { pick in candidates.first { $0.id == pick.id } }
        guard let top = picked.first else { return false }
        if vagueCategories.contains(top.category ?? "음식점") { return true }
        if let second = picked.dropFirst().first, second.distance - top.distance <= 10 { return true }
        return false
    }

    private struct RestoredVisit: Decodable {
        struct Draft: Decodable { let genre: String; let text: String }
        let title: String
        let place: String
        let dishes: [String: String]
        let drafts: [Draft]
        let english: String?
    }

    /// Restores what a memory-version bump threw away, from the app's own
    /// log. A visit is found by date AND by the restaurant being among the
    /// places near its photos: two visits can share a title (one "오후 1시"
    /// title was both a lunch and a café afterwards), and matching on
    /// the title alone put one visit's place, drafts and posted mark on the
    /// other. Anything already sitting on the wrong visit moves across.
    private func restore(from file: URL) async {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([RestoredVisit].self, from: data) else {
            print("[Restore] could not read \(file.lastPathComponent)")
            return
        }
        print("[Restore] \(saved.count) entries to place")
        for entry in saved {
            let sameDay = visits.filter { $0.title == entry.title }
            guard !sameDay.isEmpty else {
                print("[Restore] \(entry.title): no visit with that date any more")
                continue
            }
            // Which of them was at this restaurant? The one whose nearby
            // places include it.
            var chosen: (visit: Visit, place: PlaceCandidate)?
            for visit in sameDay {
                await lookupPlace(for: visit)
                if let place = (placeCandidates[visit.id] ?? []).first(where: { $0.name == entry.place }) {
                    chosen = (visit, place)
                    break
                }
            }
            if chosen == nil, sameDay.count == 1, let visit = sameDay.first {
                // Only one visit that day and the place is out of range (a
                // takeaway eaten at home): look it up by name.
                let found = await PlaceLookup.searchText(entry.place, near: visit.coordinate)
                if let place = found.first(where: { $0.name == entry.place }) ?? found.first { chosen = (visit, place) }
            }
            guard let (visit, place) = chosen else {
                print("[Restore] \(entry.title) / \(entry.place): could not tell which visit this was")
                continue
            }
            // Move anything the earlier, title-only restore misfiled.
            for other in visits where other.id != visit.id && confirmedPlaces[other.id]?.googlePlaceID == place.googlePlaceID {
                print("[Restore] moving \(entry.place) off \(other.title)")
                clearPlace(for: other)
                memory.options[other.id] = nil
                memory.drafts[other.id] = nil
                memory.photoDishes[other.id] = nil
                reviewOptions[other.id] = nil
                reviewDrafts[other.id] = nil
                photoDishes[other.id] = nil
                if memory.posted[other.id] != nil {
                    memory.posted[other.id] = nil
                    posted[other.id] = nil
                    memory.posted[visit.id] = Date()
                    posted[visit.id] = Date()
                }
                memory.formOpened.remove(other.id)
                formOpened.remove(other.id)
            }
            confirmPlace(place, for: visit)
            for (index, name) in entry.dishes.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
                guard let n = Int(index), visit.photos.indices.contains(n - 1) else { continue }
                setPhotoDish(name, for: visit.photos[n - 1], in: visit)
            }
            if !entry.drafts.isEmpty, memory.options[visit.id] == nil {
                let options = entry.drafts.prefix(3).map { GenreDraft(genre: $0.genre, note: "", text: $0.text) }
                memory.options[visit.id] = Array(options)
                reviewOptions[visit.id] = Array(options)
                if let first = options.first { chooseDraft(first, for: visit) }
                if let english = entry.english, let korean = options.first?.text {
                    memory.translations[Self.digest([korean])] = english
                    translations[Self.digest([korean])] = english
                }
            }
            markFormOpened(visit)
            print("[Restore] \(entry.title) → \(place.name), dishes \(entry.dishes.count), drafts \(entry.drafts.count)")
        }
        saveMemory()
    }

    /// Looks up and matches the next few visits that still need a place, so
    /// opening one from the top of the list does not wait for the network.
    /// Nothing is looked up before it is opened. A Nearby Search is billed
    /// per request, so prefetching four visits at launch spent money on
    /// visits that were never opened — and the pile-up of parallel requests
    /// was dropping connections.
    private func prefetchPlaces(_ count: Int = 0) async {
        guard count > 0 else { return }
        let pending = visits.filter { confirmedPlaces[$0.id] == nil }.prefix(count)
        for visit in pending {
            await lookupPlace(for: visit)
            await matchPlace(for: visit)
        }
    }

    /// The nearby list arrived after the match was skipped (the lookup was
    /// empty or still failing), so ask now that there is something to choose
    /// between — one visit sat with 35 candidates and no pick because
    /// the match had run before the list came back.
    func matchIfPending(for visit: Visit) async {
        guard confirmedPlaces[visit.id] == nil,
              placeMatches[visit.id] == nil,
              (placeCandidates[visit.id]?.count ?? 0) > 1 else { return }
        await matchPlace(for: visit)
    }

    /// Visits whose candidates' menus are being searched right now.
    @Published private(set) var digging: Set<Visit.ID> = []
    /// Visits where the search found no candidate serving the dishes.
    @Published private(set) var digFailed: Set<Visit.ID> = []

    /// "메뉴까지 뒤져보기": the photo match ranks nearby places by what they
    /// could serve; this checks what they DO serve. The model searches each
    /// nearby candidate's menu on the web and the nearest one that carries
    /// the dishes goes to the top, with the menu item as the reason.
    /// A search of five candidates costs 5-20s, so the person asks for it.
    /// Visits whose candidate menus have been searched once. A web search is
    /// the most expensive thing the app can do (about $0.05 a go, ten seconds
    /// or more), so it runs once per visit.
    @Published private(set) var dug: Set<Visit.ID> = []

    func digIntoMenus(for visit: Visit) async {
        await Usage.stage(visit.title, "메뉴 뒤지기") { await digIntoMenusWork(for: visit) }
    }

    private func digIntoMenusWork(for visit: Visit) async {
        guard let match = placeMatches[visit.id], let candidates = placeCandidates[visit.id],
              let key = PlaceMatcher.openAIKey, !digging.contains(visit.id), !dug.contains(visit.id) else { return }
        dug.insert(visit.id)
        digging.insert(visit.id)
        digFailed.remove(visit.id)
        defer { digging.remove(visit.id) }
        let dishes: [String] = match.dishes.filter { $0.confidence != "low" }.map { $0.name }
        let started = Date()
        let verdicts = await MenuVerifier.verify(dishes: dishes, candidates: candidates, key: key)
        print(String(format: "[MenuVerifier] %@: %.1fs", visit.title, Date().timeIntervalSince(started)))
        guard let best = verdicts.first else {
            print("[MenuVerifier] \(visit.title): no candidate's menu confirmed " + dishes.joined(separator: ", "))
            digFailed.insert(visit.id)
            return
        }
        let found: [String] = verdicts.map { verdict in verdict.candidate.name + " — " + verdict.evidence }
        print("[MenuVerifier] \(visit.title): " + found.joined(separator: " | "))
        // Keep every menu the search read, not only the winner's: the person
        // may confirm a different candidate from the list, and the menu for
        // it has already been paid for. Without this the next screen said
        // "이 가게 메뉴 없음" and offered to buy the same pages again — the
        // WebMenu calls are $0.134 of a visit's cost.
        var kept = 0
        for verdict in verdicts {
            guard let placeID = verdict.candidate.googlePlaceID else { continue }
            let dishes = verdict.menu.filter { Self.isDish($0.name) }
            guard !dishes.isEmpty else { continue }
            // Never overwrite a menu read off Google's own page: that one was
            // transcribed, this one was found by searching.
            if let already = memory.googleMenus[placeID], !already.items.isEmpty, already.fromWeb != true { continue }
            memory.googleMenus[placeID] = Memory.CachedGoogleMenu(
                fetchedAt: Date(), highlights: [], photoURLs: [], items: dishes, fromWeb: true)
            kept += 1
        }
        if kept > 0 {
            Usage.local(tag: "딥서치 메뉴 보관", detail: "\(kept)곳", seconds: 0)
            for one in visits where confirmedPlaces[one.id]?.googlePlaceID != nil {
                if let placeID = confirmedPlaces[one.id]?.googlePlaceID, memory.googleMenus[placeID] != nil {
                    menuNames[one.id] = Self.names(of: memory.googleMenus[placeID]!)
                }
            }
        }
        var picks = match.picks.filter { $0.id != best.candidate.id }
        picks.insert(PlaceMatch.Pick(id: best.candidate.id, confidence: "high", reason: best.evidence), at: 0)
        let updated = PlaceMatch(dishes: match.dishes, cuisine: match.cuisine, picks: Array(picks.prefix(3)))
        placeMatches[visit.id] = updated
        let digest = Self.digest(["match-v4"] + visit.photos.map(\.id) + candidates.map(\.id))
        memory.matches[digest] = updated
        saveMemory()
    }

    // MARK: - Menu and dish names

    /// Whether the free path — the Google Maps page — has been tried for this
    /// place. The paid search is only worth offering after it has.
    func menuWasRead(for visit: Visit) -> Bool {
        guard let placeID = confirmedPlace(for: visit.id)?.googlePlaceID else { return false }
        return memory.googleMenus[placeID] != nil
    }

    /// Korean names for a menu printed only in another script, kept on the
    /// menu itself so chips, review names and later visits all read them.
    func fillKoreanNames(for visit: Visit) async {
        guard !AppLanguage.current.isEnglish, let placeID = confirmedPlaces[visit.id]?.googlePlaceID,
              let menu = memory.googleMenus[placeID] else { return }
        let missing = menu.items.filter { $0.localName == nil && $0.shown.unicodeScalars.allSatisfy { !(0xAC00...0xD7A3).contains($0.value) } }
        guard !missing.isEmpty else { return }
        let korean = await ReviewDrafter.koreanNames(missing.map(\.shown))
        guard !korean.isEmpty, var now = memory.googleMenus[placeID] else { return }
        for i in now.items.indices where now.items[i].localName == nil {
            if let k = korean[now.items[i].shown] { now.items[i].localName = k }
        }
        memory.googleMenus[placeID] = now
        saveMemory()
        for one in visits where confirmedPlaces[one.id]?.googlePlaceID == placeID {
            menuNames[one.id] = Self.names(of: now)
        }
    }

    /// The English app's names for a menu that has none in English, asked
    /// once per menu per run.
    func fillEnglishNames(for visit: Visit) async {
        guard AppLanguage.current.isEnglish, let placeID = confirmedPlaces[visit.id]?.googlePlaceID,
              let menu = memory.googleMenus[placeID], !englishAsked.contains(placeID),
              let key = PlaceMatcher.openAIKey else { return }
        let missing = menu.items.filter { Self.isDish($0.name) && MenuEnglish.needs($0) }.map(\.name)
        guard !missing.isEmpty else { return }
        englishAsked.insert(placeID)
        namingInEnglish.insert(visit.id)
        defer { namingInEnglish.remove(visit.id) }
        print("[MenuEnglish] \(missing.count) names at \(confirmedPlaces[visit.id]?.name ?? placeID)")
        guard let english = await MenuEnglish.names(missing, place: confirmedPlaces[visit.id]?.name ?? "", key: key),
              !english.isEmpty, var now = memory.googleMenus[placeID] else { return }
        for i in now.items.indices where MenuEnglish.needs(now.items[i]) {
            if let e = english[now.items[i].name] { now.items[i].english = e }
        }
        memory.googleMenus[placeID] = now
        saveMemory()
        for one in visits where confirmedPlaces[one.id]?.googlePlaceID == placeID {
            menuNames[one.id] = Self.names(of: now)
        }
    }

    /// Google's popular dishes at the visit's place, as printed; none when
    /// the scrape read more than the box (see `names(of:)`).
    func menuHighlights(for visit: Visit) -> [String] {
        guard let placeID = confirmedPlaces[visit.id]?.googlePlaceID, let cached = memory.googleMenus[placeID] else { return [] }
        return cached.highlights.allSatisfy(Self.isDish) ? cached.highlights : []
    }

    func menuFromWeb(for visit: Visit) -> Bool {
        guard let placeID = confirmedPlaces[visit.id]?.googlePlaceID else { return false }
        return memory.googleMenus[placeID]?.fromWeb == true
    }

    func menuItems(for visit: Visit) -> [MenuItem] {
        guard let placeID = confirmedPlaces[visit.id]?.googlePlaceID else { return [] }
        return (memory.googleMenus[placeID]?.items ?? []).filter { Self.isDish($0.name) }
    }

    /// Google's own buttons read as sentences — "주소 복사", "휴대전화로
    /// 보내기", "영업 종료 · 목 오전 11:00에 영업 시작", "전화: +81 3-0000-0000",
    /// "리뷰 41건에서 드미글라스이(가) 언급됨" — and a scrape that missed the
    /// menu box offered all of them as dishes. The scraper no longer gathers
    /// them; this keeps the ones already saved out of the suggestions without
    /// rewriting anyone's stored menu behind their back.
    ///
    /// Measured over the 567 names already on disk: it drops 153 and loses no
    /// real dish. The length allowance is 80 because real menus run long in
    /// two languages — "닭가슴살 & 구운야채 부리또 볼 Chicken Brest & Grilled
    /// Vegetable Burrito Bowl" is 66.
    nonisolated static func isDish(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80 else { return false }
        // Headings, not dishes: "메뉴 전체" arrived as a dish from a search
        // that found nothing. Of 1,482 stored names, 11
        // looked like this — 메뉴 전체, 단품요리, 식사류, 주류, 추천메뉴, 음료,
        // 디저트. Not "name equals its section": Soupe du Jour is both.
        if text.range(of: #"^(메뉴 ?전체|전체 ?메뉴|(추천|대표|인기|세트|시즌|사이드|기타) ?메뉴|신메뉴|메뉴|단품 ?요리|주류|음료|디저트|식사|사이드|[가-힣]{1,4}류)$"#,
                      options: .regularExpression) != nil { return false }
        // Kind and tab names in English: a menu search answered with a
        // site's category list — pizza, pasta, Salad & Brunch, Special Menu —
        // under a section called 카테고리 (Grok).
        if text.range(of: #"^((all|special|main|set|lunch|dinner|brunch|today'?s) ?)?(menu|menus|pizzas?|pastas?|salads?|brunch|desserts?|drinks|beverages?|mains?|appetizers?|starters?|sides|specials?)( ?(&|and|/) ?(salads?|brunch|pastas?|pizzas?|drinks|desserts?))?$"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if ["삭제", "좋아요", "공유", "저장", "스트리트 뷰", "수정 제안하기",
            "사진 및 동영상 추가", "플러스 코드 자세히 알아보기"].contains(text) { return false }
        if text.contains("·") || text.contains(":") { return false }
        for word in ["영업", "전화", "웹사이트", "주소", "오전", "오후", "리뷰", "평점", "Plus Code", "플러스 코드"]
        where text.contains(word) { return false }
        for tail in ["하기", "복사", "보내기", "더보기", "길찾기"] where text.hasSuffix(tail) { return false }
        // +81 3-…, 050-…
        if text.range(of: "\\+[0-9]", options: .regularExpression) != nil { return false }
        if text.range(of: "[0-9][0-9\\- ]{6,}", options: .regularExpression) != nil { return false }
        if text.range(of: "^좋아요( [0-9]+개)?$", options: .regularExpression) != nil { return false }
        return true
    }

    private static func names(of cached: Memory.CachedGoogleMenu) -> [String] {
        // In the app's language: 판콘 토마테, not Pan Con Tomate.
        let items = cached.items.filter { isDish($0.name) }.map(\.shown)
        // Highlights are all or nothing. They are gathered from one box on the
        // page, so a single button among them means the scrape missed the box
        // and read the whole panel — the neighbouring restaurants it picked up
        // there (a skewer bar beside a 함박스테이크 place) read as
        // dishes and cannot be told apart one by one.
        let clean = cached.highlights.allSatisfy(isDish) ? cached.highlights : []
        return items + clean.filter { h in !items.contains { $0.contains(h) } }
    }

    private let fetcher = MenuFetcher()

    /// Show what was already read and named for this visit, without reading
    /// anything new. Reading is the user's call (`loadMenu`).
    func restoreMenu(for visit: Visit) async {
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID else { return }
        if let cached = memory.googleMenus[placeID], !(cached.items.isEmpty && cached.highlights.isEmpty) {
            menuNames[visit.id] = Self.names(of: cached)
        }
        photoDishes[visit.id] = memory.photoDishes[visit.id] ?? [:]
        photoSuggestions[visit.id] = memory.photoSuggestions[visit.id] ?? [:]
        photoKinds[visit.id] = memory.photoKinds[visit.id] ?? [:]
    }

    /// Get the confirmed place's menu from its Google Maps page — read inside
    /// the app by `MenuFetcher`, no browser or extension involved — then name
    /// this visit's photos with it. Cached per place; `again` re-reads.
    func loadMenu(for visit: Visit, again: Bool = false) async {
        await Usage.stage(visit.title, "메뉴 읽기") { await loadMenuWork(for: visit, again: again) }
    }

    private func loadMenuWork(for visit: Visit, again: Bool = false) async {
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID else {
            print("[MenuFetcher] \(visit.title): no confirmed Google place — nothing to read")
            menuHint[visit.id] = String(localized: "가게가 확정돼야 메뉴를 읽을 수 있어요. 가게 단계에서 골라 주세요.")
            return
        }
        print("[MenuFetcher] \(visit.title): menu \(again ? "re-read" : "read") requested for \(place.name)")
        // Reading a place whose Google page has no menu comes back empty, and
        // the empty answer is only cached for a day — so pressing the button
        // again opened the page again, five seconds each time, for nothing.
        // Within a session, once is enough.
        if !again, readThisSession.contains(placeID) {
            menuHint[visit.id] = memory.googleMenus[placeID].map { $0.items.isEmpty && $0.highlights.isEmpty }  == true
                ? String(localized: "방금 찾아봤는데 웹에 이 가게 메뉴가 없어요. 이름은 직접 적어 주세요.")
                : String(localized: "방금 찾아온 메뉴예요.")
            return
        }
        if !again, let cached = memory.googleMenus[placeID],
           Date().timeIntervalSince(cached.fetchedAt) < Self.placeCacheLife {
            menuNames[visit.id] = Self.names(of: cached)
            await nameDishes(for: visit)
            return
        }
        readThisSession.insert(placeID)
        awaitingMenu[placeID, default: []].insert(visit.id)
        menuLoading.insert(visit.id)
        menuHint[visit.id] = nil
        guard !fetchingMenu.contains(placeID) else { return }
        fetchingMenu.insert(placeID)
        // The web search, not the Google Maps page. The page read was free
        // and, when it worked, took six to nine seconds — but then it stopped
        // working at all (12 reads, 0 menus, 30s each) while the search kept
        // answering in five to ten for a few cents. So the search it is. This
        // is the app's own path now, so it
        // does not draw on the weekly allowance the hand-pressed searches do.
        guard let key = PlaceMatcher.openAIKey else {
            fetchingMenu.remove(placeID)
            for id in awaitingMenu[placeID] ?? [] {
                menuLoading.remove(id)
                menuHint[id] = String(localized: "OpenAI 키가 없어 메뉴를 못 찾아요. 이름은 직접 적어 주세요.")
            }
            awaitingMenu[placeID] = nil
            return
        }
        // Three sides searched at once and merged — one press is the whole
        // menu. The Google Maps page is not read: the
        // same place came back without its 메뉴 tab seven loads running.
        // The photos are matched afterwards by the namer, against this list.
        print("[DishSearch] reading \(place.name) (\(placeID)) from the web, three sides")
        let found = await DishSearch.findFullMenu(place: place, key: key)
        let items = (found?.items ?? []).filter { Self.isDish($0.name) }
        let empty = items.isEmpty
        // An empty answer expires after a day, a real one after the usual month.
        let fetchedAt = empty ? Date().addingTimeInterval(-Self.placeCacheLife + 24 * 3600) : Date()
        let cached = Memory.CachedGoogleMenu(fetchedAt: fetchedAt, highlights: [], photoURLs: [], items: items, fromWeb: true)
        // A failed search (no side answered) leaves whatever was there, and
        // so does a search again that found less food than was on hand.
        let had = memory.googleMenus[placeID].map { DishSearch.foodCount($0.items, category: place.category) } ?? -1
        if found != nil, DishSearch.foodCount(items, category: place.category) >= had { memory.googleMenus[placeID] = cached }
        if let found, !found.notes.isEmpty { memory.deepSearchNotes[placeID] = found.notes.joined(separator: " / ") }
        saveMemory()
        // On the ledger: how many of each kind and the names, so a menu with
        // no 음료 or a short list shows without opening memory.json.
        let byKind = Dictionary(grouping: items) { $0.section.isEmpty ? "그 외" : $0.section }
            .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: " · ")
        Usage.local(tag: "메뉴 결과",
                    detail: found == nil ? "실패 — 답이 없음"
                        : "\(place.name): \(items.count)개 · \(byKind) | " + items.map(\.shown).joined(separator: ", "),
                    seconds: 0)
        print("[DishSearch] \(place.name): \(items.count) items" + (found.map { " | " + $0.notes.joined(separator: " / ") } ?? " | nothing"))
        // Done fetching before the waiting visits are named: one that asked
        // while they were named found the fetch still marked running, was
        // left waiting with nobody to answer it, and showed "메뉴 찾는 중"
        // for good.
        fetchingMenu.remove(placeID)
        let waiting = awaitingMenu[placeID] ?? []
        awaitingMenu[placeID] = nil
        for visitID in waiting {
            menuLoading.remove(visitID)
            menuHint[visitID] = found == nil ? String(localized: "연결이 안 돼서 메뉴를 못 찾았어요.")
                : empty ? String(localized: "웹에서 이 가게 메뉴를 못 찾았어요. 이름은 직접 적어 주세요.") : nil
            guard found != nil, let visit = visits.first(where: { $0.id == visitID }) else { continue }
            menuNames[visitID] = Self.names(of: cached)
            // Named again against the new menu, even if named before.
            await nameDishes(for: visit, again: true)
        }
    }

    /// Whether this place's menu was searched in this session already.
    func menuSearchedThisSession(_ placeID: String) -> Bool { readThisSession.contains(placeID) }

    private var fetchingMenu: Set<String> = []
    /// Places whose Google page has already been opened this session.
    private var readThisSession: Set<String> = []

    private func receiveMenu(_ menu: GoogleMenu) async {
        // The menu arrives from the web view long after loadMenu returned, so
        // the reading — and its cost — falls outside that stage's scope.
        let waiting = awaitingMenu[menu.placeId]?.first
        let title = visits.first { $0.id == waiting }?.title ?? menu.name
        await Usage.stage(title, "메뉴 읽기 · 응답") { await receiveMenuWork(menu) }
    }

    private func receiveMenuWork(_ menu: GoogleMenu) async {
        var jpegs: [Data] = []
        for urlString in menu.menuPhotos.prefix(8) {
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            jpegs.append(data)
        }
        // What the page listed as text costs nothing and is already exact;
        // the model only has to read the photographed menu boards.
        var items: [MenuItem] = menu.items
        if !jpegs.isEmpty, let key = PlaceMatcher.openAIKey {
            let read = await MenuReader.read(jpegs: jpegs, key: key) ?? []
            let have = Set(items.map { $0.name })
            items += read.filter { !have.contains($0.name) }
        }
        print("[MenuReader] \(menu.name): \(items.count) items (\(menu.items.count) listed as text, \(jpegs.count) menu photos read); highlights " + menu.highlights.joined(separator: ", "))
        // Nothing on Google Maps (a bakery has no menu tab). A whole-menu web
        // search used to fire here by itself: five searches, $0.13, and at a
        // bakery it returned four frozen-dough products from the online store
        // and nothing from the case. The person asks for that now (`deepSearch`).
        let fromWeb = false
        let empty = items.isEmpty && menu.highlights.isEmpty && menu.items.isEmpty
        // An empty or failed read expires after a day, a real one after the usual month.
        let fetchedAt = empty ? Date().addingTimeInterval(-Self.placeCacheLife + 24 * 3600) : Date()
        let cached = Memory.CachedGoogleMenu(fetchedAt: fetchedAt, highlights: menu.highlights, photoURLs: menu.menuPhotos, items: items, fromWeb: fromWeb)
        memory.googleMenus[menu.placeId] = cached
        saveMemory()
        let waiting = awaitingMenu[menu.placeId] ?? []
        awaitingMenu[menu.placeId] = nil
        for visitID in waiting {
            menuLoading.remove(visitID)
            // Say what came back. Clearing the hint here meant a read that
            // found nothing looked like a button that did nothing: one
            // visit
            // was read three times in a row, five seconds each, in silence.
            menuHint[visitID] = empty
                ? String(localized: "구글 지도에 이 가게 메뉴가 없어요. 이름은 사진만 보고 붙인 거라 전부 추측이에요 — 딥서치로 메뉴를 찾아볼 수 있어요.")
                : nil
            guard let visit = visits.first(where: { $0.id == visitID }) else { continue }
            menuNames[visitID] = Self.names(of: cached)
            await nameDishes(for: visit)
        }
    }

    /// Name the photographed dishes with the menu. Once per (visit, place);
    /// what the user typed is never overwritten.
    /// `again`: name the photos even if they were named before — a new menu
    /// has just arrived.
    func nameDishes(for visit: Visit, again: Bool = false) async {
        await Usage.stage(visit.title, "음식 이름 붙이기") { await nameDishesWork(for: visit, again: again) }
    }

    private func nameDishesWork(for visit: Visit, again: Bool = false) async {
        await waitWhileNaming(visit)
        await fillEnglishNames(for: visit)
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID,
              let cached = memory.googleMenus[placeID], !naming.contains(visit.id) else { return }
        photoDishes[visit.id] = memory.photoDishes[visit.id] ?? [:]
        if !again, let kept = memory.photoSuggestions[visit.id], memory.rotationJudged.contains(visit.id) {
            photoSuggestions[visit.id] = kept
            photoKinds[visit.id] = memory.photoKinds[visit.id] ?? [:]
            return
        }
        guard let key = PlaceMatcher.openAIKey else { return }
        naming.insert(visit.id)
        defer { naming.remove(visit.id) }
        // Every photo, in the order the grid shows them: each gets a kind, and
        // the ones that are food get a name.
        var sent: [(id: String, jpeg: Data)] = []
        for photo in visit.photos.prefix(12) {
            if let jpeg = await reducedJPEG(for: photo, maxPixel: 768) { sent.append((photo.id, jpeg)) }
        }
        guard !sent.isEmpty else { return }
        print("[MenuNamer] naming \(visit.title) at \(place.name): \(sent.count) photos, \(cached.items.count) items, \(cached.highlights.count) highlights")
        guard let result = await MenuNamer.name(photos: sent, place: place, items: cached.items, highlights: cached.highlights, key: key) else { return }
        let committed = memory.photoDishes[visit.id] ?? [:]
        var suggestions: [String: String] = [:]
        var kinds: [String: DishNaming.Kind] = [:]
        for entry in result.photos {
            kinds[entry.photoID] = entry.kind
            // The model's rotation call, unless the user already turned it.
            // Never for a video: the namer sees one still of it, the player
            // and the posted file never took the turn, and a landscape clip
            // showed turned on its tile.
            let isVideo = visit.photos.first { $0.id == entry.photoID }?.isVideo == true
            if !isVideo, userRotated[entry.photoID] != true, entry.rotate != (memory.photoRotations[entry.photoID] ?? 0) {
                memory.photoRotations[entry.photoID] = entry.rotate
                photoRotations[entry.photoID] = entry.rotate
                draggableURLs[entry.photoID] = nil
                print("[MenuNamer] rotate \(entry.photoID.prefix(8)) by \(entry.rotate)°")
            }
            // A photo can hold a whole order — cookie, latte, the drink beside
            // them — and they go in the one field, comma separated. In the
            // words a review would use, not the menu's (no shop name glued on).
            let named = entry.dishes.map(\.reviewName).joined(separator: ", ")
            guard (committed[entry.photoID] ?? "").isEmpty, !named.isEmpty else { continue }
            // A guess is offered, never written in: it was wrong too often to
            // count as the photo's name — ✓, 리뷰에 들어갈 것 and the drafts
            // take only what the person adds or accepts (this reverses an
            // earlier "fill the guesses in").
            suggestions[entry.photoID] = named
        }
        let before = dishNames(for: visit)
        memory.photoSuggestions[visit.id] = suggestions
        memory.photoKinds[visit.id] = kinds
        memory.rotationJudged.insert(visit.id)
        photoSuggestions[visit.id] = suggestions
        photoKinds[visit.id] = kinds
        if dishNames(for: visit) != before { invalidateDraftOptions(for: visit) }
        saveMemory()
        let byOrder = visit.photos.compactMap { photo -> String? in
            guard let entry = result.photos.first(where: { $0.photoID == photo.id }) else { return nil }
            let named = entry.dishes.map { "\($0.name)\($0.fromMenu ? "✓" : "?")(\($0.shows))" }.joined(separator: "+")
            return "\(entry.kind.rawValue)" + (named.isEmpty ? "" : ":\(named)")
        }
        print("[MenuNamer] \(visit.title): " + byOrder.enumerated().map { "\($0 + 1) \($1)" }.joined(separator: " | "))
    }

    private func waitWhileNaming(_ visit: Visit) async {
        while naming.contains(visit.id) || menuLoading.contains(visit.id) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Name one photo again. Not a saving — the batch call is cheaper per
    /// photo than singles — but the way to fix one wrong name without
    /// redoing the visit, and without the person typing what the model can
    /// read off the plate.
    @Published private(set) var renaming: Set<String> = []

    func renamePhoto(_ photo: Photo, in visit: Visit) async {
        guard let place = confirmedPlaces[visit.id], let key = PlaceMatcher.openAIKey,
              !renaming.contains(photo.id) else { return }
        renaming.insert(photo.id)
        defer { renaming.remove(photo.id) }
        guard let jpeg = await reducedJPEG(for: photo, maxPixel: 768) else { return }
        let cached = place.googlePlaceID.flatMap { memory.googleMenus[$0] }
        let result = await Usage.stage(visit.title, "이름 다시 붙이기") {
            await MenuNamer.name(photos: [(id: photo.id, jpeg: jpeg)], place: place,
                                 items: cached?.items ?? [], highlights: cached?.highlights ?? [], key: key)
        }
        guard let entry = result?.photos.first, !entry.dishes.isEmpty else { return }
        let named = entry.dishes.map(\.name).joined(separator: ", ")
        var kinds = memory.photoKinds[visit.id] ?? [:]
        kinds[photo.id] = entry.kind
        memory.photoKinds[visit.id] = kinds
        photoKinds[visit.id] = kinds
        setPhotoDish(named, for: photo, in: visit)
        var guesses = memory.photoSuggestions[visit.id] ?? [:]
        guesses[photo.id] = entry.fromMenu ? nil : named
        memory.photoSuggestions[visit.id] = guesses
        photoSuggestions[visit.id] = guesses
        saveMemory()
        print("[MenuNamer] again \(visit.title): " + entry.dishes.map { "\($0.name)\($0.fromMenu ? "✓" : "?")(\($0.shows))" }.joined(separator: " + "))
    }

    // MARK: - 딥서치

    /// A web search for what this place sells, then the namer over the visit's
    /// photos with what came back. The dearest call in the app, so the person
    /// presses it and an allowance limits how often.
    #if DEBUG
    /// Unmetered in the build run from source: the allowance exists to keep a
    /// stranger's bill down, and it gets in the way of testing the thing it
    /// is metering.
    static let deepSearchLimit = Int.max
    #else
    static let deepSearchLimit = 3
    #endif
    static var metered: Bool { deepSearchLimit < 100 }
    private static let deepSearchWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Searches left in the rolling week.
    var deepSearchesLeft: Int {
        let since = Date().addingTimeInterval(-Self.deepSearchWindow)
        return max(0, Self.deepSearchLimit - memory.deepSearches.filter { $0 > since }.count)
    }

    /// When the oldest spent search falls out of the window, for the tooltip.
    var deepSearchRenews: Date? {
        let since = Date().addingTimeInterval(-Self.deepSearchWindow)
        return memory.deepSearches.filter { $0 > since }.min()?.addingTimeInterval(Self.deepSearchWindow)
    }

    /// One photo, searched on its own — the fallback when the place-wide
    /// search came back without the thing actually on the table.
    /// Photos still without a name, asked about together.
    ///
    /// One at a time this is $0.045 and 7 seconds EACH — measured over 14
    /// calls — because each one runs its own web search. A five-photo table
    /// came to $0.23. Together it is one search, and the extra photos cost
    /// tokens rather than searches, so it lands near the price of a single
    /// one and spends one of the week's allowance instead of five.
    func deepSearchPhotos(in visit: Visit) async {
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID,
              let key = PlaceMatcher.openAIKey,
              !deepSearching.contains(visit.id), deepSearchesLeft > 0 else { return }
        let waiting = unnamedPhotos(in: visit)
        guard !waiting.isEmpty else { return }
        deepSearching.insert(visit.id)
        for photo in waiting { deepSearching.insert(photo.id) }
        defer {
            deepSearching.remove(visit.id)
            for photo in waiting { deepSearching.remove(photo.id) }
        }
        var jpegs: [Data] = []
        var sent: [Photo] = []
        for photo in waiting.prefix(12) {
            guard let jpeg = await reducedJPEG(for: photo, maxPixel: 768) else { continue }
            jpegs.append(jpeg); sent.append(photo)
        }
        guard !jpegs.isEmpty else { return }
        let found = await Usage.stage(visit.title, "딥서치 · 사진 \(jpegs.count)장") {
            await DishSearch.find(jpegs: jpegs, place: place, known: menuNames[visit.id] ?? [],
                                  language: AppLanguage.current.isEnglish ? "English" : "Korean", key: key)
        }
        // Billed whether or not anything came back, so it spends either way.
        memory.deepSearches.append(Date())
        guard let found else {
            for photo in sent {
                deepSearchNote[photo.id] = String(localized: "웹에서 이 사진 메뉴를 못 찾았어요.")
                memory.deepSearchNotes[photo.id] = deepSearchNote[photo.id]
            }
            saveMemory()
            return
        }
        // What it read belongs to the place's menu as much as to these photos.
        let existing = memory.googleMenus[placeID]
        var items = existing?.items ?? []
        let have = Set(items.map { $0.name })
        items += found.items.filter { !have.contains($0.name) }
        memory.googleMenus[placeID] = Memory.CachedGoogleMenu(
            fetchedAt: Date(), highlights: existing?.highlights ?? [], photoURLs: existing?.photoURLs ?? [],
            items: items, fromWeb: true)
        menuNames[visit.id] = Self.names(of: memory.googleMenus[placeID]!)
        for (index, photo) in sent.enumerated() {
            if let names = found.names[index], !names.isEmpty {
                setPhotoDish(names.joined(separator: ", "), for: photo, in: visit)
                deepSearchNote[photo.id] = found.evidence
            } else {
                deepSearchNote[photo.id] = String(localized: "이 사진은 웹에서도 못 찾았어요.")
            }
            memory.deepSearchNotes[photo.id] = deepSearchNote[photo.id]
        }
        saveMemory()
        print("[DishSearch/batch] \(visit.title) at \(place.name): \(found.names.count)/\(sent.count) named | " + found.evidence)
    }

    /// Photos of this visit that still have no dish written against them.
    func unnamedPhotos(in visit: Visit) -> [Photo] {
        let written = memory.photoDishes[visit.id] ?? [:]
        return visit.photos.filter { photo in
            guard photo.isFood, !memory.hidden.contains(photo.id) else { return false }
            return (written[photo.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
    }

    func deepSearch(photo: Photo, in visit: Visit) async {
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID,
              let key = PlaceMatcher.openAIKey,
              !deepSearching.contains(photo.id), deepSearchesLeft > 0 else { return }
        deepSearching.insert(photo.id)
        defer { deepSearching.remove(photo.id) }
        guard let jpeg = await reducedJPEG(for: photo, maxPixel: 768) else { return }
        let found = await Usage.stage(visit.title, "딥서치 · 사진") {
            await DishSearch.find(jpeg: jpeg, place: place, known: menuNames[visit.id] ?? [],
                                  language: AppLanguage.current.isEnglish ? "English" : "Korean", key: key)
        }
        memory.deepSearches.append(Date())
        guard let found, !found.items.isEmpty else {
            deepSearchNote[photo.id] = String(localized: "웹에서 이 사진 메뉴를 못 찾았어요.")
            memory.deepSearchNotes[photo.id] = deepSearchNote[photo.id]
            saveMemory()
            return
        }
        // What it found belongs to the place's menu as much as to this photo.
        let existing = memory.googleMenus[placeID]
        var items = existing?.items ?? []
        let have = Set(items.map { $0.name })
        items += found.items.filter { !have.contains($0.name) }
        memory.googleMenus[placeID] = Memory.CachedGoogleMenu(
            fetchedAt: Date(), highlights: existing?.highlights ?? [], photoURLs: existing?.photoURLs ?? [],
            items: items, fromWeb: true)
        menuNames[visit.id] = Self.names(of: memory.googleMenus[placeID]!)
        setPhotoDish(found.items.map(\.name).joined(separator: ", "), for: photo, in: visit)
        deepSearchNote[photo.id] = found.evidence
        memory.deepSearchNotes[photo.id] = found.evidence
        saveMemory()
        print("[DishSearch] photo \(photo.id.prefix(8)) at \(place.name): "
              + found.items.map(\.name).joined(separator: " + ") + " | " + found.evidence)
    }

    func deepSearch(for visit: Visit) async {
        guard let place = confirmedPlaces[visit.id], let placeID = place.googlePlaceID else {
            menuHint[visit.id] = String(localized: "가게가 정해져야 딥서치할 수 있어요.")
            return
        }
        guard let key = PlaceMatcher.openAIKey, !deepSearching.contains(visit.id), deepSearchesLeft > 0 else { return }
        deepSearching.insert(visit.id)
        defer { deepSearching.remove(visit.id) }
        menuHint[visit.id] = String(localized: "웹에서 \(place.name) 메뉴를 찾는 중…")
        let found = await Usage.stage(visit.title, "딥서치") {
            await DishSearch.find(place: place, language: AppLanguage.current.isEnglish ? "English" : "Korean", key: key)
        }
        // The search was billed whether or not it came back with names, so it
        // spends the allowance either way.
        memory.deepSearches.append(Date())
        guard let found, !found.items.isEmpty else {
            menuHint[visit.id] = String(localized: "웹에서도 이 가게 메뉴를 못 찾았어요. 이름은 직접 적어 주세요.")
            saveMemory()
            print("[DishSearch] \(visit.title) at \(place.name): nothing found")
            return
        }
        // Keep whatever Google Maps gave (highlights, prices) and add these.
        let existing = memory.googleMenus[placeID]
        var items = existing?.items ?? []
        let have = Set(items.map { $0.name })
        items += found.items.filter { !have.contains($0.name) }
        memory.googleMenus[placeID] = Memory.CachedGoogleMenu(
            fetchedAt: Date(), highlights: existing?.highlights ?? [], photoURLs: existing?.photoURLs ?? [],
            items: items, fromWeb: true)
        menuNames[visit.id] = Self.names(of: memory.googleMenus[placeID]!)
        memory.deepSearchNotes[visit.id] = found.evidence
        deepSearchNote[visit.id] = found.evidence
        menuHint[visit.id] = found.evidence
        saveMemory()
        print("[DishSearch] \(visit.title) at \(place.name): \(found.items.count) items — "
              + found.items.prefix(12).map(\.name).joined(separator: ", ") + " | " + found.evidence)
        // Name the photos again from the fuller menu: the earlier naming ran
        // against whatever Google had, which for these places was nothing.
        // Names the person never touched — still exactly as guessed — go, so
        // the new menu can replace them; anything they typed stays.
        var kept = memory.photoDishes[visit.id] ?? [:]
        for (photoID, guess) in memory.photoSuggestions[visit.id] ?? [:] where kept[photoID] == guess {
            kept[photoID] = nil
        }
        memory.photoDishes[visit.id] = kept
        photoDishes[visit.id] = kept
        memory.photoSuggestions[visit.id] = nil
        photoSuggestions[visit.id] = nil
        memory.rotationJudged.remove(visit.id)
        await nameDishes(for: visit)
    }

    func setPhotoDish(_ name: String, for photo: Photo, in visit: Visit) {
        var names = memory.photoDishes[visit.id] ?? [:]
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A slip in a typed name, against this menu and the dish dictionary:
        // "차돌밖이" → "차돌박이". One letter only, and never when the name is
        // already one the menu or the dictionary knows.
        let menu = menuItems(for: visit).map(\.shown)
        // One field can hold a whole order — "쑥 앙금호두 쿠키, 아메리카노" — so
        // each part is corrected on its own and the commas are left alone.
        let parts = Self.dishParts(cleaned)
        let corrected = parts.map { part -> String in
            guard let fixed = DishSpelling.corrected(part, menu: menu, vocabulary: ReviewDrafter.knownDishes) else { return part }
            print("[Dish] spelling: \(part) → \(fixed)")
            return fixed
        }
        if !corrected.isEmpty { cleaned = corrected.joined(separator: ", ") }
        names[photo.id] = cleaned.isEmpty ? nil : cleaned
        guard memory.photoDishes[visit.id] != names else { return }
        let before = dishNames(for: visit)
        memory.photoDishes[visit.id] = names
        photoDishes[visit.id] = names
        // The guess stays on offer: taking one dish of it must leave the
        // others in 추천 (they hide once added).
        if dishNames(for: visit) != before { invalidateDraftOptions(for: visit) }
        saveMemory()
    }

    /// The three genre takes were written with the old dish names; drop them
    /// so the next "리뷰 문장 만들기" writes with the new ones. The chosen final
    /// text stays — it may already carry the user's edits.
    private func invalidateDraftOptions(for visit: Visit) {
        guard memory.options[visit.id] != nil || reviewOptions[visit.id] != nil else { return }
        memory.options[visit.id] = nil
        reviewOptions[visit.id] = nil
    }

    /// What the drafts call the food: committed names in photo order, once each.
    func dishNames(for visit: Visit) -> [String] {
        let names = photoDishes[visit.id] ?? memory.photoDishes[visit.id] ?? [:]
        var seen: [String] = []
        for photo in visit.photos {
            for part in Self.dishParts(names[photo.id] ?? "") where !seen.contains(part) { seen.append(part) }
        }
        return seen
    }

    /// One photo often carries a whole order — a cookie and the coffee beside
    /// it — and the review has to name both. A comma separates them, the way
    /// the predecessor engine always read a memo: it is a hard boundary,
    /// never inside a name.
    static func dishParts(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "·" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Review draft

    /// Rotations the user set by hand this session win over the model's.
    private var userRotated: [String: Bool] = [:]

    func rotation(of photo: Photo) -> Int { photoRotations[photo.id] ?? 0 }

    /// ↻ on a tile: a quarter turn clockwise, remembered, applied to the
    /// tile and to every copy made from now on.
    func rotate(_ photo: Photo) {
        let next = ((photoRotations[photo.id] ?? 0) + 90) % 360
        photoRotations[photo.id] = next
        memory.photoRotations[photo.id] = next
        userRotated[photo.id] = true
        draggableURLs[photo.id] = nil
        saveMemory()
    }

    var googleAccount: String { memory.googleAccount }
    func setGoogleAccount(_ account: String) {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard memory.googleAccount != trimmed else { return }
        memory.googleAccount = trimmed
        saveMemory()
        objectWillChange.send()
    }

    func note(for visit: Visit) -> String { memory.notes[visit.id] ?? "" }
    func rating(for visit: Visit) -> Int { memory.ratings[visit.id] ?? 0 }

    func setNote(_ note: String, for visit: Visit) {
        guard memory.notes[visit.id] != note else { return }
        memory.notes[visit.id] = note
        saveMemory()
    }

    /// The stars set the review's tone when a draft is written; changing
    /// them afterwards does not throw the drafts away (a rewrite on every
    /// star change was annoying — the per-dish ♥ carries the
    /// verdicts now).
    func setRating(_ rating: Int, for visit: Visit) {
        guard memory.ratings[visit.id] != rating else { return }
        memory.ratings[visit.id] = rating
        saveMemory()
        objectWillChange.send()
    }

    /// ♥ is per photo (so it is always there to press, name or not); a dish
    /// counts as liked when any photo captioned with it is.
    func isLiked(photo: Photo, in visit: Visit) -> Bool { likes[visit.id]?.contains(photo.id) ?? false }

    func isLiked(_ dish: String, in visit: Visit) -> Bool {
        if likedDishes[visit.id]?.contains(dish) == true { return true }
        let names = photoDishes[visit.id] ?? memory.photoDishes[visit.id] ?? [:]
        // The heart is on the photo, and a photo may name a whole order, so
        // every dish in a liked photo counts as liked.
        return (likes[visit.id] ?? []).contains { Self.dishParts(names[$0] ?? "").contains(dish) }
    }

    func toggleLike(dish: String, in visit: Visit) {
        var set = likedDishes[visit.id] ?? []
        if set.contains(dish) { set.remove(dish) } else { set.insert(dish) }
        likedDishes[visit.id] = set
        memory.likedDishes[visit.id] = set
        invalidateDraftOptions(for: visit)
        saveMemory()
    }

    func toggleLike(photo: Photo, in visit: Visit) {
        var set = likes[visit.id] ?? []
        if set.contains(photo.id) { set.remove(photo.id) } else { set.insert(photo.id) }
        likes[visit.id] = set
        memory.likes[visit.id] = set
        invalidateDraftOptions(for: visit)
        saveMemory()
    }

    /// Three genre takes for a visit whose place is confirmed. Kept ones are
    /// shown again unless `again`, which rolls three new genres.
    func draftReview(for visit: Visit, again: Bool = false) async {
        await Usage.stage(visit.title, "리뷰 초안") { await draftReviewWork(for: visit, again: again) }
    }

    private func draftReviewWork(for visit: Visit, again: Bool = false) async {
        await waitWhileNaming(visit)
        guard let place = confirmedPlaces[visit.id], !drafting.contains(visit.id) else { return }
        if !again, let kept = memory.options[visit.id], !kept.isEmpty {
            reviewOptions[visit.id] = kept
            if let chosen = memory.drafts[visit.id] { reviewDrafts[visit.id] = chosen }
            return
        }
        guard PlaceMatcher.openAIKey != nil else {
            print("[ReviewDraft] no OpenAI key")
            return
        }
        drafting.insert(visit.id)
        defer { drafting.remove(visit.id); draftStage[visit.id] = nil }
        let visitID = visit.id
        await ReviewDrafter.$report.withValue({ stage in
            Task { @MainActor [weak self] in
                guard let self, self.drafting.contains(visitID) else { return }
                self.draftStage[visitID] = stage
            }
        }) {
            await draftWork(for: visit, again: again, place: place)
        }
    }

    private func draftWork(for visit: Visit, again: Bool, place: PlaceCandidate) async {

        // The v3 engine: dish names in, one card per style; no
        // photos, no place.
        // First draw = the plain line + two styles; "다른 표현으로" = three
        // styles, from families not shown last time.
        let shownBefore = Set(memory.options[visit.id]?.map(\.genre) ?? [])
        let firstDraw = shownBefore.isEmpty
        // Four on the first draw (the feed shows one at a time and the
        // person swipes through), three on a redraw.
        let styles: [ReviewGenre?] = firstDraw
            ? [nil] + ReviewDrafter.draw(3, avoiding: shownBefore)
            : ReviewDrafter.draw(3, avoiding: shownBefore)
        // The user's dish names first; the matcher's descriptions only before
        // any naming has happened.
        let named = dishNames(for: visit)
        // The matcher's guesses stand in only when the person wrote nothing at
        // all — a visit with 전망 alone is about the place, not the food.
        // Nothing named yet (a card prepared ahead for the feed): the photos'
        // guesses, then the matcher's dishes.
        let guessed = visit.photos.flatMap { Self.dishParts(memory.photoSuggestions[visit.id]?[$0.id] ?? "") }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let asNamed = named.isEmpty
            ? ((memory.tags[visit.id] ?? []).isEmpty ? (guessed.isEmpty ? (placeMatches[visit.id]?.dishes.map(\.name) ?? []) : guessed) : [])
            : named
        let liked = Set(asNamed.filter { isLiked($0, in: visit) }.map { reviewName(for: $0, in: visit) })
        let disliked = Set(asNamed.filter { VisitThreads.shared.taste(of: $0, in: visit.id) == .bad }.map { reviewName(for: $0, in: visit) })
        // Written as a review says them, not as the menu or the field holds
        // them; one name once.
        let dishes = asNamed.map { reviewName(for: $0, in: visit) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        print("[ReviewDraft] drafting \(visit.title) at \(place.name): dishes " + dishes.joined(separator: " / ") + ", styles " + styles.map { $0?.name ?? "담백" }.joined(separator: "/"))
        // The tag lines write from the photos the namer called place or
        // other — the room, the view, the front. Never a food photo: handed
        // a table of plates for "Great view", the writer made the view out
        // of the plates. With none, the remark is said
        // in general terms.
        let chosenTags = memory.tags[visit.id] ?? []
        var placePhotos: [Data] = []
        if !chosenTags.isEmpty {
            let kinds = memory.photoKinds[visit.id] ?? [:]
            let scenery = visit.photos.filter { (kinds[$0.id] ?? .food) != .food }
            for photo in scenery.prefix(3) {
                if let jpeg = await reducedJPEG(for: photo, maxPixel: 768) { placePhotos.append(jpeg) }
            }
        }
        guard let drafts = await ReviewDrafter.drafts(
            dishes: dishes, liked: liked, disliked: disliked, tags: chosenTags,
            abouts: Dictionary(asNamed.compactMap { name in
                menuItem(named: name, in: visit)?.about.map { (reviewName(for: name, in: visit), $0) }
            }, uniquingKeysWith: { a, _ in a }),
            place: [place.name, visit.coordinate.flatMap { VisitCity.known(at: $0) } ?? place.address].compactMap { $0 }.joined(separator: ", "),
            placePhotos: placePhotos,
            setting: Self.setting(of: visit, place: place),
            note: memory.notes[visit.id], styles: styles, key: PlaceMatcher.openAIKey ?? "",
            // Signed in with ChatGPT, the cards are written on the plan too:
            // everything on the subscription, Grok's key unused. Otherwise
            // the Grok writer.
            models: Brain.subscriptionReady ? [ReviewDrafter.model] : (ReviewDrafter.comparing ?? [ReviewDrafter.model])
        ) else {
            print("[ReviewDraft] nothing came back for \(visit.title)")
            return
        }
        // Stopped part way (the person moved on): what came back is not a
        // set of drafts — one visit kept the one plain card that had
        // returned and asked to pick from it.
        guard !Task.isCancelled else {
            print("[ReviewDraft] \(visit.title): stopped, \(drafts.count) cards dropped")
            return
        }
        memory.options[visit.id] = drafts
        saveMemory()
        reviewOptions[visit.id] = drafts
        for draft in drafts { print("[ReviewDraft] \(visit.title) · \(draft.genre)\(draft.modelTag.map { " [\($0)]" } ?? ""): \(draft.text.replacingOccurrences(of: "\n", with: " / "))") }
    }

    /// A menu name as a review would say it: words that only repeat the
    /// shop's own name are dropped from the front — "Daybreak Breakfast
    /// Grilled Chicken" at "Daybreak Coffee and Breakfast" → "Grilled
    /// Chicken". Nothing is dropped if nothing would be
    /// left.
    static func reviewName(_ name: String, place: String) -> String {
        // Only when the name opens with the shop's own first word (its
        // brand): "Coffee Latte" at a shop called "… Coffee" keeps its Coffee.
        // A brand glued to the rest of the shop's name counts too: "가온" at
        // 가온화로구이. And a bracketed option goes.
        let name = MenuName.withoutNote(name)
        let shopWords = place.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
        guard let brand = shopWords.first else { return name }
        let key = { (word: String) in word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let isShop = { (word: String) -> Bool in
            let k = key(word)
            return k.count >= 2 && shopWords.contains { $0 == k || $0.hasPrefix(k) }
        }
        var words = name.split(separator: " ").map(String.init)
        guard let first = words.first, key(first) == brand || (key(first).count >= 2 && brand.hasPrefix(key(first))) else { return name }
        while words.count > 1, let first = words.first, isShop(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// A name as the review writes it, however it was put on the photo: the
    /// menu's own review name when the menu knows the dish, else the name
    /// with the shop's brand and any bracketed option dropped. The drafts
    /// read names through this, so "가온 마늘갈비살" already on a photo is
    /// written "마늘갈비살".
    func reviewName(for name: String, in visit: Visit) -> String {
        let place = confirmedPlaces[visit.id]?.name ?? ""
        let stripped = Self.reviewName(name, place: place)
        let item = menuItem(named: name, in: visit)
        if let item, let review = item.review?.trimmingCharacters(in: .whitespacesAndNewlines), !review.isEmpty,
           !(AppLanguage.current.isEnglish && MenuName.hasHangul(review)) {
            return review
        }
        // The English app names a printed 島豚あぐーのねぎしゃぶしゃぶ in English.
        if AppLanguage.current.isEnglish, let item, item.english?.isEmpty == false {
            return Self.reviewName(item.shown, place: place)
        }
        return ReviewDrafter.knownKoreanName(ReviewDrafter.spoken(stripped)) ?? stripped
    }

    /// The chip: the Korean name, then the name as the menu prints it in
    /// smaller type — "니쿠타마 우동 Nikutama" (was "부라타 과일 샐러드 (burrata
    /// fruit salad)" before). The draft
    /// says the Korean alone.
    func chipName(for name: String, in visit: Visit) -> (name: String, printed: String?) {
        let key = "\(menuSignature(for: visit))|\(name)"
        if let kept = chipNames[key] { return kept }
        let chip = makeChipName(for: name, in: visit)
        chipNames[key] = chip
        return chip
    }

    /// The menu item a name stands for, by any of the names it goes by.
    /// Kept per menu: each chip asked it of every item, every redraw, and a
    /// pressed chip took seconds to light at a 64-item menu.
    func menuItem(named name: String, in visit: Visit) -> MenuItem? {
        let signature = menuSignature(for: visit)
        if menuAliases[signature] == nil {
            let place = confirmedPlaces[visit.id]?.name ?? ""
            var map: [String: MenuItem] = [:]
            for item in menuItems(for: visit) {
                for alias in [item.name, item.shown, item.localName ?? "", item.english ?? "", Self.reviewName(item.shown, place: place)]
                where !alias.isEmpty && map[alias] == nil {
                    map[alias] = item
                }
            }
            menuAliases[signature] = map
        }
        return menuAliases[signature]?[name]
    }

    /// Changes whenever the visit's menu or its names do.
    private func menuSignature(for visit: Visit) -> String {
        guard let placeID = confirmedPlaces[visit.id]?.googlePlaceID, let items = memory.googleMenus[placeID]?.items else { return visit.id }
        let named = items.reduce(0) { $0 + ($1.english == nil ? 0 : 1) + ($1.localName == nil ? 0 : 2) + ($1.review == nil ? 0 : 4) }
        return "\(placeID)|\(confirmedPlaces[visit.id]?.name ?? "")|\(items.count)|\(named)|\(AppLanguage.current.isEnglish)"
    }

    private func makeChipName(for name: String, in visit: Visit) -> (name: String, printed: String?) {
        let review = reviewName(for: name, in: visit)
        // English: the English name, then the menu's own printing of it
        // under it.
        if AppLanguage.current.isEnglish {
            let item = menuItem(named: name, in: visit)
            let printed = item?.printedOther ?? (name != review && !MenuName.hasHangul(name) ? MenuName.withoutNote(name) : nil)
            return (review, printed.flatMap { $0.isEmpty || $0 == review ? nil : $0 })
        }
        let hangul = { (text: String) in text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) }
        guard hangul(review) else { return (review, nil) }
        let place = confirmedPlaces[visit.id]?.name ?? ""
        let item = menuItems(for: visit).first { [$0.name, $0.shown, $0.localName ?? ""].contains(name) }
        let original = item.map { Self.reviewName(MenuName.split($0.name).english.isEmpty ? $0.name : MenuName.split($0.name).english, place: place) }
            ?? Self.reviewName(name, place: place)
        let printed = MenuName.withoutNote(original).trimmingCharacters(in: .whitespaces)
        guard !printed.isEmpty, printed != review, !hangul(printed) else { return (review, nil) }
        return (review, printed == printed.uppercased() ? printed.capitalized : printed)
    }

    /// "저녁 · 이자카야" — when, and what kind of place.
    static func setting(of visit: Visit, place: PlaceCandidate) -> String {
        let hour = visit.calendar.component(.hour, from: visit.takenAt)
        let english = AppLanguage.current.isEnglish
        let when = switch hour {
        case 5..<11: english ? "morning" : "아침"
        case 11..<15: english ? "lunchtime" : "점심"
        case 15..<18: english ? "afternoon" : "오후"
        case 18..<22: english ? "evening" : "저녁"
        default: english ? "late night" : "밤"
        }
        return [when, place.category].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The user picked one of the three; it becomes the editable final text.
    func postFolder(for visit: Visit) -> URL? { postFolders[visit.id] }

    /// ~/Pictures/Afterplate — ONE folder, holding only the visit being
    /// posted. The same place every time, so a file chooser that was used
    /// there once reopens there (open panels remember their last folder per
    /// app), and the sidebar's Pictures is one click away. By design:
    /// automation is slow to watch; make the folder easy. Afterplate in
    /// Finder's sidebar favorites, which every file dialog shows too —
    /// Google's "사진 추가" in Safari included. Safari's dialog opens wherever
    /// it last was, and the app cannot move it without a permission ruled
    /// out by design; one click on the sidebar gets there from anywhere.
    /// Added once, left alone after that.
    static func addToSidebar(_ folder: URL) {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue() else { return }
        var seed: UInt32 = 0
        let items = (LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
        let paths = items.compactMap { (LSSharedFileListItemCopyResolvedURL($0, 0, nil)?.takeRetainedValue() as URL?)?.standardizedFileURL.path }
        guard !paths.contains(folder.standardizedFileURL.path), let last = items.last else { return }
        // After the last item: the "at the end" marker crashes when passed from Swift.
        _ = LSSharedFileListInsertItemURL(list, last, "Afterplate" as CFString, nil, folder as CFURL, nil, nil)
        print("[Post] added \(folder.path) to the Finder sidebar")
    }

    func postFolderURL(for visit: Visit) -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Afterplate", isDirectory: true)
    }

    /// "<place> <yyyy-MM-dd>", the stem of the files in that folder.
    func postFileStem(for visit: Visit) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = visit.timeZone
        let place = (confirmedPlaces[visit.id]?.name ?? "방문")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(place) \(formatter.string(from: visit.takenAt))"
    }

    func chooseDraft(_ option: GenreDraft, for visit: Visit) {
        print("[ReviewDraft] \(visit.title): picked \(option.id)")
        let draft = ReviewDraft(text: option.text, dishes: placeMatches[visit.id]?.dishes.map(\.name) ?? [], genre: option.genre, model: option.model)
        reviewDrafts[visit.id] = draft
        memory.drafts[visit.id] = draft
        saveMemory()
    }

    /// Copies of this visit's photos, upright JPEGs, in ~/Pictures/Afterplate
    /// — one folder, holding only the visit being posted, so a file chooser
    /// that was used there once reopens there and the sidebar's Pictures is
    /// a click away. Waits for the conversion first. This is the whole of
    /// the app's part in posting: the person pastes the text, presses
    /// 별점 and picks the photos in Google's own form (by design, over three
    /// flavours of automation that each needed a
    /// permission or a login).
    func preparePost(photos: [Photo], for visit: Visit) async -> URL {
        let copies = await prepareForDrag(photos)
        let folder = postFolderURL(for: visit)
        // Empty it, never replace it: a file dialog remembers the folder
        // itself, and a new folder at the same path is a stranger to it.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        var index = 0
        let stem = postFileStem(for: visit)
        // Google's picker hands the page the files in whatever order the open
        // panel is sorted by. The names already run 01, 02, 03 for a name
        // sort; these were all written in the same second, so a date sort had
        // no order at all. Stamp them a minute apart with the first photo
        // newest, which puts it on top under "date added, newest first" too.
        var written: [URL] = []
        for photo in photos {
            guard let url = copies[photo.id] else { continue }
            index += 1
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let destination = folder.appendingPathComponent(String(format: "%@ %02d.%@", stem, index, ext))
            try? FileManager.default.copyItem(at: url, to: destination)
            written.append(destination)
        }
        let now = Date()
        for (offset, url) in written.enumerated() {
            let stamp = now.addingTimeInterval(TimeInterval(-60 * offset))
            try? FileManager.default.setAttributes([.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: url.path)
        }
        Self.addToSidebar(folder)
        print("[Post] \(folder.lastPathComponent): \(index) of \(photos.count) photos ready")
        postFolders[visit.id] = folder
        return folder
    }

    /// "이건 방문 아니에요" / "역시 방문이에요" — the person's own verdict on whether a
    /// visit is a meal at all, which no classifier gets right every time.
    /// `verdict` false: put away for another reason (put off three times),
    /// not a judgement on whether it was a meal — kept off that log.
    func setNotMeal(_ isNot: Bool, for visit: Visit, verdict: Bool = true) {
        // The person's own verdict on whether this was a visit worth
        // reviewing — the thing the classifier is guessing at. Logged with
        // the scores as they stood, so the disagreements can be read back.
        if verdict { Usage.archive(
            visit: visit.fullTitle, put: isNot,
            photos: visit.photos.count, videos: visit.photos.filter(\.isVideo).count,
            food: visit.photos.filter(\.isFood).count,
            apple: visit.photos.map(\.appleScore).max() ?? 0,
            mainlyFood: visit.photos.map(\.mainlyFoodScore).max() ?? 0,
            table: visit.photos.map(\.tableScore).max() ?? 0,
            people: visit.photos.map(\.peopleScore).max() ?? 0,
            hasGPS: visit.coordinate != nil,
            place: confirmedPlaces[visit.id]?.name ?? "",
            step: step(for: visit)) }
        if isNot {
            notMeals.insert(visit.id); memory.notMeals.insert(visit.id)
            sureMeals.remove(visit.id); memory.sureMeals.remove(visit.id)
        } else {
            notMeals.remove(visit.id); memory.notMeals.remove(visit.id)
        }
        saveMemory()
    }

    /// "리뷰 쓸래요" on a visit the classifiers were unsure about: it joins the queue.
    func setSureMeal(for visit: Visit) {
        sureMeals.insert(visit.id); memory.sureMeals.insert(visit.id)
        notMeals.remove(visit.id); memory.notMeals.remove(visit.id)
        saveMemory()
    }

    func markPosted(_ visit: Visit) {
        // Posted on the app's own pick: that pick stood, so it is graded now.
        if memory.autoConfirmed.contains(visit.id), let place = confirmedPlaces[visit.id] {
            confirmPlace(place, for: visit)
        }
        posted[visit.id] = Date()
        memory.posted[visit.id] = Date()
        saveMemory()
    }

    /// The next visit still waiting to be written, in the list's own order
    /// (newest first): skips what is archived, what has no GPS and so is not
    /// listed, and what is already written.
    /// Wraps around. Looking only at what comes after meant that finishing
    /// something near the end of the list handed back nothing, however many
    /// unwritten visits were sitting above it — and the screen went blank
    /// instead of opening the next one. The tab the person was working from
    /// comes first: finishing a card opened from 작성중 hands them the next
    /// 작성중 card, and only when that tab is empty does the search widen to
    /// everything unwritten — which the list then follows by switching to
    /// 방문. Picking from the whole list regardless of tab jumped from a
    /// half-written visit to an untouched one while 작성중 still had work in
    /// it.
    func nextToWrite(after visit: Visit, inTab tab: VisitListScreen.Filter? = nil) -> Visit? {
        guard let index = visits.firstIndex(where: { $0.id == visit.id }) else { return nil }
        let ordered = Array(visits[(index + 1)...]) + Array(visits[..<index])
        let unwritten: (Visit) -> Bool = { candidate in
            candidate.coordinate != nil && !self.notMeals.contains(candidate.id) && self.posted[candidate.id] == nil
                && (candidate.photos.contains(where: \.isFood) || self.sureMeals.contains(candidate.id) || self.step(for: candidate) > 2)
        }
        let tabSteps: ClosedRange<Int>? = switch tab {
        case .ready: 3...5
        case .place: 2...2
        default: nil
        }
        if let tabSteps, let same = ordered.first(where: { unwritten($0) && tabSteps.contains(step(for: $0)) }) { return same }
        return ordered.first(where: unwritten)
    }

    /// Unwritten visits the automatic hand-off will never reach, because it
    /// only follows visits that have a position. Counted so the empty screen
    /// can say why it is empty instead of looking like the end of the queue.
    var unwrittenWithoutLocation: Int {
        visits.filter { candidate in
            candidate.coordinate == nil && !notMeals.contains(candidate.id) && posted[candidate.id] == nil
                && (candidate.photos.contains(where: \.isFood) || sureMeals.contains(candidate.id) || step(for: candidate) > 2)
        }.count
    }

    /// Whether anything is left to write at all, ignoring where it sits. It
    /// separates "you are done" from "nothing after this one", which the
    /// blank screen could not say apart.
    func anythingLeftToWrite(besides visit: Visit) -> Bool {
        visits.contains { candidate in
            candidate.id != visit.id && !notMeals.contains(candidate.id) && posted[candidate.id] == nil
                && (candidate.photos.contains(where: \.isFood) || sureMeals.contains(candidate.id) || step(for: candidate) > 2)
        }
    }

    /// The mark is one click away from the open button and gets hit by
    /// mistake mid-draft; taking it back must be one click too.
    func unmarkPosted(_ visit: Visit) {
        posted[visit.id] = nil
        memory.posted[visit.id] = nil
        saveMemory()
    }

    /// Another visit to the same Google place that was already marked
    /// posted. Google keeps one review per account per place, so posting
    /// again replaces that review. Only posts made through the app are known.
    /// The live map fills only for visits opened this session (and wholesale
    /// only when stranded work was adopted), so any question about *other*
    /// visits' places has to fall back to memory. Read live-only, the
    /// same-place check saw no earlier review for one restaurant although a
    /// posted visit sat two weeks away in the list.
    func confirmedPlace(for id: Visit.ID) -> PlaceCandidate? {
        confirmedPlaces[id] ?? memory.confirmed[id]
    }

    func earlierPost(samePlaceAs visit: Visit) -> (visit: Visit, date: Date, korean: String, english: String)? {
        guard let placeID = confirmedPlace(for: visit.id)?.googlePlaceID else { return nil }
        let found = visits
            .filter { $0.id != visit.id && confirmedPlace(for: $0.id)?.googlePlaceID == placeID }
            .compactMap { other in (posted[other.id] ?? memory.posted[other.id]).map { (other, $0) } }
            .max { $0.1 < $1.1 }
        guard let found else { return nil }
        // What was actually posted, so the person can read it before writing
        // over it — the English one when that is what went up.
        let draft = reviewDrafts[found.0.id] ?? memory.drafts[found.0.id]
        let korean = draft?.text ?? ""
        return (found.0, found.1, korean, translation(of: korean) ?? "")
    }

    /// Where a visit stands, for the list and for opening the flow at the
    /// right step: 2 place, 3 dishes, 4 review, 5 post, 6 posted.
    /// Which tab a visit lives in, or nil when it is not listed at all (no
    /// GPS, or no 애플사진 and never touched). One answer for the sidebar
    /// and the map, which used to be the sidebar's private rule.
    func homeTab(of visit: Visit) -> VisitListScreen.Filter? {
        if notMeals.contains(visit.id) { return .notMeal }
        guard visit.coordinate != nil else { return nil }
        let step = step(for: visit)
        guard step > 2 || sureMeals.contains(visit.id) || visit.photos.contains(where: { $0.isFood }) else { return nil }
        if step == 6 { return .posted }
        return step >= 3 ? .ready : .place
    }

    /// The card's status line, for the map's preview.
    func statusLine(for visit: Visit) -> String {
        switch step(for: visit) {
        case 2: return String(localized: "사진 \(visit.photoCount)장")
        case 3: return String(localized: "메뉴 이름 붙이는 중")
        case 4: return String(localized: "초안 3개 준비됨")
        case 5: return String(localized: "문장 준비됨")
        default: return String(localized: "리뷰 씀")
        }
    }

    func nextAction(for visit: Visit) -> String {
        switch step(for: visit) {
        case 2: return String(localized: "가게 찾기")
        case 3: return String(localized: "메뉴 적기")
        case 4: return String(localized: "리뷰 고르기")
        case 5: return String(localized: "올리기")
        default: return String(localized: "다시 보기")
        }
    }

    func step(for visit: Visit) -> Int {
        if posted[visit.id] != nil || memory.posted[visit.id] != nil { return 6 }
        // memory, not just the live list: the live one fills in only once the
        // visit has been opened and its lookup has run, so a visit with a
        // restaurant already chosen read as unstarted and sat in 방문 until
        // someone opened it.
        guard (confirmedPlaces[visit.id] ?? memory.confirmed[visit.id])?.googlePlaceID != nil else { return 2 }
        if reviewDrafts[visit.id] != nil || memory.drafts[visit.id] != nil { return 5 }
        _ = memory.tags[visit.id]
        if reviewOptions[visit.id] != nil || memory.options[visit.id] != nil { return 4 }
        return 3
    }

    /// The user's edit, kept so it survives a relaunch.
    func updateDraft(_ text: String, for visit: Visit) {
        guard var draft = reviewDrafts[visit.id], draft.text != text else { return }
        draft.text = text
        reviewDrafts[visit.id] = draft
        memory.drafts[visit.id] = draft
        saveMemory()
    }

    /// English for the current Korean text; cached by the text itself, so an
    /// edit asks again and an unchanged text never does.
    func translation(of korean: String) -> String? {
        translations[Self.digest([korean])] ?? memory.translations[Self.digest([korean])]
    }

    func translate(for visit: Visit) async {
        await Usage.stage(visit.title, "영어로 옮기기") { await translateWork(for: visit) }
    }

    private func translateWork(for visit: Visit) async {
        guard let korean = reviewDrafts[visit.id]?.text, !korean.isEmpty,
              translation(of: korean) == nil, !translating.contains(visit.id),
              let key = PlaceMatcher.openAIKey else { return }
        translating.insert(visit.id)
        defer { translating.remove(visit.id) }
        // Hand the translator the menu's own English for each dish it can
        // find, so the English review uses the restaurant's wording.
        let menu = menuItems(for: visit)
        let pairs = dishNames(for: visit).map { name -> String in
            guard let match = menu.first(where: { $0.shown == name }) else { return name }
            // The menu's own English if it printed one; otherwise the printed
            // name as it stands, which the translator can render.
            let printed = MenuName.split(match.name)
            let other = printed.english.isEmpty ? (printed.korean == name ? "" : match.name) : printed.english
            return other.isEmpty ? name : name + " = " + other
        }
        guard let english = await ReviewDrafter.translate(korean, dishes: pairs, key: key) else { return }
        let digest = Self.digest([korean])
        translations[digest] = english
        memory.translations[digest] = english
        saveMemory()
        print("[Translate] \(visit.title): \(english.replacingOccurrences(of: "\n", with: " / "))")
    }

    private static let whenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 (E) a h시"
        return formatter
    }()

    /// Every line of text the Vision framework can read in the visit's
    /// photos — receipts, signs, menu boards — free and on-device. What the
    /// place matcher may cite as written evidence, and nothing else.
    private func ocrLines(for visit: Visit) async -> [String] {
        let key = Self.digest(["ocr"] + visit.photos.map(\.id))
        if let cached = memory.ocr[key] { return cached }
        // Only photos that could carry writing. Reading a plate of food finds
        // nothing, and every photo read costs a fetch out of Photos: the
        // signboard, the receipt, the menu, the cup — the ones the classifier
        // did NOT call food — plus a couple of food shots in case the name is
        // printed on the plate or the wrapper.
        let text = visit.photos.filter { !$0.isFood }
        let food = visit.photos.filter { $0.isFood }.prefix(2)
        let photos = Array((text + food).prefix(8))
        let byPhoto = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, photo) in photos.enumerated() {
                group.addTask {
                    // The same render the model is sent, so a photo is pulled
                    // out of Photos once and read from memory after that.
                    guard let jpeg = await self.reducedJPEG(for: photo, maxPixel: 1280),
                          let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (index, []) }
                    return (index, await Task.detached(priority: .userInitiated) { Self.recognizeText(in: image) }.value)
                }
            }
            var ordered = [[String]](repeating: [], count: photos.count)
            for await (index, found) in group { ordered[index] = found }
            return ordered
        }
        let lines = byPhoto.flatMap { $0 }
        memory.ocr[key] = lines
        saveMemory()
        return lines
    }

    nonisolated private static func recognizeText(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }

    private static func digest(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1f}")
        return "match/v1:" + SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Only a Google place can be confirmed: the review is posted on Google,
    /// so a MapKit-only candidate would stall the flow at the last step.
    func confirmPlace(_ place: PlaceCandidate, for visit: Visit) {
        guard place.googlePlaceID != nil else {
            print("[PlaceLookup] refusing to confirm \(place.name): no Google place id")
            return
        }
        Task { await PlaceNames.fill([place.name], library: self) }
        // The scorecard: what the app offered against what the person chose.
        // Free, and it knows the answer — every confirmation is one graded
        // question about the matching rules.
        let match = placeMatches[visit.id]
        let picks = match?.picks ?? []
        let rank = picks.firstIndex { $0.id == place.id } ?? -1
        let top = picks.first.flatMap { pick in placeCandidates[visit.id]?.first { $0.id == pick.id } }
        Usage.matchScore(
            visit: visit.title, rank: rank, offered: picks.count,
            top: top?.name ?? "(none)", topCategory: top?.category ?? "",
            topMetres: (top?.distance).map { $0 >= 0 ? Int($0.rounded()) : -1 } ?? -1,
            reason: picks.first?.reason ?? "",
            chosen: place.name, chosenCategory: place.category ?? "",
            metres: place.distance >= 0 ? Int(place.distance.rounded()) : -1,
            dishes: match?.dishes.prefix(4).map(\.name) ?? [],
            boughtReviews: picks.contains { ($0.reason.contains("손님 리뷰") || $0.reason.contains("review")) })
        confirmedPlaces[visit.id] = place
        memory.confirmed[visit.id] = place
        memory.autoConfirmed.remove(visit.id)
        saveMemory()
    }

    /// The app's own pick, set ahead of time so the feed card arrives with
    /// its menu and review ready. Not graded: the scorecard waits for the
    /// person — they post it (the pick stood) or pick another.
    func tentativelyConfirm(_ place: PlaceCandidate, for visit: Visit) {
        guard place.googlePlaceID != nil, confirmedPlaces[visit.id] == nil else { return }
        confirmedPlaces[visit.id] = place
        memory.confirmed[visit.id] = place
        memory.autoConfirmed.insert(visit.id)
        saveMemory()
    }

    func isTentative(_ visit: Visit) -> Bool { memory.autoConfirmed.contains(visit.id) }

    /// The drafts were written for other dishes or other tastes: drop them so
    /// the next draw writes anew. The chosen text stays.
    func dropDraftOptions(for visit: Visit) {
        invalidateDraftOptions(for: visit)
        saveMemory()
    }

    /// Sets a dish's heart outright (the thread's taste answer), rather
    /// than toggling it.
    func setLiked(_ liked: Bool, dish: String, in visit: Visit) {
        guard isLiked(dish, in: visit) != liked else { return }
        var set = likedDishes[visit.id] ?? []
        if liked { set.insert(dish) } else {
            set.remove(dish)
            // A heart on the photo counts for every dish on it; take it off.
            let names = photoDishes[visit.id] ?? memory.photoDishes[visit.id] ?? [:]
            let photos = (likes[visit.id] ?? []).filter { Self.dishParts(names[$0] ?? "").contains(dish) }
            if !photos.isEmpty {
                likes[visit.id]?.subtract(photos)
                memory.likes[visit.id] = likes[visit.id]
            }
        }
        likedDishes[visit.id] = set
        memory.likedDishes[visit.id] = set
        invalidateDraftOptions(for: visit)
        saveMemory()
    }

    /// The saved place, and what was saved with it (menu names, guesses,
    /// drafts), brought into the live state without opening the visit — the
    /// live dictionaries fill only when a visit is opened, so the feed's
    /// preparation took a confirmed visit for one with no place.
    func restoreSaved(for visit: Visit) async {
        if confirmedPlaces[visit.id] == nil, let saved = memory.confirmed[visit.id] { confirmedPlaces[visit.id] = saved }
        if confirmedPlaces[visit.id] != nil { await restoreMenu(for: visit) }
        if reviewOptions[visit.id] == nil, let kept = memory.options[visit.id], !kept.isEmpty { reviewOptions[visit.id] = kept }
        if reviewDrafts[visit.id] == nil, let chosen = memory.drafts[visit.id] { reviewDrafts[visit.id] = chosen }
    }

    /// A new place: the drafts and the photo guesses were for the old one.
    /// The menu is the new place's own (fetched by the prefetcher).
    func forgetPreparation(for visit: Visit) {
        reviewOptions[visit.id] = nil
        memory.options[visit.id] = nil
        reviewDrafts[visit.id] = nil
        memory.drafts[visit.id] = nil
        photoSuggestions[visit.id] = nil
        memory.photoSuggestions[visit.id] = nil
        menuNames[visit.id] = nil
        saveMemory()
    }

    /// Readies visits ahead of the person (the feed's backing).
    lazy var prefetcher = Prefetcher(library: self)

    /// Visits a feed would offer, newest first: listed, not archived, not
    /// yet posted.
    var feedCandidates: [Visit] {
        visits.filter { visit in
            guard let tab = homeTab(of: visit) else { return false }
            return tab == .place || tab == .ready
        }
    }

    /// Take a photo out of its visit. Remembered across relaunches, so a
    /// rescan does not bring it back. A visit with no photo left disappears;
    /// otherwise its centroid moved, so the place is looked up again.
    /// Take a photo out of a visit. It used to clear the place, the
    /// candidates and the match as well, so removing one photo sent the whole
    /// place search around again and lost a confirmed restaurant; the visit
    /// keeps everything it had.
    func removePhoto(_ photo: Photo, from visit: Visit) {
        memory.hidden.insert(photo.id)
        saveMemory()
        guard let index = visits.firstIndex(where: { $0.id == visit.id }) else { return }
        visits[index].photos.removeAll { $0.id == photo.id }
        if visits[index].photos.isEmpty { visits.remove(at: index) }
    }

    /// Photos taken out of this visit, newest last — for putting one back.
    func removedPhotos(from visit: Visit) -> [Photo] {
        guard !memory.hidden.isEmpty else { return [] }
        let span = visit.photos.map(\.takenAt)
        guard let first = span.min(), let last = span.max() else { return [] }
        return scanned
            .filter { memory.hidden.contains($0.id) }
            .filter { $0.takenAt >= first.addingTimeInterval(-visitGap) && $0.takenAt <= last.addingTimeInterval(visitGap) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    /// A photo taken out, by its id, while it is still out.
    func removedPhoto(_ id: String) -> Photo? {
        guard memory.hidden.contains(id) else { return nil }
        return scanned.first { $0.id == id }
    }

    func restorePhoto(_ photo: Photo, to visit: Visit) {
        memory.hidden.remove(photo.id)
        saveMemory()
        regroup()
    }

    /// Put back everything taken out of this visit, in one go.
    func restoreAll(to visit: Visit) {
        for photo in removedPhotos(from: visit) { memory.hidden.remove(photo.id) }
        saveMemory()
        regroup()
    }

    func clearPlace(for visit: Visit) {
        // "다른 가게예요" is the other half of the scorecard: the pick the
        // person rejected outright.
        if let wrong = confirmedPlaces[visit.id] {
            let match = placeMatches[visit.id]
            Usage.matchScore(
                visit: visit.title, rank: -2, offered: match?.picks.count ?? 0,
                top: wrong.name, topCategory: wrong.category ?? "",
                topMetres: wrong.distance >= 0 ? Int(wrong.distance.rounded()) : -1,
                reason: match?.picks.first?.reason ?? "",
                chosen: "(취소)", chosenCategory: "",
                metres: wrong.distance >= 0 ? Int(wrong.distance.rounded()) : -1,
                dishes: match?.dishes.prefix(4).map(\.name) ?? [],
                boughtReviews: match?.picks.contains { ($0.reason.contains("손님 리뷰") || $0.reason.contains("review")) } ?? false)
        }
        confirmedPlaces[visit.id] = nil
        memory.confirmed[visit.id] = nil
        // A draft names the place, so it goes with it — and so do the dish
        // names, which came from that place's reviews.
        reviewDrafts[visit.id] = nil
        reviewOptions[visit.id] = nil
        photoDishes[visit.id] = nil
        photoSuggestions[visit.id] = nil
        photoKinds[visit.id] = nil
        menuNames[visit.id] = nil
        memory.drafts[visit.id] = nil
        memory.options[visit.id] = nil
        memory.photoDishes[visit.id] = nil
        memory.photoSuggestions[visit.id] = nil
        memory.photoKinds[visit.id] = nil
        saveMemory()
    }

    // MARK: - Pixels

    func thumbnail(for photo: Photo, side: CGFloat) async -> NSImage? {
        let turned = rotation(of: photo)
        let image: NSImage?
        switch photo.origin {
        case .asset(let identifier):
            guard let asset = assetsByIdentifier[identifier] else { return nil }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            image = await assetImage(asset, size: CGSize(width: side * scale, height: side * scale))
        case .file(let url):
            image = await Task.detached(priority: .utility) {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side * scale,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return NSImage(cgImage: image, size: .zero)
            }.value
        }
        guard turned != 0, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return NSImage(cgImage: Self.upright(cg, orientation: Self.orientation(turningClockwise: turned)), size: .zero)
    }

    /// The EXIF orientation whose correction is a clockwise turn of `degrees`.
    nonisolated private static func orientation(turningClockwise degrees: Int) -> CGImagePropertyOrientation {
        switch degrees { case 90: return .right; case 180: return .down; case 270: return .left; default: return .up }
    }

    /// A video ready to play, straight out of Photos. The tile shows a frame
    /// and used to stop there: enlarging a clip gave a still picture with no
    /// way to play it.
    func playerItem(for photo: Photo) async -> AVPlayerItem? {
        switch photo.origin {
        case .file(let url):
            return AVPlayerItem(url: url)
        case .asset(let identifier):
            guard let asset = assetsByIdentifier[identifier], asset.mediaType == .video else { return nil }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            return await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private func assetImage(_ asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// A small JPEG for the vision model: 768px on the long side, the size the
    /// cost target was computed at. Nothing larger leaves the machine.
    /// Renders already made this session, by photo and size. PhotoKit charges
    /// the full price every time — decode the original, and for a photo that
    /// lives only in iCloud, download it first — and the same photo is asked
    /// for by the matcher, the OCR, the namer and every redo. Keeping the
    /// JPEG (a couple of hundred KB) rather than the image keeps this small.
    private var renders: [String: Data] = [:]
    private var renderOrder: [String] = []

    func reducedJPEG(for photo: Photo, maxPixel: CGFloat) async -> Data? {
        let key = "\(photo.id)@\(Int(maxPixel))"
        if let kept = renders[key] { return kept }
        let image: CGImage?
        switch photo.origin {
        case .asset(let identifier):
            guard let asset = assetsByIdentifier[identifier] else { return nil }
            let ns = await assetImage(asset, size: CGSize(width: maxPixel, height: maxPixel))
            image = ns?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case .file(let url):
            image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        }
        guard let image else { return nil }
        guard let data = try? Self.encodeJPEG(image, quality: 0.78) else { return nil }
        renders[key] = data
        renderOrder.append(key)
        while renderOrder.count > 80 { renders[renderOrder.removeFirst()] = nil }
        return data
    }

    /// JPEG copies on disk, ready to be dragged into another app.
    ///
    /// Two things a drag needs that a lazy export cannot give: the file must
    /// exist *before* the drag begins (a promised file is not what browsers
    /// accept reliably), and it must be a JPEG — the library and a phone
    /// folder are full of HEIC, which a web upload target refuses.
    func prepareForDrag(_ photos: [Photo]) async -> [String: URL] {
        var prepared: [String: URL] = [:]
        for photo in photos {
            if let url = draggableURLs[photo.id] {
                prepared[photo.id] = url
                continue
            }
            guard let url = try? await makeJPEG(for: photo) else { continue }
            draggableURLs[photo.id] = url
            prepared[photo.id] = url
        }
        return prepared
    }

    /// Where drag copies live. Wiped on every launch: they exist only so a
    /// drag has a real file to hand over, and are remade when a visit opens.
    private static let dragDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Afterplate", isDirectory: true)

    static func clearDragCopies() {
        try? FileManager.default.removeItem(at: dragDirectory)
    }

    /// The movie file itself, copied out of the library so it can be dragged
    /// or handed to Google's form. The original resource is written as is —
    /// no re-encode, so nothing is lost and nothing takes minutes.
    private func makeMovie(for photo: Photo) async throws -> URL {
        guard case .asset(let identifier) = photo.origin,
              let asset = assetsByIdentifier[identifier] else { throw CocoaError(.fileNoSuchFile) }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = Self.dragDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = SHA256.hash(data: Data(photo.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let url = directory.appendingPathComponent("afterplate-\(formatter.string(from: photo.takenAt))-\(suffix).\(ext.isEmpty ? "mov" : ext)")
        let turn = rotation(of: photo)
        // The turn is in the name, so a clip turned after it was copied is
        // copied again rather than served from the old file.
        let target = turn == 0 ? url : url.deletingPathExtension().appendingPathExtension("r\(turn).mov")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if !FileManager.default.fileExists(atPath: url.path) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        guard turn != 0 else { return url }
        // ↻ on a clip: the same frames, re-wrapped with the turn added to the
        // track's orientation — no re-encoding, so it is quick and lossless.
        // The original went up unturned whatever the tile showed.
        let source = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let duration = try await source.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for track in try await source.loadTracks(withMediaType: .audio) {
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: track, at: .zero)
        }
        guard let video = try await source.loadTracks(withMediaType: .video).first,
              let out = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return url }
        try out.insertTimeRange(range, of: video, at: .zero)
        let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
        let upright = size.applying(transform)
        let (w, h) = (abs(upright.width), abs(upright.height))
        let spin: CGAffineTransform = switch turn {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        default: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        }
        out.preferredTransform = transform.concatenating(spin)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return url }
        try? FileManager.default.removeItem(at: target)
        export.outputURL = target
        export.outputFileType = .mov
        await export.export()
        return export.status == .completed ? target : url
    }

    private func makeJPEG(for photo: Photo) async throws -> URL {
        if photo.isVideo { return try await makeMovie(for: photo) }
        let directory = Self.dragDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // A stable suffix: Swift's hashValue is seeded per process, and using
        // it here made every launch write a fresh copy of the same photo —
        // 73 files, 720MB, for one nine-photo visit.
        let suffix = SHA256.hash(data: Data(photo.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let turned = rotation(of: photo)
        let name = "afterplate-\(formatter.string(from: photo.takenAt))-\(suffix)\(turned == 0 ? "" : "-r\(turned)").jpg"
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let data: Data
        switch photo.origin {
        case .file(let source):
            data = try await Task.detached(priority: .userInitiated) {
                try Self.jpegData(from: source, turnedClockwise: turned)
            }.value
        case .asset(let identifier):
            guard let asset = assetsByIdentifier[identifier] else { throw CocoaError(.fileNoSuchFile) }
            data = try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, orientation, info in
                    if let data {
                        // Library originals are HEIC on any recent iPhone. The
                        // orientation PhotoKit hands back is the one to apply —
                        // it reflects edits made in Photos, which the file's own
                        // tag does not.
                        continuation.resume(returning: Self.jpegData(from: data, uti: uti, orientation: orientation, turnedClockwise: turned) ?? data)
                    } else {
                        continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? CocoaError(.fileNoSuchFile))
                    }
                }
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The photo with its orientation baked into the pixels, so the JPEG
    /// stands upright anywhere (Google's composer showed sideways
    /// photos). The rotation is done here, explicitly, from the
    /// orientation given — ImageIO's thumbnail transform turned this very
    /// photo the wrong way. No orientation tag is written.
    nonisolated private static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let width = image.width, height = image.height
        let swaps = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let outWidth = swaps ? height : width, outHeight = swaps ? width : height
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        context.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        switch orientation {
        case .down, .downMirrored: context.rotate(by: .pi)
        case .right, .rightMirrored: context.rotate(by: -.pi / 2)   // EXIF 6: raw rows run down the visual right → turn clockwise
        case .left, .leftMirrored: context.rotate(by: .pi / 2)     // EXIF 8
        default: break
        }
        if [CGImagePropertyOrientation.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation) {
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage() ?? image
    }

    nonisolated private static func fileOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
    }

    nonisolated private static func jpegData(from url: URL, turnedClockwise turned: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let standing = upright(image, orientation: fileOrientation(source))
        return try encodeJPEG(upright(standing, orientation: orientation(turningClockwise: turned)))
    }

    /// First the camera's orientation, then the extra turn the model or
    /// the user decided on.
    nonisolated private static func jpegData(from data: Data, uti: String?, orientation: CGImagePropertyOrientation, turnedClockwise turned: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        print("[PhotoLibrary] jpeg copy: PhotoKit orientation \(orientation.rawValue), \(image.width)x\(image.height), then \(turned)° clockwise")
        let standing = upright(image, orientation: orientation)
        return try? encodeJPEG(upright(standing, orientation: Self.orientation(turningClockwise: turned)))
    }

    nonisolated private static func encodeJPEG(_ image: CGImage, quality: Double = 0.92) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
