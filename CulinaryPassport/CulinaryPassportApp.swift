import SwiftUI
import UserNotifications

@main
struct StampdApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel(demo: ProcessInfo.processInfo.arguments.contains("-uiPreview"))
    @State private var showSplash = true
    @State private var showPasswordReset = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                SwiftUI.Group {
                    switch app.session {
                    case .unknown:
                        Color.paper.ignoresSafeArea()
                    case .signedOut:
                        SignInView()
                            .transition(.opacity)
                    case .signedIn:
                        RootView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: app.session)

                if showSplash {
                    SplashView()
                        .zIndex(1)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .milliseconds(450))
                            withAnimation(.easeOut(duration: 0.25)) { showSplash = false }
                        }
                }
            }
            .environment(app)
            .tint(Color.brand)
            .toastHost($app.toast)
            .onOpenURL { url in
                // The password-reset email links back here; only that link
                // opens "set a new password" (an OAuth callback also yields a
                // session and must not).
                if url.host == "reset-password" {
                    Task {
                        if (try? await SupabaseBackend.shared.client.auth.session(from: url)) != nil {
                            showPasswordReset = true
                        }
                    }
                } else {
                    app.handle(url: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stampdOpenURL)) { _ in
                if let url = DeepLinkInbox.take() { app.handle(url: url) }
            }
            .sheet(isPresented: $showPasswordReset) {
                NewPasswordSheet()
            }
            .task {
                app.start()
                if let url = DeepLinkInbox.take() { app.handle(url: url) }
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the notification delegate when a reminder is tapped.
    static let stampdOpenURL = Notification.Name("stampdOpenURL")
}

/// Cold-launch brand card: the system launch frame is already this green.
private struct SplashView: View {
    @State private var popped = false

    var body: some View {
        ZStack {
            Color.brandDeep.ignoresSafeArea()
            VStack(spacing: 10) {
                Image("BrandMark")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("Stampd")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.957, green: 0.937, blue: 0.894))
            }
            .scaleEffect(popped ? 1 : 0.8)
            .opacity(popped ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { popped = true }
        }
    }
}

/// After a password-reset deep link (recovery session active).
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
                        .textContentType(.newPassword)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(Color.danger)
                    } else {
                        Text("At least 8 characters.")
                    }
                }
            }
            .paperListStyle()
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
            try await SupabaseBackend.shared.updatePassword(password)
            dismiss()
        } catch {
            self.error = AppError.friendly(error)
        }
    }
}
