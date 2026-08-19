import SwiftUI

// MARK: - Sell

struct SellView: View {
    let currentUser: User

    @State private var query = ""
    @State private var chosenSet: BrickSet?
    @State private var noSetType: ListingType?
    @State private var condition: Condition = .built
    @State private var completeness = 8
    @State private var priceText = ""
    @State private var phone = ""
    @State private var note = ""
    @State private var showTerms = false
    @State private var isPublishing = false
    @State private var published = false
    @State private var filterMessage: String?
    @State private var publishError: String?
    @State private var photos: [PendingPhoto] = []

    private var suggestedPrice: Int {
        guard let set = chosenSet else { return 0 }
        let completenessAdjustment = completeness == 8 ? 1.0 : 0.72 + Double(completeness) * 0.035
        let raw = Double(set.retailQAR) * condition.priceMultiplier * completenessAdjustment
        return Int((raw / 5).rounded()) * 5
    }

    private var canPublish: Bool {
        (chosenSet != nil || noSetType != nil)
        && !priceText.isEmpty
        && phone.filter(\.isNumber).count >= 8
        && !note.trimmingCharacters(in: .whitespaces).isEmpty
        && PhotoRules.shortfall(count: photos.count, condition: condition) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if published {
                    Section {
                        Text("Listing is live. Buyers watching this theme have been notified and will reach you on WhatsApp.")
                        Button("List something else") { reset() }
                    }
                } else {
                    setSection
                    if chosenSet != nil || noSetType != nil {
                        conditionSection
                        photoSection
                        detailsSection
                        publishSection
                    }
                }
            }
            .navigationTitle("Sell")
            .sheet(isPresented: $showTerms) {
                TermsGate { publish() }
            }
            .alert("Listing held", isPresented: .constant(filterMessage != nil)) {
                Button("OK") { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
            .alert("Couldn't publish", isPresented: .constant(publishError != nil)) {
                Button("OK") { publishError = nil }
            } message: {
                Text(publishError ?? "")
            }
        }
    }

    private var setSection: some View {
        Section {
            if let set = chosenSet {
                HStack(spacing: 11) {
                    BrickArt(seed: Catalog.themeSeed(set.theme), height: 44)
                        .frame(width: 44).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name).font(.system(size: 15, weight: .semibold))
                        Text("\(set.id) · \(set.theme) · \(set.pieces.formatted()) pcs")
                            .font(.setNumber(11.5)).foregroundStyle(Brand.muted)
                    }
                }
                Button("Not this one — search again") {
                    chosenSet = nil; query = ""
                }
                .font(.system(size: 13))

            } else if let type = noSetType {
                Text(type.label).font(.system(size: 15, weight: .semibold))
                Button("Choose something else") { noSetType = nil }
                    .font(.system(size: 13))

            } else {
                TextField("Set name or number — try \"castle\"", text: $query)
                    .autocorrectionDisabled()

                ForEach(Catalog.shared.search(query, limit: 5)) { set in
                    Button {
                        chosenSet = set
                        priceText = ""
                    } label: {
                        SetSuggestionRow(set: set, listedCount: 0)
                    }
                    .buttonStyle(.plain)
                }

                if query.isEmpty {
                    Picker("No set number?", selection: $noSetType) {
                        Text("Choose").tag(ListingType?.none)
                        Text("Bulk bricks").tag(ListingType?.some(.bulk))
                        Text("Minifigures").tag(ListingType?.some(.minifigures))
                        Text("Parts").tag(ListingType?.some(.parts))
                    }
                }
            }
        } header: {
            Text("What are you selling?")
        } footer: {
            if chosenSet == nil && noSetType == nil {
                Text("Type the name or the number from the box corner. Most people don't know the number — the name works fine.")
            }
        }
    }

    private var conditionSection: some View {
        Section("Condition") {
            Picker("Condition", selection: $condition) {
                ForEach(Condition.allCases) { c in
                    VStack(alignment: .leading) {
                        Text(c.rawValue)
                        Text(c.blurb).font(.caption).foregroundStyle(.secondary)
                    }.tag(c)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if chosenSet != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Completeness").font(.system(size: 14, weight: .medium))
                    HStack(spacing: 7) {
                        ForEach(1...8, id: \.self) { index in
                            Button {
                                completeness = index
                            } label: {
                                Circle()
                                    .fill(index <= completeness ? Brand.yellow : Brand.studOff)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Set completeness to \(index) of 8")
                        }
                    }
                    Text(completeness == 8 ? "Every piece present"
                         : completeness >= 7 ? "A handful of pieces missing"
                         : completeness >= 5 ? "Noticeably incomplete" : "Partial set")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.muted)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var photoSection: some View {
        Section {
            PhotoPickerStrip(photos: $photos, condition: condition)
        } header: {
            Text("Photos")
        } footer: {
            Text(chosenSet != nil
                 ? "The set's catalogue picture is shown first automatically. Your photos show what buyers are actually getting."
                 : "Photos of the actual items. Bulk lots sell on how they look in the box.")
        }
    }

    private var detailsSection: some View {
        Section {
            if chosenSet != nil {
                LabeledContent("Suggested price", value: "QAR \(suggestedPrice.formatted())")
            }
            TextField("Price in QAR", text: $priceText).keyboardType(.numberPad)
            TextField("+974 WhatsApp number", text: $phone).keyboardType(.phonePad)
            TextField("Describe it honestly — missing pieces, box condition, why you're selling",
                      text: $note, axis: .vertical)
                .lineLimit(3...7)
        } header: {
            Text("Price and contact")
        } footer: {
            Text("Buyers tap through to WhatsApp with the set already written into the message. Your number stays hidden until someone opens the chat.")
        }
    }

    private var publishSection: some View {
        Section {
            Button(isPublishing ? "Publishing…" : "Publish listing") {
                if TermsGate.hasAccepted { publish() } else { showTerms = true }
            }
            .disabled(!canPublish || isPublishing)
        }
    }

    private func publish() {
        // Screen before publishing, not after. Guideline 1.2 requires "a method for
        // refusing to publish objectionable content" — moderating after the fact
        // doesn't satisfy it.
        switch ContentFilter.evaluate(note: note, title: chosenSet?.name ?? noSetType?.label ?? "") {
        case .reject(let message):
            filterMessage = message
            return
        case .review(let message):
            filterMessage = message
        case .allow:
            break
        }

        isPublishing = true
        Task {
            let listing = Listing(
                id: UUID().uuidString,
                sellerID: currentUser.id,
                sellerName: currentUser.displayName ?? "Seller",
                sellerTrades: currentUser.completedTrades,
                type: chosenSet != nil ? .set : (noSetType ?? .bulk),
                setNumber: chosenSet?.id,
                theme: chosenSet?.theme ?? "Mixed",
                title: chosenSet?.name ?? (noSetType?.label ?? "Bulk lot"),
                condition: condition,
                completeness: chosenSet != nil ? completeness : nil,
                includesInstructions: chosenSet != nil,
                boxCondition: nil,
                priceQAR: Int(priceText) ?? 0,
                note: note,
                photoURLs: photos.map(\.path),
                whatsAppNumber: phone,
                createdAt: .now
            )
            do {
                _ = try await BackendClient.shared.publish(listing)
                published = true
            } catch {
                // The server runs the same content check and can refuse outright, and
                // it may simply be unreachable. Either way, saying "Listing is live"
                // when nothing was published is the one thing not to do.
                publishError = error.localizedDescription
            }
            isPublishing = false
        }
    }

    private func reset() {
        published = false; chosenSet = nil; noSetType = nil
        query = ""; priceText = ""; note = ""; completeness = 8
        // Photos belong to the listing that was just published; the server refuses to
        // reuse them, so starting fresh is the only correct thing here.
        photos = []
    }
}

// MARK: - Wanted

struct WantedView: View {
    @State private var items: [WantedItem] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                if items.isEmpty && !isLoading {
                    Text("Nothing on your list yet. Search for a set and add it — sellers can see that buyers are waiting.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.muted)
                }
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        // A single stud, to mark the row as a thing you are watching.
                        Circle().fill(Brand.yellow).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(itemTitle(item)).font(.system(size: 15, weight: .semibold))
                            if let max = item.maxPriceQAR {
                                Text("up to QAR \(max.formatted())")
                                    .font(.setNumber(11.5)).foregroundStyle(Brand.muted)
                            }
                        }
                        Spacer()
                        Text("Watching").font(.system(size: 12)).foregroundStyle(Brand.muted)
                    }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { items[$0].id }
                    items.remove(atOffsets: indexSet)
                    Task { for id in ids { try? await BackendClient.shared.removeWanted(id: id) } }
                }
            } header: {
                Text("Sets you're hunting")
            } footer: {
                Text("A small market has thin supply. Wanted lists let demand build up while inventory is scarce, and give sellers proof that buyers exist before they bother listing.")
            }
        }
        .navigationTitle("Wanted")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            items = (try? await BackendClient.shared.wanted()) ?? []
            isLoading = false
        }
    }

    private func itemTitle(_ item: WantedItem) -> String {
        if let number = item.setNumber, let set = Catalog.shared.set(number) { return set.name }
        return item.theme ?? "Any set"
    }
}

// MARK: - Profile

struct ProfileView: View {
    let user: User
    @EnvironmentObject private var auth: AuthManager

    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var wantedCount: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 13) {
                        Circle().fill(Brand.yellow).frame(width: 54, height: 54)
                            .overlay(Text(user.initial).font(.system(size: 21, weight: .heavy)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName ?? "Brick Souq member")
                                .font(.system(size: 19, weight: .bold))
                            Text("\(user.completedTrades) completed trades")
                                .font(.system(size: 12.5)).foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    NavigationLink {
                        WantedView()
                    } label: {
                        HStack(spacing: 11) {
                            StudCaps(count: 2, color: Brand.yellow, studWidth: 9, studHeight: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Wanted").font(.system(size: 15, weight: .semibold))
                                Text(wantedCount == nil ? "Sets you're hunting"
                                     : wantedCount == 0 ? "Nothing on your list yet"
                                     : "\(wantedCount!) set\(wantedCount! == 1 ? "" : "s") you're hunting")
                                    .font(.system(size: 12)).foregroundStyle(Brand.muted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Watching")
                } footer: {
                    Text("You'll be notified when something on this list is posted.")
                }

                Section("My listings") {
                    NavigationLink("Active listings") { Text("Your listings") }
                    NavigationLink("Sold") { Text("Sold listings") }
                }

                Section {
                    Link("Privacy Policy", destination: URL(string: "https://bricksouq.qa/privacy")!)
                    Link("Terms of Use", destination: URL(string: "https://bricksouq.qa/terms")!)
                    Link("Contact support", destination: URL(string: "mailto:support@bricksouq.qa")!)
                    NavigationLink("Blocked users") { Text("Blocked users") }
                } header: {
                    Text("Safety and support")
                } footer: {
                    // Guideline 1.2 requires published contact info reachable in-app.
                    Text("We act on reports within 24 hours. Reach us any time at support@bricksouq.qa.")
                }

                Section {
                    Button("Sign out") { auth.signOut() }
                    Button("Delete account", role: .destructive) { showDeleteConfirm = true }
                        .disabled(isDeleting)
                } footer: {
                    Text("Deleting removes your account, your listings and your Apple sign-in connection. It can't be undone.")
                }
            }
            .navigationTitle("You")
            .task { wantedCount = (try? await BackendClient.shared.wanted())?.count }
            .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    isDeleting = true
                    Task {
                        try? await auth.deleteAccount()
                        isDeleting = false
                    }
                }
            } message: {
                Text("Your listings and trade history will be removed. This can't be undone.")
            }
        }
    }
}
