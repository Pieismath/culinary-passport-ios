import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab
    @State private var debugScreen = RootView.debugScreenArg

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
