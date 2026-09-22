import SwiftUI

/// What your people have eaten lately — and, one segment over, the public
/// plates of everyone else. Opened from Tables.
struct FriendsFeedView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case friends = "Friends"
        case discover = "Discover"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @State private var segment: Segment = .friends
    @State private var friends = FeedModel(kind: .friends)
    @State private var discover = FeedModel(kind: .discover)
    @State private var viewing: Meal?
    @State private var profileId: UUID?
    @State private var showSearch = false

    private var feed: FeedModel { segment == .friends ? friends : discover }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Picker("Feed", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if segment == .friends && !friends.newTastes.isEmpty {
                    newTastesStrip
                }

                content
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 24)
        }
        .paperBackground()
        .refreshable { await feed.refresh(app: app) }
        .navigationTitle("Friends' plates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Find people")
            }
        }
        .navigationDestination(item: $profileId) { ProfileView(userId: $0) }
        .sheet(item: $viewing) { MealDetailView(meal: $0) }
        .sheet(isPresented: $showSearch) { PeopleSearchView() }
        .task(id: segment) {
            if !feed.loaded { await feed.refresh(app: app) }
        }
        .onChange(of: app.following) {
            Task { await friends.refresh(app: app) }
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
            ForEach(feed.visible(app: app)) { meal in
                MealCard(
                    meal: meal,
                    author: app.profile(meal.userId),
                    tallies: feed.tallies(for: meal.id, me: app.myId),
                    commentCount: feed.commentCounts[meal.id] ?? 0,
                    badge: feed.firstTasteBadge(for: meal),
                    onOpen: { viewing = meal },
                    onOpenAuthor: { profileId = meal.userId },
                    onReact: { emoji, on in Task { await feed.react(meal.id, emoji: emoji, on: on, app: app) } }
                )
            }
            // Paging sentinel. Keyed by page size so it re-appears after each
            // load; watching the last *item* stalled when that item was
            // filtered out (blocked author, private profile in Discover).
            if !feed.exhausted {
                ProgressView()
                    .padding()
                    .id(feed.items.count)
                    .onAppear { Task { await feed.loadMore(app: app) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch segment {
        case .friends:
            if app.following.isEmpty && app.groups.isEmpty {
                EmptyStateView(systemImage: "person.2",
                               title: "Dinner's better with friends",
                               message: "Follow friends to see what they're eating — and when they follow you back, you'll see each other's friends-only meals.",
                               primaryTitle: "Find friends",
                               primaryAction: { showSearch = true })
            } else {
                EmptyStateView(systemImage: "fork.knife",
                               title: "Nothing on the table yet",
                               message: "Nobody you follow has logged a meal yet. Log one of yours to get things going.")
            }
        case .discover:
            EmptyStateView(systemImage: "sparkles",
                           title: "Nothing to discover yet",
                           message: "Public meals from people everywhere will appear here.")
        }
    }

    private var newTastesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "New cuisines")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(friends.newTastes) { taste in
                        Button { profileId = taste.userId } label: {
                            HStack(spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    AvatarView(profile: app.profile(taste.userId), size: 40)
                                    Text(Country.flag(for: taste.countryCode))
                                        .font(.system(size: 17))
                                        .offset(x: 5, y: 4)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.profile(taste.userId)?.firstName ?? "Friend")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                    Text("\(taste.cuisine) · \(RelativeTime.short(taste.createdAt))")
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

/// One feed's meals, reactions and paging.
@MainActor
@Observable
final class FeedModel {
    enum Kind { case friends, discover }

    let kind: Kind
    var items: [Meal] = []
    var reactions: [UUID: [Reaction]] = [:]
    var commentCounts: [UUID: Int] = [:]
    /// "Maya tasted Senegalese" — friends' first tastes lately.
    var newTastes: [Taste] = []
    /// Authors' tastes, to badge a meal as their first of a cuisine.
    var authorTastes: [String: Taste] = [:]
    var loaded = false
    var loadingMore = false
    var exhausted = false

    private let pageSize = 20

    init(kind: Kind) { self.kind = kind }

    func visible(app: AppModel) -> [Meal] {
        items.filter { meal in
            guard !app.blocked.contains(meal.userId) else { return false }
            if kind == .discover { return app.profile(meal.userId)?.isPublic == true }
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
                let recent = (try? await app.backend.recentTastes(userIds: Array(app.networkIds), limit: 30)) ?? []
                _ = await app.profiles(for: recent.map(\.userId))
                // One chip per person a week, so ticking twenty cuisines at
                // once doesn't flood the strip.
                var seen = Set<String>()
                newTastes = recent.filter { taste in
                    guard Date().timeIntervalSince(taste.createdAt) < 14 * 86_400,
                          !app.blocked.contains(taste.userId) else { return false }
                    let week = Int(taste.createdAt.timeIntervalSince1970 / (7 * 86_400))
                    return seen.insert("\(taste.userId)|\(week)|\(taste.source == .manual ? "ticked" : taste.countryCode)").inserted
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

    private func fetch(app: AppModel, before: Date?) async throws -> [Meal] {
        switch kind {
        case .friends: try await app.backend.friendsFeed(before: before, limit: pageSize)
        case .discover: try await app.backend.discoverFeed(before: before, limit: pageSize)
        }
    }

    private func decorate(_ page: [Meal], app: AppModel, replacing: Bool) async {
        let ids = page.map(\.id)
        _ = await app.profiles(for: page.map(\.userId))
        let fetchedReactions = (try? await app.backend.reactions(mealIds: ids)) ?? []
        let counts = (try? await app.backend.commentCounts(mealIds: ids)) ?? [:]
        let grouped = Dictionary(grouping: fetchedReactions, by: \.entryId)
        if replacing {
            reactions = grouped
            commentCounts = counts
        } else {
            reactions.merge(grouped) { _, new in new }
            commentCounts.merge(counts) { _, new in new }
        }
        let cooks = Array(Set(page.map(\.userId)))
        if !cooks.isEmpty, let tastes = try? await app.backend.tastes(userIds: cooks) {
            for taste in tastes { authorTastes["\(taste.userId)|\(taste.countryCode)"] = taste }
        }
    }

    func tallies(for id: UUID, me: UUID?) -> [ReactionTally] {
        ReactionTally.tally((reactions[id] ?? []).map { ($0.emoji, $0.userId) }, me: me)
    }

    /// "First taste" when this meal is the author's first of its cuisine.
    func firstTasteBadge(for meal: Meal) -> String? {
        guard let taste = authorTastes["\(meal.userId)|\(meal.countryCode)"],
              taste.firstTasted == meal.date,
              Date().timeIntervalSince(meal.createdAt) < 30 * 86_400 else { return nil }
        return "First taste"
    }

    func react(_ mealId: UUID, emoji: String, on: Bool, app: AppModel) async {
        guard let me = app.myId else { return }
        let before = reactions[mealId] ?? []
        var next = before.filter { !($0.userId == me && $0.emoji == emoji) }
        if on { next.append(Reaction(entryId: mealId, userId: me, emoji: emoji, createdAt: Date())) }
        reactions[mealId] = next
        do {
            try await app.backend.setReaction(mealId: mealId, emoji: emoji, on: on)
        } catch {
            reactions[mealId] = before
            app.show(error)
        }
    }
}

/// Follows, reactions and comments aimed at you.
struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ActivityRow] = []
    @State private var meals: [UUID: Meal] = [:]
    @State private var loaded = false
    /// Captured before marking seen, so the unseen dots actually show.
    @State private var seenBefore = Date.distantPast
    @State private var viewing: Meal?

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
                                   message: "New followers, reactions and comments on your meals show up here.")
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: UUID.self) { ProfileView(userId: $0) }
            .sheet(item: $viewing) { MealDetailView(meal: $0) }
            .task {
                seenBefore = app.activityLastSeen
                rows = (try? await app.backend.activity(limit: 80)) ?? []
                _ = await app.profiles(for: rows.map(\.actorId))
                let ids = Array(Set(rows.compactMap(\.entryId)))
                let fetched = (try? await app.backend.meals(ids: ids)) ?? []
                meals = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
                loaded = true
                app.markActivitySeen()
            }
        }
    }

    @ViewBuilder private func rowView(_ row: ActivityRow) -> some View {
        let actor = app.profile(row.actorId)
        let meal = row.entryId.flatMap { meals[$0] }
        let content = HStack(spacing: 12) {
            AvatarView(profile: actor, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                SwiftUI.Group {
                    switch row.kind {
                    case .follow:
                        Text("\(Text(actor?.name ?? "Someone").bold()) started following you")
                    case .reaction:
                        Text("\(Text(actor?.name ?? "Someone").bold()) reacted \(row.emoji ?? "") to \(meal?.displayTitle ?? "your meal")")
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
            if let meal {
                MealPlate(meal: meal, size: 46, showsFlag: false)
            }
            if row.createdAt > seenBefore {
                Circle().fill(Color.stampRed).frame(width: 8, height: 8)
                    .accessibilityLabel("New")
            }
        }
        .padding(.vertical, 2)

        if let meal {
            Button { viewing = meal } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: row.actorId) { content }
        }
    }
}
