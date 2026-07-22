import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab
    @State private var debugScreen = RootView.debugScreenArg
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $tab) {
            GlobeSceneView()
                .tabItem { Label("Globe", image: "tab-globe") }
                .tag("globe")
            EntriesView()
                .tabItem { Label("Journal", image: "tab-journal") }
                .tag("journal")
            GroupsView()
                .tabItem { Label("Groups", image: "tab-groups") }
                .tag("groups")
            PeopleView()
                .tabItem { Label("People", image: "tab-people") }
                .tag("people")
            ProfileView()
                .tabItem { Label("Profile", image: "tab-profile") }
                .tag("profile")
        }
        #if DEBUG
        // Headless test hook: `-open wrapped` presents that screen on launch.
        .sheet(item: $debugScreen) { screen in
            NavigationStack {
                switch screen {
                case .wrapped: WrappedView()
                }
            }
        }
        #endif
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                Self.markOnboarded()
                showOnboarding = false
            }
        }
        .task {
            // First run for this account: no meals yet and never welcomed.
            // Follows auth changes rather than running once — a stale keychain
            // session at launch would otherwise make the check look at the
            // previous account.
            guard !ProcessInfo.processInfo.arguments.contains("-uiPreview"),
                  !ProcessInfo.processInfo.arguments.contains("-skipOnboarding") else { return }
            for await state in SupabaseService.shared.client.auth.authStateChanges
            where state.session != nil {
                guard !Self.hasOnboarded() else { break }
                let mine = (try? await SupabaseService.shared.myEntries()) ?? []
                if mine.isEmpty {
                    showOnboarding = true
                    break
                }
            }
        }
    }

    private static func onboardKey() -> String {
        "hasOnboarded" // per-device is fine; the entries check handles per-account
    }

    static func hasOnboarded() -> Bool {
        UserDefaults.standard.bool(forKey: onboardKey())
    }

    static func markOnboarded() {
        UserDefaults.standard.set(true, forKey: onboardKey())
    }

    /// Headless test hook: `-tab journal` opens on that tab.
    private static var initialTab: String {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count { return args[i + 1] }
        #endif
        return "globe"
    }

    enum DebugScreen: String, Identifiable { case wrapped; var id: String { rawValue } }

    private static var debugScreenArg: DebugScreen? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-open"), i + 1 < args.count { return DebugScreen(rawValue: args[i + 1]) }
        #endif
        return nil
    }
}
