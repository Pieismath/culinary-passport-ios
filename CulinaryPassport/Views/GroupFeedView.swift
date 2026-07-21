import SwiftUI
import Supabase
import UIKit

/// The group chat: messages with their replies threaded INLINE underneath
/// (no comments-behind-a-tap), live via realtime, iMessage-adjacent styling.
/// Reached from the group home — the globe stays the main event.
struct GroupFeedView: View {
    let group: Group

    @State private var posts: [GroupPost] = []
    @State private var commentsByPost: [UUID: [PostComment]] = [:]
    @State private var authors: [UUID: Profile] = [:]
    @State private var reactionsByPost: [UUID: [PostReaction]] = [:]
    @State private var myId: UUID?
    @State private var composerText = ""
    @State private var replyTo: GroupPost?
    @State private var error: String?
    @State private var reloadDebounce: Task<Void, Never>?
    /// Post awaiting an emoji from the picker.
    @State private var reactingTo: GroupPost?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if posts.isEmpty {
                    ContentUnavailableView(
                        "Say something",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Meals you log also drop into the chat for everyone to see.")
                    )
                    .listRowSeparator(.hidden)
                }
                // Chat order: oldest at the top, newest by the composer.
                ForEach(posts.reversed()) { post in
                    MessageRow(
                        post: post,
                        comments: commentsByPost[post.id] ?? [],
                        authors: authors,
                        reactions: reactionsByPost[post.id] ?? [],
                        myId: myId,
                        onToggle: { emoji, on in Task { await react(post: post, emoji: emoji, on: on) } },
                        onAddReaction: { reactingTo = post },
                        onReply: { replyTo = post }
                    )
                    .id(post.id)
                    .listRowSeparator(.hidden)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) { composer }
            .onChange(of: posts.first?.id) {
                if let newest = posts.first?.id {
                    withAnimation { proxy.scrollTo(newest, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("\(group.name) chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SyncedMealsView(group: group)
                } label: {
                    BrandedIcon(name: "feature-sync", size: 22)
                }
            }
        }
        .task { await reload() }
        .task { await listenForChanges() }
        .refreshable { await reload() }
        .sheet(item: $reactingTo) { post in
            EmojiPickerSheet { emoji in
                Task { await react(post: post, emoji: emoji, on: true) }
            }
        }
    }

    // ── Composer (message, or threaded reply when a target is set) ───────────

    private var composer: some View {
        VStack(spacing: 6) {
            if let replyTo {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption2)
                    Text("Replying to \(authors[replyTo.authorId]?.name ?? "someone"): \(replyTo.text)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.replyTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                }
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(replyTo == nil ? "Message…" : "Reply…", text: $composerText, axis: .vertical)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(composerText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func send() async {
        let text = composerText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            if let replyTo {
                try await SupabaseService.shared.addComment(postId: replyTo.id, text: text)
            } else {
                try await SupabaseService.shared.createPost(groupId: group.id, text: text)
            }
            composerText = ""
            replyTo = nil
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Finding 7: live chat. Posts are filtered to this group server-side;
    /// comments/reactions carry no group_id, so any event debounce-reloads
    /// (RLS scopes what we receive). `.task` cancellation tears it down.
    private func listenForChanges() async {
        let client = SupabaseService.shared.client
        let channel = client.channel("group-feed-\(group.id.uuidString)")
        let postEvents = channel.postgresChange(
            AnyAction.self, schema: "public", table: "group_posts",
            filter: .eq("group_id", value: group.id.uuidString)
        )
        let commentEvents = channel.postgresChange(AnyAction.self, schema: "public", table: "post_comments")
        let reactionEvents = channel.postgresChange(AnyAction.self, schema: "public", table: "post_reactions")
        do {
            try await channel.subscribeWithError()
        } catch {
            await client.removeChannel(channel)
            return
        }

        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask { for await _ in postEvents { await reloadSoon() } }
            tasks.addTask { for await _ in commentEvents { await reloadSoon() } }
            tasks.addTask { for await _ in reactionEvents { await reloadSoon() } }
        }
        await client.removeChannel(channel)
    }

    @MainActor
    private func reloadSoon() {
        reloadDebounce?.cancel()
        reloadDebounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        do {
            myId = try? await SupabaseService.shared.client.auth.session.user.id
            posts = try await SupabaseService.shared.feedPosts(groupId: group.id)
            let allComments = try await SupabaseService.shared.comments(postIds: posts.map(\.id))
            commentsByPost = Dictionary(grouping: allComments, by: \.postId)

            // Colors consistent with the group globe legend.
            let memberIds = (try? await SupabaseService.shared.groupMemberIds(groupId: group.id)) ?? []
            var authorIds = Set(posts.map(\.authorId)).union(allComments.map(\.authorId))
            authorIds.formUnion(memberIds)
            let profiles = try await SupabaseService.shared.profiles(ids: Array(authorIds))
            let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let palette = GroupPalette.assign(memberIds: memberIds, profiles: byId)
            authors = byId.mapValues { profile in
                var p = profile
                p.color = palette[p.id] ?? p.color
                return p
            }

            let allReactions = try await SupabaseService.shared.reactions(postIds: posts.map(\.id))
            reactionsByPost = Dictionary(grouping: allReactions, by: \.postId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func react(post: GroupPost, emoji: String, on: Bool) async {
        try? await SupabaseService.shared.toggleReaction(postId: post.id, emoji: emoji, on: on)
        await reload()
    }
}

// ── One message + its inline thread ─────────────────────────────────────────

private struct MessageRow: View {
    let post: GroupPost
    let comments: [PostComment]
    let authors: [UUID: Profile]
    let reactions: [PostReaction]
    let myId: UUID?
    let onToggle: (String, Bool) -> Void
    let onAddReaction: () -> Void
    let onReply: () -> Void

    @State private var linkedEntry: Entry?

    private func color(_ id: UUID) -> Color {
        Color(uiColor: UIColor(hex: authors[id]?.color ?? "") ?? .systemGray)
    }

    /// Distinct emoji on this message, most-reacted first, stable thereafter.
    private var tallies: [(emoji: String, count: Int, mine: Bool)] {
        Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count,
                    mine: $0.value.contains { $0.userId == myId }) }
            .sorted { ($0.count, $1.emoji) > ($1.count, $0.emoji) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color(post.authorId)).frame(width: 9, height: 9)
                Text(authors[post.authorId]?.name ?? "Someone").font(.subheadline.bold())
                Spacer()
                Text(post.createdAt, style: .relative)
                    .font(.caption2).foregroundStyle(Color(.secondaryLabel))
            }

            if !post.text.isEmpty {
                Text(post.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
            }
            // When the message links a logged meal, show its compact card.
            if let entry = linkedEntry { LinkedMealCard(entry: entry) }

            // Only reactions people actually added show up — each with its
            // count, mine highlighted, tap to add/remove yours.
            HStack(spacing: 6) {
                if !tallies.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tallies, id: \.emoji) { tally in
                                Button {
                                    onToggle(tally.emoji, !tally.mine)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(tally.emoji)
                                        Text("\(tally.count)").monospacedDigit()
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(tally.mine ? Color.accentColor.opacity(0.18) : Color(.systemGray6),
                                                in: Capsule())
                                    .overlay {
                                        if tally.mine {
                                            Capsule().stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button(action: onAddReaction) {
                    Image(systemName: "face.smiling")
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(.systemGray6), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityLabel("Add a reaction")

                Spacer()
                Button(action: onReply) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.secondaryLabel))
            }

            // The thread, right here under the message.
            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(comments) { comment in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(color(comment.authorId)).frame(width: 7, height: 7)
                            Text(authors[comment.authorId]?.name ?? "Someone")
                                .font(.caption.bold())
                            Text(comment.text).font(.callout)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(width: 2)
                        .clipShape(Capsule())
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 5)
        .task(id: post.entryId) {
            guard let entryId = post.entryId else { linkedEntry = nil; return }
            linkedEntry = try? await SupabaseService.shared.entry(id: entryId)
        }
    }
}

/// Compact card for a meal a message links to.
struct LinkedMealCard: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 10) {
            if let first = entry.photos.first {
                SignedPhotoImage(path: first) { image in
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
                    .foregroundStyle(Color(.secondaryLabel))
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
