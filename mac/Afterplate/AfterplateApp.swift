import SwiftUI
import Photos

@main
struct AfterplateApp: App {
    @StateObject private var library = PhotoLibrary()

    init() {
        // Line-buffer stdout so `open --stdout log` shows prints as they
        // happen; fully buffered, nothing appears until the app quits.
        setvbuf(stdout, nil, _IOLBF, 0)
        // The app's own language, not the Mac's: with an English system and
        // no choice saved, the new English strings would take over. Korean
        // until changed in Settings.
        if UserDefaults.standard.string(forKey: AppLanguage.key) == nil { AppLanguage.set(.korean) }
        PhotoLibrary.clearDragCopies()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

        // ⌘, — where the app's OpenAI calls are paid from.
        Settings {
            AccountSettings()
                .environmentObject(library)
                .environmentObject(ChatGPTAccount.shared)
                .environmentObject(GrokAccount.shared)
                .preferredColorScheme(.dark)
        }
    }
}

/// 앱 언어 / App language. macOS loads a bundle's language at launch, so a
/// change applies after the app is restarted.
struct LanguagePicker: View {
    @State private var chosen = AppLanguage.current
    private let atLaunch = AppLanguage.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("앱 언어 / App language").font(.system(size: 14, weight: .bold))
                Spacer()
                Picker("", selection: $chosen) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 180)
                .onChange(of: chosen) { _, value in AppLanguage.set(value) }
            }
            if chosen != atLaunch {
                Text(verbatim: "다시 켜면 적용돼요 / Applies after restart")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}

/// One API key, kept in the Keychain. Shows only whether one is saved and its
/// last four characters, never the key.
struct KeyField: View {
    let title: String
    let vendor: Keys.Vendor
    let note: String
    var changed: () -> Void = {}
    @State private var draft = ""
    @State private var saved: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
                if let saved { Text("저장됨 ····\(saved.suffix(4))").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            HStack {
                SecureField(saved == nil ? "키 붙여넣기" : "새 키로 바꾸기", text: $draft)
                Button("저장") { Keys.set(draft, for: vendor); draft = ""; saved = Keys.get(vendor); changed() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved != nil {
                    Button("지우기") { Keys.set("", for: vendor); saved = nil; changed() }
                }
            }
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { saved = Keys.get(vendor) }
    }
}

/// Sign in with ChatGPT: run the app's OpenAI calls on the person's own
/// ChatGPT plan instead of the API key. The button wording is OpenAI's
/// own ("Continue with ChatGPT"), as its brand guidelines ask.
struct AccountSettings: View {
    @AppStorage(Brain.defaultsKey) private var brain = Brain.chatgpt.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("어떤 AI로 생각할까요").font(.system(size: 20, weight: .black))
            Text("가게 맞추기, 메뉴 찾기, 사진 이름 붙이기, 리뷰 문장, 미리 준비까지 고른 AI가 해요.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // One of three, as a choice — the segmented control read as
            // tabs.
            Picker("", selection: $brain) {
                Text("ChatGPT — 유료 구독").tag(Brain.chatgpt.rawValue)
                Text("Grok — 유료 구독").tag(Brain.grok.rawValue)
                Text("Claude — 내 API 키, 쓴 만큼 요금").tag(Brain.claude.rawValue)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            // The chosen one's own part keeps one height, so what is under it
            // stays where it is when the choice changes.
            BrainConnect(brain: Brain(rawValue: brain) ?? .chatgpt)
                .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 170, alignment: .topLeading)
            Divider().padding(.vertical, 4)
            PlaceSearchSettings()
            Divider().padding(.vertical, 4)
            GoogleAccountSettings()
            Divider().padding(.vertical, 4)
            LanguagePicker()
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// The Google account the review form opens in. Asked in the conversation
/// before the first post; changed here after that.
struct GoogleAccountSettings: View {
    @EnvironmentObject private var library: PhotoLibrary
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("리뷰 올릴 구글 계정").font(.system(size: 20, weight: .black))
            Text("Safari에 구글 계정이 여러 개면 리뷰창이 이 계정으로 열려요. 비워 두면 Safari가 마지막에 쓴 계정으로 열려요.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "이메일"), text: $email)
                .textFieldStyle(.roundedBorder)
                .onSubmit { library.setGoogleAccount(email) }
                .onChange(of: email) { _, value in
                    library.setGoogleAccount(value)
                    if !value.trimmingCharacters(in: .whitespaces).isEmpty { ThreadActions.oneAccount = false }
                }
        }
        .onAppear { email = library.googleAccount }
    }
}

/// Where nearby places come from: this Mac's share of Afterplate's Google
/// searches, or one's own Google Maps key with its own free
/// calls.
struct PlaceSearchSettings: View {
    @State private var share: (used: Int, limit: Int, resets: Date?)?
    @State private var own = PlaceLookup.googleKey != nil
    @State private var howOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("가게 검색").font(.system(size: 20, weight: .black))
            Group {
                if own {
                    Text("내 Google 지도 키로 찾아요. 그 키의 무료 한도에서 써요.")
                } else if let share {
                    Text("이번 주 가게 검색 \(share.limit)번 중 \(share.used)번 썼어요. 방문 하나에 1~2번이에요. 매주 \((share.resets ?? Date()).formatted(.dateTime.weekday(.wide).hour().minute()))에 다시 \(share.limit)번으로 채워져요.")
                } else {
                    Text("Afterplate의 Google 검색을 맥마다 일주일 몫씩 나눠 써요. 방문 하나에 1~2번이에요.")
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            KeyField(title: String(localized: "내 Google 지도 키 (선택)"), vendor: .google,
                     note: String(localized: "넣으면 Afterplate 몫 대신 이 키로 찾아요. Google이 주는 무료 한도 안에서는 요금이 없어요."),
                     changed: { own = PlaceLookup.googleKey != nil })
            // A popover, not a disclosure: the Settings window does not grow
            // with its content, so the opened steps were cut off and the
            // row looked dead.
            Button { howOpen = true } label: {
                Label("키 받는 법", systemImage: "questionmark.circle")
            }
            .buttonStyle(.link)
            .popover(isPresented: $howOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    howStep("1", String(localized: "Google Cloud에서 프로젝트를 만들어요."), "https://console.cloud.google.com/projectcreate")
                    howStep("2", String(localized: "결제 계정을 연결해요. 카드가 필요하지만, 무료 한도 안에서는 청구되지 않아요."), "https://console.cloud.google.com/billing")
                    howStep("3", String(localized: "Places API (New)를 사용 설정해요."), "https://console.cloud.google.com/apis/library/places.googleapis.com")
                    howStep("4", String(localized: "사용자 인증 정보 → API 키 만들기. 키 제한에서 Places API (New)만 고르면 안전해요."), "https://console.cloud.google.com/apis/credentials")
                    howStep("5", String(localized: "무료 한도를 넘지 않게 하루 검색 수에 상한을 걸어 둘 수 있어요 (예: SearchNearby 하루 150)."), "https://console.cloud.google.com/apis/api/places.googleapis.com/quotas")
                    Text("만든 키를 위 칸에 붙여 넣으면 돼요.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(width: 400)
            }
        }
        .task {
            if !own { share = await PlacesProxy.allowance() }
        }
    }

    private func howStep(_ number: String, _ text: String, _ link: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: number).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: link) {
                    Link(link.replacingOccurrences(of: "https://", with: ""), destination: url).font(.system(size: 11))
                }
            }
        }
    }
}

/// Connecting the chosen brain: ChatGPT's sign-in, Grok's code, or a Claude
/// key. In Settings, and on the feed when nothing is connected yet.
struct BrainConnect: View {
    @ObservedObject private var account = ChatGPTAccount.shared
    @ObservedObject private var grok = GrokAccount.shared
    let brain: Brain
    var changed: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch brain {
            case .grok: grokSection
            case .claude: claudeSection
            case .chatgpt: chatGPTSection
            }
            if let error = brain == .grok ? grok.lastError : brain == .chatgpt ? account.lastError : nil {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Claude on the person's own Anthropic API key, paid per call.
    @ViewBuilder
    private var claudeSection: some View {
        KeyField(title: String(localized: "Claude API 키"), vendor: .anthropic,
                 note: String(localized: "platform.claude.com에서 키를 만들어요. 쓴 만큼 요금이 나가요. 미리 준비는 앱을 켤 때마다 $1까지만 써요."), changed: changed)
    }

    /// Linking a Grok account: a code to type on x.ai, approved there.
    @ViewBuilder
    private var grokSection: some View {
        if grok.linked {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(grok.email ?? "Grok 계정") 연결됨").font(.system(size: 14, weight: .bold))
                Spacer()
                Button("연결 끊기") { grok.unlink() }
            }
        } else if grok.linking {
            VStack(alignment: .leading, spacing: 8) {
                Text("x.ai 창에서 이 코드를 확인하고 승인해 주세요").font(.system(size: 13, weight: .bold))
                Text(grok.userCode ?? "…")
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    if let url = grok.verifyURL { Link("x.ai 승인 창 다시 열기", destination: url).font(.system(size: 12)) }
                    Spacer()
                    ProgressView().controlSize(.small)
                    Button("취소") { grok.cancelLink() }
                }
            }
        } else {
            Button {
                grok.link()
            } label: {
                Text("Grok 계정 연결")
                    .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            Text("SuperGrok 또는 X Premium+ 구독이 있어야 해요. 비밀번호는 x.ai에서만 입력해요.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chatGPTSection: some View {
            if let email = account.email {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(email) 로 로그인됨").font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button("로그아웃") { Task { await account.signOut() } }
                }
                if !account.models.isEmpty {
                    Text("쓸 수 있는 모델: \(account.models.prefix(8).joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Link("ChatGPT에서 사용량·한도 보기", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    .font(.system(size: 12))
            } else {
                if account.signingIn {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(account.signInStep).font(.system(size: 14, weight: .bold))
                        Spacer()
                        Button("취소") { account.cancelSignIn() }
                    }
                    .frame(height: 40)
                    Text("브라우저 창을 닫았으면 취소를 눌러 주세요.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await account.signIn() }
                    } label: {
                        Text("Continue with ChatGPT")
                            .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("비밀번호는 chatgpt.com에서만 입력해요.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: PhotoLibrary
    /// The visit whose flow is open in the detail pane; nil shows a prompt.
    @State private var openVisit: Visit.ID?
    /// The map and the list, for looking back; the feed is home.
    @AppStorage("showLibrary") private var showLibrary = false

    var body: some View {
        Group {
        switch library.firstRunPreview ? .unknown : library.access {
        case .granted, .folder:
          if !showLibrary {
            FeedView(prefetcher: library.prefetcher, openLibrary: { showLibrary = true })
                .background(BrandBackdrop().ignoresSafeArea())
                .navigationTitle("")
                .toolbarBackground(.hidden, for: .windowToolbar)
          } else {
            // The standard Mac list-and-detail structure, as Mail and Notes
            // use it: the visits are the sidebar, the review of the picked
            // visit is the detail. Opening, closing and resizing the sidebar
            // are the system's own — the hand-made slide before this read as
            // unnatural.
          VStack(spacing: 0) {
            AppTopBar(prefetcher: library.prefetcher, inLibrary: true, toggle: { openVisit = nil; showLibrary = false })
            NavigationSplitView {
                VisitListScreen(selected: openVisit) { visit in openVisit = visit?.id }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
            } detail: {
                ZStack {
                    BrandBackdrop().ignoresSafeArea()
                    if let openVisit {
                        VisitFlow(visitID: openVisit, home: { self.openVisit = nil }, openNext: { finished in
                            // Straight on to the next one to write; the list
                            // pane stays put, so the queue is still in view.
                            let tab = UserDefaults.standard.string(forKey: "visitListFilter")
                                .flatMap(VisitListScreen.Filter.init(rawValue:))
                            self.openVisit = library.nextToWrite(after: finished, inTab: tab)?.id
                        })
                        .id(openVisit)
                    } else {
                        // Home is the map: every listed visit as a pin.
                        VisitMapView { visit in openVisit = visit.id }
                    }
                }
                .onExitCommand { openVisit = nil }
            }
            .navigationSplitViewStyle(.balanced)
          }
            // The window title sat on the detail pane's own toolbar material,
            // so the top strip read as two shades meeting mid-window. The app
            // has its own wordmark in the sidebar; drop the title and let the
            // backdrop run under the whole toolbar.
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(BrandBackdrop().ignoresSafeArea())
          }
        case .unknown, .denied:
            ZStack {
                BrandBackdrop().ignoresSafeArea()
                FirstRunFlow()
            }
        }
        }
        // Permission granted on an earlier launch is the normal case, and
        // nothing else asks: the NavigationSplitView rewrite (20eab1e) took
        // this line with it, so the app opened on the first-run screen and
        // never scanned unless someone pressed the button.
        .task { library.refreshAccess() }
        // Get the newest unwritten visits ready in the background, on the
        // ChatGPT plan only — the feed's backing.
        .task(id: library.visits.count) {
            guard !library.visits.isEmpty else { return }
            library.prefetcher.want(Array(library.feedCandidates.prefix(Prefetcher.ahead)))
            // Places settled before readings existed, or in another language.
            await PlaceNames.fill(library.confirmedPlaces.values.map(\.name), library: library)
            await MenuTrial.runIfAsked(library)
            await DictBuild.runIfAsked()
            await DescTrial.runIfAsked()
        }
    }
}

/// The first run, in order: which AI first, then the photos. Choosing the
/// AI used to come up only while the library was being looked through, on
/// top of it; with the AI settled first, the look through the library is
/// left to be watched, stickers and all.
struct FirstRunFlow: View {
    @State private var brainReady = Brain.subscriptionReady

    var body: some View {
        Group {
            if brainReady {
                FirstRunView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                BrainSetup(changed: check)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        // Signing in finishes in the browser or on x.ai; look until it has.
        .task(id: brainReady) {
            while !brainReady, !Task.isCancelled {
                check()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func check() {
        let ready = Brain.subscriptionReady
        guard ready != brainReady else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { brainReady = ready }
    }
}

struct FirstRunView: View {
    @EnvironmentObject private var library: PhotoLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BrandWordmark(size: 25)

            VStack(alignment: .leading, spacing: 16) {
                Text("밀린 음식 사진,\n여기서 한 번에.")
                    .font(.system(size: 40, weight: .black))
                    .tracking(-1.4)
                    .lineSpacing(4)
                    .foregroundStyle(AppBrand.foreground)
                Text("사진 앱에서 음식 사진을 찾아 방문 단위로 묶고, 가게와 메뉴를 읽어 리뷰 초안까지 만들어 둡니다. 사진은 복사하지 않고 그대로 둡니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppBrand.muted)
                    .lineSpacing(5)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            BrandPanel(padding: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    reason(
                        symbol: "photo.on.rectangle.angled",
                        title: String(localized: "사진 앱 그대로, 옮길 것 없이"),
                        body: String(localized: "iPhone에서 찍어 iCloud 사진으로 올라온 사진까지, 사진 앱에 있는 그대로 읽어요. 내보내거나 폴더로 옮길 필요가 없어요.")
                    )
                    reason(
                        symbol: "lock.shield",
                        title: String(localized: "원본은 이 맥에 그대로 있어요"),
                        body: String(localized: "가게와 메뉴를 알아낼 때 작게 줄인 사진은 고른 AI(ChatGPT·Grok·Claude)에게, 사진 찍은 위치는 Google 지도 검색에 보내요. 원본은 어디에도 올리지 않아요.")
                    )
                }
            }
            .frame(maxWidth: 580)

            // The Photos app is the way in: it is the whole library, iCloud
            // included, and nothing to export. It used to be the grey button
            // beside a yellow "choose a folder", which read as the other way
            // round; now both are the same grey, Photos first and with its
            // own icon.
            HStack(spacing: 12) {
                SourceButton(
                    icon: Self.photosIcon.map { Image(nsImage: $0) } ?? Image(systemName: "photo.on.rectangle"),
                    title: String(localized: "사진 앱 연결하기"),
                    detail: String(localized: "iCloud 사진까지 전부에서 찾아요")
                ) { Task { await library.requestAccess() } }
                SourceButton(
                    icon: Image(systemName: "folder"),
                    title: String(localized: "폴더에서 고르기"),
                    detail: String(localized: "고른 폴더의 사진만 읽어요")
                ) { library.chooseFolder() }
            }
            .frame(maxWidth: 580)

            if library.access == .denied {
                Button("시스템 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(BrandSecondaryButtonStyle())
            }

            Text(library.access == .denied
                 ? "사진 앱 접근이 꺼져 있어요. 시스템 설정에서 켜 주시거나, 폴더로 먼저 써 보세요."
                 : "사진 앱 접근은 macOS가 한 번 물어봐요. 권한 없이 써 보고 싶으면 폴더로 시작해도 돼요.")
                .font(.system(size: 11))
                .foregroundStyle(AppBrand.faint)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Photos app's own icon, so the button says which app it means.
    private static let photosIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.apple.Photos")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    private func reason(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppBrand.signal)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(AppBrand.foreground)
                Text(body).font(.system(size: 11)).foregroundStyle(AppBrand.muted).lineSpacing(3)
            }
        }
    }
}

/// One of the first screen's two ways in: a big button with the source's
/// icon, what it is, and one line on what it reads.
private struct SourceButton: View {
    let icon: Image
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon.resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 18, weight: .black))
                    Text(detail).font(.system(size: 12, weight: .semibold)).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppBrand.foreground)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(AppBrand.raisedSurface)
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppBrand.line, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plainHit)
    }
}
