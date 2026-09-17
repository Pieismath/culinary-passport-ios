import SwiftUI

/// Find people to follow: search public profiles, or pick from the people
/// already in your groups. Invite anyone who isn't here yet.
struct PeopleSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    private var suggestions: [Profile] {
        app.groupMateIds.subtracting(app.following).subtracting(app.blocked)
            .compactMap { app.profile($0) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmed.count < 2 {
                    Section {
                        ShareLink(item: AppLinks.inviteText(from: app.me)) {
                            Label("Invite friends to Stampd", systemImage: "paperplane.fill")
                                .foregroundStyle(Color.brand)
                        }
                        .listRowBackground(Color.card)
                    }
                    if !suggestions.isEmpty {
                        Section("From your groups") {
                            ForEach(suggestions) { row($0) }
                        }
                    }
                } else {
                    Section {
                        ForEach(results.filter { !app.blocked.contains($0.id) && $0.id != app.myId }) { row($0) }
                    }
                }
            }
            .paperListStyle()
            .overlay {
                if query.trimmed.count >= 2 && !searching && results.isEmpty {
                    ContentUnavailableView("No one found", systemImage: "person.crop.circle.badge.questionmark",
                                           description: Text("Search by name or @username. Private profiles don't appear."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or @username")
            .onChange(of: query) { _, text in scheduleSearch(text) }
            .navigationTitle("Find people")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { ProfileView(userId: $0) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ person: Profile) -> some View {
        NavigationLink(value: person.id) {
            HStack(spacing: 12) {
                AvatarView(profile: person, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.headline).foregroundStyle(Color.ink)
                    if let handle = person.handle {
                        Text(handle).font(.caption).foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer()
                FollowButton(userId: person.id)
            }
        }
        .listRowBackground(Color.card)
    }

    /// Debounced, and a late response can never overwrite a newer query's.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let term = text.trimmed
        guard term.count >= 2 else {
            results = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await app.backend.searchProfiles(term)) ?? []
            guard !Task.isCancelled, term == query.trimmed else { return }
            results = found
            searching = false
        }
    }
}

/// Follow / Following / Friends, reflecting the mutual relationship.
struct FollowButton: View {
    let userId: UUID
    @Environment(AppModel.self) private var app

    private var following: Bool { app.following.contains(userId) }
    private var followsYou: Bool { app.followers.contains(userId) }

    var body: some View {
        if userId == app.myId {
            EmptyView()
        } else if following {
            Menu {
                Button(role: .destructive) { app.setFollowing(userId, false) } label: {
                    Label("Unfollow", systemImage: "person.badge.minus")
                }
            } label: {
                Label(followsYou ? "Friends" : "Following",
                      systemImage: followsYou ? "person.2.fill" : "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Color.sunken, in: Capsule())
            }
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                app.setFollowing(userId, true)
            } label: {
                Text(followsYou ? "Follow back" : "Follow")
            }
            .buttonStyle(.capsuleProminent)
        }
    }
}

enum AppLinks {
    static func inviteText(from me: Profile?) -> String {
        let who = me?.handle.map { " — I'm \($0)" } ?? ""
        return "I'm mapping everywhere I've been on Stampd, the travel passport app\(who). Come compare passports!"
    }

    static func groupInvite(_ group: Group) -> String {
        "Join “\(group.name)” on Stampd — we're sharing one globe. Tap culinarypassport://join/\(group.inviteCode) or enter the code \(group.inviteCode)."
    }
}

/// Someone else's passport: who they are, where they've been, what they saw.
struct ProfileView: View {
    let userId: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var profile: Profile?
    @State private var stamps: [Stamp] = []
    @State private var memories: [Memory] = []
    @State private var counts: (followers: Int, following: Int) = (0, 0)
    @State private var loaded = false
    @State private var viewing: Memory?
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var selectedCountry: String?

    private var visited: Set<String> { Set(stamps.map(\.countryCode)) }
    private var stats: TravelStats { TravelStats(stamps: stamps, memories: memories) }
    private var shared: Int { visited.intersection(app.visitedCodes).count }

    var body: some View {
        ScrollView {
            if let profile {
                VStack(spacing: 18) {
                    header(profile)
                    globeCard(profile)
                    if !stamps.isEmpty { stampsCard }
                    memoriesSection
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 24)
            } else if loaded {
                EmptyStateView(systemImage: "lock", title: "Profile unavailable",
                               message: "This traveller's profile is private, or they've left Stampd.")
                    .padding(.top, 80)
            } else {
                ProgressView().padding(.top, 120)
            }
        }
        .paperBackground()
        .navigationTitle(profile?.handle ?? profile?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if userId != app.myId, profile != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: "\(profile?.name ?? "") on Stampd: \(stats.countries) countries so far.") {
                            Label("Share profile", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { reporting = true } label: {
                            Label("Report", systemImage: "flag")
                        }
                        if app.blocked.contains(userId) {
                            Button { Task { await app.unblock(userId) } } label: {
                                Label("Unblock", systemImage: "hand.raised.slash")
                            }
                        } else {
                            Button(role: .destructive) { confirmBlock = true } label: {
                                Label("Block", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
        .sheet(isPresented: $reporting) {
            ReportSheet(title: "Report profile") { reason in
                Task { await app.report("profile", id: userId, reason: reason) }
            }
        }
        .confirmationDialog("Block \(profile?.name ?? "this person")?", isPresented: $confirmBlock,
                            titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await app.block(userId) } }
        } message: {
            Text("They won't appear in your feeds or search, and you'll stop following them.")
        }
        .task { await load() }
    }

    private func header(_ profile: Profile) -> some View {
        VStack(spacing: 12) {
            AvatarView(profile: profile, size: 96)
            VStack(spacing: 4) {
                Text(profile.name).font(.displaySmall).foregroundStyle(Color.ink)
                HStack(spacing: 6) {
                    if let handle = profile.handle { Text(handle) }
                    if let home = profile.homeCountry, let country = CountryStore.byCode[home] {
                        Text("· \(country.flag) \(profile.homeCity.flatMap { $0.isEmpty ? nil : $0 } ?? country.name)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            HStack(spacing: 0) {
                StatTile(value: "\(stats.countries)", label: "Countries")
                StatTile(value: "\(stats.continents)", label: "Continents")
                StatTile(value: "\(counts.followers)", label: "Followers")
                StatTile(value: "\(counts.following)", label: "Following")
            }
            .padding(.top, 4)
            if userId != app.myId {
                FollowButton(userId: userId)
            }
            if userId != app.myId, shared > 0 {
                Pill(systemImage: "sparkles", text: "You've both been to \(shared) countr\(shared == 1 ? "y" : "ies")",
                     tint: .brand, background: .brandSoft)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func globeCard(_ profile: Profile) -> some View {
        let tint = UIColor(hex: profile.color) ?? Palette.brand
        let style = GlobeStyle(scheme)
        let visited = self.visited
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("\(profile.firstName)'s globe", subtitle: "\(stats.worldPercentText) of the world")
            GlobeCanvas(
                style: style,
                color: { code, isSelected in
                    visited.contains(code)
                        ? style.visited(tint, memories: 1, selected: isSelected)
                        : style.untouched(selected: isSelected)
                },
                selected: $selectedCountry,
                isEmphasized: { visited.contains($0) }
            )
            .frame(height: 300)
            if let code = selectedCountry, let country = CountryStore.byCode[code] {
                HStack {
                    Text("\(country.flag) \(country.name)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(visited.contains(code) ? "Visited" : "Not yet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(visited.contains(code) ? Color.brand : Color.inkSecondary)
                }
                .transition(.opacity)
            }
        }
        .card()
    }

    private var stampsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Stamps", subtitle: "\(stamps.count) places")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(stamps.sorted { ($0.firstVisited ?? "") > ($1.firstVisited ?? "") }) { stamp in
                        StampBadge(code: stamp.countryCode, subtitle: stamp.yearsText, size: 86)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .card()
    }

    @ViewBuilder private var memoriesSection: some View {
        if !memories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Memories", subtitle: "\(memories.count) shared with you")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(memories) { memory in
                        Button { viewing = memory } label: { MemoryTile(memory: memory) }
                            .buttonStyle(.plain)
                    }
                }
            }
        } else if loaded, profile != nil {
            Text("No memories shared with you yet.")
                .font(.subheadline)
                .foregroundStyle(Color.inkTertiary)
                .padding(.top, 8)
        }
    }

    private func load() async {
        if let cached = app.profile(userId) { profile = cached }
        let backend = app.backend
        let id = userId
        async let fetchedProfile = try? backend.profile(id: id)
        async let fetchedStamps = try? backend.stamps(userIds: [id])
        async let fetchedMemories = try? backend.memories(userId: id)
        async let fetchedCounts = try? backend.followCounts(userId: id)
        let (p, s, m, c) = await (fetchedProfile, fetchedStamps, fetchedMemories, fetchedCounts)
        if let p { profile = p; app.people[p.id] = p }
        stamps = s ?? []
        memories = m ?? []
        counts = c ?? (0, 0)
        loaded = true
    }
}
