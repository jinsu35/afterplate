import Foundation
import AppKit
import WebKit

/// What Google Maps' menu tab yields for a place: highlight dish names and
/// menu photo URLs (or a note on why there was nothing).
struct GoogleMenu: Codable {
    let placeId: String
    let name: String
    let url: String
    let highlights: [String]
    let menuPhotos: [String]
    /// Items read as text off the menu view — a name and, where one is shown,
    /// a price. Google increasingly shows Korean places' menus this way
    /// instead of as photographs of the menu board, and reading only the
    /// photographs left those places looking menu-less.
    var items: [MenuItem] = []
    let note: String?
}

/// Reads a place's menu from its Google Maps page inside the app, in a web
/// view nobody sees. The page needs no login, so none of the embedded-browser
/// restrictions apply, and the user installs and allows nothing.
///
/// Same steps the Safari/Chrome extension takes (`extension/content.js`,
/// verified on a pizzeria's page): load the place, hop to the 메뉴 view
/// (`!10e9` before `!16s`), wait for it to render, read the "하이라이트" popular
/// dishes and the menu photos, return. The extension stays for the step that
/// does need the user's own browser session — posting the review.
@MainActor
final class MenuFetcher: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var continuation: CheckedContinuation<GoogleMenu?, Never>?
    private var placeID = ""
    private var startedAt = Date()
    /// Page loads spent on this read. Google serves some loads of a place
    /// without its 메뉴 tab at all (one bakery: 2 of 3 in a row),
    /// so one empty load is not an answer.
    private var attempts = 0
    private static let maxAttempts = 2

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        // Off-screen but in a real window, so the page lays out and renders
        // the panel; Maps builds it lazily and needs a viewport.
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        super.init()
        webView.navigationDelegate = self
    }

    func fetch(placeID: String) async -> GoogleMenu? {
        if continuation != nil { return nil }   // one at a time
        self.placeID = placeID
        startedAt = Date()
        attempts = 1
        window.orderBack(nil)
        guard let url = Self.placeURL(placeID) else { return nil }
        webView.load(URLRequest(url: url))
        let result = await withCheckedContinuation { (c: CheckedContinuation<GoogleMenu?, Never>) in
            continuation = c
            // Hard stop: never hang a visit on a page that will not render.
            // 40s: the menu waits on this beside a six-second web search.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                self?.finish(nil, reason: "timed out")
            }
        }
        window.orderOut(nil)
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        return result
    }

    private func finish(_ menu: GoogleMenu?, reason: String) {
        guard let c = continuation else { return }
        continuation = nil
        let what = menu.map { "\($0.items.count) items, \($0.highlights.count) highlights, \($0.menuPhotos.count) photos" } ?? "nothing"
        print("[MenuFetcher] \(placeID): \(what) (\(reason), \(Int(Date().timeIntervalSince(startedAt)))s)")
        // On the ledger too: "메뉴 읽기 실패" with no reason left nothing to
        // look at afterwards.
        Usage.local(tag: "구글 지도 메뉴", detail: "\(what) — \(reason)", seconds: -startedAt.timeIntervalSinceNow)
        c.resume(returning: menu)
    }

    private static func placeURL(_ placeID: String) -> URL? {
        URL(string: "https://www.google.com/maps/place/?q=place_id:\(placeID)&hl=ko")
    }

    /// Load the place again from the start, if loads are left.
    private func retry(_ why: String) -> Bool {
        guard attempts < Self.maxAttempts, let url = Self.placeURL(placeID) else { return false }
        attempts += 1
        print("[MenuFetcher] \(placeID): \(why) — load \(attempts) of \(Self.maxAttempts)")
        webView.load(URLRequest(url: url))
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil else { return }
        Task { await step() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil, reason: "navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(nil, reason: "load failed: \(error.localizedDescription)") }
    }

    /// Runs after each page load: hop to the menu view if not there yet,
    /// otherwise wait for it to render and scrape.
    private func step() async {
        guard continuation != nil else { return }
        // The ?q=place_id: URL redirects to the canonical one; wait for it.
        guard let href = await poll(Self.hrefJS, until: { ($0 as? String)?.contains("!16s") == true }, seconds: 15) as? String else {
            finish(nil, reason: "no canonical URL"); return
        }
        print("[MenuFetcher] \(placeID): place page at \(Int(Date().timeIntervalSince(startedAt)))s")
        let target = Self.menuViewURL(href)
        if target != href, let url = URL(string: target) {
            webView.load(URLRequest(url: url))   // didFinish → step() again
            return
        }
        // Ten seconds, not twenty-five. The early exit on "tabs drawn, none
        // says 메뉴" was removed for a restaurant whose menu tab shows in a
        // browser but not here — and nothing took its place, so every page
        // without a menu marker ran the full 25s and then scraped anyway.
        // The ledger since: 12 reads, 12 at ~30s, 0 menus. The 8 reads that
        // ever found one all finished inside 9s.
        let state = await poll(Self.readyJS, until: { ($0 as? String)?.hasPrefix("ready") == true }, seconds: 10) as? String
        // A page whose tabs do not say 메뉴 is not proof there is no menu:
        // Maps draws its tabs late and names them differently from place to
        // place. Scrape what the menu view holds and let the result decide.
        guard state?.hasPrefix("ready") == true else {
            let seen = (try? await webView.evaluateJavaScript(Self.debugJS)) as? String ?? "?"
            if let raw = try? await webView.evaluateJavaScript(Self.scrapeJS) as? [String: Any],
               let menu = Self.menu(from: raw, placeID: placeID, href: href),
               !(menu.items.isEmpty && menu.highlights.isEmpty && menu.menuPhotos.isEmpty) {
                finish(menu, reason: "scraped without a 메뉴 tab"); return
            }
            if retry("no menu on this load") { return }
            print("[MenuFetcher] page state when giving up: \(seen)")
            finish(GoogleMenu(placeId: placeID, name: "", url: href, highlights: [], menuPhotos: [], note: "no menu found — \(seen)"),
                   reason: "nothing on the page — \(seen.prefix(120))")
            return
        }
        _ = try? await webView.evaluateJavaScript(Self.nudgeJS)
        try? await Task.sleep(for: .milliseconds(1200))
        guard let raw = try? await webView.evaluateJavaScript(Self.scrapeJS) as? [String: Any] else {
            finish(nil, reason: "scrape failed"); return
        }
        // A menu the owner typed in comes in category tabs — White, Red,
        // Coffee, Toast & Sandwich — and only the open one is on the page.
        // The scrape read the tab names as dishes and never looked inside;
        // every tab is opened in turn now.
        var all = raw
        let tabsStarted = Date()
        print("[MenuFetcher] \(placeID): menu view ready at \(Int(tabsStarted.timeIntervalSince(startedAt)))s, opening tabs")
        if let tabbed = try? await webView.callAsyncJavaScript(Self.tabsJS, arguments: [:], in: nil, contentWorld: .page) as? [String: Any],
           let rows = tabbed["items"] as? [[String: String]], !rows.isEmpty {
            all["items"] = rows + (raw["items"] as? [[String: String]] ?? [])
            print("[MenuFetcher] \(placeID): \(rows.count) items in tabs \((tabbed["tabs"] as? [String] ?? []).joined(separator: ", ")) — \(String(format: "%.1f", Date().timeIntervalSince(tabsStarted)))s")
        }
        guard let menu = Self.menu(from: all, placeID: placeID, href: href) else { finish(nil, reason: "scrape failed"); return }
        if menu.items.isEmpty, menu.highlights.isEmpty, retry("menu view empty") { return }
        finish(menu, reason: "ok")
    }

    private static func menu(from raw: [String: Any], placeID: String, href: String) -> GoogleMenu? {
        var seen = Set<String>()
        let items = (raw["items"] as? [[String: String]] ?? []).compactMap { entry -> MenuItem? in
            guard let printed = entry["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !printed.isEmpty else { return nil }
            let name = koreanFirst(printed)
            guard seen.insert(name).inserted else { return nil }
            return MenuItem(name: name, price: entry["price"] ?? "", section: entry["section"] ?? "")
        }
        return GoogleMenu(
            placeId: placeID,
            name: raw["name"] as? String ?? "",
            url: href,
            highlights: raw["highlights"] as? [String] ?? [],
            menuPhotos: raw["menuPhotos"] as? [String] ?? [],
            items: items,
            note: nil
        )
    }

    /// "Pan Con Tomate (판콘 토마테)" → "판콘 토마테 Pan Con Tomate": the
    /// Korean leads, as `MenuName` expects of a two-language line.
    static func koreanFirst(_ printed: String) -> String {
        guard let m = printed.wholeMatch(of: #/(.+?)\s*\(([^()]*\p{Script=Hangul}[^()]*)\)/#) else { return printed }
        let english = String(m.1).trimmingCharacters(in: .whitespaces)
        guard english.range(of: "\\p{Script=Hangul}", options: .regularExpression) == nil else { return printed }
        return String(m.2).trimmingCharacters(in: .whitespaces) + " " + english
    }

    private func poll(_ js: String, until done: (Any?) -> Bool, seconds: Double) async -> Any? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, continuation != nil {
            let value = try? await webView.evaluateJavaScript(js)
            if done(value) { return value }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    /// The 메뉴 view is the place URL with "!10e9" before "!16s".
    static func menuViewURL(_ href: String) -> String {
        if href.contains("!10e9") { return href }
        return href.replacingOccurrences(of: "!4m6!3m5!", with: "!4m7!3m6!")
            .replacingOccurrences(of: "!16s", with: "!10e9!16s")
    }

    private static let hrefJS = "location.href"
    /// "ready": the menu view has content. "none": the place page rendered
    /// and has no 메뉴 tab at all — no point waiting. Anything else: not yet.
    private static let readyJS = """
    (() => {
      const main = document.querySelector('[role="main"]') || document.body;
      const t = main.innerText;
      // A price on the page is a menu as surely as the word 하이라이트 is:
      // many places list dishes as rows of text with no heading we know.
      const priced = /(₩\\s?[\\d,]{3,}|[\\d,]{3,}\\s?원)/.test(t);
      if (t.includes('하이라이트') || /^메뉴$/m.test(t) || priced || /총 \\d+장 중 \\d+번째 사진/.test(main.innerHTML)) return 'ready';
      return '';
    })()
    """
    private static let debugJS = """
    (() => {
      // Enough of the page to read a failure later without opening it again:
      // where it landed, the heading, the tabs, how much is actually drawn,
      // and the first lines of text.
      const main = document.querySelector('[role="main"]') || document.body;
      const h1 = ((document.querySelector('h1') || {}).textContent || '').trim();
      const tabs = [...document.querySelectorAll('[role="tab"]')].map(x => x.textContent.trim()).join(',');
      const buttons = main.querySelectorAll('button[aria-label]').length;
      const text = main.innerText.replace(/\\n+/g, ' / ').slice(0, 600);
      return 'url=' + location.href.slice(0, 120) + ' | h1=' + h1 + ' | tabs=' + tabs + ' | buttons=' + buttons + ' | mainChars=' + main.innerText.length + ' | text=' + text;
    })()
    """
    private static let nudgeJS = """
    (() => { const main = document.querySelector('[role="main"]') || document.body; for (const el of main.querySelectorAll('div')) { if (el.scrollWidth > el.clientWidth + 50 && el.clientHeight > 80 && el.clientHeight < 400) el.scrollLeft = el.scrollWidth; } return true; })()
    """
    /// Opens each of the menu's category tabs and reads its rows: a name in
    /// the row's larger line, a description and sometimes a price in the
    /// smaller ones. Run with callAsyncJavaScript — it waits between clicks.
    private static let tabsJS = """
    const main = document.querySelector('[role="main"]') || document.body;
    const place = ((document.querySelector('h1') || {}).textContent || '').trim();
    const top = /^(개요|메뉴|리뷰|정보|사진|업데이트|예약|주문|소개)$/;
    const label = t => (t.getAttribute('aria-label') || t.textContent || '').trim();
    const tabs = [...main.querySelectorAll('[role="tab"][data-tab-index]')]
      .filter(t => { const l = label(t); return l && !top.test(l) && !(place && l.includes(place)); });
    const priceRe = /(₩\\s?[\\d,]{3,}|[\\d,]{3,}\\s?원|\\$\\s?\\d+(\\.\\d\\d)?)/;
    const rows = () => [...main.querySelectorAll('.fontBodyMedium')].filter(e => e.parentElement && e.parentElement.querySelector('.fontBodySmall'));
    const items = [];
    const seen = new Set();
    for (const tab of tabs) {
      const before = rows().map(e => e.textContent.trim()).join('|');
      tab.click();
      // Until the rows change, then until they stop changing.
      let last = before, settled = 0;
      for (let i = 0; i < 16 && settled < 2; i++) {
        await new Promise(r => setTimeout(r, 250));
        const now = rows().map(e => e.textContent.trim()).join('|');
        if (now !== before && now === last) settled++; else settled = 0;
        last = now;
      }
      for (const nameEl of rows()) {
        const name = nameEl.textContent.trim();
        if (!name || name.length > 60 || seen.has(name)) continue;
        seen.add(name);
        const small = [...nameEl.parentElement.querySelectorAll('.fontBodySmall')].map(e => e.textContent.trim());
        items.push({ name, price: small.find(s => priceRe.test(s)) || '', section: label(tab) });
      }
    }
    return { tabs: tabs.map(label), items };
    """

    // Mirrors scrape() in extension/content.js.
    private static let scrapeJS = """
    (() => {
      const main = document.querySelector('[role="main"]') || document.body;
      const photoRe = /^총 (\\d+)장 중 (\\d+)번째 사진$/;
      // The menu view's box: the container around the "하이라이트" (or "메뉴")
      // heading. Dishes are buttons whose aria-label is the dish name — only
      // the first carries a visible "인기" badge, so reading text lines misses
      // the rest (one dumpling house: 7 dishes, one badge).
      // Maps labels its own furniture the same way it labels dishes, and a
      // 아리아 sweep took the lot: "<place> 개요", "<place> 리뷰", "경로", "저장",
      // "주변" all arrived as menu items. Anything carrying the
      // place's own name is a tab, and the rest is a short list of controls.
      const place = ((document.querySelector('h1') || {}).textContent || '').trim();
      const chrome = /^(경로|저장|주변|공유|전화|웹사이트|길찾기|리뷰|개요|정보|사진|동영상|메뉴|업데이트|예약|주문|더보기|닫기|뒤로|보내기|목록에 저장|즐겨찾기|모두 보기|지도|길 안내|스트리트 뷰)$/;
      // Google's own buttons are labelled like sentences — "주소 복사",
      // "휴대전화로 보내기", "영업 종료 · 목 오전 11:00에 영업 시작",
      // "전화: …". None of them is a dish, and all of them
      // reached the menu list once.
      // The same list the app applies to menus already saved, so a fresh
      // scrape and an old one are judged alike.
      const action = /(하기|복사|보내기|더보기|길찾기)$/;
      const facts = /(영업|전화|웹사이트|주소|오전|오후|리뷰|평점|Plus Code|플러스 코드)/;
      const ui = ['삭제', '좋아요', '공유', '저장', '스트리트 뷰', '수정 제안하기', '사진 및 동영상 추가', '플러스 코드 자세히 알아보기'];
      const keep = (t) => {
        const s = t.trim();
        if (!s || chrome.test(s)) return false;
        if (place && s.includes(place)) return false;          // "<place> 개요"
        if (/(개요|리뷰|정보|사진|동영상|업데이트)$/.test(s)) return false;
        if (/^[\\d.]+$/.test(s)) return false;             // a rating
        if (ui.includes(s) || action.test(s) || facts.test(s)) return false;
        if (/\\+\\d/.test(s) || /\\d[\\d\\- ]{6,}/.test(s)) return false;  // +81 3-…, 050-…
        if (s.includes(':') || s.includes('·')) return false;
        return true;
      };
      const heading = [...main.querySelectorAll('h1,h2,h3,div,span')].find(e => e.children.length === 0 && ['하이라이트', '메뉴 및 인기 요리'].includes(e.textContent.trim()));
      let box = heading;
      while (box && box.innerText.split('\\n').filter(Boolean).length < 8 && box !== main) box = box.parentElement;
      // Without the heading there is no highlights box, and reading every
      // button on the panel is how "주소 복사" became a dish. The text-menu
      // pass below still runs on the whole panel — it needs a price beside
      // the name, which no button has.
      const foundBox = !!box;
      box = box || main;
      const highlights = [];
      const photos = new Map();
      for (const button of box.querySelectorAll('button[aria-label]')) {
        // A menu's category tabs are buttons too ("White", "Toast & Sandwich");
        // they are sections, not dishes. tabsJS reads inside them.
        if (button.getAttribute('role') === 'tab') continue;
        const aria = button.getAttribute('aria-label').trim();
        const m = aria.match(photoRe);
        const img = button.querySelector('img');
        if (m) { if (img && img.src) photos.set(+m[2], img.src.replace(/=w\\d+-h\\d+[^=]*$/, '=w1600-h1600-k-no')); }
        else if (foundBox && aria && aria.length <= 40 && keep(aria) && !highlights.includes(aria)) highlights.push(aria);
      }
      if (!highlights.length) {
        const lines = main.innerText.split('\\n').map(s => s.trim());
        for (let i = 0; i < lines.length; i++) if (lines[i] === '인기' && lines[i + 1] && keep(lines[i + 1]) && !highlights.includes(lines[i + 1])) highlights.push(lines[i + 1]);
      }
      // Text menus: Google lists many Korean places' dishes as rows rather
      // than as photographs of a menu board. A row is a name followed by a
      // price, so read the prices and take the line above each one.
      const items = [];
      const priceRe = /^(₩\\s?[\\d,]{3,}|[\\d,]{3,}\\s?원|\\$\\s?\\d+(\\.\\d\\d)?)$/;
      const lines = box.innerText.split('\\n').map(s => s.trim());
      const skip = /^(메뉴|하이라이트|인기|사진|리뷰|개요|정보|더보기|웹사이트|메뉴 및 인기 요리)$/;
      let section = '';
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (!line) continue;
        if (priceRe.test(line)) {
          for (let j = i - 1; j >= 0 && j >= i - 3; j--) {
            const name = lines[j];
            if (!name || priceRe.test(name) || skip.test(name) || !keep(name) || name.length > 40) continue;
            if (!items.some(x => x.name === name)) items.push({ name, price: line, section });
            break;
          }
        } else if (line.length <= 14 && lines[i + 1] && !priceRe.test(lines[i + 1]) && /^[가-힣A-Za-z ]+$/.test(line) && skip.test(line) === false && line.endsWith('류')) {
          section = line;
        }
      }
      const name = ((document.querySelector('h1') || {}).textContent || document.title.replace(/ - Google 지도$/, '')).trim();
      return { name, highlights, items, menuPhotos: [...photos.entries()].sort((a, b) => a[0] - b[0]).map(([, url]) => url) };
    })()
    """
}
