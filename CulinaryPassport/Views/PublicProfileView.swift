import SwiftUI

/// v1.1 item 7 — a public profile: avatar, bio, follower/following counts, the
/// countries they've tried, and a follow button. Reached from People search.
struct PublicProfileView: View {
    let profile: Profile

    @State private var followers = 0
    @State private var followingCount = 0
    @State private var isFollowing = false
    @State private var triedCodes: [String] = []
    @State private var busy = false
    @State private var loaded = false

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
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(profile.username.map { "@\($0)" } ?? profile.name)
        .navigationBarTitleDisplayMode(.inline)
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
