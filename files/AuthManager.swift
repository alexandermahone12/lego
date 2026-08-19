import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

/// Sign in with Apple.
///
/// Two things trip people up here:
///  1. Apple returns the user's name and email ONLY on the very first authorization.
///     Never again, on any device. If you don't persist them immediately they're gone,
///     and the only way to see them again is for the user to remove the app from
///     Settings > Apple ID > Sign in with Apple, which they will not do.
///  2. If you offer account deletion (Apple requires it — Guideline 5.1.1(v)) you must
///     also revoke the Apple token server-side. Deleting your own database row is not
///     enough and reviewers do check.
@MainActor
final class AuthManager: ObservableObject {

    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(User)
    }

    @Published private(set) var state: State = .unknown
    @Published var errorMessage: String?

    private let keychain = KeychainStore(service: "qa.bricksouq.auth")
    private var currentNonce: String?

    // MARK: - Lifecycle

    /// Call on launch. Apple's credential can be revoked from the user's device settings
    /// at any time, so a stored session is not proof of a valid one.
    func restoreSession() async {
        guard let userID = keychain.string(for: "userIdentifier") else {
            state = .signedOut
            return
        }

        let provider = ASAuthorizationAppleIDProvider()
        do {
            let credentialState = try await provider.credentialState(forUserID: userID)
            switch credentialState {
            case .authorized:
                if let user = loadCachedUser() {
                    state = .signedIn(user)
                } else {
                    state = .signedIn(User(id: userID, displayName: nil, email: nil))
                }
            case .revoked, .notFound:
                clearLocalSession()
                state = .signedOut
            default:
                state = .signedOut
            }
        } catch {
            state = .signedOut
        }
    }

    // MARK: - Sign in

    /// Configure the request. Attach this to `SignInWithAppleButton(onRequest:)`.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Handle the result. Attach to `SignInWithAppleButton(onCompletion:)`.
    func handle(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            // User cancelling is not an error worth surfacing.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = "Sign in didn't complete. Try again."

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                errorMessage = "Sign in didn't complete. Try again."
                return
            }

            let name = credential.fullName.flatMap { components -> String? in
                let formatter = PersonNameComponentsFormatter()
                formatter.style = .short
                let formatted = formatter.string(from: components).trimmingCharacters(in: .whitespaces)
                return formatted.isEmpty ? nil : formatted
            }

            // First authorization only — persist now or lose them.
            let user = User(
                id: credential.user,
                displayName: name ?? loadCachedUser()?.displayName,
                email: credential.email ?? loadCachedUser()?.email
            )

            do {
                // Exchange the identity token for your own session. The backend must
                // verify the token signature against Apple's public keys and check that
                // the nonce matches — otherwise anyone can forge a token and sign in as
                // anyone. Verifying on-device is not verification.
                let session = try await BackendClient.shared.signInWithApple(
                    identityToken: identityToken,
                    rawNonce: nonce,
                    authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                    displayName: user.displayName,
                    email: user.email
                )

                keychain.set(credential.user, for: "userIdentifier")
                keychain.set(session.accessToken, for: "accessToken")
                cache(user)
                currentNonce = nil
                state = .signedIn(user)

            } catch {
                errorMessage = "Couldn't reach Brick Souq. Check your connection and try again."
            }
        }
    }

    // MARK: - Sign out and delete

    func signOut() {
        clearLocalSession()
        state = .signedOut
    }

    /// Guideline 5.1.1(v): account deletion must be initiable in-app. Pointing users at
    /// an email address is an automatic rejection.
    func deleteAccount() async throws {
        try await BackendClient.shared.deleteAccount()
        clearLocalSession()
        state = .signedOut
    }

    // MARK: - Local persistence

    private func cache(_ user: User) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: "cachedUser")
        }
    }

    private func loadCachedUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: "cachedUser") else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func clearLocalSession() {
        keychain.delete("userIdentifier")
        keychain.delete("accessToken")
        UserDefaults.standard.removeObject(forKey: "cachedUser")
    }

    // MARK: - Nonce

    /// The nonce binds this sign-in attempt to this token, so a token intercepted from
    /// another session can't be replayed against yours.
    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Keychain

/// Tokens belong in the Keychain, not UserDefaults. UserDefaults is a plist any
/// backup or jailbroken device can read.
struct KeychainStore {
    let service: String

    func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        #if DEBUG
        // Worth saying out loud. If this fails the app keeps working until the first
        // request that needs a token, then reports an expired session — which sends you
        // looking at the server instead of at the Keychain. -34018 means the app is
        // missing the keychain-sharing entitlement.
        if status != errSecSuccess {
            print("[Keychain] failed to store \(key): OSStatus \(status)")
        }
        #endif
    }

    func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
