import Foundation

// MARK: - User

struct User: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var displayName: String?
    var email: String?
    var whatsAppNumber: String?
    var completedTrades: Int = 0
    var rating: Double?
    var joinedAt: Date = .now

    var initial: String {
        String(displayName?.first ?? "?")
    }
}

// MARK: - Condition

enum Condition: String, Codable, CaseIterable, Identifiable {
    case new = "New"
    case built = "Built"
    case good = "Good condition"
    case poor = "Poor condition"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .new:   "Sealed, never opened"
        case .built: "Assembled and on display"
        case .good:  "Taken apart, bagged and sorted"
        case .poor:  "Pieces no longer organised"
        }
    }

    /// Rough multiplier against original retail. Replace with real sold-price data
    /// once you have enough completed trades to compute it — this is a placeholder.
    var priceMultiplier: Double {
        switch self {
        case .new: 1.50
        case .built: 0.80
        case .good: 0.60
        case .poor: 0.35
        }
    }
}

// MARK: - Listing type

enum ListingType: String, Codable, CaseIterable, Identifiable {
    case set, minifigures, bulk, parts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .set: "Sets"
        case .minifigures: "Minifigures"
        case .bulk: "Bulk bricks"
        case .parts: "Parts"
        }
    }
}

// MARK: - Catalog set

struct BrickSet: Codable, Identifiable, Hashable {
    let id: String          // set number, e.g. "10305"
    let name: String
    let theme: String
    let pieces: Int
    let year: Int
    let retailQAR: Int
    let isRetired: Bool
    var imageURL: URL?
}

// MARK: - Listing

struct Listing: Codable, Identifiable, Hashable {
    let id: String
    let sellerID: String
    var sellerName: String
    var sellerTrades: Int

    var type: ListingType
    var setNumber: String?      // nil for bulk / parts / minifigure lots
    var theme: String
    var title: String

    var condition: Condition
    /// 0–8. nil where completeness is meaningless, e.g. an unsorted bulk box.
    var completeness: Int?
    var includesInstructions: Bool
    var boxCondition: String?

    var priceQAR: Int
    var note: String
    var photoURLs: [URL]
    var whatsAppNumber: String

    var createdAt: Date
    var isSold: Bool = false

    var subtitle: String {
        if let set = Catalog.shared.set(setNumber ?? "") {
            return "\(set.theme) · \(set.pieces.formatted()) pcs"
        }
        return theme
    }

    /// Deep link that opens WhatsApp with the set already named, so the seller's first
    /// message isn't "hi is this available".
    var whatsAppURL: URL? {
        let identifier = setNumber.map { "\(title) (\($0))" } ?? title
        let text = "Hi — I saw your \(identifier) on Brick Souq for QAR \(priceQAR). Is it still available?"
        let digits = whatsAppNumber.filter(\.isNumber)
        var components = URLComponents(string: "https://wa.me/\(digits)")
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        return components?.url
    }
}

// MARK: - Wanted

struct WantedItem: Codable, Identifiable, Hashable {
    let id: String
    var setNumber: String?
    var theme: String?
    var maxPriceQAR: Int?
    var createdAt: Date = .now
}

// MARK: - Moderation

struct Report: Codable, Identifiable {
    enum Reason: String, Codable, CaseIterable, Identifiable {
        case counterfeit = "Counterfeit or clone bricks"
        case misleading  = "Condition is misleading"
        case prohibited  = "Not LEGO, or not allowed here"
        case spam        = "Spam or duplicate listing"
        case abusive     = "Abusive or offensive content"
        case other       = "Something else"

        var id: String { rawValue }
    }

    let id: String
    let listingID: String
    let reporterID: String
    let reason: Reason
    var detail: String?
    let createdAt: Date
}
