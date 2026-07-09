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
            ToolbarItem(placement: .primaryAction) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(author?.name ?? "Someone").font(.subheadline.bold())
                Spacer()
                Text(post.createdAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !post.text.isEmpty { Text(post.text) }
            // TODO(v1.2): entry cards — when post.entryId != nil render the meal
            // ("Mom tried her first Ethiopian → Meskerem, ★★★★★") + "Save to want-to-try"

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
