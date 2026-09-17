import SwiftUI

/// Where your people have been lately — and, one tab over, the public
/// travels of everyone else.
struct FriendsView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case friends = "Friends"
        case discover = "Discover"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @State private var segment: Segment = .friends
    @State private var friends = FeedModel(kind: .friends)
    @State private var discover = FeedModel(kind: .discover)
    @State private var viewing: Memory?
    @State private var profileId: UUID?
    @State private var showActivity = false
    @State private var showSearch = false

    private var feed: FeedModel { segment == .friends ? friends : discover }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    Picker("Feed", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if segment == .friends && !friends.newStamps.isEmpty {
                        newStampsStrip
                    }

                    content
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 24)
            }
            .paperBackground()
            .refreshable { await feed.refresh(app: app) }
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Find people")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showActivity = true } label: {
                        Image(systemName: app.unseenActivity > 0 ? "bell.badge" : "bell")
                            .symbolRenderingMode(app.unseenActivity > 0 ? .multicolor : .monochrome)
                    }
                    .accessibilityLabel(app.unseenActivity > 0 ? "Activity, \(app.unseenActivity) new" : "Activity")
                }
            }
            .navigationDestination(item: $profileId) { ProfileView(userId: $0) }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .sheet(isPresented: $showActivity, onDismiss: { app.markActivitySeen() }) {
                ActivityView()
            }
            .sheet(isPresented: $showSearch) { PeopleSearchView() }
            .task(id: segment) {
                if !feed.loaded { await feed.refresh(app: app) }
            }
            .onChange(of: app.following) {
                // New follows change what belongs in the feed.
                Task { await friends.refresh(app: app) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !feed.loaded && feed.items.isEmpty {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { SkeletonBlock(cornerRadius: 19).frame(width: 38, height: 38); SkeletonBlock().frame(width: 140, height: 14) }
                    SkeletonBlock().aspectRatio(4.0 / 5.0, contentMode: .fit)
                }
                .card(padding: 14)
            }
        } else if feed.visible(app: app).isEmpty {
            emptyState.padding(.top, 50)
        } else {
            ForEach(feed.visible(app: app)) { memory in
                MemoryCard(
                    memory: memory,
                    author: app.profile(memory.userId),
                    tallies: feed.tallies(for: memory.id, me: app.myId),
                    commentCount: feed.commentCounts[memory.id] ?? 0,
                    badge: feed.firstVisitBadge(for: memory),
                    onOpen: { viewing = memory },
                    onOpenAuthor: { profileId = memory.userId },
                    onReact: { emoji, on in Task { await feed.react(memory.id, emoji: emoji, on: on, app: app) } }
                )
                .onAppear {
                    if memory.id == feed.items.last?.id { Task { await feed.loadMore(app: app) } }
                }
            }
            if feed.loadingMore {
                ProgressView().padding()
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch segment {
        case .friends:
            if app.following.isEmpty && app.groups.isEmpty {
                EmptyStateView(systemImage: "person.2",
                               title: "Travel's better with friends",
                               message: "Follow friends to see their trips here — and when they follow you back, you'll see each other's friends-only memories.",
                               primaryTitle: "Find friends",
                               primaryAction: { showSearch = true })
            } else {
                EmptyStateView(systemImage: "airplane.departure",
                               title: "Quiet skies",
                               message: "Nobody you follow has posted a memory yet. Share one of yours to get things going.")
            }
        case .discover:
            EmptyStateView(systemImage: "sparkles",
                           title: "Nothing to discover yet",
                           message: "Public memories from travellers everywhere will appear here.")
        }
    }

    private var newStampsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "New stamps")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(friends.newStamps) { stamp in
                        Button { profileId = stamp.userId } label: {
                            HStack(spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    AvatarView(profile: app.profile(stamp.userId), size: 40)
                                    Text(Country.flag(for: stamp.countryCode))
                                        .font(.system(size: 17))
                                        .offset(x: 5, y: 4)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.profile(stamp.userId)?.firstName ?? "Friend")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                    Text("\(stamp.country?.name ?? stamp.countryCode) · \(RelativeTime.short(stamp.createdAt))")
                                        .font(.caption)
                                        .foregroundStyle(Color.inkSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 14)
                            .padding(.vertical, 9)
                            .background(Color.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// One feed's items, reactions and paging.
@MainActor
@Observable
final class FeedModel {
    enum Kind { case friends, discover }

    let kind: Kind
    var items: [Memory] = []
    var reactions: [UUID: [Reaction]] = [:]
    var commentCounts: [UUID: Int] = [:]
    var newStamps: [Stamp] = []
    /// Stamps of authors, to badge a memory as their first time in a country.
    var authorStamps: [String: Stamp] = [:]
    var loaded = false
    var loadingMore = false
    var exhausted = false

    private let pageSize = 20

    init(kind: Kind) { self.kind = kind }

    func visible(app: AppModel) -> [Memory] {
        items.filter { memory in
            guard !app.blocked.contains(memory.userId) else { return false }
            if kind == .discover { return app.profile(memory.userId)?.isPublic == true }
            return true
        }
    }

    func refresh(app: AppModel) async {
        do {
            let page = try await fetch(app: app, before: nil)
            items = page
            exhausted = page.count < pageSize
            await decorate(page, app: app, replacing: true)
            if kind == .friends {
                let recent = (try? await app.backend.recentStamps(userIds: Array(app.networkIds), limit: 30)) ?? []
                _ = await app.profiles(for: recent.map(\.userId))
                // One chip per person+week so a photo import of 14 countries
                // doesn't flood the strip.
                var seen = Set<String>()
                newStamps = recent.filter { stamp in
                    guard Date().timeIntervalSince(stamp.createdAt) < 14 * 86_400,
                          !app.blocked.contains(stamp.userId) else { return false }
                    let week = Int(stamp.createdAt.timeIntervalSince1970 / (7 * 86_400))
                    return seen.insert("\(stamp.userId)|\(week)|\(stamp.source == .photos ? "bulk" : stamp.countryCode)").inserted
                }
            }
        } catch {
            if !(error is CancellationError) { app.show(error) }
        }
        loaded = true
    }

    func loadMore(app: AppModel) async {
        guard loaded, !loadingMore, !exhausted, let last = items.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await fetch(app: app, before: last.createdAt) else { return }
        let known = Set(items.map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        items += fresh
        exhausted = page.count < pageSize
        await decorate(fresh, app: app, replacing: false)
    }

    private func fetch(app: AppModel, before: Date?) async throws -> [Memory] {
        switch kind {
        case .friends: try await app.backend.friendsFeed(before: before, limit: pageSize)
        case .discover: try await app.backend.discoverFeed(before: before, limit: pageSize)
        }
    }

    private func decorate(_ page: [Memory], app: AppModel, replacing: Bool) async {
        let ids = page.map(\.id)
        _ = await app.profiles(for: page.map(\.userId))
        let fetchedReactions = (try? await app.backend.reactions(memoryIds: ids)) ?? []
        let counts = (try? await app.backend.commentCounts(memoryIds: ids)) ?? [:]
        let grouped = Dictionary(grouping: fetchedReactions, by: \.entryId)
        if replacing {
            reactions = grouped
            commentCounts = counts
        } else {
            reactions.merge(grouped) { _, new in new }
            commentCounts.merge(counts) { _, new in new }
        }
        let authors = Array(Set(page.map(\.userId)))
        if let stamps = try? await app.backend.stamps(userIds: authors) {
            for stamp in stamps { authorStamps["\(stamp.userId)|\(stamp.countryCode)"] = stamp }
        }
    }

    func tallies(for id: UUID, me: UUID?) -> [ReactionTally] {
        ReactionTally.tally((reactions[id] ?? []).map { ($0.emoji, $0.userId) }, me: me)
    }

    /// "New stamp" when this memory is the author's first visit to the country.
    func firstVisitBadge(for memory: Memory) -> String? {
        guard let stamp = authorStamps["\(memory.userId)|\(memory.countryCode)"],
              stamp.firstVisited == memory.date,
              Date().timeIntervalSince(memory.createdAt) < 30 * 86_400 else { return nil }
        return "New stamp"
    }

    func react(_ memoryId: UUID, emoji: String, on: Bool, app: AppModel) async {
        guard let me = app.myId else { return }
        let before = reactions[memoryId] ?? []
        var next = before.filter { !($0.userId == me && $0.emoji == emoji) }
        if on { next.append(Reaction(entryId: memoryId, userId: me, emoji: emoji, createdAt: Date())) }
        reactions[memoryId] = next
        do {
            try await app.backend.setReaction(memoryId: memoryId, emoji: emoji, on: on)
        } catch {
            reactions[memoryId] = before
            app.show(error)
        }
    }
}

/// Follows, reactions and comments aimed at you.
struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ActivityRow] = []
    @State private var memories: [UUID: Memory] = [:]
    @State private var loaded = false
    /// Captured before marking seen, so the unseen dots actually show. (The
    /// old view overwrote last-seen before rows rendered — dots never appeared.)
    @State private var seenBefore = Date.distantPast
    @State private var viewing: Memory?

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows.filter { !app.blocked.contains($0.actorId) }) { row in
                    rowView(row)
                        .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .overlay {
                if !loaded {
                    ProgressView()
                } else if rows.isEmpty {
                    EmptyStateView(systemImage: "bell", title: "Nothing yet",
                                   message: "New followers, reactions and comments on your memories show up here.")
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: UUID.self) { ProfileView(userId: $0) }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .task {
                seenBefore = app.activityLastSeen
                rows = (try? await app.backend.activity(limit: 80)) ?? []
                _ = await app.profiles(for: rows.map(\.actorId))
                let ids = Array(Set(rows.compactMap(\.entryId)))
                let fetched = (try? await app.backend.memories(ids: ids)) ?? []
                memories = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
                loaded = true
                app.markActivitySeen()
            }
        }
    }

    @ViewBuilder private func rowView(_ row: ActivityRow) -> some View {
        let actor = app.profile(row.actorId)
        let memory = row.entryId.flatMap { memories[$0] }
        let content = HStack(spacing: 12) {
            AvatarView(profile: actor, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                SwiftUI.Group {
                    switch row.kind {
                    case .follow:
                        Text("\(Text(actor?.name ?? "Someone").bold()) started following you")
                    case .reaction:
                        Text("\(Text(actor?.name ?? "Someone").bold()) reacted \(row.emoji ?? "") to \(memory?.displayTitle ?? "your memory")")
                    case .comment:
                        Text("\(Text(actor?.name ?? "Someone").bold()) commented: \(row.body ?? "")")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                Text(RelativeTime.short(row.createdAt))
                    .font(.caption)
                    .foregroundStyle(Color.inkTertiary)
            }
            Spacer(minLength: 4)
            if let memory, let first = memory.photos.first {
                StoragePhoto(path: first, maxPixel: 200)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if row.createdAt > seenBefore {
                Circle().fill(Color.stampRed).frame(width: 8, height: 8)
                    .accessibilityLabel("New")
            }
        }
        .padding(.vertical, 2)

        if let memory {
            Button { viewing = memory } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: row.actorId) { content }
        }
    }
}
