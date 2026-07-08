import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            GlobeSceneView()
                .tabItem { Label("Globe", systemImage: "globe.asia.australia") }
            EntriesView()
                .tabItem { Label("Journal", systemImage: "clock") }
            GroupsView()
                .tabItem { Label("Groups", systemImage: "person.3") }
            PeopleView()
                .tabItem { Label("People", systemImage: "person.2") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}
