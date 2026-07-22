import SwiftUI

/// v1.1: the social layer. Empty search shows the Discover feed (item 8); typing
/// searches public profiles to follow (item 7).
struct PeopleView: View {
    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var following: Set<UUID> = []
    @State private var feed: [FeedItem] = []
    @State private var viewing: FeedItem?
    @State private var blocked: Set<UUID> = []
    @State private var showActivity = false
    @State private var hasUnseenActivity = false
    @State private var status: String?

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    ForEach(results.filter { !blocked.contains($0.id) }) { profile in
                        NavigationLink {
                            PublicProfileView(profile: profile)
                        } label: {
                            PersonRow(
                                profile: profile,
                                following: following.contains(profile.id),
                                onToggle: { follow in Task { await toggle(profile.id, to: follow) } }
                            )
                        }
                    }
                } else {
                    Section("Discover") {
                        ForEach(feed.filter { !blocked.contains($0.author.id) }) { item in
                            Button {
                                viewing = item
                            } label: {
                                FeedRow(item: item)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .overlay {
                if searching && results.isEmpty {
                    ContentUnavailableView(
                        "No one found",
                        systemImage: "person.2",
                        description: Text("Search by name or username. Public profiles only.")
                    )
                } else if !searching && feed.isEmpty {
                    ContentUnavailableView(
                        "Nothing to discover yet",
                        systemImage: "sparkles",
                        description: Text("Public meals from the community will show up here.")
                    )
                }
            }
            .sheet(item: $viewing) { item in
                EntryDetailView(entry: item.entry, author: item.author)
                    .presentationDetents([.medium, .large])
            }
            .searchable(text: $query, prompt: "Name or username")
            .onChange(of: query) { Task { await search() } }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showActivity = true } label: {
                        Image(systemName: "bell")
                            .overlay(alignment: .topTrailing) {
                                if hasUnseenActivity {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                    }
                    .accessibilityLabel("Activity")
                }
            }
            .sheet(isPresented: $showActivity, onDismiss: { hasUnseenActivity = false }) {
                ActivityView()
            }
            .task {
                following = (try? await SupabaseService.shared.following()) ?? []
                blocked = (try? await SupabaseService.shared.blockedIds()) ?? []
                feed = (try? await SupabaseService.shared.discoverFeed()) ?? []
                // Light unseen check: anything in activity newer than last open?
                if let latest = (try? await SupabaseService.shared.activity(limit: 1))?.first {
                    hasUnseenActivity = latest.date > ActivityView.lastSeen
                }
            }
            .refreshable {
                blocked = (try? await SupabaseService.shared.blockedIds()) ?? blocked
                feed = (try? await SupabaseService.shared.discoverFeed()) ?? []
            }
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
            SupabaseService.shared.logEvent(follow ? "followed" : "unfollowed")
            if follow { following.insert(userId) } else { following.remove(userId) }
        } catch { status = error.localizedDescription }
    }
}

private struct PersonRow: View {
    let profile: Profile
    let following: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: profile.avatarUrl.flatMap(URL.init)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
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
            Button(following ? "Following" : "Follow") { onToggle(!following) }
                .buttonStyle(.bordered)
                .tint(following ? .secondary : .accentColor)
        }
    }
}

/// One discover-feed meal: author, cuisine, restaurant, rating, optional photo.
private struct FeedRow: View {
    let item: FeedItem

    private var country: Country? { CountryStore.byCode[item.entry.countryCode] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AsyncImage(url: item.author.avatarUrl.flatMap(URL.init)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.author.name).font(.subheadline).bold()
                    Text("\(country?.flagEmoji ?? "🌍") \(country?.cuisineName ?? item.entry.countryCode) · \(item.entry.dateTried)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(repeating: "★", count: item.entry.rating))
                    .font(.caption).foregroundStyle(.orange)
            }

            if let first = item.entry.photos.first {
                SignedPhotoImage(path: first) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text(item.entry.restaurantName)
                .font(.subheadline)
            if let city = item.entry.city, !city.isEmpty {
                Text(city).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
