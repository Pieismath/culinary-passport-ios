import SwiftUI
import PhotosUI

/// Your profile: photo, identity, the numbers, and the ways in.
/// The avatar is a photo YOU choose — the AI-generated portrait pipeline was
/// dropped (it cost an API key per user and a stylized face isn't what this
/// app is about); unlockable accessories still composite over the photo.
struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?
    @State private var equipped = EquippedStore.load()
    @State private var profile: Profile?
    @State private var showEdit = false
    @State private var stats = Stats()
    @State private var follows: (followers: Int, following: Int) = (0, 0)

    struct Stats {
        var meals = 0
        var countries = 0
        var continents = 0
        var rare = 0
        var streakWeeks = 0
        var thisYear = 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    countRows
                    cards
                    actionRows

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                            .multilineTextAlignment(.center)
                    }

                    Button("Sign out") {
                        Task { try? await SupabaseService.shared.client.auth.signOut() }
                    }
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .onAppear { equipped = EquippedStore.load() } // reflect customizer changes on return
            .onChange(of: pickedItem) { Task { await uploadPhoto() } }
            .sheet(isPresented: $showEdit) {
                if let profile {
                    ProfileEditSheet(profile: profile) { await load() }
                }
            }
        }
    }

    // ── Header: photo, identity, follow counts, actions ──────────────────────

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ComposedAvatarView(url: avatarURL, equipped: equipped, size: 104)
                    .id(equipped)
                    .background(Circle().fill(.white).padding(-4))
                    .overlay(Circle().stroke(.white, lineWidth: 3).padding(-4))
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
                CountColumn(value: follows.followers, label: "Followers")
                CountColumn(value: follows.following, label: "Following")
                CountColumn(value: stats.countries, label: "Cuisines")
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button { showEdit = true } label: {
                    Text("Edit profile")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                ShareLink(item: shareText) {
                    Text("Share profile")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var shareText: String {
        let handle = profile?.username.map { "@\($0)" } ?? profile?.name ?? "me"
        return "\(handle) has eaten \(stats.countries) of the world's cuisines on Culinary Passport."
    }

    // ── Counts (the Been / Want to try shape) ────────────────────────────────

    private var countRows: some View {
        VStack(spacing: 0) {
            CountRow(icon: "checkmark.circle", tint: .green, title: "Meals logged", value: stats.meals)
            Divider().padding(.leading, 50)
            CountRow(icon: "globe.europe.africa", tint: .blue, title: "Continents", value: stats.continents)
            Divider().padding(.leading, 50)
            CountRow(icon: "sparkles", tint: .orange, title: "Rare finds", value: stats.rare)
        }
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // ── Cards ────────────────────────────────────────────────────────────────

    private var cards: some View {
        HStack(spacing: 10) {
            StatCard(icon: "flame.fill", tint: .orange,
                     value: "\(stats.streakWeeks)", caption: stats.streakWeeks == 1 ? "week streak" : "weeks streak")
            StatCard(icon: "calendar", tint: .purple,
                     value: "\(stats.thisYear)", caption: "meals this year")
        }
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            NavigationLink {
                WrappedView()
            } label: {
                ActionRow(icon: "sparkles", tint: .pink, title: "Year in review")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            NavigationLink {
                AvatarCustomizeView(avatarURL: avatarURL)
            } label: {
                ActionRow(icon: "wand.and.stars", tint: .purple, title: "Customize avatar")
            }
            .buttonStyle(.plain)
            .disabled(avatarURL == nil)
            .opacity(avatarURL == nil ? 0.45 : 1)
        }
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
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
            if let urlString = me.avatarUrl { avatarURL = URL(string: urlString) }
            follows = (try? await SupabaseService.shared.followCounts(userId: me.id)) ?? (0, 0)

            // RLS also returns group-shared entries; the profile counts should
            // only reflect MY meals.
            let mine = ((try? await SupabaseService.shared.myEntries()) ?? [])
                .filter { $0.userId == me.id }
            stats = Self.summarize(mine)
        } catch {
            // Transient load failure — leave the screen as-is (don't sign out).
        }
    }

    static func summarize(_ entries: [Entry]) -> Stats {
        var s = Stats()
        s.meals = entries.count
        let codes = Set(entries.map(\.countryCode))
        s.countries = codes.count
        s.continents = Set(codes.compactMap { CountryStore.byCode[$0]?.continent }).count
        s.rare = codes.filter { Country.rareCodes.contains($0) }.count

        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let dates = entries.compactMap { parser.date(from: $0.dateTried) }
        s.thisYear = dates.filter { calendar.component(.year, from: $0) == year }.count

        // Consecutive weeks with at least one meal, counting back from this
        // week (a not-yet-eaten current week doesn't break the streak).
        let weeks = Set(dates.compactMap {
            calendar.dateInterval(of: .weekOfYear, for: $0)?.start
        })
        guard var cursor = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return s }
        if !weeks.contains(cursor) {
            cursor = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) ?? cursor
        }
        while weeks.contains(cursor) {
            s.streakWeeks += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return s
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
            avatarURL = URL(string: url)
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct CountColumn: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CountRow: View {
    let icon: String
    let tint: Color
    let title: String
    let value: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
            Spacer()
            Text("\(value)").font(.headline).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

private struct ActionRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
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
    @State private var saving = false
    @State private var error: String?

    init(profile: Profile, onSave: @escaping () async -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _username = State(initialValue: profile.username ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _isPublic = State(initialValue: profile.isPublic ?? false)
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
                isPublic: isPublic
            )
            await onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription // e.g. username-taken from the DB
        }
    }
}
