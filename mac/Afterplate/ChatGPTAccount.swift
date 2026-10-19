import Foundation
import AppKit
import CryptoKit
import Network

/// Sign in with ChatGPT, for running the app's OpenAI calls on the
/// person's own ChatGPT plan instead of a paid API key.
///
/// OpenAI opened ChatGPT plan usage to open-source and locally hosted apps on
/// 2026-09-29 (developers.openai.com/siwc/token-sharing-open-source). The
/// flow, as documented there:
/// - First sign-in registers the app with `client_id=dynamic_agent_client`;
///   the callback returns the issued `client_id`, which is kept and reused.
/// - Authorization code + PKCE in the system browser, back to a loopback
///   listener on 127.0.0.1 at `/auth/callback`.
/// - Scopes `openid profile email offline_access resource.invoke
///   chatgpt.tokens.use.direct`, resource `https://api.openai.com/v1`.
/// - Access tokens live an hour; the refresh token rotates and lives 30 days.
/// - Requests go to the public Responses API with `store: false` and
///   `stream: true`, without `max_output_tokens`, `temperature` and a few
///   other fields, and finish only at `response.completed`.
///
/// Credentials live in ~/Library/Application Support/Afterplate/chatgpt/, owner
/// read-only, never in memory.json, the ledger or a log.
@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()

    /// The signed-in account's email, when there is one with plan usage.
    @Published private(set) var email: String?
    @Published private(set) var signingIn = false
    /// What the sign-in is waiting on, for the button.
    @Published private(set) var signInStep = ""
    private var pendingListener: LoopbackListener?
    @Published private(set) var lastError: String?
    /// Model slugs the account may use, in the server's order.
    @Published private(set) var models: [String] = []

    /// Whether calls should go on the plan right now: signed in is enough,
    /// choosing ChatGPT means using its plan.
    var active: Bool { credentials != nil }

    /// The same, readable off the main actor: a saved sign-in.
    nonisolated static var planReady: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("credentials.json").path)
    }

    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let appName = "Afterplate"

    struct Credentials: Codable {
        var email: String?
        var subject: String
        var clientID: String
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scopes: [String]
        var models: [String]?
    }

    private var credentials: Credentials?
    /// The issued client id, kept through sign-out for the next sign-in.
    private var clientID: String?
    private var refreshing: Task<Credentials?, Never>?

    private init() {
        credentials = Self.read(Credentials.self, "credentials.json")
        clientID = credentials?.clientID ?? Self.read([String: String].self, "client.json")?["client_id"]
        email = credentials?.email
        models = credentials?.models ?? []
        keepFresh()
        // The catalog as it is today, not as it was at sign-in.
        if credentials != nil { Task { await loadModels() } }
    }

    /// Renews the access token ten minutes before it lapses while the app is
    /// open, so the first call after a quiet hour does not start with a
    /// refresh — and anything else reading the saved token finds a live one.
    private func keepFresh() {
        Task { [weak self] in
            while let self {
                if let creds = self.credentials, creds.expiresAt.timeIntervalSinceNow < 600 {
                    _ = await self.accessToken(margin: 600)
                }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    // MARK: - Files

    nonisolated private static var folder: URL {
        let base = AppData.accounts.appendingPathComponent("chatgpt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        let url = folder.appendingPathComponent(name)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// This Mac's stable host id, made once before the first sign-in.
    private static var hostID: String {
        if let saved = read([String: String].self, "host.json")?["ext_agent_host_id"] { return saved }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        write(["ext_agent_host_id": id], "host.json")
        return id
    }

    // MARK: - Sign in

    func signIn() async {
        guard !signingIn else { return }
        signingIn = true
        signInStep = String(localized: "브라우저를 여는 중…")
        lastError = nil
        defer { signingIn = false; signInStep = ""; pendingListener = nil }
        do {
            let creds = try await authorize()
            credentials = creds
            clientID = creds.clientID
            Self.write(creds, "credentials.json")
            Self.write(["client_id": creds.clientID], "client.json")
            email = creds.email
            await loadModels()
        } catch {
            lastError = (error as? AuthError)?.message ?? error.localizedDescription
            print("[ChatGPT] sign-in failed: \(lastError ?? "")")
            Usage.local(tag: "ChatGPT 로그인 실패", detail: lastError ?? "", seconds: 0)
        }
    }

    struct AuthError: Error { let message: String }

    private func authorize() async throws -> Credentials {
        let state = Self.random(), nonce = Self.random(), verifier = Self.random(48)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let listener = try await LoopbackListener.start()
        pendingListener = listener
        let redirect = "http://127.0.0.1:\(listener.port)/auth/callback"
        let saved = clientID
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: saved ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: Self.hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: Self.scopes),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if saved == nil { items.append(.init(name: "agent_name_hint", value: Self.appName)) }
        else if let hint = credentials?.idToken { items.append(.init(name: "id_token_hint", value: hint)) }
        // Every value fully form-encoded, as OpenAI's devkit does with
        // URLSearchParams: URLComponents left the redirect_uri's ":" and "/"
        // bare, and the authorize endpoint answered "invalid
        // redirect_uri".
        var unreserved = CharacterSet.alphanumerics; unreserved.insert(charactersIn: "-._~ ")
        let encode = { (value: String) in
            (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value).replacingOccurrences(of: " ", with: "+")
        }
        let query = items.map { "\($0.name)=\(encode($0.value ?? ""))" }.joined(separator: "&")
        let url = URL(string: Self.authorizeURL.absoluteString + "?" + query)!
        print("[ChatGPT] authorize via \(redirect)")
        Usage.local(tag: "ChatGPT 로그인 시작", detail: redirect + (saved == nil ? " · 첫 등록" : " · 재로그인"), seconds: 0)
        NSWorkspace.shared.open(url)
        signInStep = String(localized: "브라우저에서 로그인하는 중…")

        let callback = try await listener.waitForCallback(state: state)
        signInStep = String(localized: "확인하는 중…")
        guard callback["state"] == state else { throw AuthError(message: String(localized: "로그인 응답이 이 요청과 맞지 않아요. 다시 시도해 주세요.")) }
        if callback["error"] == "access_denied" { throw AuthError(message: String(localized: "ChatGPT 요금제 사용을 허락하지 않았어요.")) }
        if let error = callback["error"] { throw AuthError(message: String(localized: "ChatGPT 로그인 오류: \(error)")) }
        guard let code = callback["code"] else { throw AuthError(message: String(localized: "로그인 코드가 오지 않았어요.")) }
        let issued: String
        if let saved {
            if let returned = callback["client_id"], returned != saved { throw AuthError(message: String(localized: "다른 등록으로 돌아왔어요. 다시 시도해 주세요.")) }
            issued = saved
        } else {
            guard let returned = callback["client_id"], returned != "dynamic_agent_client" else {
                throw AuthError(message: String(localized: "앱 등록이 끝나지 않았어요. 다시 시도해 주세요."))
            }
            issued = returned
        }
        let token = try await Self.tokenRequest([
            "grant_type": "authorization_code", "client_id": issued, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource,
        ])
        return try Self.credentials(from: token, clientID: issued, nonce: nonce, previous: nil)
    }

    /// Checks the ID token's claims. Its signature is not checked against
    /// OpenAI's JWKS: it came straight from the token endpoint over TLS in a
    /// code-flow exchange, which OpenID Connect Core (3.1.3.7) accepts in
    /// place of a signature check.
    private static func credentials(from token: [String: Any], clientID: String, nonce: String?, previous: Credentials?) throws -> Credentials {
        guard let access = token["access_token"] as? String else { throw AuthError(message: String(localized: "토큰을 받지 못했어요.")) }
        let scopes = (token["scope"] as? String ?? previous?.scopes.joined(separator: " ") ?? "").split(separator: " ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct") else {
            throw AuthError(message: String(localized: "ChatGPT 요금제 사용 권한이 허락되지 않았어요. ChatGPT 설정에서 이 앱의 요금제 사용을 켜 주세요."))
        }
        let idToken = token["id_token"] as? String ?? previous?.idToken ?? ""
        let claims = jwtClaims(idToken)
        if previous == nil {
            guard claims["iss"] as? String == "https://auth.openai.com" else { throw AuthError(message: String(localized: "ID 토큰 발급자가 달라요.")) }
            let aud = claims["aud"] as? String ?? (claims["aud"] as? [String])?.first ?? ""
            guard aud == clientID || (claims["aud"] as? [String])?.contains(clientID) == true else { throw AuthError(message: String(localized: "ID 토큰 대상이 달라요.")) }
            if let nonce { guard claims["nonce"] as? String == nonce else { throw AuthError(message: String(localized: "ID 토큰이 이 요청 것이 아니에요.")) } }
        }
        let subject = claims["sub"] as? String ?? previous?.subject ?? ""
        if let previous, !subject.isEmpty, subject != previous.subject { throw AuthError(message: String(localized: "다른 계정으로 바뀌었어요. 다시 로그인해 주세요.")) }
        return Credentials(
            email: claims["email"] as? String ?? previous?.email,
            subject: subject, clientID: clientID, idToken: idToken, accessToken: access,
            refreshToken: token["refresh_token"] as? String ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(Double(token["expires_in"] as? Int ?? 3600)),
            scopes: scopes, models: previous?.models)
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var unreserved = CharacterSet.alphanumerics; unreserved.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? "http \(status)"
            // What OpenAI said, for the log: an error reply carries no token.
            print("[ChatGPT] token \(form["grant_type"] ?? "") refused: \(status) \(String(data: data.prefix(600), encoding: .utf8) ?? "")")
            // invalid_grant on the first exchange is OpenAI turning the sign-in
            // down, not an expiry (a free plan's sign-in).
            let refused = form["grant_type"] == "authorization_code"
                ? String(localized: "OpenAI가 이 계정의 로그인을 받아 주지 않았어요 (\(code)). 무료 계정은 안 돼요. ChatGPT Plus 이상이 필요해요.")
                : String(localized: "로그인이 만료됐어요. 다시 로그인해 주세요.")
            throw AuthError(message: code == "invalid_grant" ? refused : String(localized: "토큰 요청 실패: \(code)"))
        }
        return json
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func random(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Tokens

    /// A live access token, refreshed first when it is about to lapse; nil
    /// when not signed in or the session cannot be renewed.
    func accessToken(margin: TimeInterval = 120) async -> String? {
        guard var creds = credentials else { return nil }
        if creds.expiresAt.timeIntervalSinceNow > margin { return creds.accessToken }
        // One refresh at a time: the refresh token rotates.
        if refreshing == nil {
            let current = creds
            refreshing = Task {
                do {
                    let token = try await Self.tokenRequest([
                        "grant_type": "refresh_token", "client_id": current.clientID,
                        "refresh_token": current.refreshToken, "resource": Self.resource,
                    ])
                    return try Self.credentials(from: token, clientID: current.clientID, nonce: nil, previous: current)
                } catch {
                    print("[ChatGPT] refresh failed: \((error as? AuthError)?.message ?? error.localizedDescription)")
                    return nil
                }
            }
        }
        let renewed = await refreshing?.value
        refreshing = nil
        guard let renewed else {
            lastError = String(localized: "ChatGPT 로그인이 만료됐어요. 설정에서 다시 로그인해 주세요.")
            return nil
        }
        creds = renewed
        credentials = creds
        Self.write(creds, "credentials.json")
        return creds.accessToken
    }

    /// The browser window was closed, or the person changed their mind: a
    /// closed tab sends nothing back, so the wait has to be ended here.
    func cancelSignIn() {
        pendingListener?.cancel(String(localized: "로그인을 취소했어요."))
    }

    func signOut() async {
        if let creds = credentials, !creds.refreshToken.isEmpty {
            // The revocation endpoint from the discovery document.
            if let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!),
               let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let endpoint = (config["revocation_endpoint"] as? String).flatMap(URL.init(string:)) {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = "token=\(creds.refreshToken)&token_type_hint=refresh_token&client_id=\(creds.clientID)".data(using: .utf8)
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        credentials = nil
        email = nil
        models = []
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("credentials.json"))
    }

    private func loadModels() async {
        guard let token = await accessToken() else { return }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let list = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
        // Hidden ones too: gpt-reserve, unlisted, wrote a review card fastest.
        let slugs = list.compactMap { ($0["slug"] as? String) ?? ($0["id"] as? String) }
        models = slugs
        credentials?.models = slugs
        if let creds = credentials { Self.write(creds, "credentials.json") }
        print("[ChatGPT] models: \(slugs.joined(separator: ", "))")
    }

    /// The account's model for one the app asks for: the same slug when the
    /// plan has it, else the nearest of the same size ("mini"), else the
    /// first the plan lists.
    func planModel(for wanted: String) -> String {
        if models.isEmpty || models.contains(wanted) { return wanted }
        // The plan lists no mini (gpt-6.1-sol, gpt-6-astra,
        // gpt-6-sol, gpt-6-luna, gpt-5.6-sol/terra/luna). Measured on a
        // one-line prompt: gpt-6-sol 2.7s and gpt-6-luna 2.8s, both taking
        // reasoning effort none; gpt-6.1-sol and gpt-6-astra refuse "none".
        let small = wanted.contains("mini") || wanted.contains("nano")
        // The full model (gpt-5.4) writes the review cards. One card, three
        // runs each, one model at a time: gpt-reserve 2.8s, gpt-6-luna
        // 3.4s, codex-auto-review 3.4s … gpt-6-sol 5.0s, gpt-6-astra 8.6s.
        // The fastest the plan has — gpt-reserve, unlisted, so gpt-6-luna
        // stands behind it.
        let preferred = small ? ["gpt-6-luna", "gpt-5.6-luna", "gpt-6-sol"] : ["gpt-reserve", "gpt-6-luna", "gpt-6-sol"]
        return preferred.first { models.contains($0) } ?? models[0]
    }
}

// MARK: - Loopback callback

/// A one-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
final class LoopbackListener: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "afterplate.chatgpt.callback")

    /// Listening before it returns, on 1455 (the docs' example) or, when that
    /// is taken, any free port. The first version set a required local
    /// endpoint, which NWListener does not bind by: it never became ready,
    /// the button hung three seconds, and the redirect went out as port 0.
    static func start() async throws -> LoopbackListener {
        if let fixed = try? await LoopbackListener(port: 1455) { return fixed }
        return try await LoopbackListener(port: 0)
    }

    private init(port wanted: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: wanted) ?? .any)
        let queue = self.queue
        let listener = self.listener
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; ready.resume()
                case .failed(let error): resumed = true; ready.resume(throwing: error)
                case .cancelled: resumed = true; ready.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        guard let bound = listener.port?.rawValue, bound != 0 else {
            listener.cancel()
            throw ChatGPTAccount.AuthError(message: String(localized: "로그인 응답을 받을 포트를 열지 못했어요."))
        }
        port = bound
    }

    /// Stops waiting; the sign-in ends with `reason`.
    func cancel(_ reason: String) {
        queue.async { self.finish(.failure(ChatGPTAccount.AuthError(message: reason))) }
    }

    /// The sign-in this listener is for: a reply carrying another state is
    /// an earlier attempt's page coming back (Safari reopening an old tab),
    /// and is turned away without ending this one — taking it as the answer
    /// closed the port two seconds in, before the real reply.
    private var expected = ""

    func waitForCallback(state: String) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.expected = state
            // Waits until the browser comes back or Cancel is pressed: a
            // five-minute limit closed the port under a first sign-up, and
            // Safari came back to "can't connect to the server".
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else {
                connection.cancel(); return
            }
            let parts = head.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  url.path == "/auth/callback" else {
                connection.send(content: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
            if query["state"] != self.expected {
                print("[ChatGPT] an earlier sign-in's reply came back; still waiting for this one")
                let body = "<html><meta charset=utf-8><body style=\"font-family:-apple-system;padding:40px\"><h2>Afterplate</h2><p>\(String(localized: "이전 로그인 창이에요. 이 탭은 닫고, 가장 최근에 열린 로그인 창에서 마쳐 주세요."))</p></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let body = "<html><meta charset=utf-8><body style=\"font-family:-apple-system;padding:40px\"><h2>Afterplate</h2><p>\(String(localized: "로그인이 끝났어요. 앱으로 돌아가세요."))</p></body></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(query))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener.cancel()
        continuation.resume(with: result)
    }
}

// MARK: - Transport

/// Every OpenAI Responses call goes through here. Signed in with ChatGPT and
/// with 구독 사용 on, the request is reshaped for plan usage (store false,
/// streamed, no output cap, the plan's model) and the stream is folded back
/// into the same JSON a plain call returns, so the callers' parsing does not
/// change. Otherwise it is the API-key request it always was. When the plan
/// refuses (usage limit) and a key exists, the call is made on the key.
enum OpenAITransport {
    /// Set for work nobody asked for yet (the feed's preparation): such a
    /// call runs on the plan or not at all — never on a paid key.
    @TaskLocal static var planOnly = false
    /// A Grok model to use instead of the usual one, for a side-by-side.
    @TaskLocal static var grokModel: String?
    /// The plan answered "usage limit" — background preparation stops.
    nonisolated(unsafe) static var planLimitedAt: Date?
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let unsupported = ["background", "conversation", "max_output_tokens", "max_tool_calls", "metadata",
                                      "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier",
                                      "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id"]

    /// (body, HTTP status). On the plan the model in the returned JSON is
    /// prefixed "chatgpt-plan/" so the ledger prices it at $0.
    static func post(_ body: [String: Any], apiKey: String?, timeout: TimeInterval, tag: String) async -> (Data, Int)? {
        let apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        if Brain.current == .claude {
            let result = await ClaudeAPI.post(body, timeout: timeout, tag: tag)
            if result?.1 == 429 { planLimitedAt = Date() }
            return result
        }
        if Brain.current == .grok {
            if let token = await GrokAccount.shared.accessToken(),
               var result = await viaGrok(body, token: token, timeout: timeout, tag: tag) {
                // A 429 in a burst is xAI's per-second rate, not the plan's
                // limit: at launch the preparation sent forty drafts at once
                // and a few came back 429. Wait and try again;
                // only a 429 that persists stops the preparation.
                for wait in [2.0, 6.0] where result.1 == 429 {
                    try? await Task.sleep(for: .seconds(wait + Double.random(in: 0...1)))
                    if let again = await viaGrok(body, token: token, timeout: timeout, tag: tag) { result = again }
                }
                if result.1 == 429 { planLimitedAt = Date() }
                return result
            }
            return nil
        }
        if await ChatGPTAccount.shared.active, let token = await ChatGPTAccount.shared.accessToken() {
            if var result = await viaPlan(body, token: token, timeout: timeout, tag: tag) {
                // A failed response on the plan is often passing: all ten menu
                // searches of one batch failed together, and the same
                // searches had gone through an hour
                // before. One more try, a moment later.
                if result.1 >= 500 {
                    try? await Task.sleep(for: .seconds(2))
                    if let again = await viaPlan(body, token: token, timeout: timeout, tag: tag) { result = again }
                }
                if result.1 == 429 { planLimitedAt = Date() }
                if result.1 == 200 || apiKey == nil || planOnly { return result }
                print("[\(tag)] ChatGPT plan refused (\(result.1)); using the API key")
            }
        }
        guard let apiKey, !planOnly else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The linked Grok subscription: the same Responses body on api.x.ai,
    /// one Grok model for every call, no `reasoning` (refused by it), and
    /// the model in the answer marked "grok-plan/" so the ledger prices it $0.
    private static func viaGrok(_ original: [String: Any], token: String, timeout: TimeInterval, tag: String) async -> (Data, Int)? {
        var body = original
        body["reasoning"] = nil
        body["model"] = grokModel ?? GrokAccount.model
        body["store"] = false
        var request = URLRequest(url: GrokAccount.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        logLimitHeaders(response, plan: "Grok plan")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[\(tag)] Grok HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            return (data, status)
        }
        root["model"] = "grok-plan/" + (root["model"] as? String ?? GrokAccount.model)
        return ((try? JSONSerialization.data(withJSONObject: root)) ?? data, 200)
    }

    /// Whether a plan says how much of it is used: the documentation names
    /// no such header, so the response's limit-like headers are
    /// written to the log once per launch per plan to see.
    nonisolated(unsafe) private static var headersLogged: Set<String> = []
    private static func logLimitHeaders(_ response: URLResponse, plan: String) {
        guard !headersLogged.contains(plan), let http = response as? HTTPURLResponse else { return }
        headersLogged.insert(plan)
        let names = http.allHeaderFields.compactMap { $0.key as? String }
        let hits = names.filter { $0.range(of: "limit|usage|quota|remaining|reset|percent|credit", options: [.regularExpression, .caseInsensitive]) != nil }
        let line = hits.sorted().map { "\($0)=\(http.value(forHTTPHeaderField: $0) ?? "")" }.joined(separator: " · ")
        print("[\(plan) headers] \(http.statusCode): \(line.isEmpty ? "none of them; all: " + names.sorted().joined(separator: ", ") : line)")
    }

    private static func viaPlan(_ original: [String: Any], token: String, timeout: TimeInterval, tag: String) async -> (Data, Int)? {
        var body = original
        for key in unsupported { body[key] = nil }
        body["store"] = false
        body["stream"] = true
        let wanted = body["model"] as? String ?? ""
        let model = await ChatGPTAccount.shared.planModel(for: wanted)
        body["model"] = model
        // A bare string input is sent as one user message, as the flow wants.
        if let text = body["input"] as? String { body["input"] = [["role": "user", "content": text]] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        logLimitHeaders(response, plan: "ChatGPT plan")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch {}
            let text = String(data: data, encoding: .utf8) ?? ""
            // Some plan models take no "none" effort: ask again at "low".
            if status == 400, text.contains("'none' is not supported"),
               var reasoning = original["reasoning"] as? [String: Any] {
                reasoning["effort"] = "low"
                var again = original; again["reasoning"] = reasoning
                return await viaPlan(again, token: token, timeout: timeout, tag: tag)
            }
            print("[\(tag)] ChatGPT plan HTTP \(status): \(text.prefix(300))")
            return (data, status)
        }
        // With store false the final response carries no output: the items
        // arrive one by one before it, and are put back here.
        var items: [[String: Any]] = []
        do {
            for try await line in bytes.lines where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                let type = event["type"] as? String ?? ""
                if type == "response.output_item.done", let item = event["item"] as? [String: Any] { items.append(item) }
                if type == "response.completed" || type == "response.incomplete", var response = event["response"] as? [String: Any] {
                    if (response["output"] as? [[String: Any]] ?? []).isEmpty { response["output"] = items }
                    response["model"] = "chatgpt-plan/" + (response["model"] as? String ?? model)
                    return ((try? JSONSerialization.data(withJSONObject: response)) ?? Data(), 200)
                }
                if type == "response.failed" || type == "error" {
                    let error = ((event["response"] as? [String: Any])?["error"] as? [String: Any]) ?? event
                    let code = error["code"] as? String ?? "failed"
                    print("[\(tag)] ChatGPT plan failed: \(code)")
                    Usage.local(tag: "플랜 실패", detail: "\(tag): \(code) \(String(payload.prefix(400)))", seconds: 0)
                    let limited = code.contains("usage")
                    return ((try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(), limited ? 429 : 500)
                }
            }
        } catch {
            print("[\(tag)] ChatGPT plan stream broke: \(error.localizedDescription)")
            return nil
        }
        return nil
    }
}
