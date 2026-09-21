import SwiftUI

/// The group chat: messages, shared memories, reactions and inline replies,
/// live over realtime. Every message can be reacted to, replied to, deleted
/// by its author, or reported (App Store 1.2 — this used to be missing).
struct GroupChatView: View {
    let group: Group

    @Environment(AppModel.self) private var app
    @State private var chat: ChatModel
    @State private var composer = ""
    @State private var replyTo: GroupPost?
    @State private var reactingTo: GroupPost?
    @State private var reporting: ReportTarget?
    @State private var viewing: Memory?
    @State private var sharingMemory = false
    @State private var sending = false
    @FocusState private var composerFocused: Bool

    struct ReportTarget: Identifiable {
        let type: String
        let id: UUID
    }

    init(group: Group) {
        self.group = group
        _chat = State(initialValue: ChatModel(groupId: group.id))
    }

    private var palette: [UUID: String] {
        var profiles = app.people
        if let me = app.me { profiles[me.id] = me }
        return GroupPalette.assign(memberIds: app.members(of: group.id), profiles: profiles)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chat.canLoadEarlier {
                        Button {
                            Task { await chat.loadEarlier(app: app) }
                        } label: {
                            Text(chat.loadingEarlier ? "Loading…" : "Load earlier messages")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    if chat.loaded && chat.posts.isEmpty {
                        EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                                       title: "Start planning",
                                       message: "Share a memory, float a destination, or tap 🎲 and let the globe decide.")
                            .padding(.top, 60)
                    }
                    ForEach(chat.posts.reversed().filter { !app.blocked.contains($0.authorId) }) { post in
                        MessageView(
                            post: post,
                            isMine: post.authorId == app.myId,
                            author: app.profile(post.authorId),
                            color: Color(hex: palette[post.authorId] ?? "#8b8b8b"),
                            memory: post.entryId.flatMap { chat.memories[$0] },
                            memoryMissing: post.entryId != nil && chat.memoriesLoaded && post.entryId.flatMap { chat.memories[$0] } == nil,
                            replies: (chat.comments[post.id] ?? []).filter { !app.blocked.contains($0.authorId) },
                            tallies: ReactionTally.tally((chat.reactions[post.id] ?? []).map { ($0.emoji, $0.userId) }, me: app.myId),
                            palette: palette,
                            onReact: { emoji, on in Task { await chat.react(post.id, emoji: emoji, on: on, app: app) } },
                            onPickReaction: { reactingTo = post },
                            onReply: {
                                replyTo = post
                                composerFocused = true
                            },
                            onDelete: { Task { await chat.delete(post, app: app) } },
                            onReport: { reporting = ReportTarget(type: "post", id: post.id) },
                            onDeleteReply: { reply in Task { await chat.deleteReply(reply, app: app) } },
                            onReportReply: { reply in reporting = ReportTarget(type: "comment", id: reply.id) },
                            onOpenMemory: { viewing = $0 }
                        )
                        .id(post.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .paperBackground()
            .safeAreaInset(edge: .bottom) { composerBar }
            .onChange(of: chat.posts.first?.id) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $reactingTo) { post in
            EmojiPickerSheet { emoji in Task { await chat.react(post.id, emoji: emoji, on: true, app: app) } }
        }
        .sheet(item: $reporting) { target in
            ReportSheet(title: "Report message") { reason in
                Task { await app.report(target.type, id: target.id, reason: reason) }
            }
        }
        .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
        .sheet(isPresented: $sharingMemory) {
            MemoryPickerSheet { memory in
                Task { await chat.send(text: "", memoryId: memory.id, app: app) }
            }
        }
        .task { await chat.reload(app: app) }
        .task {
            // Realtime: debounce bursts of events into one reload.
            var pending: Task<Void, Never>?
            for await _ in app.backend.chatChanges(groupId: group.id) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await chat.reload(app: app)
                }
            }
        }
        .refreshable { await chat.reload(app: app) }
    }

    private var composerBar: some View {
        VStack(spacing: 8) {
            if let replyTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.caption)
                    Text("Replying to \(app.profile(replyTo.authorId)?.firstName ?? "message")")
                        .font(.caption.weight(.semibold))
                    Text(replyTo.text.isEmpty ? "shared memory" : replyTo.text)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(Color.inkSecondary)
                    Spacer()
                    Button { self.replyTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Cancel reply")
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { sharingMemory = true } label: {
                        Label("Share a memory", systemImage: "photo.on.rectangle")
                    }
                    Button { Task { await suggestDinner() } } label: {
                        Label("What should we eat?", systemImage: "fork.knife")
                    }
                    Button { Task { await suggestDestination() } } label: {
                        Label("Where should we go?", systemImage: "airplane")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 38, height: 38)
                        .background(Color.sunken, in: Circle())
                }
                .accessibilityLabel("Share")

                TextField(replyTo == nil ? "Message" : "Reply", text: $composer, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.8))

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.onBrand)
                        .frame(width: 38, height: 38)
                        .background(composer.trimmed.isEmpty ? Color.inkTertiary : Color.brand, in: Circle())
                }
                .disabled(composer.trimmed.isEmpty || sending)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() async {
        let text = composer.trimmed
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        let target = replyTo
        composer = ""
        replyTo = nil
        let sent = target == nil
            ? await chat.send(text: text, memoryId: nil, app: app)
            : await chat.reply(to: target!.id, text: text, app: app)
        if !sent {
            // Offline or rejected: give the words back instead of losing them.
            composer = text
            replyTo = target
        }
    }

    /// A cuisine none of you has tasted — the weekly version of the trip dice.
    private func suggestDinner() async {
        let members = app.members(of: group.id)
        let tasted = Set(((try? await app.backend.tastes(userIds: members)) ?? []).map(\.countryCode))
        let pool = Cuisine.dicePool.filter { !tasted.contains($0) }
        guard let pick = (pool.isEmpty ? Cuisine.dicePool : pool).randomElement() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let line = pool.isEmpty ? "we've all had it, but it's been a while"
                                : "none of us has tried it yet"
        await chat.send(text: "🎲 Dinner roll: \(Country.flag(for: pick)) \(Cuisine.name(for: pick)) — \(line)!",
                        memoryId: nil, app: app)
        app.backend.logEvent("dinner_rolled", props: ["cuisine": pick, "group": "true"])
    }

    /// A country none of you has stamped — let the globe pick the next trip.
    private func suggestDestination() async {
        let members = app.members(of: group.id)
        let stamps = (try? await app.backend.stamps(userIds: members)) ?? []
        let visited = Set(stamps.map(\.countryCode))
        let pool = CountryStore.all.filter { $0.isSovereign && !visited.contains($0.code) }
        guard let pick = pool.randomElement() else { return }
        await chat.send(text: "🎲 Where next? \(pick.flag) \(pick.name) — none of us has been yet!", memoryId: nil, app: app)
    }
}

@MainActor
@Observable
final class ChatModel {
    let groupId: UUID
    var posts: [GroupPost] = []          // newest first
    var comments: [UUID: [PostComment]] = [:]
    var reactions: [UUID: [PostReaction]] = [:]
    var memories: [UUID: Memory] = [:]
    var loaded = false
    var memoriesLoaded = false
    var canLoadEarlier = false
    var loadingEarlier = false

    private let pageSize = 40

    init(groupId: UUID) { self.groupId = groupId }

    func reload(app: AppModel) async {
        guard let page = try? await app.backend.posts(groupId: groupId, before: nil, limit: pageSize) else {
            loaded = true
            return
        }
        // Keep history already paged in; refresh the newest page.
        let fresh = Set(page.map(\.id))
        let oldest = page.last?.createdAt ?? .distantFuture
        let older = posts.filter { !fresh.contains($0.id) && $0.createdAt < oldest }
        posts = page + older
        if older.isEmpty { canLoadEarlier = page.count >= pageSize }
        await decorate(posts, app: app)
        loaded = true
    }

    func loadEarlier(app: AppModel) async {
        guard !loadingEarlier, let oldest = posts.last else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        guard let page = try? await app.backend.posts(groupId: groupId, before: oldest.createdAt, limit: pageSize) else { return }
        posts += page
        canLoadEarlier = page.count >= pageSize
        await decorate(page, app: app)
    }

    private func decorate(_ page: [GroupPost], app: AppModel) async {
        let ids = page.map(\.id)
        let fetchedComments = (try? await app.backend.postComments(postIds: ids)) ?? []
        let fetchedReactions = (try? await app.backend.postReactions(postIds: ids)) ?? []
        for id in ids {
            comments[id] = fetchedComments.filter { $0.postId == id }
            reactions[id] = fetchedReactions.filter { $0.postId == id }
        }
        let memoryIds = Array(Set(page.compactMap(\.entryId)).subtracting(memories.keys))
        if !memoryIds.isEmpty, let fetched = try? await app.backend.memories(ids: memoryIds) {
            for memory in fetched { memories[memory.id] = memory }
        }
        memoriesLoaded = true
        var people = Set(page.map(\.authorId))
        people.formUnion(fetchedComments.map(\.authorId))
        people.formUnion(memories.values.map(\.userId))
        _ = await app.profiles(for: Array(people))
    }

    @discardableResult
    func send(text: String, memoryId: UUID?, app: AppModel) async -> Bool {
        do {
            try await app.backend.createPost(groupId: groupId, text: text, memoryId: memoryId)
            app.backend.logEvent("chat_sent", props: memoryId == nil ? nil : ["memory": "true"])
            await reload(app: app)
            return true
        } catch {
            app.show(error)
            return false
        }
    }

    @discardableResult
    func reply(to postId: UUID, text: String, app: AppModel) async -> Bool {
        do {
            try await app.backend.addPostComment(postId: postId, text: text)
            await reload(app: app)
            return true
        } catch {
            app.show(error)
            return false
        }
    }

    func react(_ postId: UUID, emoji: String, on: Bool, app: AppModel) async {
        guard let me = app.myId else { return }
        let before = reactions[postId] ?? []
        var next = before.filter { !($0.userId == me && $0.emoji == emoji) }
        if on { next.append(PostReaction(postId: postId, userId: me, emoji: emoji)) }
        reactions[postId] = next
        do {
            try await app.backend.setPostReaction(postId: postId, emoji: emoji, on: on)
        } catch {
            reactions[postId] = before
            app.show(error)
        }
    }

    func delete(_ post: GroupPost, app: AppModel) async {
        let before = posts
        posts.removeAll { $0.id == post.id }
        do {
            try await app.backend.deletePost(id: post.id)
        } catch {
            posts = before
            app.show(error)
        }
    }

    func deleteReply(_ reply: PostComment, app: AppModel) async {
        let before = comments[reply.postId] ?? []
        comments[reply.postId] = before.filter { $0.id != reply.id }
        do {
            try await app.backend.deletePostComment(id: reply.id)
        } catch {
            comments[reply.postId] = before
            app.show(error)
        }
    }
}

private struct MessageView: View {
    let post: GroupPost
    let isMine: Bool
    let author: Profile?
    let color: Color
    let memory: Memory?
    let memoryMissing: Bool
    let replies: [PostComment]
    let tallies: [ReactionTally]
    let palette: [UUID: String]
    let onReact: (String, Bool) -> Void
    let onPickReaction: () -> Void
    let onReply: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void
    let onDeleteReply: (PostComment) -> Void
    let onReportReply: (PostComment) -> Void
    let onOpenMemory: (Memory) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                if isMine { Spacer(minLength: 50) }
                if !isMine {
                    AvatarView(profile: author, size: 30, ring: color)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine {
                        Text(author?.firstName ?? "Traveller")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(.body)
                            .foregroundStyle(isMine ? Color.onBrand : Color.ink)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(isMine ? Color.brand : Color.card,
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                if !isMine {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5)
                                }
                            }
                    }
                    if let memory {
                        Button { onOpenMemory(memory) } label: { SharedMemoryCard(memory: memory) }
                            .buttonStyle(.plain)
                    } else if memoryMissing {
                        Label("This memory isn't available", systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(Color.inkTertiary)
                            .padding(10)
                            .background(Color.sunken, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text(RelativeTime.short(post.createdAt))
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                }
                .contextMenu {
                    Button(action: onPickReaction) { Label("React", systemImage: "face.smiling") }
                    Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    if !post.text.isEmpty {
                        Button { UIPasteboard.general.string = post.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    if isMine {
                        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    } else {
                        Button(role: .destructive, action: onReport) { Label("Report", systemImage: "flag") }
                    }
                }
                if !isMine { Spacer(minLength: 50) }
            }

            if !tallies.isEmpty {
                HStack(spacing: 5) {
                    ForEach(tallies) { tally in
                        Button { onReact(tally.emoji, !tally.mine) } label: {
                            Text("\(tally.emoji) \(tally.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tally.mine ? Color.brand : Color.inkSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(tally.mine ? Color.brandSoft : Color.sunken, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(isMine ? .trailing : .leading, isMine ? 4 : 38)
            }

            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(replies) { reply in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(reply.authorId == app.myId ? "You" : (app.profile(reply.authorId)?.firstName ?? "Traveller"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(hex: palette[reply.authorId] ?? "#8b8b8b"))
                            Text(reply.text)
                                .font(.subheadline)
                                .foregroundStyle(Color.ink)
                        }
                        .contextMenu {
                            if reply.authorId == app.myId {
                                Button(role: .destructive) { onDeleteReply(reply) } label: { Label("Delete", systemImage: "trash") }
                            } else {
                                Button(role: .destructive) { onReportReply(reply) } label: { Label("Report", systemImage: "flag") }
                            }
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.5)).frame(width: 2)
                }
                .padding(isMine ? .trailing : .leading, isMine ? 8 : 40)
                .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

private struct SharedMemoryCard: View {
    let memory: Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(width: 230, height: 170)
                .overlay {
                    if let first = memory.photos.first {
                        StoragePhoto(path: first, maxPixel: 700)
                    } else {
                        PostcardPlaceholder(code: memory.countryCode, title: nil)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text("\(memory.country?.flag ?? "") \(memory.placeLine)")
                    .font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: 230)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
    }
}

/// Pick one of your memories to share.
struct MemoryPickerSheet: View {
    let onPick: (Memory) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let shareable = app.memories.filter { $0.visibility != .private }
                if shareable.isEmpty {
                    EmptyStateView(systemImage: "photo.on.rectangle", title: "Nothing to share yet",
                                   message: "Memories set to Only me can't be shared to groups.")
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(shareable) { memory in
                            Button {
                                onPick(memory)
                                dismiss()
                            } label: {
                                MemoryTile(memory: memory)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Metrics.gutter)
                }
            }
            .paperBackground()
            .navigationTitle("Share a memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
