import SwiftUI
import PhotosUI

/// MVP step 4-5: solo profile + the avatar pipeline entry point.
/// Selfie → Vision face-crop → generate-avatar edge function → cached PNG.
struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?
    @State private var equipped = EquippedStore.load()
    @State private var profile: Profile?
    @State private var showEdit = false

    @State private var stats: (countries: Int, meals: Int, continents: Int)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    statsRow
                    actionRows

                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Sign out") {
                        Task { try? await SupabaseService.shared.client.auth.signOut() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
                .padding()
            }
            .background(Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea())
            .navigationTitle("Profile")
            .task { await loadAvatar() }
            .onAppear { equipped = EquippedStore.load() } // reflect customizer changes on return
            .onChange(of: pickedItem) {
                Task { await generate() }
            }
            .sheet(isPresented: $showEdit) {
                if let profile {
                    ProfileEditSheet(profile: profile) { await loadAvatar() }
                }
            }
        }
    }

    // ── Hero: avatar on a soft backdrop, camera FAB, identity (bitmoji-style) ─

    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                // Composited with equipped accessories (ROADMAP item 17).
                ComposedAvatarView(url: avatarURL, equipped: equipped, size: 190)
                    .id(equipped)
                    .background(Circle().fill(.white).padding(-8))
                    .overlay(Circle().stroke(.white, lineWidth: 5).padding(-8))
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                    .overlay {
                        if busy {
                            ZStack {
                                Circle().fill(.black.opacity(0.35))
                                ProgressView().tint(.white)
                            }
                        }
                    }

                // "new selfie → new avatar" lives on the avatar itself.
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                }
                .disabled(busy)
                .offset(x: 6, y: 6)
                .accessibilityLabel("New selfie, new avatar")
            }
            .padding(.top, 26)

            VStack(spacing: 3) {
                Text(profile?.name ?? " ").font(.title2.bold())
                if let username = profile?.username, !username.isEmpty {
                    Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
                }
                if let profile {
                    Label(profile.isPublic == true ? "Public profile" : "Private profile",
                          systemImage: profile.isPublic == true ? "globe" : "lock")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.7), in: Capsule())
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background {
            // warm paper → soft lavender wash, with faint stamp rings
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.99, green: 0.98, blue: 0.96),
                             Color(red: 0.90, green: 0.87, blue: 0.95)],
                    startPoint: .top, endPoint: .bottom
                )
                Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 300, height: 300).offset(x: -130, y: -70)
                Circle().stroke(.white.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 210, height: 210).offset(x: 150, y: 90)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    // ── Stats ────────────────────────────────────────────────────────────────

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(value: stats.map { "\($0.countries)" } ?? "–", label: "cuisines")
            StatTile(value: stats.map { "\($0.meals)" } ?? "–", label: "meals")
            StatTile(value: stats.map { "\($0.continents)" } ?? "–", label: "continents")
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private var actionRows: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AvatarCustomizeView(avatarURL: avatarURL)
            } label: {
                ActionRow(icon: "wand.and.stars", tint: .purple, title: "Customize avatar")
            }
            .buttonStyle(.plain)
            .disabled(avatarURL == nil)
            .opacity(avatarURL == nil ? 0.45 : 1)

            Divider().padding(.leading, 56)

            Button { showEdit = true } label: {
                ActionRow(icon: "pencil", tint: .blue, title: "Edit profile")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            NavigationLink {
                WrappedView()
            } label: {
                ActionRow(icon: "sparkles", tint: .orange, title: "Year in review")
            }
            .buttonStyle(.plain)
        }
        .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private func loadAvatar() async {
        do {
            guard let me = try await SupabaseService.shared.myProfile() else {
                // Profile row is gone (deleted user / stale session) — sign out.
                await SupabaseService.shared.signOut()
                return
            }
            profile = me
            if let urlString = me.avatarUrl { avatarURL = URL(string: urlString) }
            let entries = (try? await SupabaseService.shared.myEntries()) ?? []
            let codes = Set(entries.map(\.countryCode))
            let continents = Set(codes.compactMap { CountryStore.byCode[$0]?.continent })
            stats = (codes.count, entries.count, continents.count)
        } catch {
            // Transient load failure — leave the screen as-is (don't sign out).
        }
    }

    private func generate() async {
        guard let pickedItem else { return }
        busy = true
        defer { busy = false; self.pickedItem = nil }
        do {
            guard let data = try await pickedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                status = "Couldn't read that photo"
                return
            }
            status = "Generating your avatar — takes ~20s…"
            let result = try await AvatarService.generateAvatar(from: image)
            avatarURL = URL(string: "\(result.url)?v=\(Int(Date().timeIntervalSince1970))")
            status = "Done (\(result.provider))"
        } catch {
            status = error.localizedDescription // includes the 3/day limit message from the server
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
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
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.gradient))
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
