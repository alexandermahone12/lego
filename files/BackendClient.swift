import Foundation

/// Everything that must live on a server, behind one protocol.
///
/// `MockBackend` lets you run the whole app today. When you pick a backend
/// (Firebase and Supabase are both reasonable), write one conforming type and
/// change the line in `BackendClient.shared`. No view code changes.
protocol Backend {
    func signInWithApple(identityToken: String, rawNonce: String, authorizationCode: String?,
                         displayName: String?, email: String?) async throws -> Session
    func deleteAccount() async throws

    /// Upload one prepared JPEG. Returns the path to store on the listing, which the
    /// app resolves against whatever server it is pointed at.
    func uploadPhoto(_ jpeg: Data) async throws -> URL

    func listings(theme: String?, type: ListingType?, condition: Condition?,
                  query: String?) async throws -> [Listing]
    func publish(_ listing: Listing) async throws -> Listing
    func markSold(listingID: String) async throws
    func delete(listingID: String) async throws

    func wanted() async throws -> [WantedItem]
    func addWanted(_ item: WantedItem) async throws
    func removeWanted(id: String) async throws

    func report(_ report: Report) async throws
    func block(userID: String) async throws
    func blockedUserIDs() async throws -> Set<String>
}

struct Session: Codable {
    let accessToken: String
    let refreshToken: String?
    let userID: String
}

enum BackendError: LocalizedError {
    case notConfigured
    case network
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Brick Souq isn't connected to a server yet."
        case .network: "Couldn't reach Brick Souq. Check your connection."
        case .rejected(let reason): reason
        }
    }
}

enum BackendClient {
    /// The real server lives in `server/` — start it with `npm start` from there.
    ///
    /// Swap in `MockBackend.instance` to work on the UI with no server running; nothing
    /// else in the app has to change, which is the point of the protocol above.
    static let shared: Backend = HTTPBackend.shared
}

// MARK: - Mock

/// In-memory only. Data disappears when the app is killed. This exists so you can
/// build, run and demo before writing a single line of server code — it is not a
/// backend and must not ship.
actor MockBackend: Backend {
    static let instance = MockBackend()

    private var store: [Listing] = MockData.listings
    private var wantedItems: [WantedItem] = MockData.wanted
    private var blocked: Set<String> = []

    func signInWithApple(identityToken: String, rawNonce: String, authorizationCode: String?,
                         displayName: String?, email: String?) async throws -> Session {
        try await Task.sleep(for: .milliseconds(400))
        return Session(accessToken: UUID().uuidString, refreshToken: nil, userID: "mock-user")
    }

    func deleteAccount() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func uploadPhoto(_ jpeg: Data) async throws -> URL {
        try await Task.sleep(for: .milliseconds(300))
        // Nothing is stored; the Sell screen shows the thumbnail it already has.
        return URL(string: "/v1/photos/\(UUID().uuidString.lowercased()).jpg")!
    }

    func listings(theme: String?, type: ListingType?, condition: Condition?,
                  query: String?) async throws -> [Listing] {
        try await Task.sleep(for: .milliseconds(200))
        return store.filter { listing in
            guard !listing.isSold, !blocked.contains(listing.sellerID) else { return false }
            if let theme, listing.theme != theme { return false }
            if let type, listing.type != type { return false }
            if let condition, listing.condition != condition { return false }
            if let query, !query.isEmpty {
                let haystack = "\(listing.title) \(listing.setNumber ?? "") \(listing.theme)".lowercased()
                if !haystack.contains(query.lowercased()) { return false }
            }
            return true
        }
    }

    func publish(_ listing: Listing) async throws -> Listing {
        try await Task.sleep(for: .milliseconds(400))
        store.insert(listing, at: 0)
        return listing
    }

    func markSold(listingID: String) async throws {
        if let i = store.firstIndex(where: { $0.id == listingID }) { store[i].isSold = true }
    }

    func delete(listingID: String) async throws {
        store.removeAll { $0.id == listingID }
    }

    func wanted() async throws -> [WantedItem] { wantedItems }
    func addWanted(_ item: WantedItem) async throws { wantedItems.append(item) }
    func removeWanted(id: String) async throws { wantedItems.removeAll { $0.id == id } }

    func report(_ report: Report) async throws {
        try await Task.sleep(for: .milliseconds(300))
        // Real implementation: write to a moderation queue and alert whoever is
        // on duty. Apple requires action within 24 hours of a report.
    }

    func block(userID: String) async throws { blocked.insert(userID) }
    func blockedUserIDs() async throws -> Set<String> { blocked }
}
