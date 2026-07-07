import SwiftUI

@main
struct CulinaryPassportApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            if session.isSignedIn {
                RootView()
                    .environment(session)
            } else {
                SignInView()
                    .environment(session)
            }
        }
    }
}

/// Auth state observable — wraps Supabase auth session.
@Observable
final class SessionStore {
    var isSignedIn = false

    init() {
        Task { await observeAuth() }
    }

    @MainActor
    private func observeAuth() async {
        for await state in SupabaseService.shared.client.auth.authStateChanges {
            isSignedIn = state.session != nil
        }
    }
}

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Culinary Passport")
                .font(.system(.largeTitle, design: .serif)).italic()
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Sign in") {
                Task {
                    do {
                        try await SupabaseService.shared.client.auth.signIn(email: email, password: password)
                    } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(.borderedProminent)
            // TODO(MVP-1): Sign in with Apple
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(32)
    }
}
