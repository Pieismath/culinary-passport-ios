import SwiftUI

struct RootView: View {
    @State private var tab = RootView.initialTab
    @State private var debugScreen = RootView.debugScreenArg

    var body: some View {
        TabView(selection: $tab) {
            GlobeSceneView()
                .tabItem { Label("Globe", systemImage: "globe.asia.australia") }
                .tag("globe")
            EntriesView()
                .tabItem { Label("Journal", systemImage: "clock") }
                .tag("journal")
            GroupsView()
                .tabItem { Label("Groups", systemImage: "person.3") }
                .tag("groups")
            PeopleView()
                .tabItem { Label("People", systemImage: "person.2") }
                .tag("people")
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
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
