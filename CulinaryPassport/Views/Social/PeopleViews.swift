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
        return "I'm eating my way around the world on Stampd\(who). Come see how much of the world you've eaten — and spin for dinner with me."
    }

    static func groupInvite(_ group: Group) -> String {
        "Pull up a chair at “\(group.name)” on Stampd — we spin the globe for dinner and eat our way round it together. Tap culinarypassport://join/\(group.inviteCode) or enter the code \(group.inviteCode)."
    }
}

/// Someone else's food passport: who they are, how much of the world they've
/// eaten, and the plates they've shared with you.
struct ProfileView: View {
    let userId: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var profile: Profile?
    @State private var tastes: [Taste] = []
    @State private var meals: [Meal] = []
    @State private var counts: (followers: Int, following: Int) = (0, 0)
    @State private var loaded = false
    @State private var viewing: Meal?
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var selectedCuisine: String?

    private var tasted: Set<String> { Set(tastes.map(\.countryCode)) }
    private var stats: FoodStats { FoodStats(tastes: tastes, meals: meals) }
    private var shared: Int { tasted.intersection(app.tastedCodes).count }
    /// What they've had that you haven't — ideas for dinner.
    private var theyHaveYouHavent: [String] {
        tasted.subtracting(app.tastedCodes).filter(Cuisine.isCuisine).sorted { Cuisine.name(for: $0) < Cuisine.name(for: $1) }
    }

    var body: some View {
        ScrollView {
            if let profile {
                VStack(spacing: 20) {
                    header(profile)
                    globe(profile)
                    if userId != app.myId, !theyHaveYouHavent.isEmpty { ideas(profile) }
                    platesSection
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 24)
            } else if loaded {
                EmptyStateView(systemImage: "lock", title: "Profile unavailable",
                               message: "This profile is private, or they've left Stampd.")
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
                        ShareLink(item: "\(profile?.name ?? "") on Stampd: \(stats.cuisines) cuisines, \(stats.worldPercentText) of the world eaten.") {
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
        .sheet(item: $viewing) { MealDetailView(meal: $0) }
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
                .overlay(Circle().strokeBorder(Color.card, lineWidth: 4))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
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
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            HStack(spacing: 0) {
                StatTile(value: "\(stats.cuisines)", label: "Cuisines")
                StatTile(value: stats.worldPercentText, label: "Of the world")
                StatTile(value: "\(counts.followers)", label: "Followers")
                StatTile(value: "\(counts.following)", label: "Following")
            }
            .padding(.top, 4)
            if userId != app.myId {
                FollowButton(userId: userId)
            }
            if userId != app.myId, shared > 0 {
                Pill(systemImage: "fork.knife", text: "You've both had \(shared.counted("cuisine"))",
                     tint: .brand, background: .brandSoft)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func globe(_ profile: Profile) -> some View {
        let tint = UIColor(hex: profile.color) ?? Palette.brand
        let style = GlobeStyle(scheme)
        let tasted = self.tasted
        return VStack(spacing: 10) {
            ZStack {
                Plate(rim: 0.15, band: .clear) {
                    GlobeCanvas(
                        style: style,
                        color: { code, isSelected in
                            tasted.contains(code)
                                ? style.tasted(tint, meals: 1, selected: isSelected)
                                : style.untouched(selected: isSelected)
                        },
                        selected: $selectedCuisine,
                        isEmphasized: { tasted.contains($0) },
                        fitMargin: 1.05
                    )
                }
                ContinentRim(progress: FoodStats.continentProgress(tasted), tint: Color(uiColor: tint))
            }
            .frame(maxWidth: 340)
            if let code = selectedCuisine {
                HStack {
                    Text("\(Country.flag(for: code)) \(Cuisine.name(for: code))").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(tasted.contains(code) ? "\(profile.firstName)'s had it" : "Not yet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tasted.contains(code) ? Color.brand : Color.inkSecondary)
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
        }
    }

    private func ideas(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("\(profile.firstName)'s had, you haven't", subtitle: theyHaveYouHavent.count.counted("cuisine"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(theyHaveYouHavent.prefix(20), id: \.self) { code in
                        StampBadge(code: code, size: 84, inked: false, tasted: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var platesSection: some View {
        if !meals.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Plates", subtitle: "\(meals.count) shared with you")
                PlateStack(columns: 3, spacing: 10) {
                    ForEach(meals.prefix(30)) { meal in
                        Button { viewing = meal } label: { MealPlate(meal: meal) }
                            .buttonStyle(PressScale())
                    }
                }
            }
        } else if loaded, profile != nil {
            Text("No meals shared with you yet.")
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
        async let fetchedTastes = try? backend.tastes(userIds: [id])
        async let fetchedMeals = try? backend.meals(userId: id)
        async let fetchedCounts = try? backend.followCounts(userId: id)
        let (p, t, m, c) = await (fetchedProfile, fetchedTastes, fetchedMeals, fetchedCounts)
        if let p { profile = p; app.people[p.id] = p }
        tastes = t ?? []
        meals = m ?? []
        counts = c ?? (0, 0)
        loaded = true
    }
}
