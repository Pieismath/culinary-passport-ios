import SwiftUI
import MapKit

/// The talk at a table: messages, shared meals and dinner picks, with
/// reactions and inline replies, live over realtime. A pick is a ticket
/// everyone can answer with "I'm in". Every message can be reacted to,
/// replied to, deleted by its author, or reported.
struct TableConversation: View {
    let group: Group
    @Bindable var chat: ChatModel
    var composing: FocusState<Bool>.Binding
    /// Spin the table's globe (from the composer's menu).
    var onSpin: () -> Void
    /// Find a picked cuisine near you.
    var onFind: (String) -> Void

    @Environment(AppModel.self) private var app
    @State private var composer = ""
    @State private var replyTo: GroupPost?
    @State private var reactingTo: GroupPost?
    @State private var reporting: ReportTarget?
    @State private var viewing: Meal?
    @State private var sharingMeal = false
    @State private var sending = false

    struct ReportTarget: Identifiable {
        let type: String
        let id: UUID
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
                        VStack(spacing: 6) {
                            Text("Nothing said yet")
                                .font(.displayXSmall)
                                .foregroundStyle(Color.ink)
                            Text("Spin the globe for tonight's cuisine, share a meal, or just say hi.")
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 30)
                        .padding(.horizontal, 30)
                    }
                    let palette = self.palette
                    ForEach(chat.posts.reversed().filter { !app.blocked.contains($0.authorId) }) { post in
                        MessageView(
                            post: post,
                            isMine: post.authorId == app.myId,
                            author: app.profile(post.authorId),
                            color: Color(hex: palette[post.authorId] ?? "#8b8b8b"),
                            meal: post.entryId.flatMap { chat.meals[$0] },
                            mealMissing: post.entryId != nil && chat.mealsLoaded && post.entryId.flatMap { chat.meals[$0] } == nil,
                            replies: (chat.comments[post.id] ?? []).filter { !app.blocked.contains($0.authorId) },
                            reactions: chat.reactions[post.id] ?? [],
                            palette: palette,
                            onReact: { emoji, on in Task { await chat.react(post.id, emoji: emoji, on: on, app: app) } },
                            onPickReaction: { reactingTo = post },
                            onReply: {
                                replyTo = post
                                composing.wrappedValue = true
                            },
                            onDelete: { Task { await chat.delete(post, app: app) } },
                            onReport: { reporting = ReportTarget(type: "post", id: post.id) },
                            onDeleteReply: { reply in Task { await chat.deleteReply(reply, app: app) } },
                            onReportReply: { reply in reporting = ReportTarget(type: "comment", id: reply.id) },
                            onOpenMeal: { viewing = $0 },
                            onFind: onFind
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
            .safeAreaInset(edge: .bottom) { composerBar }
            .onChange(of: chat.posts.first?.id) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.mealsLoaded) {
                // Shared meals arrive after the words and make the page taller.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .sheet(item: $reactingTo) { post in
            EmojiPickerSheet { emoji in Task { await chat.react(post.id, emoji: emoji, on: true, app: app) } }
        }
        .sheet(item: $reporting) { target in
            ReportSheet(title: "Report message") { reason in
                Task { await app.report(target.type, id: target.id, reason: reason) }
            }
        }
        .sheet(item: $viewing) { MealDetailView(meal: $0) }
        .sheet(isPresented: $sharingMeal) {
            MealPickerSheet { meal in
                Task { await chat.send(text: "", mealId: meal.id, app: app) }
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
    }

    private var composerBar: some View {
        VStack(spacing: 8) {
            if let replyTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.caption)
                    Text("Replying to \(app.profile(replyTo.authorId)?.firstName ?? "message")")
                        .font(.caption.weight(.semibold))
                    Text(replyTo.pick.map { $0.placeName ?? Cuisine.name(for: $0.cuisineCode) }
                         ?? (replyTo.text.isEmpty ? "shared meal" : replyTo.text))
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
                    Button(action: onSpin) {
                        Label("Spin for the table", systemImage: "globe.europe.africa.fill")
                    }
                    Button { sharingMeal = true } label: {
                        Label("Share a meal", systemImage: "fork.knife")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 38, height: 38)
                        .background(Color.sunken, in: Circle())
                }
                .accessibilityLabel("Spin or share")

                TextField(replyTo == nil ? "Say something to the table" : "Reply", text: $composer, axis: .vertical)
                    .lineLimit(1...5)
                    .focused(composing)
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
            ? await chat.send(text: text, mealId: nil, app: app)
            : await chat.reply(to: target!.id, text: text, app: app)
        if !sent {
            // Offline or rejected: give the words back instead of losing them.
            composer = text
            replyTo = target
        }
    }
}

@MainActor
@Observable
final class ChatModel {
    let groupId: UUID
    var posts: [GroupPost] = []          // newest first
    var comments: [UUID: [PostComment]] = [:]
    var reactions: [UUID: [PostReaction]] = [:]
    var meals: [UUID: Meal] = [:]
    var loaded = false
    var mealsLoaded = false
    var canLoadEarlier = false
    var loadingEarlier = false

    private let pageSize = 40

    init(groupId: UUID) { self.groupId = groupId }

    /// The latest word at the table, for the header.
    var latest: GroupPost? { posts.first }

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
        let mealIds = Array(Set(page.compactMap(\.entryId)).subtracting(meals.keys))
        if !mealIds.isEmpty, let fetched = try? await app.backend.meals(ids: mealIds) {
            for meal in fetched { meals[meal.id] = meal }
        }
        mealsLoaded = true
        var people = Set(page.map(\.authorId))
        people.formUnion(fetchedComments.map(\.authorId))
        people.formUnion(fetchedReactions.map(\.userId))
        people.formUnion(meals.values.map(\.userId))
        _ = await app.profiles(for: Array(people))
    }

    @discardableResult
    func send(text: String, mealId: UUID?, app: AppModel) async -> Bool {
        do {
            try await app.backend.createPost(groupId: groupId, text: text, mealId: mealId, pick: nil)
            app.backend.logEvent("chat_sent", props: mealId == nil ? nil : ["meal": "true"])
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
    let meal: Meal?
    let mealMissing: Bool
    let replies: [PostComment]
    let reactions: [PostReaction]
    let palette: [UUID: String]
    let onReact: (String, Bool) -> Void
    let onPickReaction: () -> Void
    let onReply: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void
    let onDeleteReply: (PostComment) -> Void
    let onReportReply: (PostComment) -> Void
    let onOpenMeal: (Meal) -> Void
    let onFind: (String) -> Void

    @Environment(AppModel.self) private var app

    /// "I'm in" answers a pick; it isn't shown with the other reactions.
    private var tallies: [ReactionTally] {
        let others = post.pick == nil ? reactions : reactions.filter { $0.emoji != GroupPost.imIn }
        return ReactionTally.tally(others.map { ($0.emoji, $0.userId) }, me: app.myId)
    }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                if isMine { Spacer(minLength: 40) }
                if !isMine {
                    AvatarView(profile: author, size: 30, ring: color)
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                    if !isMine {
                        Text(author?.firstName ?? "Someone")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    if let pick = post.pick {
                        PickTicket(post: post, pick: pick, reactions: reactions, onToggleIn: onReact, onFind: onFind)
                    } else if !post.text.isEmpty {
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
                    if let meal {
                        Button { onOpenMeal(meal) } label: { SharedMealPlate(meal: meal) }
                            .buttonStyle(.plain)
                    } else if mealMissing {
                        Label("This meal isn't available", systemImage: "eye.slash")
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
                if !isMine { Spacer(minLength: 40) }
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
                            Text(reply.authorId == app.myId ? "You" : (app.profile(reply.authorId)?.firstName ?? "Someone"))
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

/// A dinner pick in the chat: a ticket for the restaurant (or the cuisine
/// the globe landed on), with who's in.
struct PickTicket: View {
    let post: GroupPost
    let pick: DinnerPick
    let reactions: [PostReaction]
    let onToggleIn: (String, Bool) -> Void
    let onFind: (String) -> Void

    @Environment(AppModel.self) private var app

    private var ink: Color { StampInk.color(for: pick.cuisineCode) }
    private var inIds: [UUID] { reactions.filter { $0.emoji == GroupPost.imIn }.map(\.userId) }
    private var iAmIn: Bool { app.myId.map(inIds.contains) ?? false }
    /// What the author wrote beyond the generated line.
    private var note: String? {
        let text = post.text.trimmed
        return text.isEmpty || text == pick.fallbackText ? nil : text
    }

    var body: some View {
        TicketCard(stubWidth: 66, stubTint: ink.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 5) {
                Text(pick.hasPlace ? "\(Country.flag(for: pick.cuisineCode)) \(Cuisine.name(for: pick.cuisineCode).uppercased()) · SUGGESTED"
                                   : "🎲 THE GLOBE SAYS")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text(pick.hasPlace ? (pick.placeName ?? "") : "\(Country.flag(for: pick.cuisineCode)) \(Cuisine.name(for: pick.cuisineCode))")
                    .font(.displayXSmall)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                if let address = pick.placeAddress, pick.hasPlace {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onToggleIn(GroupPost.imIn, !iAmIn)
                    } label: {
                        Label(iAmIn ? "You're in" : "I'm in", systemImage: iAmIn ? "checkmark.circle.fill" : "hand.raised")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(iAmIn ? Color.onBrand : Color.brand)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(iAmIn ? Color.brand : Color.brandSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(iAmIn ? "You're in. Tap to drop out." : "I'm in")
                    if !inIds.isEmpty {
                        AvatarStack(profiles: inIds.compactMap { app.profile($0) }, size: 20, max: 4)
                        Text("\(inIds.count) in")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                .padding(.top, 3)
            }
        } stub: {
            Button {
                if pick.hasPlace, pick.hasCoordinate { directions() } else { onFind(pick.cuisineCode) }
            } label: {
                VStack(spacing: 4) {
                    if pick.hasPlace {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(ink)
                        Text("GO")
                    } else {
                        StampBadge(code: pick.cuisineCode, size: 46, inked: false, tasted: true)
                        Text("FIND")
                    }
                }
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pick.hasPlace ? "Directions" : "Find \(Cuisine.name(for: pick.cuisineCode)) near you")
        }
        .frame(maxWidth: 300)
    }

    private func directions() {
        guard let lat = pick.placeLat, let lng = pick.placeLng else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)))
        item.name = pick.placeName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

/// A shared meal in the chat: its plate, what it was, where.
private struct SharedMealPlate: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealPlate(meal: meal, size: 86)
            VStack(alignment: .leading, spacing: 3) {
                Text(meal.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                Text(meal.feedLine)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(10)
        .padding(.trailing, 4)
        .background(Color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
    }
}

/// Pick one of your meals to share.
struct MealPickerSheet: View {
    let onPick: (Meal) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let shareable = app.meals.filter { $0.visibility != .private }
                if shareable.isEmpty {
                    EmptyStateView(systemImage: "fork.knife", title: "Nothing to share yet",
                                   message: "Meals set to Only me can't be shared to a table.")
                        .padding(.top, 60)
                } else {
                    PlateStack(columns: 3, spacing: 10) {
                        ForEach(shareable) { meal in
                            Button {
                                onPick(meal)
                                dismiss()
                            } label: {
                                MealPlate(meal: meal)
                            }
                            .buttonStyle(PressScale())
                        }
                    }
                    .padding(Metrics.gutter)
                }
            }
            .paperBackground()
            .navigationTitle("Share a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
