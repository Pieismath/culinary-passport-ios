import SwiftUI

@main
struct CulinaryPassportApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            if session.isSignedIn || session.uiPreview {
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
        // -noPush: headless test runs can't tap the OS permission dialog
        let skipPush = ProcessInfo.processInfo.arguments.contains("-noPush")
        for await state in SupabaseService.shared.client.auth.authStateChanges {
            isSignedIn = state.session != nil
            // .initialSession can now carry an expired session (offline
            // relaunch): still show the app — autoRefresh will replace it
            // (tokenRefreshed) or end it (signedOut) — but hold side effects
            // like the push permission prompt until the session is valid.
            let sessionIsValid = state.session.map { !$0.isExpired } ?? false
            if sessionIsValid && !skipPush { PushRegistrar.requestAndRegister() }
        }
    }
}

// SignInView moved to Views/SignInView.swift (social-first sign-in).
