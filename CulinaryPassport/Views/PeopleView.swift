import SwiftUI

/// v1.1: the social layer — search public profiles, follow / unfollow.
/// Discover feed + suggestions come after the follow graph has data.
struct PeopleView: View {
    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var following: Set<UUID> = []
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { profile in
                    HStack(spacing: 12) {
                        AsyncImage(url: profile.avatarUrl.flatMap(URL.init)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            if let username = profile.username {
                                Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        let follows = following.contains(profile.id)
                        Button(follows ? "Following" : "Follow") {
                            Task { await toggle(profile.id, to: !follows) }
                        }
                        .buttonStyle(.bordered)
                        .tint(follows ? .secondary : .accentColor)
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        "Find your people",
                        systemImage: "person.2",
                        description: Text("Search by name or username. Public profiles only.")
                    )
                }
            }
            .searchable(text: $query, prompt: "Name or username")
            .onChange(of: query) {
                Task { await search() }
            }
            .navigationTitle("People")
            .task { following = (try? await SupabaseService.shared.following()) ?? [] }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        do { results = try await SupabaseService.shared.searchPublicProfiles(q) }
        catch { status = error.localizedDescription }
    }

    private func toggle(_ userId: UUID, to follow: Bool) async {
        do {
            try await SupabaseService.shared.setFollowing(userId, follow)
            if follow { following.insert(userId) } else { following.remove(userId) }
        } catch { status = error.localizedDescription }
    }
}
