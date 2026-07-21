import SwiftUI
import PhotosUI

/// Your profile: photo, identity, and the numbers worth bragging about.
/// The avatar is a photo you pick — the AI selfie→portrait pipeline was
/// retired (per-user API cost, and a stylized face isn't what this app is).
struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?
    @State private var profile: Profile?
    @State private var showEdit = false
    @State private var sheet: ProfileSheet?
    @State private var entries: [Entry] = []
    @State private var insights = Insights()
    @State private var follows: (followers: Int, following: Int) = (0, 0)

    enum ProfileSheet: String, Identifiable {
        case followers, following, cuisines
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    worldCard
                    insightCards
                    actionRows
                    signOut
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            // Reload whenever the session changes. `.task` alone fires once on
            // appear, which can lose a race with sign-in (or an expired token
            // being refreshed) and leave the screen showing zeros forever.
            .task {
                for await state in SupabaseService.shared.client.auth.authStateChanges
                where state.session != nil {
                    await load()
                }
            }
            .onChange(of: pickedItem) { Task { await uploadPhoto() } }
            .sheet(isPresented: $showEdit) {
                if let profile {
                    ProfileEditSheet(profile: profile) { await load() }
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .followers:
                    PeopleListSheet(title: "Followers", ids: { try await SupabaseService.shared.followerIds(userId: $0) },
                                    userId: profile?.id)
                case .following:
                    PeopleListSheet(title: "Following", ids: { try await SupabaseService.shared.followingIds(userId: $0) },
                                    userId: profile?.id)
                case .cuisines:
                    CuisineListSheet(entries: entries)
                }
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ProfilePhotoView(url: avatarURL, size: 104)
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                    .overlay {
                        if busy {
                            ZStack {
                                Circle().fill(.black.opacity(0.35))
                                ProgressView().tint(.white)
                            }
                        }
                    }

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                }
                .disabled(busy)
                .accessibilityLabel("Change profile photo")
            }
            .padding(.top, 6)

            VStack(spacing: 2) {
                Text(profile?.name ?? " ").font(.title3.bold())
                if let username = profile?.username, !username.isEmpty {
                    Text("@\(username)").font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
                if let since = profile?.createdAt {
                    Text("Member since \(since.formatted(.dateTime.month(.wide).year()))")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }

            HStack(spacing: 0) {
                CountColumn(value: follows.followers, label: "Followers") { sheet = .followers }
                CountColumn(value: follows.following, label: "Following") { sheet = .following }
                CountColumn(value: insights.countries, label: "Cuisines") { sheet = .cuisines }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button { showEdit = true } label: {
                    Text("Edit profile").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                ShareLink(item: shareText) {
                    Text("Share profile").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var shareText: String {
        let handle = profile?.username.map { "@\($0)" } ?? profile?.name ?? "me"
        return "\(handle) has eaten \(insights.countries) of the world's cuisines on Culinary Passport."
    }

    // ── How much of the world you've eaten ───────────────────────────────────

    private var worldCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("World eaten").font(.subheadline.weight(.semibold))
                Spacer()
                Text(insights.percentText)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * insights.fraction))
                }
            }
            .frame(height: 8)

            Text("\(insights.countries) of \(CountryStore.all.count) cuisines · \(insights.meals) meals · \(insights.continents) of 6 continents")
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // ── The two facts people actually want to see ────────────────────────────

    private var insightCards: some View {
        HStack(spacing: 10) {
            InsightCard(
                caption: "Go-to cuisine",
                headline: insights.topCuisine.map { "\($0.flag) \($0.name)" } ?? "—",
                detail: insights.topCuisine.map {
                    "\($0.count) meal\($0.count == 1 ? "" : "s") · ★\(String(format: "%.1f", $0.avgRating))"
                } ?? "Log a few meals"
            )
            InsightCard(
                caption: insights.second?.caption ?? "Rarest find",
                headline: insights.second.map { "\($0.cuisine.flag) \($0.cuisine.name)" } ?? "—",
                detail: insights.second?.detail ?? "Try somewhere unexpected"
            )
        }
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            NavigationLink {
                CuisineSuggestionsView(entries: entries)
            } label: {
                ActionRow(icon: "sparkle.magnifyingglass", tint: .teal, title: "Recommended for you")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            NavigationLink {
                WrappedView()
            } label: {
                ActionRow(image: "feature-rewind", tint: .pink, title: "Year in review")
            }
            .buttonStyle(.plain)
        }
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var signOut: some View {
        Button {
            Task { try? await SupabaseService.shared.client.auth.signOut() }
        } label: {
            Text("Sign out")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .padding(.top, 10)
    }

    // ── Data ─────────────────────────────────────────────────────────────────

    private func load() async {
        do {
            guard let me = try await SupabaseService.shared.myProfile() else {
                // Profile row is gone (deleted user / stale session) — sign out.
                await SupabaseService.shared.signOut()
                return
            }
            profile = me
            avatarURL = me.avatarUrl.flatMap(URL.init)
            follows = (try? await SupabaseService.shared.followCounts(userId: me.id)) ?? (0, 0)
            // RLS also returns group-shared entries; these numbers are MINE.
            entries = ((try? await SupabaseService.shared.myEntries()) ?? [])
                .filter { $0.userId == me.id }
            insights = Insights(entries: entries)
        } catch {
            // Transient load failure — leave the screen as-is (don't sign out).
        }
    }

    private func uploadPhoto() async {
        guard let pickedItem else { return }
        busy = true
        defer { busy = false; self.pickedItem = nil }
        do {
            guard let data = try await pickedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = ImageTools.squareJPEG(image, side: 512) else {
                status = "Couldn't read that photo"
                return
            }
            let url = try await SupabaseService.shared.uploadAvatar(jpeg)
            // Bust AsyncImage's cache: a new path each upload already differs,
            // but this also survives an identical re-pick.
            avatarURL = URL(string: "\(url)?v=\(Int(Date().timeIntervalSince1970))")
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

// ── Insights ────────────────────────────────────────────────────────────────

struct Insights {
    struct Cuisine { let code: String; let flag: String; let name: String; let count: Int; let avgRating: Double }

    var meals = 0
    var countries = 0
    var continents = 0
    var rare = 0
    var topCuisine: Cuisine?
    /// The second card — always a DIFFERENT cuisine from the first, so the two
    /// never show the same country: a rare find if there is one, otherwise the
    /// best-rated of the rest.
    var second: (caption: String, cuisine: Cuisine, detail: String)?

    var fraction: Double {
        guard CountryStore.all.count > 0 else { return 0 }
        return min(1, Double(countries) / Double(CountryStore.all.count))
    }

    var percentText: String {
        let pct = fraction * 100
        return pct > 0 && pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
    }

    init() {}

    init(entries: [Entry]) {
        meals = entries.count
        let byCountry = Dictionary(grouping: entries, by: \.countryCode)
        countries = byCountry.count
        continents = Set(byCountry.keys.compactMap { CountryStore.byCode[$0]?.continent }).count
        let rareTried = byCountry.keys.filter { Country.rareCodes.contains($0) }
        rare = rareTried.count

        func cuisine(_ code: String) -> Cuisine? {
            guard let country = CountryStore.byCode[code], let rows = byCountry[code] else { return nil }
            let avg = rows.isEmpty ? 0 : Double(rows.map(\.rating).reduce(0, +)) / Double(rows.count)
            return Cuisine(code: code, flag: country.flagEmoji, name: country.cuisineName,
                           count: rows.count, avgRating: avg)
        }

        // Most-eaten cuisine; ties break on the higher average rating.
        topCuisine = byCountry.keys
            .compactMap(cuisine)
            .max { a, b in (a.count, a.avgRating) < (b.count, b.avgRating) }

        let others = byCountry.keys
            .filter { $0 != topCuisine?.code }
            .compactMap(cuisine)

        if let rarest = others.filter({ Country.rareCodes.contains($0.code) })
            .max(by: { $0.count < $1.count }) {
            second = ("Rarest find", rarest, "\(rare) of \(Country.rareCodes.count) rare cuisines")
        } else if let best = others.max(by: { ($0.avgRating, $0.count) < ($1.avgRating, $1.count) }) {
            second = ("Best rated", best,
                      "★\(String(format: "%.1f", best.avgRating)) across \(best.count) meal\(best.count == 1 ? "" : "s")")
        }
    }
}

// ── Sheets ──────────────────────────────────────────────────────────────────

/// Followers / following. Ids come from the follows table; the profiles they
/// resolve to are whatever the profiles policy lets this user see.
private struct PeopleListSheet: View {
    let title: String
    let ids: (UUID) async throws -> [UUID]
    let userId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var people: [Profile] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(people) { person in
                    NavigationLink {
                        PublicProfileView(profile: person)
                    } label: {
                        HStack(spacing: 12) {
                            ProfilePhotoView(url: person.avatarUrl.flatMap(URL.init), size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name)
                                if let username = person.username, !username.isEmpty {
                                    Text("@\(username)").font(.caption)
                                        .foregroundStyle(Color(.secondaryLabel))
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if loaded && people.isEmpty {
                    ContentUnavailableView(
                        title == "Followers" ? "No followers yet" : "Not following anyone",
                        systemImage: "person.2",
                        description: Text("Find people from the People tab.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let userId else { loaded = true; return }
                let list = (try? await ids(userId)) ?? []
                people = ((try? await SupabaseService.shared.profiles(ids: list)) ?? [])
                    .sorted { $0.name < $1.name }
                loaded = true
            }
        }
    }
}

/// Every cuisine you've tried, most-eaten first.
private struct CuisineListSheet: View {
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    private var rows: [(country: Country, count: Int, avg: Double)] {
        Dictionary(grouping: entries, by: \.countryCode).compactMap { code, rows in
            guard let country = CountryStore.byCode[code] else { return nil }
            let avg = Double(rows.map(\.rating).reduce(0, +)) / Double(rows.count)
            return (country, rows.count, avg)
        }
        .sorted { ($0.count, $0.country.name) > ($1.count, $1.country.name) }
    }

    var body: some View {
        NavigationStack {
            List(rows, id: \.country.code) { row in
                HStack(spacing: 12) {
                    Text(row.country.flagEmoji).font(.title2)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(row.country.cuisineName)
                            if row.country.rare {
                                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Text("\(row.count) meal\(row.count == 1 ? "" : "s") · ★\(String(format: "%.1f", row.avg))")
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    Spacer()
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No cuisines yet",
                        systemImage: "fork.knife",
                        description: Text("Log a meal to start filling the globe.")
                    )
                }
            }
            .navigationTitle("Cuisines tried")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// ── Small pieces ────────────────────────────────────────────────────────────

private struct CountColumn: View {
    let value: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("\(value)").font(.headline).monospacedDigit().foregroundStyle(.primary)
                Text(label).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct InsightCard: View {
    let caption: String
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color(.tertiaryLabel))
            Text(headline).font(.callout.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

private struct ActionRow: View {
    var icon: String? = nil
    /// Branded asset alternative to an SF Symbol.
    var image: String? = nil
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SwiftUI.Group {
                if let image {
                    BrandedIcon(name: image, size: 17)
                } else if let icon {
                    Image(systemName: icon).font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.gradient))
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// Edit name / username / bio and toggle profile visibility (v1.1 item 7).
struct ProfileEditSheet: View {
    let profile: Profile
    var onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var username: String
    @State private var bio: String
    @State private var isPublic: Bool
    @State private var color: String
    @State private var saving = false
    @State private var error: String?

    init(profile: Profile, onSave: @escaping () async -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _username = State(initialValue: profile.username ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _isPublic = State(initialValue: profile.isPublic ?? false)
        _color = State(initialValue: profile.color.lowercased())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                Section("Bio") {
                    TextField("A line about your taste", text: $bio, axis: .vertical)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(GroupPalette.fallbacks, id: \.self) { swatch in
                            Button {
                                color = swatch
                            } label: {
                                Circle()
                                    .fill(Color(uiColor: UIColor(hex: swatch) ?? .systemGray))
                                    .frame(height: 30)
                                    .overlay {
                                        if swatch == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Your color")
                } footer: {
                    Text("This is you on every globe. If someone in a group already uses your color, yours shifts to the next free one there so no two members ever match.")
                }
                Section {
                    Toggle("Public profile", isOn: $isPublic)
                } footer: {
                    Text("Public profiles can be found in People search and followed.")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(name.isEmpty || saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        do {
            try await SupabaseService.shared.updateMyProfile(
                name: name,
                username: trimmedUser.isEmpty ? nil : trimmedUser,
                bio: bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio,
                isPublic: isPublic,
                color: color
            )
            await onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription // e.g. username-taken from the DB
        }
    }
}
