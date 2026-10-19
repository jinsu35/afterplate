import Foundation
import AppKit

/// A person's Grok account, linked to the app so its calls run on their
/// SuperGrok or X Premium+ subscription.
///
/// The link is xAI's device-code flow (RFC 8628) against auth.x.ai, as a
/// public client: the app shows a short code and opens x.ai's own approval
/// page; the person approves there with their own account, and the app only
/// ever receives a token. xAI has no sign-up for third-party OAuth clients
/// yet, so apps that link Grok (OpenClaw, Hermes) ship the Grok CLI's public
/// client id — `clientID` below — and xAI could stop accepting it at any
/// time. A standard SuperGrok plan has been seen refused with HTTP 403; the
/// person is then told and pointed at an API key instead.
///
/// Calls go to api.x.ai/v1/responses — the same Responses shape the app
/// already sends, without `reasoning` (the non-reasoning model refuses it).
///
/// Credentials live in ~/Library/Application Support/Afterplate/grok/, owner
/// read-only, never in memory.json, the ledger or a log.
@MainActor
final class GrokAccount: ObservableObject {
    static let shared = GrokAccount()

    /// The public client id the device flow identifies the app with — the
    /// Grok CLI's, as shipped by other apps that link Grok.
    nonisolated static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"

    @Published private(set) var email: String?
    @Published private(set) var linking = false
    /// The code to type on x.ai while linking, shown big.
    @Published private(set) var userCode: String?
    @Published private(set) var verifyURL: URL?
    @Published private(set) var lastError: String?

    private static let deviceURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let scopes = "openid profile email offline_access grok-cli:access api:access"
    static let endpoint = URL(string: "https://api.x.ai/v1/responses")!
    /// One model for everything: sees photos, searches the web, writes JSON.
    static let model = "grok-4.20-non-reasoning"

    struct Credentials: Codable {
        var email: String?
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private var credentials: Credentials?
    private var refreshing: Task<Credentials?, Never>?
    private var linkTask: Task<Void, Never>?

    var linked: Bool { credentials != nil }

    /// Linked, readable off the main actor.
    nonisolated static var ready: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("credentials.json").path)
    }

    private init() {
        credentials = Self.read()
        email = credentials?.email
    }

    // MARK: - Files

    nonisolated private static var folder: URL {
        let base = AppData.accounts.appendingPathComponent("grok", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func read() -> Credentials? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("credentials.json")) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Credentials.self, from: data)
    }

    private static func write(_ creds: Credentials?) {
        let url = folder.appendingPathComponent("credentials.json")
        guard let creds else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(creds) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Link

    func link() {
        guard !linking else { return }
        guard !Self.clientID.isEmpty else {
            lastError = String(localized: "이 빌드에는 Grok 연결용 앱 ID가 아직 없어요.")
            return
        }
        lastError = nil
        linking = true
        linkTask = Task { await runLink(); linking = false; userCode = nil; verifyURL = nil }
    }

    func cancelLink() {
        linkTask?.cancel()
        linkTask = nil
        linking = false
        userCode = nil
        verifyURL = nil
    }

    func unlink() {
        credentials = nil
        email = nil
        Self.write(nil)
    }

    private func runLink() async {
        guard let device = await Self.form(Self.deviceURL, ["client_id": Self.clientID, "scope": Self.scopes]),
              let deviceCode = device["device_code"] as? String,
              let code = device["user_code"] as? String else {
            lastError = String(localized: "x.ai에서 연결 코드를 받지 못했어요. 잠시 뒤 다시 해 주세요.")
            return
        }
        userCode = code
        let page = (device["verification_uri_complete"] as? String) ?? (device["verification_uri"] as? String)
        verifyURL = page.flatMap(URL.init(string:))
        if let verifyURL { NSWorkspace.shared.open(verifyURL) }

        var wait = Double(device["interval"] as? Int ?? 5)
        let deadline = Date().addingTimeInterval(Double(device["expires_in"] as? Int ?? 600))
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            guard let token = await Self.form(Self.tokenURL, [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": deviceCode, "client_id": Self.clientID,
            ], acceptErrors: true) else { continue }
            switch token["error"] as? String {
            case "authorization_pending"?: continue
            case "slow_down"?: wait += 5; continue
            case "access_denied"?:
                lastError = String(localized: "x.ai에서 연결을 거절했어요.")
                return
            case "expired_token"?:
                lastError = String(localized: "연결 코드가 만료됐어요. 다시 눌러 주세요.")
                return
            case nil:
                guard let creds = Self.credentials(from: token, previous: nil) else {
                    lastError = String(localized: "x.ai 응답을 읽지 못했어요.")
                    return
                }
                credentials = creds
                email = creds.email
                Self.write(creds)
                await checkPlan()
                return
            case let other?:
                lastError = String(localized: "연결 실패: \(other)")
                return
            }
        }
        if !Task.isCancelled { lastError = String(localized: "연결 코드가 만료됐어요. 다시 눌러 주세요.") }
    }

    /// One tiny call right after linking: a plan xAI does not serve over this
    /// link answers 403, and the person should hear it now, not on first use.
    private func checkPlan() async {
        guard let token = await accessToken() else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.model, "input": "hi", "store": false])
        request.timeoutInterval = 30
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            lastError = String(localized: "연결은 됐지만 이 Grok 요금제로는 앱에서 쓸 수 없어요 (SuperGrok 이상 필요). 대신 아래에 xAI API 키를 넣을 수 있어요.")
        }
    }

    // MARK: - Tokens

    /// A live access token, refreshed when it is within `margin` of lapsing.
    func accessToken(margin: TimeInterval = 120) async -> String? {
        guard let creds = credentials else { return nil }
        if creds.expiresAt.timeIntervalSinceNow > margin { return creds.accessToken }
        if let refreshing { return await refreshing.value?.accessToken }
        let task = Task<Credentials?, Never> {
            guard let token = await Self.form(Self.tokenURL, [
                "grant_type": "refresh_token", "refresh_token": creds.refreshToken, "client_id": Self.clientID,
            ]) else { return nil }
            return Self.credentials(from: token, previous: creds)
        }
        refreshing = task
        let fresh = await task.value
        refreshing = nil
        if let fresh {
            credentials = fresh
            Self.write(fresh)
        }
        return fresh?.accessToken
    }

    private static func credentials(from token: [String: Any], previous: Credentials?) -> Credentials? {
        guard let access = token["access_token"] as? String else { return nil }
        let lifetime = Double(token["expires_in"] as? Int ?? 3600)
        return Credentials(
            email: (token["id_token"] as? String).flatMap(emailClaim) ?? previous?.email,
            accessToken: access,
            refreshToken: token["refresh_token"] as? String ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(lifetime))
    }

    private static func emailClaim(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    /// A form POST; the JSON answer, or nil. With `acceptErrors` an OAuth
    /// error answer (400 with "error") comes back too, for the poll.
    private static func form(_ url: URL, _ fields: [String: String], acceptErrors: Bool = false) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 || (acceptErrors && json["error"] != nil) { return json }
        return nil
    }
}

/// Which subscription thinks for the app (both will be
/// supported). Everything — place, menu search, dish names, drafts, the
/// feed's preparation — goes to the chosen one.
enum Brain: String, CaseIterable, Identifiable {
    case chatgpt, grok, claude
    var id: String { rawValue }

    /// Where the choice is kept; apart from the real one for a new person.
    nonisolated static let defaultsKey = AppData.apart("brain")

    nonisolated static var current: Brain {
        Brain(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .chatgpt
    }

    /// The chosen brain can take calls: the subscription is linked (no
    /// charge per call), or for Claude an API key is saved (paid, with the
    /// preparation capped by `ClaudeAPI.prepBudget`).
    nonisolated static var subscriptionReady: Bool {
        switch current {
        case .chatgpt: ChatGPTAccount.planReady
        case .grok: GrokAccount.ready
        case .claude: ClaudeAPI.key != nil
        }
    }
}
