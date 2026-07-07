import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            GlobeSceneView()
                .tabItem { Label("Globe", systemImage: "globe.asia.australia") }
            Text("Journal — timeline of every meal (port web A4 design)")
                .tabItem { Label("Journal", systemImage: "clock") }
            Text("Groups — feed, shared map, solidarity/consensus toggle (v1.2)")
                .tabItem { Label("Groups", systemImage: "person.3") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}

struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 16) {
            AsyncImage(url: avatarURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160, height: 160)

            // TODO(MVP-4): PhotosPicker / camera → AvatarService.generateAvatar
            Button(busy ? "Generating…" : "Upload a selfie → get your avatar") {
                status = "Wire up PhotosPicker here (see AvatarService)"
            }
            .disabled(busy)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }

            Button("Sign out") {
                Task { try? await SupabaseService.shared.client.auth.signOut() }
            }
            .font(.caption)
        }
        .padding()
    }
}
