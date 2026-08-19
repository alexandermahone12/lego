import Foundation

/// The set catalog.
///
/// IMPORTANT: the bundled list below is a stub of ~30 sets for development. LEGO has
/// released well over 20,000. Search is worthless without the real thing — someone looks
/// for "ninjago dragon", finds nothing, and concludes the app is broken.
///
/// Before launch, replace `bundled` with a synced catalog. Rebrickable's API is the
/// practical choice: full set data with images, free tier, and terms that permit this
/// use. BrickLink's catalog is richer but owned by the LEGO Group — read their terms
/// before depending on it.
///
/// Sync strategy that works: ship a pre-built SQLite file in the bundle so search is
/// instant and works offline, then refresh it from your server monthly for new releases.
/// Do not hit a third-party API on every keystroke.
final class Catalog {
    static let shared = Catalog()

    private(set) var sets: [String: BrickSet] = [:]

    private init() {
        for set in Self.bundled { sets[set.id] = set }
    }

    func set(_ number: String) -> BrickSet? { sets[number] }

    /// Ranked search over numbers, names and themes.
    ///
    /// Ranking order matters more than the matching does. Someone typing "10" wants set
    /// numbers; someone typing "castle" wants names. Prefix matches beat substring
    /// matches, and theme matches come last so "star" surfaces the sets before it
    /// surfaces the entire Star Wars catalog.
    func search(_ query: String, limit: Int = 8) -> [BrickSet] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        return sets.values
            .compactMap { set -> (BrickSet, Int)? in
                let name = set.name.lowercased()
                if set.id.hasPrefix(needle)            { return (set, 0) }
                if name.hasPrefix(needle)              { return (set, 1) }
                if name.contains(needle)               { return (set, 2) }
                if set.theme.lowercased().contains(needle) { return (set, 3) }
                return nil
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.name < rhs.0.name
            }
            .prefix(limit)
            .map(\.0)
    }

    static let themes = [
        "Star Wars", "Technic", "Icons", "Harry Potter", "City", "Ninjago",
        "Architecture", "Botanicals", "Ideas", "Creator", "Marvel",
        "Minecraft", "Friends", "Speed Champions", "Duplo"
    ]

    static func themeSeed(_ theme: String) -> Int {
        abs(theme.hashValue % 360)
    }

    // MARK: - Development stub

    private static let bundled: [BrickSet] = [
        .init(id: "75192", name: "Millennium Falcon", theme: "Star Wars", pieces: 7541, year: 2017, retailQAR: 3299, isRetired: false),
        .init(id: "75313", name: "AT-AT", theme: "Star Wars", pieces: 6785, year: 2021, retailQAR: 3199, isRetired: false),
        .init(id: "75331", name: "The Razor Crest", theme: "Star Wars", pieces: 6187, year: 2022, retailQAR: 2699, isRetired: true),
        .init(id: "75341", name: "Luke Skywalker's Landspeeder", theme: "Star Wars", pieces: 1890, year: 2022, retailQAR: 999, isRetired: true),
        .init(id: "42143", name: "Ferrari Daytona SP3", theme: "Technic", pieces: 3778, year: 2022, retailQAR: 1499, isRetired: false),
        .init(id: "42115", name: "Lamborghini Sián FKP 37", theme: "Technic", pieces: 3696, year: 2020, retailQAR: 1499, isRetired: true),
        .init(id: "42131", name: "Cat D11 Bulldozer", theme: "Technic", pieces: 3854, year: 2021, retailQAR: 1699, isRetired: false),
        .init(id: "42100", name: "Liebherr R 9800 Excavator", theme: "Technic", pieces: 4108, year: 2019, retailQAR: 1799, isRetired: true),
        .init(id: "10305", name: "Lion Knights' Castle", theme: "Icons", pieces: 4514, year: 2022, retailQAR: 1599, isRetired: true),
        .init(id: "10276", name: "Colosseum", theme: "Icons", pieces: 9036, year: 2020, retailQAR: 2099, isRetired: true),
        .init(id: "10294", name: "Titanic", theme: "Icons", pieces: 9090, year: 2021, retailQAR: 2599, isRetired: false),
        .init(id: "10497", name: "Galaxy Explorer", theme: "Icons", pieces: 1254, year: 2022, retailQAR: 449, isRetired: true),
        .init(id: "71043", name: "Hogwarts Castle", theme: "Harry Potter", pieces: 6020, year: 2018, retailQAR: 1799, isRetired: false),
        .init(id: "76399", name: "Hogwarts Magical Trunk", theme: "Harry Potter", pieces: 603, year: 2022, retailQAR: 299, isRetired: false),
        .init(id: "60337", name: "Express Passenger Train", theme: "City", pieces: 764, year: 2022, retailQAR: 599, isRetired: false),
        .init(id: "60198", name: "Cargo Train", theme: "City", pieces: 1226, year: 2018, retailQAR: 799, isRetired: true),
        .init(id: "71741", name: "Ninjago City Gardens", theme: "Ninjago", pieces: 5685, year: 2021, retailQAR: 1499, isRetired: true),
        .init(id: "21058", name: "Great Pyramid of Giza", theme: "Architecture", pieces: 1476, year: 2022, retailQAR: 599, isRetired: false),
        .init(id: "21051", name: "Tokyo", theme: "Architecture", pieces: 547, year: 2020, retailQAR: 249, isRetired: false),
        .init(id: "21044", name: "Paris", theme: "Architecture", pieces: 649, year: 2019, retailQAR: 249, isRetired: false),
        .init(id: "10281", name: "Bonsai Tree", theme: "Botanicals", pieces: 878, year: 2021, retailQAR: 199, isRetired: false),
        .init(id: "10280", name: "Flower Bouquet", theme: "Botanicals", pieces: 756, year: 2021, retailQAR: 199, isRetired: false),
        .init(id: "10289", name: "Bird of Paradise", theme: "Botanicals", pieces: 1173, year: 2021, retailQAR: 359, isRetired: false),
        .init(id: "21318", name: "Tree House", theme: "Ideas", pieces: 3036, year: 2019, retailQAR: 1099, isRetired: true),
        .init(id: "21335", name: "Motorised Lighthouse", theme: "Ideas", pieces: 2065, year: 2022, retailQAR: 1099, isRetired: false),
        .init(id: "31120", name: "Medieval Castle", theme: "Creator", pieces: 1426, year: 2021, retailQAR: 449, isRetired: true),
        .init(id: "76178", name: "Daily Bugle", theme: "Marvel", pieces: 3772, year: 2021, retailQAR: 1399, isRetired: true),
        .init(id: "21188", name: "The Llama Village", theme: "Minecraft", pieces: 1252, year: 2022, retailQAR: 349, isRetired: false),
        .init(id: "41732", name: "Downtown Flower and Design Stores", theme: "Friends", pieces: 2010, year: 2023, retailQAR: 499, isRetired: false),
        .init(id: "76900", name: "Koenigsegg Jesko", theme: "Speed Champions", pieces: 280, year: 2021, retailQAR: 89, isRetired: true),
        .init(id: "10874", name: "Steam Train", theme: "Duplo", pieces: 59, year: 2018, retailQAR: 149, isRetired: false)
    ]
}

// MARK: - Development data

enum MockData {
    static let listings: [Listing] = [
        Listing(id: "1", sellerID: "u1", sellerName: "Faisal", sellerTrades: 24, type: .set,
                setNumber: "10305", theme: "Icons", title: "Lion Knights' Castle",
                condition: .new, completeness: 8, includesInstructions: true, boxCondition: "Mint",
                priceQAR: 2400, note: "Bought two at launch. Never opened, stored flat in AC.",
                photoURLs: [], whatsAppNumber: "97433124455", createdAt: .now.addingTimeInterval(-172_800)),

        Listing(id: "2", sellerID: "u2", sellerName: "Maryam", sellerTrades: 11, type: .set,
                setNumber: "10497", theme: "Icons", title: "Galaxy Explorer",
                condition: .good, completeness: 8, includesInstructions: true, boxCondition: "Good",
                priceQAR: 520, note: "Built it, displayed it a year, took it apart. Every piece counted back against the inventory.",
                photoURLs: [], whatsAppNumber: "97455667788", createdAt: .now.addingTimeInterval(-18_000)),

        Listing(id: "3", sellerID: "u3", sellerName: "Ibrahim", sellerTrades: 6, type: .bulk,
                setNumber: nil, theme: "Mixed", title: "Mixed bulk lot, 4.2 kg",
                condition: .poor, completeness: nil, includesInstructions: false, boxCondition: nil,
                priceQAR: 340, note: "Kids grew out of it. All jumbled in one box, no sorting. Mostly City and Creator.",
                photoURLs: [], whatsAppNumber: "97466778899", createdAt: .now.addingTimeInterval(-86_400)),

        Listing(id: "4", sellerID: "u4", sellerName: "Dana", sellerTrades: 38, type: .set,
                setNumber: "21318", theme: "Ideas", title: "Tree House",
                condition: .built, completeness: 7, includesInstructions: true, boxCondition: "Fair",
                priceQAR: 1650, note: "Missing 6 leaf elements and one 1x2 tile. Listed below market because of it — I'd rather be honest than argue later.",
                photoURLs: [], whatsAppNumber: "97477889900", createdAt: .now.addingTimeInterval(-259_200)),

        Listing(id: "5", sellerID: "u1", sellerName: "Faisal", sellerTrades: 24, type: .minifigures,
                setNumber: nil, theme: "Star Wars", title: "Star Wars minifigures, 14 figures",
                condition: .good, completeness: nil, includesInstructions: false, boxCondition: nil,
                priceQAR: 275, note: "Fourteen figures, all authentic, all with correct accessories.",
                photoURLs: [], whatsAppNumber: "97433124455", createdAt: .now.addingTimeInterval(-345_600)),

        Listing(id: "6", sellerID: "u5", sellerName: "Hessa", sellerTrades: 9, type: .set,
                setNumber: "75341", theme: "Star Wars", title: "Luke Skywalker's Landspeeder",
                condition: .new, completeness: 8, includesInstructions: true, boxCondition: "Mint",
                priceQAR: 1180, note: "Sealed since release. Retired now, but I need the shelf space.",
                photoURLs: [], whatsAppNumber: "97488990011", createdAt: .now.addingTimeInterval(-43_200))
    ]

    static let wanted: [WantedItem] = [
        WantedItem(id: "w1", setNumber: "10276", theme: nil, maxPriceQAR: 2600),
        WantedItem(id: "w2", setNumber: "75313", theme: nil, maxPriceQAR: 2800),
        WantedItem(id: "w3", setNumber: nil, theme: "Technic", maxPriceQAR: 1200)
    ]
}
