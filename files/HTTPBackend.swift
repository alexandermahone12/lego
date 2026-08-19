import Foundation

// MARK: - Where the server lives

enum ServerConfig {

    /// The deployed server. HTTPS, always on, and what a TestFlight or App Store build
    /// has to talk to — nobody else can reach your Mac.
    ///
    /// To develop against your own machine instead, set the override below rather than
    /// editing this line, so a local address can never be shipped by accident.
    private static let defaultURL = "https://lego-production-5167.up.railway.app"

    /// Overridable without touching code:
    ///
    ///   Xcode → Edit Scheme → Run → Arguments → Environment Variables
    ///   BRICKSOUQ_SERVER_URL = http://localhost:8080
    ///
    /// Use that for day-to-day work against `npm start` on your Mac. On a real device
    /// localhost is the *phone*, so use your Mac's Wi-Fi address there instead
    /// ("http://192.168.18.123:8080") plus the ATS exception in server/README.md —
    /// iOS blocks plain HTTP to anything but loopback.
    static var baseURL: URL {
        let string = ProcessInfo.processInfo.environment["BRICKSOUQ_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: "BrickSouqServerURL")
            ?? defaultURL
        return URL(string: string) ?? URL(string: defaultURL)!
    }

    /// Photos are stored as paths ("/v1/photos/<uuid>.jpg") rather than absolute URLs,
    /// so moving the server from your Mac to a real host does not invalidate every
    /// image already in the database. This is where a path becomes loadable.
    static func absoluteURL(for stored: URL) -> URL {
        guard stored.scheme == nil else { return stored }
        return URL(string: stored.absoluteString, relativeTo: baseURL)?.absoluteURL ?? stored
    }
}

// MARK: - HTTP backend

/// The real backend: talks to the server in `server/`.
///
/// An actor because the token refresh has to be serialised — otherwise five views
/// loading at once all get a 401 at the same moment and all try to refresh, and four of
/// them burn the rotated refresh token and log the user out.
actor HTTPBackend: Backend {

    static let shared = HTTPBackend()

    private let baseURL: URL
    private let session: URLSession
    private let keychain = KeychainStore(service: "qa.bricksouq.auth")

    private var refreshTask: Task<Void, Error>?

    init(baseURL: URL = ServerConfig.baseURL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Tokens

    private var accessToken: String? {
        keychain.string(for: "accessToken")
    }

    private func store(_ session: Session) {
        keychain.set(session.accessToken, for: "accessToken")
        if let refreshToken = session.refreshToken {
            keychain.set(refreshToken, for: "refreshToken")
        }
        keychain.set(session.userID, for: "serverUserID")
    }

    private func clearTokens() {
        keychain.delete("accessToken")
        keychain.delete("refreshToken")
        keychain.delete("serverUserID")
        keychain.delete("appleAuthorizationCode")
    }

    // MARK: - Backend

    func signInWithApple(identityToken: String, rawNonce: String, authorizationCode: String?,
                         displayName: String?, email: String?) async throws -> Session {
        var payload: [String: Any] = [
            "identityToken": identityToken,
            "rawNonce": rawNonce
        ]
        if let authorizationCode { payload["authorizationCode"] = authorizationCode }
        if let displayName { payload["displayName"] = displayName }
        if let email { payload["email"] = email }

        let session: Session = try await send("POST", "/v1/auth/apple",
                                              body: payload, authenticated: false)
        store(session)

        // Apple's revoke endpoint needs this code, and it is valid exactly once, right
        // now. Keep it or account deletion can only ever delete our half.
        if let authorizationCode {
            keychain.set(authorizationCode, for: "appleAuthorizationCode")
        }
        return session
    }

    /// Guideline 5.1.1(v). The server does the revoking; our job is to hand it the
    /// authorization code we stashed at sign-in.
    func deleteAccount() async throws {
        struct Deletion: Decodable { let deleted: Bool }

        var payload: [String: Any] = [:]
        if let code = keychain.string(for: "appleAuthorizationCode") {
            payload["authorizationCode"] = code
        }

        let _: Deletion = try await send("DELETE", "/v1/account", body: payload)
        clearTokens()
    }

    func uploadPhoto(_ jpeg: Data) async throws -> URL {
        struct Uploaded: Decodable { let id: String; let path: String; let bytes: Int }

        // A raw image body, not multipart. The server has one field to receive, and a
        // multipart parser would be a dependency or a page of code to avoid it.
        let uploaded: Uploaded = try await send("POST", "/v1/photos",
                                                body: jpeg, contentType: "image/jpeg")

        guard let url = URL(string: uploaded.path) else {
            throw BackendError.rejected("The server returned a photo we can't read.")
        }
        return url
    }

    func listings(theme: String?, type: ListingType?, condition: Condition?,
                  query: String?) async throws -> [Listing] {
        struct Response: Decodable { let listings: [Listing] }

        var items: [URLQueryItem] = []
        if let theme { items.append(URLQueryItem(name: "theme", value: theme)) }
        if let type { items.append(URLQueryItem(name: "type", value: type.rawValue)) }
        if let condition { items.append(URLQueryItem(name: "condition", value: condition.rawValue)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }

        let response: Response = try await send("GET", "/v1/listings", query: items)
        return response.listings
    }

    /// The server overrides id, sellerID, sellerName, sellerTrades and createdAt from
    /// the session — a client does not get to say who it is — so use what comes back
    /// rather than what went out.
    func publish(_ listing: Listing) async throws -> Listing {
        try await send("POST", "/v1/listings", body: try encoded(listing))
    }

    func markSold(listingID: String) async throws {
        try await sendVoid("POST", "/v1/listings/\(escape(listingID))/sold")
    }

    func delete(listingID: String) async throws {
        try await sendVoid("DELETE", "/v1/listings/\(escape(listingID))")
    }

    func wanted() async throws -> [WantedItem] {
        struct Response: Decodable { let wanted: [WantedItem] }
        let response: Response = try await send("GET", "/v1/wanted")
        return response.wanted
    }

    func addWanted(_ item: WantedItem) async throws {
        let _: WantedItem = try await send("POST", "/v1/wanted", body: try encoded(item))
    }

    func removeWanted(id: String) async throws {
        try await sendVoid("DELETE", "/v1/wanted/\(escape(id))")
    }

    func report(_ report: Report) async throws {
        struct Receipt: Decodable { let received: Bool }
        let _: Receipt = try await send("POST", "/v1/reports", body: try encoded(report))
    }

    func block(userID: String) async throws {
        struct Response: Decodable { let blockedUserIDs: [String] }
        let _: Response = try await send("POST", "/v1/blocks", body: ["userID": userID])
    }

    func blockedUserIDs() async throws -> Set<String> {
        struct Response: Decodable { let blockedUserIDs: [String] }
        let response: Response = try await send("GET", "/v1/blocks")
        return Set(response.blockedUserIDs)
    }

    // MARK: - Request plumbing

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        do {
            return try Self.encoder.encode(value)
        } catch {
            throw BackendError.rejected("Couldn't prepare that request.")
        }
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String,
        query: [URLQueryItem] = [], body: Any? = nil,
        contentType: String = "application/json", authenticated: Bool = true
    ) async throws -> Response {
        let data = try await perform(method, path, query: query, body: body,
                                     contentType: contentType, authenticated: authenticated)
        guard !data.isEmpty else { throw BackendError.rejected("The server sent an empty reply.") }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw BackendError.rejected("Couldn't read the server's reply.")
        }
    }

    private func sendVoid(
        _ method: String, _ path: String,
        query: [URLQueryItem] = [], body: Any? = nil, authenticated: Bool = true
    ) async throws {
        _ = try await perform(method, path, query: query, body: body,
                              contentType: "application/json", authenticated: authenticated)
    }

    private func perform(
        _ method: String, _ path: String,
        query: [URLQueryItem], body: Any?, contentType: String,
        authenticated: Bool, isRetry: Bool = false
    ) async throws -> Data {

        if authenticated { try await ensureSignedIn() }

        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw BackendError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if authenticated, let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if let data = body as? Data {
                request.httpBody = data
            } else if let dictionary = body as? [String: Any] {
                request.httpBody = try? JSONSerialization.data(withJSONObject: dictionary)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.network
        }

        guard let http = response as? HTTPURLResponse else { throw BackendError.network }

        switch http.statusCode {
        case 200...299:
            return data

        case 401 where authenticated && !isRetry:
            // Try once to get a working session, then retry exactly once — a second
            // 401 means it is genuinely dead, and retrying forever would just spin.
            guard await recoverSession() else {
                clearTokens()
                throw BackendError.rejected("Your session expired. Sign in again.")
            }
            return try await perform(method, path, query: query, body: body,
                                     contentType: contentType,
                                     authenticated: authenticated, isRetry: true)

        case 401:
            clearTokens()
            throw BackendError.rejected("Your session expired. Sign in again.")

        default:
            throw BackendError.rejected(Self.serverMessage(from: data)
                ?? "The server refused that request (\(http.statusCode)).")
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        struct Failure: Decodable { let error: String }
        return try? JSONDecoder().decode(Failure.self, from: data).error
    }

    // MARK: - Session management

    /// Get back to a working session after a 401.
    ///
    /// The ordinary cause is an expired access token, which the refresh token fixes.
    /// The other cause — the one that costs an afternoon — is that the server's database
    /// was reset while this app kept a token from before it. Browsing hides that,
    /// because browsing does not require a session, so the first thing that fails is the
    /// first authenticated call and the error points at the wrong thing entirely.
    ///
    /// In DEBUG, `skipSignIn` means there is no sign-in screen to send anyone to, so
    /// telling the user to sign in again is useless advice. Get a fresh development
    /// session instead and carry on.
    private func recoverSession() async -> Bool {
        if (try? await refreshSession()) != nil { return true }

        clearTokens()

        #if DEBUG
        if (try? await ensureSignedIn()) != nil { return true }
        #endif

        return false
    }

    /// Collapses concurrent refreshes into one. Whoever arrives while a refresh is in
    /// flight waits for that one instead of starting another.
    private func refreshSession() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }

        let task = Task<Void, Error> { [keychain, baseURL, session] in
            guard let refreshToken = keychain.string(for: "refreshToken") else {
                throw BackendError.rejected("Your session expired. Sign in again.")
            }

            var request = URLRequest(url: baseURL.appendingPathComponent("/v1/auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let renewed = try? HTTPBackend.decoder.decode(Session.self, from: data) else {
                throw BackendError.rejected("Your session expired. Sign in again.")
            }

            keychain.set(renewed.accessToken, for: "accessToken")
            if let token = renewed.refreshToken { keychain.set(token, for: "refreshToken") }
        }

        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    /// In DEBUG the app can skip the Apple flow (`RootView.skipSignIn`), which leaves no
    /// token for the server to check. Rather than every screen failing, grab a
    /// development session automatically. The server only serves these when it is not
    /// running as production, and the whole thing compiles out of a release build.
    private func ensureSignedIn() async throws {
        guard accessToken == nil else { return }

        #if DEBUG
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/auth/dev"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userID": "dev-user",
            "displayName": "Faisal",
            "whatsAppNumber": "97433124455",
            "completedTrades": 24
        ])

        guard let (data, response) = try? await session.data(for: request) else {
            throw BackendError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A production server refuses development sign-in on purpose, so this is not a
        // fault — it means the app is pointed at a real server while still skipping the
        // Apple flow. Reporting "check your connection" here sends you hunting through
        // the server for a problem that is in RootView.
        if status == 404 {
            throw BackendError.rejected(
                "This server has development sign-in disabled, which is correct for a "
                + "deployed one. Set skipSignIn to false in RootView to use Sign in "
                + "with Apple, or point BRICKSOUQ_SERVER_URL at your local server."
            )
        }

        guard status == 200, let devSession = try? Self.decoder.decode(Session.self, from: data) else {
            throw BackendError.network
        }
        store(devSession)
        #else
        throw BackendError.rejected("Sign in to continue.")
        #endif
    }

    // MARK: - Coding

    /// Dates cross the wire as ISO-8601.
    ///
    /// `.iso8601` on its own chokes on the fractional seconds JavaScript's
    /// `toISOString()` always emits, so parse both shapes. These are format *styles*
    /// rather than `ISO8601DateFormatter`s because the styles are value types and can
    /// therefore be shared across concurrency domains — a formatter object cannot.
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)

            if let date = try? withFractionalSeconds.parse(text) { return date }
            if let date = try? withoutFractionalSeconds.parse(text) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not an ISO-8601 date: \(text)"
            )
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(withFractionalSeconds))
        }
        return encoder
    }()
}
