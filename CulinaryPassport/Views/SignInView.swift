import SwiftUI
import AuthenticationServices

/// Sign-in leads with one-tap social (Apple + Google, Beli-style); email/password
/// is a collapsed fallback. ROADMAP item 1.
struct SignInView: View {
    @Environment(SessionStore.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var showEmail = false
    @State private var showLegal = false
    @State private var busy = false
    @State private var appleRawNonce = ""

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 6) {
                    Text("Stampd")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Color("BrandGreen"))
                    Text("Fill the globe, one cuisine at a time.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()

            // Primary: Sign in with Apple (native).
            SignInWithAppleButton(.continue) { request in
                appleRawNonce = SocialAuth.randomNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = SocialAuth.sha256(appleRawNonce)
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(Capsule())

            // Primary: Continue with Google (web OAuth).
            Button {
                Task { await continueWithGoogle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text("Continue with Google").fontWeight(.medium)
                }
                .frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .clipShape(Capsule())
            .disabled(busy)

            // Fallback: email / password.
            Button(showEmail ? "Hide email sign-in" : "Use email instead") {
                withAnimation { showEmail.toggle() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)

            if showEmail {
                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Sign in") { Task { await emailSignIn(create: false) } }
                            .buttonStyle(.borderedProminent)
                        Button("Create account") { Task { await emailSignIn(create: true) } }
                            .buttonStyle(.bordered)
                    }
                    Button("Forgot password?") { Task { await forgotPassword() } }
                        .font(.footnote)
                        .disabled(email.isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }

            #if DEBUG
            Button("UI preview (no backend)") { session.uiPreview = true }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            #endif
            Spacer()

            HStack(spacing: 4) {
                Text("By continuing you agree to the")
                Button("terms & privacy policy") { showLegal = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption2)
            .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(32)
        .sheet(isPresented: $showLegal) {
            NavigationStack { LegalView() }
        }
    }

    // MARK: Actions

    private func continueWithGoogle() async {
        busy = true; defer { busy = false }
        do { try await SocialAuth.google() }
        catch { self.error = friendly(error) }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                error = "Apple sign-in didn't return a token."
                return
            }
            Task {
                do { try await SocialAuth.apple(idToken: idToken, rawNonce: appleRawNonce) }
                catch { self.error = friendly(error) }
            }
        case .failure(let err):
            // Swallow user-cancellation; surface everything else.
            if (err as? ASAuthorizationError)?.code != .canceled {
                error = err.localizedDescription
            }
        }
    }

    private func forgotPassword() async {
        do {
            try await SupabaseService.shared.requestPasswordReset(email: email)
            notice = "Reset link sent — check \(email). Opening it brings you back here to set a new password."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func emailSignIn(create: Bool) async {
        busy = true; defer { busy = false }
        do {
            if create {
                try await SupabaseService.shared.client.auth.signUp(email: email, password: password)
            } else {
                try await SupabaseService.shared.client.auth.signIn(email: email, password: password)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func friendly(_ error: Error) -> String {
        error.localizedDescription
    }
}
