import AuthenticationServices
import SwiftUI

// MARK: - Root

struct RootView: View {
    @StateObject private var auth = AuthManager()
    @StateObject private var blockList = BlockList()

    /// Skips the sign-in screen during development. Flip to false before you test
    /// the real Apple flow. The #if DEBUG means it can't reach a release build.
    #if DEBUG
    private let skipSignIn = true
    #else
    private let skipSignIn = false
    #endif

    private let devUser = User(
        id: "dev-user",
        displayName: "Faisal",
        email: nil,
        whatsAppNumber: "97433124455",
        completedTrades: 24,
        rating: 4.9
    )

    var body: some View {
        Group {
            if skipSignIn {
                MainTabs(user: devUser)
                    .environmentObject(auth)
                    .environmentObject(blockList)
                    .task { await blockList.refresh() }
            } else {
                switch auth.state {
                case .unknown:
                    ProgressView().tint(Brand.yellowDeep)
                case .signedOut:
                    SignInView(auth: auth)
                case .signedIn(let user):
                    MainTabs(user: user)
                        .environmentObject(auth)
                        .environmentObject(blockList)
                        .task { await blockList.refresh() }
                }
            }
        }
        .task {
            if !skipSignIn { await auth.restoreSession() }
        }
    }
}
// MARK: - Sign in

struct SignInView: View {
    @ObservedObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Brand.yellow).frame(width: 11, height: 11)
                }
            }
            Text("Brick Souq")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Brand.ink)
                .padding(.top, 12)

            Text("Buy and sell secondhand LEGO® in Qatar.\nPost a listing, talk on WhatsApp, sort the rest out yourselves.")
                .font(.system(size: 15))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            Spacer()

            VStack(spacing: 14) {
                SignInWithAppleButton(.signIn) { request in
                    auth.configure(request)
                } onCompletion: { result in
                    Task { await auth.handle(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                Text("We only ever see the name and email you choose to share. Apple's Hide My Email works fine here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Link("Privacy Policy", destination: URL(string: "https://bricksouq.qa/privacy")!)
                    Link("Terms", destination: URL(string: "https://bricksouq.qa/terms")!)
                }
                .font(.system(size: 12, weight: .medium))
                .tint(Brand.ink)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.page)
        .alert("Sign in", isPresented: .constant(auth.errorMessage != nil)) {
            Button("OK") { auth.errorMessage = nil }
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }
}

// MARK: - Tabs

struct MainTabs: View {
    let user: User

    enum Tab: Hashable { case browse, search, sell, you }
    @State private var selection: Tab = .browse

    var body: some View {
        TabView(selection: $selection) {
            // Browse is the front face: recent listings, nothing to configure. Anything
            // that involves deciding what you want lives one tab across.
            BrowseView(currentUser: user, onSearch: { selection = .search })
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                .tag(Tab.browse)

            SearchView(currentUser: user)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            SellView(currentUser: user)
                .tabItem { Label("Sell", systemImage: "plus.circle") }
                .tag(Tab.sell)

            // Wanted lives inside You now — it is a thing about you, not a place.
            ProfileView(user: user)
                .tabItem { Label("You", systemImage: "person") }
                .tag(Tab.you)
        }
        .tint(Brand.yellowDeep)
    }
}

// MARK: - Browse

struct BrowseView: View {
    let currentUser: User
    let onSearch: () -> Void

    @EnvironmentObject private var blockList: BlockList
    @State private var listings: [Listing] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var visible: [Listing] {
        listings.filter { !blockList.isBlocked($0.sellerID) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    studStrip

                    HStack {
                        SectionLabel(text: "Just listed")
                        Spacer()
                        if isLoading && !visible.isEmpty {
                            ProgressView().controlSize(.small).tint(Brand.yellowDeep)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    if visible.isEmpty && !isLoading {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(visible) { listing in
                                NavigationLink {
                                    ListingDetailView(listing: listing, currentUser: currentUser)
                                } label: {
                                    ListingCard(listing: listing)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Brand.page)
            .navigationTitle("Brick Souq")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .tint(Brand.ink)
                    .accessibilityLabel("Search")
                }
            }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    /// A course of studs under the title. Cheap, and it makes the top of the app look
    /// like the top of a brick.
    private var studStrip: some View {
        StudCaps(count: 9, color: Brand.yellow, studWidth: 14, studHeight: 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(loadError == nil ? "Nothing listed yet" : "Can't reach Brick Souq")
                .font(.system(size: 17, weight: .bold))
            Text(loadError ?? "Be the first — the Sell tab takes about a minute.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
            if loadError != nil {
                Button("Try again") { Task { await load() } }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            listings = try await BackendClient.shared.listings(
                theme: nil, type: nil, condition: nil, query: nil
            )
            loadError = nil
        } catch {
            listings = []
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Search

/// Everything that involves deciding what you want: the query, the categories, and the
/// filters. Keeping it here is what lets Browse stay a plain feed.
struct SearchView: View {
    let currentUser: User

    @EnvironmentObject private var blockList: BlockList
    @State private var listings: [Listing] = []
    @State private var query = ""
    @State private var theme: String?
    @State private var type: ListingType?
    @State private var condition: Condition?
    @State private var isLoading = false
    @State private var loadError: String?

    private var isFiltering: Bool {
        !query.isEmpty || theme != nil || type != nil || condition != nil
    }

    private var visible: [Listing] {
        listings.filter { !blockList.isBlocked($0.sellerID) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    if !query.isEmpty {
                        let suggestions = Catalog.shared.search(query, limit: 5)
                        if !suggestions.isEmpty {
                            SectionLabel(text: "Sets matching \"\(query)\"").padding(.horizontal, 16)
                            VStack(spacing: 0) {
                                ForEach(suggestions) { set in
                                    Button {
                                        query = set.name
                                        theme = nil
                                    } label: {
                                        SetSuggestionRow(set: set,
                                                         listedCount: listings.filter { $0.setNumber == set.id }.count)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 64)
                                }
                            }
                            .background(Brand.card)
                            .clipShape(BrickFace(cornerRadius: 10))
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                        }
                    }

                    filters

                    if !isFiltering {
                        SectionLabel(text: "Browse by theme")
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                        themeGrid
                    }

                    resultsHeader

                    if visible.isEmpty && !isLoading {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(visible) { listing in
                                NavigationLink {
                                    ListingDetailView(listing: listing, currentUser: currentUser)
                                } label: {
                                    ListingCard(listing: listing)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Brand.page)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search a set name or number")
            .refreshable { await load() }
        }
        .task { await load() }
        .onChange(of: theme) { _, _ in Task { await load() } }
        .onChange(of: type) { _, _ in Task { await load() } }
        .onChange(of: condition) { _, _ in Task { await load() } }
        .onChange(of: query) { _, _ in Task { await load() } }
    }

    private var resultsHeader: some View {
        HStack {
            Text(isFiltering
                 ? "\(visible.count) listing\(visible.count == 1 ? "" : "s")\(theme.map { " in \($0)" } ?? "")"
                 : "Everything listed")
                .font(.system(size: 12))
                .foregroundStyle(Brand.muted)
            Spacer()
            if isFiltering {
                Button("Clear filters") {
                    query = ""; theme = nil; type = nil; condition = nil
                }
                .font(.system(size: 12, weight: .semibold))
                .tint(Brand.ink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "Everything", isSelected: type == nil) { type = nil }
                    ForEach(ListingType.allCases) { t in
                        Chip(title: t.label, isSelected: type == t) { type = t }
                    }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "Any condition", isSelected: condition == nil, accent: Brand.yellow) { condition = nil }
                    ForEach(Condition.allCases) { c in
                        Chip(title: c.rawValue, isSelected: condition == c, accent: Brand.yellow) { condition = c }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }

    private var themeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)], spacing: 10) {
            ForEach(Catalog.themes, id: \.self) { name in
                ThemeBrick(name: name,
                           listingCount: listings.filter { $0.theme == name }.count) {
                    theme = name
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(loadError == nil ? "Nobody has listed this yet" : "Can't reach Brick Souq")
                .font(.system(size: 17, weight: .bold))
            Text(loadError ?? "Put it on your wanted list — it's in the You tab — and you'll be notified the moment it appears.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
            if loadError != nil {
                Button("Try again") { Task { await load() } }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            listings = try await BackendClient.shared.listings(
                theme: theme, type: type, condition: condition,
                query: query.isEmpty ? nil : query
            )
            loadError = nil
        } catch {
            listings = []
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Cards

struct ListingCard: View {
    let listing: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ListingImageView(image: listing.cardImage, theme: listing.theme, height: 132)

                // The condition badge as a little 2-stud tile sitting on the artwork.
                VStack(spacing: 0) {
                    StudCaps(count: 2, color: .white.opacity(0.95), studWidth: 9, studHeight: 4)
                    Text(listing.condition.rawValue)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3.5)
                        .background(.white.opacity(0.95))
                        .clipShape(BrickFace(cornerRadius: 4))
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(listing.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let number = listing.setNumber {
                        Text(number)
                            .font(.setNumber(11.5))
                            .foregroundStyle(Brand.muted)
                    }
                }
                Text(listing.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Brand.muted)

                if let completeness = listing.completeness {
                    StudMeter(filled: completeness, showLabel: true).padding(.top, 6)
                }

                Divider().padding(.vertical, 8)

                HStack {
                    PriceLabel(amount: listing.priceQAR)
                    Spacer()
                    Text(listing.createdAt, format: .relative(presentation: .numeric))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
            }
            .padding(11)
        }
        .background(Brand.card)
        .clipShape(BrickFace(cornerRadius: 10))
        .overlay(BrickFace(cornerRadius: 10).stroke(Brand.line, lineWidth: 1))
    }
}

struct SetSuggestionRow: View {
    let set: BrickSet
    let listedCount: Int

    var body: some View {
        HStack(spacing: 11) {
            BrickArt(seed: Catalog.themeSeed(set.theme), height: 40)
                .frame(width: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(set.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text("\(set.id) · \(set.theme)")
                    .font(.setNumber(11.5))
                    .foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 4)

            Text(listedCount > 0 ? "\(listedCount) listed" : "None listed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(listedCount > 0 ? Brand.ink : Brand.muted)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(listedCount > 0 ? Brand.yellow : Brand.lineSoft))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

struct PriceLabel: View {
    let amount: Int
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 2) {
            Text("QAR").font(.setNumber(size * 0.66)).foregroundStyle(Brand.muted)
            Text(amount.formatted()).font(.priceValue(size)).foregroundStyle(Brand.ink)
        }
    }
}

// MARK: - Detail

struct ListingDetailView: View {
    let listing: Listing
    let currentUser: User

    @EnvironmentObject private var blockList: BlockList
    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var showBlockConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhotoCarousel(listing: listing, height: 260)

                VStack(alignment: .leading, spacing: 16) {
                    Text(listing.title)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Brand.ink)

                    if let number = listing.setNumber, let set = Catalog.shared.set(number) {
                        Text("\(number) · \(set.theme) · \(set.pieces.formatted()) pieces")
                            .font(.setNumber(13))
                            .foregroundStyle(Brand.muted)
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        PriceLabel(amount: listing.priceQAR, size: 30)
                        if let number = listing.setNumber, let set = Catalog.shared.set(number) {
                            let delta = Int((Double(listing.priceQAR) / Double(set.retailQAR) - 1) * 100)
                            Text("\(delta > 0 ? "+" : "")\(delta)% vs. retail")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.muted)
                        }
                    }

                    conditionCard
                    sellerCard

                    Text(listing.note)
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.ink)

                    whatsAppButton

                    moderationControls
                }
                .padding(16)
            }
        }
        .background(Brand.page)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showReport) {
            ReportSheet(listing: listing, reporterID: currentUser.id)
        }
        .confirmationDialog("Block \(listing.sellerName)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task {
                    await blockList.block(listing.sellerID)
                    dismiss()
                }
            }
        } message: {
            Text("You won't see their listings again and they won't be able to contact you here.")
        }
    }

    private var conditionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: listing.condition.rawValue)
            Text(listing.condition.blurb)
                .font(.system(size: 14))
                .foregroundStyle(Brand.ink)

            if let completeness = listing.completeness {
                Divider().padding(.vertical, 4)
                SectionLabel(text: "Completeness")
                StudMeter(filled: completeness, size: 13)
                Text(completeness == 8
                     ? "Seller confirms every piece is present against the official inventory."
                     : "Seller reports missing pieces. Details are in their note.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.ink)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.yellowSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var sellerCard: some View {
        HStack(spacing: 11) {
            Circle().fill(Brand.yellow).frame(width: 38, height: 38)
                .overlay(Text(String(listing.sellerName.prefix(1))).font(.system(size: 15, weight: .heavy)))
            VStack(alignment: .leading, spacing: 1) {
                Text(listing.sellerName).font(.system(size: 14, weight: .semibold))
                Text("\(listing.sellerTrades) completed trades")
                    .font(.system(size: 11.5)).foregroundStyle(Brand.muted)
            }
            Spacer()
        }
        .padding(12)
        .background(Brand.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var whatsAppButton: some View {
        VStack(spacing: 10) {
            Button {
                if let url = listing.whatsAppURL { UIApplication.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.fill")
                    Text("Message \(listing.sellerName) on WhatsApp")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 9).fill(Brand.whatsApp))
            }
            .buttonStyle(.plain)

            Text("Brick Souq doesn't handle money. Meet somewhere public, check the set, then pay.")
                .font(.system(size: 11.5))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
        }
    }

    /// Guideline 1.2 requires both of these to be reachable from the content itself.
    private var moderationControls: some View {
        HStack(spacing: 20) {
            Button("Report listing") { showReport = true }
            Button("Block \(listing.sellerName)") { showBlockConfirm = true }
            Spacer()
        }
        .font(.system(size: 13))
        .tint(Brand.muted)
        .padding(.top, 8)
    }
}

//bypass

