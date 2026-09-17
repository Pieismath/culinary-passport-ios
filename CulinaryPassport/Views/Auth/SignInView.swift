import SwiftUI
import AuthenticationServices

/// One-tap social sign-in first (Apple, Google); email is a sheet behind it.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var appleRawNonce = ""
    @State private var showEmail = false
    @State private var showLegal = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 18) {
                ZStack {
                    ForEach(Array(["JP", "IS", "PE", "IT"].enumerated()), id: \.offset) { index, code in
                        StampBadge(code: code, size: 92)
                            .offset(x: [-96, 98, -70, 84][index], y: [-54, -40, 70, 76][index])
                            .opacity(0.5)
                    }
                    Image("BrandMark")
                        .resizable()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                }
                .frame(height: 220)
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Stampd")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.brand)
                    Text("Your travel passport.")
                        .font(.display)
                        .foregroundStyle(Color.ink)
                    Text("Stamp every country you visit, keep the photos on your globe, and see where your friends have been.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }

            Spacer(minLength: 20)

            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    appleRawNonce = SocialAuth.randomNonce()
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = SocialAuth.sha256(appleRawNonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(Capsule())

                Button {
                    Task { await continueWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        Text("G")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.brand)
                        Text("Continue with Google")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(busy)

                Button("Continue with email") { showEmail = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.brand)
                    .padding(.top, 2)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.danger)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                #if DEBUG
                Button("Explore with demo data") { app.enterDemo() }
                    .font(.footnote)
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.top, 4)
                #endif

                Button { showLegal = true } label: {
                    Text("By continuing you agree to the \(Text("Terms & Privacy Policy").underline())")
                        .font(.caption)
                        .foregroundStyle(Color.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .paperBackground()
        .sheet(isPresented: $showEmail) { EmailAuthSheet() }
        .sheet(isPresented: $showLegal) { NavigationStack { LegalView() } }
    }

    private func continueWithGoogle() async {
        busy = true
        defer { busy = false }
        do {
            try await SocialAuth.google()
            error = nil
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            self.error = AppError.friendly(error)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                error = "Apple sign-in didn't return a token. Try again."
                return
            }
            Task {
                do {
                    try await SocialAuth.apple(idToken: idToken, rawNonce: appleRawNonce)
                    error = nil
                } catch {
                    self.error = AppError.friendly(error)
                }
            }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled {
                error = "Apple sign-in isn't available right now. Try Google or email."
            }
        }
    }
}

/// Email sign-in / sign-up with the feedback the old inline form lacked.
struct EmailAuthSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case create = "Create account"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @FocusState private var focus: Field?

    enum Field { case email, password }

    private var emailLooksValid: Bool {
        let e = email.trimmed
        return e.contains("@") && e.contains(".") && e.count >= 5
    }

    private var canSubmit: Bool {
        emailLooksValid && password.count >= (mode == .create ? 8 : 1) && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Clearing messages in the binding (not onChange) so the
                    // post-signup notice survives the switch to Sign in.
                    Picker("Mode", selection: Binding(get: { mode }, set: {
                        mode = $0
                        error = nil
                        notice = nil
                    })) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField(mode == .create ? "Password (8+ characters)" : "Password", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error { Text(error).foregroundStyle(Color.danger) }
                        if let notice { Text(notice).foregroundStyle(Color.brand) }
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(busy ? "One moment…" : mode.rawValue)
                    }
                    .buttonStyle(.primary)
                    .disabled(!canSubmit)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if mode == .signIn {
                        Button("Forgot password?") { Task { await forgot() } }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .disabled(!emailLooksValid || busy)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .paperListStyle()
            .navigationTitle("Continue with email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focus = .email }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        guard canSubmit else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        let auth = SupabaseBackend.shared.client.auth
        do {
            switch mode {
            case .signIn:
                try await auth.signIn(email: email.trimmed, password: password)
                dismiss()
            case .create:
                let response = try await auth.signUp(email: email.trimmed, password: password)
                if response.session == nil {
                    // Email confirmation is on: without this, "Create account"
                    // looked like it did nothing.
                    notice = "Almost there — check \(email.trimmed) for a confirmation link, then sign in."
                    mode = .signIn
                    password = ""
                } else {
                    dismiss()
                }
            }
        } catch {
            self.error = AppError.friendly(error)
        }
    }

    private func forgot() async {
        busy = true
        defer { busy = false }
        do {
            try await SupabaseBackend.shared.requestPasswordReset(email: email.trimmed)
            error = nil
            notice = "Reset link sent to \(email.trimmed). Opening it brings you back here."
        } catch {
            self.error = AppError.friendly(error)
        }
    }
}
