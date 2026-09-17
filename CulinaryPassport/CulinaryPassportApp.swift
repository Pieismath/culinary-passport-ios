import SwiftUI

@main
struct CulinaryPassportApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    @State private var showPasswordReset = false

    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                SwiftUI.Group {
                    if session.isSignedIn || session.uiPreview {
                        RootView()
                            .environment(session)
                    } else {
                        SignInView()
                            .environment(session)
                    }
                }
                // Brand moment on every cold launch: the system launch frame is
                // already this green (UILaunchScreen), the name pops, then the
                // app fades in underneath. Total ~1.2s.
                if showSplash {
                    SplashView()
                        .zIndex(1)
                        .transition(.opacity)
                        .task {
                            // Long enough for the wordmark to land, short enough
                            // not to tax every cold launch.
                            try? await Task.sleep(for: .milliseconds(450))
                            withAnimation(.easeOut(duration: 0.25)) { showSplash = false }
                        }
                }
            }
            // The password-reset email links back here; the SDK turns the URL
            // into a recovery session, after which the user sets a new password.
            // Only that link: an OAuth callback also yields a session, and
            // must not pop a "set a new password" sheet.
            .onOpenURL { url in
                guard url.host == "reset-password" else { return }
                Task {
                    if (try? await SupabaseService.shared.client.auth.session(from: url)) != nil {
                        showPasswordReset = true
                    }
                }
            }
            .sheet(isPresented: $showPasswordReset) {
                NewPasswordSheet()
            }
        }
    }
}

/// Auth state observable — wraps Supabase auth session.
@Observable
final class SessionStore {
    var isSignedIn = false
    /// Debug-only: browse the tab shell without a backend (data calls fail gracefully).
    /// Toggled by the sign-in screen button or the `-uiPreview` launch argument.
    var uiPreview = ProcessInfo.processInfo.arguments.contains("-uiPreview")

    init() {
        Task { await observeAuth() }
        #if DEBUG
        // Headless test hook: launch with `-email x -password y` to sign in automatically.
        let args = ProcessInfo.processInfo.arguments
        if let e = args.firstIndex(of: "-email"), e + 1 < args.count,
           let p = args.firstIndex(of: "-password"), p + 1 < args.count {
            Task {
                try? await SupabaseService.shared.client.auth.signIn(
                    email: args[e + 1], password: args[p + 1])
            }
        }
        #endif
    }

    @MainActor
    private func observeAuth() async {
        for await state in SupabaseService.shared.client.auth.authStateChanges {
            if state.event == .signedOut { DiskCache.clear() }
            if state.event == .signedIn { SupabaseService.shared.logEvent("app_open") }
            isSignedIn = state.session != nil
            // .initialSession can carry an expired session (offline relaunch):
            // still show the app — autoRefresh replaces it (tokenRefreshed) or
            // ends it (signedOut) — but hold side effects until it's valid.
            // Notification permission is never requested here: a cold prompt
            // at sign-in (for pushes that don't exist yet) burns the one ask.
            // It's requested in context; this only refreshes an existing grant.
            let sessionIsValid = state.session.map { !$0.isExpired } ?? false
            if sessionIsValid && state.event != .tokenRefreshed {
                PushRegistrar.registerIfAuthorized()
            }
        }
    }
}

/// The green flash card at cold launch: "Stampd" pops in over brand green.
private struct SplashView: View {
    @State private var popped = false

    var body: some View {
        ZStack {
            Color("BrandGreen").ignoresSafeArea()
            Text("Stampd")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(Color("BrandCream"))
                .scaleEffect(popped ? 1 : 0.72)
                .opacity(popped ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { popped = true }
        }
    }
}

// SignInView moved to Views/SignInView.swift (social-first sign-in).

/// Shown after a password-reset deep link lands (recovery session active).
struct NewPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Repeat it", text: $confirm)
                } footer: {
                    Text("At least 8 characters.")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Set a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(password.count < 8 || password != confirm || busy)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await SupabaseService.shared.updatePassword(password)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
