import SwiftUI

/// v1.2: the group feed — posts, emoji reactions, comments.
/// Realtime subscription lands after the basics prove out; pull-to-refresh for now.
struct GroupFeedView: View {
    let group: Group

    @State private var posts: [GroupPost] = []
    @State private var authors: [UUID: Profile] = [:]
    @State private var reactionsByPost: [UUID: [PostReaction]] = [:]
    @State private var myId: UUID?
    @State private var composerText = ""
    @State private var error: String?

    private let quickEmoji = ["😋", "🔥", "❤️", "😂"]

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Share something…", text: $composerText, axis: .vertical)
                    Button("Post") { Task { await post() } }
                        .disabled(composerText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(posts) { post in
                PostRow(
                    post: post,
                    author: authors[post.authorId],
                    reactions: reactionsByPost[post.id] ?? [],
                    myId: myId,
                    quickEmoji: quickEmoji,
                    onReact: { emoji, on in Task { await react(post: post, emoji: emoji, on: on) } }
                )
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle(group.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink {
                    SyncedMealsView(group: group)
                } label: {
                    Image(systemName: "heart")
                }
                NavigationLink {
                    GroupGlobeView(group: group)
                } label: {
                    Image(systemName: "globe.americas")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            myId = try? await SupabaseService.shared.client.auth.session.user.id
            posts = try await SupabaseService.shared.feedPosts(groupId: group.id)
            let authorList = try await SupabaseService.shared.profiles(ids: Array(Set(posts.map(\.authorId))))
            authors = Dictionary(uniqueKeysWithValues: authorList.map { ($0.id, $0) })
            let allReactions = try await SupabaseService.shared.reactions(postIds: posts.map(\.id))
            reactionsByPost = Dictionary(grouping: allReactions, by: \.postId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func post() async {
        do {
            try await SupabaseService.shared.createPost(groupId: group.id, text: composerText)
            composerText = ""
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func react(post: GroupPost, emoji: String, on: Bool) async {
        try? await SupabaseService.shared.toggleReaction(postId: post.id, emoji: emoji, on: on)
        await reload()
    }
}

private struct PostRow: View {
    let post: GroupPost
    let author: Profile?
    let reactions: [PostReaction]
    let myId: UUID?
    let quickEmoji: [String]
    let onReact: (String, Bool) -> Void

    @State private var showComments = false
    @State private var linkedEntry: Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(author?.name ?? "Someone").font(.subheadline.bold())
                Spacer()
                Text(post.createdAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !post.text.isEmpty { Text(post.text) }
            // When the post links a logged meal, show a compact card for it.
            if let entry = linkedEntry { LinkedMealCard(entry: entry) }

            HStack(spacing: 6) {
                ForEach(quickEmoji, id: \.self) { emoji in
                    let count = reactions.filter { $0.emoji == emoji }.count
                    let mine = reactions.contains { $0.emoji == emoji && $0.userId == myId }
                    Button {
                        onReact(emoji, !mine)
                    } label: {
                        Text(count > 0 ? "\(emoji) \(count)" : emoji)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(mine ? Color.accentColor.opacity(0.18) : Color(.systemGray6),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    showComments = true
                } label: {
                    Label("Comments", systemImage: "bubble.right").font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showComments) { CommentsSheet(post: post) }
        .task(id: post.entryId) {
            guard let entryId = post.entryId else { linkedEntry = nil; return }
            linkedEntry = try? await SupabaseService.shared.entry(id: entryId)
        }
    }
}

/// Compact card for a meal a post links to — flag/photo, restaurant, cuisine,
/// rating. Mirrors EntryRow's styling in a boxed, feed-friendly form.
private struct LinkedMealCard: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 10) {
            if let first = entry.photos.first, let url = SupabaseService.shared.photoURL(first) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text(CountryStore.byCode[entry.countryCode]?.flagEmoji ?? "🌍")
                        .font(.caption2)
                }
            } else {
                Text(CountryStore.byCode[entry.countryCode]?.flagEmoji ?? "🌍")
                    .font(.title2)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.restaurantName).font(.subheadline.bold())
                Text(CountryStore.byCode[entry.countryCode]?.cuisineName ?? entry.countryCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(repeating: "★", count: entry.rating))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CommentsSheet: View {
    let post: GroupPost

    @State private var comments: [PostComment] = []
    @State private var authors: [UUID: Profile] = [:]
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authors[comment.authorId]?.name ?? "Someone")
                            .font(.caption.bold())
                        Text(comment.text)
                    }
                    .padding(.leading, comment.parentId == nil ? 0 : 20) // threaded replies
                }
                HStack {
                    TextField("Add a comment…", text: $draft)
                    Button("Send") { Task { await send() } }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Comments")
            .task { await reload() }
        }
    }

    private func reload() async {
        comments = (try? await SupabaseService.shared.comments(postId: post.id)) ?? []
        let authorList = (try? await SupabaseService.shared.profiles(ids: Array(Set(comments.map(\.authorId))))) ?? []
        authors = Dictionary(uniqueKeysWithValues: authorList.map { ($0.id, $0) })
    }

    private func send() async {
        try? await SupabaseService.shared.addComment(postId: post.id, text: draft)
        draft = ""
        await reload()
    }
}
