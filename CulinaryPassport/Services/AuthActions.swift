import Foundation
import CryptoKit
import Supabase

/// Social sign-in helpers (ROADMAP item 1). Google works today via Supabase's
/// Google provider (web OAuth over ASWebAuthenticationSession). Apple uses the
/// native Sign in with Apple credential → Supabase id-token sign-in; the code
/// path is ready but only works once the app has the Sign in with Apple
/// capability (paid Apple Developer account required).
enum SocialAuth {
    /// Deep-link the OAuth callback returns to. Must be registered in
    /// project.yml (CFBundleURLTypes) AND in Supabase Auth's redirect allow-list.
    static let redirectURL = URL(string: "culinarypassport://login-callback")!

    /// Google: presents the provider's web flow and completes the session.
    static func google() async throws {
        try await SupabaseService.shared.client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: redirectURL
        )
    }

    /// Apple: exchange the native identity token for a Supabase session.
    static func apple(idToken: String, rawNonce: String) async throws {
        try await SupabaseService.shared.client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
    }

    // MARK: Nonce (Sign in with Apple replay protection)

    /// A random nonce; the raw value is kept and its SHA-256 is sent in the
    /// Apple request, then the raw value is handed to Supabase for verification.
    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        for byte in bytes { result.append(charset[Int(byte) % charset.count]) }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
