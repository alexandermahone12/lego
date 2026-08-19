import Combine
import SwiftUI

/// Guideline 1.2 compliance.
///
/// This is the most common reason marketplace apps get rejected, and people usually
/// discover it after they've already built everything else. Apple requires ALL of:
///
///   1. A EULA with an explicit zero-tolerance clause, accepted before posting
///   2. Automated filtering that refuses to publish objectionable content
///   3. A report control on every piece of user content
///   4. A block control on every user
///   5. Published contact info reachable from inside the app
///   6. Action on reports within 24 hours — a real human commitment, not code
///
/// Point the reviewer at each of these in your App Review notes with navigation steps.
/// Reviewers reject when they can't find the controls, not only when they're absent.

// MARK: - Content filter

enum ContentFilter {
    /// Refuses obviously bad listings before they're published. Deliberately narrow —
    /// broad keyword blocking produces false positives that infuriate real sellers.
    /// Anything ambiguous goes to the manual queue instead of being blocked outright.
    ///
    /// Layer a real moderation API on top of this before launch. Apple accepts
    /// automated pre-screening plus human review; it does not accept nothing.
    static func evaluate(note: String, title: String) -> Verdict {
        let text = "\(title) \(note)".lowercased()

        if profanity.contains(where: text.contains) {
            return .reject("Listings can't contain offensive language.")
        }
        if offPlatform.contains(where: text.contains) {
            return .reject("Keep contact details out of the description — buyers reach you through the WhatsApp button.")
        }
        if counterfeitSignals.contains(where: text.contains) {
            return .review("This looks like it may not be genuine LEGO. We'll check it before it goes live.")
        }
        return .allow
    }

    enum Verdict: Equatable {
        case allow
        case review(String)     // publish held pending human check
        case reject(String)     // never published
    }

    private static let profanity: [String] = [
        // Populate from a maintained list; keep it in a config file you can update
        // without shipping a build. Include Arabic terms — an English-only filter on
        // a Qatar app is not a filter.
    ]

    private static let offPlatform: [String] = [
        "instagram.com", "snapchat", "@gmail", "@hotmail"
    ]

    private static let counterfeitSignals: [String] = [
        "lepin", "compatible bricks", "not original", "replica set", "knockoff"
    ]
}

// MARK: - Report sheet

struct ReportSheet: View {
    let listing: Listing
    let reporterID: String
    @Environment(\.dismiss) private var dismiss

    @State private var reason: Report.Reason = .counterfeit
    @State private var detail = ""
    @State private var isSending = false
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Text("Report received. We review every report within 24 hours and will remove the listing if it breaks the rules.")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.muted)
                    }
                } else {
                    Section("Why are you reporting this?") {
                        Picker("Reason", selection: $reason) {
                            ForEach(Report.Reason.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section("Anything else we should know?") {
                        TextField("Optional", text: $detail, axis: .vertical)
                            .lineLimit(3...6)
                    }

                    Section {
                        Button("Send report") { send() }
                            .disabled(isSending)
                    }
                }
            }
            .navigationTitle("Report listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            let report = Report(
                id: UUID().uuidString,
                listingID: listing.id,
                reporterID: reporterID,
                reason: reason,
                detail: detail.isEmpty ? nil : detail,
                createdAt: .now
            )
            try? await BackendClient.shared.report(report)
            isSending = false
            sent = true
        }
    }
}

// MARK: - EULA gate

/// Shown once before a user can post. Apple specifically asks for terms that make
/// zero tolerance explicit — a generic privacy policy doesn't satisfy this.
struct TermsGate: View {
    @AppStorage("acceptedTermsVersion") private var acceptedVersion = 0
    static let currentVersion = 1

    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Before you post")
                        .font(.system(size: 24, weight: .bold))

                    Group {
                        rule("Genuine LEGO only.",
                             "Clone brands and counterfeit sets are removed and the seller is banned.")
                        rule("Describe condition honestly.",
                             "If pieces are missing, say how many. Overstating completeness is the fastest way to lose your account.")
                        rule("No offensive or abusive content.",
                             "Zero tolerance. Listings, notes and messages that harass or offend get the account removed immediately, without warning.")
                        rule("Deals happen off the app.",
                             "Brick Souq doesn't hold money or guarantee any transaction. Meet somewhere public and check the set before you pay.")
                        rule("Reports are acted on within 24 hours.",
                             "Anyone can report a listing. We remove content that breaks these rules and eject the person who posted it.")
                    }

                    Text("Questions or problems: support@bricksouq.qa")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "I agree") {
                    acceptedVersion = Self.currentVersion
                    onAccept()
                    dismiss()
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }

    private func rule(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(Brand.muted)
        }
    }

    static var hasAccepted: Bool {
        UserDefaults.standard.integer(forKey: "acceptedTermsVersion") >= currentVersion
    }
}

// MARK: - Block

@MainActor
final class BlockList: ObservableObject {
    @Published private(set) var blocked: Set<String> = []

    func refresh() async {
        blocked = (try? await BackendClient.shared.blockedUserIDs()) ?? []
    }

    func block(_ userID: String) async {
        try? await BackendClient.shared.block(userID: userID)
        blocked.insert(userID)
    }

    func isBlocked(_ userID: String) -> Bool { blocked.contains(userID) }
}
