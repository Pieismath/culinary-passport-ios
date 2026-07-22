import SwiftUI

/// v1.1 item 7 — a public profile: avatar, bio, follower/following counts, the
/// countries they've tried, and a follow button. Reached from People search.
struct PublicProfileView: View {
    let profile: Profile

    @State private var followers = 0
    @State private var followingCount = 0
    @State private var isFollowing = false
    @State private var triedCodes: [String] = []
    @State private var entries: [Entry] = []
    @State private var viewing: Entry?
    @State private var busy = false
    @State private var loaded = false
    @State private var reporting = false
    @State private var reportReason = ""
    @State private var isBlocked = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AsyncImage(url: profile.avatarUrl.flatMap(URL.init)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 80)).foregroundStyle(.secondary)
                }
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(profile.name).font(.title2).bold()
                    if let username = profile.username {
                        Text("@\(username)").foregroundStyle(.secondary)
                    }
                }

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                HStack(spacing: 28) {
                    stat(triedCodes.count, "cuisines")
                    stat(followers, "followers")
                    stat(followingCount, "following")
                }

                Button {
                    Task { await toggleFollow() }
                } label: {
                    Text(isFollowing ? "Following" : "Follow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isFollowing ? .secondary : .accentColor)
                .disabled(busy)
                .padding(.horizontal)

                if !triedCodes.isEmpty {
                    FlagWrap(codes: triedCodes)
                        .padding(.horizontal)
                }

                // Their meals — tap one for the full card.
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Meals")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                        ForEach(entries) { entry in
                            Button { viewing = entry } label: {
                                PublicMealRow(entry: entry).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 60)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .sheet(item: $viewing) { entry in
            EntryDetailView(entry: entry, author: profile)
                .presentationDetents([.medium, .large])
        }
        .navigationTitle(profile.username.map { "@\($0)" } ?? profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) { reporting = true } label: {
                        Label("Report profile", systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        Task {
                            try? await SupabaseService.shared.setBlocked(profile.id, true)
                            isBlocked = true
                        }
                    } label: {
                        Label("Block \(profile.name)", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Report this profile", isPresented: $reporting) {
            TextField("What's wrong?", text: $reportReason)
            Button("Cancel", role: .cancel) { reportReason = "" }
            Button("Report", role: .destructive) {
                Task {
                    try? await SupabaseService.shared.report(
                        contentType: "profile", contentId: profile.id,
                        reason: reportReason.isEmpty ? "inappropriate" : reportReason)
                    reportReason = ""
                }
            }
        }
        .overlay {
            if isBlocked {
                ContentUnavailableView(
                    "\(profile.name) is blocked",
                    systemImage: "hand.raised",
                    description: Text("They no longer appear in your feeds or search.")
                )
                .background(Color(.systemBackground))
            }
        }
        .task { await load() }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack {
            Text("\(value)").font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        defer { loaded = true }
        async let counts = try? await SupabaseService.shared.followCounts(userId: profile.id)
        async let following = (try? await SupabaseService.shared.following()) ?? []
        async let entries = (try? await SupabaseService.shared.publicEntries(userId: profile.id)) ?? []
        let (c, f, e) = await (counts, following, entries)
        followers = c?.followers ?? 0
        followingCount = c?.following ?? 0
        isFollowing = f.contains(profile.id)
        triedCodes = Array(Set(e.map(\.countryCode))).sorted()
        self.entries = e
    }

    private func toggleFollow() async {
        busy = true
        defer { busy = false }
        let target = !isFollowing
        do {
            try await SupabaseService.shared.setFollowing(profile.id, target)
            isFollowing = target
            followers += target ? 1 : -1
        } catch { /* keep prior state on failure */ }
    }
}

/// Simple wrapping row of cuisine flags.
private struct FlagWrap: View {
    let codes: [String]
    private let columns = [GridItem(.adaptive(minimum: 36), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(codes, id: \.self) { code in
                Text(CountryStore.byCode[code]?.flagEmoji ?? "🌍")
                    .font(.title3)
            }
        }
    }
}

/// One of someone else's meals in their profile list.
private struct PublicMealRow: View {
    let entry: Entry
    private var country: Country? { CountryStore.byCode[entry.countryCode] }

    var body: some View {
        HStack(spacing: 12) {
            if let first = entry.photos.first {
                SignedPhotoImage(path: first) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(country?.flagEmoji ?? "🌍")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.restaurantName).font(.subheadline.weight(.medium))
                Text([country?.cuisineName, entry.city].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            Spacer()
            Text(String(repeating: "★", count: entry.rating))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
    }
}
